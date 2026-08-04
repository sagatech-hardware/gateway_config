#!/usr/bin/env bash
# femto-deploy.sh — push femto-provision.sh to the femto over SSH and run it.
#
# Runs on Linux and on Windows (Git Bash / MSYS2 / Cygwin): network facts come from
# nmcli+ip or from netsh+arp, and the SSH password is fed by sshpass, plink or
# OpenSSH's askpass — whichever the machine has.
#
# No credentials are configured: the gateway is discovered at its AP address, its
# MAC is read off the link, and Browan's factory naming derives both the AP name
# (AP-<last 6 MAC chars>) and the root password (browan@<last 6 MAC chars>).
# Older firmware generations predate that scheme and use root/root — tried as a
# last resort, after every MAC-derived candidate has been refused.
#
# dropbear on the gateway has no scp/sftp, so the script is streamed through
# `cat >`. Provisioning stops BasicStation, which sometimes drops the SSH session,
# so the run is detached and this wrapper polls its log.
#
# usage: ./femto-deploy.sh [host] [install|verify|rollback|status]

set -uo pipefail

DISCOVER_IP="192.168.55.1"
ACTION="${2:-install}"
HOST="${1:-$DISCOVER_IP}"
SRC="$(dirname "$0")/femto-provision.sh"
REMOTE="/tmp/femto-provision.sh"
RLOG="/tmp/femto-provision.log"
FWSRC="$(dirname "$0")/femto-firmware.sh"
STAGESRC="$(dirname "$0")/femto-fw-stage.sh"
FWREMOTE="/tmp/femto-firmware.sh"
FWTAR="$(dirname "$0")/fw_pkt_4.00.19_9816ff6b.tar.gz"
FWLOG="/tmp/femto-firmware.log"
LEGACY_PASS="root"
POLL_TRIES=40
POLL_SLEEP=5
BOOT_TRIES=60
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

case "$(uname -s 2> /dev/null)" in
MINGW* | MSYS* | CYGWIN*) OS=win ;;
*) OS=nix ;;
esac

# ---------- platform facts ----------

ping_host() {
	if [ "$OS" = win ]; then
		ping -n 1 -w 2000 "$1" > /dev/null 2>&1
	else
		ping -c 1 -W 2 "$1" > /dev/null 2>&1
	fi
}

mac_norm() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr '-' ':'; }

wifi_dev() { nmcli -t -f DEVICE,TYPE dev status 2> /dev/null | sed -n 's/:wifi$//p' | head -1; }

# MAC of a neighbour, preferring the wireless interface (see suffix_candidates).
neigh_mac() {
	ping_host "$1"
	if [ "$OS" = win ]; then
		arp -a "$1" 2> /dev/null |
			grep -oiE '([0-9a-f]{2}-){5}[0-9a-f]{2}' | head -1 | tr '-' ':'
	else
		ip neigh show "$1" ${2:+dev "$2"} 2> /dev/null |
			awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i + 1)}' | head -1
	fi
}

# Names are matched by pattern, not by label, so localized netsh output still works.
active_ap() {
	if [ "$OS" = win ]; then
		netsh wlan show interfaces 2> /dev/null | grep -oiE 'AP-[0-9A-F]{6}' | head -1
	else
		nmcli -t -f NAME con show --active 2> /dev/null | grep -m1 '^AP-'
	fi
}

known_aps() {
	if [ "$OS" = win ]; then
		{
			netsh wlan show profiles 2> /dev/null
			netsh wlan show networks 2> /dev/null
		} | grep -oiE 'AP-[0-9A-F]{6}'
	else
		{
			nmcli -t -f NAME con show 2> /dev/null
			nmcli -t -f SSID dev wifi list 2> /dev/null
		} | grep -E '^AP-'
	fi
}

active_bssid() {
	if [ "$OS" = win ]; then
		netsh wlan show interfaces 2> /dev/null |
			grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1
	else
		nmcli -t -f ACTIVE,BSSID dev wifi list 2> /dev/null | sed -n 's/^yes://p' | tr -d '\\'
	fi
}

# ---------- password-authenticated ssh ----------

ASKPASS_FILE=""
cleanup() { [ -n "$ASKPASS_FILE" ] && rm -f "$ASKPASS_FILE"; }
trap cleanup EXIT

PW_TOOL=""
pick_pw_tool() {
	if command -v sshpass > /dev/null 2>&1; then
		PW_TOOL=sshpass
	elif command -v plink > /dev/null 2>&1 || command -v plink.exe > /dev/null 2>&1; then
		PW_TOOL=plink
	elif command -v ssh > /dev/null 2>&1; then
		PW_TOOL=askpass
	fi
}

write_askpass() {
	if [ "$OS" = win ]; then
		ASKPASS_FILE="$(mktemp -u)".bat
		printf '@echo off\r\necho %s\r\n' "$1" > "$ASKPASS_FILE"
	else
		ASKPASS_FILE="$(mktemp)"
		printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "'$1'" > "$ASKPASS_FILE"
	fi
	chmod 700 "$ASKPASS_FILE"
}

# Runs a command as root on $HOST with $1 as the password; stdin is passed through.
ssh_pw() {
	pass="$1"
	shift
	case "$PW_TOOL" in
	sshpass) sshpass -p "$pass" ssh $SSH_OPTS "root@$HOST" "$@" ;;
	plink) plink -ssh -batch -pw "$pass" "root@$HOST" "$@" ;;
	askpass)
		write_askpass "$pass"
		SSH_ASKPASS="$ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
			ssh -o BatchMode=no $SSH_OPTS "root@$HOST" "$@"
		;;
	*) return 127 ;;
	esac
}

ssh_femto() { ssh_pw "$PASS" "$@"; }

ssh_try() {
	# plink refuses unknown host keys in batch mode; cache the key once.
	[ "$PW_TOOL" = plink ] && printf 'y\n' | plink -ssh -pw "$1" "root@$HOST" exit > /dev/null 2>&1
	ssh_pw "$1" true > /dev/null 2>&1
}

# ---------- discovery ----------

mac_suffix() {
	s=$(mac_norm "$1")
	s=${s//:/}
	s=${s^^}
	echo "${s: -6}"
}

# Best source first: the ARP entry for the AP address on the wireless interface is
# the gateway's base MAC, which is what the factory naming uses. The other MACs on
# this box are offset from it (eth0.2 +1, the AP's own BSSID +2), and the AP names
# the OS knows carry the right suffix — all are candidates, each confirmed by an
# actual SSH login below.
suffix_candidates() {
	m=$(neigh_mac "$DISCOVER_IP" "$(wifi_dev)") && [ -n "$m" ] && mac_suffix "$m"
	active_ap | sed 's/^[Aa][Pp]-//'
	m=$(neigh_mac "$DISCOVER_IP") && [ -n "$m" ] && mac_suffix "$m"
	if [ "$HOST" != "$DISCOVER_IP" ]; then
		m=$(neigh_mac "$HOST") && [ -n "$m" ] && mac_suffix "$m"
	fi
	known_aps | sed 's/^[Aa][Pp]-//'
	m=$(active_bssid) && [ -n "$m" ] && mac_suffix "$m"
}

# ---------- main ----------

[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }
[ -f "$FWSRC" ] || { echo "missing $FWSRC"; exit 1; }
[ -f "$STAGESRC" ] || { echo "missing $STAGESRC"; exit 1; }
. "$STAGESRC"
pick_pw_tool
[ -n "$PW_TOOL" ] || {
	echo "need one of: sshpass, plink (PuTTY), or an OpenSSH client >= 8.4"
	echo "  Linux:   apt install sshpass"
	echo "  Windows: winget install PuTTY.PuTTY   (or run this from WSL)"
	exit 1
}

case "$ACTION" in
install | verify | rollback | status | firmware) ;;
*) echo "usage: $0 [host] [install|verify|rollback|status|firmware]"; exit 2 ;;
esac

# The AP address only exists over the gateway's own Wi-Fi, and laptops drift back
# to other networks — which makes the femto look dead.
case "$HOST" in
192.168.55.*)
	AP_ACTIVE=$(active_ap)
	if [ -z "$AP_ACTIVE" ]; then
		echo "not associated with a femto AP — connect to its Wi-Fi first:"
		known_aps | sort -u | sed 's/^/  /'
		echo "(or pass the LAN address: $0 10.4.13.48 $ACTION)"
		exit 1
	fi
	echo "-- Wi-Fi '$AP_ACTIVE' active"
	;;
esac

ping_host "$HOST" || { echo "$HOST unreachable"; exit 1; }

CANDS=$(suffix_candidates | tr '[:lower:]' '[:upper:]' | awk 'NF && !seen[$0]++')
[ -n "$CANDS" ] || {
	echo "no MAC or AP name found for $DISCOVER_IP — is this box on the gateway's Wi-Fi?"
	exit 1
}

PASS=""
for suf in $CANDS; do
	for cand in "browan@$suf" "browan@${suf: -4}"; do
		if ssh_try "$cand"; then
			PASS="$cand"
			AP="AP-$suf"
			break 2
		fi
	done
done

# Older firmware generations ship the vendor default root/root instead of the
# MAC-derived password. Tried only after every derived candidate has failed, so a
# unit that follows the factory scheme never authenticates on the weaker default.
if [ -z "$PASS" ] && ssh_try "$LEGACY_PASS"; then
	PASS="$LEGACY_PASS"
	# No suffix was accepted, so the AP name cannot be derived from the password;
	# wait_reboot needs one to re-associate, hence the live SSID then first candidate.
	AP="$(active_ap)"
	AP="${AP:-AP-$(echo "$CANDS" | head -1)}"
fi

[ -n "$PASS" ] || {
	echo "suffixes tried: $(echo "$CANDS" | tr '\n' ' ')"
	echo "no derived password (nor the legacy root/root default) accepted by root@$HOST"
	echo "— check the unit's factory scheme"
	echo "(expected AP-<last 6 MAC chars> / browan@<last 6 MAC chars>)"
	exit 1
}
if [ "$PASS" = "$LEGACY_PASS" ]; then
	echo "-- $AP via $PW_TOOL, legacy vendor default root password (older firmware)"
else
	echo "-- $AP via $PW_TOOL, root password derived from MAC suffix ${PASS#browan@}"
fi

echo "== femto $HOST: $ACTION =="
# tr strips CRs so a Windows checkout of the script still parses in busybox ash.
tr -d '\r' < "$SRC" | ssh_femto "cat > $REMOTE && chmod +x $REMOTE" || {
	echo "push failed"
	exit 1
}
tr -d '\r' < "$FWSRC" | ssh_femto "cat > $FWREMOTE" || {
	echo "push failed"
	exit 1
}

case "$ACTION" in
firmware)
	firmware_stage
	exit $?
	;;
install)
	firmware_stage || exit 1
	;;
esac

if [ "$ACTION" = verify ] || [ "$ACTION" = status ]; then
	ssh_femto "sh $REMOTE $ACTION"
	exit $?
fi

ssh_femto "rm -f $RLOG; sh $REMOTE $ACTION > $RLOG 2>&1 &" || true

for _ in $(seq "$POLL_TRIES"); do
	sleep "$POLL_SLEEP"
	OUT="$(ssh_femto "cat $RLOG 2>/dev/null" || true)"
	if echo "$OUT" | grep -q "PROVISION_RESULT="; then
		echo "$OUT"
		echo "$OUT" | grep -q "PROVISION_RESULT=PASS" && exit 0 || exit 1
	fi
done

echo "timed out waiting for $RLOG on $HOST; last output:"
ssh_femto "cat $RLOG 2>/dev/null" || true
exit 1
