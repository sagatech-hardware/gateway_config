#!/bin/bash
# Set target host IP or hostname
TARGET_HOST='google.com'

count=$(ping -c 10 $TARGET_HOST | grep from* | wc -l)

if [ $count -eq 0 ]; then
    echo "$(date)" "Target host" $TARGET_HOST "unreachable, Rebooting!" >>/var/log/check_no_connection_reboot.log
    /sbin/shutdown -r 0
else
    echo "$(date) ===-> OK! " >>/var/log/check_no_connection_reboot.log
fi