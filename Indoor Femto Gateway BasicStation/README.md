# Gateway scripts

Two independent tool sets live here:

| Set | Files | Target |
|---|---|---|
| **Femto provisioning** | `femto-provision.sh`, `femto-deploy.sh` | Gemtek/Browan WLRGFM-100 femto — full ThingPark chain (CUPS URI + Amazon Root CA 1 + server-auth creds + the 1-byte station patch), reboot-persistent. See [RUNBOOK.md](RUNBOOK.md). |
| **Connection watchdog** | `conn_watchdog.sh`, `manage_conn_watchdog.sh` | Browan WSMS-155 — reboot-on-LNS-loss self recovery (documented further down). |

# Femto WLRGFM-100 provisioning

Full operating procedure — download commands, Linux/Windows requirements, ThingPark
preconditions, `install`/`verify`/`rollback`, recovery scenarios and troubleshooting — lives in
**[RUNBOOK.md](RUNBOOK.md)**. Rationale and the binary-patch derivation are in
`docs/femto-provisioning.md` and `docs/femto-station-eeprom-parse-bug.md`.

Quick start (from this directory, with the machine on the gateway's Wi-Fi):

```sh
./femto-deploy.sh                     # 192.168.55.1, action install
./femto-deploy.sh 10.4.13.48 verify   # or over the LAN
```

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
