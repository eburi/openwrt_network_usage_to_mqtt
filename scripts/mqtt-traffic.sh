#!/bin/sh
# Reads nft per-device byte counters and publishes to MQTT:
#   - total bytes (cumulative, resets on router reboot)
#   - current bandwidth in bytes/s  (two readings BW_INTERVAL seconds apart)
#   - daily usage in bytes          (resets at midnight)
#   - weekly usage in bytes         (resets on Monday / week rollover)
#
# State is kept in STATE_DIR (tmpfs RAM); daily/weekly survive until next reboot.
# Run via cron every minute, e.g.:
#   * * * * * /usr/bin/mqtt-traffic.sh
#
# Run manually (debug):
#   LOG_LEVEL=debug /usr/bin/mqtt-traffic.sh

set -eu

BROKER="192.168.46.222"
MQTT_USER="mqtt_user"
MQTT_PASS="mqtt"

BASE_TOPIC="network/usage"
DISCOVERY_PREFIX="homeassistant"

TABLE_FAMILY="inet"
TABLE_NAME="traffic_monitor"
CHAIN_NAME="forward"

TAG="tm"
LEASES_FILE="/tmp/dhcp.leases"

# State directory lives in tmpfs along with nft counters (both reset on reboot).
STATE_DIR="/tmp/traffic_state"

# Seconds between the two counter readings used for bandwidth calculation.
# Increase for a smoother average; the script blocks for this long each run.
BW_INTERVAL=5

LOG_TAG="mqtt-traffic"
LOG_LEVEL="${LOG_LEVEL:-info}"   # debug|info|warn|error

# ---------- logging ----------
lvl() { case "$1" in debug) echo 10;; info) echo 20;; warn) echo 30;; error) echo 40;; *) echo 20;; esac; }
should_log() { [ "$(lvl "$1")" -ge "$(lvl "$LOG_LEVEL")" ]; }
log() {
  level="$1"; shift
  should_log "$level" || return 0
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$ts [$LOG_TAG] $level: $*" >&2
  logger -t "$LOG_TAG" "$level: $*" 2>/dev/null || true
}
die()      { log error "$*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

need_cmd nft
need_cmd mosquitto_pub
need_cmd jq
need_cmd awk
need_cmd grep
need_cmd ip
need_cmd date
need_cmd logger
need_cmd mktemp
need_cmd sleep

# ---------- MQTT ----------
pub() {
  topic="$1" payload="$2" retain="${3:-false}"
  if [ "$retain" = "true" ]; then
    mosquitto_pub -h "$BROKER" -u "$MQTT_USER" -P "$MQTT_PASS" \
      -r -t "$topic" -m "$payload" 2>/dev/null \
      || log warn "MQTT publish failed topic=$topic (retained)"
  else
    mosquitto_pub -h "$BROKER" -u "$MQTT_USER" -P "$MQTT_PASS" \
      -t "$topic" -m "$payload" 2>/dev/null \
      || log warn "MQTT publish failed topic=$topic"
  fi
}

json_escape() {
  printf '%s' "$1" | awk 'BEGIN{ORS=""}{
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"\\r")
    if(NR>1) printf "\\n"; printf "%s",$0}'
}

# ---------- DHCP / ARP helpers ----------
lease_lookup() {
  [ -r "$LEASES_FILE" ] || return 0
  # DHCP lease format: expiry mac ip hostname clientid
  awk -v ip="$1" '$3==ip{print tolower($2)" "$4; exit}' "$LEASES_FILE" 2>/dev/null || true
}

ip_to_mac() {
  out="$(lease_lookup "$1")"
  mac="$(printf '%s' "$out" | awk '{print $1}')"
  if [ -z "$mac" ]; then
    mac="$(ip neigh show "$1" 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if($i=="lladdr"){print tolower($(i+1)); exit}}' || true)"
  fi
  printf '%s' "$mac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' \
    && printf '%s' "$mac" || printf ''
}

ip_to_name() {
  out="$(lease_lookup "$1")"
  hn="$(printf '%s' "$out" | awk '{print $2}')"
  if [ -n "$hn" ] && [ "$hn" != "*" ]; then printf '%s' "$hn"; else printf '%s' "$1"; fi
}

# ---------- nft ----------
# Output one line per tracked rule: "<ip> <dir> <bytes> <packets>"
# Uses nft -j (JSON) output parsed with jq – no regex library required;
# startswith() is sufficient since ONIGURUMA is not available on OpenWrt jq.
get_counters() {
  nft -j list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" 2>/dev/null \
    | jq -r --arg tag "${TAG}:" '
        .nftables[] | .rule?
        | select((.comment // "") | startswith($tag))
        | (.comment | split(":")) as $c
        | [ $c[1], $c[2],
            (.expr[] | .counter?.bytes   // empty | tostring),
            (.expr[] | .counter?.packets // empty | tostring)
          ]
        | join(" ")
      '
}

# ---------- per-MAC+dir state ----------
# State file: $STATE_DIR/<mac_id>_<dir>
# Each line: key=value
# Keys: bw_bytes bw_ts day_bytes day_date week_bytes week_num

_state_file() { printf '%s/%s_%s' "$STATE_DIR" "$1" "$2"; }

load_state() {
  # Outputs variable assignments via stdout; caller evals result.
  bw_bytes=0 bw_ts=0 day_bytes=0 day_date="" week_bytes=0 week_num=""
  f="$(_state_file "$1" "$2")"
  [ -r "$f" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      bw_bytes)   bw_bytes="$v"   ;;
      bw_ts)      bw_ts="$v"      ;;
      day_bytes)  day_bytes="$v"  ;;
      day_date)   day_date="$v"   ;;
      week_bytes) week_bytes="$v" ;;
      week_num)   week_num="$v"   ;;
    esac
  done < "$f"
}

save_state() {
  printf 'bw_bytes=%s\nbw_ts=%s\nday_bytes=%s\nday_date=%s\nweek_bytes=%s\nweek_num=%s\n' \
    "$bw_bytes" "$bw_ts" "$day_bytes" "$day_date" "$week_bytes" "$week_num" \
    > "$(_state_file "$1" "$2")"
}

# ---------- HA discovery ----------
# 4 sensors per direction (in/out) per device:
#   total bytes, bandwidth (B/s), daily bytes, weekly bytes
publish_discovery() {
  mac="$1" name="$2"
  mac_id="$(printf '%s' "$mac" | tr ':' '_')"
  dev_id="openwrt_${mac_id}"
  dev_name="LAN $(json_escape "$name")"
  dev_json='"device":{"identifiers":["'"$dev_id"'"],"name":"'"$dev_name"'","model":"OpenWrt nft counters","manufacturer":"OpenWrt","connections":[["mac","'"$mac"'"]]}'

  _disc() {
    # _disc <sensor_suffix> <label> <value_template> <unit> <state_class> [device_class]
    obj="lan_${mac_id}_$1"
    dc_field=""; [ -n "${6:-}" ] && dc_field=',"device_class":"'"$6"'"'
    payload='{"name":"'"$dev_name $2"'","state_topic":"'"$state_topic"'","value_template":"'"$3"'","unique_id":"'"${dev_id}_$1"'"'"$dc_field"',"unit_of_measurement":"'"$4"'","state_class":"'"$5"'",'"$dev_json"'}'
    pub "$DISCOVERY_PREFIX/sensor/$obj/config" "$payload" true
  }

  for dir in in out; do
    state_topic="$BASE_TOPIC/$mac/$dir"
    case "$dir" in in) lbl="In";; *) lbl="Out";; esac

    _disc "${dir}_bytes"  "$lbl Total"     '{{ value_json.bytes }}'   "B"   "total_increasing" "data_size"
    _disc "${dir}_bw"     "$lbl Bandwidth" '{{ value_json.bw }}'      "B/s" "measurement"      "data_rate"
    _disc "${dir}_daily"  "$lbl Daily"     '{{ value_json.daily }}'   "B"   "measurement"       "data_size"
    _disc "${dir}_weekly" "$lbl Weekly"    '{{ value_json.weekly }}'  "B"   "measurement"       "data_size"
  done

  log info "Discovery published for $mac ($name)"
}

# ---------- process one counter entry ----------
process_entry() {
  ipaddr="$1" dir="$2" bytes_now="$3" bw_delta_bytes="$4"
  today="$5"  this_week="$6"  now_ts="$7"

  [ "$ipaddr" = "$BROKER" ] && { log debug "Skipping broker $ipaddr"; return 0; }

  mac="$(ip_to_mac "$ipaddr")"
  if [ -z "$mac" ]; then
    log warn "No MAC for $ipaddr (dir=$dir), skipping"
    return 0
  fi

  mac_id="$(printf '%s' "$mac" | tr ':' '_')"
  name="$(ip_to_name "$ipaddr")"

  # Publish discovery once per MAC per run (retained – broker caches it)
  if ! grep -Fxq "$mac" "$SEEN_MACS_FILE" 2>/dev/null; then
    publish_discovery "$mac" "$name"
    printf '%s\n' "$mac" >> "$SEEN_MACS_FILE"
  fi

  load_state "$mac_id" "$dir"

  # ---- current bandwidth (bytes/s) ----
  bw=$(( bw_delta_bytes / BW_INTERVAL ))
  [ "$bw" -lt 0 ] && bw=0

  # ---- counter-reset guard (nft rules re-created after reboot → counters at 0) ----
  [ "$bytes_now" -lt "$day_bytes" ]  && { day_bytes=0;  day_date=""; }
  [ "$bytes_now" -lt "$week_bytes" ] && { week_bytes=0; week_num=""; }

  # ---- daily baseline (set/reset once per calendar day) ----
  if [ "$day_date" != "$today" ]; then
    day_bytes="$bytes_now"; day_date="$today"
    log debug "Daily baseline reset for $mac $dir (date=$today)"
  fi
  daily=$(( bytes_now - day_bytes ))

  # ---- weekly baseline (set/reset once per ISO week) ----
  if [ "$week_num" != "$this_week" ]; then
    week_bytes="$bytes_now"; week_num="$this_week"
    log debug "Weekly baseline reset for $mac $dir (week=$this_week)"
  fi
  weekly=$(( bytes_now - week_bytes ))

  # ---- persist updated state ----
  bw_bytes="$bytes_now"; bw_ts="$now_ts"
  save_state "$mac_id" "$dir"

  # ---- publish state ----
  name_json="$(json_escape "$name")"
  topic="$BASE_TOPIC/$mac/$dir"
  payload="$(printf '{"ip":"%s","mac":"%s","name":"%s","dir":"%s","bytes":%s,"bw":%s,"daily":%s,"weekly":%s,"ts":%s}' \
    "$ipaddr" "$mac" "$name_json" "$dir" \
    "$bytes_now" "$bw" "$daily" "$weekly" "$now_ts")"

  log info "pub $topic  bw=${bw}B/s  daily=${daily}B  weekly=${weekly}B  total=${bytes_now}B"
  pub "$topic" "$payload" false
}

# ---------- main ----------
log info "Starting. broker=$BROKER table=$TABLE_FAMILY/$TABLE_NAME chain=$CHAIN_NAME bw_interval=${BW_INTERVAL}s level=$LOG_LEVEL"

mkdir -p "$STATE_DIR"

nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1 \
  || die "Missing nft table: $TABLE_FAMILY $TABLE_NAME"
nft list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" >/dev/null 2>&1 \
  || die "Missing nft chain: $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME"

SNAP1="$(mktemp)"
SNAP2="$(mktemp)"
SEEN_MACS_FILE="$(mktemp)"
trap 'rm -f "$SNAP1" "$SNAP2" "$SEEN_MACS_FILE"' EXIT

# Take two counter snapshots BW_INTERVAL seconds apart for bandwidth measurement.
# One nft call each – very cheap on resources.
log debug "Snapshot 1 …"
get_counters > "$SNAP1"
sleep "$BW_INTERVAL"
log debug "Snapshot 2 …"
get_counters > "$SNAP2"

rows="$(wc -l < "$SNAP2" | tr -d ' ')"
if [ "$rows" = "0" ]; then
  log warn "No counters found. Check: nft -a list chain $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME"
  exit 0
fi

now_ts="$(date +%s)"
today="$(date +%Y%m%d)"
this_week="$(date +%Y%W)"   # %W = week 00-53, Monday-based (busybox-safe)

log debug "ts=$now_ts  today=$today  week=$this_week  rows=$rows"

# Join both snapshots on (ip, dir) and compute per-entry byte delta for bandwidth.
awk '
  NR==FNR { snap1[$1,$2] = $3+0; next }
  {
    ip=$1; dir=$2; bytes=$3
    delta = bytes - snap1[ip,dir]+0
    if (delta < 0) delta = 0
    print ip, dir, bytes, delta
  }
' "$SNAP1" "$SNAP2" | while read -r ipaddr dir bytes_now bw_delta; do
  [ -n "$ipaddr" ] || continue
  process_entry "$ipaddr" "$dir" "$bytes_now" "$bw_delta" \
    "$today" "$this_week" "$now_ts" || true
done

log info "Done. rows=$rows"
