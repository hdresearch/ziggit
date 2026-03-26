#!/bin/bash
# NET-SMART agent - Git Smart HTTP Protocol
# VM: BUNCOMPAT (36cf902f-4f78-4830-838e-c3b4f87bffaf)
# Goal: Implement git smart HTTP protocol so ziggit can clone/fetch over HTTPS
# DEADLINE: Must work by tomorrow morning

export NODE_OPTIONS="--max-old-space-size=256"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"

cd /root/ziggit || exit 1

exec pi --no-session -p "You are implementing the git smart HTTP protocol for ziggit, a Zig git implementation.

## PRIORITY ORDER (tests first, then implementation)
1. Write tests FIRST for every component before implementing
2. Tests must be in test/ directory and wired into build.zig
3. Every test must compile and pass before moving on
4. Implementation comes AFTER tests exist

## YOUR MISSION
Implement the git smart HTTP protocol in src/git/smart_http.zig so that ziggit can:
1. Clone repositories over HTTPS (git clone --bare https://github.com/user/repo.git)
2. Fetch from repositories over HTTPS (git fetch --quiet)

These are the ONLY two network operations bun needs.

## WHAT YOU MUST BUILD

### File: src/git/smart_http.zig

#### 1. pkt-line parser/writer
- Parse 4-hex-digit length-prefixed lines: '001e# service=git-upload-pack\n'
- Handle flush packets: '0000'
- Handle delim packets: '0001'
- Write pkt-lines for request body

#### 2. Ref discovery
- GET {url}/info/refs?service=git-upload-pack
- Parse response: extract ref name -> hash mapping
- Parse capabilities from first ref line (multi_ack, thin-pack, side-band-64k, etc.)
- Handle both v1 and v2 protocol (v1 is sufficient for GitHub)

#### 3. Pack negotiation (clone)
- POST {url}/git-upload-pack
- Request body: 'want {hash} {capabilities}\n' for each wanted ref, then 'done\n'
- For clone: want ALL refs, have NOTHING
- Parse response: skip NAK/ACK lines, read pack data
- Handle side-band demuxing (channel 1 = pack data, channel 2 = progress, channel 3 = error)

#### 4. Pack negotiation (fetch)
- Same POST endpoint
- Request body: 'want {hash}\n' for new refs, 'have {hash}\n' for existing objects, 'done\n'
- Handle thin packs (deltas referencing objects we already have)

#### 5. Authentication
- Support Authorization: Bearer {token} header
- Read token from GIT_TOKEN or GITHUB_TOKEN env var
- Support https://x-access-token:{token}@github.com/... URL format

### INTEGRATION
- Wire into src/ziggit.zig Repository.fetch() and Repository.cloneBare()
- Replace the current 'return error.NetworkRemoteNotSupported' with actual implementation
- Wire into src/main_common.zig CLI commands for clone and fetch

## PROTOCOL REFERENCE

GET /info/refs?service=git-upload-pack response:
\`\`\`
001e# service=git-upload-pack\n
0000
00XXhash1 HEAD\0capabilities...\n
003fhash2 refs/heads/main\n
003fhash3 refs/tags/v1.0.0\n
0000
\`\`\`

POST /git-upload-pack request (clone):
\`\`\`
0067want hash1 multi_ack_detailed thin-pack side-band-64k ofs-delta\n
0032want hash2\n
00000009done\n
\`\`\`

POST /git-upload-pack response:
\`\`\`
0008NAK\n
PACK{binary pack data...}
\`\`\`
(with side-band-64k: each chunk prefixed with pkt-line, first byte is channel number)

## TECHNICAL NOTES
- Use std.http.Client (works on these VMs, tested and confirmed)
- Zig 0.13 std.http.Client API: client.open(.GET, uri, .{.server_header_buffer = &buf})
- Pack data starts with 'PACK' magic, 4-byte version, 4-byte object count
- The NET-PACK agent handles saving/indexing the pack file - you just need to get the bytes
- Save pack data to a temp file, then the pack indexer will process it

## EXISTING CODE TO USE
- src/git/network.zig has HttpClient and DumbHttpProtocol stubs (replace with smart protocol)
- src/git/objects.zig has pack file reading (findObjectInPack, loadFromPackFiles)
- src/git/refs.zig has ref reading/writing

## CONSTRAINTS
- Do NOT write markdown status files
- Do NOT fabricate test results
- Write a test for EVERY function BEFORE implementing it
- Tests go in test/smart_http_test.zig
- Commit frequently with descriptive messages
- Pull --rebase before push, abort+reset on conflict
- Keep the build GREEN at all times

## AFTER EACH PI RUN
git add -A && git commit -m '<descriptive message>' && git pull --rebase origin master && git push origin master
"
