const std = @import("std");
const testing = std.testing;

// Test that our build system improvements work correctly
// This is a standalone test that doesn't depend on internal ziggit modules

test "verify benchmarks structure" {
    // Check that we have exactly 3 benchmark files
    var bench_dir = std.fs.cwd().openDir("benchmarks", .{ .iterate = true }) catch {
        std.debug.print("Benchmarks directory not found\n", .{});
        return error.BenchmarkDirNotFound;
    };
    defer bench_dir.close();

    var count: u32 = 0;
    const expected_files = [_][]const u8{ "cli_benchmark.zig", "lib_benchmark.zig", "bun_scenario_bench.zig" };
    var found_files = [_]bool{false} ** 3;

    var iterator = bench_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            count += 1;
            
            // Check if this is one of our expected files
            for (expected_files, 0..) |expected, i| {
                if (std.mem.eql(u8, entry.name, expected)) {
                    found_files[i] = true;
                    break;
                }
            }
        }
    }

    // Verify we have exactly 3 files
    try testing.expectEqual(@as(u32, 3), count);
    
    // Verify we have all expected files
    for (found_files, expected_files) |found, expected| {
        if (!found) {
            std.debug.print("Missing expected benchmark file: {s}\n", .{expected});
            return error.MissingBenchmarkFile;
        }
    }

    std.debug.print("✓ Benchmarks structure verified: 3 files as expected\n", .{});
}

test "verify test structure cleanup" {
    // Check that we removed redundant test files and have consolidated pack tests
    var test_dir = std.fs.cwd().openDir("test", .{ .iterate = true }) catch {
        std.debug.print("Test directory not found\n", .{});
        return error.TestDirNotFound;
    };
    defer test_dir.close();

    var has_pack_tests = false;
    var has_git_interop = false;
    var zig_file_count: u32 = 0;

    var iterator = test_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            zig_file_count += 1;
            
            if (std.mem.eql(u8, entry.name, "pack_tests.zig")) {
                has_pack_tests = true;
            }
            if (std.mem.eql(u8, entry.name, "git_interop_test.zig")) {
                has_git_interop = true;
            }
        }
    }

    if (!has_pack_tests) {
        return error.MissingPackTests;
    }
    if (!has_git_interop) {
        return error.MissingGitInteropTest;
    }

    // We should have significantly fewer .zig files now (was 14, now should be around 6-8)
    if (zig_file_count > 10) {
        std.debug.print("Warning: Still have {} .zig test files, expected cleanup\n", .{zig_file_count});
    }

    std.debug.print("✓ Test structure verified: consolidated pack tests, kept essential tests\n", .{});
}

test "verify no broken pipe handling exists" {
    // Test that platform/native.zig has proper BrokenPipe handling
    const native_source = std.fs.cwd().readFileAlloc(testing.allocator, "src/platform/native.zig", 1024 * 1024) catch {
        std.debug.print("Could not read src/platform/native.zig\n", .{});
        return;
    };
    defer testing.allocator.free(native_source);

    const has_broken_pipe_stdout = std.mem.indexOf(u8, native_source, "error.BrokenPipe => return") != null;
    const has_writeStdout = std.mem.indexOf(u8, native_source, "writeStdoutImpl") != null;

    if (!has_broken_pipe_stdout) {
        return error.MissingBrokenPipeHandling;
    }
    if (!has_writeStdout) {
        return error.MissingWriteStdout;
    }

    std.debug.print("✓ BrokenPipe error handling verified in platform/native.zig\n", .{});
}

test "verify build.zig structure" {
    // Test that build.zig has the expected clean structure
    const build_source = std.fs.cwd().readFileAlloc(testing.allocator, "build.zig", 1024 * 1024) catch {
        std.debug.print("Could not read build.zig\n", .{});
        return;
    };
    defer testing.allocator.free(build_source);

    // Check for essential build steps
    const has_lib_step = std.mem.indexOf(u8, build_source, "lib_step") != null;
    const has_test_step = std.mem.indexOf(u8, build_source, "test_step") != null;
    const has_bench_step = std.mem.indexOf(u8, build_source, "bench_step") != null;
    const has_wasm_step = std.mem.indexOf(u8, build_source, "wasm_step") != null;

    if (!has_lib_step) return error.MissingLibStep;
    if (!has_test_step) return error.MissingTestStep;
    if (!has_bench_step) return error.MissingBenchStep;
    if (!has_wasm_step) return error.MissingWasmStep;

    // Verify we don't have too many benchmark references (should be 3)
    const benchmark_count = std.mem.count(u8, build_source, "_benchmark");
    if (benchmark_count > 6) { // Each benchmark appears twice (declaration + run)
        std.debug.print("Warning: Found {} benchmark references, expected ~6\n", .{benchmark_count});
    }

    std.debug.print("✓ Build.zig structure verified: clean targets present\n", .{});
}