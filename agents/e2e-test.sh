#!/bin/bash
# LIBSTATUS agent (updated) - End-to-end validation + git interop tests
# VM: LIBSTATUS (c0e95676-bf99-4e56-a9cd-634df61a7ff5)
# Goal: Validate ziggit produces git-compatible output, write cross-validation tests

export NODE_OPTIONS="--max-old-space-size=256"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"

cd /root/ziggit || exit 1

exec pi --no-session -p "You write end-to-end validation tests for ziggit, a Zig git implementation.
Your tests verify that ziggit produces output that real git can read, and vice versa.

## PRIORITY ORDER
1. Write shell script tests that compare ziggit CLI output to git CLI output
2. Write Zig tests that create repos with ziggit API, then verify with git CLI
3. Write Zig tests that create repos with git CLI, then verify with ziggit API
4. Test the bun workflow end-to-end: init, add package.json, commit, tag, status, describe

## TEST SCENARIOS TO COVER

### Cross-validation (ziggit writes, git reads):
- ziggit init -> git status (should show empty repo)
- ziggit add + commit -> git log (should show the commit)
- ziggit tag -> git tag -l (should list the tag)
- ziggit commit -> git cat-file -p HEAD (should show valid commit object)

### Cross-validation (git writes, ziggit reads):
- git init + add + commit -> ziggit rev-parse HEAD (should match)
- git tag -> ziggit describe --tags (should find tag)
- git commit multiple -> ziggit log --format=%H -1 HEAD~1 (should resolve)

### Bun workflow simulation:
- Create package.json, add, commit, tag, verify status clean
- Clone bare, fetch, checkout, verify files present
- Multiple commits, verify log output matches git

### Edge cases:
- Binary files in add/commit
- Files with spaces and special characters
- Empty commits
- Repos with 100+ files
- Deeply nested directory trees
- Merge commits (two parents)

## TEST FILE LOCATIONS
- test/e2e_validation_test.sh - shell script cross-validation
- test/ziggit_writes_git_reads_test.zig - Zig API -> git CLI
- test/git_writes_ziggit_reads_test.zig - git CLI -> Zig API

## CONSTRAINTS
- ONLY write tests - no feature implementation
- Do NOT write markdown files
- Every test must actually run and pass
- Wire Zig test files into build.zig
- Commit frequently
- Pull --rebase before push

## AFTER EACH PI RUN
git add -A && git commit -m 'test: <describe tests added>' && git pull --rebase origin master && git push origin master
"
