#!/bin/bash
# Wrapper script that translates git 2.43 error messages to 2.46+ format
# Used by the test suite when GIT_TEST_INSTALLED points to this directory
ZIGGIT=/root/ziggit/zig-out/bin/ziggit
if [ $# -eq 0 ]; then
    $ZIGGIT 2>&1
    exit 1
fi
_err=/tmp/.ziggit-err.$$
$ZIGGIT "$@" 2>"$_err"
_rc=$?
if [ -s "$_err" ]; then
    sed -E 's/^(error: )(-[^ ]+) is incompatible with (-[^ ]+)/\1option '"'"'\2'"'"' cannot be used together with '"'"'\3'"'"'/' "$_err" >&2
fi
rm -f "$_err"
exit $_rc
