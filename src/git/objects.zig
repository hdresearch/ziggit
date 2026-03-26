const std = @import("std");
const crypto = std.crypto;

pub const ObjectType = enum {
    blob,
    tree,
    commit,
    tag,

    pub fn toString(self: ObjectType) []const u8 {
        return switch (self) {
            .blob => "blob",
            .tree => "tree", 
            .commit => "commit",
            .tag => "tag",
        };
    }

    pub fn fromString(str: []const u8) ?ObjectType {
        if (std.mem.eql(u8, str, "blob")) return .blob;
        if (std.mem.eql(u8, str, "tree")) return .tree;
        if (std.mem.eql(u8, str, "commit")) return .commit;
        if (std.mem.eql(u8, str, "tag")) return .tag;
        return null;
    }
};

pub const GitObject = struct {
    type: ObjectType,
    data: []const u8,

    pub fn init(obj_type: ObjectType, data: []const u8) GitObject {
        return GitObject{
            .type = obj_type,
            .data = data,
        };
    }

    pub fn deinit(self: GitObject, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn hash(self: GitObject, allocator: std.mem.Allocator) ![]u8 {
        // Git object format: "<type> <size>\0<data>"
        const header = try std.fmt.allocPrint(allocator, "{s} {}\x00", .{ self.type.toString(), self.data.len });
        defer allocator.free(header);

        const content = try std.mem.concat(allocator, u8, &[_][]const u8{ header, self.data });
        defer allocator.free(content);

        var hasher = crypto.hash.Sha1.init(.{});
        hasher.update(content);
        var digest: [20]u8 = undefined;
        hasher.final(&digest);

        return try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&digest)});
    }

    pub fn store(self: GitObject, git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![]u8 {
        const hash_str = try self.hash(allocator);
        defer allocator.free(hash_str);

        // Create object directory: .git/objects/xx/
        const obj_dir = hash_str[0..2];
        const obj_file = hash_str[2..];
        
        const obj_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ git_dir, obj_dir });
        defer allocator.free(obj_dir_path);
        
        platform_impl.fs.makeDir(obj_dir_path) catch |err| switch (err) {
            error.AlreadyExists => {},
            else => return err,
        };

        const obj_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ obj_dir_path, obj_file });
        defer allocator.free(obj_file_path);

        // Create the object content
        const header = try std.fmt.allocPrint(allocator, "{s} {}\x00", .{ self.type.toString(), self.data.len });
        defer allocator.free(header);

        const content = try std.mem.concat(allocator, u8, &[_][]const u8{ header, self.data });
        defer allocator.free(content);

        // Compress the content using zlib for git compatibility (skip on WASM for stability)
        const final_content = if (@import("builtin").target.os.tag == .wasi or @import("builtin").target.os.tag == .freestanding) blk: {
            // For WASM builds, store uncompressed to avoid memory issues
            // This is a temporary workaround - repositories work but may be slightly larger
            break :blk try allocator.dupe(u8, content);
        } else blk: {
            var compressed_data = std.ArrayList(u8).init(allocator);
            defer compressed_data.deinit();
            
            var input_stream = std.io.fixedBufferStream(content);
            try std.compress.zlib.compress(input_stream.reader(), compressed_data.writer(), .{});
            
            break :blk try allocator.dupe(u8, compressed_data.items);
        };
        defer allocator.free(final_content);
        
        try platform_impl.fs.writeFile(obj_file_path, final_content);

        return try allocator.dupe(u8, hash_str);
    }

    pub fn load(hash_str: []const u8, git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !GitObject {
        const obj_dir = hash_str[0..2];
        const obj_file = hash_str[2..];
        
        const obj_file_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}/{s}", .{ git_dir, obj_dir, obj_file });
        defer allocator.free(obj_file_path);

        const compressed_content = platform_impl.fs.readFile(allocator, obj_file_path) catch |err| switch (err) {
            error.FileNotFound => {
                // Try to find object in pack files
                return loadFromPackFiles(hash_str, git_dir, platform_impl, allocator) catch return error.ObjectNotFound;
            },
            else => return err,
        };
        defer allocator.free(compressed_content);

        // Decompress using zlib for git compatibility (handle both compressed and uncompressed)
        var content = std.ArrayList(u8).init(allocator);
        defer content.deinit();
        
        // For WASM builds, handle both compressed and uncompressed objects
        if (@import("builtin").target.os.tag == .wasi or @import("builtin").target.os.tag == .freestanding) {
            // Check if this looks like a git object header (uncompressed)
            if (std.mem.indexOf(u8, compressed_content, "\x00")) |_| {
                // Looks like uncompressed object, use directly
                try content.appendSlice(compressed_content);
            } else {
                // Try decompression
                var compressed_stream = std.io.fixedBufferStream(compressed_content);
                std.compress.zlib.decompress(compressed_stream.reader(), content.writer()) catch {
                    // If decompression fails, treat as uncompressed
                    try content.appendSlice(compressed_content);
                };
            }
        } else {
            var compressed_stream = std.io.fixedBufferStream(compressed_content);
            try std.compress.zlib.decompress(compressed_stream.reader(), content.writer());
        }

        // Parse the object
        const null_pos = std.mem.indexOf(u8, content.items, "\x00") orelse return error.InvalidObject;
        
        const header = content.items[0..null_pos];
        const data = content.items[null_pos + 1 ..];
        
        const space_pos = std.mem.indexOf(u8, header, " ") orelse return error.InvalidObject;
        const type_str = header[0..space_pos];
        const size_str = header[space_pos + 1 ..];
        
        const obj_type = ObjectType.fromString(type_str) orelse return error.InvalidObject;
        const size = std.fmt.parseInt(usize, size_str, 10) catch return error.InvalidObject;
        
        if (data.len != size) return error.InvalidObject;

        const data_copy = try allocator.dupe(u8, data);
        
        return GitObject{
            .type = obj_type,
            .data = data_copy,
        };
    }
};

pub fn createBlobObject(data: []const u8, allocator: std.mem.Allocator) !GitObject {
    const data_copy = try allocator.dupe(u8, data);
    return GitObject.init(.blob, data_copy);
}

pub fn createTreeObject(entries: []const TreeEntry, allocator: std.mem.Allocator) !GitObject {
    var content = std.ArrayList(u8).init(allocator);
    defer content.deinit();

    for (entries) |entry| {
        try content.writer().print("{s} {s}\x00", .{ entry.mode, entry.name });
        // Write hash bytes directly
        var hash_bytes: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash_bytes, entry.hash);
        try content.appendSlice(&hash_bytes);
    }

    const data = try content.toOwnedSlice();
    return GitObject.init(.tree, data);
}

pub const TreeEntry = struct {
    mode: []const u8, // e.g., "100644", "040000", "100755"
    name: []const u8,
    hash: []const u8, // 40-character hex string

    pub fn init(mode: []const u8, name: []const u8, hash: []const u8) TreeEntry {
        return TreeEntry{
            .mode = mode,
            .name = name,
            .hash = hash,
        };
    }

    pub fn deinit(self: TreeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.mode);
        allocator.free(self.name);
        allocator.free(self.hash);
    }
};

pub fn createCommitObject(tree_hash: []const u8, parent_hashes: []const []const u8, author: []const u8, committer: []const u8, message: []const u8, allocator: std.mem.Allocator) !GitObject {
    var content = std.ArrayList(u8).init(allocator);
    defer content.deinit();

    try content.writer().print("tree {s}\n", .{tree_hash});
    
    for (parent_hashes) |parent| {
        try content.writer().print("parent {s}\n", .{parent});
    }
    
    try content.writer().print("author {s}\n", .{author});
    try content.writer().print("committer {s}\n", .{committer});
    try content.writer().print("\n{s}", .{message});

    const data = try content.toOwnedSlice();
    return GitObject.init(.commit, data);
}

/// Try to load object from pack files when loose object is not found
fn loadFromPackFiles(hash_str: []const u8, git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !GitObject {
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_path);
    
    // Open pack directory
    var pack_dir = std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch return error.ObjectNotFound;
    defer pack_dir.close();
    
    // Look for .idx files (pack index files)
    var iterator = pack_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        
        // Try to find object in this pack
        const obj = findObjectInPack(pack_dir_path, entry.name, hash_str, platform_impl, allocator) catch continue;
        return obj;
    }
    
    return error.ObjectNotFound;
}

/// Find object in a specific pack file
fn findObjectInPack(pack_dir_path: []const u8, idx_filename: []const u8, hash_str: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !GitObject {
    // Convert hash string to bytes for searching
    var target_hash: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&target_hash, hash_str);
    
    // Read the .idx file to find object offset
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_dir_path, idx_filename});
    defer allocator.free(idx_path);
    
    const idx_data = platform_impl.fs.readFile(allocator, idx_path) catch return error.ObjectNotFound;
    defer allocator.free(idx_data);
    
    // Parse pack index v2 format (simplified)
    if (idx_data.len < 8) return error.ObjectNotFound;
    
    // Check for pack index magic and version
    const magic = std.mem.readIntBig(u32, idx_data[0..4]);
    const version = std.mem.readIntBig(u32, idx_data[4..8]);
    
    if (magic != 0xff744f63) return error.ObjectNotFound; // '\377tOc'
    if (version != 2) return error.ObjectNotFound;
    
    // Skip fanout table (256 * 4 bytes) 
    const fanout_start = 8;
    const fanout_end = fanout_start + 256 * 4;
    if (idx_data.len < fanout_end) return error.ObjectNotFound;
    
    // Get number of objects from last fanout entry
    const num_objects = std.mem.readIntBig(u32, idx_data[fanout_end - 4..fanout_end]);
    if (num_objects == 0) return error.ObjectNotFound;
    
    // Find object in sorted SHA-1 table
    const sha1_table_start = fanout_end;
    const sha1_table_end = sha1_table_start + num_objects * 20;
    if (idx_data.len < sha1_table_end) return error.ObjectNotFound;
    
    var object_index: ?u32 = null;
    var i: u32 = 0;
    while (i < num_objects) : (i += 1) {
        const sha1_offset = sha1_table_start + i * 20;
        const obj_hash = idx_data[sha1_offset..sha1_offset + 20];
        
        if (std.mem.eql(u8, obj_hash, &target_hash)) {
            object_index = i;
            break;
        }
    }
    
    if (object_index == null) return error.ObjectNotFound;
    
    // Get offset from offset table (simplified - assumes 32-bit offsets)
    const offset_table_start = sha1_table_end + num_objects * 4; // Skip CRC table
    const offset_table_offset = offset_table_start + object_index.? * 4;
    if (idx_data.len < offset_table_offset + 4) return error.ObjectNotFound;
    
    const object_offset = std.mem.readIntBig(u32, idx_data[offset_table_offset..offset_table_offset + 4]);
    
    // Now read from the corresponding .pack file
    const pack_filename = try std.fmt.allocPrint(allocator, "{s}.pack", .{idx_filename[0..idx_filename.len-4]});
    defer allocator.free(pack_filename);
    
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_dir_path, pack_filename});
    defer allocator.free(pack_path);
    
    return readObjectFromPack(pack_path, object_offset, platform_impl, allocator);
}

/// Read object from pack file at given offset (simplified implementation)
fn readObjectFromPack(pack_path: []const u8, offset: u32, platform_impl: anytype, allocator: std.mem.Allocator) !GitObject {
    const pack_data = platform_impl.fs.readFile(allocator, pack_path) catch return error.ObjectNotFound;
    defer allocator.free(pack_data);
    
    if (offset >= pack_data.len) return error.ObjectNotFound;
    
    // Parse pack object header (simplified)
    var pos: usize = offset;
    if (pos >= pack_data.len) return error.ObjectNotFound;
    
    const first_byte = pack_data[pos];
    pos += 1;
    
    const obj_type_num = (first_byte >> 4) & 7;
    const obj_type: ObjectType = switch (obj_type_num) {
        1 => .commit,
        2 => .tree, 
        3 => .blob,
        4 => .tag,
        else => return error.ObjectNotFound,
    };
    
    // Read variable-length size (simplified)
    var size: usize = @intCast(first_byte & 15);
    var shift: u3 = 4;
    
    while (first_byte & 0x80 != 0 and pos < pack_data.len) {
        const next_byte = pack_data[pos];
        pos += 1;
        size |= @as(usize, @intCast(next_byte & 0x7F)) << shift;
        shift += 7;
        if (next_byte & 0x80 == 0) break;
    }
    
    // Decompress object data using zlib
    if (pos >= pack_data.len) return error.ObjectNotFound;
    
    var decompressed = std.ArrayList(u8).init(allocator);
    defer decompressed.deinit();
    
    var stream = std.io.fixedBufferStream(pack_data[pos..]);
    std.compress.zlib.decompress(stream.reader(), decompressed.writer()) catch return error.ObjectNotFound;
    
    if (decompressed.items.len != size) return error.ObjectNotFound;
    
    const data = try allocator.dupe(u8, decompressed.items);
    return GitObject.init(obj_type, data);
}

/// Legacy function for compatibility with tests - reads and decompresses git object
pub fn readObject(allocator: std.mem.Allocator, objects_dir: []const u8, hash_bytes: *const [20]u8) ![]u8 {
    // Convert hash bytes to hex string
    const hash_str = try allocator.alloc(u8, 40);
    defer allocator.free(hash_str);
    _ = try std.fmt.bufPrint(hash_str, "{}", .{std.fmt.fmtSliceHexLower(hash_bytes)});
    
    // Build object file path
    const obj_dir = hash_str[0..2];
    const obj_file = hash_str[2..];
    const obj_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{objects_dir, obj_dir, obj_file});
    defer allocator.free(obj_path);
    
    // Read compressed object file
    const compressed_data = std.fs.cwd().readFileAlloc(allocator, obj_path, 1024 * 1024) catch return error.ObjectNotFound;
    defer allocator.free(compressed_data);
    
    // Decompress using zlib
    var decompressed = std.ArrayList(u8).init(allocator);
    defer decompressed.deinit();
    
    var stream = std.io.fixedBufferStream(compressed_data);
    std.compress.zlib.decompress(stream.reader(), decompressed.writer()) catch |err| {
        // If decompression fails, maybe it's uncompressed
        if (std.mem.indexOf(u8, compressed_data, "\x00") != null) {
            return try allocator.dupe(u8, compressed_data);
        }
        return err;
    };
    
    return try allocator.dupe(u8, decompressed.items);
}