const std = @import("std");
const platform = @import("platform/platform.zig");

// Simple allocator for freestanding environment
var memory_buffer: [64 * 1024]u8 = undefined; // 64KB buffer
var fba = std.heap.FixedBufferAllocator.init(&memory_buffer);

export fn ziggit_main() i32 {
    main() catch return 1;
    return 0;
}

pub fn main() !void {
    const allocator = fba.allocator();
    
    const plat = platform.getCurrentPlatform();
    var args = try plat.getArgs(allocator);
    defer args.deinit();
    
    _ = args.skip(); // skip program name

    const command = args.next() orelse {
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
        return;
    };

    // TODO: Implement all git commands as drop-in replacements
    // For now, just output a simple message without formatting
    try plat.writeStdout("ziggit: '");
    try plat.writeStdout(command);
    try plat.writeStdout("' is not yet implemented\n");
}