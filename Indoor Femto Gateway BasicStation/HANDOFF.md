# HANDOFF — pktfwd-station-bridge

Status of the **Indoor Femto Gateway BasicStation** deliverable and what's left.

## What this is

A Go daemon that lets a **Gemtek/Browan Indoor Femto (WLRGFM-100)** — which runs
the legacy Semtech-UDP `lora_pkt_fwd` and **cannot run LoRa Basics Station**
(its SX1301 is behind a proprietary `/dev/semtech0` driver, not `spidev`) — reach
a **BasicStation/CUPS LNS** (ThingPark). It sits between the native packet
forwarder and the LNS and translates the protocols, so **no firmware swap and no
HAL port** are needed. Runs on-device, cross-compiled static for MT7620
`mipsle`/softfloat.

## Architecture

```
 SX1301 ─(/dev/semtech0)─ lora_pkt_fwd ─Semtech UDP─▶ bridge ─wss/mTLS─▶ LNS (ThingPark)
        native, untouched              127.0.0.1:1700    │
                                        CUPS bootstrap ───┘ tc.crt/tc.key/tc.uri
```

Module map (`internal/`):

| pkg          | role                                                             |
| ------------ | --------------------------------------------------------------- |
| `config`     | loads `.env` (beside the binary) → `Config`; `ROUTER_ID`, `REGION`… |
| `cups`       | CUPS `/update-info` client: fetch + DER-parse tc.* creds; disk store |
| `udp`        | Semtech-UDP server (rxpk in, txpk out, ACKs, TX_ACK parse)      |
| `station`    | BasicStation WebSocket client (mTLS, `version`→`router_config`) |
| `translate`  | `rxpk`↔`updf/jreq`, `dnmsg`↔`txpk`; DR tables; xtime packing    |
| `bridge`     | wires it together; RX1→RX2 fallback via TX_ACK                  |
| `cmd/bridge` | entrypoint: load `.env` → obtain creds → run bridge            |

## Status

**Done** (builds, `go test` green, cross-compiles static):
- `.env` config incl. `REGION` (default **US915**).
- CUPS bootstrap client (POST `/update-info`, parse binary response → tc.*).
- Uplink: `rxpk` → `updf`/`jreq` (PHYPayload parse, DR mapping).
- Downlink: `dnmsg` → `txpk` (RX1 = xtime+RxDelay, class C = immediate).
- **RX1→RX2 fallback** driven by the forwarder's `TX_ACK`.
- `install.sh` (SSH deploy) + `bridge.init` (OpenWrt) + committed `bin/` binary.

**Not done — on-device validation only** (needs the gateway online, see below):
- Confirm CUPS actually provisions tc.* to this gateway.
- Confirm the LNS handshake (direct `tc.uri` vs router-info discovery).
- Confirm `xtime↔tmst` timing lands RX1/RX2.
- RX2 is a best-effort retry, not RX-window scheduled in one shot.

## Key facts (hard-won — don't re-derive)

| item            | value                                                          |
| --------------- | ------------------------------------------------------------- |
| Gateway         | `192.168.55.1` — its own Wi-Fi AP `AP-4572D3`; SSH `root`/`root` |
| Hardware        | MT7620 `mipsle`, OpenWrt Barrier Breaker 14.07, uClibc        |
| Radio           | SX1301 behind `/dev/semtech0` (`gmspi_module`) — no spidev    |
| LNS EUI         | `0016C0-80029C4572D3` (`ROUTER_FORMAT=raw`)                    |
| CUPS            | `https://thingparkenterprise.sa.actility.com:443`             |
| LNS             | `wss://lns.sa.thingpark.com:443`, mTLS `tc.*`                 |
| Region          | **US915**                                                     |
| SSH crypto      | dropbear needs legacy KEX/cipher opts (see `install.sh`)      |

**⚠️ CUPS off-device returns empty.** A `/update-info` POST from a dev machine
returns a 14-byte "nothing" response even for a known-registered EUI. ThingPark
appears to provision **only to the gateway itself**. So either the bridge must
bootstrap on-device, or drop `tc.crt`/`tc.key`/`tc.trust`/`tc.uri` into `TC_DIR`
manually (portal download) and it skips CUPS.

**⚠️ The femto has no WAN right now.** `ping lns.sa.thingpark.com` fails and DNS
resolves to `127.0.0.1`. The internal bridge can't reach ThingPark until the
gateway's uplink (Ethernet/cellular) is brought up.

## Build & deploy

```bash
make build                                       # → bin/pktfwd-station-bridge (mipsle, committed)
./install/install.sh -g 192.168.55.1 -e 0016C0-80029C4572D3 -r US915
```

`install.sh` pushes binary + `.env` + init to `/mnt/data/pktfwd-station-bridge/`,
points `lora_pkt_fwd` at `127.0.0.1:1700`, adds a watchdog cron, starts it. It is
idempotent and backs up `global_conf.json` first.

## On-device validation (the remaining work)

1. Bring the gateway's WAN up; confirm it can reach both hosts above.
2. `./install/install.sh …`, then `ssh root@192.168.55.1 logread -f | grep pktfwd`.
3. Expect: `CUPS bootstrap … router=…`, then `LNS = wss://lns.sa.thingpark.com`,
   `station: connected`, `station: router_config region=US915`, and `updf` as
   devices transmit. In ThingPark the base station should go online.
4. If CUPS returns no creds, download tc.* from the ThingPark base-station page
   into `TC_DIR` and restart.
5. If the LNS closes right after `version`, it likely wants the **router-info**
   discovery step first — add it to `internal/station`.
6. Watch downlinks: `bridge: downlink queued …`; if `TX_ACK error=TOO_LATE`,
   the RX2 retry fires — verify the device actually receives it.

## Open decisions / TODO

- Router-info discovery in `station.Dial` if ThingPark needs it.
- Verify `xtime` high-bit session scheme is accepted (currently `1<<48 | tmst`).
- `defaultTxPowerDBm=27` in `translate/downlink.go` — confirm vs the gateway's
  `tx_gain_lut`.
- Not committed yet (per owner). Folder is untracked in `gateway_config`.
