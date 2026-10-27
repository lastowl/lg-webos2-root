#!/bin/sh
# SSH forced-command wrapper for persistent root on LG webOS.
# Set as command= in authorized_keys. On each SSH connection:
#   1. Launches the exploit in background if not already rooted
#   2. Passes through to the original command or interactive shell
#
# The exploit takes ~5-8 seconds. /tmp/rootsh becomes available after.

PERSIST_DIR="/media/developer/persist"

if [ ! -f /tmp/rooted ] && [ -x "$PERSIST_DIR/towelroot" ]; then
    if [ ! -f /tmp/.autoroot_running ]; then
        touch /tmp/.autoroot_running
        (
            cp "$PERSIST_DIR/rootsh" /tmp/rootsh 2>/dev/null
            chmod 755 /tmp/rootsh 2>/dev/null
            cp "$PERSIST_DIR/dotrigger" /tmp/dotrigger 2>/dev/null
            chmod 755 /tmp/dotrigger 2>/dev/null
            "$PERSIST_DIR/towelroot" > /tmp/autoroot.log 2>&1
        ) &
    fi
fi

if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
    exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
else
    exec /bin/sh -l
fi
