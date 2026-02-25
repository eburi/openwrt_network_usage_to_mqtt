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
