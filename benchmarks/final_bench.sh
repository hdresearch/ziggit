#!/bin/bash

ZIGGIT=/root/ziggit/zig-out/bin/ziggit
ITERATIONS=500
BENCHMARK_DIR="/tmp/final_benchmark_$$"

echo "=== ZIGGIT vs GIT FINAL BENCHMARK ==="
echo "Testing bun's most-used git commands with optimized ziggit (ReleaseFast build)"
echo ""

# Create realistic test repository
rm -rf "$BENCHMARK_DIR"
mkdir -p "$BENCHMARK_DIR"
cd "$BENCHMARK_DIR"

git init -q
git config user.email "bench@bench.com"
git config user.name "Benchmark"

# Create 500 files across 20 subdirectories
echo "Creating 500 files across 20 subdirectories..."
for i in {1..20}; do
    mkdir -p "dir_$i"
    for j in {1..25}; do
        echo "Content for file $j in directory $i - $(date)" > "dir_$i/file_$j.txt"
    done
done

echo '{"name": "bun-test-repo", "version": "1.0.0"}' > package.json
echo "# Test Repository" > README.md
echo "node_modules/" > .gitignore

git add .
git commit -q -m "Initial commit with 500+ files"

# Create 50 commits with 5 tags
echo "Creating 50 commits with 5 tags..."
for i in {2..50}; do
    echo "Update $i at $(date)" >> README.md
    if [ $((i % 10)) -eq 0 ]; then
        echo "New feature $i" > "dir_1/feature_$i.txt"
    fi
    git add .
    git commit -q -m "Commit $i: updates"
    
    case $i in
        10) git tag -a "v1.0.0" -m "Version 1.0.0" ;;
        20) git tag -a "v1.1.0" -m "Version 1.1.0" ;;
        30) git tag -a "v1.2.0" -m "Version 1.2.0" ;;
        40) git tag -a "v2.0.0" -m "Version 2.0.0" ;;
        50) git tag -a "v2.1.0" -m "Version 2.1.0" ;;
    esac
done

echo "Repository: $(git rev-list --count HEAD) commits, $(git tag | wc -l) tags, $(find . -type f ! -path './.git/*' | wc -l) files"

# Benchmark function with more detailed statistics
benchmark_detailed() {
    local name="$1"
    local git_cmd="$2" 
    local ziggit_cmd="$3"
    local scenario="$4"
    
    echo ""
    echo "=== $scenario ==="
    echo "Command: $name"
    
    # Verify commands work
    if ! git $git_cmd >/dev/null 2>&1; then
        echo "ERROR: git $git_cmd failed"
        return
    fi
    
    if ! $ZIGGIT $ziggit_cmd >/dev/null 2>&1; then
        echo "ERROR: ziggit $ziggit_cmd failed"  
        return
    fi
    
    # Warmup
    for i in {1..10}; do
        git $git_cmd >/dev/null 2>&1
        $ZIGGIT $ziggit_cmd >/dev/null 2>&1
    done
    
    # Time git
    declare -a git_times
    for i in $(seq 1 $ITERATIONS); do
        local start=$(date +%s%N)
        git $git_cmd >/dev/null 2>&1
        local end=$(date +%s%N)
        git_times+=($(((end - start) / 1000000)))
    done
    
    # Time ziggit
    declare -a ziggit_times
    for i in $(seq 1 $ITERATIONS); do
        local start=$(date +%s%N)
        $ZIGGIT $ziggit_cmd >/dev/null 2>&1
        local end=$(date +%s%N)
        ziggit_times+=($(((end - start) / 1000000)))
    done
    
    # Sort arrays for percentile calculation
    IFS=$'\n' git_times=($(sort -n <<<"${git_times[*]}"))
    IFS=$'\n' ziggit_times=($(sort -n <<<"${ziggit_times[*]}"))
    
    # Calculate statistics
    local git_min=${git_times[0]}
    local git_median=${git_times[$((ITERATIONS/2))]}
    local git_p95=${git_times[$((ITERATIONS * 95 / 100))]}
    local git_p99=${git_times[$((ITERATIONS * 99 / 100))]}
    
    local ziggit_min=${ziggit_times[0]}
    local ziggit_median=${ziggit_times[$((ITERATIONS/2))]}
    local ziggit_p95=${ziggit_times[$((ITERATIONS * 95 / 100))]}
    local ziggit_p99=${ziggit_times[$((ITERATIONS * 99 / 100))]}
    
    # Calculate speedup
    local speedup=$(awk "BEGIN {if($ziggit_median > 0) printf \"%.2f\", $git_median / $ziggit_median; else print \"N/A\"}")
    
    echo "Git:    min=${git_min}ms, median=${git_median}ms, p95=${git_p95}ms, p99=${git_p99}ms"
    echo "Ziggit: min=${ziggit_min}ms, median=${ziggit_median}ms, p95=${ziggit_p95}ms, p99=${ziggit_p99}ms"
    echo "Speedup: ${speedup}x (based on median)"
    
    # Save to CSV
    echo "$scenario,$name,git,$git_min,$git_median,$git_p95,$git_p99" >> /root/ziggit/benchmarks/final_results.csv
    echo "$scenario,$name,ziggit,$ziggit_min,$ziggit_median,$ziggit_p95,$ziggit_p99" >> /root/ziggit/benchmarks/final_results.csv
}

# Initialize results file
echo "Scenario,Command,Tool,Min_ms,Median_ms,P95_ms,P99_ms" > /root/ziggit/benchmarks/final_results.csv

echo ""
echo "Running comprehensive benchmarks ($ITERATIONS iterations each)..."

# Test 1: Clean repository (fast path scenario)
benchmark_detailed "status --porcelain" "status --porcelain" "status --porcelain" "Clean Repository"
benchmark_detailed "rev-parse HEAD" "rev-parse HEAD" "rev-parse HEAD" "Clean Repository"
benchmark_detailed "describe --tags --abbrev=0" "describe --tags --abbrev=0" "describe --tags --abbrev=0" "Clean Repository"
benchmark_detailed "log --format=%H -1" "log --format=%H -1" "log --format=%H -1" "Clean Repository"

# Test 2: Dirty repository (realistic bun scenario)  
echo ""
echo "Modifying files for dirty repository scenario..."
echo "Working changes for testing" >> "dir_1/file_1.txt"
echo "More changes" >> "dir_2/file_2.txt"
echo "New untracked file" > "untracked.txt"

benchmark_detailed "status --porcelain" "status --porcelain" "status --porcelain" "Dirty Repository"

echo ""
echo "=== FINAL SUMMARY ==="
echo ""

# Print summary table
printf "%-20s %-30s %-15s %-15s %-10s\n" "Scenario" "Command" "Git (median)" "Ziggit (median)" "Speedup"
printf "%-20s %-30s %-15s %-15s %-10s\n" "--------------------" "------------------------------" "---------------" "---------------" "----------"

while IFS=',' read -r scenario cmd tool min med p95 p99; do
    if [[ "$tool" == "git" ]] && [[ "$scenario" != "Scenario" ]]; then
        git_med=$med
        # Read next line for ziggit
        IFS=',' read -r zscenario zcmd ztool zmin zmed zp95 zp99
        if [[ "$zcmd" == "$cmd" ]] && [[ "$ztool" == "ziggit" ]]; then
            speedup=$(awk "BEGIN {if($zmed > 0) printf \"%.2f\", $git_med / $zmed; else print \"N/A\"}")
            printf "%-20s %-30s %-15s %-15s %-10s\n" "$scenario" "$cmd" "${git_med}ms" "${zmed}ms" "${speedup}x"
        fi
    fi
done < /root/ziggit/benchmarks/final_results.csv

echo ""
echo "Full results saved to: benchmarks/final_results.csv"

# Clean up
cd /
rm -rf "$BENCHMARK_DIR"