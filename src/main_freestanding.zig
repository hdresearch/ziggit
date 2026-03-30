// Freestanding main optimized for browser/JS integration with minimal dependencies
const std = @import("std");

// Import wasm_exports to link all git operations into the WASM binary
const wasm_exports = @import("wasm_exports.zig");
comptime {
    _ = wasm_exports; // Force linking of all exports
}

// Simple fixed buffer allocator for freestanding environment
// Can be configured at compile time with -Dfreestanding-memory-size=<size>
const config = @import("config");
const MEMORY_SIZE = if (@hasDecl(config, "freestanding_memory_size"))
    config.freestanding_memory_size
else 
    64 * 1024; // Default: 64KB buffer

var memory_buffer: [MEMORY_SIZE]u8 = undefined; 
var fba: std.heap.FixedBufferAllocator = undefined;
var allocator_initialized = false;

// Global arguments storage for JS integration
var global_argc: u32 = 0;
var global_argv: ?[][]const u8 = null;

// External functions that must be provided by the JavaScript host environment
extern fn host_write_stdout(ptr: [*]const u8, len: u32) void;
extern fn host_write_stderr(ptr: [*]const u8, len: u32) void;
extern fn host_read_file(path_ptr: [*]const u8, path_len: u32, data_ptr: *[*]u8, data_len: *u32) bool;
extern fn host_write_file(path_ptr: [*]const u8, path_len: u32, data_ptr: [*]const u8, data_len: u32) bool;
extern fn host_file_exists(path_ptr: [*]const u8, path_len: u32) bool;
extern fn host_make_dir(path_ptr: [*]const u8, path_len: u32) bool;
extern fn host_delete_file(path_ptr: [*]const u8, path_len: u32) bool;
extern fn host_get_cwd(data_ptr: *[*]u8, data_len: *u32) bool;

// Export main function for WASM
export fn ziggit_main() i32 {
    main() catch return 1;
    return 0;
}

// Export function for host to set arguments before calling commands
// Export functions for platform to access global args
export fn getGlobalArgc() u32 {
    return global_argc;
}

export fn getGlobalArgv() ?[*][]const u8 {
    if (global_argv) |argv| {
        return argv.ptr;
    }
    return null;
}

export fn ziggit_set_args(argc: u32, argv_ptr: [*][*:0]const u8) i32 {
    const allocator = getOrInitAllocator();
    
    // Clean up previous args
    if (global_argv) |argv| {
        for (argv) |arg| {
            allocator.free(arg);
        }
        allocator.free(argv);
    }
    
    // Allocate new args
    global_argc = argc;
    global_argv = allocator.alloc([]const u8, argc) catch return 1;
    
    for (0..argc) |i| {
        const arg_ptr = argv_ptr[i];
        // Find length by iterating until null terminator
        var arg_len: usize = 0;
        while (arg_ptr[arg_len] != 0) arg_len += 1;
        global_argv.?[i] = allocator.dupe(u8, arg_ptr[0..arg_len]) catch return 1;
    }
    
    return 0;
}

// Export function for host to call with full command line
export fn ziggit_command_line(argc: u32, argv_ptr: [*][*:0]const u8) i32 {
    // Set arguments
    if (ziggit_set_args(argc, argv_ptr) != 0) return 1;
    
    // Run command using freestanding main
    zigzitMainFreestanding() catch return 1;
    return 0;
}

// Export function for host to call specific commands (legacy compatibility)
export fn ziggit_command(command_ptr: [*]const u8, command_len: u32) i32 {
    const command = command_ptr[0..command_len];
    handleSingleCommand(command) catch return 1;
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
    // Default behavior - show welcome message if no args
    if (global_argv == null or global_argc == 0) {
        try showWelcomeMessage();
        return;
    }
    
    // Use freestanding-specific main functionality
    try zigzitMainFreestanding();
}

// Simplified freestanding main logic without platform abstraction
fn zigzitMainFreestanding() !void {
    if (global_argv == null or global_argc < 2) {
        try showUsageSimple();
        return;
    }
    
    const command = global_argv.?[1]; // Skip program name (index 0)

    if (std.mem.eql(u8, command, "init")) {
        try cmdInitSimple();
    } else if (std.mem.eql(u8, command, "status")) {
        try cmdStatusSimple();
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        writeStdout("ziggit version 0.1.0 (Browser/freestanding)\n");
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try showUsageSimple();
    } else {
        writeStderr("ziggit: '");
        writeStderr(command);
        writeStderr("' is not implemented in browser mode. See 'ziggit --help'.\n");
    }
}

fn handleSingleCommand(command: []const u8) !void {
    if (std.mem.eql(u8, command, "") or std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        try showUsageSimple();
    } else if (std.mem.eql(u8, command, "init")) {
        writeStdout("ziggit init: would create repository (requires JavaScript host filesystem implementation)\n");
    } else if (std.mem.eql(u8, command, "status")) {
        writeStdout("On branch main\n\nBrowser mode - status requires JavaScript host filesystem implementation\n");
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        writeStdout("ziggit version 0.1.0 (Browser/freestanding)\n");
    } else {
        writeStderr("ziggit: '");
        writeStderr(command);
        writeStderr("' is not yet implemented in browser mode\n");
        writeStderr("Available commands: init, status, help, version\n");
    }
}

// Simplified git commands for freestanding mode
fn cmdInitSimple() !void {
    // For browser mode, delegate to host filesystem
    if (host_make_dir(".git".ptr, 4)) {
        writeStdout("Initialized empty Git repository (browser mode)\n");
        writeStdout("Note: Full git functionality requires complete JavaScript host filesystem implementation\n");
    } else {
        writeStderr("ziggit init: failed to create .git directory (check host filesystem implementation)\n");
    }
}

fn cmdStatusSimple() !void {
    // Check if we're in a git repository
    const is_git_repo = host_file_exists(".git".ptr, 4);
    
    if (is_git_repo) {
        writeStdout("On branch main\n\n");
        writeStdout("Browser mode - limited status functionality\n");
        writeStdout("Note: Full git status requires complete JavaScript host filesystem implementation\n");
    } else {
        writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
    }
}

fn showUsageSimple() !void {
    writeStdout("ziggit: a modern version control system written in Zig (Browser)\n");
    writeStdout("usage: ziggit <command> [<args>]\n\n");
    writeStdout("Commands available in browser mode:\n");
    writeStdout("  init       Create an empty repository\n");
    writeStdout("  status     Show the working tree status\n");
    writeStdout("  help       Show this help message\n");
    writeStdout("  version    Show version information\n");
    writeStdout("\nNote: Browser mode requires JavaScript host functions for file operations.\n");
}

fn showWelcomeMessage() !void {
    writeStdout("ziggit: a modern version control system written in Zig (Browser/freestanding)\n");
    writeStdout("\nFor browser integration, use these exported functions:\n");
    writeStdout("  - ziggit_main(): Initialize ziggit\n");
    writeStdout("  - ziggit_command_line(argc, argv): Run full command line\n");
    writeStdout("  - ziggit_command(cmd_ptr, cmd_len): Run single command (legacy)\n");
    writeStdout("  - ziggit_set_args(argc, argv): Set arguments for subsequent calls\n");
    writeStdout("\nNote: Host JavaScript must implement filesystem extern functions.\n");
    writeStdout("See README.md for integration details.\n");
}

fn writeStdout(data: []const u8) void {
    host_write_stdout(data.ptr, @intCast(data.len));
}

fn writeStderr(data: []const u8) void {
    host_write_stderr(data.ptr, @intCast(data.len));
}



