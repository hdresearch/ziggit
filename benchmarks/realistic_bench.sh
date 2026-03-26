#!/bin/bash

ZIGGIT=/root/ziggit/zig-out/bin/ziggit
ITERATIONS=100
BENCHMARK_DIR="/tmp/realistic_benchmark_$$"

echo "Creating realistic test repository..."

# Clean up and create directory
rm -rf "$BENCHMARK_DIR"
mkdir -p "$BENCHMARK_DIR"
cd "$BENCHMARK_DIR"

# Initialize git repo
git init -q
git config user.email "bench@bench.com"
git config user.name "Benchmark"

# Create 500 files across 20 subdirectories (like bun would have)
echo "Creating 500 files across 20 subdirectories..."
for i in {1..20}; do
    mkdir -p "dir_$i"
    for j in {1..25}; do
        echo "Content for file $j in directory $i" > "dir_$i/file_$j.txt"
    done
done

echo '{"name": "bun-test-repo", "version": "1.0.0"}' > package.json
git add .
git commit -q -m "Initial commit"

# Add some more commits with tags
for i in {2..5}; do
    echo "Update $i" >> package.json
    git add .
    git commit -q -m "Commit $i"
    if [ $i -eq 3 ]; then
        git tag -a "v1.0.0" -m "Version 1.0.0"
    fi
done

echo "Repository created with $(git rev-list --count HEAD) commits, $(git tag | wc -l) tags, $(find . -type f ! -path './.git/*' | wc -l) files"

# Benchmark function
benchmark() {
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
echo "Testing CLEAN repository (fast path should work)..."
echo ""

benchmark "status --porcelain (clean)" "status --porcelain" "status --porcelain"
benchmark "rev-parse HEAD" "rev-parse HEAD" "rev-parse HEAD"
benchmark "describe --tags --abbrev=0" "describe --tags --abbrev=0" "describe --tags --abbrev=0"
benchmark "log --format=%H -1" "log --format=%H -1" "log --format=%H -1"

# Now test with modifications (realistic bun scenario)
echo ""
echo "Testing with MODIFICATIONS (realistic bun workflow)..."
echo "Modifying a few files to simulate typical development..."
echo "working changes" >> "dir_1/file_1.txt"
echo "more changes" >> "dir_2/file_1.txt"
echo "new file for testing" > "new_file.txt"

echo ""
benchmark "status --porcelain (dirty)" "status --porcelain" "status --porcelain"

# Clean up
cd /
rm -rf "$BENCHMARK_DIR"