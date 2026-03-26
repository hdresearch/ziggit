const std = @import("std");
const objects = @import("src/git/objects.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with the pack files we created earlier
    const pack_dir = "/root/ziggit/test_simple_pack/.git/objects/pack";
    
    std.debug.print("Checking pack files in: {s}\n", .{pack_dir});
    
    // List pack files
    var pack_dir_handle = std.fs.cwd().openDir(pack_dir, .{.iterate = true}) catch |err| {
        std.debug.print("Failed to open pack dir: {}\n", .{err});
        return;
    };
    defer pack_dir_handle.close();
    
    var iterator = pack_dir_handle.iterate();
    while (try iterator.next()) |entry| {
        std.debug.print("Found: {s}\n", .{entry.name});
        
        if (std.mem.endsWith(u8, entry.name, ".idx")) {
            // Try to parse this index file
            const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_dir, entry.name});
            defer allocator.free(idx_path);
            
            std.debug.print("Parsing pack index: {s}\n", .{idx_path});
            
            const idx_data = std.fs.cwd().readFileAlloc(allocator, idx_path, 10*1024*1024) catch |err| {
                std.debug.print("Failed to read index file: {}\n", .{err});
                continue;
            };
            defer allocator.free(idx_data);
            
            std.debug.print("Index file size: {} bytes\n", .{idx_data.len});
            
            // Check magic and version
            if (idx_data.len >= 8) {
                const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
                const version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
                std.debug.print("Magic: 0x{x}, Version: {}\n", .{magic, version});
                
                if (magic == 0xff744f63) {
                    std.debug.print("Valid v2 pack index\n", .{});
                    
                    // Check fanout table
                    const fanout_start = 8;
                    if (idx_data.len >= fanout_start + 256 * 4) {
                        const total_objects = std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + 255 * 4..fanout_start + 255 * 4 + 4]), .big);
                        std.debug.print("Total objects: {}\n", .{total_objects});
                    }
                } else {
                    std.debug.print("Possibly v1 pack index\n", .{});
                    
                    // Check fanout for v1
                    if (idx_data.len >= 256 * 4) {
                        const total_objects = std.mem.readInt(u32, @ptrCast(idx_data[255 * 4..255 * 4 + 4]), .big);
                        std.debug.print("Total objects (v1): {}\n", .{total_objects});
                    }
                }
            }
        }
    }
}

test "pack direct test" {
    try main();
}