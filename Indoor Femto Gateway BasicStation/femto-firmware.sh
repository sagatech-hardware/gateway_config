#!/bin/sh
# femto-firmware.sh — check whether the femto runs BasicStation firmware and, if it
# does not, flash the BasicStation package the way the web UI would.
#
# Runs on the gateway (busybox ash). Reproduces the LuCI upgrade chain
# (action_ota_firmware) step for step, using the vendor's own validators instead of
# writing mtd directly, so every gate the web UI enforces is still enforced here.
#
# The upgrade is A/B: /sbin/upgrade_firmware.sh writes the *inactive* bank, flips the
# U-Boot `running_fw` env plus uci boot_firmware.fw_info.primary, and reboots. The
# bank currently running is left untouched and stays available as a fallback.
#
# usage: sh femto-firmware.sh {check|flash|status} [tarball]
#        FORCE=1 sh femto-firmware.sh flash    # flash even if BasicStation is present

STAGE_DIR="/mnt/data"
IMG="/tmp/firmware.img"
MARKERS="/tmp/version_ok /tmp/version_fail /tmp/magic_ok /tmp/magic_fail /tmp/com_file"
# BasicStation shipped from this firmware generation on; earlier builds are packet
# forwarder only (the femto's own fw2 bank held 3.03.09-opdk).
BS_MAJOR=4

ACTION="${1:-check}"
TARBALL="${2:-}"

say() { echo "$@"; }
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; }

result() {
	echo "FIRMWARE_RESULT=$1"
	[ "$1" = FAIL ] && exit 1
	exit 0
}

# ---------- facts ----------

fw_version() { uci get profile.system.fw_version 2> /dev/null; }
fw_major() { fw_version | cut -d. -f1; }
model() { uci get profile.system.model_name 2> /dev/null; }
bank() { fw_printenv running_fw 2> /dev/null | cut -d= -f2; }
bank_vers() {
	printf 'fw1=%s fw2=%s primary=%s' \
		"$(uci get boot_firmware.fw_info.fw1_ver 2> /dev/null)" \
		"$(uci get boot_firmware.fw_info.fw2_ver 2> /dev/null)" \
		"$(uci get boot_firmware.fw_info.primary 2> /dev/null)"
}

# BasicStation present? The binary is the load-bearing marker: the packet-forwarder
# firmware ships /usr/bin/lora_pkt_fwd and no /bin/station at all.
has_station() { [ -x /bin/station ]; }

# Newest staged package, so the caller can push a tarball and not repeat its name.
find_tarball() {
	[ -n "$TARBALL" ] && { echo "$TARBALL"; return; }
	ls -t "$STAGE_DIR"/fw_pkt_*.tar.gz 2> /dev/null | head -1
}

# ---------- check ----------

# Exit 0 = BasicStation present (nothing to do), 10 = missing (flash needed).
cmd_check() {
	say "model      : $(model)"
	say "fw_version : $(fw_version)"
	say "banks      : $(bank_vers)"
	say "running    : $(bank)"
	say "/bin/station         : $(has_station && echo present || echo ABSENT)"
	say "/usr/bin/lora_pkt_fwd: $([ -x /usr/bin/lora_pkt_fwd ] && echo present || echo absent)"

	if has_station && [ "$(fw_major)" = "$BS_MAJOR" ]; then
		ok "BasicStation firmware present ($(fw_version)) — no upgrade needed"
		return 0
	fi
	bad "BasicStation missing (fw_version $(fw_version), /bin/station $(has_station && echo present || echo absent))"
	return 10
}

cmd_status() {
	cmd_check
	say "--- staged packages ---"
	ls -la "$STAGE_DIR"/fw_pkt_*.tar.gz 2> /dev/null || say "(none in $STAGE_DIR)"
	say "--- upgrade state ---"
	say "pending=$(uci get profile.fw_upgrade.pending 2> /dev/null) status=$(uci get profile.fw_upgrade.status 2> /dev/null)"
	say "fw_ota_ver=$(uci get 'system.@system[0].fw_ota_ver' 2> /dev/null)"
	say "--- tmpfs ---"
	df -h /tmp | tail -1
}

# ---------- flash ----------

# The vendor's integrity gate, reproduced from LuCI check_crc(): the CRC32 of the
# package must equal characters 16-23 of its own filename. Also catches a truncated
# upload, which is the realistic failure of a 10 MB push over dropbear.
verify_crc() {
	base="$(basename "$1")"
	want="$(echo "$base" | cut -c16-23)"
	got="$(crc32 "$1" 2> /dev/null)"
	say "crc32 $got (filename claims $want)"
	[ -n "$got" ] && [ "$got" = "$want" ]
}

cmd_flash() {
	# Decided before the package is even looked for: a healthy box needs no upload.
	if has_station && [ "$(fw_major)" = "$BS_MAJOR" ] && [ "${FORCE:-0}" != 1 ]; then
		ok "BasicStation already present ($(fw_version)) — nothing to flash"
		result SKIP
	fi

	tar="$(find_tarball)"
	[ -n "$tar" ] || {
		bad "no package found: pass a path or push one to $STAGE_DIR/fw_pkt_*.tar.gz"
		result FAIL
	}
	[ -f "$tar" ] || { bad "$tar not found"; result FAIL; }
	say "package    : $tar ($(wc -c < "$tar") bytes)"

	verify_crc "$tar" || { bad "crc32 mismatch — package corrupt or truncated"; result FAIL; }
	ok "crc32 matches filename"

	# uncompress -d greps /tmp for the single fw_pkt_*img it just extracted, so a
	# stale image from an earlier attempt would be picked up instead of this one.
	rm -f $MARKERS "$IMG" /tmp/fw_pkt_*.img
	free_kb="$(df -k /tmp | tail -1 | awk '{print $4}')"
	[ "${free_kb:-0}" -gt 20480 ] || { bad "/tmp has only ${free_kb}KB free, need ~20MB"; result FAIL; }

	# -d: tar -zxvf <pkg> -C /tmp, compare the image version against
	# profile.system.fw_version, then rename the image to /tmp/firmware.img.
	say "-- uncompress -d"
	/usr/bin/uncompress -d "$tar" > /dev/null 2>&1
	[ -f "$IMG" ] || { bad "no $IMG produced — package is not a femto fw_pkt bundle"; result FAIL; }
	ok "extracted $IMG ($(wc -c < "$IMG") bytes)"

	if [ -f /tmp/version_fail ]; then
		bad "vendor version gate rejected the package"
		say "--- /tmp/com_file (image name, image version, installed version) ---"
		cat /tmp/com_file 2> /dev/null
		result FAIL
	fi
	[ -f /tmp/version_ok ] || { bad "version gate produced no verdict"; result FAIL; }
	ok "version gate passed"

	# -m: /lib/upgrade/platform.sh check <img> — uImage magic must be 27051956.
	say "-- uncompress -m"
	/usr/bin/uncompress -m "$IMG" > /dev/null 2>&1
	[ -f /tmp/magic_ok ] || { bad "magic check failed — image is not a valid uImage"; result FAIL; }
	ok "magic check passed"

	new_ver="$(cat /tmp/fw_femto_ver 2> /dev/null | tr -d '\n')"
	[ -n "$new_ver" ] && {
		uci set "system.@system[0].fw_ota_ver=$new_ver" 2> /dev/null
		uci commit system 2> /dev/null
		ok "fw_ota_ver = $new_ver"
	}

	say "target bank: $([ "$(bank)" = firmware1 ] && echo firmware2 || echo firmware1) (current $(bank) kept as fallback)"
	sync
	ok "gates passed — handing over to /sbin/upgrade_firmware.sh"
	echo "FIRMWARE_RESULT=PASS"

	# upgrade_firmware.sh runs `/sbin/wifi down` before `mtd write` and ends in
	# `reboot`, so it kills the SSH session it was launched from — over the AP
	# address it kills the whole link. Detach and ignore HUP so the write always
	# completes; the caller confirms the outcome after the box comes back.
	trap "" HUP
	/sbin/upgrade_firmware.sh >> /tmp/femto-firmware-flash.log 2>&1 &
	exit 0
}

case "$ACTION" in
check) cmd_check ;;
status) cmd_status ;;
flash) cmd_flash ;;
*)
	echo "usage: $0 {check|flash|status} [tarball]"
	exit 2
	;;
esac
