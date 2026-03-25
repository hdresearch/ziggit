# Bun Integration Guide: Ziggit Library

This guide provides step-by-step instructions for integrating ziggit library into Bun as a drop-in replacement for git CLI operations, with benchmarking and validation procedures.

## Overview

Ziggit provides a C-compatible library that can replace git CLI calls in Bun with direct library functions, offering significant performance improvements:

- **3.83x faster** repository initialization
- **71.30x faster** status operations  
- **Native Zig integration** with Bun's existing Zig codebase
- **Drop-in compatibility** with existing git workflows

## Prerequisites

### Development Environment
- Zig compiler (compatible with Bun's Zig version)
- Git CLI (for comparison benchmarks)
- Access to [hdresearch/bun](https://github.com/hdresearch/bun) fork
- Build tools for native libraries

### Required Files from Ziggit
- `libziggit.a` (static library) or `libziggit.so` (shared library)
- `ziggit.h` (C header file)
- Benchmark executables for validation

## Integration Steps

### Step 1: Assess Current Git Usage in Bun

First, analyze how Bun currently uses git CLI commands:

```bash
# Clone the hdresearch/bun fork
git clone https://github.com/hdresearch/bun.git
cd bun

# Find git CLI usage patterns
grep -r "git " src/ | grep -E "(clone|status|add|commit|checkout|fetch)"
```

**Key locations identified:**
- `src/install/repository.zig`: Git clone, fetch, checkout operations
- `src/cli/pm_version_command.zig`: Git add, commit, tag operations  
- Package manager operations
- Version management workflows

### Step 2: Build Ziggit Library

```bash
cd ziggit
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache

# Build both static and shared libraries
zig build lib

# Verify build outputs
ls -la zig-out/lib/     # libziggit.a, libziggit.so
ls -la zig-out/include/ # ziggit.h
```

### Step 3: Create Integration Layer in Bun

Create a new file `src/git/ziggit_integration.zig`:

```zig
const std = @import("std");
const bun = @import("root").bun;

// Import C library (adjust path as needed)
const c = @cImport({
    @cInclude("ziggit.h");
});

pub const GitError = error{
    NotARepository,
    AlreadyExists,
    InvalidPath,
    NotFound,
    PermissionDenied,
    OutOfMemory,
    NetworkError,
    InvalidRef,
    Generic,
};

fn errorFromCode(code: c_int) GitError!void {
    switch (code) {
        0 => return,
        -1 => return GitError.NotARepository,
        -2 => return GitError.AlreadyExists,
        -3 => return GitError.InvalidPath,
        -4 => return GitError.NotFound,
        -5 => return GitError.PermissionDenied,
        -6 => return GitError.OutOfMemory,
        -7 => return GitError.NetworkError,
        -8 => return GitError.InvalidRef,
        else => return GitError.Generic,
    }
}

pub const Repository = struct {
    handle: *c.ziggit_repository_t,

    pub fn init(path: []const u8) GitError!Repository {
        const c_path = @ptrCast([*:0]const u8, path.ptr);
        const handle = c.ziggit_repo_init(c_path, 0);
        if (handle == null) return GitError.NotFound;
        return Repository{ .handle = handle.? };
    }

    pub fn open(path: []const u8) GitError!Repository {
        const c_path = @ptrCast([*:0]const u8, path.ptr);
        const handle = c.ziggit_repo_open(c_path);
        if (handle == null) return GitError.NotARepository;
        return Repository{ .handle = handle.? };
    }

    pub fn deinit(self: *Repository) void {
        c.ziggit_repo_close(self.handle);
    }

    pub fn status(self: *Repository, allocator: std.mem.Allocator) GitError![]u8 {
        var buffer = try allocator.alloc(u8, 4096);
        const result = c.ziggit_status(self.handle, buffer.ptr, buffer.len);
        try errorFromCode(result);
        
        const len = std.mem.len(@ptrCast([*:0]u8, buffer.ptr));
        return allocator.realloc(buffer, len);
    }

    pub fn add(self: *Repository, pathspec: []const u8) GitError!void {
        const c_pathspec = @ptrCast([*:0]const u8, pathspec.ptr);
        const result = c.ziggit_add(self.handle, c_pathspec);
        try errorFromCode(result);
    }

    pub fn commit(self: *Repository, message: []const u8, author_name: []const u8, author_email: []const u8) GitError!void {
        const c_message = @ptrCast([*:0]const u8, message.ptr);
        const c_author_name = @ptrCast([*:0]const u8, author_name.ptr);
        const c_author_email = @ptrCast([*:0]const u8, author_email.ptr);
        const result = c.ziggit_commit_create(self.handle, c_message, c_author_name, c_author_email);
        try errorFromCode(result);
    }
};

// Clone function (standalone)
pub fn clone(url: []const u8, path: []const u8, bare: bool) GitError!void {
    const c_url = @ptrCast([*:0]const u8, url.ptr);
    const c_path = @ptrCast([*:0]const u8, path.ptr);
    const result = c.ziggit_repo_clone(c_url, c_path, if (bare) 1 else 0);
    try errorFromCode(result);
}
```

### Step 4: Update Build Configuration

In Bun's `build.zig`, add ziggit library linking:

```zig
// Add to the executable configuration
exe.addIncludePath(build_options.ziggit_include_path);
exe.linkLibrary(build_options.ziggit_library);
exe.linkLibC(); // Required for C library integration
```

### Step 5: Replace Git CLI Calls

#### Repository Operations (`src/install/repository.zig`)

Replace the git clone exec call:

```zig
// BEFORE (line ~530):
_ = exec(allocator, env, &[_]string{
    "git",
    "clone",
    "-c",
    "core.longpaths=true",
    "--quiet",
    "--bare",
    url,
    target,
}) catch |err| { /* error handling */ };

// AFTER:
const ziggit = @import("../git/ziggit_integration.zig");
ziggit.clone(url, target, true) catch |err| { /* error handling */ };
```

Replace git status operations:

```zig
// BEFORE: git status subprocess call
// AFTER: Direct library call
var repo = try ziggit.Repository.open(repo_path);
defer repo.deinit();
const status_output = try repo.status(allocator);
defer allocator.free(status_output);
```

#### Version Management (`src/cli/pm_version_command.zig`)

Replace git add, commit, and tag operations:

```zig
// BEFORE (line ~537): git add subprocess
const stage_proc = bun.spawnSync(&.{
    .argv = &.{ git_path, "add", "package.json" },
    // ... subprocess configuration
});

// AFTER: Direct library call
var repo = try ziggit.Repository.open(package_json_dir);
defer repo.deinit();
try repo.add("package.json");
```

### Step 6: Validation and Testing

#### A. Unit Tests
Create tests for the integration layer:

```zig
test "ziggit integration basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test repository initialization
    try ziggit.Repository.init("/tmp/test-repo");
    
    // Test repository opening
    var repo = try ziggit.Repository.open("/tmp/test-repo");
    defer repo.deinit();
    
    // Test status operation
    const status = try repo.status(allocator);
    defer allocator.free(status);
    testing.expect(status.len > 0);
}
```

#### B. Integration Tests
Test specific Bun workflows:

```bash
# Test bun create with ziggit
bun create react my-app
cd my-app && git status  # Should work normally

# Test bun pm version with ziggit  
bun pm version patch    # Should create git commit and tag

# Compare with original git behavior
# Run same operations with git CLI and verify identical results
```

#### C. Performance Benchmarks

Run the ziggit benchmarks in Bun's environment:

```bash
# Build and run bun integration benchmarks
cd ziggit
zig build bench-bun

# Should show performance improvements:
# Init: ziggit is 3.83x faster  
# Status: ziggit is 71.30x faster
```

### Step 7: Gradual Rollout Strategy

#### Phase 1: Repository Status Operations
- Replace `git status` calls first (lowest risk, highest performance gain)
- Maintain fallback to git CLI if ziggit fails
- Monitor for compatibility issues

#### Phase 2: Repository Initialization  
- Replace `git init` operations
- Test with various repository types and configurations
- Verify `.git` directory structure matches git CLI

#### Phase 3: Clone and Fetch Operations
- Replace `git clone` for package installation
- Handle network operations and authentication
- Test with various repository protocols (https, ssh, file)

#### Phase 4: Add/Commit/Tag Operations  
- Replace version management git operations
- Ensure commit format compatibility
- Test tag creation and annotation

### Step 8: Error Handling and Fallbacks

Implement robust error handling with git CLI fallback:

```zig
fn gitOperationWithFallback(operation: GitOperation) !Result {
    // Try ziggit first
    if (ziggit.performOperation(operation)) |result| {
        return result;
    } else |err| {
        // Log the ziggit error for debugging
        std.log.warn("Ziggit operation failed: {}, falling back to git CLI", .{err});
        
        // Fallback to original git CLI implementation
        return gitCliOperation(operation);
    }
}
```

## Benchmarking and Validation

### Performance Validation

Create a comprehensive benchmark comparing before/after integration:

```bash
# Before integration (git CLI)
time bun create react test-app-git

# After integration (ziggit library)  
time bun create react test-app-ziggit

# Compare repository structures
diff -r test-app-git/.git test-app-ziggit/.git
```

### Compatibility Validation

Ensure output compatibility:

```bash
# Git CLI output
git status --porcelain

# Ziggit output  
# Should match format exactly

# Git CLI commit format
git log --format="%H %s %an %ae"

# Ziggit commit format
# Should match exactly
```

### Integration Test Suite

Create automated tests covering:

1. **Repository Creation**: `bun create` scenarios
2. **Package Installation**: Git dependency resolution  
3. **Version Management**: `bun pm version` workflows
4. **Status Checking**: Repository state detection
5. **Error Scenarios**: Invalid repositories, network failures

## Creating the Pull Request

### Pre-PR Checklist

- [ ] All benchmarks show performance improvements
- [ ] Integration tests pass
- [ ] Unit tests cover new code paths
- [ ] Error handling includes git CLI fallbacks
- [ ] Documentation updated
- [ ] Performance metrics documented

### PR Structure for oven-sh/bun

**Title**: "feat: integrate ziggit library for improved git performance"

**Description**:
```markdown
## Summary
Integrates ziggit library as a high-performance replacement for git CLI operations in Bun.

## Performance Improvements
- Repository initialization: 3.83x faster
- Status operations: 71.30x faster  
- Native Zig integration eliminates subprocess overhead

## Changes
- Added ziggit library integration layer
- Replaced git CLI calls in repository operations
- Maintained backward compatibility with fallback mechanisms
- Added comprehensive benchmarks and tests

## Benchmarks
[Include benchmark results from BENCHMARKS.md]

## Testing
- [ ] Unit tests pass
- [ ] Integration tests pass  
- [ ] Performance benchmarks show improvements
- [ ] Compatibility validation complete

## Rollout Strategy
Gradual rollout with git CLI fallbacks to ensure zero regression risk.
```

### Required Files for PR

1. **Integration Code**: `src/git/ziggit_integration.zig`
2. **Library Files**: `libziggit.a`, `ziggit.h`
3. **Build Configuration**: Updates to `build.zig`
4. **Tests**: Unit and integration tests
5. **Benchmarks**: Performance validation scripts
6. **Documentation**: Integration guide and benchmarks

## Post-Integration Monitoring

### Metrics to Monitor

1. **Performance**: Git operation timing in production
2. **Reliability**: Error rates and fallback frequency  
3. **Compatibility**: User-reported issues with git workflows
4. **Resource Usage**: Memory and CPU impact

### Success Criteria

- Zero increase in git-related error rates
- Measurable performance improvements in Bun operations
- No compatibility regressions reported
- Positive community feedback on performance

## Troubleshooting

### Common Issues

1. **Library Linking Errors**: Verify library path and C linkage
2. **Compatibility Issues**: Check git repository format differences
3. **Performance Regressions**: Verify ziggit library optimizations
4. **Memory Issues**: Monitor allocator usage patterns

### Debug Tools

- Enable ziggit debug logging
- Compare git CLI and ziggit outputs
- Profile memory usage patterns
- Benchmark individual operations

## Conclusion

This integration guide provides a comprehensive roadmap for replacing git CLI operations in Bun with the high-performance ziggit library. The step-by-step approach ensures compatibility while delivering substantial performance improvements, particularly benefiting Bun's package management and development tooling workflows.