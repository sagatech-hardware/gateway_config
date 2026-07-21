#!/usr/bin/env bash
#
# install.sh — deploy pktfwd-station-bridge onto a Gemtek/Browan Indoor Femto
# (or any OpenWrt gateway of the same type) over SSH. Idempotent: safe to re-run.
#
# The gateway keeps forwarding LoRa frames with its native lora_pkt_fwd; this
# script points that Semtech-UDP stream at the local bridge, which relays it to
# the BasicStation LNS. Binary + .env live together in /mnt/data (persistent).
# Dropbear has no scp, so files go over `ssh 'cat >file'`.
#
#   ./install.sh -g 192.168.55.1 -e 0016C0-80029C4572D3
set -euo pipefail

GW=192.168.55.1
USER=root
PASS=root
ROUTER=""
CUPS_URI="https://thingparkenterprise.sa.actility.com:443"
REGION=US915
UDP_PORT=1700
BIN=""
INSTALL_DIR=/mnt/data/pktfwd-station-bridge
GLOBAL_CONF=/app/cfg/global_conf.json
HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
	cat >&2 <<EOF
usage: $0 -e <routerId> [-g gw] [-u user] [-p pass] [-b binary]
          [-c cupsUri] [-P udpPort] [-d installDir]
  -e  gateway router id registered on the LNS (e.g. 0016C0-80029C4572D3)   [required]
  -g  gateway address (default $GW)
  -b  path to mipsle binary (default: committed bin/, else make build)
EOF
	exit 2
}

while getopts "g:u:p:e:c:r:P:b:d:h" opt; do
	case "$opt" in
	g) GW="$OPTARG" ;; u) USER="$OPTARG" ;; p) PASS="$OPTARG" ;;
	e) ROUTER="$OPTARG" ;; c) CUPS_URI="$OPTARG" ;; r) REGION="$OPTARG" ;;
	P) UDP_PORT="$OPTARG" ;; b) BIN="$OPTARG" ;; d) INSTALL_DIR="$OPTARG" ;; *) usage ;;
	esac
done
[ -n "$ROUTER" ] || { echo "error: -e <routerId> required" >&2; usage; }

if [ -z "$BIN" ]; then
	if [ -f "$HERE/../bin/pktfwd-station-bridge" ]; then
		BIN="$HERE/../bin/pktfwd-station-bridge"
	else
		echo "==> building binary (make build)"
		make -C "$HERE/.." build
		BIN="$HERE/../bin/pktfwd-station-bridge"
	fi
fi
[ -f "$BIN" ] || { echo "error: binary not found: $BIN" >&2; exit 1; }

REMOTE_BIN="$INSTALL_DIR/pktfwd-station-bridge"
TCDIR="$INSTALL_DIR/tc"

SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8
	-o PreferredAuthentications=keyboard-interactive,password
	-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1
	-o HostKeyAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc,aes128-ctr -o PubkeyAuthentication=no)
ASKPASS="$(mktemp)"
printf '#!/bin/sh\necho %q\n' "$PASS" >"$ASKPASS"
chmod +x "$ASKPASS"
trap 'rm -f "$ASKPASS"' EXIT

sshc() { SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w ssh "${SSHOPTS[@]}" "$USER@$GW" "$@"; }
push() { SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w ssh "${SSHOPTS[@]}" "$USER@$GW" "cat > '$2'" <"$1"; }

echo "==> [1/7] probe $USER@$GW"
sshc 'echo "    connected: $(uname -m) $(uci get profile.system.model_name 2>/dev/null)"'

echo "==> [2/7] backup global_conf.json on gateway"
sshc "mkdir -p $INSTALL_DIR $TCDIR /root/pktfwd-bridge-backup && cp $GLOBAL_CONF /root/pktfwd-bridge-backup/global_conf.json.\$(date +%s) 2>/dev/null; true"

echo "==> [3/7] push .env to $INSTALL_DIR/.env"
ENV_TMP="$(mktemp)"
cat >"$ENV_TMP" <<EOF
ROUTER_ID=$ROUTER
ROUTER_FORMAT=raw
CUPS_URI=$CUPS_URI
LNS_URI=
UDP_LISTEN=127.0.0.1:$UDP_PORT
TC_DIR=$TCDIR
REGION=$REGION
MODEL=WLRGFM-100
EOF
push "$ENV_TMP" "$INSTALL_DIR/.env"
rm -f "$ENV_TMP"

echo "==> [4/7] push binary to $REMOTE_BIN"
push "$BIN" "$REMOTE_BIN"
sshc "chmod +x $REMOTE_BIN"

echo "==> [5/7] install init script + enable"
push "$HERE/bridge.init" /etc/init.d/pktfwd-station-bridge
sshc "chmod +x /etc/init.d/pktfwd-station-bridge && /etc/init.d/pktfwd-station-bridge enable"

echo "==> [6/7] point lora_pkt_fwd at 127.0.0.1:$UDP_PORT"
sshc "sed -i \
  -e 's#\(\"server_address\":\)[^,]*#\1 \"127.0.0.1\"#' \
  -e 's#\(\"serv_port_up\":\)[^,]*#\1 $UDP_PORT#' \
  -e 's#\(\"serv_port_down\":\)[^,]*#\1 $UDP_PORT#' \
  $GLOBAL_CONF"

echo "==> [7/7] watchdog cron + start"
sshc '(crontab -l 2>/dev/null | grep -v pktfwd-station-bridge; echo "*/1 * * * * /etc/init.d/pktfwd-station-bridge start") | crontab -'
sshc "/etc/init.d/pktfwd-station-bridge restart 2>/dev/null; /etc/init.d/pktfwd-station-bridge start"

echo "==> done. logs: ssh $USER@$GW logread | grep pktfwd"
