#!/bin/bash
# NET-PACK agent - Pack file storage + index generation + ref updates
# VM: PERF (39b4d3fb-2722-4fe3-afb6-39ced8db5df8)
# Goal: Save received pack files, generate .idx, update refs after clone/fetch
# DEADLINE: Must work by tomorrow morning

export NODE_OPTIONS="--max-old-space-size=256"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"

cd /root/ziggit || exit 1

exec pi --no-session -p "You are implementing pack file storage and index generation for ziggit, a Zig git implementation.

## PRIORITY ORDER (tests first, then implementation)
1. Write tests FIRST for every component before implementing
2. Tests must be in test/ directory and wired into build.zig
3. Every test must compile and pass before moving on
4. Implementation comes AFTER tests exist

## YOUR MISSION
The NET-SMART agent is implementing the HTTP protocol to download pack data from remote repos.
YOUR job is to handle what happens AFTER the pack bytes arrive:
1. Save pack file to objects/pack/
2. Generate .idx index file for the pack
3. Update refs after fetch/clone
4. Support the full clone and fetch workflows

## WHAT YOU MUST BUILD

### File: src/git/pack_writer.zig

#### 1. Save received pack to disk
- Input: raw pack bytes (starting with PACK magic)
- Validate: check PACK magic, version (2), object count
- Compute SHA-1 checksum of entire pack
- Save as objects/pack/pack-{checksum}.pack
- Return the checksum for idx naming

#### 2. Generate .idx from .pack file (CRITICAL)
The .idx file is how git looks up objects in a pack file.
Format (v2):
\`\`\`
[4 bytes] magic: 0xff744f63
[4 bytes] version: 2
[256 * 4 bytes] fanout table (cumulative count by first hash byte)
[N * 20 bytes] sorted SHA-1 hashes
[N * 4 bytes] CRC32 of each object's compressed data
[N * 4 bytes] 4-byte pack offsets (or 8-byte for large packs)
[20 bytes] pack file SHA-1 checksum
[20 bytes] idx file SHA-1 checksum
\`\`\`

To build the idx, you must:
a. Walk the pack file sequentially
b. For each object: record offset, decompress to get type+size, compute SHA-1 of the full object
c. For delta objects (OFS_DELTA, REF_DELTA): resolve the delta chain to get base type+data, then compute SHA-1
d. Sort entries by SHA-1, build fanout table, compute CRCs
e. Write the idx file

#### 3. Ref update after clone
- Input: ref_name -> hash mapping from smart HTTP ref discovery
- Write refs/heads/*, refs/tags/* files
- For bare clone: write HEAD file
- For non-bare clone: write refs/remotes/origin/* instead

#### 4. Ref update after fetch
- Input: ref_name -> hash mapping from smart HTTP ref discovery
- Update refs/remotes/origin/* files
- Handle FETCH_HEAD

### File: src/git/clone.zig (orchestration)

#### 5. Clone workflow
\`\`\`
cloneBareSmart(url, target_dir):
  1. Create bare repo structure (HEAD, objects/, refs/)
  2. Call smart_http.discoverRefs(url) -> refs + pack_data
  3. Call pack_writer.savePack(pack_data) -> checksum
  4. Call pack_writer.generateIdx(pack_path) -> idx_path
  5. Call pack_writer.updateRefs(refs, target_dir, bare=true)
\`\`\`

#### 6. Fetch workflow
\`\`\`
fetchSmart(repo, remote_url):
  1. Call smart_http.discoverRefs(url) -> remote_refs
  2. Compare with local refs to find new objects needed
  3. Call smart_http.fetchPack(url, wants, haves) -> pack_data
  4. Call pack_writer.savePack(pack_data)
  5. Call pack_writer.generateIdx(pack_path)
  6. Call pack_writer.updateRemoteRefs(remote_refs, repo)
\`\`\`

## EXISTING CODE TO USE
- src/git/objects.zig: has readPackObjectAtOffset(), applyDelta() - use for idx generation
- src/git/pack.zig: has PackFileStats, some pack reading utilities
- src/git/refs.zig: has resolveRef(), ref reading
- src/ziggit.zig: Repository struct where you wire in the final clone/fetch

## TECHNICAL NOTES
- Zig 0.13 has std.compress.zlib for decompression
- For zlib compression (pack objects): std.compress.zlib
- SHA-1: std.crypto.hash.Sha1
- CRC32: std.hash.Crc32
- Big-endian integers: std.mem.readInt(u32, bytes, .big)
- Pack object types: 1=commit, 2=tree, 3=blob, 4=tag, 6=ofs_delta, 7=ref_delta

## DELTA RESOLUTION FOR IDX GENERATION
OFS_DELTA objects reference a base at (current_offset - negative_offset).
REF_DELTA objects reference a base by SHA-1 hash.
To compute the SHA-1 of a delta object, you must:
1. Find the base object (possibly another delta - chain them)
2. Apply all deltas to get final content
3. Compute SHA-1 of '{type} {size}\0{content}'

## CONSTRAINTS
- Do NOT write markdown status files
- Do NOT fabricate test results
- Write a test for EVERY function BEFORE implementing it
- Tests go in test/pack_writer_test.zig
- Commit frequently with descriptive messages
- Pull --rebase before push, abort+reset on conflict
- Keep the build GREEN at all times
- The NET-SMART agent owns the HTTP layer - do NOT duplicate that
- You own the storage layer - save pack, generate idx, update refs

## AFTER EACH PI RUN
git add -A && git commit -m '<descriptive message>' && git pull --rebase origin master && git push origin master
"
