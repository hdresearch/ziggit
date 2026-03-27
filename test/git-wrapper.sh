#!/bin/bash
# Minimal git-wrapper.sh for test compatibility
# No more perl stderr translations - ziggit produces correct output natively
ZIGGIT=/root/ziggit/zig-out/bin/ziggit
if [ $# -eq 0 ]; then
    $ZIGGIT 2>&1
    exit 1
fi
exec $ZIGGIT "$@"
