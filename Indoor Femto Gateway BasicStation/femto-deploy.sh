#!/bin/bash
# femto-deploy.sh — push femto-provision.sh to the femto over SSH and run it.
#
# dropbear on this gateway has no scp/sftp, so the script is streamed through
# `cat >`. The provisioning run stops BasicStation, which sometimes drops the SSH
# session, so it is started detached and the caller polls its log instead.
#
# No credentials are configured: the gateway is discovered at its AP address, its
# MAC is read off the link, and Browan's factory naming derives both the AP name
# (AP-<last 6 MAC chars>) and the root password (browan@<last 6 MAC chars>).
#
# usage: ./femto-deploy.sh [host] [install|verify|rollback|status]

set -uo pipefail

DISCOVER_IP="192.168.55.1"
ACTION="${2:-install}"
HOST="${1:-$DISCOVER_IP}"
SRC="$(dirname "$0")/femto-provision.sh"
REMOTE="/tmp/femto-provision.sh"
RLOG="/tmp/femto-provision.log"
POLL_TRIES=40
POLL_SLEEP=5

wifi_dev() { nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | sed -n 's/:wifi$//p' | head -1; }

neigh_mac() {
	ping -c1 -W2 "$1" > /dev/null 2>&1
	ip neigh show "$1" ${2:+dev "$2"} 2>/dev/null |
		awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i + 1)}' | head -1
}

active_ap() { nmcli -t -f NAME con show --active 2>/dev/null | grep -m1 '^AP-'; }

# Best source first: the ARP entry for the AP address on the wireless interface is
# the gateway's base MAC, which is what the factory naming uses. The other MACs on
# this box are offset from it (eth0.2 +1, the AP's own BSSID +2), so they only serve
# as fallbacks — each candidate is confirmed by an actual SSH login below.
discover_macs() {
	neigh_mac "$DISCOVER_IP" "$(wifi_dev)"
	neigh_mac "$DISCOVER_IP"
	[ "$HOST" = "$DISCOVER_IP" ] || neigh_mac "$HOST"
	nmcli -t -f ACTIVE,BSSID dev wifi list 2>/dev/null | sed -n 's/^yes://p' | tr -d '\\'
}

ssh_try() {
	sshpass -p "$1" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=8 -o LogLevel=ERROR -o NumberOfPasswordPrompts=1 \
		"root@$HOST" true > /dev/null 2>&1
}

ssh_femto() {
	sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=10 -o LogLevel=ERROR "root@$HOST" "$@"
}

command -v sshpass >/dev/null || { echo "sshpass required"; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }

case "$ACTION" in
install | verify | rollback | status) ;;
*) echo "usage: $0 [host] [install|verify|rollback|status]"; exit 2 ;;
esac

# The AP address only exists over the gateway's own Wi-Fi, and this laptop keeps
# drifting back to other networks — which makes the femto look dead.
case "$HOST" in
192.168.55.*)
	AP_ACTIVE=$(active_ap)
	if [ -z "$AP_ACTIVE" ]; then
		echo "not associated with a femto AP — connect first, e.g.:"
		nmcli -t -f SSID dev wifi list 2>/dev/null | grep '^AP-' | sort -u |
			sed "s/^/  nmcli con up /"
		echo "(or pass the LAN address: $0 10.4.13.48 $ACTION)"
		exit 1
	fi
	echo "-- Wi-Fi '$AP_ACTIVE' active"
	;;
esac

ping -c1 -W2 "$HOST" > /dev/null 2>&1 || { echo "$HOST unreachable"; exit 1; }

MACS=$(discover_macs | awk 'NF && !seen[$0]++')
[ -n "$MACS" ] || {
	echo "no MAC found for $DISCOVER_IP — is this box on the gateway's Wi-Fi?"
	exit 1
}

PASS=""
for mac in $MACS; do
	s=${mac//[:-]/}
	s=${s^^}
	suf=${s: -6}
	for cand in "browan@$suf" "browan@${suf: -4}"; do
		if ssh_try "$cand"; then
			PASS="$cand"
			AP="AP-$suf"
			MAC="$mac"
			break 2
		fi
	done
done

[ -n "$PASS" ] || {
	echo "MACs tried: $(echo "$MACS" | tr '\n' ' ')"
	echo "no derived password accepted by root@$HOST — check the unit's factory scheme"
	echo "(expected AP-<last 6 MAC chars> / browan@<last 6 MAC chars>)"
	exit 1
}
echo "-- MAC $MAC -> $AP, root password derived from suffix ${PASS#browan@}"

echo "== femto $HOST: $ACTION =="
ssh_femto "cat > $REMOTE && chmod +x $REMOTE" < "$SRC" || { echo "push failed"; exit 1; }

if [ "$ACTION" = "verify" ] || [ "$ACTION" = "status" ]; then
	ssh_femto "sh $REMOTE $ACTION"
	exit $?
fi

ssh_femto "rm -f $RLOG; sh $REMOTE $ACTION > $RLOG 2>&1 &" || true

for _ in $(seq "$POLL_TRIES"); do
	sleep "$POLL_SLEEP"
	OUT="$(ssh_femto "cat $RLOG 2>/dev/null" || true)"
	if grep -q "PROVISION_RESULT=" <<< "$OUT"; then
		echo "$OUT"
		grep -q "PROVISION_RESULT=PASS" <<< "$OUT" && exit 0 || exit 1
	fi
done

echo "timed out waiting for $RLOG on $HOST; last output:"
ssh_femto "cat $RLOG 2>/dev/null" || true
exit 1
