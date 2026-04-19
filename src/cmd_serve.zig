const std = @import("std");
const platform_mod = @import("platform/platform.zig");

pub fn cmdServe(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = allocator;
    _ = args;
    try platform_impl.writeStderr("ziggit serve: command reached successfully but not implemented\n");
    std.process.exit(1);
}
