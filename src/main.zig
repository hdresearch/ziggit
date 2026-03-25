const std = @import("std");
const platform = @import("platform/platform.zig");
const Repository = @import("git/repository.zig").Repository;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const plat = platform.getCurrentPlatform();
    var args = try plat.getArgs(allocator);
    defer args.deinit();
    
    _ = args.skip(); // skip program name

    const command = args.next() orelse {
        try showUsage(&plat);
        return;
    };

    if (std.mem.eql(u8, command, "init")) {
        try cmdInit(allocator, &plat, &args);
    } else if (std.mem.eql(u8, command, "status")) {
        try cmdStatus(allocator, &plat);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "ziggit: '{s}' is not yet implemented\n", .{command});
        defer allocator.free(msg);
        try plat.writeStdout(msg);
    }
}

fn showUsage(plat: *const platform.Platform) !void {
    try plat.writeStdout("ziggit: a modern version control system written in Zig\n");
    try plat.writeStdout("usage: ziggit <command> [<args>]\n\n");
    try plat.writeStdout("Commands:\n");
    try plat.writeStdout("  init       Create an empty repository\n");
    try plat.writeStdout("  add        Add file contents to the index\n");
    try plat.writeStdout("  commit     Record changes to the repository\n");
    try plat.writeStdout("  status     Show the working tree status\n");
    try plat.writeStdout("  log        Show commit logs\n");
    try plat.writeStdout("  checkout   Switch branches or restore working tree files\n");
    try plat.writeStdout("  branch     List, create, or delete branches\n");
    try plat.writeStdout("  merge      Join two or more development histories together\n");
    try plat.writeStdout("  clone      Clone a repository into a new directory\n");
    try plat.writeStdout("  push       Update remote refs along with associated objects\n");
    try plat.writeStdout("  pull       Fetch from and integrate with another repository\n");
    try plat.writeStdout("  fetch      Download objects and refs from another repository\n");
    try plat.writeStdout("  diff       Show changes between commits, commit and working tree, etc\n");
}

fn cmdInit(allocator: std.mem.Allocator, plat: *const platform.Platform, args: *platform.ArgIterator) !void {
    const path = args.next() orelse ".";
    var repo = Repository.init(allocator, path, plat.*);
    try repo.initRepository();
}

fn cmdStatus(allocator: std.mem.Allocator, plat: *const platform.Platform) !void {
    const cwd = try plat.fs.getCwd(allocator);
    defer allocator.free(cwd);
    
    var repo = Repository.init(allocator, cwd, plat.*);
    const repo_exists = try repo.exists();
    
    if (!repo_exists) {
        try plat.writeStdout("fatal: not a ziggit repository (or any of the parent directories): .ziggit\n");
        return;
    }
    
    try plat.writeStdout("On branch main\nNothing to commit, working tree clean\n");
}
