# Gateway scripts

Two independent tool sets live here:

| Set | Files | Target |
|---|---|---|
| **Femto provisioning** | `femto-provision.sh`, `femto-deploy.sh` | Gemtek/Browan WLRGFM-100 femto — full ThingPark chain (CUPS URI + Amazon Root CA 1 + server-auth creds + the 1-byte station patch), reboot-persistent. Runbook below. |
| **Connection watchdog** | `conn_watchdog.sh`, `manage_conn_watchdog.sh` | Browan WSMS-155 — reboot-on-LNS-loss self recovery (documented further down). |

# RUNBOOK — Femto WLRGFM-100 provisioning

Brings the femto from "reset / factory-ish" to **decoding uplinks on ThingPark**, permanently.
Deep background: `docs/femto-provisioning.md` (layer map, why each step) and
`docs/femto-station-eeprom-parse-bug.md` (how the binary patch was derived).
Installed and verified across a full reboot on 2026-08-01.

## 0. Preconditions

- **ThingPark side** — base station registered as *Generic → Basics Station packet forwarder with
  CUPS* (`femto02`, ref `6798`, uuid `80029C-FFFE4572D3`, RF region LA 915MHz CH0-CH7) **and an LRC
  assigned to it**. Without an LRC, CUPS answers every `/update-info` with `400` and no gateway-side
  change can fix it.
- **Dev box** — `sshpass` and `nmcli`. **No credentials to configure**: the script finds the gateway
  at `192.168.55.1`, reads its MAC off the link and derives Browan's factory naming from the last 6
  characters — AP `AP-<suffix>`, root password `browan@<suffix>` (e.g. MAC `80:02:9C:45:72:D3` →
  `AP-4572D3` / `browan@4572D3`). Each candidate is confirmed with a real SSH login before use, and
  a 4-character suffix is tried as a fallback for units that use the shorter scheme.
- **Network** — join the gateway's own Wi-Fi, which is the default path:
  ```sh
  nmcli con up AP-4572D3
  ```
  The LAN address `10.4.13.48` (eth0.2) works too when the femto has a DHCP lease — the MAC is still
  discovered over the AP, because the eth0.2 MAC is offset by one from the base MAC (and the AP's own
  BSSID by two), so only the AP-side ARP entry yields the correct suffix.

## 1. Provision

```sh
./femto-deploy.sh                        # host 192.168.55.1, action install
./femto-deploy.sh 10.4.13.48 install     # same over the LAN
```

Idempotent — safe to re-run. Three guards run before anything is pushed: the `192.168.55.*` path
requires an `AP-*` connection to be active in `nmcli`, the host must answer a ping, and a derived
password must be accepted by an SSH login. Every failure exits non-zero and prints the fix without
touching the gateway.

What `install` does, in order: backup every file it will touch into
`/mnt/data/femto-provision.bak` (never overwritten → first run keeps the pristine vendor state) →
stop BasicStation → write `cups.uri` + **Amazon Root CA 1** `cups.trust` + zero-length
`cups.crt`/`cups.key` (ThingPark CUPS is server-auth only; the factory TrackNet trust expired
2024-11-06) → reseed the same into `/mnt/data/bsStation/user_cups.*`, `/app/lora_pkg/cups-boot_def.*`
and uci `bsConfig` → patch **`/bin/station`** and `/opt/basicstation/station` (offset `237679`,
`0xA7`→`0xAF`) → `sync` → restart and verify.

`/bin/station` is the one that matters: `/etc/init.d/boot` copies it over
`/opt/basicstation/station` on **every** boot, so patching only `/opt` is undone at the next reboot.

## 2. Verify

```sh
./femto-deploy.sh 192.168.55.1 verify
```

```
OK   /bin/station patched
OK   /opt/basicstation/station patched
OK   cups.uri
OK   cups.trust = Amazon Root CA 1
OK   cups.crt empty (server auth)
OK   default trust reseeded
OK   tc.uri served by CUPS: wss://lns.sa.thingpark.com:443
OK   station running (pid …)
OK   LNS session established with 54.207.14.41:443
OK   radio active (concentrator/timesync/RX traffic since last start)
PROVISION_RESULT=PASS
```

Checks are functional (process + socket on the `tc.uri` port + activity since the last
`Station EUI` line), not boot-banner greps — the station log truncates and rotates.

`./femto-deploy.sh 192.168.55.1 status` prints EUI, URIs, the patch byte, the pid and the tail of
`/tmp/station.log`. Healthy traffic looks like:

```
[S2E:VERB] RX 916.6MHz DR0 SF12/BW125 snr=9.0 rssi=-53 - updf DevAddr=22075715 FCnt=470
```

## 3. Rollback

```sh
./femto-deploy.sh 192.168.55.1 rollback
```

Restores every file from `/mnt/data/femto-provision.bak` (including the unpatched `/bin/station`),
`sync`s, restarts. The gateway returns to vendor behaviour: CUPS/LNS fine, radio dying with
`SX1301 digital gain must be between 0 and 3. [12]`.

## 4. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `not associated with a femto AP` | laptop drifted to another network → the script lists the `AP-*` SSIDs it can see; `nmcli con up AP-4572D3`, or use `10.4.13.48` |
| `no derived password accepted` | the unit does not follow `browan@<last 6 MAC chars>` (nor the 4-char variant) → check its factory label; the MACs tried are printed |
| `192.168.55.1 unreachable` while associated | gateway rebooting; retry, or reach it over IPv6 link-local `root@fe80::8202:9cff:fe45:72d3%<wlan-if>` |
| `FAIL tc.uri absent` | ThingPark did not serve credentials → check the **LRC assignment** on `femto02` |
| `FAIL log has RAL:CRIT` right after install | an unpatched instance was started by cron between stop and patch; re-run `verify` after a minute (cron restarts it patched) |
| `has an unexpected byte at 237679` | firmware differs from `4.00.19-opdk`; do **not** force — re-derive the offset per `docs/femto-station-eeprom-parse-bug.md` |
| SSH session drops mid-install | expected (stopping the station kills it); the run continues detached and the wrapper polls `/tmp/femto-provision.log` |

busybox on this gateway has no `timeout`, `nohup`, `setsid`, `od` or `scp` — the scripts avoid all of
them deliberately.

# Gateway connection watchdog

Self-recovery for the Browan WSMS-155 (`10.4.13.25`): if the BasicStation link
to the LNS drops, the gateway **reboots**, and keeps rebooting on a ~15 min
cadence until the link is back. Recovery is automatic — no "un-do" step: the
watchdog is stateless, so once connected again its runs are no-ops and the
gateway just operates normally.

## Files

| File | Role |
|---|---|
| `conn_watchdog.sh` | the check: station up + ESTABLISHED TCP to LNS port? no → `reboot`. Runs from crond every 15 min. |
| `manage_conn_watchdog.sh` | `install` / `remove` / `status` — deploys the script, the cron entry, and a boot hook. |

## Behavior

- **Connected?** `pidof station` alive **and** a non-loopback `ESTABLISHED` TCP
  session to the LNS port (parsed from `/app/basicstation/tc.uri`, default 443).
  Reflects station's own live socket, so a pure LNS drop (internet still up) is
  caught, not just network reachability.
- **Post-boot grace (600 s):** never reboots within 10 min of boot, so station
  gets time to reconnect after each boot — prevents a fast reboot loop.
- **Blip tolerance:** 3 re-checks 10 s apart before a reboot is taken.
- **Cadence while down:** crond `*/15` + grace ⇒ a reboot roughly every 15–30 min
  until the LNS returns.

Tune the knobs at the top of `conn_watchdog.sh` (`GRACE_SECS`, `CHECKS`,
`CHECK_GAP`). Log: `/app/log/lora/conn_watchdog.log` (capped 64 KiB, survives
reboot — `/app` is persistent).

## Install (run from the dev box)

Dropbear on the gateway has **no scp**, so push each file with `cat`:

```sh
GW=root@10.4.13.25
ssh $GW 'mkdir -p /app/gwscripts'
ssh $GW 'cat > /app/gwscripts/conn_watchdog.sh'        < conn_watchdog.sh
ssh $GW 'cat > /app/gwscripts/manage_conn_watchdog.sh' < manage_conn_watchdog.sh
ssh $GW 'sh /app/gwscripts/manage_conn_watchdog.sh install'
```

`install` prints a `status` block. Confirm: `script present`, `cron entry
present`, `crond running`, `boot hook present`.

## Verify / operate

```sh
ssh $GW 'sh /app/gwscripts/manage_conn_watchdog.sh status'   # state + last log lines
ssh $GW 'sh /app/conn_watchdog.sh'                           # force one check now
ssh $GW 'sh /app/gwscripts/manage_conn_watchdog.sh remove'   # stop + uninstall
```

## Not yet verified live

Syntax is checked against busybox `ash` (the gateway's shell) and the port
parser + `ESTABLISHED` detection are unit-tested locally. **The install path
and an actual reboot-on-loss have not been run on the gateway yet** — do the
first install while you can reach the unit out-of-band, and watch one cycle.

## Caveats

- A reboot won't fix an **LNS-side** outage (ThingPark down): the gateway will
  reboot every ~15 min until ThingPark returns. Add an internet-reachability
  guard, or a max-reboots cap, if that's unwanted.
- Boot persistence rides on `/etc/rc.local` running at boot (OpenWrt-style).
  `status` after a real reboot is the proof it held.
