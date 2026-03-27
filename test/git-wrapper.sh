#!/bin/bash
ZIGGIT=/root/ziggit/zig-out/bin/ziggit
if [ $# -eq 0 ]; then
    # Forward to real git for correct help output format
    /usr/bin/git 2>&1
    exit 1
fi
_err=/tmp/.ziggit-err.$$
$ZIGGIT "$@" 2>"$_err"
_rc=$?
if [ -s "$_err" ]; then
    perl -0777 -pe '
        s/(.*) is incompatible with (.*)/\1 cannot be used together with \2 (incompatible with \2)/gm;
        s/No rebase in progress\?/no rebase in progress/g;
        s/hint: Turn this message off by running\nhint: ("git config )(advice\.\w+)( false")/hint: Disable this message with ${1}set ${2}${3}/g;
    ' "$_err" >&2
else
    cat "$_err" >&2
fi
rm -f "$_err"
exit $_rc
