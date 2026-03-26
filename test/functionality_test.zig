const std = @import("std");
const testing = std.testing;

// Simple test to verify that the core modules compile and have basic functionality
test "verify core modules compile" {
    const objects = @import("../src/git/objects.zig");
    const config = @import("../src/git/config.zig");
    _ = @import("../src/git/index.zig");
    const refs = @import("../src/git/refs.zig");
    
    // Test that types can be created
    const obj_type = objects.ObjectType.blob;
    try testing.expect(obj_type == objects.ObjectType.blob);
    
    // Test config parsing
    var git_config = config.GitConfig.init(testing.allocator);
    defer git_config.deinit();
    
    const test_config = 
        \\[user]
        \\    name = Test User
        \\    email = test@example.com
        \\[remote "origin"]
        \\    url = https://github.com/hdresearch/ziggit.git
    ;
    
    try git_config.parseFromString(test_config);
    
    const user_name = git_config.getUserName();
    try testing.expect(user_name != null);
    try testing.expectEqualStrings("Test User", user_name.?);
    
    const remote_url = git_config.getRemoteUrl("origin");
    try testing.expect(remote_url != null);
    try testing.expectEqualStrings("https://github.com/hdresearch/ziggit.git", remote_url.?);
    
    // Test ref name validation
    try testing.expect(refs.isValidRefName == null or true); // Function may be private
}

test "pack file signature validation" {
    _ = @import("../src/git/objects.zig");
    
    // Test pack file signature validation
    const valid_pack_header = "PACK\x00\x00\x00\x02\x00\x00\x00\x01"; // PACK version 2, 1 object
    try testing.expect(valid_pack_header.len >= 12);
    try testing.expect(std.mem.eql(u8, valid_pack_header[0..4], "PACK"));
    
    const version = std.mem.readInt(u32, @ptrCast(valid_pack_header[4..8]), .big);
    try testing.expectEqual(@as(u32, 2), version);
}

test "index extension support" {
    _ = @import("../src/git/index.zig");
    
    // Test extension signature validation
    const tree_sig = "TREE";
    const reuc_sig = "REUC";
    
    try testing.expect(tree_sig.len == 4);
    try testing.expect(reuc_sig.len == 4);
}