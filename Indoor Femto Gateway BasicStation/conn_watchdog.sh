#!/bin/sh
# conn_watchdog.sh — Browan WSMS-155 LNS connection watchdog.
#
# Reboots the gateway when its BasicStation link to the LNS is down, so a
# field unit that loses connectivity self-recovers. Meant to run every 15 min
# from crond (see manage_conn_watchdog.sh). It is STATELESS: each run only
# decides reboot-or-not, so recovery "normalizes" on its own — once the link is
# back, runs become no-ops and the gateway keeps operating untouched.
#
# Detection: `station` alive AND holding an ESTABLISHED TCP session to the LNS
# port parsed from tc.uri. This reflects station's own live socket, not mere
# network reachability, so an LNS drop with the internet still up is caught.
#
# Safety: a post-boot grace window stops a reboot loop while station is still
# dialing the LNS after each boot; a transient blip is ridden out with a few
# short re-checks before any reboot is taken.

set -u

TC_URI_FILE=/app/basicstation/tc.uri
LOG=/app/log/lora/conn_watchdog.log
GRACE_SECS=600   # skip reboot within 10 min of boot — station needs time to connect
CHECKS=3         # consecutive failed checks required before declaring "down"
CHECK_GAP=10     # seconds between re-checks (rides out momentary blips)
LOG_MAX=65536    # cap the log at 64 KiB on flash

uptime_secs() {
	# integer seconds since boot — device wall clock is undisciplined (no GPS/PPS)
	u=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	echo "${u:-0}"
}

cap_log() {
	sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
	[ "${sz:-0}" -gt "$LOG_MAX" ] || return 0
	tail -c $((LOG_MAX / 2)) "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
	return 0
}

log() {
	printf '%s up=%ss %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$(uptime_secs)" "$1" \
		>> "$LOG" 2>/dev/null
	cap_log
}

lns_port() {
	# parse the port from tc.uri (wss://host:port[/...]); default 443 when absent
	uri=$(cat "$TC_URI_FILE" 2>/dev/null)
	hp=${uri#*://}
	hp=${hp%%/*}
	p=${hp##*:}
	case "$p" in
		'' | *[!0-9]*) echo 443 ;;
		*) echo "$p" ;;
	esac
}

is_connected() {
	# station must be running...
	pidof station >/dev/null 2>&1 || return 1
	# ...and own a live (ESTABLISHED) non-loopback TCP session to the LNS port.
	# awk on the Foreign Address column ($5 = ip:port) keeps this free of any
	# netstat -p / program-column dependency (busybox netstat -p is unreliable).
	netstat -tn 2>/dev/null | awk -v p=":$(lns_port)$" '
		/ESTABLISHED/ && $5 ~ p && $5 !~ /^127\./ { found = 1 }
		END { exit(found ? 0 : 1) }'
}

main() {
	up=$(uptime_secs)
	if [ "$up" -lt "$GRACE_SECS" ]; then
		log "grace (up<${GRACE_SECS}s) — skip"
		exit 0
	fi
	i=1
	while [ "$i" -le "$CHECKS" ]; do
		if is_connected; then
			log "connected — ok"
			exit 0
		fi
		[ "$i" -lt "$CHECKS" ] && sleep "$CHECK_GAP"
		i=$((i + 1))
	done
	log "LNS link DOWN after ${CHECKS} checks — rebooting"
	sync
	reboot
}

main
