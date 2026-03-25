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

// External functions to get global args from main_freestanding.zig
extern fn getGlobalArgc() u32;
extern fn getGlobalArgv() ?[*][]const u8;

fn getArgsImpl(allocator: std.mem.Allocator) !interface.ArgIterator {
    const argc = getGlobalArgc();
    if (argc > 0) {
        if (getGlobalArgv()) |argv_ptr| {
            const argv = argv_ptr[0..argc];
            // Create a copy of the args for the iterator
            var arg_list = std.ArrayList([]u8).init(allocator);
            for (argv) |arg| {
                const owned_arg = try allocator.dupe(u8, arg);
                try arg_list.append(owned_arg);
            }
            
            return interface.ArgIterator{
                .args = try arg_list.toOwnedSlice(),
                .allocator = allocator,
            };
        }
    }
    
    // Default to ziggit --help if no args provided
    var arg_list = std.ArrayList([]u8).init(allocator);
    try arg_list.append(try allocator.dupe(u8, "ziggit"));
    try arg_list.append(try allocator.dupe(u8, "--help"));
    
    return interface.ArgIterator{
        .args = try arg_list.toOwnedSlice(),
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