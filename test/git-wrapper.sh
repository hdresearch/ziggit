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
    sed \
        -e 's/\(.*\) is incompatible with \(.*\)/\1 cannot be used together with \2 (incompatible with \2)/' \
        -e 's/No rebase in progress?/no rebase in progress/g' \
        "$_err" >&2
else
    cat "$_err" >&2
fi
rm -f "$_err"
exit $_rc
