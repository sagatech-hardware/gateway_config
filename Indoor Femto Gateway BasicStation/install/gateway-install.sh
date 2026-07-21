#!/bin/sh
# gateway-install.sh — ON-DEVICE provisioner for pktfwd-station-bridge on the
# Gemtek/Browan Indoor Femto (WLRGFM-100). Run this ON the gateway, as root:
#
#   wget -O /tmp/gwi.sh "<raw>/install/gateway-install.sh" && sh /tmp/gwi.sh
#
# (The other installer, install/install.sh, runs from a dev box and pushes over
# SSH. This one is the "log in and run it yourself" path.)
#
# It derives ROUTER_ID from the gateway MAC AUTOMATICALLY (0016C0-<MAC>), points
# the native lora_pkt_fwd at the local bridge, installs the service + watchdogs,
# and configures the WAN from wan.env. Idempotent.
#
# Overrides via env: RAW_BASE=, MAC_IFACE=, ROUTER_ID=, ROUTER_PREFIX=,
#   REGION=, CUPS_URI=, UDP_PORT=.

set -u

RAW_BASE="${RAW_BASE:-https://github.com/sagatech-hardware/gateway_config/raw/main/Indoor%20Femto%20Gateway%20BasicStation}"
DIR=/mnt/data/pktfwd-station-bridge
BIN="$DIR/pktfwd-station-bridge"
GCONF=/app/cfg/global_conf.json
ROUTER_PREFIX="${ROUTER_PREFIX:-0016C0}"
REGION="${REGION:-US915}"
CUPS_URI="${CUPS_URI:-https://thingparkenterprise.sa.actility.com:443}"
UDP_PORT="${UDP_PORT:-1700}"

log() { printf '[install] %s\n' "$1"; }

fetch() { # $1=relpath under RAW_BASE  $2=dest
	# Gateways often lack a CA bundle → GitHub TLS verify fails. Try verified
	# first, then fall back to --no-check-certificate (own repo, acceptable).
	wget -q -O "$2" "$RAW_BASE/$1" \
		|| wget -q --no-check-certificate -O "$2" "$RAW_BASE/$1" \
		|| { log "ERR fetch $1"; return 1; }
	[ -s "$2" ] || { log "ERR empty $1"; return 1; }
}

detect_mac() {
	iface="${MAC_IFACE:-}"
	if [ -z "$iface" ]; then
		for c in eth0 br-lan eth1; do
			[ -f "/sys/class/net/$c/address" ] && { iface="$c"; break; }
		done
	fi
	[ -n "$iface" ] && cat "/sys/class/net/$iface/address" 2>/dev/null
}

router_id_from_mac() { # $1=mac; ROUTER_ID = <prefix>-<12 hex MAC>
	hex=$(printf '%s' "$1" | tr -d ':' | tr 'a-z' 'A-Z')
	[ ${#hex} -eq 12 ] || return 1
	printf '%s-%s' "$ROUTER_PREFIX" "$hex"
}

add_cron() { # idempotent crontab line
	line="$1"
	existing=$(crontab -l 2>/dev/null)
	printf '%s\n' "$existing" | grep -qF "$line" && return 0
	{ printf '%s\n' "$existing"; printf '%s\n' "$line"; } | grep -v '^$' | crontab -
}

install_deps() {
	# NB: BB 14.07's feed has no ca-bundle ("Unknown package"), so the TLS trust
	# anchor is shipped by write_trust() instead of opkg. Only nohup is fetched.
	opkg update 2>/dev/null
	opkg install coreutils-nohup 2>/dev/null
}

# ThingPark CUPS/LNS sit behind AWS, so their server certs chain to Amazon Root
# CA 1 — Actility docs require cups.trust == AmazonRootCA1 for every SaaS region
# (EU/AU/US/SA). These gateways have no system CA store, so pin that single root
# here; the Go bridge validates the CUPS/LNS handshake against TRUST_CA_PATH.
# Cert SHA1 8D:A7:F9:65:EC:5E:FC:37:91:0F:1C:6E:59:FD:C1:CC:6A:6E:DE:16.
write_trust() {
	mkdir -p "$DIR/tc"
	cat > "$DIR/tc/cups.trust" <<'EOF'
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
EOF
	log "CUPS/LNS trust pinned → $DIR/tc/cups.trust (Amazon Root CA 1)"
}

install_bridge() {
	mkdir -p "$DIR" "$DIR/tc" /root/pktfwd-bridge-backup
	cp "$GCONF" "/root/pktfwd-bridge-backup/global_conf.json.$(date +%s)" 2>/dev/null
	fetch bin/pktfwd-station-bridge "$BIN" && chmod +x "$BIN"
	fetch install/bridge.init /etc/init.d/pktfwd-station-bridge \
		&& chmod +x /etc/init.d/pktfwd-station-bridge
	/etc/init.d/pktfwd-station-bridge enable 2>/dev/null
	log "bridge binary + init installed"
}

# write_env stamps ROUTER_ID from the MAC — the ONLY per-gateway value — so no
# .env editing is needed. TC_DIR/CUPS/region come from the overridable defaults.
write_env() {
	mac=$(detect_mac)
	rid="${ROUTER_ID:-$(router_id_from_mac "$mac")}"
	if [ -z "$rid" ]; then
		log "ERR could not derive ROUTER_ID from MAC '$mac' — set ROUTER_ID="
		return 1
	fi
	cat > "$DIR/.env" <<EOF
ROUTER_ID=$rid
ROUTER_FORMAT=raw
CUPS_URI=$CUPS_URI
LNS_URI=
UDP_LISTEN=127.0.0.1:$UDP_PORT
TC_DIR=$DIR/tc
TRUST_CA_PATH=$DIR/tc/cups.trust
REGION=$REGION
MODEL=WLRGFM-100
EOF
	log "ROUTER_ID = $rid (from MAC ${mac:-unknown})"
}

point_pktfwd() {
	sed -i \
		-e 's#\("server_address":\)[^,]*#\1 "127.0.0.1"#' \
		-e "s#\(\"serv_port_up\":\)[^,]*#\1 $UDP_PORT#" \
		-e "s#\(\"serv_port_down\":\)[^,]*#\1 $UDP_PORT#" \
		"$GCONF"
	log "lora_pkt_fwd → 127.0.0.1:$UDP_PORT"
}

install_watchdogs() {
	fetch install/check_no_connection_reboot.sh /sbin/check_no_connection_reboot.sh \
		&& chmod +x /sbin/check_no_connection_reboot.sh
	add_cron "*/1 * * * * /etc/init.d/pktfwd-station-bridge start"
	add_cron "*/30 * * * * nohup /sbin/check_no_connection_reboot.sh"
	/etc/init.d/cron enable 2>/dev/null
	/etc/init.d/cron restart 2>/dev/null
	log "watchdogs installed (bridge keep-alive 1m, conn-check 30m)"
}

wan_env_path() {
	for p in /etc/gemtek/wan.env ./wan.env /tmp/wan.env; do
		[ -f "$p" ] && { printf '%s' "$p"; return 0; }
	done
	fetch wan.env /tmp/wan.env && { printf '/tmp/wan.env'; return 0; }
	return 1
}

apply_wan() {
	f=$(wan_env_path) || { log "no wan.env found — WAN left unchanged"; return 0; }
	. "$f"
	uci -q set network.wan=interface
	uci -q set network.wan.proto="${WAN_PROTO:-3g}"
	[ -n "${WAN_DEVICE:-}" ]   && uci -q set network.wan.device="$WAN_DEVICE"
	[ -n "${WAN_AT_PORT:-}" ]  && uci -q set network.wan.at_port="$WAN_AT_PORT"
	[ -n "${WAN_APN:-}" ]      && uci -q set network.wan.apn="$WAN_APN"
	[ -n "${WAN_PINCODE:-}" ]  && uci -q set network.wan.pincode="$WAN_PINCODE"
	[ -n "${WAN_USERNAME:-}" ] && uci -q set network.wan.username="$WAN_USERNAME"
	[ -n "${WAN_PASSWORD:-}" ] && uci -q set network.wan.password="$WAN_PASSWORD"
	uci commit network
	/etc/init.d/network reload 2>/dev/null || /etc/init.d/network restart 2>/dev/null
	log "WAN set from $f: proto=${WAN_PROTO:-3g} apn=${WAN_APN:-n/a}"
}

main() {
	log "== Femto WLRGFM-100 pktfwd-station-bridge provisioning =="
	install_deps
	install_bridge
	write_trust
	write_env
	point_pktfwd
	install_watchdogs
	apply_wan
	/etc/init.d/pktfwd-station-bridge restart 2>/dev/null \
		|| /etc/init.d/pktfwd-station-bridge start
	log "== done. Verify: logread | grep pktfwd ; cat $DIR/.env | grep ROUTER_ID =="
}

main
