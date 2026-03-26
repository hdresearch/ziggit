const std = @import("std");

// Import the C API functions
extern fn ziggit_repo_open(path: [*:0]const u8) ?*opaque;
extern fn ziggit_repo_close(repo: *opaque) void;
extern fn ziggit_status_porcelain(repo: *opaque, buffer: [*]u8, buffer_size: usize) c_int;

pub fn main() !void {
    // Test in /tmp/status_test
    const repo_path = "/tmp/status_test";

    std.debug.print("Testing ziggit library status function...\n", .{});
    
    const repo = ziggit_repo_open(repo_path) orelse {
        std.debug.print("Failed to open repository\n", .{});
        return;
    };
    defer ziggit_repo_close(repo);

    var buffer: [4096]u8 = undefined;
    const result = ziggit_status_porcelain(repo, &buffer, buffer.len);
    if (result != 0) {
        std.debug.print("Failed to get status: error code {}\n", .{result});
        return;
    }

    const status = std.mem.trim(u8, std.mem.sliceTo(&buffer, 0), " \n\r\t");
    std.debug.print("Ziggit library status: '{s}'\n", .{status});
}