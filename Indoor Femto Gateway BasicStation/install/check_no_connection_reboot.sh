#!/bin/sh
# check_no_connection_reboot.sh — reboot the femto when the internet is
# unreachable, so a stuck cellular/WAN link self-recovers. Cron: every 30 min.
#
# It gates on general internet reachability (a ping target), NOT the bridge↔LNS
# link: an LNS-side outage must not trigger reboots. Override the target with
# TARGET_HOST=.

TARGET_HOST="${TARGET_HOST:-google.com}"
LOG=/var/log/check_no_connection_reboot.log

if ping -c 10 "$TARGET_HOST" 2>/dev/null | grep -q 'from'; then
	echo "$(date) ===-> OK!" >> "$LOG"
else
	echo "$(date) Target $TARGET_HOST unreachable, rebooting!" >> "$LOG"
	/sbin/reboot
fi
