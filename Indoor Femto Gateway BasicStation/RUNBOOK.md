# RUNBOOK — Femto WLRGFM-100 (Gemtek/Browan) on ThingPark

Takes the femto from a reset/factory-ish state to **decoding uplinks on ThingPark**, and keeps it
that way across reboots. Two scripts do the work:

| Script | Runs on | Role |
|---|---|---|
| `femto-deploy.sh` | dev machine (**Linux or Windows**) | discovers the gateway + credentials, pushes the provisioner, polls the result |
| `femto-provision.sh` | the gateway (busybox `ash`) | CUPS config + Amazon Root CA 1 + the 1-byte station patch + `sync` + verify |
| `femto-firmware.sh` | the gateway (busybox `ash`) | is this BasicStation firmware? if not, flash `fw_pkt_*.tar.gz` the way the web UI would |
| `femto-fw-stage.sh` | dev machine (sourced by `femto-deploy.sh`) | pushes the 10 MB package, launches the flash detached, waits out the reboot |

Background: `docs/femto-provisioning.md` (layer map, why each step),
`docs/femto-station-eeprom-parse-bug.md` (how the binary patch was derived) and
`docs/femto-firmware-upgrade.md` (the reversed web-UI upgrade chain).
Installed and verified across a reboot on 2026-08-01.

## 1. Get the scripts

Repo folder: <https://github.com/sagatech-hardware/gateway_config/tree/main/Indoor%20Femto%20Gateway%20BasicStation>

All files must land in the **same directory** — `femto-deploy.sh` reads the other scripts, and
the firmware package, next to itself.

**Linux / macOS / Git Bash — just the scripts:**

```sh
mkdir -p femto && cd femto && for f in femto-deploy.sh femto-provision.sh femto-firmware.sh femto-fw-stage.sh; do
  curl -fsSL "https://raw.githubusercontent.com/sagatech-hardware/gateway_config/main/Indoor%20Femto%20Gateway%20BasicStation/$f" -o "$f"
done && chmod +x femto-*.sh
```

Add the firmware package too if any unit might still be on the 3.x packet-forwarder firmware
(10 MB; only read when an upgrade is actually needed):

```sh
curl -fsSLO "https://raw.githubusercontent.com/sagatech-hardware/gateway_config/main/Indoor%20Femto%20Gateway%20BasicStation/fw_pkt_4.00.19_9816ff6b.tar.gz"
```

**Whole folder (adds this runbook and the watchdog scripts):**

```sh
curl -fsSL https://codeload.github.com/sagatech-hardware/gateway_config/tar.gz/refs/heads/main \
  | tar xz --strip-components=2 --wildcards '*/Indoor Femto Gateway BasicStation/*'
```

**Git, for later `git pull` updates** (`core.autocrlf=false` keeps the shell scripts LF on Windows):

```sh
git clone --depth 1 --filter=blob:none --sparse --config core.autocrlf=false \
  https://github.com/sagatech-hardware/gateway_config.git
cd gateway_config && git sparse-checkout set 'Indoor Femto Gateway BasicStation'
```

**Windows PowerShell** (download only — run it from Git Bash or WSL):

```powershell
$b='https://raw.githubusercontent.com/sagatech-hardware/gateway_config/main/Indoor%20Femto%20Gateway%20BasicStation'
New-Item -ItemType Directory -Force femto | Out-Null
'femto-deploy.sh','femto-provision.sh','femto-firmware.sh','femto-fw-stage.sh' | % { Invoke-WebRequest "$b/$_" -OutFile "femto\$_" }
```

## 2. Requirements on the dev machine

| | Linux | Windows |
|---|---|---|
| shell | any POSIX shell + `bash` | **Git Bash**, MSYS2 or Cygwin (or run the Linux path under WSL) |
| network facts | `nmcli`, `ip` | `netsh`, `arp` (built in) |
| SSH password | `sshpass` (`apt install sshpass`) | `plink` (`winget install PuTTY.PuTTY`), or `sshpass` in MSYS2, or an OpenSSH client ≥ 8.4 (askpass) |

The wrapper picks whichever password tool exists and prints what it used; with none of them it exits
with the install hints above. `netsh` output is parsed by pattern (`AP-xxxxxx`, MAC regex), so a
localized Windows works.

**No credentials are configured anywhere.** The gateway is found at `192.168.55.1`, its MAC is read
off the link, and Browan's factory naming gives both the AP name and the root password from the
**last 6 MAC characters**: `80:02:9C:45:72:D3` → `AP-4572D3` / `browan@4572D3`. Every candidate is
confirmed by a real SSH login first (a 4-character suffix is tried as a fallback for units using the
shorter scheme). Firmware generations older than that scheme use the vendor default **`root` /
`root`**, which is tried **last** — only once every MAC-derived candidate has been refused, so a unit
that does follow the factory scheme never ends up authenticating on the weaker default. The line the
wrapper prints says which one was accepted (`legacy vendor default root password` for the old units).

The MAC is always looked up on the **AP side**, even when deploying over the LAN: on this unit the
`eth0.2` MAC is the base MAC **+1** and the AP's own BSSID is **+2**, so those sources give the wrong
suffix. When the machine is not associated with the AP, the `AP-*` names known to the OS are used
instead.

## 3. Preconditions

- **ThingPark** — base station registered as *Generic → Basics Station packet forwarder with CUPS*
  (`femto02`, ref `6798`, uuid `80029C-FFFE4572D3`, RF region LA 915MHz CH0-CH7) **with an LRC
  assigned**. With `lrcConfig` empty, CUPS answers every `/update-info` with `400` and nothing on the
  gateway can fix it.
- **Network** — join the gateway's Wi-Fi (default path):
  ```sh
  nmcli con up AP-4572D3          # Linux
  netsh wlan connect name=AP-4572D3   # Windows
  ```
  The LAN address `10.4.13.48` (eth0.2) also works when the femto holds a DHCP lease.

## 4. Provision

```sh
./femto-deploy.sh                        # 192.168.55.1, action install
./femto-deploy.sh 10.4.13.48 install     # same over the LAN
```

Idempotent — safe to re-run. Three guards run before anything is pushed: for a `192.168.55.*` host an
`AP-*` connection must be active, the host must answer a ping, and a derived password must be
accepted by SSH. Each failure exits non-zero and prints the fix without touching the gateway.

### 4a. Firmware stage (runs first, usually a no-op)

`install` begins by asking the gateway whether it runs BasicStation at all — `/bin/station` present
and `profile.system.fw_version` in the 4.x generation. A unit that already is reports
`no upgrade needed` in a second, nothing is uploaded, and provisioning continues.

A unit still on the 3.x packet-forwarder firmware cannot be provisioned at all (`femto-provision.sh`
preflights on `/opt/basicstation/station`), so the package is flashed first:
staged on `/mnt/data`, validated through the vendor's own CRC/magic/version gates, written to the
**inactive** firmware bank, then the box reboots into it and the run continues. Expect ~5-10 min,
most of it the 10 MB push through `cat >`. Run the check on its own with:

```sh
./femto-deploy.sh 10.4.13.48 firmware
```

The upgrade is A/B — the bank that was running is left intact as a fallback. Details and the
reversed web-UI chain: `docs/femto-firmware-upgrade.md`.

`install`, after the firmware stage, in order:

1. **Backup** every file it touches into `/mnt/data/femto-provision.bak` (mirrored tree, never
   overwritten → the first run preserves the pristine vendor state). `/mnt/data` is a separate
   partition and survives an overlay wipe.
2. **Stop BasicStation** — the binary cannot be patched while running.
3. **CUPS config** — `cups.uri` = `https://thingparkenterprise.sa.actility.com:443`,
   `cups.trust` = **Amazon Root CA 1**, `cups.crt`/`cups.key` truncated to 0 bytes (kept as
   `*.factory`). The factory trust is `O=TrackNet.io`, **expired 2024-11-06** — the cause of
   `X509 - Certificate verification failed`; ThingPark's CUPS chains to Amazon Root CA 1 and is
   **server-auth only**, so an empty client pair is correct.
4. **Reseed the other layers** — the same trust/uri/empty pair into
   `/mnt/data/bsStation/user_cups.*` and `/app/lora_pkg/cups-boot_def.*`, plus uci `bsConfig`. This
   is what makes a rebuilt `/opt/basicstation` come back **working** instead of factory (observed
   2026-08-01 03:07: the directory was recreated at boot and came back pointing at ThingPark with the
   Amazon trust, unattended).
5. **Patch the station binary** — offset `237679`, `0xA7 → 0xAF`, on **`/bin/station`** and
   `/opt/basicstation/station`. `/etc/init.d/boot` copies `/bin/station` over
   `/opt/basicstation/station` on **every** boot, so patching only `/opt` is undone at the next
   reboot. The byte is read back first: already-patched → skip, unexpected byte → abort.
6. **`sync`** — `/overlay` and `/mnt/data` are jffs2 and this box reboots often; unsynced writes have
   been lost before.
7. **Restart + verify.**

## 5. Verify

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

Checks are functional (process + socket on the `tc.uri` port + activity since the last `Station EUI`
line), not boot-banner greps — the station log truncates and rotates. `status` prints EUI, URIs, the
patch byte, the pid and the log tail. Healthy traffic:

```
[RAL:INFO] Concentrator started (3s…)
[S2E:INFO]   TX power: 30.0 dBm EIRP
[S2E:VERB] RX 916.6MHz DR0 SF12/BW125 snr=9.0 rssi=-53 - updf DevAddr=22075715 FCnt=470
```

## 6. Rollback

```sh
./femto-deploy.sh 192.168.55.1 rollback
```

Restores every file from `/mnt/data/femto-provision.bak` (including the unpatched `/bin/station`),
`sync`s and restarts. The gateway returns to vendor behaviour: CUPS/LNS fine, radio dying with
`SX1301 digital gain must be between 0 and 3. [12]`.

## 7. Recovery scenarios

| Situation | What to do |
|---|---|
| `/opt/basicstation` rebuilt at boot | nothing — the reseeded defaults and the `/bin/station` copy restore a working setup automatically; run `verify` to confirm |
| `verify` right after a reboot shows factory values | the overlay had not been mounted yet; wait ~1 min and re-run |
| **`tc.*` lost** → `verify` says `tc.uri absent`, log shows `(400) Bad Request` with `cupsCredCrc=989310313 tcCredCrc=2077607535` | ThingPark serves the credential **once**; regenerate it for the base station — portal *Advanced* tab, or `POST wireless/rest/partners/mine/bss/6798/regenerateCertificate` (→ 204) — then the next CUPS poll fills `tc.*`; run `install` afterwards so the fresh files get `sync`ed |
| Gateway unreachable on both addresses | it is rebooting; or the laptop roamed off the AP (`nmcli con up AP-4572D3`), or use IPv6 link-local `root@fe80::8202:9cff:fe45:72d3%<wlan-if>` |

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `not associated with a femto AP` | laptop drifted to another network; the script lists the `AP-*` SSIDs it can see |
| `no derived password ... accepted` | unit follows neither `browan@<last 6 MAC chars>` (nor the 4-char variant) nor the legacy `root`/`root` — check its label; the suffixes tried are printed |
| `need one of: sshpass, plink …` | install one (see §2) or run from WSL |
| `has an unexpected byte at 237679` | firmware differs from `4.00.19-opdk`; do **not** force — re-derive the offset per `docs/femto-station-eeprom-parse-bug.md` |
| `FAIL log has RAL:CRIT` right after install | an unpatched instance was started by cron between stop and patch; re-run `verify` after a minute (cron restarts it patched) |
| SSH session drops mid-install | expected — stopping the station kills it; the run continues detached and the wrapper polls `/tmp/femto-provision.log` |
| provisioner fails with `\r` errors | a CRLF checkout; the wrapper strips CRs when pushing, so re-clone with `core.autocrlf=false` if you edited it on Windows |

busybox on this gateway has no `timeout`, `nohup`, `setsid`, `od` or `scp` — both scripts avoid them
deliberately. Station log timestamps run **+3 h** ahead of the system clock on this unit.
