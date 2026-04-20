#!/bin/bash
swapon /swapfile 2>/dev/null || true
export NODE_OPTIONS="--max-old-space-size=256"
export PATH="/usr/local/zig:/usr/local/bin:/usr/bin:/bin:$PATH"
cd /root/ziggit || exit 1

GOAL='You are working on ziggit, a version control system in Zig at /root/ziggit (repo: https://github.com/hdresearch/ziggit.git). Your job is benchmarking and performance optimization.

CRITICAL RULES:
- Do NOT write markdown reports or verification docs. Only .zig code, .sh scripts, and benchmark result files.
- Do NOT fabricate benchmark numbers. Every number must be from an actual measured run.
- Run "zig build" after every change.
- Commit and push after each milestone.
- IMPORTANT: Another agent is adding a git CLI fallback that forwards unknown commands to git. This DOES NOT COUNT as a native implementation. When you benchmark ziggit, you must benchmark the PURE ZIG code paths — direct Zig function calls that do NOT spawn any external process. If a code path spawns "git" as a child process, it is NOT a valid benchmark of ziggit performance. Your benchmarks must verify that the measured code path is pure Zig (no std.process.Child, no runGitCommand).

CONTEXT: ziggit is being built as a Zig package that bun can @import directly. The key advantage over libgit2 (C) and git CLI is: pure Zig means zero FFI overhead, zero process spawn overhead, and the Zig compiler can optimize across the call boundary.

There should be a public Zig API at src/ziggit.zig (another agent is creating it). If it exists, benchmark it. If not, benchmark the internal functions directly by importing from src/lib/ziggit.zig or src/git/*.zig.

YOUR TASK:

PHASE 1: Benchmark ziggit Zig function calls vs git CLI spawning.
Create benchmarks/api_vs_cli_bench.zig:
- Set up a test repo with git (100 files, 10 commits, tags)
- For each bun-critical operation, measure both:
  A) Direct Zig function call (import and call the function)
  B) Spawning "git <command>" as a child process
- Operations to benchmark:
  1. rev-parse HEAD: read .git/HEAD + follow ref (should be ~microseconds as Zig, ~milliseconds as CLI spawn)
  2. status --porcelain: read index + stat files
  3. describe --tags: walk commit chain to find tag
  4. is_clean: check if status is empty
- Run 1000 iterations of each, measure wall clock with std.time.nanoTimestamp()
- Compute min, median, mean, p95, p99
- Print results as a table
- Also measure with -Doptimize=ReleaseFast

Add this to build.zig as a "bench" target.

PHASE 2: Optimize hot paths.
Based on benchmark results, optimize:
- rev-parse HEAD should be 2 file reads (HEAD + ref). If it is doing more, eliminate the overhead.
- status --porcelain: use index mtime/size as fast path to skip SHA-1 computation. Only hash file content if stat differs.
- describe --tags: cache tag-to-commit resolution instead of re-reading objects each time.

For each optimization:
1. Measure before with the benchmark
2. Make the change
3. Measure after
4. Commit with actual measured numbers: "Optimize X: Yus -> Zus (N% faster)"

PHASE 3: Build release and measure.
Build with: zig build -Doptimize=ReleaseFast
Run all benchmarks again.
Commit results showing debug vs release performance.

The goal metric: prove that calling ziggit Zig functions is 100-1000x faster than spawning git CLI (because you eliminate ~2-5ms of process spawn overhead per call, vs ~1-50us for a direct function call).'

while true; do
    echo "$(date): Starting pi agent run..." >> /root/agent.log
    pi -p "$GOAL" --model anthropic/claude-sonnet-4-20250514 --no-session >> /root/agent.log 2>&1
    EXIT=$?
    echo "$(date): Agent run completed (exit=$EXIT)" >> /root/agent.log
    cd /root/ziggit
    git pull --rebase origin master 2>> /root/agent.log || { git rebase --abort 2>/dev/null; git reset --hard origin/master; }
    if [ -n "$(git status --porcelain)" ]; then
        git add -A && git commit -m "agent: auto-commit perf work" 2>> /root/agent.log || true
        git push origin master 2>> /root/agent.log || true
    fi
    sleep 10
done
