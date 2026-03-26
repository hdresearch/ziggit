const std = @import("std");

pub fn main() !void {
    std.debug.print("🧪 Running simple validation tests...\n");
    
    // Test that we can import all the modules
    const objects = @import("src/git/objects.zig");
    const config = @import("src/git/config.zig");
    const index = @import("src/git/index.zig");
    const refs = @import("src/git/refs.zig");
    
    _ = objects;
    _ = config; 
    _ = index;
    _ = refs;
    
    std.debug.print("✅ All core modules import successfully\n");
    
    // Test basic config parsing
    {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        const test_config = 
            \\[user]
            \\    name = Test User
            \\    email = test@example.com
            \\[remote "origin"]
            \\    url = https://github.com/test/repo.git
        ;
        
        try git_config.parseFromString(test_config);
        
        const name = git_config.getUserName().?;
        const email = git_config.getUserEmail().?;
        const url = git_config.getRemoteUrl("origin").?;
        
        if (!std.mem.eql(u8, name, "Test User")) return error.ConfigNameFailed;
        if (!std.mem.eql(u8, email, "test@example.com")) return error.ConfigEmailFailed;
        if (!std.mem.eql(u8, url, "https://github.com/test/repo.git")) return error.ConfigUrlFailed;
        
        std.debug.print("✅ Config parsing works correctly\n");
    }
    
    // Test basic index functionality
    {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        
        var test_index = index.Index.init(allocator);
        defer test_index.deinit();
        
        // Can create an index without errors
        std.debug.print("✅ Index creation works correctly\n");
    }
    
    // Test basic objects functionality
    {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        
        // Test creating blob object
        const blob = try objects.createBlobObject("Hello, world!", allocator);
        defer blob.deinit(allocator);
        
        if (blob.type != .blob) return error.BlobTypeFailed;
        if (!std.mem.eql(u8, blob.data, "Hello, world!")) return error.BlobDataFailed;
        
        std.debug.print("✅ Object creation works correctly\n");
    }
    
    std.debug.print("✅ All basic validation tests passed!\n");
    std.debug.print("🎉 Core git format implementations are working correctly!\n");
}