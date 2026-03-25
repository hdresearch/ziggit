const std = @import("std");
const interface = @import("interface.zig");

// For freestanding WASM, we'll need to provide external functions
// that can be implemented by the JavaScript runtime

// External functions to be implemented by the host environment
extern fn host_write_stdout(ptr: [*]const u8, len: u32) void;
extern fn host_write_stderr(ptr: [*]const u8, len: u32) void;
extern fn host_read_file(path_ptr: [*]const u8, path_len: u32, data_ptr: *[*]u8, data_len: *u32) bool;
extern fn host_write_file(path_ptr: [*]const u8, path_len: u32, data_ptr: [*]const u8, data_len: u32) bool;
extern fn host_file_exists(path_ptr: [*]const u8, path_len: u32) bool;
extern fn host_make_dir(path_ptr: [*]const u8, path_len: u32) bool;
extern fn host_delete_file(path_ptr: [*]const u8, path_len: u32) bool;
extern fn host_get_cwd(data_ptr: *[*]u8, data_len: *u32) bool;

// Global storage for arguments - will be set by host
var global_args: ?[][]const u8 = null;
var global_allocator: ?std.mem.Allocator = null;

// Export function for host to set arguments
export fn set_args(argc: u32, argv_ptr: [*][*]const u8) void {
    if (global_allocator) |allocator| {
        var args = allocator.alloc([]const u8, argc) catch return;
        for (0..argc) |i| {
            const arg_ptr = argv_ptr[i];
            // Find length by iterating until null terminator
            var arg_len: usize = 0;
            while (arg_ptr[arg_len] != 0) arg_len += 1;
            args[i] = allocator.dupe(u8, arg_ptr[0..arg_len]) catch return;
        }
        global_args = args;
    }
}

// Export function for host to set allocator
export fn set_allocator(allocator_ptr: *std.mem.Allocator) void {
    global_allocator = allocator_ptr.*;
}

fn getArgsImpl(allocator: std.mem.Allocator) !interface.ArgIterator {
    if (global_args) |args| {
        // Create a copy of the args for the iterator
        var arg_list = std.ArrayList([]u8).init(allocator);
        for (args) |arg| {
            const owned_arg = try allocator.dupe(u8, arg);
            try arg_list.append(owned_arg);
        }
        
        return interface.ArgIterator{
            .args = try arg_list.toOwnedSlice(),
            .allocator = allocator,
        };
    }
    
    // Default to empty args if none provided
    return interface.ArgIterator{
        .args = try allocator.alloc([]u8, 0),
        .allocator = allocator,
    };
}

fn writeStdoutImpl(data: []const u8) !void {
    host_write_stdout(data.ptr, @intCast(data.len));
}

fn writeStderrImpl(data: []const u8) !void {
    host_write_stderr(data.ptr, @intCast(data.len));
}

fn existsImpl(path: []const u8) !bool {
    return host_file_exists(path.ptr, @intCast(path.len));
}

fn makeDirImpl(path: []const u8) !void {
    if (!host_make_dir(path.ptr, @intCast(path.len))) {
        return error.MakeDirFailed;
    }
}

fn readFileImpl(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var data_ptr: [*]u8 = undefined;
    var data_len: u32 = undefined;
    
    if (host_read_file(path.ptr, @intCast(path.len), &data_ptr, &data_len)) {
        // Copy the data to our allocator-managed memory
        const result = try allocator.alloc(u8, data_len);
        @memcpy(result, data_ptr[0..data_len]);
        return result;
    }
    
    return error.FileNotFound;
}

fn writeFileImpl(path: []const u8, data: []const u8) !void {
    if (!host_write_file(path.ptr, @intCast(path.len), data.ptr, @intCast(data.len))) {
        return error.WriteFileFailed;
    }
}

fn deleteFileImpl(path: []const u8) !void {
    if (!host_delete_file(path.ptr, @intCast(path.len))) {
        return error.DeleteFileFailed;
    }
}

fn getCwdImpl(allocator: std.mem.Allocator) ![]u8 {
    var data_ptr: [*]u8 = undefined;
    var data_len: u32 = undefined;
    
    if (host_get_cwd(&data_ptr, &data_len)) {
        const result = try allocator.alloc(u8, data_len);
        @memcpy(result, data_ptr[0..data_len]);
        return result;
    }
    
    // Default fallback
    return try allocator.dupe(u8, "/");
}

fn chdirImpl(path: []const u8) !void {
    // Not supported in freestanding mode
    _ = path;
    return error.NotSupported;
}

pub const freestanding_platform = interface.Platform{
    .getArgs = getArgsImpl,
    .writeStdout = writeStdoutImpl,
    .writeStderr = writeStderrImpl,
    .fs = .{
        .exists = existsImpl,
        .makeDir = makeDirImpl,
        .readFile = readFileImpl,
        .writeFile = writeFileImpl,
        .deleteFile = deleteFileImpl,
        .getCwd = getCwdImpl,
        .chdir = chdirImpl,
    },
};