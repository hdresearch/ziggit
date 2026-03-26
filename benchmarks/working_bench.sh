#!/bin/bash

set -e

ZIGGIT=/root/ziggit/zig-out/bin/ziggit
ITERATIONS=1000
BENCHMARK_DIR="/tmp/ziggit_working_benchmark"

echo "Creating test repository..."
rm -rf "$BENCHMARK_DIR"
mkdir -p "$BENCHMARK_DIR"
cd "$BENCHMARK_DIR"

git init -q
git config user.email "bench@bench.com"
git config user.name "Benchmark"

# Create 100+ files
mkdir -p src docs scripts
for i in {1..50}; do
    echo "content $i" > "src/file_$i.js"
    echo "doc $i" > "docs/doc_$i.md"
done

for i in {1..20}; do
    echo "#!/bin/bash" > "scripts/script_$i.sh"
    echo "echo script $i" >> "scripts/script_$i.sh"
done

echo '{"name": "bench"}' > package.json
echo "# Benchmark Repo" > README.md

# Create 10+ commits
git add .
git commit -q -m "Initial commit"
git tag -a v1.0.0 -m "v1.0.0"

for i in {2..12}; do
    echo "update $i" >> "README.md"
    echo "new feature $i" > "src/new_$i.js"
    git add .
    git commit -q -m "Commit $i"
    if [ $((i % 3)) -eq 0 ]; then
        git tag -a "v1.$i.0" -m "Version 1.$i.0"
    fi
done

echo "Working dir change" >> "README.md"
echo "new file" > "new_file.txt"

echo "Repository created with $(git rev-list --count HEAD) commits, $(git tag | wc -l) tags, $(find . -type f ! -path './.git/*' | wc -l) files"

# Simple benchmark function
run_benchmark() {
    local name="$1"
    local cmd="$2"
    local iterations="$3"
    
    echo "Benchmarking $name..."
    
    # Time git
    start=$(date +%s%N)
    for i in $(seq 1 $iterations); do
        eval "git $cmd" >/dev/null 2>&1
    done
    end=$(date +%s%N)
    git_total=$((end - start))
    git_avg=$((git_total / iterations))
    
    # Time ziggit
    start=$(date +%s%N)
    for i in $(seq 1 $iterations); do
        eval "$ZIGGIT $cmd" >/dev/null 2>&1
    done
    end=$(date +%s%N)
    ziggit_total=$((end - start))
    ziggit_avg=$((ziggit_total / iterations))
    
    # Calculate speedup
    speedup=$(awk "BEGIN {printf \"%.2f\", $git_avg / $ziggit_avg}")
    
    # Convert to milliseconds
    git_ms=$(awk "BEGIN {printf \"%.3f\", $git_avg / 1000000}")
    ziggit_ms=$(awk "BEGIN {printf \"%.3f\", $ziggit_avg / 1000000}")
    
    printf "%-30s | git: %8.3fms | ziggit: %8.3fms | speedup: %5.2fx\n" "$name" "$git_ms" "$ziggit_ms" "$speedup"
    
    # Save to results
    echo "$name: git=${git_ms}ms, ziggit=${ziggit_ms}ms, speedup=${speedup}x" >> /root/ziggit/benchmarks/results.txt
}

# Clear and initialize results file
echo "Ziggit vs Git Benchmark Results" > /root/ziggit/benchmarks/results.txt
echo "Generated: $(date)" >> /root/ziggit/benchmarks/results.txt
echo "Iterations: $ITERATIONS per command" >> /root/ziggit/benchmarks/results.txt
echo "" >> /root/ziggit/benchmarks/results.txt

echo ""
echo "Running benchmarks with $ITERATIONS iterations each..."
printf "%-30s | %-12s | %-12s | %-10s\n" "Command" "Git" "Ziggit" "Speedup"
printf "%-30s-+-%-12s-+-%-12s-+-%-10s\n" "------------------------------" "------------" "------------" "----------"

# Run benchmarks for the 4 required commands
run_benchmark "status --porcelain" "status --porcelain" $ITERATIONS
run_benchmark "rev-parse HEAD" "rev-parse HEAD" $ITERATIONS
run_benchmark "describe --tags --abbrev=0" "describe --tags --abbrev=0" $ITERATIONS
run_benchmark "log --format=%H -1" "log --format=%H -1" $ITERATIONS

echo ""
echo "Benchmark completed! Results saved to benchmarks/results.txt"

# Cleanup
cd /
rm -rf "$BENCHMARK_DIR"