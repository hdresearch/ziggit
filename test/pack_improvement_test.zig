const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");

test "pack file hash validation improvements" {
    const allocator = testing.allocator;
    
    // Test invalid hash length
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                _ = alloc;
                _ = path;
                return error.FileNotFound;
            }
        };
    };
    
    // Test with invalid hash length
    const result = objects.GitObject.load("abc", "/tmp", TestPlatform, allocator);
    try testing.expectError(error.InvalidHashLength, result);
    
    // Test with invalid hash characters
    const result2 = objects.GitObject.load("gggggggggggggggggggggggggggggggggggggggg", "/tmp", TestPlatform, allocator);
    try testing.expectError(error.InvalidHashCharacter, result2);
    
    std.debug.print("Pack file validation improvements working correctly\n", .{});
}

test "config boolean parsing improvements" {
    const config = @import("../src/git/config.zig");
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const config_content =
        \\[core]
        \\    emptyvalue =
        \\    numericvalue = 42
        \\    zerovalue = 0
    ;
    
    try git_config.parseFromString(config_content);
    
    // Empty value should be true
    try testing.expect(git_config.getBool("core", null, "emptyvalue", false));
    
    // Non-zero numeric should be true
    try testing.expect(git_config.getBool("core", null, "numericvalue", false));
    
    // Zero should be false
    try testing.expect(!git_config.getBool("core", null, "zerovalue", true));
    
    std.debug.print("Config boolean parsing improvements working correctly\n", .{});
}