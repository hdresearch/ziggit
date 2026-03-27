#!/bin/bash
ZIGGIT=/root/ziggit/zig-out/bin/ziggit
if [ $# -eq 0 ]; then
    $ZIGGIT 2>&1
    exit 1
fi
_err=/tmp/.ziggit-err.$$
$ZIGGIT "$@" 2>"$_err"
_rc=$?
if [ -s "$_err" ]; then
    sed -E \
        -e "s/^(error: )(-[^ ]+) is incompatible with (-[^ ]+)/\1option '\2' cannot be used together with '\3'/" \
        -e 's/^(fatal: )No rebase in progress\?$/\1no rebase in progress/' \
        "$_err" >&2
fi
rm -f "$_err"
exit $_rc
