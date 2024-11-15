#!/bin/sh

#set -u
#set -e

# Add a console on ttyAMA0
if [ -e ${TARGET_DIR}/etc/inittab ]; then
    grep -qE '^ttyAMA0::' ${TARGET_DIR}/etc/inittab || \
        sed -i '/GENERIC_SERIAL/a\
ttyAMA0::respawn:-/bin/sh' ${TARGET_DIR}/etc/inittab
fi
