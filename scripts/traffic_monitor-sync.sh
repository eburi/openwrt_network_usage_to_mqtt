# Creates/maintains per-device nftables counter rules automatically from DHCP leases, with logging.
#
# Rules are tagged by comment:
#   "tm:<ip>:out" (ip saddr <ip>)
#   "tm:<ip>:in"  (ip daddr <ip>)
#
# Logs go to:
#   - stderr (console when run manually)
#   - syslog via logger (view with: logread -e traffic-sync)
#
# Run manually (debug):
#   LOG_LEVEL=debug /usr/bin/traffic_monitor-sync.sh
# Extra shell trace:
#   sh -x /usr/bin/traffic_monitor-sync.sh

#!/bin/sh
set -eu

TABLE_FAMILY="inet"
TABLE_NAME="traffic_monitor"
CHAIN_NAME="forward"

LEASES_FILE="/tmp/dhcp.leases"

TAG="tm"

LOG_TAG="traffic-sync"
LOG_LEVEL="${LOG_LEVEL:-info}"   # debug|info|warn|error

lvl() {
  case "$1" in
    debug) echo 10 ;;
    info)  echo 20 ;;
    warn)  echo 30 ;;
    error) echo 40 ;;
    *)     echo 20 ;;
  esac
}

should_log() {
  [ "$(lvl "$1")" -ge "$(lvl "$LOG_LEVEL")" ]
}

log() {
  level="$1"; shift
  msg="$*"
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if should_log "$level"; then
    echo "$ts [$LOG_TAG] $level: $msg" >&2
    logger -t "$LOG_TAG" "$level: $msg" 2>/dev/null || true
  fi
}

die() {
  log error "$*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

need_cmd nft
need_cmd awk
need_cmd grep
need_cmd sort
need_cmd sed
need_cmd mktemp
need_cmd date
need_cmd logger

nft_exists_table() { nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; }
nft_exists_chain() { nft list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" >/dev/null 2>&1; }

ensure_nft_objects() {
  if ! nft_exists_table; then
    log info "Creating nft table: $TABLE_FAMILY $TABLE_NAME"
    nft add table "$TABLE_FAMILY" "$TABLE_NAME"
  else
    log debug "nft table exists: $TABLE_FAMILY $TABLE_NAME"
  fi

  if ! nft_exists_chain; then
    log info "Creating nft chain with forward hook: $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME"
    nft add chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" \
      "{ type filter hook forward priority 0; }"
  else
    log debug "nft chain exists: $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME"
  fi
}

rule_exists() {
  ip="$1"
  dir="$2" # out|in

  if [ "$dir" = "out" ]; then
    pat="ip saddr $ip"
    cmt="$TAG:$ip:out"
  else
    pat="ip daddr $ip"
    cmt="$TAG:$ip:in"
  fi

  nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" 2>/dev/null \
    | grep -F "$pat" | grep -F "comment \"$cmt\"" >/dev/null 2>&1
}

add_rules_for_ip() {
  ip="$1"

  if ! rule_exists "$ip" "out"; then
    log info "Adding rule OUT for $ip (comment \"$TAG:$ip:out\")"
    nft add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" \
      ip saddr "$ip" counter comment "\"$TAG:$ip:out\""
  else
    log debug "Rule OUT already exists for $ip"
  fi

  if ! rule_exists "$ip" "in"; then
    log info "Adding rule IN for $ip (comment \"$TAG:$ip:in\")"
    nft add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" \
      ip daddr "$ip" counter comment "\"$TAG:$ip:in\""
  else
    log debug "Rule IN already exists for $ip"
  fi
}

prune_stale_rules() {
  current_ips_file="$1"

  log debug "Pruning rules not in current DHCP IP list: $current_ips_file"

  nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" 2>/dev/null \
    | sed -n 's/.*ip \(saddr\|daddr\) \([0-9.]\+\).*comment "'"$TAG"':[^\"]\+".*handle \([0-9]\+\).*/\2 \3/p' \
    | while read -r ip handle; do
        [ -n "$ip" ] || continue
        if ! grep -qx "$ip" "$current_ips_file"; then
          log info "Deleting stale rule handle=$handle for ip=$ip (no longer in leases)"
          nft delete rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" handle "$handle" || log warn "Failed to delete handle=$handle"
        else
          log debug "Keeping rule for ip=$ip (still in leases)"
        fi
      done
}

log info "Starting. table=$TABLE_FAMILY/$TABLE_NAME chain=$CHAIN_NAME tag=$TAG leases=$LEASES_FILE level=$LOG_LEVEL"

ensure_nft_objects

if [ ! -r "$LEASES_FILE" ]; then
  log warn "Leases file not readable: $LEASES_FILE. Nothing to do."
  exit 0
fi

tmp_ips="$(mktemp)"
trap 'rm -f "$tmp_ips"' EXIT

awk '{print $3}' "$LEASES_FILE" \
  | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/' \
  | sort -u > "$tmp_ips"

lease_count="$(wc -l < "$tmp_ips" | tr -d ' ')"
log info "Found $lease_count unique DHCP IPv4 addresses in leases"

if [ "$lease_count" = "0" ]; then
  log warn "No DHCP IPs found in $LEASES_FILE. No rules added."
  exit 0
fi

# Note: counters like added/kept inside while may not propagate in some /bin/sh implementations.
# We log per-IP actions anyway, plus a final snapshot count.
while read -r ip; do
  [ -n "$ip" ] || continue
  log debug "Processing IP: $ip"
  add_rules_for_ip "$ip"
done < "$tmp_ips"

# Optional: prune rules for devices not currently leased
prune_stale_rules "$tmp_ips"

# Final rule summary
rule_lines="$(nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" 2>/dev/null | grep -F "comment \"$TAG:" | wc -l | tr -d ' ' || true)"
log info "Done. managed_rule_lines=$rule_lines (should be ~2 per active leased IP)"

# Debug tip: show managed rules quickly
log debug "Managed rules (grep):"
if should_log debug; then
  nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" 2>/dev/null \
    | grep -F "comment \"$TAG:" >&2 || true
fi