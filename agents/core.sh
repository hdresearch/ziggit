#!/bin/bash
swapon /swapfile 2>/dev/null || true
export NODE_OPTIONS="--max-old-space-size=256"
export PATH="/usr/local/zig:/usr/local/bin:/usr/bin:/bin:$PATH"
cd /root/ziggit || exit 1

if ! grep -q 'zig-cache' .gitignore 2>/dev/null; then
    printf '.zig-cache/\nzig-out/\n*.o\n*.a\n' > .gitignore
    git add .gitignore
fi

GOAL='You are working on ziggit, a VCS in Zig. Repo: https://github.com/hdresearch/ziggit.git

CRITICAL RULES:
- Do NOT write reports, verification docs, or .md files. Only .zig code and tests.
- Do NOT touch src/lib/*.zig — another agent owns those files.
- Do NOT touch src/git/*.zig — another agent owns those files.
- Do NOT touch src/main_common.zig — another agent owns that file.
- You work on: src/platform/*.zig, build.zig, and test/ files for integration testing.
- You may also clean up: delete redundant benchmark files, consolidate tests, fix build targets.

YOUR TASK: Integration testing and build system maintenance.

1. Clean up benchmarks/ directory — there are 25+ benchmark files, many redundant. Consolidate into at most 3:
   - benchmarks/cli_benchmark.zig — times ziggit CLI vs git CLI
   - benchmarks/lib_benchmark.zig — times ziggit library calls 
   - benchmarks/bun_scenario_bench.zig — simulates bun workflow
   Delete all other benchmark files.

2. Write integration tests in test/ that run BOTH git and ziggit on the same repo and compare output:
   - test/git_interop_test.zig — already exists, improve it
   - Tests must create a repo with git, then verify ziggit reads it correctly
   - Tests must create a repo with ziggit, then verify git reads it correctly
   - Cover: init, add, commit, status --porcelain, log --oneline, branch, diff, checkout

3. Fix build.zig to have clean targets:
   - "zig build" — builds ziggit CLI
   - "zig build lib" — builds libziggit.a + ziggit.h  
   - "zig build test" — runs unit tests
   - "zig build bench" — runs benchmarks
   - "zig build wasm" — WASM target
   Remove duplicate/broken build targets.

4. Fix the BrokenPipe error in src/platform/native.zig when output is piped to head/less.

Run "zig build" and "zig build test" after every change.

IMPORTANT: Commit and push:
  git add -A && git commit -m "<describe>" && git pull --rebase origin master && git push origin master'

while true; do
    echo "$(date): Starting pi agent run..." >> /root/agent.log
    pi -p "$GOAL" --model anthropic/claude-sonnet-4-20250514 --no-session >> /root/agent.log 2>&1
    EXIT=$?
    echo "$(date): Agent run completed (exit=$EXIT)" >> /root/agent.log
    cd /root/ziggit
    git pull --rebase origin master 2>> /root/agent.log || { git rebase --abort 2>/dev/null; git reset --hard origin/master; }
    if [ -n "$(git status --porcelain)" ]; then
        git add -A && git commit -m "agent: auto-commit integration/build work" 2>> /root/agent.log || true
        git push origin master 2>> /root/agent.log || true
    fi
    sleep 10
done
