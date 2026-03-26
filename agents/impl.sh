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
- Do NOT touch src/lib/ziggit.zig — another agent owns that file.
- Do NOT touch src/main_common.zig — another agent owns that file.
- You work on: src/git/*.zig files (objects.zig, index.zig, refs.zig, diff.zig, repository.zig, gitignore.zig)
- You may also create NEW files in src/git/ (e.g. src/git/config.zig, src/git/pack.zig, src/git/tree.zig)
- You may work on build.zig and test/ files.

YOUR TASK: Strengthen the core git format implementations that the library and CLI both depend on.

Priority order:
1. **src/git/objects.zig — pack file reading**: The loadFromPackFiles() function exists but is incomplete. Implement proper pack index v2 (.idx) parsing and pack file (.pack) object extraction. This is critical because any cloned repo or repo after "git gc" uses pack files. You need:
   - Parse .idx fanout table, SHA-1 table, offset table
   - Read objects from .pack by offset
   - Handle OBJ_OFS_DELTA and OBJ_REF_DELTA types (apply delta to base object)
   - Test by creating a repo, running "git gc", then reading objects through pack files

2. **src/git/config.zig (NEW)**: Create a git config parser that reads .git/config INI format. Must support:
   - [remote "origin"] url = ... 
   - [branch "master"] remote = origin
   - [user] name = ..., email = ...
   This is needed because the library ziggit_remote_get_url() currently returns a placeholder.

3. **src/git/index.zig — improve binary format**: The current index parser works for basic cases. Add:
   - Support for index extensions (TREE, REUC, etc.) — at minimum, skip them without crashing
   - Handle index v3 and v4 (bun may encounter these)
   - Proper SHA-1 checksum verification of the index file

4. **src/git/refs.zig — symbolic ref resolution**: Improve ref resolution to handle:
   - Nested symbolic refs
   - Annotated tags (tag object → commit)
   - refs/remotes/ for tracking branches

Write tests in test/ for each improvement. Run "zig build test" after every change.

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
        git add -A && git commit -m "agent: auto-commit git format work" 2>> /root/agent.log || true
        git push origin master 2>> /root/agent.log || true
    fi
    sleep 10
done
