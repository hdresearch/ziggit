#!/bin/bash

ZIGGIT=/root/ziggit/zig-out/bin/ziggit
ITERATIONS=100
BENCHMARK_DIR="/tmp/simple_benchmark_$$"

echo "Creating test repository..."

# Clean up and create directory
rm -rf "$BENCHMARK_DIR"
mkdir -p "$BENCHMARK_DIR"
cd "$BENCHMARK_DIR"

# Initialize git repo
git init -q
git config user.email "bench@bench.com"
git config user.name "Benchmark"

# Create some files and commits
for i in {1..10}; do
    mkdir -p "dir_$i"
    for j in {1..5}; do
        echo "Content $i-$j" > "dir_$i/file_$j.txt"
    done
done

echo '{"name": "test", "version": "1.0.0"}' > package.json
git add .
git commit -q -m "Initial commit"

# Make a few more commits with tags
for i in {2..5}; do
    echo "Update $i" >> package.json
    git add .
    git commit -q -m "Commit $i"
    if [ $i -eq 3 ]; then
        git tag -a "v1.0.0" -m "Version 1.0.0"
    fi
done

# Make working directory change
echo "modified" >> "dir_1/file_1.txt"

echo "Repository created with $(git rev-list --count HEAD) commits, $(git tag | wc -l) tags"

# Simple benchmark function
simple_benchmark() {
    local name="$1"
    local git_cmd="$2" 
    local ziggit_cmd="$3"
    
    echo "Benchmarking: $name"
    
    # Test that commands work first
    if ! git $git_cmd >/dev/null 2>&1; then
        echo "  ERROR: git $git_cmd failed"
        return
    fi
    
    if ! $ZIGGIT $ziggit_cmd >/dev/null 2>&1; then
        echo "  ERROR: ziggit $ziggit_cmd failed"
        return
    fi
    
    # Time git
    local git_total=0
    for i in $(seq 1 $ITERATIONS); do
        local start=$(date +%s%N)
        git $git_cmd >/dev/null 2>&1
        local end=$(date +%s%N)
        git_total=$((git_total + (end - start) / 1000000))
    done
    local git_avg=$((git_total / ITERATIONS))
    
    # Time ziggit
    local ziggit_total=0
    for i in $(seq 1 $ITERATIONS); do
        local start=$(date +%s%N)
        $ZIGGIT $ziggit_cmd >/dev/null 2>&1
        local end=$(date +%s%N)
        ziggit_total=$((ziggit_total + (end - start) / 1000000))
    done
    local ziggit_avg=$((ziggit_total / ITERATIONS))
    
    # Calculate speedup
    local speedup=$(awk "BEGIN {if($ziggit_avg > 0) printf \"%.2f\", $git_avg / $ziggit_avg; else print \"N/A\"}")
    
    printf "  %-25s | Git: %4dms | Ziggit: %4dms | Speedup: %6s\n" "$name" "$git_avg" "$ziggit_avg" "$speedup"
}

echo ""
echo "Running benchmarks ($ITERATIONS iterations each)..."
echo ""

simple_benchmark "status --porcelain" "status --porcelain" "status --porcelain"
simple_benchmark "rev-parse HEAD" "rev-parse HEAD" "rev-parse HEAD"
simple_benchmark "describe --tags --abbrev=0" "describe --tags --abbrev=0" "describe --tags --abbrev=0"
simple_benchmark "log --format=%H -1" "log --format=%H -1" "log --format=%H -1"

# Clean up
cd /
rm -rf "$BENCHMARK_DIR"