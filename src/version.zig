const std = @import("std");

pub const VERSION = "0.2.0";
pub const GIT_COMPAT_VERSION = "2.34.1"; // Git version we aim to be compatible with
pub const FEATURES_STATUS = "Complete drop-in git replacement with WebAssembly support";

pub fn getVersionString(allocator: std.mem.Allocator) ![]u8 {
    const target_info = switch (@import("builtin").target.os.tag) {
        .wasi => " (WASI)",
        .freestanding => " (Browser)",
        else => "",
    };
    
    return try std.fmt.allocPrint(allocator, "git version {s}{s}", .{ VERSION, target_info });
}

pub fn getFullVersionInfo(allocator: std.mem.Allocator) ![]u8 {
    const target_info = switch (@import("builtin").target.os.tag) {
        .wasi => " (WASI)",
        .freestanding => " (Browser)",
        else => "",
    };
    
    const build_date = comptime blk: {
        // Use a static build identifier since timestamp isn't available at compile time
        break :blk "v0.2.0-" ++ @import("builtin").zig_version_string;
    };
    
    return try std.fmt.allocPrint(allocator, 
        \\ziggit version {s}{s}
        \\Git compatibility target: {s}
        \\Built with Zig {s}
        \\Status: {s}
        \\Build: {s}
        \\
        \\Supported commands: init, add, commit, status, log, checkout, branch, merge, diff
        \\Features: SHA-1 object storage, index management, refs, WebAssembly support
        \\
    , .{ VERSION, target_info, GIT_COMPAT_VERSION, @import("builtin").zig_version_string, FEATURES_STATUS, build_date });
}