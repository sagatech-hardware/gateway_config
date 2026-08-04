# femto-fw-stage.sh — host side of the firmware stage, sourced by femto-deploy.sh.
#
# Its gateway-side half is femto-firmware.sh, exactly as femto-provision.sh is the
# gateway-side half of femto-deploy.sh. Kept out of the wrapper because flashing has
# its own failure surface: a 10 MB push, a reboot into the other bank, and a link
# that drops mid-write when the deploy runs over the gateway's own Wi-Fi.
#
# Uses the caller's HOST, AP, OS, FWSRC, FWREMOTE, FWTAR, FWLOG, POLL_* and BOOT_TRIES,
# plus its ssh_femto and ping_host helpers.

# The gateway reboots into the other bank, so the session dies by design. tmpfs is
# wiped with it, so the checker has to be pushed again before it can answer.
wait_reboot() {
	echo "-- waiting for reboot (up to $((BOOT_TRIES * POLL_SLEEP))s)"
	for _ in $(seq "$BOOT_TRIES"); do
		sleep "$POLL_SLEEP"
		# Over the AP the radio goes down with the box; nudge the laptop back on.
		case "$HOST" in
		192.168.55.*) [ "$OS" = nix ] && nmcli con up "$AP" > /dev/null 2>&1 ;;
		esac
		ping_host "$HOST" || continue
		tr -d '\r' < "$FWSRC" | ssh_femto "cat > $FWREMOTE" > /dev/null 2>&1 || continue
		ssh_femto "sh $FWREMOTE check" && return 0
	done
	echo "gateway did not come back with BasicStation"
	return 1
}

# Staged on /mnt/data (persistent, ~300 MB free) so a retry does not re-upload, then
# run detached: upgrade_firmware.sh takes wifi down before `mtd write` and reboots.
flash_firmware() {
	[ -f "$FWTAR" ] || { echo "missing firmware package: $FWTAR"; return 1; }
	base="$(basename "$FWTAR")"
	echo "-- pushing $base ($(wc -c < "$FWTAR") bytes; slow, dropbear has no scp)"
	ssh_femto "cat > /mnt/data/$base" < "$FWTAR" || { echo "package push failed"; return 1; }
	ssh_femto "rm -f $FWLOG; sh $FWREMOTE flash > $FWLOG 2>&1 &" || true
	OUT=""
	for _ in $(seq "$POLL_TRIES"); do
		sleep "$POLL_SLEEP"
		OUT="$(ssh_femto "cat $FWLOG 2>/dev/null" || true)"
		echo "$OUT" | grep -q "FIRMWARE_RESULT=" && break
	done
	echo "$OUT"
	# SKIP and FAIL both stop here: SKIP means the box already had BasicStation, and
	# only PASS means a bank was written and a reboot is on its way.
	echo "$OUT" | grep -q "FIRMWARE_RESULT=PASS" || return 1
	wait_reboot
}

# femto-provision.sh preflights on /opt/basicstation/station, so a factory
# packet-forwarder unit cannot be serviced at all until BasicStation is flashed.
firmware_stage() {
	ssh_femto "sh $FWREMOTE check"
	case "$?" in
	0) return 0 ;;
	10) flash_firmware ;;
	*) echo "firmware check failed on $HOST"; return 1 ;;
	esac
}
