#!/bin/sh
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

LOG_TAG="mqtt-traffic"
LOG_LEVEL="${LOG_LEVEL:-info}"   # debug|info|warn|error

# ---------- logging ----------
lvl() { case "$1" in debug) echo 10;; info) echo 20;; warn) echo 30;; error) echo 40;; *) echo 20;; esac; }
should_log() { [ "$(lvl "$1")" -ge "$(lvl "$LOG_LEVEL")" ]; }
log() {
  level="$1"; shift
  msg="$*"
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if should_log "$level"; then
    echo "$ts [$LOG_TAG] $level: $msg" >&2
    logger -t "$LOG_TAG" "$level: $msg" 2>/dev/null || true
  fi
}

die() { log error "$*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

need_cmd nft
need_cmd mosquitto_pub
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd ip
need_cmd date
need_cmd logger
need_cmd mktemp

# ---------- helpers ----------
pub() {
  topic="$1"
  payload="$2"
  retain="${3:-false}"

  # -r for retained messages
  if [ "$retain" = "true" ]; then
    if ! err="$(mosquitto_pub -h "$BROKER" -u "$MQTT_USER" -P "$MQTT_PASS" -r -t "$topic" -m "$payload" 2>&1)"; then
      log warn "MQTT publish failed topic=$topic retain=true error=${err:-unknown}"
    fi
  else
    if ! err="$(mosquitto_pub -h "$BROKER" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>&1)"; then
      log warn "MQTT publish failed topic=$topic retain=false error=${err:-unknown}"
    fi
  fi
}

json_escape() {
  printf '%s' "$1" | awk 'BEGIN { ORS="" } {
    gsub(/\\/,"\\\\")
    gsub(/"/,"\\\"")
    gsub(/\t/,"\\t")
    gsub(/\r/,"\\r")
    if (NR > 1) printf "\\n"
    printf "%s", $0
  }'
}

# From DHCP lease: ip -> (mac, hostname)
lease_lookup() {
  ipaddr="$1"
  if [ -r "$LEASES_FILE" ]; then
    # expiry mac ip hostname clientid
    awk -v ip="$ipaddr" '$3==ip {print tolower($2) " " $4; exit}' "$LEASES_FILE" 2>/dev/null || true
  fi
}

ip_to_mac() {
  ipaddr="$1"
  out="$(lease_lookup "$ipaddr")"
  mac="$(echo "$out" | awk '{print $1}')"

  if [ -z "$mac" ]; then
    mac="$(ip neigh show "$ipaddr" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="lladdr"){print tolower($(i+1)); exit}}' || true)"
  fi

  echo "$mac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' && echo "$mac" || echo ""
}

ip_to_name() {
  ipaddr="$1"
  out="$(lease_lookup "$ipaddr")"
  hn="$(echo "$out" | awk '{print $2}')"
  if [ -n "$hn" ] && [ "$hn" != "*" ]; then
    echo "$hn"
  else
    echo "$ipaddr"
  fi
}

# mqtt discovery: create sensors (retained)
publish_discovery_for_mac() {
  mac="$1"
  name="$2"

  mac_id="$(echo "$mac" | tr ':' '_')"     # valid for entity unique_id/object_id
  dev_name="LAN ${name}"
  dev_name_json="$(json_escape "$dev_name")"
  dev_id="openwrt_${mac_id}"

  # Bytes IN sensor
  obj_in="lan_${mac_id}_in_bytes"
  topic_in="$DISCOVERY_PREFIX/sensor/$obj_in/config"
  state_in="$BASE_TOPIC/$mac/in"

  payload_in=$(cat <<EOF
{"name":"${dev_name_json} In Bytes","state_topic":"${state_in}","value_template":"{{ value_json.bytes }}","unique_id":"${dev_id}_in_bytes","device_class":"data_size","unit_of_measurement":"B","state_class":"total_increasing","device":{"identifiers":["${dev_id}"],"name":"${dev_name_json}","model":"OpenWrt nft counters","manufacturer":"OpenWrt","connections":[["mac","${mac}"]]}}
EOF
)
  pub "$topic_in" "$payload_in" true

  # Bytes OUT sensor
  obj_out="lan_${mac_id}_out_bytes"
  topic_out="$DISCOVERY_PREFIX/sensor/$obj_out/config"
  state_out="$BASE_TOPIC/$mac/out"

  payload_out=$(cat <<EOF
{"name":"${dev_name_json} Out Bytes","state_topic":"${state_out}","value_template":"{{ value_json.bytes }}","unique_id":"${dev_id}_out_bytes","device_class":"data_size","unit_of_measurement":"B","state_class":"total_increasing","device":{"identifiers":["${dev_id}"],"name":"${dev_name_json}","model":"OpenWrt nft counters","manufacturer":"OpenWrt","connections":[["mac","${mac}"]]}}
EOF
)
  pub "$topic_out" "$payload_out" true

  log info "Discovery published (retained) for $mac ($name)"
}

# Extract counters from your actual nft output format:
# "... counter packets P bytes B comment "tm:IP:dir" ..."
get_counters() {
  nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" 2>/dev/null \
    | sed -n 's/.*counter packets \([0-9]\+\) bytes \([0-9]\+\) comment "'"$TAG"':\([0-9.]\+\):\(in\|out\)".*/\3 \4 \2 \1/p'
}

publish_state() {
  ipaddr="$1"
  dir="$2"
  bytes="$3"
  packets="$4"

  # Skip broker itself to reduce noise (optional but recommended)
  [ "$ipaddr" = "$BROKER" ] && { log debug "Skipping broker IP $ipaddr"; return 0; }

  mac="$(ip_to_mac "$ipaddr")"
  if [ -z "$mac" ]; then
    log warn "No MAC found for IP $ipaddr (dir=$dir). Skipping."
    return 0
  fi

  name="$(ip_to_name "$ipaddr")"

  # Publish discovery once per MAC in this run
  if ! grep -Fxq "$mac" "$SEEN_MACS_FILE" 2>/dev/null; then
    publish_discovery_for_mac "$mac" "$name"
    printf '%s\n' "$mac" >> "$SEEN_MACS_FILE"
  fi

  name_json="$(json_escape "$name")"

  topic="$BASE_TOPIC/$mac/$dir"
  ts="$(date +%s)"
  payload=$(printf '{"ip":"%s","mac":"%s","name":"%s","dir":"%s","bytes":%s,"packets":%s,"ts":%s}' \
    "$ipaddr" "$mac" "$name_json" "$dir" "$bytes" "$packets" "$ts")

  log info "Publishing state to $topic payload=$payload"
  pub "$topic" "$payload" false
}

# ---------- main ----------
log info "Starting. broker=$BROKER base_topic=$BASE_TOPIC discovery=$DISCOVERY_PREFIX table=$TABLE_FAMILY/$TABLE_NAME chain=$CHAIN_NAME tag=$TAG leases=$LEASES_FILE level=$LOG_LEVEL"

SEEN_MACS_FILE="$(mktemp)"
trap 'rm -f "$SEEN_MACS_FILE"' EXIT

# Sanity checks
nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1 || die "Missing nft table: $TABLE_FAMILY $TABLE_NAME"
nft list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" >/dev/null 2>&1 || die "Missing nft chain: $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME"

rows="$(get_counters | wc -l | tr -d ' ')"
if [ "$rows" = "0" ]; then
  log warn "No counters matched. Check: nft -a list chain $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME"
  exit 0
fi

get_counters | while read -r ipaddr dir bytes packets; do
  [ -n "$ipaddr" ] || continue
  publish_state "$ipaddr" "$dir" "$bytes" "$packets" || true
done

log info "Done. matched_rows=$rows"