#!/bin/bash

ZIGGIT=/root/ziggit/zig-out/bin/ziggit
ITERATIONS=10

cd /tmp && rm -rf quick_bench && mkdir quick_bench && cd quick_bench
git init -q && git config user.email "t@t.com" && git config user.name "T"
echo hello > test.txt && git add test.txt && git commit -q -m "test"
git tag -a v1.0.0 -m "v1.0.0"
echo world > test2.txt && git add test2.txt && git commit -q -m "second"

echo "Running quick benchmark..."

# Test status --porcelain
echo "Timing git status --porcelain..."
start=$(date +%s%N)
for i in $(seq 1 $ITERATIONS); do
    git status --porcelain >/dev/null 2>&1
done
end=$(date +%s%N)
git_time=$((end - start))

echo "Timing ziggit status --porcelain..."
start=$(date +%s%N)
for i in $(seq 1 $ITERATIONS); do
    $ZIGGIT status --porcelain >/dev/null 2>&1
done
end=$(date +%s%N)
ziggit_time=$((end - start))

echo "Git total time: ${git_time}ns (avg: $((git_time / ITERATIONS))ns)"
echo "Ziggit total time: ${ziggit_time}ns (avg: $((ziggit_time / ITERATIONS))ns)"
speedup=$(awk "BEGIN {printf \"%.2f\", $git_time / $ziggit_time}")
echo "Speedup: ${speedup}x"