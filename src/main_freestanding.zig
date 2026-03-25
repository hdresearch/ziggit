// Minimal freestanding main that avoids Zig stdlib POSIX dependencies
const std = @import("std");

// Simple fixed buffer allocator for freestanding environment
var memory_buffer: [64 * 1024]u8 = undefined; // 64KB buffer
var fba: std.heap.FixedBufferAllocator = undefined;
var allocator_initialized = false;

// External functions that must be provided by the JavaScript host environment
extern fn host_write_stdout(ptr: [*]const u8, len: u32) void;
extern fn host_write_stderr(ptr: [*]const u8, len: u32) void;

// Export main function for WASM
export fn ziggit_main() i32 {
    main() catch return 1;
    return 0;
}

// Export function for host to call specific commands
export fn ziggit_command(command_ptr: [*]const u8, command_len: u32) i32 {
    const command = command_ptr[0..command_len];
    handleCommand(command) catch return 1;
    return 0;
}

fn getOrInitAllocator() std.mem.Allocator {
    if (!allocator_initialized) {
        fba = std.heap.FixedBufferAllocator.init(&memory_buffer);
        allocator_initialized = true;
    }
    return fba.allocator();
}

pub fn main() !void {
    writeStdout("ziggit: a modern version control system written in Zig (WASM/Browser mode)\n");
    writeStdout("Use ziggit_command() function to execute commands.\n");
}

fn handleCommand(command: []const u8) !void {
    if (std.mem.eql(u8, command, "") or std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        writeStdout("ziggit: a modern version control system written in Zig\n");
        writeStdout("usage: ziggit <command> [<args>]\n\n");
        writeStdout("Commands:\n");
        writeStdout("  init       Create an empty repository\n");
        writeStdout("  add        Add file contents to the index\n");
        writeStdout("  commit     Record changes to the repository\n");
        writeStdout("  status     Show the working tree status\n");
        writeStdout("  log        Show commit logs\n");
        writeStdout("  checkout   Switch branches or restore working tree files\n");
        writeStdout("  branch     List, create, or delete branches\n");
        writeStdout("  merge      Join two or more development histories together\n");
        writeStdout("  clone      Clone a repository into a new directory\n");
        writeStdout("  push       Update remote refs along with associated objects\n");
        writeStdout("  pull       Fetch from and integrate with another repository\n");
        writeStdout("  fetch      Download objects and refs from another repository\n");
        writeStdout("  diff       Show changes between commits, commit and working tree, etc\n");
        writeStdout("\nNote: Browser mode requires JavaScript host functions for file operations.\n");
    } else if (std.mem.eql(u8, command, "init")) {
        writeStdout("ziggit init: would create repository (requires JavaScript host filesystem)\n");
    } else if (std.mem.eql(u8, command, "status")) {
        writeStdout("On branch main\n\nBrowser mode - status requires JavaScript host filesystem\n");
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        writeStdout("ziggit version 0.1.0 (Browser/freestanding)\n");
    } else {
        writeStdout("ziggit: '");
        writeStdout(command);
        writeStdout("' is not yet fully implemented in browser mode\n");
        writeStdout("Available commands: init, status, help, version\n");
    }
}

fn writeStdout(data: []const u8) void {
    host_write_stdout(data.ptr, @intCast(data.len));
}

fn writeStderr(data: []const u8) void {
    host_write_stderr(data.ptr, @intCast(data.len));
}