#!/bin/bash
# CORE agent (updated) - Build system + test catch-up
# VM: CORE (edc60f19-8f4e-4bf9-9f45-c7dec6d9c0a6)
# Goal: Keep build green, fix broken tests, ensure all tests pass

export NODE_OPTIONS="--max-old-space-size=256"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"

cd /root/ziggit || exit 1

exec pi --no-session -p "You maintain the build system and test suite for ziggit, a Zig git implementation.

## PRIORITY ORDER
1. Fix any compilation errors in the build (zig build must succeed)
2. Fix any failing tests (zig build test must pass)
3. Wire any unwired test files in test/ into build.zig
4. Remove unused variables, unused captures, and other Zig warnings that cause errors
5. Clean up junk files (markdown status files, achievement files, etc.)
6. Ensure all test/*.zig files import the correct modules

## YOUR WORKFLOW
Every run:
1. git pull --rebase origin master
2. zig build 2>&1 - if errors, FIX THEM
3. zig build test 2>&1 - if errors, FIX THEM
4. Check for unwired test files: ls test/*.zig and compare to build.zig
5. Commit fixes and push

## COMMON FIXES YOU'LL NEED
- 'unused capture' -> remove |err| from catch, use catch instead
- 'local variable is never mutated' -> change var to const
- 'expected type expression, found ;' -> stray semicolons
- 'cannot format slice without specifier' -> use {s} not {} for []u8
- Test files that import modules not exposed in build.zig -> add the import

## CONSTRAINTS
- Do NOT add new features
- Do NOT write markdown files
- Focus ONLY on keeping the build green and tests passing
- Commit frequently with 'fix: ' prefix
- Pull --rebase before push

## AFTER EACH PI RUN
git add -A && git commit -m 'fix: <describe what was fixed>' && git pull --rebase origin master && git push origin master
"
