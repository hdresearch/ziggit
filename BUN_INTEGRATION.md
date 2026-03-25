# Bun Integration Guide for Ziggit

This guide provides step-by-step instructions for integrating ziggit as a high-performance git replacement in the Bun JavaScript runtime.

## Overview

Ziggit can replace Bun's current git CLI usage with a native Zig library, providing:
- **69x faster** status operations 
- **3.8x faster** repository initialization
- Direct Zig FFI integration (no C ABI overhead)
- Reduced memory footprint (no process spawning)

## Current Git Usage in Bun

Bun currently uses git CLI for:
1. **Build system**: Getting commit SHA (`git rev-parse HEAD`) in `scripts/build/config.ts`
2. **Source management**: Checkout and pull operations in `scripts/sync-webkit-source.ts`  
3. **Patch application**: `git apply` for source patches in `scripts/build/fetch-cli.ts`

## Integration Steps

### Phase 1: Library Integration (Recommended First Step)

#### Step 1: Add Ziggit as Dependency

1. Clone ziggit to your bun fork:
```bash
cd /path/to/bun
git submodule add https://github.com/hdresearch/ziggit.git vendor/ziggit
```

2. Build ziggit library:
```bash
cd vendor/ziggit
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
zig build lib
```

#### Step 2: Update Build System

Add to `build.zig`:

```zig
// Add ziggit library
const ziggit_lib = b.dependency("ziggit", .{
    .target = target,
    .optimize = optimize,
});

// Link ziggit to your build targets
exe.linkLibrary(ziggit_lib.artifact("ziggit"));
exe.addIncludePath(ziggit_lib.path("src/lib"));
```

#### Step 3: Create Zig Git Interface

Create `src/git/ziggit_integration.zig`:

```zig
const std = @import("std");
const ziggit = @import("ziggit");

pub fn getCommitSha(allocator: std.mem.Allocator, repo_path: []const u8) ![]u8 {
    const repo = try ziggit.repo_open(allocator, repo_path);
    defer repo.deinit();
    
    // Implementation to get HEAD commit SHA
    // Replace git rev-parse HEAD
    return try getHeadCommit(repo);
}

pub fn applyPatch(repo_path: []const u8, patch_content: []const u8) !void {
    // Replace git apply operations
    // Implementation depends on your patch format requirements
}

pub fn getRepositoryStatus(allocator: std.mem.Allocator, repo_path: []const u8) ![]u8 {
    const repo = try ziggit.repo_open(allocator, repo_path);
    defer repo.deinit();
    
    var buffer = try allocator.alloc(u8, 4096);
    const status = try ziggit.repo_status(&repo, allocator);
    return status;
}
```

### Phase 2: Replace Git CLI Calls

#### Step 1: Replace `git rev-parse HEAD` 

In `scripts/build/config.ts`, replace:
```typescript
// OLD
return execSync("git rev-parse HEAD", { cwd, encoding: "utf8" }).trim();

// NEW - using ziggit
import { getCommitSha } from "../src/git/ziggit_integration.zig";
return getCommitSha(cwd);
```

#### Step 2: Replace Status Checks

For any git status operations:
```typescript
// OLD
const gitStatus = execSync("git status --porcelain", { cwd }).toString();

// NEW 
import { getRepositoryStatus } from "../src/git/ziggit_integration.zig";
const gitStatus = getRepositoryStatus(cwd);
```

#### Step 3: Optimize Repository Operations

For `bun create` and other operations that initialize repositories:
```typescript
// OLD
execSync("git init", { cwd });

// NEW
import { initRepository } from "../src/git/ziggit_integration.zig"; 
initRepository(cwd);
```

### Phase 3: Performance Validation

#### Step 1: Run Integration Benchmarks

```bash
cd vendor/ziggit
zig build bench-bun
zig build bench-simple
```

Expected improvements:
- Status operations: ~69x faster
- Init operations: ~3.8x faster
- Reduced memory usage
- No process spawning overhead

#### Step 2: Run Bun Test Suite

Ensure existing functionality is preserved:
```bash
bun test
bun test:integration  
# Run your existing test suite
```

#### Step 3: Measure Real-World Performance

Test with actual Bun operations:
```bash
# Measure bun create performance
time bun create next-app my-app

# Measure git operations in build
time bun run build

# Compare memory usage
valgrind --tool=massif bun create next-app my-app-test
```

### Phase 4: Production Deployment

#### Step 1: Feature Flag Integration

Add feature flag to control ziggit usage:
```typescript
const USE_ZIGGIT = process.env.BUN_USE_ZIGGIT === "1" || false;

function getGitRevision(cwd: string): string {
  if (USE_ZIGGIT) {
    return getCommitSha(cwd);
  }
  // Fallback to existing git CLI
  return execSync("git rev-parse HEAD", { cwd, encoding: "utf8" }).trim();
}
```

#### Step 2: Gradual Rollout

1. Deploy with feature flag disabled
2. Enable for internal testing
3. Enable for beta users
4. Full rollout after validation

## API Reference

### Core Operations

```c
// Repository management
ziggit_repository_t* ziggit_repo_open(const char* path);
int ziggit_repo_init(const char* path, int bare);
void ziggit_repo_close(ziggit_repository_t* repo);

// Status and information
int ziggit_status(ziggit_repository_t* repo, char* buffer, size_t buffer_size);
int ziggit_is_clean(ziggit_repository_t* repo);
const char* ziggit_version(void);

// Operations
int ziggit_add(ziggit_repository_t* repo, const char* pathspec);
int ziggit_commit_create(ziggit_repository_t* repo, const char* message, 
                         const char* author_name, const char* author_email);
```

### Error Handling

```c
typedef enum {
    ZIGGIT_SUCCESS = 0,
    ZIGGIT_ERROR_NOT_A_REPOSITORY = -1,
    ZIGGIT_ERROR_ALREADY_EXISTS = -2,
    ZIGGIT_ERROR_INVALID_PATH = -3,
    ZIGGIT_ERROR_NOT_FOUND = -4,
    ZIGGIT_ERROR_PERMISSION_DENIED = -5,
    ZIGGIT_ERROR_OUT_OF_MEMORY = -6,
    ZIGGIT_ERROR_NETWORK_ERROR = -7,
    ZIGGIT_ERROR_INVALID_REF = -8,
    ZIGGIT_ERROR_GENERIC = -100
} ziggit_error_t;
```

## WebAssembly Support

Ziggit also supports WebAssembly for browser environments:

```bash
# Build for WASI (Node.js/server)
zig build wasm

# Build for browser  
zig build wasm-browser
```

This enables:
- Browser-based git operations
- Offline git functionality
- Consistent behavior across platforms

## Testing Strategy

### Unit Tests
```bash
cd vendor/ziggit
zig build test
```

### Integration Tests  
```bash
# Test ziggit vs git CLI compatibility
zig build test-compat
```

### Performance Tests
```bash
# Continuous performance monitoring
zig build bench-bun
```

## Migration Checklist

- [ ] Add ziggit as git submodule
- [ ] Build ziggit library successfully  
- [ ] Update build.zig with ziggit dependency
- [ ] Create Zig integration module
- [ ] Replace git CLI calls incrementally
- [ ] Add feature flags for gradual rollout
- [ ] Run performance benchmarks
- [ ] Validate with existing test suite
- [ ] Monitor production performance
- [ ] Document performance improvements

## Rollback Plan

If issues arise:
1. Disable feature flag (`BUN_USE_ZIGGIT=0`)
2. Existing git CLI calls remain as fallback
3. No breaking changes to public APIs
4. Remove ziggit dependency if needed

## Support and Troubleshooting

### Common Issues

1. **Build failures**: Ensure Zig version compatibility
2. **Missing symbols**: Verify library linking in build.zig
3. **Performance regression**: Check feature flag configuration
4. **Test failures**: Validate git compatibility layer

### Performance Monitoring

Track key metrics:
- `bun create` initialization time
- Git status query time  
- Memory usage during git operations
- Build system performance

### Getting Help

- Review benchmark results in `BENCHMARKS.md`
- Check ziggit documentation and examples
- Monitor integration performance in production

## Creating the PR to oven-sh/bun

**IMPORTANT**: Do not create this PR yourself. After completing integration and validation:

1. **Validate Performance**: Ensure benchmarks show expected improvements
2. **Complete Testing**: Run full test suite with ziggit enabled
3. **Document Changes**: Update this guide with actual integration details
4. **Create PR**: Human operator should create PR from hdresearch/bun to oven-sh/bun
5. **Include Benchmarks**: Attach benchmark results and performance analysis
6. **Highlight Benefits**: Emphasize performance improvements and reliability gains

The PR should demonstrate clear performance benefits and maintain full compatibility with existing Bun functionality.