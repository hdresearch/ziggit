#!/bin/bash
cd /tmp && rm -rf bun_compat_test && mkdir bun_compat_test && cd bun_compat_test
git init -q && git config user.email "t@t.com" && git config user.name "T"
echo hello > f.txt && git add f.txt && git commit -q -m "init"
git tag -a v1.0.0 -m "v1.0.0"
echo world > g.txt && git add g.txt && git commit -q -m "second"
echo mod >> f.txt
ZIGGIT=/root/ziggit/zig-out/bin/ziggit
PASS=0; FAIL=0
for test in \
  "status --porcelain" \
  "rev-parse HEAD" \
  "rev-parse --show-toplevel" \
  "describe --tags --abbrev=0" \
  "log --format=%H -1"; do
    g="$(git $test 2>&1)"; z="$($ZIGGIT $test 2>&1)"
    if [ "$g" = "$z" ]; then echo "PASS: $test"; PASS=$((PASS+1)); else echo "FAIL: $test"; echo "  git=[$g]"; echo "  zig=[$z]"; FAIL=$((FAIL+1)); fi
done
echo "$PASS passed, $FAIL failed"