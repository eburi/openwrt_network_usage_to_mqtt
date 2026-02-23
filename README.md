# OpenWrt Per-Device Network Usage → MQTT (Home Assistant Compatible)

This project provides lightweight per-device network usage monitoring on **OpenWrt** using `nftables` counters and publishes usage data to an MQTT broker.

It is designed to:

- Track **per-device traffic** (LAN ↔ WAN)
- Avoid storing historical data on the router
- Publish usage to MQTT per **MAC address**
- Support **Home Assistant MQTT Discovery**
- Run efficiently on low-memory routers

The repository contains two scripts:
```
scripts/
├── traffic_monitor-sync.sh
└── mqtt-traffic.sh
```

---

## How It Works

### 1️⃣ `traffic_monitor-sync.sh`

- Reads active DHCP leases from `/tmp/dhcp.leases`
- Automatically creates per-device `nftables` counter rules
- Maintains rules as devices join/leave the network
- Adds two counters per device:
  - `in`  (traffic to device)
  - `out` (traffic from device)

Example nft rule:
```
ip saddr 192.168.46.200 counter packets 5051 bytes 2861847 comment "tm:192.168.46.200:out"
```

---

### 2️⃣ `mqtt-traffic.sh`

- Reads nft counters
- Maps IP → MAC → hostname
- Publishes MQTT state topics:
```
    network/usage/<mac>/in
    network/usage/<mac>/out
```

- Publishes Home Assistant MQTT discovery messages: `homeassistant/sensor/.../config`
  This automatically creates sensors in Home Assistant for each device.

---

## Requirements

On OpenWrt:

- firewall4 (nftables-based)
- `mosquitto-client`
- `awk`, `sed`, `ip`, `logger`

Install required packages:

```sh
opkg update
opkg install mosquitto-client
```

# Installation

1️. Copy Scripts to Router

Clone the repository locally and copy to OpenWrt:
```sh
scp scripts/*.sh root@<router-ip>:/usr/bin/
```

Make executable:
```sh
chmod +x /usr/bin/traffic_monitor-sync.sh
chmod +x /usr/bin/mqtt-traffic.sh
```

2. Configure MQTT Credentials

Edit /usr/bin/mqtt-traffic.sh:
```
BROKER="192.168.46.222"
MQTT_USER="mqtt_user"
MQTT_PASS="mqtt"
```

3. Initialize nft Table (First Run)

Run once manually:
```sh
/usr/bin/traffic_monitor-sync.sh
```

Verify rules exist:
```sh
nft -a list chain inet traffic_monitor forward
```

You should see rules containing:
```
comment "tm:<ip>:in"
comment "tm:<ip>:out"
```

4. Test MQTT Publishing

Run manually:
```sh
LOG_LEVEL=debug /usr/bin/mqtt-traffic.sh
```

Verify on broker:

```sh
mosquitto_sub -h 192.168.46.222 -u mqtt_user -P mqtt -t 'network/#' -v
```

You should see per-MAC topics.

5. Enable Home Assistant Discovery

In Home Assistant:
```sh
Settings → Devices & Services → MQTT → Configure
```
Ensure Enable discovery is ON.

To verify discovery messages:
```sh
mosquitto_sub -h 192.168.46.222 -u mqtt_user -P mqtt -t 'homeassistant/#' -v
```

Then run:

```sh
/usr/bin/mqtt-traffic.sh
```

New devices should appear automatically.



## Automation (Cron)

Add periodic sync and publishing:

```sh
crontab -e
```

Example:
```
*/5 * * * * /usr/bin/traffic_monitor-sync.sh
* * * * * /usr/bin/mqtt-traffic.sh
```

Restart cron:
```sh
/etc/init.d/cron restart
```

## Home Assistant Sensors

For each device, two sensors are created:

- <Device> In Bytes
- <Device> Out Bytes

Characteristics:

- device_class: data_size
- state_class: total_increasing
- Units: Bytes (B)

You can use:

- Utility Meter helper → daily/monthly usage
- Statistics graph → historical trends
- Template sensors → convert to MB/GB

# Notes & Design Decisions

- No historical storage on router
- Only cumulative nft counters are used
- Rate calculation should be done in Home Assistant
- Rules automatically follow DHCP leases
- Broker IP can be excluded to reduce noise

# Troubleshooting

## No counters found
Run:
```sh
nft -a list chain inet traffic_monitor forward
```
If empty:
```sh
/usr/bin/traffic_monitor-sync.sh
```

## MQTT “Not authorised”
Ensure:
- Username/password are correct
- ACL allows publish to:
-- `network/usage/#`
-- `homeassistant/#`

## Home Assistant not discovering sensors
Check:
```sh
mosquitto_sub -h <broker> -u <user> -P <pass> -t 'homeassistant/#' -v
```
If no output:
- Discovery publish not working
- MQTT discovery disabled in HA
- Wrong broker configured in HA


# What This Is Not
- Not a full NetFlow/IPFIX solution
- Not deep packet inspection
- Not historical storage on the router
- Not bandwidth shaping

It is a lightweight, transparent, router-native accounting system.