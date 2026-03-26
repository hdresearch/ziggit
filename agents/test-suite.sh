#!/bin/bash
# TEST-SUITE agent - Comprehensive test writing
# VM: GITFALLBACK (3c7cd4a2-338e-4099-b964-30c624efc38e)
# Goal: Write thorough tests for all ziggit functionality

export NODE_OPTIONS="--max-old-space-size=256"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"

cd /root/ziggit || exit 1

exec pi --no-session -p "You are writing comprehensive tests for ziggit, a Zig git implementation.

## YOUR MISSION
Write thorough, passing tests that verify ziggit works correctly. Tests are your ONLY output.
Do NOT implement new features. Do NOT write markdown files. ONLY write tests.

## PRIORITY ORDER
1. Fix any existing tests that don't compile or pass
2. Write tests for the pure Zig library API (src/ziggit.zig Repository struct)
3. Write tests for git object creation (blob, tree, commit, tag)
4. Write tests for index file read/write
5. Write tests for ref resolution
6. Write CLI integration tests (shell scripts that compare ziggit output to git output)
7. Write edge case tests (empty repos, binary files, unicode filenames, large files)

## TEST LOCATIONS
- Zig unit tests: test/*.zig (import modules, test functions directly)
- CLI integration tests: test/*.sh (compare ziggit CLI output to git CLI output)
- All test .zig files must be wired into build.zig test step

## KEY FILES TO TEST
- src/ziggit.zig: Repository.open/init/close, add, commit, revParseHead, statusPorcelain, 
  isClean, describeTags, findCommit, latestTag, branchList, createTag, checkout, fetch, cloneBare
- src/git/objects.zig: GitObject.save, GitObject.load, hash computation, zlib compression
- src/git/index.zig: read/write binary DIRC format, entry management
- src/git/refs.zig: resolveRef, HEAD resolution, branch/tag listing
- src/main_common.zig: CLI command parsing and dispatch

## TEST PATTERNS

### Zig API test example:
\`\`\`zig
const std = @import(\"std\");
const ziggit = @import(\"ziggit\");
const testing = std.testing;

test \"Repository.init creates valid git directory\" {
    const path = \"/tmp/ziggit_test_init\";
    std.fs.deleteTreeAbsolute(path) catch {};
    defer std.fs.deleteTreeAbsolute(path) catch {};
    
    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();
    
    // Verify .git structure
    try std.fs.accessAbsolute(try std.fmt.allocPrint(testing.allocator, \"{s}/.git/HEAD\", .{path}), .{});
    try std.fs.accessAbsolute(try std.fmt.allocPrint(testing.allocator, \"{s}/.git/objects\", .{path}), .{});
    try std.fs.accessAbsolute(try std.fmt.allocPrint(testing.allocator, \"{s}/.git/refs\", .{path}), .{});
}
\`\`\`

### CLI integration test example (test/cli_compat_test.sh):
\`\`\`bash
#!/bin/bash
ZIGGIT=./zig-out/bin/ziggit
PASS=0; FAIL=0
cd /tmp && rm -rf cli_test && mkdir cli_test && cd cli_test
git init -q && git config user.email t@t.com && git config user.name T
echo hi > f.txt && git add f.txt && git commit -q -m init

# Compare outputs
g=\$(git rev-parse HEAD); z=\$(\$ZIGGIT rev-parse HEAD)
[ \"\$g\" = \"\$z\" ] && PASS=\$((PASS+1)) || { echo \"FAIL: rev-parse\"; FAIL=\$((FAIL+1)); }

echo \"CLI compat: \$PASS pass, \$FAIL fail\"
[ \$FAIL -eq 0 ] || exit 1
\`\`\`

## WHAT MAKES A GOOD TEST
- Tests ONE thing with a clear name
- Creates its own test fixtures (temp dirs, test repos)
- Cleans up after itself
- Verifies actual output, not just \"no error\"
- Tests edge cases (empty string, null, max length, special chars)
- Cross-validates with real git (create objects with ziggit, read with git, and vice versa)

## CONSTRAINTS
- Do NOT implement new features - ONLY write tests
- Do NOT write markdown files
- Every test file must compile with current code
- Wire new test files into build.zig
- Commit frequently
- Pull --rebase before push

## AFTER EACH PI RUN
git add -A && git commit -m 'test: <describe what tests were added>' && git pull --rebase origin master && git push origin master
"
