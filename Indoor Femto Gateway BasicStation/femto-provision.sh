#!/bin/sh
# femto-provision.sh — Gemtek/Browan WLRGFM-100 femto: make BasicStation reach
# ThingPark and bring the SX1301 up, permanently (survives reboot).
#
# Runs ON the gateway (busybox ash; no timeout/nohup/setsid/od available).
# Actions: install (default) | verify | rollback | status
# Prerequisites, rationale and the byte-patch derivation: docs/femto-provisioning.md
#
# Emits a final "PROVISION_RESULT=PASS|FAIL" line for callers to grep.

set -u
trap "" HUP INT

CUPS_URI="https://thingparkenterprise.sa.actility.com:443"
BS_DIR="/opt/basicstation"
DEF_DIR="/app/lora_pkg"
USR_DIR="/mnt/data/bsStation"
BKP_DIR="/mnt/data/femto-provision.bak"
STATION_SRC="/bin/station"
LOG="/tmp/station.log"

PATCH_OFF=237679
MD5_BYTE_VENDOR="6b2b98fea11e51af3043b192f719bd69"
MD5_BYTE_FIXED="00d9712ec5eb70807a73b8d2d6ead90d"
MD5_TRUST_PEM="7095142f080d1d25221eec161ff14223"

say() { echo "[provision] $*"; }
die() { echo "[provision] ERROR: $*"; echo "PROVISION_RESULT=FAIL"; exit 1; }

write_amazon_root_ca1() {
	cat > "$1" <<'PEM'
-----BEGIN CERTIFICATE-----
MIIDQTCCAimgAwIBAgITBmyfz5m/jAo54vB4ikPmljZbyjANBgkqhkiG9w0BAQsF
ADA5MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6
b24gUm9vdCBDQSAxMB4XDTE1MDUyNjAwMDAwMFoXDTM4MDExNzAwMDAwMFowOTEL
MAkGA1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJv
b3QgQ0EgMTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALJ4gHHKeNXj
ca9HgFB0fW7Y14h29Jlo91ghYPl0hAEvrAIthtOgQ3pOsqTQNroBvo3bSMgHFzZM
9O6II8c+6zf1tRn4SWiw3te5djgdYZ6k/oI2peVKVuRF4fn9tBb6dNqcmzU5L/qw
IFAGbHrQgLKm+a/sRxmPUDgH3KKHOVj4utWp+UhnMJbulHheb4mjUcAwhmahRWa6
VOujw5H5SNz/0egwLX0tdHA114gk957EWW67c4cX8jJGKLhD+rcdqsq08p8kDi1L
93FcXmn/6pUCyziKrlA4b9v7LWIbxcceVOF34GfID5yHI9Y/QCB/IIDEgEw+OyQm
jgSubJrIqg0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC
AYYwHQYDVR0OBBYEFIQYzIU07LwMlJQuCFmcx7IQTgoIMA0GCSqGSIb3DQEBCwUA
A4IBAQCY8jdaQZChGsV2USggNiMOruYou6r4lK5IpDB/G/wkjUu0yKGX9rbxenDI
U5PMCCjjmCXPI6T53iHTfIUJrU6adTrCC2qJeHZERxhlbI1Bjjt/msv0tadQ1wUs
N+gDS63pYaACbvXy8MWy7Vu33PqUXHeeE6V/Uq2V8viTO96LXFvKWlJbYK8U90vv
o/ufQJVtMVT8QtPHRh8jrdkPSHCa2XV4cdFyQzR1bldZwgJcJmApzyMZFo6IQ6XU
5MsI+yMRQ+hDKXJioaldXgjUkK642M4UwtBV8ob2xJNDd2ZhwLnoQdeXeGADbkpy
rqXRfboQnoZsG4q5WTP468SQvvG5
-----END CERTIFICATE-----
PEM
}

md5_of() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

patch_byte_state() {
	dd if="$1" bs=1 skip=$PATCH_OFF count=1 2>/dev/null | md5sum | cut -d' ' -f1
}

backup_once() {
	[ -e "$1" ] || return 0
	dst="$BKP_DIR$1"
	[ -e "$dst" ] && return 0
	mkdir -p "$(dirname "$dst")"
	cp -p "$1" "$dst"
}

patch_station() {
	f="$1"
	[ -f "$f" ] || die "$f not found"
	case "$(patch_byte_state "$f")" in
	"$MD5_BYTE_FIXED")  say "$f already patched" ;;
	"$MD5_BYTE_VENDOR")
		printf '\257' | dd of="$f" bs=1 seek=$PATCH_OFF conv=notrunc 2>/dev/null
		[ "$(patch_byte_state "$f")" = "$MD5_BYTE_FIXED" ] || die "patch of $f did not take"
		say "$f patched (offset $PATCH_OFF: 0xA7 -> 0xAF)"
		;;
	*) die "$f has an unexpected byte at $PATCH_OFF — firmware differs, refusing to patch" ;;
	esac
}

stop_station() {
	/etc/init.d/station.service stop >/dev/null 2>&1
	killall station >/dev/null 2>&1
	sleep 1
}

install_cups_config() {
	write_amazon_root_ca1 "$BS_DIR/cups.trust"
	printf '%s' "$CUPS_URI" > "$BS_DIR/cups.uri"
	for p in crt key; do
		[ -s "$BS_DIR/cups.$p" ] && cp -p "$BS_DIR/cups.$p" "$BS_DIR/cups.$p.factory"
		: > "$BS_DIR/cups.$p"
	done
	say "CUPS set: server-auth only, trust=Amazon Root CA 1, uri=$CUPS_URI"

	mkdir -p "$USR_DIR"
	write_amazon_root_ca1 "$USR_DIR/user_cups.trust"
	: > "$USR_DIR/user_cups.crt"
	: > "$USR_DIR/user_cups.key"

	write_amazon_root_ca1 "$DEF_DIR/cups-boot_def.trust"
	printf '%s' "$CUPS_URI" > "$DEF_DIR/cups-boot_def.uri"
	: > "$DEF_DIR/cups-boot_def.crt"
	: > "$DEF_DIR/cups-boot_def.key"
	say "first-boot defaults reseeded (survive a /opt/basicstation wipe)"

	if command -v uci >/dev/null 2>&1; then
		uci set bsConfig.config.mode='cups'
		uci set bsConfig.config.protocol='https'
		uci set bsConfig.config.type='regular'
		uci set bsConfig.config.srvAddress='thingparkenterprise.sa.actility.com'
		uci set bsConfig.config.srvPort='443'
		uci set bsConfig.config.srvUri="$CUPS_URI"
		uci commit bsConfig
		say "uci bsConfig aligned"
	fi
}

lns_port() { sed 's/.*://' "$BS_DIR/tc.uri" 2>/dev/null; }

lns_peer() {
	p=$(lns_port)
	[ -n "$p" ] || return 1
	netstat -ant 2>/dev/null | grep ESTABLISHED | grep ":$p" | awk '{print $5}' | head -1
}

log_since_start() {
	[ -f "$LOG" ] || return 1
	first=$(grep -n "Station EUI" "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
	total=$(wc -l < "$LOG")
	[ -n "$first" ] || first=1
	tail -n $((total - first + 1)) "$LOG"
}

radio_up() {
	log_since_start 2>/dev/null | grep -qE "Concentrator started|SYN:INFO|S2E:VERB|RAL:DEBU"
}

wait_for_radio() {
	i=0
	while [ $i -lt 45 ]; do
		radio_up && [ -n "$(lns_peer)" ] && return 0
		sleep 2
		i=$((i + 1))
	done
	return 1
}

restart_station() {
	stop_station
	/etc/init.d/station.service start >/dev/null 2>&1
	sleep 4
	pidof station >/dev/null 2>&1 && return 0
	/etc/init.d/station.service start >/dev/null 2>&1
	sleep 4
}

install() {
	[ -f "$BS_DIR/station" ] || die "$BS_DIR/station missing — not a BasicStation femto"
	[ -c /dev/semtech0 ] || die "/dev/semtech0 missing — wrong hardware"
	mkdir -p "$BKP_DIR" || die "cannot create $BKP_DIR"

	for f in "$STATION_SRC" "$BS_DIR/station" "$BS_DIR/cups.uri" "$BS_DIR/cups.trust" \
		"$BS_DIR/cups.crt" "$BS_DIR/cups.key" "$USR_DIR/user_cups.trust" \
		"$USR_DIR/user_cups.crt" "$USR_DIR/user_cups.key" \
		"$DEF_DIR/cups-boot_def.trust" "$DEF_DIR/cups-boot_def.uri" \
		"$DEF_DIR/cups-boot_def.crt" "$DEF_DIR/cups-boot_def.key"; do
		backup_once "$f"
	done
	say "backups in $BKP_DIR"

	stop_station
	install_cups_config
	patch_station "$STATION_SRC"
	cp -p "$STATION_SRC" "$BS_DIR/station"
	patch_station "$BS_DIR/station"

	sync
	say "sync done (jffs2 overlay — writes are now on flash)"

	restart_station
	say "station restarted, waiting for radio + LNS"
	wait_for_radio || say "WARN: radio/LNS not confirmed within 90s"
	verify
}

check() {
	if [ "$2" = "$3" ]; then
		say "OK   $1"
		return 0
	fi
	say "FAIL $1 (got '$2', want '$3')"
	return 1
}

verify() {
	rc=0
	check "$STATION_SRC patched" "$(patch_byte_state $STATION_SRC)" "$MD5_BYTE_FIXED" || rc=1
	check "$BS_DIR/station patched" "$(patch_byte_state $BS_DIR/station)" "$MD5_BYTE_FIXED" || rc=1
	check "cups.uri" "$(cat $BS_DIR/cups.uri 2>/dev/null)" "$CUPS_URI" || rc=1
	check "cups.trust = Amazon Root CA 1" "$(md5_of $BS_DIR/cups.trust)" "$MD5_TRUST_PEM" || rc=1
	check "cups.crt empty (server auth)" "$(wc -c < $BS_DIR/cups.crt 2>/dev/null | tr -d ' ')" "0" || rc=1
	check "default trust reseeded" "$(md5_of $DEF_DIR/cups-boot_def.trust)" "$MD5_TRUST_PEM" || rc=1

	if [ -s "$BS_DIR/tc.uri" ]; then
		say "OK   tc.uri served by CUPS: $(cat $BS_DIR/tc.uri)"
	else
		say "FAIL tc.uri absent — CUPS did not serve credentials (LRC assigned in ThingPark?)"
		rc=1
	fi
	if pidof station >/dev/null 2>&1; then
		say "OK   station running (pid $(pidof station))"
	else
		say "FAIL station not running"
		rc=1
	fi
	peer=$(lns_peer)
	if [ -n "$peer" ]; then
		say "OK   LNS session established with $peer"
	else
		say "FAIL no ESTABLISHED session to the LNS"
		rc=1
	fi
	if radio_up; then
		say "OK   radio active (concentrator/timesync/RX traffic since last start)"
	else
		say "FAIL no radio activity since the last station start"
		rc=1
	fi
	for m in "RAL:CRIT" "RAL:ERRO"; do
		if log_since_start 2>/dev/null | grep -q "$m"; then
			say "FAIL log has $m since the last start"
			rc=1
		fi
	done

	[ $rc -eq 0 ] && echo "PROVISION_RESULT=PASS" || echo "PROVISION_RESULT=FAIL"
	return $rc
}

rollback() {
	[ -d "$BKP_DIR" ] || die "no backup dir $BKP_DIR"
	stop_station
	find "$BKP_DIR" -type f | while read -r src; do
		orig=${src#$BKP_DIR}
		cp -p "$src" "$orig" && say "restored $orig"
	done
	sync
	/etc/init.d/station.service start >/dev/null 2>&1
	say "rollback done"
	echo "PROVISION_RESULT=PASS"
}

status() {
	say "station EUI:  $(grep -m1 'Station EUI' $LOG 2>/dev/null | sed 's/.*: //')"
	say "cups.uri:     $(cat $BS_DIR/cups.uri 2>/dev/null)"
	say "tc.uri:       $(cat $BS_DIR/tc.uri 2>/dev/null)"
	say "binary byte:  $(patch_byte_state $BS_DIR/station) (fixed=$MD5_BYTE_FIXED)"
	say "pid:          $(pidof station 2>/dev/null)"
	tail -5 "$LOG" 2>/dev/null
}

case "${1:-install}" in
install) install ;;
verify) verify ;;
rollback) rollback ;;
status) status ;;
*) echo "usage: $0 {install|verify|rollback|status}"; exit 2 ;;
esac
