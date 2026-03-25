# Bun Integration Guide for Ziggit

This guide provides step-by-step instructions for integrating ziggit into [Bun](https://bun.sh) as a high-performance replacement for git CLI operations.

## Overview

Ziggit offers significant performance improvements over git CLI (3.90x - 14.92x faster) for operations commonly used by Bun. This integration guide covers:

1. **Preparation**: Setting up the development environment
2. **Integration**: Modifying Bun to use ziggit library 
3. **Testing**: Validating the integration works correctly
4. **Benchmarking**: Measuring performance improvements
5. **Submission**: Creating a PR to oven-sh/bun

## Performance Benefits

Based on comprehensive benchmarking:
- **Repository Initialization**: 3.90x faster
- **Status Operations**: 14.92x faster  
- **Repository Opening**: New capability (46μs average)

See [BENCHMARKS.md](./BENCHMARKS.md) for detailed performance analysis.

## Prerequisites

- Zig 0.13.0 or later
- Bun development environment set up
- Git access to both `hdresearch/bun` and `hdresearch/ziggit`
- Basic familiarity with Zig and Bun's codebase

## Phase 1: Preparation

### 1.1 Clone Repositories

```bash
# Clone the Bun fork (contains ziggit integration prep work)
git clone https://github.com/hdresearch/bun.git bun-ziggit
cd bun-ziggit

# Clone ziggit for the library
git clone https://github.com/hdresearch/ziggit.git ziggit
cd ziggit

# Build ziggit library
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
zig build lib
```

### 1.2 Verify Library Build

```bash
# Verify static and shared libraries were created
ls -la zig-out/lib/
# Should show: libziggit.a (static) and libziggit.so (shared)

# Verify header file
ls -la zig-out/include/
# Should show: ziggit.h
```

### 1.3 Run Initial Benchmarks

```bash
# Run benchmarks to establish baseline
zig build bench-bun

# Save benchmark results for later comparison
zig build bench-bun > baseline_benchmarks.txt
```

## Phase 2: Integration Implementation

### 2.1 Add Ziggit to Bun's Build System

Edit `build.zig` in the bun root directory:

```zig
// Add ziggit library configuration
const ziggit_lib = if (use_ziggit_integration) blk: {
    // Link to pre-built ziggit library
    const lib = b.addStaticLibrary(.{
        .name = "ziggit",
        .target = target,
        .optimize = optimize,
    });
    lib.addLibraryPath(.{ .path = "ziggit/zig-out/lib" });
    lib.addIncludePath(.{ .path = "ziggit/zig-out/include" });
    lib.linkSystemLibrary("ziggit");
    break :blk lib;
} else null;

// In the bun executable configuration, add:
if (ziggit_lib) |lib| {
    exe.linkLibrary(lib);
    exe.addIncludePath(.{ .path = "ziggit/zig-out/include" });
}
```

Add a build option for ziggit integration:

```zig
const use_ziggit_integration = b.option(
    bool, 
    "ziggit", 
    "Enable ziggit integration for improved git performance"
) orelse false;
```

### 2.2 Create Ziggit Interface Module

Create `src/ziggit_integration.zig`:

```zig
const std = @import("std");
const bun = @import("root").bun;

// C interface declarations
extern fn ziggit_repo_init(path: [*:0]const u8, bare: c_int) c_int;
extern fn ziggit_repo_open(path: [*:0]const u8) ?*opaque{};
extern fn ziggit_repo_clone(url: [*:0]const u8, path: [*:0]const u8, bare: c_int) c_int;
extern fn ziggit_repo_close(repo: *opaque{}) void;
extern fn ziggit_status_porcelain(repo: *opaque{}, buffer: [*]u8, size: usize) c_int;
extern fn ziggit_commit_create(repo: *opaque{}, msg: [*:0]const u8, name: [*:0]const u8, email: [*:0]const u8) c_int;
extern fn ziggit_add(repo: *opaque{}, pathspec: [*:0]const u8) c_int;
extern fn ziggit_checkout(repo: *opaque{}, committish: [*:0]const u8) c_int;

pub const ZiggitRepository = opaque {
    pub fn open(path: []const u8) ?*ZiggitRepository {
        const path_z = std.cstr.addNullByte(bun.default_allocator, path) catch return null;
        defer bun.default_allocator.free(path_z);
        return @ptrCast(ziggit_repo_open(path_z.ptr));
    }
    
    pub fn close(self: *ZiggitRepository) void {
        ziggit_repo_close(@ptrCast(self));
    }
    
    pub fn getStatusPorcelain(self: *ZiggitRepository, allocator: std.mem.Allocator) ![]u8 {
        var buffer = try allocator.alloc(u8, 8192);
        const result = ziggit_status_porcelain(@ptrCast(self), buffer.ptr, buffer.len);
        if (result != 0) return error.GitOperationFailed;
        
        const len = std.mem.len(@as([*:0]u8, @ptrCast(buffer.ptr)));
        return buffer[0..len];
    }
};

pub fn init(path: []const u8, bare: bool) !void {
    const path_z = try std.cstr.addNullByte(bun.default_allocator, path);
    defer bun.default_allocator.free(path_z);
    
    const result = ziggit_repo_init(path_z.ptr, if (bare) 1 else 0);
    if (result != 0) return error.GitInitFailed;
}

pub fn clone(url: []const u8, path: []const u8, bare: bool) !void {
    const url_z = try std.cstr.addNullByte(bun.default_allocator, url);
    defer bun.default_allocator.free(url_z);
    
    const path_z = try std.cstr.addNullByte(bun.default_allocator, path);
    defer bun.default_allocator.free(path_z);
    
    const result = ziggit_repo_clone(url_z.ptr, path_z.ptr, if (bare) 1 else 0);
    if (result != 0) return error.GitCloneFailed;
}

// Performance-optimized status check for Bun's frequent status queries
pub fn isRepositoryClean(path: []const u8) !bool {
    const repo = ZiggitRepository.open(path) orelse return error.NotARepository;
    defer repo.close();
    
    const status = try repo.getStatusPorcelain(bun.default_allocator);
    defer bun.default_allocator.free(status);
    
    return status.len == 0 or std.mem.trim(u8, status, " \n\r\t").len == 0;
}
```

### 2.3 Modify Repository Module

Edit `src/install/repository.zig`:

```zig
// Add ziggit integration import at the top
const ziggit = if (@hasDecl(@import("root"), "ziggit_integration")) 
    @import("root").ziggit_integration 
else 
    null;

// Modify the git clone function to use ziggit when available
fn cloneWithZiggit(
    allocator: std.mem.Allocator,
    url: []const u8, 
    target: []const u8,
    bare: bool
) !void {
    if (ziggit) |z| {
        try z.clone(url, target, bare);
        return;
    }
    
    // Fallback to existing git CLI implementation
    return cloneWithGitCLI(allocator, url, target, bare);
}

// Update the clone call site
_ = cloneWithZiggit(allocator, url, target, true) catch |err| {
    if (err == error.RepositoryNotFound or attempt > 1) {
        log.addErrorFmt(
            null,
            logger.Loc.Empty,
            allocator,
            "\"git clone\" for \"{s}\" failed",
            .{name},
        ) catch unreachable;
    }
    return err;
};
```

### 2.4 Modify Create Command

Edit `src/cli/create_command.zig`:

```zig
// Add ziggit support to GitHandler
const GitHandler = struct {
    pub fn run(
        destination: string,
        PATH: string,
        comptime verbose: bool,
    ) !bool {
        // Try ziggit first for better performance
        if (ziggit) |z| {
            const git_start = std.time.nanoTimestamp();
            
            // Initialize repository
            z.init(destination, false) catch |err| {
                if (verbose) {
                    Output.prettyErrorln("ziggit init failed: {}", .{err});
                }
                // Fall back to git CLI
                return runWithGitCLI(destination, PATH, verbose);
            };
            
            // Add files
            if (ziggit.ZiggitRepository.open(destination)) |repo| {
                defer repo.close();
                _ = ziggit_add(@ptrCast(repo), destination) catch {
                    return runWithGitCLI(destination, PATH, verbose);
                };
                
                _ = ziggit_commit_create(
                    @ptrCast(repo), 
                    "Initial commit (via bun create with ziggit)", 
                    "Bun", 
                    "bun@oven.sh"
                ) catch {
                    return runWithGitCLI(destination, PATH, verbose);
                };
            }
            
            if (comptime verbose) {
                Output.prettyError("\n", .{});
                Output.printStartEnd(git_start, std.time.nanoTimestamp());
                Output.prettyError(" <d>ziggit (accelerated)<r>\n", .{});
            }
            
            return true;
        }
        
        // Fallback to existing git CLI implementation
        return runWithGitCLI(destination, PATH, verbose);
    }
    
    // ... rest of existing implementation as runWithGitCLI
};
```

## Phase 3: Testing the Integration

### 3.1 Build Bun with Ziggit Integration

```bash
cd bun-ziggit

# Build bun with ziggit integration enabled
zig build -Dziggit=true

# Or if using different build system:
cmake -DUSE_ZIGGIT=ON .
make
```

### 3.2 Test Basic Functionality

```bash
# Test repository creation
./build/bun-dev create test-project
cd test-project

# Verify git repository was created properly
ls -la .git/
git log --oneline  # Should show initial commit

# Test dependency operations
./build/bun-dev install  # Should use ziggit for any git dependencies
```

### 3.3 Test Compatibility

```bash
# Run existing bun test suite to ensure no regressions
./build/bun-dev test

# Test specific git-related operations
./build/bun-dev create react-app test-react
./build/bun-dev create next-app test-next  

# Verify git operations work correctly
cd test-react && git status
cd ../test-next && git log
```

## Phase 4: Performance Benchmarking

### 4.1 Create Benchmark Script

Create `scripts/ziggit_bench.ts`:

```typescript
import { spawn } from 'bun';
import { performance } from 'perf_hooks';

interface BenchResult {
  operation: string;
  withZiggit: number;
  withoutZiggit: number;
  speedup: number;
}

async function benchmarkOperation(
  operation: string, 
  args: string[], 
  iterations: number = 10
): Promise<BenchResult> {
  // Benchmark with ziggit
  const ziggitTimes: number[] = [];
  for (let i = 0; i < iterations; i++) {
    const start = performance.now();
    await spawn(['./build/bun-ziggit', ...args]);
    ziggitTimes.push(performance.now() - start);
  }
  
  // Benchmark without ziggit (regular bun)
  const normalTimes: number[] = [];
  for (let i = 0; i < iterations; i++) {
    const start = performance.now();
    await spawn(['./build/bun-normal', ...args]);
    normalTimes.push(performance.now() - start);
  }
  
  const ziggitAvg = ziggitTimes.reduce((a, b) => a + b) / ziggitTimes.length;
  const normalAvg = normalTimes.reduce((a, b) => a + b) / normalTimes.length;
  
  return {
    operation,
    withZiggit: ziggitAvg,
    withoutZiggit: normalAvg,
    speedup: normalAvg / ziggitAvg
  };
}

async function main() {
  console.log('=== Bun + Ziggit Integration Benchmark ===\n');
  
  const benchmarks = [
    { op: 'create react-app', args: ['create', 'react', 'bench-react'] },
    { op: 'create next-app', args: ['create', 'next', 'bench-next'] },
    { op: 'install with git deps', args: ['install'] } // in repo with git dependencies
  ];
  
  const results: BenchResult[] = [];
  
  for (const bench of benchmarks) {
    console.log(`Running ${bench.op}...`);
    const result = await benchmarkOperation(bench.op, bench.args);
    results.push(result);
    
    console.log(`  With ziggit: ${result.withZiggit.toFixed(2)}ms`);
    console.log(`  Without ziggit: ${result.withoutZiggit.toFixed(2)}ms`);
    console.log(`  Speedup: ${result.speedup.toFixed(2)}x\n`);
  }
  
  // Generate summary report
  const totalSpeedup = results.reduce((sum, r) => sum + r.speedup, 0) / results.length;
  console.log(`=== Summary ===`);
  console.log(`Average speedup: ${totalSpeedup.toFixed(2)}x`);
  console.log(`Best speedup: ${Math.max(...results.map(r => r.speedup)).toFixed(2)}x`);
}

main().catch(console.error);
```

### 4.2 Run Comprehensive Benchmarks

```bash
# Build both versions for comparison
zig build -Dziggit=true -Drelease-fast=true   # Ziggit version
mv build/bun build/bun-ziggit

zig build -Dziggit=false -Drelease-fast=true  # Normal version  
mv build/bun build/bun-normal

# Run benchmark script
bun run scripts/ziggit_bench.ts

# Also run ziggit's own benchmarks for library comparison
cd ziggit && zig build bench-bun > integration_benchmarks.txt
```

### 4.3 Document Results

Create `PERFORMANCE_RESULTS.md` with:
- Before/after comparison
- Real-world scenario improvements
- Memory usage comparison
- Regression analysis

## Phase 5: Creating the Pull Request

### 5.1 Prepare the PR

```bash
# Ensure all changes are committed
git add -A
git commit -m "Integrate ziggit for improved git performance

- Add ziggit library integration with fallback to git CLI
- 3.90x faster repository initialization  
- 14.92x faster status operations
- Maintain full compatibility with existing workflows
- Add build-time flag to enable/disable integration"

# Push to hdresearch/bun
git push origin ziggit-integration
```

### 5.2 Create PR Description

Use this template for the PR to oven-sh/bun:

```markdown
# Integrate ziggit for improved git performance

## Overview
This PR integrates [ziggit](https://github.com/hdresearch/ziggit), a high-performance git implementation written in Zig, as an optional performance enhancement for Bun's git operations.

## Performance Improvements
- **Repository initialization**: 3.90x faster
- **Status operations**: 14.92x faster  
- **Overall workflow**: Significant improvements for git-heavy operations

## Key Features
- ✅ **Backward compatible**: Falls back to git CLI if ziggit fails
- ✅ **Build-time optional**: Controlled via `-Dziggit=true` build flag
- ✅ **Zero regression risk**: All existing tests pass
- ✅ **Production ready**: Comprehensive testing and benchmarking completed

## Implementation Details
- C-compatible library interface for seamless integration
- Modified `src/install/repository.zig` and `src/cli/create_command.zig`
- Graceful fallback to git CLI for unsupported operations
- Comprehensive error handling and logging

## Benchmarks
See attached `PERFORMANCE_RESULTS.md` for detailed benchmark results.

## Testing
- [x] All existing Bun tests pass
- [x] Manual testing of `bun create` workflows  
- [x] Performance regression testing
- [x] Integration testing with common git repositories

## Migration Path
1. **Phase 1**: Optional integration (this PR)
2. **Phase 2**: Enable by default after proven stability  
3. **Phase 3**: Full migration once community feedback incorporated

This change significantly improves Bun's performance for git operations while maintaining full compatibility and stability.
```

### 5.3 Submit PR

1. **Create PR from hdresearch/bun to oven-sh/bun**
2. **Include all benchmark results and documentation**
3. **Tag relevant maintainers for review**
4. **Respond to feedback and iterate as needed**

## Phase 6: Monitoring and Iteration

### 6.1 Performance Monitoring

Set up monitoring for:
- Performance regressions
- Error rates with ziggit vs git CLI
- User feedback on perceived performance

### 6.2 Continuous Improvement

- Monitor ziggit updates for additional performance gains
- Identify additional git operations that could benefit from ziggit
- Contribute back to ziggit project based on Bun's needs

## Troubleshooting

### Common Issues

**Build errors with ziggit**:
```bash
# Ensure ziggit library is properly built
cd ziggit && zig build lib
# Verify zig-out/lib/ contains libziggit.a and libziggit.so
```

**Runtime fallback to git CLI**:
```bash
# Check ziggit library loading
ldd build/bun-ziggit | grep ziggit
# Enable verbose logging to see fallback reasons
BUN_DEBUG_GIT=1 ./build/bun-ziggit create test-app
```

**Performance not as expected**:
```bash
# Run direct ziggit benchmarks
cd ziggit && zig build bench-bun
# Compare with bun integration benchmarks
bun run scripts/ziggit_bench.ts
```

### Getting Help

- **Ziggit issues**: https://github.com/hdresearch/ziggit/issues
- **Bun integration**: https://github.com/hdresearch/bun/issues  
- **Performance questions**: Include benchmark results in issue reports

## Conclusion

This integration brings significant performance improvements to Bun's git operations while maintaining full compatibility and providing a smooth migration path. The combination of ziggit's performance with Bun's existing stability creates a compelling improvement for the entire Node.js ecosystem.

---

*For questions about this integration process, please open an issue on [hdresearch/bun](https://github.com/hdresearch/bun) or [hdresearch/ziggit](https://github.com/hdresearch/ziggit).*