# pktfwd-station-bridge

Relay a **Semtech-UDP packet forwarder** to a **BasicStation LNS** (ThingPark, ChirpStack, …).

Some LoRaWAN gateways cannot run LoRa Basics Station natively — e.g. the
**Gemtek / Browan Indoor Femto (WLRGFM-100)**, whose SX1301 sits behind a
proprietary `/dev/semtech0` kernel driver (`gmspi_module`) instead of `spidev`,
so the stock Station HAL can't drive the radio. These gateways only ship the
legacy Semtech UDP `lora_pkt_fwd`. This bridge lets them join a CUPS/BasicStation
network server **without replacing firmware or porting the HAL**: the native
packet forwarder keeps driving the radio, and the bridge translates its
UDP stream to the BasicStation WebSocket protocol.

```
 SX1301 ──(/dev/semtech0)── lora_pkt_fwd ──Semtech UDP──▶ pktfwd-station-bridge ──wss/mTLS──▶ LNS
        (native, untouched)                127.0.0.1:1700      (this daemon)         lns.sa.thingpark.com
                                                                     │
                                              CUPS bootstrap ────────┘  (fetch tc.crt/tc.key/tc.uri)
```

It runs **on the gateway** (single static binary, cross-compiled for the
MT7620 `mipsle`/softfloat target) and is **gateway-agnostic**: point it at any
registered gateway by changing one value (`ROUTER_ID`) in its `.env`.

## How it works

1. **Credentials.** Reads cached/manually-provided `tc.*` from `TC_DIR`, else runs
   a **CUPS `/update-info` bootstrap** to fetch the LNS credentials the registered
   gateway is entitled to. ThingPark CUPS is server-auth-only — the registered
   router id is the identity — and typically provisions **only to the gateway
   itself**, which is why the bridge runs on-device.
2. **Uplink.** Receives `PUSH_DATA`/`rxpk` from the local packet forwarder,
   parses the PHYPayload, and forwards it as a BasicStation `updf`/`jreq`.
3. **Downlink.** Receives BasicStation `dnmsg`, renders it as a Semtech `txpk`
   (RX1 window via `xtime + RxDelay`, or immediate for class C), and returns it
   as `PULL_RESP`.

## Quick start

The mipsle binary is committed under `bin/`, so no build is required. Two ways
to install — both idempotent, both back up `global_conf.json` first.

### A. On the gateway (log in and run it)

```sh
wget -O /tmp/gwi.sh "https://github.com/sagatech-hardware/gateway_config/raw/main/Indoor%20Femto%20Gateway%20BasicStation/install/gateway-install.sh"
sh /tmp/gwi.sh
```

[`install/gateway-install.sh`](install/gateway-install.sh) runs entirely on the
device: it fetches the binary + init script, **derives `ROUTER_ID` from the
gateway MAC automatically** (`ROUTER_ID = 0016C0-<MAC>` — no `-e` to pass and
nothing to hand-edit), points `lora_pkt_fwd` at `127.0.0.1:1700`, installs the
service + watchdogs, and sets the **WAN from [`wan.env`](wan.env)**. Overrides:
`ROUTER_ID=`, `MAC_IFACE=`, `REGION=`, `CUPS_URI=` as env vars.

### B. From a dev box (push over SSH)

```bash
./install/install.sh -g 192.168.55.1 -e 0016C0-80029C4572D3
```

[`install/install.sh`](install/install.sh) pushes the binary, its `.env`, and
the init script over SSH (dropbear-safe) to `/mnt/data/pktfwd-station-bridge/`,
points `lora_pkt_fwd` at `127.0.0.1:1700`, adds a watchdog cron, and starts the
service. Here `ROUTER_ID` is passed explicitly with `-e`.

Verify either way:

```sh
logread | grep pktfwd                          # bridge → CUPS/LNS handshake
cat /mnt/data/pktfwd-station-bridge/.env | grep ROUTER_ID
crontab -l                                      # keep-alive + conn-check crons
```

## Configuration — `.env`

The bridge reads a **`.env` in the same directory as the binary** (see the
committed `.env`). Any key can be overridden by a process environment variable.

| key             | meaning                                                        |
| --------------- | ------------------------------------------------------------- |
| `ROUTER_ID`     | gateway identity on the LNS, e.g. `0016C0-80029C4572D3`        |
| `ROUTER_FORMAT` | `raw` (strip separators), `hex`, or `id6`                     |
| `CUPS_URI`      | CUPS endpoint (default ThingPark Enterprise SA)               |
| `TRUST_CA_PATH` | PEM to validate CUPS/LNS TLS; empty = system roots            |
| `LNS_URI`       | set to skip CUPS and dial this LNS directly with cached certs |
| `TC_DIR`        | where `tc.*` are cached / dropped manually                    |
| `UDP_LISTEN`    | address the local packet forwarder targets                    |
| `REGION`        | LoRaWAN region seeding the datr↔DR map: `US915`/`AU915`/`EU868` |

**Manual credentials.** If your LNS lets you download the gateway's
`tc.crt`/`tc.key`, drop them (plus `tc.trust`, `tc.uri`) into `TC_DIR` and the
bridge skips CUPS entirely.

**Auto `ROUTER_ID`.** With the on-gateway installer (A) you don't set
`ROUTER_ID` at all — it is `0016C0-<eth0 MAC>`, derived on the device. Override
the prefix with `ROUTER_PREFIX=` or pin the whole value with `ROUTER_ID=`.

## WAN — `wan.env`

Carrier / cellular settings live in [`wan.env`](wan.env) (a `.env`-style file),
kept **separate from the bridge `.env`**. The on-gateway installer applies it to
`/etc/config/network` via UCI, so the carrier is changed in one place — no
hand-editing `/etc/config/network`. It is read from `/etc/gemtek/wan.env` first
(put real SIM creds there to keep them out of git), then `./wan.env`, then the
repo copy.

## Connection watchdog

The installer adds two crons: a **keep-alive** (restart the bridge every minute
if it died) and [`check_no_connection_reboot.sh`](install/check_no_connection_reboot.sh)
every 30 min, which **reboots the gateway when the internet is unreachable** so a
stuck cellular link self-recovers. It gates on internet reachability, not the
bridge↔LNS link, so an LNS-side outage won't cause reboot loops.

## Build

```bash
make build        # cross-compile for the gateway (mipsle, softfloat, static) → bin/
make test vet     # host-side checks
```

## Status

- [x] `.env` config + CUPS `/update-info` client (bootstrap & credential parsing)
- [x] Semtech-UDP server (local packet-forwarder side)
- [x] BasicStation WebSocket client (`version` → `router_config`)
- [x] Uplink translation `rxpk` → `updf`/`jreq`
- [x] Downlink translation `dnmsg` → `txpk` (RX1 window / class C)
- [x] RX2-window fallback on RX1 miss (driven by TX_ACK)
- [ ] On-device validation against ThingPark (CUPS provisioning, LNS discovery, xtime timing)

## License

MIT — see [LICENSE](LICENSE).
