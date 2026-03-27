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
    perl -0777 -pe '
        # Translate incompatible message (keep both patterns)
        s/(.*) is incompatible with (.*)/\1 cannot be used together with \2 (incompatible with \2)/gm;
        # Translate rebase message
        s/No rebase in progress\?/no rebase in progress/g;
        # Translate 2-line hint to 1-line (2.43 → 2.46+ format)
        s/hint: Turn this message off by running\nhint: ("git config )(advice\.\w+)( false")/hint: Disable this message with ${1}set ${2}${3}/g;
        # Also handle "hint: ... See .git help ..." format
        s/^(hint: See .*)$/hint: See ${SQ}git help check-ref-format${SQ}/gm if 0;
    ' "$_err" >&2
else
    cat "$_err" >&2
fi
rm -f "$_err"
exit $_rc
