#!/bin/sh
# manage_conn_watchdog.sh — install / remove / status for conn_watchdog.sh on
# the Browan gateway. Run ON the gateway, as root.
#
# The unit has no systemd and its busybox crond is not enabled at boot, so
# install() also wires boot persistence via /etc/rc.local — without it the
# watchdog would die after its own first reboot and never fire again.
#
#   sh manage_conn_watchdog.sh install
#   sh manage_conn_watchdog.sh remove
#   sh manage_conn_watchdog.sh status

set -u

SELF_DIR=$(dirname "$0")
SRC="$SELF_DIR/conn_watchdog.sh"
DST=/app/conn_watchdog.sh
CRON_DIR=/etc/crontabs
CRONTAB="$CRON_DIR/root"
CRON_LINE='*/15 * * * * /app/conn_watchdog.sh'
RCLOCAL=/etc/rc.local
RC_MARK='# conn_watchdog: keep crond alive'
CROND_CMD='pidof crond >/dev/null 2>&1 || crond -b -c /etc/crontabs -L /dev/null'

ensure_crond_running() {
	pidof crond >/dev/null 2>&1 && return 0
	crond -b -c "$CRON_DIR" -L /dev/null 2>/dev/null
}

add_cron_line() {
	mkdir -p "$CRON_DIR"
	[ -f "$CRONTAB" ] || : > "$CRONTAB"
	grep -qF "$CRON_LINE" "$CRONTAB" && return 0
	printf '%s\n' "$CRON_LINE" >> "$CRONTAB"
}

add_boot_hook() {
	# make crond come back after a reboot (rc.local runs late in boot)
	if [ -f "$RCLOCAL" ] && grep -qF "$RC_MARK" "$RCLOCAL"; then
		return 0
	fi
	if [ ! -f "$RCLOCAL" ]; then
		printf '#!/bin/sh\n%s\n%s\nexit 0\n' "$RC_MARK" "$CROND_CMD" > "$RCLOCAL"
		chmod +x "$RCLOCAL" 2>/dev/null
		return 0
	fi
	if grep -q '^exit 0' "$RCLOCAL"; then
		# insert before the first 'exit 0' (busybox-safe, no GNU sed 0,/re/)
		awk -v m="$RC_MARK" -v c="$CROND_CMD" '
			/^exit 0/ && !done { print m; print c; done = 1 }
			{ print }' "$RCLOCAL" > "$RCLOCAL.new" && mv "$RCLOCAL.new" "$RCLOCAL"
	else
		printf '%s\n%s\n' "$RC_MARK" "$CROND_CMD" >> "$RCLOCAL"
	fi
	chmod +x "$RCLOCAL" 2>/dev/null
}

install_watchdog() {
	if [ -f "$SRC" ]; then
		cp "$SRC" "$DST" || { echo "ERR: copy $SRC -> $DST failed"; exit 1; }
	elif [ ! -f "$DST" ]; then
		echo "ERR: $SRC not found and $DST absent — nothing to install"; exit 1
	fi
	chmod +x "$DST"
	add_cron_line
	add_boot_hook
	ensure_crond_running
	echo "installed: $DST + cron (*/15) + boot hook"
	status
}

remove_line() { # $1=file $2=pattern
	[ -f "$1" ] || return 0
	grep -vF "$2" "$1" > "$1.new" 2>/dev/null && mv "$1.new" "$1"
}

remove_watchdog() {
	remove_line "$CRONTAB" "$CRON_LINE"
	# drop both marker and command lines from rc.local
	if [ -f "$RCLOCAL" ]; then
		grep -vF "$RC_MARK" "$RCLOCAL" | grep -vF "$CROND_CMD" > "$RCLOCAL.new" \
			&& mv "$RCLOCAL.new" "$RCLOCAL"
	fi
	rm -f "$DST"
	pidof crond >/dev/null 2>&1 && kill -HUP "$(pidof crond)" 2>/dev/null
	echo "removed: $DST + cron entry + boot hook (crond left running, harmless)"
}

status() {
	echo "--- conn_watchdog status ---"
	[ -x "$DST" ] && echo "script : $DST (present)" || echo "script : MISSING"
	grep -qF "$CRON_LINE" "$CRONTAB" 2>/dev/null && echo "cron   : entry present" || echo "cron   : MISSING"
	pidof crond >/dev/null 2>&1 && echo "crond  : running (pid $(pidof crond))" || echo "crond  : NOT running"
	grep -qF "$RC_MARK" "$RCLOCAL" 2>/dev/null && echo "boot   : rc.local hook present" || echo "boot   : MISSING"
	echo "log    : /app/log/lora/conn_watchdog.log (last 3):"
	tail -n 3 /app/log/lora/conn_watchdog.log 2>/dev/null || echo "  (none yet)"
}

case "${1:-}" in
	install) install_watchdog ;;
	remove) remove_watchdog ;;
	status) status ;;
	*) echo "usage: sh $0 {install|remove|status}"; exit 2 ;;
esac
