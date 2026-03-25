const std = @import("std");

/// Platform-specific interface for ziggit
pub const Platform = struct {
    /// Get command-line arguments
    getArgs: *const fn (allocator: std.mem.Allocator) anyerror!ArgIterator,
    
    /// Write output
    writeStdout: *const fn (data: []const u8) anyerror!void,
    
    /// Write error output
    writeStderr: *const fn (data: []const u8) anyerror!void,
    
    /// File system operations
    fs: FileSystem,
};

pub const ArgIterator = struct {
    args: [][]const u8,
    index: usize = 0,
    allocator: std.mem.Allocator,
    
    pub fn next(self: *ArgIterator) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        const arg = self.args[self.index];
        self.index += 1;
        return arg;
    }
    
    pub fn skip(self: *ArgIterator) bool {
        return self.next() != null;
    }
    
    pub fn deinit(self: *ArgIterator) void {
        for (self.args) |arg| {
            self.allocator.free(arg);
        }
        self.allocator.free(self.args);
    }
};

pub const FileSystem = struct {
    /// Check if a file exists
    exists: *const fn (path: []const u8) anyerror!bool,
    
    /// Create a directory
    makeDir: *const fn (path: []const u8) anyerror!void,
    
    /// Read file contents
    readFile: *const fn (allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
    
    /// Write file contents
    writeFile: *const fn (path: []const u8, data: []const u8) anyerror!void,
    
    /// Delete file
    deleteFile: *const fn (path: []const u8) anyerror!void,
    
    /// Get current working directory
    getCwd: *const fn (allocator: std.mem.Allocator) anyerror![]u8,
    
    /// Change working directory
    chdir: *const fn (path: []const u8) anyerror!void,
    
    /// List directory contents (returns just filenames, not full paths)
    readDir: *const fn (allocator: std.mem.Allocator, path: []const u8) anyerror![][]u8,
};