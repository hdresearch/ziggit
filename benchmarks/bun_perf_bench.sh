#!/bin/bash

set -e

# Configuration
ZIGGIT=/root/ziggit/zig-out/bin/ziggit
ITERATIONS=500
WARMUP_ITERATIONS=10
BENCHMARK_DIR="/tmp/ziggit_benchmark_$$"

echo "Creating realistic test repository for bun performance benchmarks..."

# Clean up any existing benchmark directory
rm -rf "$BENCHMARK_DIR"
mkdir -p "$BENCHMARK_DIR"
cd "$BENCHMARK_DIR"

# Initialize git repo
git init -q
git config user.email "bench@bench.com"
git config user.name "Benchmark"

# Create realistic directory structure with 500 files across 20 subdirectories (as required)
echo "Creating 500 files across 20 subdirectories..."
for i in {1..20}; do
    mkdir -p "dir_$i"
    for j in {1..25}; do
        echo "Content for file $j in directory $i" > "dir_$i/file_$j.txt"
    done
done

# Create package.json, README, and other typical files
echo '{"name": "bun-test-repo", "version": "1.0.0", "dependencies": {}}' > package.json
echo "# Test Repository" > README.md
echo "node_modules/" > .gitignore
echo "*.tmp" >> .gitignore
echo ".env" >> .gitignore

echo "Creating 50 commits with 5 tags..."

# First commit
git add .
git commit -q -m "Initial commit with 500 files"

# Make 49 more commits with changes (50 total)
for commit in {2..50}; do
    # Modify some existing files
    echo "Updated in commit $commit at $(date)" >> "dir_1/file_1.txt"
    echo "Commit $commit update" >> "README.md"
    
    # Occasionally add new files
    if [ $((commit % 5)) -eq 0 ]; then
        echo "New file from commit $commit" > "dir_1/new_file_$commit.txt"
    fi
    
    git add .
    git commit -q -m "Commit $commit: updates and changes"
    
    # Add 5 tags total at different commits
    case $commit in
        10) git tag -a "v1.0.0" -m "Version 1.0.0" ;;
        20) git tag -a "v1.1.0" -m "Version 1.1.0" ;;
        30) git tag -a "v1.2.0" -m "Version 1.2.0" ;;
        40) git tag -a "v2.0.0" -m "Version 2.0.0" ;;
        50) git tag -a "v2.1.0" -m "Version 2.1.0" ;;
    esac
done

# Make some working directory changes to test status --porcelain
echo "Working directory modifications" >> "dir_1/file_1.txt"
echo "New untracked file" > "untracked.txt"
echo "Another change" >> "README.md"

echo "Repository created with $(git rev-list --count HEAD) commits, $(git tag | wc -l) tags, $(find . -type f ! -path './.git/*' | wc -l) files"

# Function to run warmup iterations
warmup() {
    local cmd="$1"
    local iterations="$2"
    
    for i in $(seq 1 $iterations); do
        eval "$cmd" >/dev/null 2>&1
    done
}

# Function to calculate statistics
calculate_stats() {
    local -n arr=$1
    local count=${#arr[@]}
    
    # Sort array
    IFS=$'\n' arr=($(sort -n <<<"${arr[*]}"))
    
    # Calculate min, median, p95, p99
    local min=${arr[0]}
    local median=${arr[$((count/2))]}
    local p95=${arr[$((count * 95 / 100))]}
    local p99=${arr[$((count * 99 / 100))]}
    
    echo "$min $median $p95 $p99"
}

# Benchmark function
benchmark_command() {
    local cmd_name="$1"
    local git_cmd="$2"
    local ziggit_cmd="$3"
    
    echo "Benchmarking: $cmd_name"
    
    # Arrays to store timing results (in milliseconds)
    declare -a git_times
    declare -a ziggit_times
    
    # Warmup git command
    echo "  Warming up git $git_cmd ($WARMUP_ITERATIONS iterations)..."
    warmup "git $git_cmd" "$WARMUP_ITERATIONS"
    
    # Warmup ziggit command  
    echo "  Warming up ziggit $ziggit_cmd ($WARMUP_ITERATIONS iterations)..."
    warmup "$ZIGGIT $ziggit_cmd" "$WARMUP_ITERATIONS"
    
    # Benchmark git command
    echo "  Benchmarking git $git_cmd ($ITERATIONS iterations)..."
    for i in $(seq 1 $ITERATIONS); do
        start_ns=$(date +%s%N)
        if git $git_cmd >/dev/null 2>&1; then
            end_ns=$(date +%s%N)
            duration_ms=$(( (end_ns - start_ns) / 1000000 ))
            git_times+=($duration_ms)
        else
            echo "    git command failed on iteration $i"
        fi
    done
    
    # Benchmark ziggit command
    echo "  Benchmarking ziggit $ziggit_cmd ($ITERATIONS iterations)..."
    for i in $(seq 1 $ITERATIONS); do
        start_ns=$(date +%s%N)
        if $ZIGGIT $ziggit_cmd >/dev/null 2>&1; then
            end_ns=$(date +%s%N)
            duration_ms=$(( (end_ns - start_ns) / 1000000 ))
            ziggit_times+=($duration_ms)
        else
            echo "    ziggit command failed on iteration $i"
        fi
    done
    
    # Calculate statistics
    if [ ${#git_times[@]} -eq 0 ] || [ ${#ziggit_times[@]} -eq 0 ]; then
        echo "  ERROR: No successful runs for $cmd_name"
        return
    fi
    
    local git_stats=($(calculate_stats git_times))
    local ziggit_stats=($(calculate_stats ziggit_times))
    
    local git_min=${git_stats[0]}
    local git_median=${git_stats[1]} 
    local git_p95=${git_stats[2]}
    local git_p99=${git_stats[3]}
    
    local ziggit_min=${ziggit_stats[0]}
    local ziggit_median=${ziggit_stats[1]}
    local ziggit_p95=${ziggit_stats[2]}
    local ziggit_p99=${ziggit_stats[3]}
    
    # Calculate speedup ratios
    local speedup_median=$(awk "BEGIN {if($ziggit_median > 0) printf \"%.2f\", $git_median / $ziggit_median; else print \"N/A\"}")
    local speedup_p99=$(awk "BEGIN {if($ziggit_p99 > 0) printf \"%.2f\", $git_p99 / $ziggit_p99; else print \"N/A\"}")
    
    # Output results table
    printf "%-30s | %4dms %4dms %4dms %4dms | %4dms %4dms %4dms %4dms | %6s %6s\n" \
        "$cmd_name" \
        "$git_min" "$git_median" "$git_p95" "$git_p99" \
        "$ziggit_min" "$ziggit_median" "$ziggit_p95" "$ziggit_p99" \
        "$speedup_median" "$speedup_p99"
    
    # Store detailed results in CSV format for analysis
    echo "$cmd_name,git,$git_min,$git_median,$git_p95,$git_p99" >> /root/ziggit/benchmarks/raw_timings.csv
    echo "$cmd_name,ziggit,$ziggit_min,$ziggit_median,$ziggit_p95,$ziggit_p99" >> /root/ziggit/benchmarks/raw_timings.csv
}

# Initialize results
echo "Command,Tool,Min_ms,Median_ms,P95_ms,P99_ms" > /root/ziggit/benchmarks/raw_timings.csv

echo ""
echo "Running bun hot-path performance benchmarks..."
echo "Repository: $BENCHMARK_DIR"
echo "Iterations: $ITERATIONS (with $WARMUP_ITERATIONS warmup iterations)"
echo ""
printf "%-30s | %-19s | %-19s | %-13s\n" "Command" "Git (min/med/p95/p99)" "Ziggit (min/med/p95/p99)" "Speedup (med/p99)"
printf "%-30s-+-%-19s-+-%-19s-+-%-13s\n" "------------------------------" "-------------------" "-------------------" "-------------"

# Run benchmarks for the bun hot-path commands
benchmark_command "status --porcelain" "status --porcelain" "status --porcelain"
benchmark_command "rev-parse HEAD" "rev-parse HEAD" "rev-parse HEAD"  
benchmark_command "describe --tags --abbrev=0" "describe --tags --abbrev=0" "describe --tags --abbrev=0"
benchmark_command "log --format=%H -1" "log --format=%H -1" "log --format=%H -1"

echo ""
echo "Benchmark completed!"
echo "Raw timing data saved to: benchmarks/raw_timings.csv"
echo ""

# Show summary from CSV
echo "Summary comparison:"
echo "Command,Git_median,Ziggit_median,Speedup" 
while IFS=',' read -r cmd tool min med p95 p99; do
    if [[ "$tool" == "git" ]] && [[ "$cmd" != "Command" ]]; then
        git_med=$med
        # Read next line for ziggit
        IFS=',' read -r zcmd ztool zmin zmed zp95 zp99
        if [[ "$zcmd" == "$cmd" ]] && [[ "$ztool" == "ziggit" ]]; then
            speedup=$(awk "BEGIN {if($zmed > 0) printf \"%.2f\", $git_med / $zmed; else print \"N/A\"}")
            echo "$cmd,${git_med}ms,${zmed}ms,${speedup}x"
        fi
    fi
done < /root/ziggit/benchmarks/raw_timings.csv

# Clean up
cd /
rm -rf "$BENCHMARK_DIR"