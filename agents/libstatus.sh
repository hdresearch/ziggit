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
- Do NOT touch src/main_common.zig — another agent owns that file.
- You ONLY work on: src/lib/ziggit.zig, src/lib/index_parser.zig, src/lib/objects_parser.zig
- Do NOT touch any file outside src/lib/ except build.zig and test/ files.

YOUR SOLE TASK: Make the library function getStatusPorcelainReal() in src/lib/ziggit.zig produce CORRECT output.

The CLI (main_common.zig) already works — "ziggit status --porcelain" matches git output. But the LIBRARY version (used via C API ziggit_status_porcelain) is BROKEN. It returns empty for repos with HEAD+index.

The problem is at approximately line 991-1015 in src/lib/ziggit.zig. The function hits this code path:
  if (head_commit_exists and index_exists) {
      // For now, return empty status (clean repository)
  }

This must be replaced with REAL logic:
1. Load the git index using index_parser.GitIndex.readFromFile()
2. For each index entry, call isFileModifiedAgainstIndex() (which already exists in the file and works)
3. For modified files, output " M path\n"  
4. For deleted files (in index but not on disk), output " D path\n"
5. Scan working directory for files NOT in the index, output "?? path\n"
6. For staged changes (index differs from HEAD tree), output "M  path\n" or "A  path\n"
7. Respect .gitignore for untracked files

The helper functions isFileModifiedAgainstIndex(), loadGitIndex(), IndexFileInfo already exist in the file. Wire them into getStatusPorcelainReal().

Also fix isFileModifiedReal() which currently has "For now, assume files are not modified for performance" — make it call isFileModifiedAgainstIndex() properly.

TEST: Write test/lib_status_test.zig that:
- Creates a repo with "git init && git add && git commit"
- Modifies a file, adds a new file, deletes a file
- Calls the library ziggit_status_porcelain via Zig import
- Compares output to "git status --porcelain"
- FAILS if they differ

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
        git add -A && git commit -m "agent: auto-commit lib status work" 2>> /root/agent.log || true
        git push origin master 2>> /root/agent.log || true
    fi
    sleep 10
done
