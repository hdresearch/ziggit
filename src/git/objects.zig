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
                return loadFromPackFiles(hash_str, git_dir, platform_impl, allocator) catch {
                    return error.ObjectNotFound;
                };
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
    var pack_dir = std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch {
        return error.ObjectNotFound;
    };
    defer pack_dir.close();
    
            // debug print removed
    
    // Look for .idx files (pack index files)
    var iterator = pack_dir.iterate();
    var pack_files_found: u32 = 0;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        
        pack_files_found += 1;
            // debug print removed
        
        // Try to find object in this pack
        const obj = findObjectInPack(pack_dir_path, entry.name, hash_str, platform_impl, allocator) catch {
            // debug print removed
            continue;
        };
            // debug print removed
        return obj;
    }
    
    if (pack_files_found == 0) {
            // debug print removed
    } else {
            // debug print removed
    }
    
    return error.ObjectNotFound;
}

/// Pack object types
const PackObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

/// Find object in a specific pack file with enhanced validation and performance
fn findObjectInPack(pack_dir_path: []const u8, idx_filename: []const u8, hash_str: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !GitObject {
    // Validate input hash format
    if (hash_str.len != 40) {
            // debug print removed
        return error.InvalidHash;
    }
    for (hash_str) |c| {
        if (!std.ascii.isHex(c)) {
            // debug print removed
            return error.InvalidHash;
        }
    }
    
    // Convert hash string to bytes for searching
    var target_hash: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&target_hash, hash_str);
    
    // Read the .idx file to find object offset
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_dir_path, idx_filename});
    defer allocator.free(idx_path);
    
            // debug print removed
    
    const idx_data = platform_impl.fs.readFile(allocator, idx_path) catch |err| switch (err) {
        error.FileNotFound => {
            // debug print removed
            return error.ObjectNotFound;
        },
        error.AccessDenied => {
            // debug print removed
            return error.PackIndexAccessDenied;
        },
        else => {
            // debug print removed
            return error.PackIndexReadError;
        },
    };
    defer allocator.free(idx_data);
    
    // Enhanced size validation
            // debug print removed
    if (idx_data.len < 8) {
            // debug print removed
        return error.CorruptedPackIndex;
    }
    if (idx_data.len > 100 * 1024 * 1024) { // 100MB max for pack index
            // debug print removed
        return error.PackIndexTooLarge;
    }
    
    // Check for pack index magic and version
    const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
    const version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
    
            // debug print removed
    
    if (magic != 0xff744f63) {
        // No magic header, might be version 1 format
            // debug print removed
        if (idx_data.len < 256 * 4) {
            // debug print removed
            return error.CorruptedPackIndex;
        }
        return findObjectInPackV1(idx_data, target_hash, pack_dir_path, idx_filename, platform_impl, allocator);
    }
    if (version != 2) {
        // Unsupported version
        if (version == 1) {
            // Explicit v1 format (rare but valid)
            return findObjectInPackV1(idx_data[8..], target_hash, pack_dir_path, idx_filename, platform_impl, allocator);
        } else if (version > 2) {
            // Future version - be strict about not supporting it
            // debug print removed
            return error.UnsupportedPackIndexVersion;
        } else {
            return error.CorruptedPackIndex;
        }
    }
    
    // Use fanout table for efficient searching with bounds checking
    const fanout_start = 8;
    const fanout_end = fanout_start + 256 * 4;
    if (idx_data.len < fanout_end) {
            // debug print removed
        return error.ObjectNotFound;
    }
    
    // Get search range from fanout table with enhanced bounds checking
    const first_byte = target_hash[0];
            // debug print removed
    
    const start_index = if (first_byte == 0) 0 else blk: {
        const offset = fanout_start + (@as(usize, first_byte) - 1) * 4;
        if (offset + 4 > idx_data.len) return error.CorruptedPackIndex;
        break :blk std.mem.readInt(u32, @ptrCast(idx_data[offset..offset + 4]), .big);
    };
    const end_index = blk: {
        const offset = fanout_start + @as(usize, first_byte) * 4;
        if (offset + 4 > idx_data.len) return error.CorruptedPackIndex;
        break :blk std.mem.readInt(u32, @ptrCast(idx_data[offset..offset + 4]), .big);
    };
    
            // debug print removed
    
    // Validate fanout table consistency
    if (start_index > end_index) return error.CorruptedPackIndex;
    if (end_index > 50_000_000) { // Sanity check: 50M objects max
            // debug print removed
        return error.SuspiciousPackIndex;
    }
    
    if (start_index >= end_index) return error.ObjectNotFound;
    
    // Binary search in the SHA-1 table within the range with better bounds checking
    const sha1_table_start = fanout_end;
    const sha1_table_end = sha1_table_start + end_index * 20;
    if (idx_data.len < sha1_table_end) {
            // debug print removed
        return error.CorruptedPackIndex;
    }
    
    var low = start_index;
    var high = end_index;
    var object_index: ?u32 = null;
    
    while (low < high) {
        const mid = low + (high - low) / 2;
        const sha1_offset = sha1_table_start + mid * 20;
        const obj_hash = idx_data[sha1_offset..sha1_offset + 20];
        
        const cmp = std.mem.order(u8, obj_hash, &target_hash);
        switch (cmp) {
            .eq => {
                object_index = mid;
                break;
            },
            .lt => low = mid + 1,
            .gt => high = mid,
        }
    }
    
    if (object_index == null) return error.ObjectNotFound;
    
    // Get offset from offset table - handle both 32-bit and 64-bit offsets
    const crc_table_start = sha1_table_end;
    const offset_table_start = crc_table_start + end_index * 4; // Skip CRC table
    const offset_table_offset = offset_table_start + object_index.? * 4;
    if (idx_data.len < offset_table_offset + 4) return error.ObjectNotFound;
    
    var object_offset: u64 = std.mem.readInt(u32, @ptrCast(idx_data[offset_table_offset..offset_table_offset + 4]), .big);
    
    // Check for 64-bit offset (MSB set)
    if (object_offset & 0x80000000 != 0) {
        const large_offset_index = object_offset & 0x7FFFFFFF;
        const large_offset_table_start = offset_table_start + end_index * 4;
        const large_offset_table_offset = large_offset_table_start + large_offset_index * 8;
        if (idx_data.len < large_offset_table_offset + 8) return error.ObjectNotFound;
        
        object_offset = std.mem.readInt(u64, @ptrCast(idx_data[large_offset_table_offset..large_offset_table_offset + 8]), .big);
    }
    
    // Now read from the corresponding .pack file
    const pack_filename = try std.fmt.allocPrint(allocator, "{s}.pack", .{idx_filename[0..idx_filename.len-4]});
    defer allocator.free(pack_filename);
    
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_dir_path, pack_filename});
    defer allocator.free(pack_path);
    
    return readObjectFromPack(pack_path, object_offset, platform_impl, allocator);
}

/// Find object in pack index v1 format (legacy support)
fn findObjectInPackV1(idx_data: []const u8, target_hash: [20]u8, pack_dir_path: []const u8, idx_filename: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !GitObject {
    // Pack index v1: fanout[256] + (sha1[20] + offset[4]) * N
    if (idx_data.len < 256 * 4) return error.ObjectNotFound;
    
    const fanout_start = 0;
    const first_byte = target_hash[0];
    
    // Get search range from fanout table
    const start_index = if (first_byte == 0) 0 else std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + (@as(usize, first_byte) - 1) * 4..fanout_start + (@as(usize, first_byte) - 1) * 4 + 4]), .big);
    const end_index = std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + @as(usize, first_byte) * 4..fanout_start + @as(usize, first_byte) * 4 + 4]), .big);
    
    if (start_index >= end_index) return error.ObjectNotFound;
    
    // Object entries start after fanout table
    const entries_start = 256 * 4;
    const entry_size = 24; // 20 bytes SHA-1 + 4 bytes offset
    
    // Binary search in the entries within the range
    var low = start_index;
    var high = end_index;
    
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry_offset = entries_start + mid * entry_size;
        
        if (entry_offset + 20 > idx_data.len) return error.ObjectNotFound;
        const obj_hash = idx_data[entry_offset..entry_offset + 20];
        
        const cmp = std.mem.order(u8, obj_hash, &target_hash);
        switch (cmp) {
            .eq => {
                // Found the object, get its offset
                if (entry_offset + 24 > idx_data.len) return error.ObjectNotFound;
                const object_offset: u64 = std.mem.readInt(u32, @ptrCast(idx_data[entry_offset + 20..entry_offset + 24]), .big);
                
                // Read from the corresponding .pack file
                const pack_filename = try std.fmt.allocPrint(allocator, "{s}.pack", .{idx_filename[0..idx_filename.len-4]});
                defer allocator.free(pack_filename);
                
                const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_dir_path, pack_filename});
                defer allocator.free(pack_path);
                
                return readObjectFromPack(pack_path, object_offset, platform_impl, allocator);
            },
            .lt => low = mid + 1,
            .gt => high = mid,
        }
    }
    
    return error.ObjectNotFound;
}

/// Read object from pack file at given offset with validation
fn readObjectFromPack(pack_path: []const u8, offset: u64, platform_impl: anytype, allocator: std.mem.Allocator) !GitObject {
    const pack_data = platform_impl.fs.readFile(allocator, pack_path) catch return error.ObjectNotFound;
    defer allocator.free(pack_data);
    
    // Validate pack file format
    if (pack_data.len < 12) return error.InvalidPackFile; // Minimum header size
    
    // Check pack file header: "PACK" + version + object count
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) {
            // debug print removed
        return error.InvalidPackFile;
    }
    
    const version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
    if (version != 2 and version != 3) {
            // debug print removed
        return error.UnsupportedPackVersion;
    }
    
    const object_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    if (object_count == 0) {
            // debug print removed
        return error.EmptyPackFile;
    }
    
    // Sanity check object count (prevent malicious/corrupted pack files)
    const max_reasonable_objects = 10_000_000; // 10 million objects max
    if (object_count > max_reasonable_objects) {
            // debug print removed
        return error.SuspiciousPackFile;
    }
    
    if (offset >= pack_data.len) {
            // debug print removed
        return error.OffsetOutOfBounds;
    }
    
    // Ensure we're not too close to the end (need at least a few bytes for object header)
    if (offset > pack_data.len - 4) {
            // debug print removed
        return error.OffsetOutOfBounds;
    }
    
    return readPackedObject(pack_data, @intCast(offset), pack_path, platform_impl, allocator);
}

/// Read a packed object with delta support
fn readPackedObject(pack_data: []const u8, offset: usize, pack_path: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !GitObject {
    if (offset >= pack_data.len) return error.ObjectNotFound;
    
    var pos = offset;
    const first_byte = pack_data[pos];
    pos += 1;
    
    const pack_type_num = (first_byte >> 4) & 7;
    const pack_type = std.meta.intToEnum(PackObjectType, pack_type_num) catch return error.ObjectNotFound;
    
    // Read variable-length size
    var size: usize = @intCast(first_byte & 15);
    var shift: u6 = 4;
    var current_byte = first_byte;
    
    while (current_byte & 0x80 != 0 and pos < pack_data.len) {
        current_byte = pack_data[pos];
        pos += 1;
        size |= @as(usize, @intCast(current_byte & 0x7F)) << shift;
        shift += 7;
    }
    
    switch (pack_type) {
        .commit, .tree, .blob, .tag => {
            // Regular object - decompress and return
            if (pos >= pack_data.len) return error.ObjectNotFound;
            
            var decompressed = std.ArrayList(u8).init(allocator);
            defer decompressed.deinit();
            
            var stream = std.io.fixedBufferStream(pack_data[pos..]);
            std.compress.zlib.decompress(stream.reader(), decompressed.writer()) catch return error.ObjectNotFound;
            
            if (decompressed.items.len != size) return error.ObjectNotFound;
            
            const obj_type: ObjectType = switch (pack_type) {
                .commit => .commit,
                .tree => .tree,
                .blob => .blob,
                .tag => .tag,
                else => unreachable,
            };
            
            const data = try allocator.dupe(u8, decompressed.items);
            return GitObject.init(obj_type, data);
        },
        .ofs_delta => {
            // Offset delta - read offset to base object using git's encoding
            if (pos >= pack_data.len) return error.ObjectNotFound;
            
            var base_offset_delta: usize = 0;
            var first_offset_byte = true;
            
            while (pos < pack_data.len) {
                const offset_byte = pack_data[pos];
                pos += 1;
                
                if (first_offset_byte) {
                    base_offset_delta = @intCast(offset_byte & 0x7F);
                    first_offset_byte = false;
                } else {
                    base_offset_delta = (base_offset_delta + 1) << 7;
                    base_offset_delta += @intCast(offset_byte & 0x7F);
                }
                
                if (offset_byte & 0x80 == 0) break;
            }
            
            // Calculate base object offset
            if (base_offset_delta >= offset) return error.ObjectNotFound;
            const base_offset = offset - base_offset_delta;
            
            // Recursively read base object
            const base_object = readPackedObject(pack_data, base_offset, pack_path, platform_impl, allocator) catch return error.ObjectNotFound;
            defer base_object.deinit(allocator);
            
            // Read and decompress delta data
            var delta_data = std.ArrayList(u8).init(allocator);
            defer delta_data.deinit();
            
            var stream = std.io.fixedBufferStream(pack_data[pos..]);
            std.compress.zlib.decompress(stream.reader(), delta_data.writer()) catch return error.ObjectNotFound;
            
            // Apply delta to base object
            const result_data = try applyDelta(base_object.data, delta_data.items, allocator);
            return GitObject.init(base_object.type, result_data);
        },
        .ref_delta => {
            // Reference delta - read 20-byte SHA-1 of base object
            if (pos + 20 > pack_data.len) return error.ObjectNotFound;
            
            const base_sha1 = pack_data[pos..pos + 20];
            pos += 20;
            
            // Convert SHA-1 to hex string for recursive lookup
            const base_hash_str = try allocator.alloc(u8, 40);
            defer allocator.free(base_hash_str);
            _ = try std.fmt.bufPrint(base_hash_str, "{}", .{std.fmt.fmtSliceHexLower(base_sha1)});
            
            // Look up base object offset in pack index, then read directly from pack_data (avoid recursive cycle)
            const pack_dir = std.fs.path.dirname(pack_path) orelse return error.ObjectNotFound;
            const pack_fname = std.fs.path.basename(pack_path);
            if (!std.mem.endsWith(u8, pack_fname, ".pack")) return error.ObjectNotFound;
            const idx_fname = try std.fmt.allocPrint(allocator, "{s}.idx", .{pack_fname[0 .. pack_fname.len - 5]});
            defer allocator.free(idx_fname);
            const idx_path2 = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, idx_fname });
            defer allocator.free(idx_path2);
            const idx_data2 = platform_impl.fs.readFile(allocator, idx_path2) catch return error.ObjectNotFound;
            defer allocator.free(idx_data2);
            var base_hash_bytes: [20]u8 = undefined;
            _ = std.fmt.hexToBytes(&base_hash_bytes, base_hash_str) catch return error.ObjectNotFound;
            // Search idx for the base object offset
            const base_offset2 = findOffsetInIdx(idx_data2, base_hash_bytes) orelse return error.ObjectNotFound;
            const base_object = readPackedObject(pack_data, base_offset2, pack_path, platform_impl, allocator) catch return error.ObjectNotFound;
            defer base_object.deinit(allocator);
            
            // Read and decompress delta data
            var delta_data = std.ArrayList(u8).init(allocator);
            defer delta_data.deinit();
            
            var stream = std.io.fixedBufferStream(pack_data[pos..]);
            std.compress.zlib.decompress(stream.reader(), delta_data.writer()) catch return error.ObjectNotFound;
            
            // Apply delta to base object
            const result_data = try applyDelta(base_object.data, delta_data.items, allocator);
            return GitObject.init(base_object.type, result_data);
        },
    }
}

/// Look up an object's offset in a pack index by its SHA-1 hash (non-generic, breaks recursive cycle)
fn findOffsetInIdx(idx_data: []const u8, target_hash: [20]u8) ?usize {
    if (idx_data.len < 8) return null;
    
    // Check for v2 magic
    const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
    if (magic == 0xff744f63) {
        // V2 index
        const fanout_start: usize = 8;
        const first_byte = target_hash[0];
        
        if (idx_data.len < fanout_start + 256 * 4) return null;
        
        const start_index: u32 = if (first_byte == 0) 0 else std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + (@as(usize, first_byte) - 1) * 4 .. fanout_start + (@as(usize, first_byte) - 1) * 4 + 4]), .big);
        const end_index = std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + @as(usize, first_byte) * 4 .. fanout_start + @as(usize, first_byte) * 4 + 4]), .big);
        
        if (start_index >= end_index) return null;
        
        const total_objects = std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + 255 * 4 .. fanout_start + 255 * 4 + 4]), .big);
        const sha1_table_start = fanout_start + 256 * 4;
        const crc_table_start = sha1_table_start + @as(usize, total_objects) * 20;
        const offset_table_start = crc_table_start + @as(usize, total_objects) * 4;
        
        // Binary search for efficiency
        var low = start_index;
        var high = end_index;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const sha_offset = sha1_table_start + @as(usize, mid) * 20;
            if (sha_offset + 20 > idx_data.len) return null;
            
            const obj_hash = idx_data[sha_offset .. sha_offset + 20];
            const cmp = std.mem.order(u8, obj_hash, &target_hash);
            
            switch (cmp) {
                .eq => {
                    // Found it, get offset
                    const off_offset = offset_table_start + @as(usize, mid) * 4;
                    if (off_offset + 4 > idx_data.len) return null;
                    var offset_val: u64 = std.mem.readInt(u32, @ptrCast(idx_data[off_offset .. off_offset + 4]), .big);
                    
                    // Handle 64-bit offsets
                    if (offset_val & 0x80000000 != 0) {
                        const large_offset_index = offset_val & 0x7FFFFFFF;
                        const large_offset_table_start = offset_table_start + @as(usize, total_objects) * 4;
                        const large_offset_table_offset = large_offset_table_start + @as(usize, large_offset_index) * 8;
                        if (large_offset_table_offset + 8 > idx_data.len) return null;
                        
                        offset_val = std.mem.readInt(u64, @ptrCast(idx_data[large_offset_table_offset .. large_offset_table_offset + 8]), .big);
                    }
                    
                    return @intCast(offset_val);
                },
                .lt => low = mid + 1,
                .gt => high = mid,
            }
        }
        return null;
    } else {
        // V1 index - fanout table followed by (offset, SHA-1) pairs
        const fanout_start: usize = 0;
        const first_byte = target_hash[0];
        
        if (idx_data.len < 256 * 4) return null;
        
        const start_index: u32 = if (first_byte == 0) 0 else std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + (@as(usize, first_byte) - 1) * 4 .. fanout_start + (@as(usize, first_byte) - 1) * 4 + 4]), .big);
        const end_index = std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + @as(usize, first_byte) * 4 .. fanout_start + @as(usize, first_byte) * 4 + 4]), .big);
        
        if (start_index >= end_index) return null;
        
        const entries_start: usize = 256 * 4;
        
        // Binary search for efficiency
        var low = start_index;
        var high = end_index;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry_offset = entries_start + @as(usize, mid) * 24;
            if (entry_offset + 24 > idx_data.len) return null;
            
            // V1 format: 4 bytes offset + 20 bytes SHA-1
            const obj_hash = idx_data[entry_offset + 4 .. entry_offset + 24];
            const cmp = std.mem.order(u8, obj_hash, &target_hash);
            
            switch (cmp) {
                .eq => {
                    const offset_val = std.mem.readInt(u32, @ptrCast(idx_data[entry_offset .. entry_offset + 4]), .big);
                    return @intCast(offset_val);
                },
                .lt => low = mid + 1,
                .gt => high = mid,
            }
        }
        return null;
    }
}

/// Apply delta to base data to reconstruct object with improved error handling
fn applyDelta(base_data: []const u8, delta_data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (delta_data.len < 2) return error.DeltaTooShort; // Need at least base_size and result_size
    if (base_data.len > 1024 * 1024 * 1024) return error.BaseTooLarge; // 1GB limit
    
    var pos: usize = 0;
    
    // Read base size (variable length)
    var base_size: usize = 0;
    var shift: u6 = 0;
    while (pos < delta_data.len and shift < 64) {
        const b = delta_data[pos];
        pos += 1;
        base_size |= @as(usize, @intCast(b & 0x7F)) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
        
        // Prevent unreasonably large base sizes
        if (shift > 32) { // Max 4GB base size
            // debug print removed
            return error.DeltaCorrupted;
        }
    }
    
    if (pos >= delta_data.len) return error.DeltaTruncated;
    
    // Read result size (variable length) 
    var result_size: usize = 0;
    shift = 0;
    while (pos < delta_data.len and shift < 64) {
        const b = delta_data[pos];
        pos += 1;
        result_size |= @as(usize, @intCast(b & 0x7F)) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
        
        // Prevent unreasonably large result sizes  
        if (shift > 32) { // Max 4GB result size
            // debug print removed
            return error.DeltaCorrupted;
        }
    }
    
    // Verify base size matches actual base data
    if (base_size != base_data.len) {
        // debug print removed
        return error.BaseSizeMismatch;
    }
    
    // Sanity check result size (100MB max for regular use)
    if (result_size > 100 * 1024 * 1024) {
        // debug print removed
        return error.ResultTooLarge;
    }
    
    // Basic sanity check: result size shouldn't be dramatically different from base
    if (result_size > base_size * 10 and result_size > 1024 * 1024) { // Allow small files to grow significantly
        // debug print removed
        return error.SuspiciousDelta;
    }
    
    // Apply delta commands
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    try result.ensureTotalCapacity(result_size);
    
    while (pos < delta_data.len) {
        if (pos >= delta_data.len) break; // Safety check
        
        const cmd = delta_data[pos];
        pos += 1;
        
        if (cmd & 0x80 != 0) {
            // Copy command
            var copy_offset: usize = 0;
            var copy_size: usize = 0;
            
            // Read offset (up to 4 bytes, little-endian)
            if (cmd & 0x01 != 0) { 
                if (pos >= delta_data.len) return error.DeltaTruncated;
                copy_offset |= @as(usize, delta_data[pos]); 
                pos += 1; 
            }
            if (cmd & 0x02 != 0) { 
                if (pos >= delta_data.len) return error.DeltaTruncated;
                copy_offset |= @as(usize, delta_data[pos]) << 8; 
                pos += 1; 
            }
            if (cmd & 0x04 != 0) { 
                if (pos >= delta_data.len) return error.DeltaTruncated;
                copy_offset |= @as(usize, delta_data[pos]) << 16; 
                pos += 1; 
            }
            if (cmd & 0x08 != 0) { 
                if (pos >= delta_data.len) return error.DeltaTruncated;
                copy_offset |= @as(usize, delta_data[pos]) << 24; 
                pos += 1; 
            }
            
            // Read size (up to 3 bytes, little-endian)
            if (cmd & 0x10 != 0) { 
                if (pos >= delta_data.len) return error.DeltaTruncated;
                copy_size |= @as(usize, delta_data[pos]); 
                pos += 1; 
            }
            if (cmd & 0x20 != 0) { 
                if (pos >= delta_data.len) return error.DeltaTruncated;
                copy_size |= @as(usize, delta_data[pos]) << 8; 
                pos += 1; 
            }
            if (cmd & 0x40 != 0) { 
                if (pos >= delta_data.len) return error.DeltaTruncated;
                copy_size |= @as(usize, delta_data[pos]) << 16; 
                pos += 1; 
            }
            
            // Size 0 means 0x10000
            if (copy_size == 0) copy_size = 0x10000;
            
            // Validate copy parameters
            if (copy_offset >= base_data.len) return error.InvalidDelta;
            if (copy_offset + copy_size > base_data.len) {
                // Clamp to available data rather than failing completely
                copy_size = base_data.len - copy_offset;
            }
            if (copy_size == 0) return error.InvalidDelta;
            
            // Prevent result from growing too large
            if (result.items.len + copy_size > result_size) return error.InvalidDelta;
            
            // Copy data from base
            try result.appendSlice(base_data[copy_offset..copy_offset + copy_size]);
        } else if (cmd > 0) {
            // Insert command - copy data from delta
            const insert_size = @as(usize, cmd);
            if (pos + insert_size > delta_data.len) return error.DeltaTruncated;
            
            // Prevent result from growing too large
            if (result.items.len + insert_size > result_size) return error.InvalidDelta;
            
            try result.appendSlice(delta_data[pos..pos + insert_size]);
            pos += insert_size;
        } else {
            // cmd == 0 is reserved and invalid
            return error.InvalidDelta;
        }
        
        // Safety check: don't let result grow beyond expected size
        if (result.items.len > result_size) return error.InvalidDelta;
    }
    
    // Verify result size matches expected
    if (result.items.len != result_size) {
        return error.ResultSizeMismatch;
    }
    
    return try allocator.dupe(u8, result.items);
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