#!/bin/sh
# Triggered by OTA upgrade stages (PREUPGRADE, PREBOOT, POSTBOOT)
# Located at: /etc/syshotplug/ota/90.persist_ssh.sh

/bin/sh /data/auto_ssh/keep_ssh.sh >/dev/null 2>&1
