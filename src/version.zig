const std = @import("std");

pub const VERSION = "0.1.1";
pub const GIT_COMPAT_VERSION = "2.34.1"; // Git version we aim to be compatible with

pub fn getVersionString(allocator: std.mem.Allocator) ![]u8 {
    const target_info = switch (@import("builtin").target.os.tag) {
        .wasi => " (WASI)",
        .freestanding => " (Browser)",
        else => "",
    };
    
    return try std.fmt.allocPrint(allocator, "ziggit version {s}{s}", .{ VERSION, target_info });
}

pub fn getFullVersionInfo(allocator: std.mem.Allocator) ![]u8 {
    const target_info = switch (@import("builtin").target.os.tag) {
        .wasi => " (WASI)",
        .freestanding => " (Browser)",
        else => "",
    };
    
    return try std.fmt.allocPrint(allocator, 
        \\ziggit version {s}{s}
        \\Git compatibility target: {s}
        \\Built with Zig {s}
        \\
    , .{ VERSION, target_info, GIT_COMPAT_VERSION, @import("builtin").zig_version_string });
}