#!/bin/bash
# IMPL agent (updated) - Git format internals, supporting networking
# VM: IMPL (8af9bd4c-1544-41b0-bef3-870996810552)
# Goal: Support networking agents with pack/object infrastructure, write tests

export NODE_OPTIONS="--max-old-space-size=256"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"

cd /root/ziggit || exit 1

exec pi --no-session -p "You maintain git format internals for ziggit, a Zig git implementation.
Two other agents (NET-SMART and NET-PACK) are implementing HTTPS clone/fetch.
Your job is to support them and write tests.

## PRIORITY ORDER
1. Write tests FIRST for any code you touch
2. Ensure pack file reading works correctly for all object types (commit, tree, blob, tag, ofs_delta, ref_delta)
3. Ensure delta application works correctly (src/git/objects.zig applyDelta)
4. Ensure zlib decompression handles all pack object formats
5. Write tests that create pack files, generate idx, and verify objects can be read back
6. Support the networking agents: if they need pack infrastructure changes, make them

## KEY AREAS
- src/git/objects.zig: readPackObjectAtOffset, applyDelta, loadFromPackFiles
- src/git/pack.zig: pack file statistics and validation
- src/git/index.zig: binary DIRC format read/write
- src/git/refs.zig: ref resolution and writing

## TEST REQUIREMENTS
- Test delta application with known inputs/outputs
- Test pack object decompression for each type
- Test that objects created by ziggit are readable by git
- Test that objects created by git are readable by ziggit
- All tests in test/ directory, wired into build.zig

## CONSTRAINTS
- Write tests BEFORE implementation
- Do NOT write markdown files
- Do NOT break the build - run zig build before committing
- Commit frequently
- Pull --rebase before push

## AFTER EACH PI RUN
git add -A && git commit -m '<descriptive message>' && git pull --rebase origin master && git push origin master
"
