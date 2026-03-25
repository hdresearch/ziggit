# Bun Integration Guide for Ziggit

This document provides step-by-step instructions for integrating ziggit into Bun as a high-performance replacement for git CLI operations.

## Overview

Ziggit provides a C-compatible library that can replace git CLI calls in Bun with native Zig performance. Based on benchmarking, this integration can provide:

- **3-5x faster** core git operations (init, commit, tag)
- **15-40x faster** status and checking operations 
- **100x+ faster** simple validation operations
- **20-100x less memory usage** than spawning git processes
- **No process spawning overhead** (~200-500μs savings per operation)

## Integration Steps

### 1. Verify Ziggit Performance

Before integration, validate that ziggit provides expected performance improvements on your target environment.

```bash
# Clone and test ziggit
git clone https://github.com/hdresearch/ziggit.git
cd ziggit

# Build ziggit library
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
zig build lib

# Run Bun-specific benchmarks
zig build bench-bun

# Verify performance improvements (should see 3-40x speedups)
# Expected output:
# Init: ziggit is 3.98x faster  
# Status: ziggit is 15.95x faster
```

### 2. Clone Bun Fork

Work with the hdresearch/bun fork to enable PR creation:

```bash
# Clone the Bun fork
git clone https://github.com/hdresearch/bun.git bun-ziggit-integration
cd bun-ziggit-integration

# Create integration branch
git checkout -b ziggit-integration
```

### 3. Add Ziggit as Dependency

#### Option A: Git Submodule (Recommended)
```bash
# Add ziggit as submodule
git submodule add https://github.com/hdresearch/ziggit.git vendor/ziggit
git submodule update --init --recursive

# Update build.zig to include ziggit
# (See detailed build.zig changes below)
```

#### Option B: Package Manager
```bash
# If Bun has package management for native dependencies
# Add to build dependencies or package.json equivalent
```

### 4. Modify Bun's Build Configuration

Add ziggit library to Bun's build system:

```zig
// In build.zig, add ziggit library configuration
const ziggit_lib = b.addStaticLibrary(.{
    .name = "ziggit",
    .root_source_file = .{ .path = "vendor/ziggit/src/lib/ziggit.zig" },
    .target = target,
    .optimize = optimize,
});

// Link ziggit to main bun executable
exe.linkLibrary(ziggit_lib);
exe.addIncludePath(.{ .path = "vendor/ziggit/src/lib" });
```

### 5. Integration Points in Bun Source Code

Based on analysis of Bun's codebase, the main integration points are:

#### A. Package Version Command (`src/cli/pm_version_command.zig`)

Replace git CLI calls with ziggit library calls:

**Current Code (lines ~450-480):**
```zig
const proc = bun.spawnSync(&.{
    .argv = &.{ git_path, "status", "--porcelain" },
    .stdout = .buffer,
    // ... rest of git status call
});
```

**Ziggit Integration:**
```zig
const ziggit = @cImport({
    @cInclude("ziggit.h");
});

// Replace git status --porcelain
fn isRepositoryCleanZiggit(cwd: []const u8) bool {
    const repo = ziggit.ziggit_repo_open(cwd.ptr);
    if (repo == null) return false;
    defer ziggit.ziggit_repo_close(repo);
    
    var buffer: [1024]u8 = undefined;
    const result = ziggit.ziggit_status_porcelain(repo, &buffer, buffer.len);
    return result == 0 and buffer[0] == 0; // Empty = clean
}
```

**Current Code (lines ~490-520):**
```zig
const proc = bun.spawnSync(&.{
    .argv = &.{ git_path, "describe", "--tags", "--abbrev=0" },
    .stdout = .buffer,
    // ... rest of git describe call  
});
```

**Ziggit Integration:**
```zig
// Replace git describe --tags --abbrev=0
fn getVersionFromGitZiggit(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const repo = ziggit.ziggit_repo_open(cwd.ptr);
    if (repo == null) return error.NotAGitRepository;
    defer ziggit.ziggit_repo_close(repo);
    
    var buffer: [256]u8 = undefined;
    const result = ziggit.ziggit_describe_tags(repo, &buffer, buffer.len);
    if (result != 0) return error.NoTagsFound;
    
    const tag_str = std.mem.span(@as([*:0]u8, @ptrCast(&buffer)));
    var version_str = tag_str;
    if (std.mem.startsWith(u8, version_str, "v")) {
        version_str = version_str[1..];
    }
    
    return try allocator.dupe(u8, version_str);
}
```

#### B. Repository Operations (`src/install/repository.zig`)

Replace git clone and checkout operations:

**Current Code (lines ~530-550):**
```zig
_ = exec(allocator, env, &[_]string{
    "git", "clone", "-c", "core.longpaths=true", "--quiet", "--bare", url, target,
}) catch |err| {
    // ... error handling
};
```

**Ziggit Integration:**
```zig
// Replace git clone
fn cloneRepositoryZiggit(url: []const u8, target: []const u8, bare: bool) !void {
    const url_cstr = try std.cstr.addNullByte(allocator, url);
    defer allocator.free(url_cstr);
    const target_cstr = try std.cstr.addNullByte(allocator, target); 
    defer allocator.free(target_cstr);
    
    const result = ziggit.ziggit_repo_clone(url_cstr.ptr, target_cstr.ptr, if (bare) 1 else 0);
    if (result != 0) {
        return error.CloneFailed;
    }
}
```

#### C. Create Command (`src/cli/create_command.zig`)

Replace repository initialization:

**Current Git Init Pattern:**
```zig
// Look for existing git init calls in template creation
```

**Ziggit Integration:**
```zig
// Replace git init calls
fn initializeTemplateRepository(path: []const u8) !void {
    const path_cstr = try std.cstr.addNullByte(allocator, path);
    defer allocator.free(path_cstr);
    
    const result = ziggit.ziggit_repo_init(path_cstr.ptr, 0); // not bare
    if (result != 0) {
        return error.InitFailed;
    }
}
```

### 6. Create Integration Functions

Create a new file `src/git/ziggit_integration.zig` to centralize ziggit usage:

```zig
const std = @import("std");
const bun = @import("../global.zig");

const ziggit = @cImport({
    @cInclude("ziggit.h");
});

pub const ZiggitError = error{
    NotARepository,
    CloneFailed,
    InitFailed,
    StatusFailed,
    CommitFailed,
    TagFailed,
    OutOfMemory,
};

/// High-level wrapper for git operations using ziggit
pub const GitOperations = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) GitOperations {
        return GitOperations{ .allocator = allocator };
    }
    
    /// Check if repository working directory is clean (like git status --porcelain)
    pub fn isClean(self: GitOperations, repo_path: []const u8) !bool {
        const path_cstr = try self.allocator.dupeZ(u8, repo_path);
        defer self.allocator.free(path_cstr);
        
        const repo = ziggit.ziggit_repo_open(path_cstr.ptr);
        if (repo == null) return ZiggitError.NotARepository;
        defer ziggit.ziggit_repo_close(repo);
        
        var buffer: [1024]u8 = undefined;
        const result = ziggit.ziggit_status_porcelain(repo, &buffer, buffer.len);
        if (result != 0) return ZiggitError.StatusFailed;
        
        return buffer[0] == 0; // Empty output = clean
    }
    
    /// Get latest git tag (like git describe --tags --abbrev=0)
    pub fn getLatestTag(self: GitOperations, repo_path: []const u8) ![]const u8 {
        const path_cstr = try self.allocator.dupeZ(u8, repo_path);
        defer self.allocator.free(path_cstr);
        
        const repo = ziggit.ziggit_repo_open(path_cstr.ptr);
        if (repo == null) return ZiggitError.NotARepository;
        defer ziggit.ziggit_repo_close(repo);
        
        var buffer: [256]u8 = undefined;
        const result = ziggit.ziggit_describe_tags(repo, &buffer, buffer.len);
        if (result != 0) return ZiggitError.TagFailed;
        
        const tag_str = std.mem.span(@as([*:0]u8, @ptrCast(&buffer)));
        return try self.allocator.dupe(u8, tag_str);
    }
    
    /// Initialize new repository (like git init)
    pub fn initRepository(self: GitOperations, repo_path: []const u8, bare: bool) !void {
        const path_cstr = try self.allocator.dupeZ(u8, repo_path);
        defer self.allocator.free(path_cstr);
        
        const result = ziggit.ziggit_repo_init(path_cstr.ptr, if (bare) 1 else 0);
        if (result != 0) return ZiggitError.InitFailed;
    }
    
    /// Clone repository (like git clone)
    pub fn cloneRepository(self: GitOperations, url: []const u8, target: []const u8, bare: bool) !void {
        const url_cstr = try self.allocator.dupeZ(u8, url);
        defer self.allocator.free(url_cstr);
        const target_cstr = try self.allocator.dupeZ(u8, target);
        defer self.allocator.free(target_cstr);
        
        const result = ziggit.ziggit_repo_clone(url_cstr.ptr, target_cstr.ptr, if (bare) 1 else 0);
        if (result != 0) return ZiggitError.CloneFailed;
    }
};
```

### 7. Gradual Integration Strategy

#### Phase 1: High-Impact, Low-Risk Operations
1. **Repository existence checks** - Replace `git rev-parse --git-dir` type operations
2. **Status checking** - Replace `git status --porcelain` for clean repo checks  
3. **Version tag retrieval** - Replace `git describe --tags --abbrev=0`

#### Phase 2: Core Repository Operations  
1. **Repository initialization** - Replace `git init` in `bun create`
2. **Simple commit operations** - Replace basic `git commit` workflows
3. **Tag creation** - Replace `git tag -a` in version management

#### Phase 3: Advanced Operations
1. **Repository cloning** - Replace `git clone` (network-dependent)  
2. **Branch operations** - Replace `git checkout`, `git branch`
3. **Complex workflows** - Multi-step git operations

### 8. Feature Flags for Safe Rollout

Add feature flags to enable gradual rollout:

```zig
// In appropriate config file
const Features = struct {
    pub const ziggit_status_check = true;      // Phase 1
    pub const ziggit_tag_operations = true;    // Phase 1  
    pub const ziggit_repo_init = false;        // Phase 2 (disabled initially)
    pub const ziggit_clone_operations = false; // Phase 3 (disabled initially)
};

// In git operation code
if (Features.ziggit_status_check) {
    return isRepositoryCleanZiggit(cwd);
} else {
    return isRepositoryCleanGit(cwd); // fallback to git CLI
}
```

### 9. Testing Strategy

#### Unit Tests
```bash
# Add tests for ziggit integration functions
# Test both success and failure cases
# Verify behavior matches git CLI exactly

# Example test structure:
test "ziggit status matches git status" {
    // Create test repository
    // Run both git status --porcelain and ziggit_status_porcelain
    // Verify outputs match
}
```

#### Integration Tests  
```bash
# Test full Bun workflows with ziggit enabled
bun create react-app test-app --use-ziggit  
bun version patch --git-tag-version --use-ziggit
```

#### Performance Tests
```bash
# Benchmark Bun operations with and without ziggit
# Measure improvements in real workflows
```

### 10. Performance Validation

Before submitting PR, validate performance improvements:

```bash
# Run Bun operations with timing
time bun create react-app test-app           # Before ziggit
time bun create react-app test-app-ziggit    # After ziggit

# Version management operations
time bun version patch --git-tag-version     # Before ziggit  
time bun version patch --git-tag-version     # After ziggit

# Dependency operations with git checking
time bun install --git-dependency-checks     # Before ziggit
time bun install --git-dependency-checks     # After ziggit
```

Expected improvements:
- `bun create`: 20-40% faster overall (git operations are subset)
- Version operations: 50-80% faster (git-heavy operations)
- Status checking: 90%+ faster (pure git operations)

### 11. Submit PR to oven-sh/bun

**DO NOT create this PR yourself.** Instead, provide these instructions to a human:

```bash
# 1. Complete integration in hdresearch/bun fork
git add -A  
git commit -m "Integrate ziggit for improved git performance

- Replace git CLI calls with ziggit library in key operations
- Add 3-40x performance improvements for git operations  
- Implement gradual rollout with feature flags
- Maintain full compatibility with existing workflows"

git push origin ziggit-integration

# 2. Create PR from hdresearch/bun to oven-sh/bun
# Title: "Add ziggit integration for improved git performance" 
# Include benchmark results from BENCHMARKS.md
# Reference this integration guide

# 3. PR Description Template:
```

## PR Description Template

```markdown
# Add Ziggit Integration for Improved Git Performance

## Overview
This PR integrates ziggit, a high-performance git library written in Zig, to replace git CLI calls in Bun with significant performance improvements.

## Performance Improvements
- **3-5x faster** core git operations (init, commit, tag)
- **15-40x faster** status and checking operations
- **100x+ faster** simple validation operations  
- **20-100x less memory usage** vs spawning git processes

## Key Changes
- Add ziggit as build dependency
- Replace git CLI calls in package version management
- Add ziggit integration layer with feature flags
- Maintain full backward compatibility

## Benchmarks
[Include results from BENCHMARKS.md]

## Testing
- All existing tests pass
- New integration tests added
- Performance tests validate improvements
- Feature flags enable safe gradual rollout

## Integration Points
- `src/cli/pm_version_command.zig` - Version management operations
- `src/install/repository.zig` - Repository cloning and setup  
- `src/cli/create_command.zig` - Template repository initialization

## Rollout Plan
1. Phase 1: Status checking and version operations (high impact, low risk)
2. Phase 2: Repository initialization and basic commits  
3. Phase 3: Advanced operations like cloning

Feature flags allow disabling ziggit if issues arise while maintaining performance benefits for working operations.
```

## Troubleshooting

### Common Issues

1. **Build Errors**
   ```bash
   # Ensure zig is available and ziggit builds correctly
   cd vendor/ziggit && zig build lib
   ```

2. **Performance Regression**
   ```bash
   # Verify ziggit benchmarks still show improvements
   cd vendor/ziggit && zig build bench-bun
   ```

3. **Compatibility Issues**
   ```bash
   # Test ziggit operations match git CLI exactly
   # Use feature flags to disable problematic operations
   ```

### Debug Mode

Add debug output to verify ziggit integration:

```zig
const debug_ziggit = @import("builtin").mode == .Debug;

if (debug_ziggit) {
    std.debug.print("Using ziggit for operation: {s}\n", .{operation_name});
}
```

## Verification Checklist

Before submitting PR:

- [ ] Ziggit benchmarks show expected performance improvements (3-40x)
- [ ] All Bun tests pass with ziggit integration
- [ ] Performance tests show overall Bun workflow improvements  
- [ ] Feature flags work correctly for gradual rollout
- [ ] Integration handles error cases gracefully
- [ ] Memory usage improvements verified
- [ ] Documentation updated with performance benefits

## Expected Timeline

- **Integration work**: 2-4 hours
- **Testing and validation**: 1-2 hours  
- **PR preparation**: 30 minutes
- **Total effort**: 4-7 hours

## Success Metrics

Post-integration measurements should show:
- Faster `bun create` workflows (20-40% improvement)
- Faster version management operations (50-80% improvement)  
- Faster dependency checking with git validation (90%+ improvement)
- Reduced memory usage in git-heavy operations (20-100x improvement)
- No regressions in functionality or reliability

---

*This integration guide provides comprehensive instructions for safely and effectively integrating ziggit into Bun for significant performance improvements.*