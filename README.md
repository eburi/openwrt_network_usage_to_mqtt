# openwrt-network-usage-to-mqtt

Tracks per-device network usage on an OpenWrt router and publishes it to MQTT. Integrates with Home Assistant via auto-discovery.

**Before you start, have ready:**
- Router IP and SSH access (`root@<router-ip>`)
- MQTT broker IP, username, and password

---

## Requirements

OpenWrt 22.03+ (firewall4/nftables). Install dependencies on the router:

```sh
opkg update && opkg install mosquitto-client jq
```

---

## Installation

### 1. Copy scripts to the router

```sh
scp scripts/traffic_monitor-sync.sh scripts/mqtt-traffic.sh root@<router-ip>:/usr/bin/
ssh root@<router-ip> 'chmod +x /usr/bin/traffic_monitor-sync.sh /usr/bin/mqtt-traffic.sh'
```

### 2. Set MQTT credentials

On the router, edit `/usr/bin/mqtt-traffic.sh` and update these lines at the top:

```sh
BROKER="192.168.1.100"   # your MQTT broker IP
MQTT_USER="mqtt_user"
MQTT_PASS="mqtt"
```

### 3. Create nft rules

```sh
/usr/bin/traffic_monitor-sync.sh
```

Verify rules were created:

```sh
nft -j list chain inet traffic_monitor forward | jq '.nftables[] | .rule?'
```

### 4. Test

```sh
LOG_LEVEL=debug /usr/bin/mqtt-traffic.sh
```

On your broker machine, check messages are arriving:

```sh
mosquitto_sub -h <broker-ip> -u <user> -P <pass> -t 'network/#' -v
```

### 5. Home Assistant discovery

In HA: **Settings → Devices & Services → MQTT → Configure** → enable **Enable discovery**.  
Sensors appear automatically after the first script run.

---

## Cron (runs automatically)

```sh
crontab -e
```

Add:

```
*/5 * * * * /usr/bin/traffic_monitor-sync.sh
* * * * * /usr/bin/mqtt-traffic.sh
```

```sh
/etc/init.d/cron restart
```

---

## What gets published

Topic: `network/usage/<mac>/in` and `.../out`

```json
{
  "ip": "192.168.1.50",
  "mac": "aa:bb:cc:dd:ee:ff",
  "name": "my-laptop",
  "dir": "in",
  "bytes": 9968801,
  "bw": 1240,
  "daily": 4512000,
  "weekly": 31200000,
  "ts": 1740398400
}
```

8 HA sensors per device: Total, Bandwidth, Daily, Weekly — for both in and out.

---

## How it works: nft rules and jq

### Rules added per device

`traffic_monitor-sync.sh` creates two rules per DHCP-leased IP in an `inet` table with a `forward` chain hooked at priority 0. The chain is type `filter`, so it sees all forwarded packets passing through the router.

```
table inet traffic_monitor {
    chain forward {
        type filter hook forward priority filter; policy accept;

        ip saddr 192.168.46.128 counter comment "tm:192.168.46.128:out"  # handle 4
        ip daddr 192.168.46.128 counter comment "tm:192.168.46.128:in"   # handle 5
    }
}
```

- `ip saddr <ip>` — matches packets **from** the device (outbound from device's perspective)
- `ip daddr <ip>` — matches packets **to** the device (inbound to device)
- `counter` — the kernel accumulates `packets` and `bytes` in-place; no userspace daemon needed
- The comment `tm:<ip>:dir` is the tag used to identify and manage rules by both scripts
- Rules never drop traffic — the chain policy is `accept`

Rules are pruned automatically when an IP leaves DHCP leases. The handle (numeric rule ID) is used for deletion.

---

### nft JSON output (`nft -j`)

Both scripts use `nft -j list chain inet traffic_monitor forward` to read counters as structured JSON, avoiding fragile text parsing. A single rule looks like:

```json
{
  "family": "inet",
  "table": "traffic_monitor",
  "chain": "forward",
  "handle": 5,
  "comment": "tm:192.168.46.128:in",
  "expr": [
    {
      "match": {
        "op": "==",
        "left": { "payload": { "protocol": "ip", "field": "daddr" } },
        "right": "192.168.46.128"
      }
    },
    {
      "counter": {
        "packets": 22762,
        "bytes": 11791165
      }
    }
  ]
}
```

The full chain output wraps all rules in a top-level array:

```json
{
  "nftables": [
    { "metainfo": { "version": "1.1.1", ... } },
    { "chain": { "family": "inet", "table": "traffic_monitor", "name": "forward", ... } },
    { "rule": { ... } },
    { "rule": { ... } }
  ]
}
```

---

### How jq extracts counter data

**`mqtt-traffic.sh` — reading bytes and packets for all tracked rules:**

```sh
nft -j list chain inet traffic_monitor forward \
  | jq -r --arg tag "tm:" '
      .nftables[] | .rule?
      | select((.comment // "") | startswith($tag))
      | (.comment | split(":")) as $c
      | [ $c[1], $c[2],
          (.expr[] | .counter?.bytes   // empty | tostring),
          (.expr[] | .counter?.packets // empty | tostring)
        ]
      | join(" ")
    '
```

Output (one line per rule, `ip dir bytes packets`):

```
192.168.46.123 out 142176 1348
192.168.46.123 in  593079 1303
192.168.46.128 out 13348220 19756
192.168.46.128 in  11791165 22762
```

- `.nftables[] | .rule?` — iterate objects, keep only rule entries (skip metainfo, chain)
- `select(... | startswith($tag))` — filter to only our tagged rules; `startswith()` is used because OpenWrt's `jq` build lacks ONIGURUMA regex (`test`/`match`)
- `(.comment | split(":")) as $c` — splits `"tm:192.168.46.128:in"` → `["tm","192.168.46.128","in"]`
- `.expr[] | .counter?.bytes // empty` — iterates the `expr` array, picks up the counter object

---

**`traffic_monitor-sync.sh` — checking if a rule already exists:**

```sh
nft -j list chain inet traffic_monitor forward \
  | jq -e --arg cmt "tm:192.168.46.128:in" '
      .nftables[] | .rule? | select(.comment == $cmt)
    '
```

`jq -e` exits non-zero when no match is found — used directly as a shell condition.

---

**`traffic_monitor-sync.sh` — finding handles of stale rules to delete:**

```sh
nft -j list chain inet traffic_monitor forward \
  | jq -r --arg tag "tm:" '
      .nftables[] | .rule?
      | select((.comment // "") | startswith($tag))
      | [(.handle | tostring), (.comment | split(":")[1])]
      | join(" ")
    '
```

Output (`handle ip`):

```
2 192.168.46.123
3 192.168.46.123
4 192.168.46.128
5 192.168.46.128
```

Stale rules are deleted by handle: `nft delete rule inet traffic_monitor forward handle <n>`

---

### Bandwidth calculation

`mqtt-traffic.sh` takes two counter snapshots `BW_INTERVAL` seconds apart (default 5 s), then computes delta with `awk`:

```sh
delta = bytes_snap2 - bytes_snap1
bw    = delta / BW_INTERVAL          # bytes/s
```

If the counter decreased (router reboot between snapshots), delta is clamped to 0.

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `BROKER` | — | MQTT broker IP |
| `MQTT_USER` / `MQTT_PASS` | — | MQTT credentials |
| `BASE_TOPIC` | `network/usage` | Root MQTT topic |
| `DISCOVERY_PREFIX` | `homeassistant` | HA discovery prefix |
| `BW_INTERVAL` | `5` | Seconds between bandwidth snapshots |
| `STATE_DIR` | `/tmp/traffic_state` | Per-device baseline state (tmpfs) |
| `LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |

---

## Troubleshooting

**No counters found** — re-run the sync script:
```sh
/usr/bin/traffic_monitor-sync.sh
```

**MQTT not authorised** — check credentials and ensure the broker ACL allows publish to `network/usage/#` and `homeassistant/#`.

**HA not discovering sensors** — check discovery is enabled in HA, then verify messages are arriving:
```sh
mosquitto_sub -h <broker> -u <user> -P <pass> -t 'homeassistant/#' -v
```
