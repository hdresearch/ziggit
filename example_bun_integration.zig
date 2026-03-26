// Example showing how bun could use ziggit as a Zig package
// This demonstrates the ZERO process spawn, ZERO git CLI dependency approach

const std = @import("std");
const ziggit = @import("ziggit"); // bun would import this directly

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🎯 Demonstrating bun + ziggit integration\n", .{});
    std.debug.print("This is pure Zig code - NO process spawning, NO git CLI dependency!\n\n", .{});

    // === SCENARIO: bun create myapp ===
    std.debug.print("📦 Scenario: bun create myapp\n", .{});
    const project_path = "/root/demo_bun_project";
    std.fs.deleteDirAbsolute(project_path) catch {};

    // 1. bun initializes git repo (pure Zig)
    var repo = ziggit.Repository.init(allocator, project_path) catch |err| {
        std.debug.print("❌ Failed to init repo: {any}\n", .{err});
        return;
    };
    defer repo.close();
    std.debug.print("✅ Repository initialized\n", .{});

    // 2. bun creates package.json and other files
    const package_json_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{project_path});
    defer allocator.free(package_json_path);
    
    const package_file = try std.fs.createFileAbsolute(package_json_path, .{ .truncate = true });
    defer package_file.close();
    try package_file.writeAll(
        \\{
        \\  "name": "myapp",
        \\  "version": "1.0.0",
        \\  "type": "module",
        \\  "scripts": {
        \\    "dev": "bun run --hot src/index.ts"
        \\  },
        \\  "devDependencies": {
        \\    "@types/bun": "latest"
        \\  }
        \\}
        \\
    );

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_path});
    defer allocator.free(src_dir);
    std.fs.makeDirAbsolute(src_dir) catch {};

    const index_path = try std.fmt.allocPrint(allocator, "{s}/src/index.ts", .{project_path});
    defer allocator.free(index_path);
    
    const index_file = try std.fs.createFileAbsolute(index_path, .{ .truncate = true });
    defer index_file.close();
    try index_file.writeAll(
        \\console.log("Hello from Bun + Ziggit!");
        \\export default {
        \\  port: 3000,
        \\  fetch(request: Request) {
        \\    return new Response("Hello World!");
        \\  },
        \\};
        \\
    );

    // 3. bun adds files to git (pure Zig - no "git add" process spawn)
    try repo.add("package.json");
    try repo.add("src/index.ts");
    std.debug.print("✅ Files added to git index\n", .{});

    // 4. bun creates initial commit (pure Zig - no "git commit" process spawn)
    const commit_hash = try repo.commit("Initial commit from bun create", "bun", "bun@example.com");
    std.debug.print("✅ Initial commit: {s}\n", .{commit_hash[0..8]});

    // === SCENARIO: bun install (dependency check) ===
    std.debug.print("\n📊 Scenario: bun install (checking if repo is clean)\n", .{});
    
    // bun checks if working tree is clean (pure Zig)
    const is_clean = try repo.isClean();
    std.debug.print("✅ Working tree clean: {any}\n", .{is_clean});

    // bun gets current HEAD for lockfile hash (pure Zig)
    const head_hash = try repo.revParseHead();
    std.debug.print("✅ Current HEAD: {s}\n", .{head_hash[0..8]});

    // === SCENARIO: bun publish ===
    std.debug.print("\n🚀 Scenario: bun publish (version tagging)\n", .{});

    // bun creates a release tag (pure Zig)
    try repo.createTag("v1.0.0", "Release version 1.0.0");
    std.debug.print("✅ Tag created: v1.0.0\n", .{});

    const latest_tag = try repo.latestTag(allocator);
    defer allocator.free(latest_tag);
    std.debug.print("✅ Latest tag: {s}\n", .{latest_tag});

    // === PERFORMANCE DEMONSTRATION ===
    std.debug.print("\n⚡ Performance demonstration:\n", .{});
    
    const start_time = std.time.nanoTimestamp();
    for (0..100) |_| {
        _ = try repo.revParseHead();
        _ = try repo.isClean();
        const status = try repo.statusPorcelain(allocator);
        allocator.free(status);
    }
    const end_time = std.time.nanoTimestamp();
    const elapsed_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
    
    std.debug.print("✅ 100 iterations of (rev-parse HEAD + isClean + status --porcelain): {d:.2}ms\n", .{elapsed_ms});
    std.debug.print("   That's {d:.3}ms per operation - ZERO process spawn overhead!\n", .{elapsed_ms / 100.0});

    std.debug.print("\n🎯 RESULT: Bun can call Zig functions directly.\n", .{});
    std.debug.print("   No process spawning, no git CLI dependency, no C FFI.\n", .{});
    std.debug.print("   The Zig compiler optimizes everything together.\n", .{});

    // Cleanup
    std.fs.deleteDirAbsolute(project_path) catch {};
}