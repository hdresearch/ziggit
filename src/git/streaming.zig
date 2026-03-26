const zlib_compat = @import("zlib_compat.zig");
const std = @import("std");
const objects = @import("objects.zig");

/// Streaming interface for reading large git objects without loading them fully into memory
pub const ObjectStream = struct {
    reader: std.io.AnyReader,
    object_type: objects.ObjectType,
    remaining_bytes: usize,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(reader: std.io.AnyReader, object_type: objects.ObjectType, size: usize, allocator: std.mem.Allocator) Self {
        return Self{
            .reader = reader,
            .object_type = object_type,
            .remaining_bytes = size,
            .allocator = allocator,
        };
    }
    
    /// Read data from the object stream
    pub fn read(self: *Self, buffer: []u8) !usize {
        const to_read = @min(buffer.len, self.remaining_bytes);
        if (to_read == 0) return 0;
        
        const bytes_read = try self.reader.read(buffer[0..to_read]);
        self.remaining_bytes -= bytes_read;
        return bytes_read;
    }
    
    /// Read all remaining data (use with caution for large objects)
    pub fn readAll(self: *Self) ![]u8 {
        if (self.remaining_bytes == 0) return try self.allocator.alloc(u8, 0);
        
        var data = try self.allocator.alloc(u8, self.remaining_bytes);
        errdefer self.allocator.free(data);
        
        var total_read: usize = 0;
        while (total_read < data.len) {
            const bytes_read = try self.reader.read(data[total_read..]);
            if (bytes_read == 0) break; // EOF
            total_read += bytes_read;
        }
        
        self.remaining_bytes -= total_read;
        return data[0..total_read];
    }
    
    /// Skip remaining bytes in the stream
    pub fn skip(self: *Self) !void {
        var buffer: [8192]u8 = undefined;
        while (self.remaining_bytes > 0) {
            const to_read = @min(buffer.len, self.remaining_bytes);
            const bytes_read = try self.reader.read(buffer[0..to_read]);
            if (bytes_read == 0) break; // EOF
            self.remaining_bytes -= bytes_read;
        }
    }
    
    pub fn bytesRemaining(self: Self) usize {
        return self.remaining_bytes;
    }
    
    pub fn getObjectType(self: Self) objects.ObjectType {
        return self.object_type;
    }
};

/// Stream-based pack file reader for memory-efficient processing
pub const PackFileStream = struct {
    pack_data: []const u8,
    position: usize,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(pack_data: []const u8, allocator: std.mem.Allocator) !Self {
        if (pack_data.len < 12) return error.InvalidPackFile;
        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackFile;
        
        return Self{
            .pack_data = pack_data,
            .position = 12, // Skip header
            .allocator = allocator,
        };
    }
    
    /// Get next object as a stream
    pub fn nextObjectStream(self: *Self) !?ObjectStream {
        if (self.position >= self.pack_data.len - 20) return null; // Account for trailing checksum
        
        // Read object header
        const start_pos = self.position;
        const first_byte = self.pack_data[self.position];
        self.position += 1;
        
        const pack_type_num = (first_byte >> 4) & 7;
        const pack_type = std.meta.intToEnum(objects.PackObjectType, pack_type_num) catch return error.InvalidPackObject;
        
        // Read variable-length size
        var size: usize = @intCast(first_byte & 15);
        var shift: u6 = 4;
        var current_byte = first_byte;
        
        while (current_byte & 0x80 != 0 and self.position < self.pack_data.len) {
            current_byte = self.pack_data[self.position];
            self.position += 1;
            size |= @as(usize, @intCast(current_byte & 0x7F)) << shift;
            shift += 7;
        }
        
        switch (pack_type) {
            .commit, .tree, .blob, .tag => {
                // Create a decompression stream
                const compressed_data = self.pack_data[self.position..];
                var stream = std.io.fixedBufferStream(compressed_data);
                var decompressor = zlib_compat.decompressor(stream.reader());
                
                const obj_type: objects.ObjectType = switch (pack_type) {
                    .commit => .commit,
                    .tree => .tree,
                    .blob => .blob,
                    .tag => .tag,
                    else => unreachable,
                };
                
                // Advance position past compressed data (approximate)
                // Note: This is a simplified approach - in a full implementation,
                // we'd need to actually decompress to find the end
                self.position += @min(size * 2, self.pack_data.len - self.position); // Rough estimate
                
                return ObjectStream.init(
                    decompressor.reader().any(),
                    obj_type,
                    size,
                    self.allocator
                );
            },
            .ofs_delta, .ref_delta => {
                // For now, skip delta objects in streaming mode
                // Full implementation would need to resolve deltas
                self.position = start_pos + 1;
                return self.nextObjectStream(); // Try next object
            },
        }
    }
    
    /// Reset stream to beginning
    pub fn reset(self: *Self) void {
        self.position = 12; // Skip header
    }
    
    /// Get current position in pack file
    pub fn getPosition(self: Self) usize {
        return self.position;
    }
};

/// Streaming tree walker for efficient directory traversal
pub const TreeWalker = struct {
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    platform_impl: anytype,
    
    const Self = @This();
    
    pub const TreeEntry = struct {
        mode: []const u8,
        name: []const u8,
        hash: []const u8,
        object_type: objects.ObjectType,
        
        pub fn deinit(self: TreeEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.mode);
            allocator.free(self.name);
            allocator.free(self.hash);
        }
    };
    
    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8, platform_impl: anytype) Self {
        return Self{
            .allocator = allocator,
            .git_dir = git_dir,
            .platform_impl = platform_impl,
        };
    }
    
    /// Walk a tree object, yielding entries one by one
    pub fn walkTree(self: *Self, tree_hash: []const u8, callback: *const fn (TreeEntry, []const u8) anyerror!void, path_prefix: []const u8) !void {
        const tree_obj = try objects.GitObject.load(tree_hash, self.git_dir, self.platform_impl, self.allocator);
        defer tree_obj.deinit(self.allocator);
        
        if (tree_obj.type != .tree) return error.NotATreeObject;
        
        var pos: usize = 0;
        while (pos < tree_obj.data.len) {
            // Find space separator
            const space_pos = std.mem.indexOfScalar(u8, tree_obj.data[pos..], ' ') orelse break;
            const mode = tree_obj.data[pos..pos + space_pos];
            pos += space_pos + 1;
            
            // Find null terminator
            const null_pos = std.mem.indexOfScalar(u8, tree_obj.data[pos..], 0) orelse break;
            const name = tree_obj.data[pos..pos + null_pos];
            pos += null_pos + 1;
            
            // Read 20-byte hash
            if (pos + 20 > tree_obj.data.len) break;
            const hash_bytes = tree_obj.data[pos..pos + 20];
            pos += 20;
            
            // Convert hash to hex string
            const hash_hex = try self.allocator.alloc(u8, 40);
            _ = try std.fmt.bufPrint(hash_hex, "{x}", .{hash_bytes});
            
            // Determine object type from mode
            const obj_type: objects.ObjectType = if (std.mem.eql(u8, mode, "040000"))
                .tree
            else
                .blob;
            
            const entry = TreeEntry{
                .mode = try self.allocator.dupe(u8, mode),
                .name = try self.allocator.dupe(u8, name),
                .hash = hash_hex,
                .object_type = obj_type,
            };
            
            // Build full path
            const full_path = if (path_prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path_prefix, name })
            else
                try self.allocator.dupe(u8, name);
            defer self.allocator.free(full_path);
            
            // Call callback with entry
            try callback(entry, full_path);
            
            // Recursively walk subdirectories
            if (obj_type == .tree) {
                try self.walkTree(entry.hash, callback, full_path);
            }
            
            entry.deinit(self.allocator);
        }
    }
};

/// Memory-mapped file reader for large pack files
pub const MmapPackReader = struct {
    file: std.fs.File,
    mapping: []align(std.mem.page_size) const u8,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, pack_path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(pack_path, .{});
        errdefer file.close();
        
        const file_size = try file.getEndPos();
        if (file_size == 0) return error.EmptyPackFile;
        
        // Memory map the file for efficient access
        const mapping = try std.posix.mmap(
            null,
            file_size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0
        );
        
        return Self{
            .file = file,
            .mapping = mapping,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        std.posix.munmap(self.mapping);
        self.file.close();
    }
    
    /// Get a slice of the pack data
    pub fn getData(self: Self) []const u8 {
        return self.mapping;
    }
    
    /// Create a streaming reader for this pack
    pub fn createStream(self: Self) !PackFileStream {
        return PackFileStream.init(self.mapping, self.allocator);
    }
    
    /// Read object at specific offset
    pub fn readObjectAtOffset(self: Self, offset: usize, platform_impl: anytype) !objects.GitObject {
        if (offset >= self.mapping.len) return error.OffsetOutOfBounds;
        
        // Use the existing pack object reading function
        const pack_path = ""; // Not needed for this call
        return objects.readPackedObject(self.mapping, offset, pack_path, platform_impl, self.allocator);
    }
};

/// Utilities for streaming large git operations
pub const StreamingUtils = struct {
    /// Stream objects from a commit's tree recursively
    pub fn streamTreeObjects(
        allocator: std.mem.Allocator, 
        git_dir: []const u8,
        tree_hash: []const u8,
        platform_impl: anytype,
        callback: *const fn (objects.GitObject, []const u8) anyerror!void
    ) !void {
        var walker = TreeWalker.init(allocator, git_dir, platform_impl);
        
        const callbackWrapper = struct {
            fn call(entry: TreeWalker.TreeEntry, path: []const u8) !void {
                // Load the actual object and call user callback
                const obj = objects.GitObject.load(entry.hash, git_dir, platform_impl, allocator) catch return;
                defer obj.deinit(allocator);
                try callback(obj, path);
            }
        }.call;
        
        try walker.walkTree(tree_hash, &callbackWrapper, "");
    }
    
    /// Stream diff between two commits
    pub fn streamCommitDiff(
        allocator: std.mem.Allocator,
        git_dir: []const u8, 
        commit1_hash: []const u8,
        commit2_hash: []const u8,
        platform_impl: anytype,
        callback: *const fn ([]const u8, []const u8, []const u8) anyerror!void // path, old_content, new_content
    ) !void {
        _ = allocator;
        _ = git_dir;
        _ = commit1_hash;
        _ = commit2_hash;
        _ = platform_impl;
        _ = callback;
        
        // TODO: Implement streaming diff
        // This would involve:
        // 1. Loading both commit trees
        // 2. Walking both trees in parallel
        // 3. Comparing objects and streaming differences
        return error.NotImplemented;
    }
};

test "object stream" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const data = "Hello, streaming world!";
    var stream = std.io.fixedBufferStream(data);
    var obj_stream = ObjectStream.init(
        stream.reader().any(),
        .blob,
        data.len,
        allocator
    );
    
    var buffer: [10]u8 = undefined;
    const bytes_read = try obj_stream.read(&buffer);
    
    try testing.expect(bytes_read == 10);
    try testing.expectEqualStrings("Hello, str", buffer[0..bytes_read]);
    try testing.expect(obj_stream.bytesRemaining() == data.len - 10);
}

test "pack file stream initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create minimal valid pack file header
    const pack_header = "PACK" ++ [_]u8{0, 0, 0, 2} ++ [_]u8{0, 0, 0, 0}; // version 2, 0 objects
    
    var stream = try PackFileStream.init(pack_header, allocator);
    try testing.expect(stream.getPosition() == 12);
}

test "tree walker entry parsing" {
    // This would need actual tree object data to test properly
    // Skipping for now as it requires a more complex setup
}