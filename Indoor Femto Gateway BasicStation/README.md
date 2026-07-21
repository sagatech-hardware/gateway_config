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
3. **Downlink.** Receives BasicStation `dnmsg`, renders it as a Semtech `txpk`,
   and returns it as `PULL_RESP` *(next release)*.

## Quick start

The mipsle binary is committed under `bin/`, so no build is required:

```bash
./install/install.sh -g 192.168.55.1 -e 0016C0-80029C4572D3
```

`install.sh` pushes the binary, its `.env`, and the init script over SSH
(dropbear-safe) to `/mnt/data/pktfwd-station-bridge/`, points `lora_pkt_fwd` at
`127.0.0.1:1700`, adds a watchdog cron, and starts the service. It is idempotent
and backs up `global_conf.json` first.

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

**Manual credentials.** If your LNS lets you download the gateway's
`tc.crt`/`tc.key`, drop them (plus `tc.trust`, `tc.uri`) into `TC_DIR` and the
bridge skips CUPS entirely.

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
- [ ] Downlink translation `dnmsg` → `txpk` (RX1/RX2 timing)
- [ ] On-device validation against ThingPark (CUPS provisioning, LNS discovery)

## License

MIT — see [LICENSE](LICENSE).
