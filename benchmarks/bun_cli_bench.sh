#!/bin/bash

set -e

# Configuration
ZIGGIT=/root/ziggit/zig-out/bin/ziggit
ITERATIONS=1000
BENCHMARK_DIR="/tmp/ziggit_benchmark_$$"

echo "Creating realistic test repository..."

# Clean up any existing benchmark directory
rm -rf "$BENCHMARK_DIR"
mkdir -p "$BENCHMARK_DIR"
cd "$BENCHMARK_DIR"

# Initialize git repo
git init -q
git config user.email "bench@bench.com"
git config user.name "Benchmark"

# Create realistic directory structure with 100+ files
echo "Creating 100+ files across subdirectories..."
mkdir -p src/{lib,tests,examples} docs/{api,guides} scripts tools

# Generate files with some content
for i in {1..30}; do
    echo "function example_$i() { return $i; }" > "src/lib/module_$i.js"
    echo "test('test_$i', () => { expect(example_$i()).toBe($i); });" > "src/tests/test_$i.js"
    echo "# Example $i" > "docs/api/example_$i.md"
done

for i in {1..25}; do
    echo "#!/bin/bash" > "scripts/script_$i.sh"
    echo "echo 'Script $i executed'" >> "scripts/script_$i.sh"
    chmod +x "scripts/script_$i.sh"
done

for i in {1..20}; do
    echo "# Tool $i configuration" > "tools/tool_$i.conf"
    echo "param1=value$i" >> "tools/tool_$i.conf"
done

for i in {1..30}; do
    echo "# Guide $i: How to use feature $i" > "docs/guides/guide_$i.md"
    echo "This is the documentation for feature $i." >> "docs/guides/guide_$i.md"
done

# Create some additional files
echo '{"name": "benchmark-repo", "version": "1.0.0"}' > package.json
echo "# Benchmark Repository" > README.md
echo "node_modules/" > .gitignore
echo "*.tmp" >> .gitignore

echo "Creating 10+ commits with tags..."

# First commit
git add .
git commit -q -m "Initial commit with project structure"
git tag -a v0.1.0 -m "Initial version"

# Make several commits with changes
for commit in {2..12}; do
    # Modify some files
    echo "// Updated in commit $commit" >> "src/lib/module_1.js"
    echo "Updated: $(date)" >> "README.md"
    
    # Add some new files
    echo "New feature $commit" > "src/lib/feature_$commit.js"
    echo "Test for feature $commit" > "src/tests/feature_test_$commit.js"
    
    git add .
    git commit -q -m "Commit $commit: Added feature $commit and updates"
    
    # Add tags for some commits
    if [ $((commit % 3)) -eq 0 ]; then
        git tag -a "v0.$commit.0" -m "Version 0.$commit.0"
    fi
done

# Make some working directory changes for status testing
echo "// Working directory changes" >> "src/lib/module_1.js"
echo "New file for status test" > "new_file.txt"

echo "Repository created with $(git rev-list --count HEAD) commits, $(git tag | wc -l) tags, $(find . -type f ! -path './.git/*' | wc -l) files"

# Benchmark function
benchmark_command() {
    local cmd_name="$1"
    local git_cmd="$2"
    local ziggit_cmd="$3"
    
    echo "Benchmarking: $cmd_name"
    
    # Arrays to store timing results (in nanoseconds)
    declare -a git_times
    declare -a ziggit_times
    
    # Benchmark git command
    echo "  Running git $git_cmd ($ITERATIONS iterations)..."
    for i in $(seq 1 $ITERATIONS); do
        start_ns=$(date +%s%N)
        eval "git $git_cmd" >/dev/null 2>&1
        end_ns=$(date +%s%N)
        duration=$((end_ns - start_ns))
        git_times+=($duration)
    done
    
    # Benchmark ziggit command
    echo "  Running ziggit $ziggit_cmd ($ITERATIONS iterations)..."
    for i in $(seq 1 $ITERATIONS); do
        start_ns=$(date +%s%N)
        eval "$ZIGGIT $ziggit_cmd" >/dev/null 2>&1
        end_ns=$(date +%s%N)
        duration=$((end_ns - start_ns))
        ziggit_times+=($duration)
    done
    
    # Sort arrays for percentile calculation
    IFS=$'\n' git_times=($(sort -n <<<"${git_times[*]}"))
    IFS=$'\n' ziggit_times=($(sort -n <<<"${ziggit_times[*]}"))
    
    # Calculate median (50th percentile)
    git_median=${git_times[$((ITERATIONS/2))]}
    ziggit_median=${ziggit_times[$((ITERATIONS/2))]}
    
    # Calculate 99th percentile
    p99_index=$((ITERATIONS * 99 / 100))
    git_p99=${git_times[$p99_index]}
    ziggit_p99=${ziggit_times[$p99_index]}
    
    # Calculate speedup ratio (git_time / ziggit_time)
    speedup_median=$(awk "BEGIN {printf \"%.2f\", $git_median / $ziggit_median}")
    speedup_p99=$(awk "BEGIN {printf \"%.2f\", $git_p99 / $ziggit_p99}")
    
    # Convert nanoseconds to milliseconds for readability
    git_median_ms=$(awk "BEGIN {printf \"%.3f\", $git_median / 1000000}")
    ziggit_median_ms=$(awk "BEGIN {printf \"%.3f\", $ziggit_median / 1000000}")
    git_p99_ms=$(awk "BEGIN {printf \"%.3f\", $git_p99 / 1000000}")
    ziggit_p99_ms=$(awk "BEGIN {printf \"%.3f\", $ziggit_p99 / 1000000}")
    
    # Output results
    printf "%-30s | git: %8.3fms/%8.3fms | ziggit: %8.3fms/%8.3fms | speedup: %5.2fx/%5.2fx\n" \
        "$cmd_name" "$git_median_ms" "$git_p99_ms" "$ziggit_median_ms" "$ziggit_p99_ms" "$speedup_median" "$speedup_p99"
    
    # Store detailed results
    echo "=== $cmd_name ===" >> /root/ziggit/benchmarks/results.txt
    echo "Git median: ${git_median_ms}ms, p99: ${git_p99_ms}ms" >> /root/ziggit/benchmarks/results.txt
    echo "Ziggit median: ${ziggit_median_ms}ms, p99: ${ziggit_p99_ms}ms" >> /root/ziggit/benchmarks/results.txt
    echo "Speedup median: ${speedup_median}x, p99: ${speedup_p99}x" >> /root/ziggit/benchmarks/results.txt
    echo "" >> /root/ziggit/benchmarks/results.txt
}

# Clear previous results
echo "Ziggit vs Git Benchmark Results" > /root/ziggit/benchmarks/results.txt
echo "Generated: $(date)" >> /root/ziggit/benchmarks/results.txt
echo "Repository: $BENCHMARK_DIR" >> /root/ziggit/benchmarks/results.txt
echo "Iterations: $ITERATIONS" >> /root/ziggit/benchmarks/results.txt
echo "" >> /root/ziggit/benchmarks/results.txt

echo ""
echo "Running benchmarks..."
printf "%-30s | %-21s | %-21s | %-13s\n" "Command" "Git (median/p99)" "Ziggit (median/p99)" "Speedup (med/p99)"
printf "%-30s-+-%-21s-+-%-21s-+-%-13s\n" "------------------------------" "---------------------" "---------------------" "-------------"

# Run benchmarks
benchmark_command "status --porcelain" "status --porcelain" "status --porcelain"
benchmark_command "rev-parse HEAD" "rev-parse HEAD" "rev-parse HEAD"
benchmark_command "describe --tags --abbrev=0" "describe --tags --abbrev=0" "describe --tags --abbrev=0"
benchmark_command "log --format=%H -1" "log --format=%H -1" "log --format=%H -1"

echo ""
echo "Benchmark completed! Results saved to benchmarks/results.txt"

# Clean up
cd /
rm -rf "$BENCHMARK_DIR"