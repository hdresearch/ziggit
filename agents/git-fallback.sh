#!/bin/bash
swapon /swapfile 2>/dev/null || true
export NODE_OPTIONS="--max-old-space-size=256"
export PATH="/usr/local/zig:/usr/local/bin:/usr/bin:/bin:$PATH"
cd /root/ziggit || exit 1

GOAL="You are working on ziggit, a version control system in Zig at /root/ziggit (repo: https://github.com/hdresearch/ziggit.git).

GOAL: Make ziggit a LEGITIMATE drop-in replacement for git right now, today, even for commands not yet reimplemented in Zig. The strategy: for commands that have native Zig implementations, use them. For everything else, transparently forward to the real git CLI. The user should be able to alias git=ziggit and have everything work.

CRITICAL RULES:
- Do NOT write markdown files, reports, or verification docs. Only .zig code.
- Run zig build after EVERY change. If it fails, fix it before moving on.
- Commit and push after each completed item.
- If rebase conflicts: git rebase --abort && git reset --hard origin/master, redo work.
- You primarily edit src/main_common.zig and build.zig.

ARCHITECTURE:
The fallback to git CLI must be CONDITIONAL on a build flag so it is NOT included in WASM builds.

In build.zig, add a build option:
  const enable_git_fallback = b.option(bool, \"git-fallback\", \"Enable git CLI fallback for unimplemented commands (not available in WASM)\") orelse true;
Pass this as a build option to the exe via b.addOptions().
The WASM target should always set this to false.

ITEM 1: Add git CLI fallback in src/main_common.zig.
At the END of the command dispatch in zigzitMain(), where it currently prints X is not a ziggit command, replace that with a conditional:
- Import build_options
- If enable_git_fallback is true, call forwardToGit() which spawns the real git binary with the same arguments
- If enable_git_fallback is false (WASM), print the error message as before

Implement forwardToGit() that:
- Builds an argv array with git as argv[0] and all original args after that
- Spawns a child process with stdin/stdout/stderr inherited
- CATCHES the spawn error if git is not installed
- When git is not found: prints a helpful message saying this command is not yet natively implemented, suggest installing git for fallback, exit with code 1. Do NOT crash or panic.
- When git exits: propagate its exit code via std.process.exit()

ITEM 2: Capture exit codes properly.
When forwarding to git, propagate its exit code. Use std.process.exit() with the code from the child process term so the calling process (like bun) sees the correct exit status.

ITEM 3: Forward the -C, -c, --git-dir, --work-tree global flags.
When ziggit gets global flags like -C, -c, --git-dir, --work-tree, and the command falls through to git, those flags must be forwarded too. Collect all global flags before the command, then prepend them to the git invocation.

ITEM 4: Handle stdin/stdout/stderr properly.
Some git commands are interactive (git commit without -m opens an editor, git add -p is interactive). The fallback must inherit all three file descriptors so interactive commands work.

ITEM 5: Write a comprehensive test.
Create test/git_fallback_test.sh that tests:
- Commands with native implementations work (status, rev-parse, log, branch, tag, describe, diff)
- Commands that fall back to git also work (stash list, remote -v, show HEAD, ls-files, cat-file -t HEAD, rev-list --count HEAD, log --graph --oneline -5, shortlog -sn -1)
- When git is NOT in PATH, fallback commands print a clear error message and exit 1 (not crash)

ITEM 6: Update the help text.
Update --help to mention that unimplemented commands are transparently forwarded to git.

After all items are done, verify with:
  alias git=ziggit && git status && git stash list && git remote -v && git log --graph --oneline -5

Then move on to implementing MORE commands natively in Zig to reduce git fallback usage. Priority order:
1. git show <ref> -- read and display commit/tree/blob objects (already have object reading)
2. git ls-files -- list index entries (already have index reading)
3. git cat-file -t/-s/-p <hash> -- object inspection (already have object reading)
4. git rev-list -- commit graph walking (already have commit parsing)
5. git remote -v -- parse .git/config (config parser exists)
6. git reset --soft/--mixed -- update HEAD ref + optionally update index
7. git stash -- save/restore working tree changes
8. git rm -- remove from index + working tree

For each native implementation, remove it from the fallback path and add proper Zig code."

while true; do
    echo "$(date): Starting pi agent run..." >> /root/agent.log
    pi -p "$GOAL" --model anthropic/claude-sonnet-4-20250514 --no-session >> /root/agent.log 2>&1
    EXIT=$?
    echo "$(date): Agent run completed (exit=$EXIT)" >> /root/agent.log
    cd /root/ziggit
    git pull --rebase origin master 2>> /root/agent.log || { git rebase --abort 2>/dev/null; git reset --hard origin/master; }
    if [ -n "$(git status --porcelain)" ]; then
        git add -A && git commit -m "agent: auto-commit git fallback work" 2>> /root/agent.log || true
        git push origin master 2>> /root/agent.log || true
    fi
    sleep 10
done
