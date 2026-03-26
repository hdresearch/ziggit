// test/bun_zig_api_test.zig - Bun workflow test using ziggit as pure Zig package
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

test "bun workflow - pure Zig, no git CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_path = "/tmp/zig_api_test";
    std.fs.deleteTreeAbsolute(test_path) catch {};
    
    // 1. init repo
    var repo = try ziggit.Repository.init(allocator, test_path);
    defer repo.close();

    // 2. create a file, add it, commit
    const package_json_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{test_path});
    const package_file = try std.fs.createFileAbsolute(package_json_path, .{ .truncate = true });
    defer package_file.close();
    try package_file.writeAll("{\n  \"name\": \"test\",\n  \"version\": \"1.0.0\"\n}\n");
    
    try repo.add("package.json");
    const hash = try repo.commit("Initial commit", "test", "test@test.com");

    // 3. read operations bun uses
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&hash, &head);

    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
    try testing.expectEqualStrings("", status); // clean

    // 4. create tag
    try repo.createTag("v1.0.0", "v1.0.0");
    const tag = try repo.describeTags(allocator);
    defer allocator.free(tag);
    try testing.expectEqualStrings("v1.0.0", tag);

    // 5. verify git can read what we wrote
    const git_log_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "log", "--oneline" },
        .cwd = test_path,
    });
    defer allocator.free(git_log_result.stdout);
    defer allocator.free(git_log_result.stderr);
    
    try testing.expect(git_log_result.stdout.len > 0);
    
    std.fs.deleteTreeAbsolute(test_path) catch {};
}