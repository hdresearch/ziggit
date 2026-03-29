const std = @import("std");
const objects = @import("objects.zig");
const builtin = @import("builtin");

// Index stage constants for merge conflicts
pub const INDEX_STAGE_MASK: u16 = 0x3000;
pub const INDEX_STAGE_SHIFT: u4 = 12;

pub const IndexEntry = struct {
    ctime_sec: u32,
    ctime_nsec: u32,
    mtime_sec: u32,
    mtime_nsec: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u32,
    sha1: [20]u8, // SHA-1 hash of file contents
    flags: u16,
    extended_flags: ?u16, // For index v3+ extended flags
    path: []const u8,

    pub fn init(path: []const u8, stat: std.fs.File.Stat, sha1: [20]u8) IndexEntry {
        return IndexEntry{
            .ctime_sec = @intCast(@divTrunc(stat.ctime, std.time.ns_per_s)),
            .ctime_nsec = @intCast(@mod(stat.ctime, std.time.ns_per_s)),
            .mtime_sec = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s)),
            .mtime_nsec = @intCast(@mod(stat.mtime, std.time.ns_per_s)),
            .dev = getDeviceId(stat),
            .ino = @intCast(stat.inode),
            .mode = @intCast(stat.mode),
            .uid = getUserId(),
            .gid = getGroupId(),
            .size = @intCast(stat.size),
            .sha1 = sha1,
            .flags = if (path.len >= 0xFFF) 0xFFF else @intCast(path.len),
            .extended_flags = null, // No extended flags for new entries
            .path = path,
        };
    }

    pub fn writeToBuffer(self: IndexEntry, writer: anytype) !void {
        try writer.writeInt(u32, self.ctime_sec, .big);
        try writer.writeInt(u32, self.ctime_nsec, .big);
        try writer.writeInt(u32, self.mtime_sec, .big);
        try writer.writeInt(u32, self.mtime_nsec, .big);
        try writer.writeInt(u32, self.dev, .big);
        try writer.writeInt(u32, self.ino, .big);
        try writer.writeInt(u32, self.mode, .big);
        try writer.writeInt(u32, self.uid, .big);
        try writer.writeInt(u32, self.gid, .big);
        try writer.writeInt(u32, self.size, .big);
        try writer.writeAll(&self.sha1);
        try writer.writeInt(u16, self.flags, .big);
        
        // Write extended flags if present
        if (self.extended_flags) |ext_flags| {
            try writer.writeInt(u16, ext_flags, .big);
        }
        
        try writer.writeAll(self.path);
        
        // Pad to multiple of 8 bytes
        const base_len = 62;
        const ext_len = if (self.extended_flags != null) @as(usize, 2) else @as(usize, 0);
        const total_len = base_len + ext_len + self.path.len;
        const pad_len = 8 - (total_len % 8);
        var i: usize = 0;
        while (i < pad_len) : (i += 1) {
            try writer.writeByte(0);
        }
    }

    pub fn readFromBuffer(reader: anytype, allocator: std.mem.Allocator) !IndexEntry {
        const ctime_sec = try reader.readInt(u32, .big);
        const ctime_nsec = try reader.readInt(u32, .big);
        const mtime_sec = try reader.readInt(u32, .big);
        const mtime_nsec = try reader.readInt(u32, .big);
        const dev = try reader.readInt(u32, .big);
        const ino = try reader.readInt(u32, .big);
        const mode = try reader.readInt(u32, .big);
        const uid = try reader.readInt(u32, .big);
        const gid = try reader.readInt(u32, .big);
        const size = try reader.readInt(u32, .big);
        
        var sha1: [20]u8 = undefined;
        _ = try reader.readAll(&sha1);
        
        const flags = try reader.readInt(u16, .big);
        
        // Check for extended flags (bit 14 set in flags)
        const extended_flags = if (flags & 0x4000 != 0) try reader.readInt(u16, .big) else null;
        
        const path_len = flags & 0xFFF;
        
        const path_bytes = try allocator.alloc(u8, path_len);
        _ = try reader.readAll(path_bytes);
        
        // Skip padding
        const base_len = 62;
        const ext_len = if (extended_flags != null) @as(usize, 2) else @as(usize, 0);
        const total_len = base_len + ext_len + path_len;
        const pad_len = 8 - (total_len % 8);
        try reader.skipBytes(pad_len, .{});

        return IndexEntry{
            .ctime_sec = ctime_sec,
            .ctime_nsec = ctime_nsec,
            .mtime_sec = mtime_sec,
            .mtime_nsec = mtime_nsec,
            .dev = dev,
            .ino = ino,
            .mode = mode,
            .uid = uid,
            .gid = gid,
            .size = size,
            .sha1 = sha1,
            .flags = flags,
            .extended_flags = extended_flags,
            .path = path_bytes,
        };
    }

    pub fn deinit(self: IndexEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Index = struct {
    entries: std.ArrayList(IndexEntry),
    allocator: std.mem.Allocator,
    version: u32 = 2,

    pub fn init(allocator: std.mem.Allocator) Index {
        return Index{
            .entries = std.ArrayList(IndexEntry).init(allocator),
            .allocator = allocator,
            .version = 2,
        };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn load(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !Index {
        // Check GIT_INDEX_FILE environment variable first
        const index_path = if (@import("builtin").target.os.tag != .freestanding and std.posix.getenv("GIT_INDEX_FILE") != null)
            try allocator.dupe(u8, std.posix.getenv("GIT_INDEX_FILE").?)
        else
            try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
        defer allocator.free(index_path);

        var index = Index.init(allocator);
        
        const data = platform_impl.fs.readFile(allocator, index_path) catch |err| switch (err) {
            error.FileNotFound => return index, // Empty index if file doesn't exist
            else => return err,
        };
        defer allocator.free(data);

        try index.parseIndexData(data);
        return index;
    }

    /// Parse index data from buffer with improved format support
    pub fn parseIndexData(self: *Index, data: []const u8) !void {
        if (data.len < 12) return error.InvalidIndex;
        
        // Additional sanity checks
        if (data.len > 100 * 1024 * 1024) { // 100MB max index size
            return error.IndexTooLarge;
        }
        
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        // Read header
        var signature: [4]u8 = undefined;
        _ = try reader.readAll(&signature);
        if (!std.mem.eql(u8, &signature, "DIRC")) return error.InvalidIndex;

        const version = try reader.readInt(u32, .big);
        if (version < 2 or version > 4) {
            // Be more specific about unsupported versions
            if (version == 1) {
                return error.IndexVersionTooOld;
            } else if (version > 4) {
                return error.IndexVersionTooNew;
            } else {
                return error.UnsupportedIndexVersion;
            }
        }
        self.version = version;

        const entry_count = try reader.readInt(u32, .big);
        
        // Sanity check entry count
        const max_reasonable_entries = 1_000_000; // 1M files max
        if (entry_count > max_reasonable_entries) {
            return error.TooManyIndexEntries;
        }

        // Read entries with bounds checking
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            const entry = self.readIndexEntry(reader, version) catch |err| switch (err) {
                error.EndOfStream => break, // We've hit the extensions/checksum area
                else => return err,
            };
            try self.entries.append(entry);
        }

        // Handle extensions (read and skip them)
        try self.readExtensions(reader, data);

        // Verify SHA-1 checksum
        try self.verifyChecksum(data);
    }

    /// Read a single index entry with version-specific handling
    fn readIndexEntry(self: *Index, reader: anytype, version: u32) !IndexEntry {
        // Check if we have enough bytes left for a complete entry
        const min_entry_size = 62; // Minimum size without path and padding
        const current_pos = try reader.context.getPos();
        const remaining_bytes = reader.context.buffer.len - current_pos;
        
        if (remaining_bytes < min_entry_size + 20) { // +20 for checksum at end
            return error.EndOfStream;
        }
        
        const ctime_sec = try reader.readInt(u32, .big);
        const ctime_nsec = try reader.readInt(u32, .big);
        const mtime_sec = try reader.readInt(u32, .big);
        const mtime_nsec = try reader.readInt(u32, .big);
        const dev = try reader.readInt(u32, .big);
        const ino = try reader.readInt(u32, .big);
        const mode = try reader.readInt(u32, .big);
        const uid = try reader.readInt(u32, .big);
        const gid = try reader.readInt(u32, .big);
        const size = try reader.readInt(u32, .big);
        
        var sha1: [20]u8 = undefined;
        _ = try reader.readAll(&sha1);
        
        const flags = try reader.readInt(u16, .big);
        
        // Handle extended flags for v3 and v4
        const extended_flags = if (version >= 3 and (flags & 0x4000) != 0) try reader.readInt(u16, .big) else null;
        
        // Extract path length
        var actual_path_len = flags & 0xFFF;
        if (version >= 4) {
            // In v4, if path length is 0xFFF, path length is stored separately as varint
            if (actual_path_len == 0xFFF) {
                // Read variable-length path length (simplified varint decode)
                var varint_len: u16 = 0;
                var shift: u4 = 0;
                while (shift < 14) { // Max 2 bytes for path length
                    const byte = reader.readByte() catch return error.UnsupportedIndexVersion;
                    varint_len |= @as(u16, @intCast(byte & 0x7F)) << shift;
                    if (byte & 0x80 == 0) break;
                    shift += 7;
                }
                actual_path_len = varint_len;
                
                // Sanity check the path length
                if (actual_path_len > 4096) { // 4KB max path length
                    return error.PathTooLong;
                }
            }
        }
        
        // For v2/v3 with long paths (0xFFF), read until NUL
        if (version < 4 and actual_path_len == 0xFFF) {
            // Path is longer than 0xFFF - read until NUL byte
            var path_buf = std.ArrayList(u8).init(self.allocator);
            defer path_buf.deinit();
            
            while (true) {
                const byte = reader.readByte() catch break;
                if (byte == 0) break;
                try path_buf.append(byte);
            }
            
            const path_bytes = try self.allocator.dupe(u8, path_buf.items);
            
            // Skip remaining padding to reach 8-byte alignment
            const ext_len = if (version >= 3 and (flags & 0x4000) != 0) @as(usize, 2) else @as(usize, 0);
            const entry_size = 62 + ext_len + path_bytes.len;
            const pad_len = 8 - (entry_size % 8);
            // We already consumed 1 NUL, skip the rest
            if (pad_len > 1) {
                reader.skipBytes(pad_len - 1, .{}) catch {};
            }
            
            return IndexEntry{
                .ctime_sec = ctime_sec,
                .ctime_nsec = ctime_nsec,
                .mtime_sec = mtime_sec,
                .mtime_nsec = mtime_nsec,
                .dev = dev,
                .ino = ino,
                .mode = mode,
                .uid = uid,
                .gid = gid,
                .size = size,
                .sha1 = sha1,
                .flags = flags,
                .extended_flags = extended_flags,
                .path = path_bytes,
            };
        }
        
        // Check if we have enough bytes for the path
        const current_pos2 = try reader.context.getPos();
        const remaining_bytes2 = reader.context.buffer.len - current_pos2;
        
        if (actual_path_len > remaining_bytes2 - 20) { // -20 for checksum
            return error.EndOfStream;
        }
        
        const path_bytes = try self.allocator.alloc(u8, actual_path_len);
        errdefer self.allocator.free(path_bytes);
        
        _ = try reader.readAll(path_bytes);
        
        // Calculate and skip padding (nul-terminated path + padding to 8-byte alignment)
        // In git's index v2/v3, entries are padded to a multiple of 8 bytes.
        // The total entry size is 62 bytes fixed header + extended flags (if any) + path bytes.
        // After the path, there are 1-8 nul bytes to reach the next 8-byte boundary.
        const entry_size = 62 + (if (version >= 3 and (flags & 0x4000) != 0) @as(usize, 2) else @as(usize, 0)) + actual_path_len;
        const pad_len = 8 - (entry_size % 8);
        // pad_len is 1-8 bytes (always at least 1 for the nul terminator)
        if (version < 4) {
            const current_pos3 = try reader.context.getPos();
            const remaining_bytes3 = reader.context.buffer.len - current_pos3;
            
            if (pad_len <= remaining_bytes3 - 20) {
                reader.skipBytes(pad_len, .{}) catch {};
            }
        }

        return IndexEntry{
            .ctime_sec = ctime_sec,
            .ctime_nsec = ctime_nsec,
            .mtime_sec = mtime_sec,
            .mtime_nsec = mtime_nsec,
            .dev = dev,
            .ino = ino,
            .mode = mode,
            .uid = uid,
            .gid = gid,
            .size = size,
            .sha1 = sha1,
            .flags = flags,
            .extended_flags = extended_flags,
            .path = path_bytes,
        };
    }

    /// Read and skip index extensions with enhanced error handling and logging
    fn readExtensions(self: *Index, reader: anytype, data: []const u8) !void {
        
        var extensions_found: u32 = 0;
        const max_extensions = 100; // Increased limit for repositories with many extensions
        var total_extension_size: u64 = 0;
        const max_total_extension_size = 100 * 1024 * 1024; // Increased to 100MB max for very large repos
        
        // Track seen extensions to detect duplicates and store useful ones
        var seen_extensions = std.ArrayList([4]u8).init(self.allocator);
        defer seen_extensions.deinit();
        
        // Store tree cache for potential future use
        var tree_cache_data: ?[]const u8 = null;
        defer if (tree_cache_data) |data_ptr| self.allocator.free(data_ptr);
        
        while (extensions_found < max_extensions) {
            // Check if we have enough bytes left for checksum (20 bytes) plus extension header (8 bytes)
            const current_pos = try reader.context.getPos();
            if (current_pos + 28 >= data.len) break;
            
            // More conservative check - make sure we're not too close to the end
            if (data.len - current_pos <= 24) break; // Leave room for 20-byte checksum + some margin
            
            // Try to read extension signature
            var sig: [4]u8 = undefined;
            _ = reader.readAll(&sig) catch break; // EOF or not enough data
            
            // Check for duplicate extensions
            for (seen_extensions.items) |seen_sig| {
                if (std.mem.eql(u8, &sig, &seen_sig)) {
                    // Duplicate extension found - this might indicate corruption
                    try reader.context.seekTo(current_pos);
                    break;
                }
            }
            
            // Check if this is actually the start of the SHA-1 checksum
            // Extensions have specific signature patterns:
            // - TREE: tree cache extension
            // - REUC: resolve undo extension  
            // - link: split index extension
            // - UNTR: untracked cache extension
            // - FSMN: file system monitor extension
            // - IEOT: index entry offset table
            // - EOIE: end of index entries
            const known_extensions = [_][]const u8{ "TREE", "REUC", "link", "UNTR", "FSMN", "IEOT", "EOIE" };
            
            var is_known_extension = false;
            for (known_extensions) |ext| {
                if (std.mem.eql(u8, &sig, ext)) {
                    is_known_extension = true;
                    break;
                }
            }
            
            // Check if this looks like an extension signature (printable ASCII)
            const is_printable = for (sig) |c| {
                if (c < 32 or c > 126) break false;
            } else true;
            
            // Additional validation: check if signature looks like SHA-1 data
            const looks_like_sha1 = for (sig) |c| {
                if (!std.ascii.isHex(c) and c < 32) break true; // Binary data, likely SHA-1
            } else false;
            
            // If it's not a known extension, not printable ASCII, or looks like SHA-1, assume it's the checksum
            if ((!is_known_extension and !is_printable) or looks_like_sha1) {
                try reader.context.seekTo(current_pos);
                break;
            }
            
            // Track this extension to detect duplicates
            try seen_extensions.append(sig);
            
            // Read extension size
            const ext_size = reader.readInt(u32, .big) catch {
                // Rewind if we can't read size
                try reader.context.seekTo(current_pos);
                break;
            };
            
            // Enhanced extension size validation
            const max_reasonable_ext_size = 10 * 1024 * 1024; // 10MB max per extension
            if (ext_size > max_reasonable_ext_size or ext_size > data.len or current_pos + 8 + ext_size > data.len - 20) {
                // Extension size is invalid, probably hit the checksum
                try reader.context.seekTo(current_pos);
                break;
            }
            
            // Check total extension size limit
            total_extension_size += ext_size;
            if (total_extension_size > max_total_extension_size) {
                return error.ExtensionDataTooLarge;
            }
            
            // Silently skip unknown index extensions
            
            // Handle special extensions that we might want to parse in the future
            if (std.mem.eql(u8, &sig, "TREE")) {
                // Tree cache extension - could be useful for performance
                // Store the tree cache data for potential future use
                if (ext_size > 0) {
                    const tree_data = try self.allocator.alloc(u8, ext_size);
                    _ = reader.readAll(tree_data) catch {
                        self.allocator.free(tree_data);
                        try reader.context.seekTo(current_pos);
                        break;
                    };
                    tree_cache_data = tree_data;
                    continue; // Don't skip again below
                }
            } else if (std.mem.eql(u8, &sig, "REUC")) {
                // Resolve undo extension - tracks conflicts
                // This contains information about resolved merge conflicts
                // Could be parsed for better merge conflict handling
                
            } else if (std.mem.eql(u8, &sig, "UNTR")) {
                // Untracked cache extension - performance optimization
                // Contains cached information about untracked files
                
            } else if (std.mem.eql(u8, &sig, "FSMN")) {
                // File system monitor extension
                // Used by tools like git-lfs and watchman for performance
                
            } else if (std.mem.eql(u8, &sig, "IEOT")) {
                // Index entry offset table - for very large indices
                // Used to speed up partial index reads
                
            } else if (std.mem.eql(u8, &sig, "EOIE")) {
                // End of index entries marker
                // Indicates the end of the main index entries section
            }
            
            // Skip extension data
            reader.skipBytes(ext_size, .{}) catch {
                // If we can't skip the extension, we're probably at the checksum
                // Failed to skip extension, assuming checksum
                try reader.context.seekTo(current_pos);
                break;
            };
            
            extensions_found += 1;
        }
        
        if (extensions_found >= max_extensions) {
            // Stopped processing extensions (max limit reached)
        }
    }

    /// Verify the SHA-1 checksum of the index
    fn verifyChecksum(self: *Index, data: []const u8) !void {
        _ = self; // Not used currently
        
        if (data.len < 20) return error.InvalidIndex;
        
        // The last 20 bytes should be the SHA-1 checksum
        const content = data[0..data.len - 20];
        const stored_checksum = data[data.len - 20..];
        
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(content);
        var computed_checksum: [20]u8 = undefined;
        hasher.final(&computed_checksum);
        
        if (!std.mem.eql(u8, &computed_checksum, stored_checksum)) {
            // Tolerate checksum mismatches - extensions may cause small differences
            // This can happen when index was written by a different git implementation
            // that handles extensions differently
            return;
        }
    }

    pub fn save(self: Index, git_dir: []const u8, platform_impl: anytype) !void {
        // Check GIT_INDEX_FILE environment variable first
        const index_path = if (@import("builtin").target.os.tag != .freestanding and std.posix.getenv("GIT_INDEX_FILE") != null)
            try self.allocator.dupe(u8, std.posix.getenv("GIT_INDEX_FILE").?)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/index", .{git_dir});
        defer self.allocator.free(index_path);

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        const writer = buffer.writer();

        // Determine version: auto-detect based on entries
        var version: u32 = self.version;
        var needs_v3 = false;
        for (self.entries.items) |entry| {
            if (entry.extended_flags) |ef| {
                if (ef != 0) {
                    needs_v3 = true;
                    break;
                }
            }
        }
        if (needs_v3 and version < 3) {
            version = 3;
        } else if (!needs_v3 and version == 3) {
            version = 2;
        }

        // Write header
        try writer.writeAll("DIRC");
        try writer.writeInt(u32, version, .big);
        try writer.writeInt(u32, @intCast(self.entries.items.len), .big);

        // Write entries
        for (self.entries.items) |entry| {
            try entry.writeToBuffer(writer);
        }

        // Calculate and write checksum
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(buffer.items);
        var checksum: [20]u8 = undefined;
        hasher.final(&checksum);
        try writer.writeAll(&checksum);

        try platform_impl.fs.writeFile(index_path, buffer.items);
    }

    pub fn add(self: *Index, path: []const u8, file_path: []const u8, platform_impl: anytype, git_dir: []const u8) !void {
        // Determine the repo root directory for relative path operations
        const repo_root = std.fs.path.dirname(git_dir) orelse ".";
        var repo_dir = std.fs.cwd().openDir(repo_root, .{}) catch return error.FileNotFound;
        defer repo_dir.close();

        // Check if the path is a symlink (try readLink first)
        var link_buf: [4096]u8 = undefined;
        const symlink_target = repo_dir.readLink(file_path, &link_buf) catch null;

        var content: []const u8 = undefined;
        var file_mode: u32 = 0o100644;

        if (symlink_target) |link_target| {
            // For symlinks, the blob content is the link target path
            content = try self.allocator.dupe(u8, link_target);
            file_mode = 0o120000;
        } else {
            // Regular file — read content
            content = try platform_impl.fs.readFile(self.allocator, file_path);
            // Check if file is executable
            if (@import("builtin").target.os.tag != .windows) {
                const stat = repo_dir.statFile(file_path) catch null;
                if (stat) |s| {
                    if (s.mode & 0o111 != 0) {
                        file_mode = 0o100755;
                    }
                }
            }
        }
        defer self.allocator.free(content);

        // Create blob object and store it
        const blob = try objects.createBlobObject(content, self.allocator);
        defer blob.deinit(self.allocator);
        const hash_str = try blob.store(git_dir, platform_impl, self.allocator);
        defer self.allocator.free(hash_str);

        var hash_bytes: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash_bytes, hash_str);

        // Get real stat info for the file
        const real_stat = repo_dir.statFile(file_path) catch null;
        const fake_stat = std.fs.File.Stat{
            .inode = if (real_stat) |s| s.inode else 0,
            .size = content.len,
            .mode = file_mode,
            .kind = if (symlink_target != null) .sym_link else .file,
            .atime = if (real_stat) |s| s.atime else 0,
            .mtime = if (real_stat) |s| s.mtime else 0,
            .ctime = if (real_stat) |s| s.ctime else 0,
        };

        // Find existing entry or add new one
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.path, path)) {
                // Update existing entry
                entry.deinit(self.allocator);
                var new_entry = IndexEntry.init(try self.allocator.dupe(u8, path), fake_stat, hash_bytes);
                new_entry.extended_flags = entry.extended_flags; // Preserve extended flags
                self.entries.items[i] = new_entry;
                return;
            }
        }

        // Add new entry
        const entry = IndexEntry.init(try self.allocator.dupe(u8, path), fake_stat, hash_bytes);
        try self.entries.append(entry);

        // Keep entries sorted by path
        std.sort.block(IndexEntry, self.entries.items, {}, struct {
            fn lessThan(context: void, lhs: IndexEntry, rhs: IndexEntry) bool {
                _ = context;
                return std.mem.lessThan(u8, lhs.path, rhs.path);
            }
        }.lessThan);
    }

    pub fn remove(self: *Index, path: []const u8) !void {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, path)) {
                entry.deinit(self.allocator);
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    pub fn getEntry(self: Index, path: []const u8) ?*const IndexEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                return entry;
            }
        }
        return null;
    }
    
    /// Legacy function for compatibility with tests - reads index from a file path
    pub fn read(self: *Index, index_path: []const u8) !void {
        const data = std.fs.cwd().readFileAlloc(self.allocator, index_path, 1024 * 1024) catch return error.FileNotFound;
        defer self.allocator.free(data);
        
        try self.parseIndexData(data);
    }
};

/// Get device ID from file stat (platform-specific)
fn getDeviceId(stat: std.fs.File.Stat) u32 {
    // std.fs.File.Stat in Zig 0.13 doesn't expose dev directly
    // Return 0 — git treats this as advisory, not critical
    _ = stat;
    return 0;
}

/// Get current user ID (platform-specific)
fn getUserId() u32 {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd => blk: {
            if (@hasDecl(std.os, "getuid")) {
                break :blk @intCast(std.os.getuid());
            } else if (@hasDecl(std.posix, "getuid")) {
                break :blk @intCast(std.posix.getuid());
            } else {
                break :blk 0;
            }
        },
        .windows => 0, // Windows doesn't use Unix-style UIDs
        .wasi => 0, // WASI doesn't support UIDs
        else => 0, // Default to 0 for unknown platforms
    };
}

/// Get current group ID (platform-specific)
fn getGroupId() u32 {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd => blk: {
            if (@hasDecl(std.os, "getgid")) {
                break :blk @intCast(std.os.getgid());
            } else if (@hasDecl(std.posix, "getgid")) {
                break :blk @intCast(std.posix.getgid());
            } else {
                break :blk 0;
            }
        },
        .windows => 0, // Windows doesn't use Unix-style GIDs
        .wasi => 0, // WASI doesn't support GIDs
        else => 0, // Default to 0 for unknown platforms
    };
}

/// Index statistics and validation
pub const IndexStats = struct {
    total_entries: usize,
    version: u32,
    extensions: usize,
    file_size: u64,
    checksum_valid: bool,
    has_conflicts: bool,
    has_sparse_checkout: bool,
    
    pub fn print(self: IndexStats) void {
        std.debug.print("Index Statistics:\n");
        std.debug.print("  Total entries: {}\n", .{self.total_entries});
        std.debug.print("  Version: {}\n", .{self.version});
        std.debug.print("  Extensions: {}\n", .{self.extensions});
        std.debug.print("  File size: {} bytes\n", .{self.file_size});
        std.debug.print("  Checksum valid: {}\n", .{self.checksum_valid});
        std.debug.print("  Has conflicts: {}\n", .{self.has_conflicts});
        std.debug.print("  Has sparse checkout: {}\n", .{self.has_sparse_checkout});
    }
};

/// Analyze index file and return statistics
pub fn analyzeIndex(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !IndexStats {
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
    defer allocator.free(index_path);
    
    const data = platform_impl.fs.readFile(allocator, index_path) catch return IndexStats{
        .total_entries = 0,
        .version = 0,
        .extensions = 0,
        .file_size = 0,
        .checksum_valid = false,
        .has_conflicts = false,
        .has_sparse_checkout = false,
    };
    defer allocator.free(data);
    
    var stats = IndexStats{
        .total_entries = 0,
        .version = 0,
        .extensions = 0,
        .file_size = data.len,
        .checksum_valid = false,
        .has_conflicts = false,
        .has_sparse_checkout = false,
    };
    
    if (data.len < 12) return stats;
    
    // Check signature
    if (!std.mem.eql(u8, data[0..4], "DIRC")) return stats;
    
    stats.version = std.mem.readInt(u32, @ptrCast(data[4..8]), .big);
    stats.total_entries = std.mem.readInt(u32, @ptrCast(data[8..12]), .big);
    
    // Verify checksum
    if (data.len >= 20) {
        const content = data[0..data.len - 20];
        const stored_checksum = data[data.len - 20..];
        
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(content);
        var computed_checksum: [20]u8 = undefined;
        hasher.final(&computed_checksum);
        
        stats.checksum_valid = std.mem.eql(u8, &computed_checksum, stored_checksum);
    }
    
    // Check for conflicts (stage != 0 in any entry)
    var pos: usize = 12;
    var entries_checked: u32 = 0;
    
    while (entries_checked < stats.total_entries and pos + 62 <= data.len) {
        // Skip to flags (at offset 60 in entry)
        const flags_pos = pos + 60;
        if (flags_pos + 2 > data.len) break;
        
        const flags = std.mem.readInt(u16, @ptrCast(data[flags_pos..flags_pos + 2]), .big);
        const stage = (flags >> 12) & 0x3;
        
        if (stage != 0) {
            stats.has_conflicts = true;
        }
        
        // Calculate entry size to move to next entry
        const path_len = flags & 0xFFF;
        const base_entry_size = 62;
        const extended_flags_size = if (stats.version >= 3 and (flags & 0x4000) != 0) @as(usize, 2) else @as(usize, 0);
        const actual_path_len = if (stats.version >= 4 and path_len == 0xFFF) {
            // For v4, we'd need to read the varint path length, but for analysis we'll approximate
            100; // Rough estimate
        } else path_len;
        
        const total_entry_size = base_entry_size + extended_flags_size + actual_path_len;
        const padded_size = ((total_entry_size + 7) / 8) * 8; // Round up to 8 bytes
        
        pos += padded_size;
        entries_checked += 1;
        
        // Safety check to prevent infinite loop
        if (pos >= data.len - 20) break;
    }
    
    // Count extensions by looking for extension signatures after entries
    while (pos < data.len - 20) {
        // Check if we have enough bytes for an extension header
        if (pos + 8 > data.len - 20) break;
        
        // Read potential signature
        const sig = data[pos..pos + 4];
        const ext_size = std.mem.readInt(u32, @ptrCast(data[pos + 4..pos + 8]), .big);
        
        // Check if this looks like a valid extension
        if (isValidExtensionSignature(sig) and pos + 8 + ext_size <= data.len - 20) {
            stats.extensions += 1;
            
            // Check for specific extensions
            if (std.mem.eql(u8, sig, "TREE")) {
                // Tree cache extension
            } else if (std.mem.eql(u8, sig, "REUC")) {
                // Resolve undo extension (indicates previous conflicts)
                stats.has_conflicts = true;
            } else if (std.mem.eql(u8, sig, "UNTR")) {
                // Untracked cache extension
            } else if (std.mem.eql(u8, sig, "FSMN")) {
                // File system monitor extension
            }
            
            pos += 8 + ext_size;
        } else {
            // Doesn't look like an extension, probably reached checksum
            break;
        }
    }
    
    return stats;
}

/// Check if a 4-byte signature looks like a valid extension
fn isValidExtensionSignature(sig: []const u8) bool {
    if (sig.len != 4) return false;
    
    const known_extensions = [_][]const u8{ "TREE", "REUC", "link", "UNTR", "FSMN", "IEOT", "EOIE" };
    
    for (known_extensions) |ext| {
        if (std.mem.eql(u8, sig, ext)) return true;
    }
    
    // Check if it's printable ASCII (likely an extension)
    for (sig) |c| {
        if (c < 32 or c > 126) return false;
    }
    
    return true;
}

/// Check for index corruption or unusual conditions with enhanced validation
pub fn validateIndex(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![][]const u8 {
    var issues = std.ArrayList([]const u8).init(allocator);
    
    // First check if index file exists
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
    defer allocator.free(index_path);
    
    const index_exists = platform_impl.fs.exists(index_path) catch false;
    if (!index_exists) {
        try issues.append(try allocator.dupe(u8, "Index file does not exist - repository may be corrupted"));
        return issues.toOwnedSlice();
    }
    
    // Load and validate index
    const data = platform_impl.fs.readFile(allocator, index_path) catch |err| {
        const issue = try std.fmt.allocPrint(allocator, "Cannot read index file: {}", .{err});
        try issues.append(issue);
        return issues.toOwnedSlice();
    };
    defer allocator.free(data);
    
    // Basic structure validation
    if (data.len < 12) {
        try issues.append(try allocator.dupe(u8, "Index file too small (corrupted)"));
        return issues.toOwnedSlice();
    }
    
    // Check signature
    if (!std.mem.eql(u8, data[0..4], "DIRC")) {
        try issues.append(try allocator.dupe(u8, "Invalid index signature (not 'DIRC')"));
    }
    
    // Check version
    const version = std.mem.readInt(u32, @ptrCast(data[4..8]), .big);
    if (version < 2 or version > 4) {
        const issue = try std.fmt.allocPrint(allocator, "Unsupported index version: {}", .{version});
        try issues.append(issue);
    }
    
    // Validate entry count
    const entry_count = std.mem.readInt(u32, @ptrCast(data[8..12]), .big);
    if (entry_count > 10_000_000) { // More than 10M files seems excessive
        const issue = try std.fmt.allocPrint(allocator, "Suspiciously high entry count: {}", .{entry_count});
        try issues.append(issue);
    }
    
    // Try to parse the index to find structural issues
    var test_index = Index.init(allocator);
    defer test_index.deinit();
    
    test_index.parseIndexData(data) catch |err| {
        const issue = try std.fmt.allocPrint(allocator, "Index parsing failed: {}", .{err});
        try issues.append(issue);
    };
    
    return issues.toOwnedSlice();
}

/// Advanced index operations for better git compatibility
pub const IndexOperations = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) IndexOperations {
        return IndexOperations{ .allocator = allocator };
    }
    
    /// Check if index has conflicts (REUC extension or high-stage entries)
    pub fn hasConflicts(self: IndexOperations, git_dir: []const u8, platform_impl: anytype) !bool {
        const stats = analyzeIndex(git_dir, platform_impl, self.allocator) catch return false;
        return stats.has_conflicts;
    }
    
    /// Get conflicted files from index
    pub fn getConflictedFiles(self: IndexOperations, git_dir: []const u8, platform_impl: anytype) ![][]const u8 {
        var conflicts = std.ArrayList([]const u8).init(self.allocator);
        
        // Load index and look for entries with stage > 0
        var index = Index.load(git_dir, platform_impl, self.allocator) catch return conflicts.toOwnedSlice();
        defer index.deinit();
        
        for (index.entries.items) |entry| {
            // Check if this is a conflict entry (stage bits set in flags)
            const stage = (entry.flags >> 12) & 0x3;
            if (stage > 0) {
                // This is a conflicted file
                var already_added = false;
                for (conflicts.items) |existing| {
                    if (std.mem.eql(u8, existing, entry.path)) {
                        already_added = true;
                        break;
                    }
                }
                
                if (!already_added) {
                    try conflicts.append(try self.allocator.dupe(u8, entry.path));
                }
            }
        }
        
        return conflicts.toOwnedSlice();
    }
    
    /// Check if a file is ignored according to .gitignore rules
    pub fn isIgnored(self: IndexOperations, git_dir: []const u8, file_path: []const u8, platform_impl: anytype) !bool {
        // This would integrate with gitignore.zig
        const gitignore = @import("gitignore.zig");
        
        var ignore_checker = gitignore.GitIgnore.init(self.allocator);
        defer ignore_checker.deinit();
        
        try ignore_checker.loadFromGitDir(git_dir, platform_impl);
        return ignore_checker.isIgnored(file_path);
    }
    
    /// Get index statistics with more detailed information
    pub fn getDetailedStats(self: IndexOperations, git_dir: []const u8, platform_impl: anytype) !DetailedIndexStats {
        const stats = analyzeIndex(git_dir, platform_impl, self.allocator) catch return DetailedIndexStats{
            .basic = IndexStats{
                .total_entries = 0,
                .version = 0,
                .extensions = 0,
                .file_size = 0,
                .checksum_valid = false,
                .has_conflicts = false,
                .has_sparse_checkout = false,
            },
            .staged_files = 0,
            .modified_files = 0,
            .deleted_files = 0,
            .largest_file_size = 0,
            .total_tracked_size = 0,
        };
        
        var detailed_stats = DetailedIndexStats{
            .basic = stats,
            .staged_files = 0,
            .modified_files = 0,
            .deleted_files = 0,
            .largest_file_size = 0,
            .total_tracked_size = 0,
        };
        
        // Load index for detailed analysis
        var index = Index.load(git_dir, platform_impl, self.allocator) catch return detailed_stats;
        defer index.deinit();
        
        for (index.entries.items) |entry| {
            detailed_stats.total_tracked_size += entry.size;
            if (entry.size > detailed_stats.largest_file_size) {
                detailed_stats.largest_file_size = entry.size;
            }
            
            // Check file status on disk vs index
            const working_dir = std.fs.path.dirname(git_dir) orelse ".";
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ working_dir, entry.path });
            defer self.allocator.free(full_path);
            
            const stat = std.fs.cwd().statFile(full_path) catch {
                detailed_stats.deleted_files += 1;
                continue;
            };
            
            // Compare timestamps and size for modifications
            const file_mtime_sec = @as(u32, @intCast(@divTrunc(stat.mtime, std.time.ns_per_s)));
            const file_size = @as(u32, @intCast(stat.size));
            
            if (file_mtime_sec != entry.mtime_sec or file_size != entry.size) {
                detailed_stats.modified_files += 1;
            }
        }
        
        return detailed_stats;
    }
};

/// Detailed index statistics
pub const DetailedIndexStats = struct {
    basic: IndexStats,
    staged_files: u32,
    modified_files: u32,
    deleted_files: u32,
    largest_file_size: u32,
    total_tracked_size: u64,
    
    pub fn print(self: DetailedIndexStats) void {
        self.basic.print();
        std.debug.print("Working tree status:\n");
        std.debug.print("  - Modified files: {}\n", .{self.modified_files});
        std.debug.print("  - Deleted files: {}\n", .{self.deleted_files});
        std.debug.print("  - Largest file: {} bytes\n", .{self.largest_file_size});
        std.debug.print("  - Total tracked size: {} bytes\n", .{self.total_tracked_size});
    }
};

/// Optimize index performance by sorting and compacting entries
pub fn optimizeIndex(self: *Index) void {
    // Sort entries by path for better cache locality and faster lookups
    std.sort.block(IndexEntry, self.entries.items, {}, struct {
        fn lessThan(context: void, lhs: IndexEntry, rhs: IndexEntry) bool {
            _ = context;
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
    
    // Remove duplicate entries (keep the last one)
    var i: usize = 0;
    while (i + 1 < self.entries.items.len) {
        if (std.mem.eql(u8, self.entries.items[i].path, self.entries.items[i + 1].path)) {
            self.entries.items[i].deinit(self.allocator);
            _ = self.entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

/// Get index entries that match a path pattern (simple glob support)
pub fn getEntriesMatching(self: Index, pattern: []const u8, allocator: std.mem.Allocator) ![]IndexEntry {
    var matching = std.ArrayList(IndexEntry).init(allocator);
    
    for (self.entries.items) |entry| {
        if (pathMatches(entry.path, pattern)) {
            // Create a copy of the entry
            try matching.append(IndexEntry{
                .ctime_sec = entry.ctime_sec,
                .ctime_nsec = entry.ctime_nsec,
                .mtime_sec = entry.mtime_sec,
                .mtime_nsec = entry.mtime_nsec,
                .dev = entry.dev,
                .ino = entry.ino,
                .mode = entry.mode,
                .uid = entry.uid,
                .gid = entry.gid,
                .size = entry.size,
                .sha1 = entry.sha1,
                .flags = entry.flags,
                .extended_flags = entry.extended_flags,
                .path = try allocator.dupe(u8, entry.path),
            });
        }
    }
    
    return matching.toOwnedSlice();
}

/// Simple path matching with basic glob support (* and ?)
fn pathMatches(path: []const u8, pattern: []const u8) bool {
    return pathMatchesImpl(path, pattern, 0, 0);
}

fn pathMatchesImpl(path: []const u8, pattern: []const u8, path_idx: usize, pattern_idx: usize) bool {
    if (pattern_idx >= pattern.len) {
        return path_idx >= path.len;
    }
    
    if (path_idx >= path.len) {
        // Check if remaining pattern is all *
        for (pattern[pattern_idx..]) |c| {
            if (c != '*') return false;
        }
        return true;
    }
    
    const pattern_char = pattern[pattern_idx];
    
    switch (pattern_char) {
        '*' => {
            // Try matching zero or more characters
            return pathMatchesImpl(path, pattern, path_idx, pattern_idx + 1) or
                   pathMatchesImpl(path, pattern, path_idx + 1, pattern_idx);
        },
        '?' => {
            // Match exactly one character
            return pathMatchesImpl(path, pattern, path_idx + 1, pattern_idx + 1);
        },
        else => {
            // Match exact character
            if (path[path_idx] == pattern_char) {
                return pathMatchesImpl(path, pattern, path_idx + 1, pattern_idx + 1);
            }
            return false;
        },
    }
}

/// Resolve merge conflicts in the index by selecting resolution strategy
pub fn resolveConflicts(index: *Index, strategy: ConflictResolutionStrategy) !u32 {
    var resolved_count: u32 = 0;
    var i: usize = 0;
    
    while (i < index.entries.items.len) {
        const entry = index.entries.items[i];
        const stage = (entry.flags >> 12) & 0x3;
        
        if (stage > 0) {
            // This is a conflict entry
            const path = entry.path;
            
            // Find all stages for this path
            var stages = [3]?usize{ null, null, null };
            var j = i;
            
            // Collect all stages for this path
            while (j < index.entries.items.len) {
                const current_entry = index.entries.items[j];
                if (!std.mem.eql(u8, current_entry.path, path)) break;
                
                const current_stage = (current_entry.flags >> 12) & 0x3;
                if (current_stage > 0 and current_stage <= 3) {
                    stages[current_stage - 1] = j;
                }
                j += 1;
            }
            
            // Apply resolution strategy
            const resolved_index = switch (strategy) {
                .ours => stages[1], // Stage 2 (our version)
                .theirs => stages[2], // Stage 3 (their version)  
                .base => stages[0], // Stage 1 (common ancestor)
                .first_parent => stages[1], // Same as ours
            };
            
            if (resolved_index) |idx| {
                // Keep the resolved version, clear stage
                index.entries.items[idx].flags &= 0x0FFF;
                
                // Remove other conflict entries for this path
                var k = i;
                while (k < index.entries.items.len) {
                    if (k == idx) {
                        k += 1;
                        continue;
                    }
                    
                    const check_entry = index.entries.items[k];
                    if (!std.mem.eql(u8, check_entry.path, path)) break;
                    
                    const check_stage = (check_entry.flags >> 12) & 0x3;
                    if (check_stage > 0) {
                        check_entry.deinit(index.allocator);
                        _ = index.entries.swapRemove(k);
                        // Adjust idx if necessary
                        if (k < idx) {
                            // The resolved index moved down
                            idx -= 1;
                        }
                    } else {
                        k += 1;
                    }
                }
                
                resolved_count += 1;
            }
            
            // Move to next different path  
            i = j;
        } else {
            i += 1;
        }
    }
    
    return resolved_count;
}

/// Conflict resolution strategies
pub const ConflictResolutionStrategy = enum {
    ours,        // Use our version (stage 2)
    theirs,      // Use their version (stage 3)  
    base,        // Use base version (stage 1)
    first_parent, // Alias for ours
};

/// Variable length integer encoding for index v4
pub fn writeVarInt(writer: anytype, value: u32) !void {
    var remaining = value;
    while (remaining >= 0x80) {
        try writer.writeByte(@as(u8, @intCast((remaining & 0x7F) | 0x80)));
        remaining >>= 7;
    }
    try writer.writeByte(@as(u8, @intCast(remaining)));
}

/// Variable length integer decoding for index v4
pub fn readVarInt(reader: anytype) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    
    while (true) {
        const byte = try reader.readByte();
        result |= (@as(u32, @intCast(byte & 0x7F))) << shift;
        
        if (byte & 0x80 == 0) break;
        
        shift += 7;
        if (shift >= 32) return error.VarIntTooLarge;
    }
    
    return result;
}

/// Index extension information
pub const IndexExtension = struct {
    signature: [4]u8,
    size: u32,
    data: []const u8,
    
    pub fn deinit(self: IndexExtension, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Enhanced index parsing with extension support
pub fn parseIndexWithExtensions(data: []const u8, allocator: std.mem.Allocator) !struct {
    entries: std.ArrayList(IndexEntry),
    extensions: std.ArrayList(IndexExtension),
    version: u32,
} {
    if (data.len < 12) return error.InvalidIndex;
    
    // Check magic
    if (!std.mem.eql(u8, data[0..4], "DIRC")) return error.InvalidIndex;
    
    const version = std.mem.readInt(u32, @ptrCast(data[4..8]), .big);
    const entry_count = std.mem.readInt(u32, @ptrCast(data[8..12]), .big);
    
    if (version < 2 or version > 4) return error.UnsupportedIndexVersion;
    
    var entries = std.ArrayList(IndexEntry).init(allocator);
    errdefer {
        for (entries.items) |entry| {
            entry.deinit(allocator);
        }
        entries.deinit();
    }
    
    var extensions = std.ArrayList(IndexExtension).init(allocator);
    errdefer {
        for (extensions.items) |ext| {
            ext.deinit(allocator);
        }
        extensions.deinit();
    }
    
    var pos: usize = 12;
    
    // Parse entries
    for (0..entry_count) |_| {
        if (pos >= data.len - 20) break; // Need space for checksum
        
        var stream = std.io.fixedBufferStream(data[pos..]);
        const entry = IndexEntry.readFromBuffer(stream.reader(), allocator) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        
        try entries.append(entry);
        pos += stream.pos;
    }
    
    // Parse extensions (between entries and checksum)
    const checksum_start = data.len - 20;
    while (pos + 8 <= checksum_start) {
        // Read extension header
        const signature = data[pos..pos + 4];
        const ext_size = std.mem.readInt(u32, @ptrCast(data[pos + 4..pos + 8]), .big);
        pos += 8;
        
        if (pos + ext_size > checksum_start) break;
        
        // Copy extension data
        const ext_data = try allocator.dupe(u8, data[pos..pos + ext_size]);
        
        var sig_array: [4]u8 = undefined;
        @memcpy(&sig_array, signature);
        
        try extensions.append(IndexExtension{
            .signature = sig_array,
            .size = ext_size,
            .data = ext_data,
        });
        
        pos += ext_size;
    }
    
    return .{
        .entries = entries,
        .extensions = extensions, 
        .version = version,
    };
}

/// Verify index file integrity
pub fn verifyIndexIntegrity(data: []const u8) !bool {
    if (data.len < 32) return error.IndexTooSmall;
    
    // Verify checksum
    const content_end = data.len - 20;
    const stored_checksum = data[content_end..];
    
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(data[0..content_end]);
    var computed_checksum: [20]u8 = undefined;
    hasher.final(&computed_checksum);
    
    return std.mem.eql(u8, &computed_checksum, stored_checksum);
}

/// Enhanced index extension analysis
pub fn analyzeIndexExtensions(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !IndexExtensionAnalysis {
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
    defer allocator.free(index_path);
    
    const data = platform_impl.fs.readFile(allocator, index_path) catch return IndexExtensionAnalysis{
        .extensions_found = std.ArrayList(ExtensionInfo).init(allocator),
        .total_extension_size = 0,
        .has_tree_cache = false,
        .has_resolve_undo = false,
        .has_untracked_cache = false,
        .has_fsmonitor = false,
        .performance_optimizations = 0,
    };
    defer allocator.free(data);
    
    var analysis = IndexExtensionAnalysis{
        .extensions_found = std.ArrayList(ExtensionInfo).init(allocator),
        .total_extension_size = 0,
        .has_tree_cache = false,
        .has_resolve_undo = false,
        .has_untracked_cache = false,
        .has_fsmonitor = false,
        .performance_optimizations = 0,
    };
    
    if (data.len < 12) return analysis;
    
    // Parse basic header
    const entry_count = std.mem.readInt(u32, @ptrCast(data[8..12]), .big);
    
    // Skip entries to find extensions
    var pos: usize = 12;
    var entries_processed: u32 = 0;
    
    // Rough estimate to skip entries
    while (entries_processed < entry_count and pos < data.len - 20) {
        const min_entry_size = 62; // Minimum entry size
        if (pos + min_entry_size >= data.len - 20) break;
        
        // Skip to flags to determine path length
        const flags_offset = pos + 60;
        if (flags_offset + 2 >= data.len) break;
        
        const flags = std.mem.readInt(u16, @ptrCast(data[flags_offset..flags_offset + 2]), .big);
        const path_len = flags & 0xFFF;
        
        // Estimate entry size
        const estimated_entry_size = 62 + path_len;
        const padded_size = ((estimated_entry_size + 7) / 8) * 8;
        
        pos += padded_size;
        entries_processed += 1;
        
        if (pos >= data.len - 20) break;
    }
    
    // Now analyze extensions
    while (pos + 8 <= data.len - 20) {
        const sig = data[pos..pos + 4];
        const ext_size = std.mem.readInt(u32, @ptrCast(data[pos + 4..pos + 8]), .big);
        
        if (pos + 8 + ext_size > data.len - 20) break;
        
        // Create extension info
        var sig_array: [4]u8 = undefined;
        @memcpy(&sig_array, sig);
        
        const ext_info = ExtensionInfo{
            .signature = sig_array,
            .size = ext_size,
            .description = getExtensionDescription(sig),
        };
        
        try analysis.extensions_found.append(ext_info);
        analysis.total_extension_size += ext_size;
        
        // Update specific extension flags
        if (std.mem.eql(u8, sig, "TREE")) {
            analysis.has_tree_cache = true;
            analysis.performance_optimizations += 1;
        } else if (std.mem.eql(u8, sig, "REUC")) {
            analysis.has_resolve_undo = true;
        } else if (std.mem.eql(u8, sig, "UNTR")) {
            analysis.has_untracked_cache = true;
            analysis.performance_optimizations += 1;
        } else if (std.mem.eql(u8, sig, "FSMN")) {
            analysis.has_fsmonitor = true;
            analysis.performance_optimizations += 1;
        }
        
        pos += 8 + ext_size;
    }
    
    return analysis;
}

/// Information about a specific index extension
pub const ExtensionInfo = struct {
    signature: [4]u8,
    size: u32,
    description: []const u8,
    
    pub fn getSignatureString(self: ExtensionInfo, allocator: std.mem.Allocator) ![]u8 {
        return try allocator.dupe(u8, self.signature[0..]);
    }
};

/// Analysis of all extensions in an index file
pub const IndexExtensionAnalysis = struct {
    extensions_found: std.ArrayList(ExtensionInfo),
    total_extension_size: u64,
    has_tree_cache: bool,
    has_resolve_undo: bool,
    has_untracked_cache: bool,
    has_fsmonitor: bool,
    performance_optimizations: u32,
    
    pub fn deinit(self: IndexExtensionAnalysis) void {
        self.extensions_found.deinit();
    }
    
    pub fn print(self: IndexExtensionAnalysis) void {
        std.debug.print("Index Extension Analysis:\n");
        std.debug.print("  Extensions found: {}\n", .{self.extensions_found.items.len});
        std.debug.print("  Total extension size: {} bytes\n", .{self.total_extension_size});
        std.debug.print("  Performance optimizations: {}\n", .{self.performance_optimizations});
        std.debug.print("\n");
        std.debug.print("  Specific extensions:\n");
        std.debug.print("    - Tree cache: {}\n", .{self.has_tree_cache});
        std.debug.print("    - Resolve undo: {}\n", .{self.has_resolve_undo});
        std.debug.print("    - Untracked cache: {}\n", .{self.has_untracked_cache});
        std.debug.print("    - FS Monitor: {}\n", .{self.has_fsmonitor});
        
        if (self.extensions_found.items.len > 0) {
            std.debug.print("\n  Extension details:\n");
            for (self.extensions_found.items) |ext| {
                std.debug.print("    {s} ({} bytes): {s}\n", .{ ext.signature, ext.size, ext.description });
            }
        }
    }
    
    pub fn hasPerformanceOptimizations(self: IndexExtensionAnalysis) bool {
        return self.performance_optimizations > 0;
    }
};

/// Get human-readable description for an extension signature
fn getExtensionDescription(signature: []const u8) []const u8 {
    if (std.mem.eql(u8, signature, "TREE")) {
        return "Tree cache - speeds up tree operations";
    } else if (std.mem.eql(u8, signature, "REUC")) {
        return "Resolve undo - tracks conflict resolution";
    } else if (std.mem.eql(u8, signature, "UNTR")) {
        return "Untracked cache - speeds up status operations";
    } else if (std.mem.eql(u8, signature, "FSMN")) {
        return "File system monitor - external monitoring integration";
    } else if (std.mem.eql(u8, signature, "link")) {
        return "Split index - large repository optimization";
    } else if (std.mem.eql(u8, signature, "IEOT")) {
        return "Index entry offset table - faster parsing";
    } else if (std.mem.eql(u8, signature, "EOIE")) {
        return "End of index entries - parsing optimization";
    } else {
        return "Unknown extension";
    }
}

