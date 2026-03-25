const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var args = std.process.args();
    _ = args.skip(); // skip program name

    const command = args.next() orelse {
        try stdout.print("ziggit: a modern version control system written in Zig\n", .{});
        try stdout.print("usage: ziggit <command> [<args>]\n\n", .{});
        try stdout.print("Commands:\n", .{});
        try stdout.print("  init       Create an empty repository\n", .{});
        try stdout.print("  add        Add file contents to the index\n", .{});
        try stdout.print("  commit     Record changes to the repository\n", .{});
        try stdout.print("  status     Show the working tree status\n", .{});
        try stdout.print("  log        Show commit logs\n", .{});
        try stdout.print("  checkout   Switch branches or restore working tree files\n", .{});
        try stdout.print("  branch     List, create, or delete branches\n", .{});
        try stdout.print("  merge      Join two or more development histories together\n", .{});
        try stdout.print("  clone      Clone a repository into a new directory\n", .{});
        try stdout.print("  push       Update remote refs along with associated objects\n", .{});
        try stdout.print("  pull       Fetch from and integrate with another repository\n", .{});
        try stdout.print("  fetch      Download objects and refs from another repository\n", .{});
        try stdout.print("  diff       Show changes between commits, commit and working tree, etc\n", .{});
        return;
    };

    // TODO: Implement all git commands as drop-in replacements
    try stdout.print("ziggit: '{s}' is not yet implemented\n", .{command});
}
