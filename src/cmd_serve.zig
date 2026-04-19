const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const git_serve = @import("git/git_serve.zig");

pub fn cmdServe(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var port: u16 = 9418;
    var repo_path: []const u8 = ".";
    
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            const port_str = arg["--port=".len..];
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                try platform_impl.writeStderr("Invalid port number\\n");
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--repo=")) {
            repo_path = arg["--repo=".len..];
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            repo_path = arg;
        }
    }
    
    var server = git_serve.GitServer.init(allocator, repo_path);
    defer server.deinit();
    
    try platform_impl.writeStdout("Starting git server on port ");
    var port_buf: [16]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
    try platform_impl.writeStdout(port_str);
    try platform_impl.writeStdout("\\n");
    try platform_impl.writeStdout("Repository: ");
    try platform_impl.writeStdout(repo_path);
    try platform_impl.writeStdout("\\n");
    
    try server.serve(port);
}
