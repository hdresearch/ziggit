const std = @import("std");
const objects = @import("objects.zig");

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
            .dev = 0, // TODO: get actual device ID
            .ino = @intCast(stat.inode),
            .mode = @intCast(stat.mode),
            .uid = 0, // TODO: get actual UID
            .gid = 0, // TODO: get actual GID
            .size = @intCast(stat.size),
            .sha1 = sha1,
            .flags = @intCast(path.len),
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
        const pad_len = (8 - (total_len % 8)) % 8;
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
        const pad_len = (8 - (total_len % 8)) % 8;
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

    pub fn init(allocator: std.mem.Allocator) Index {
        return Index{
            .entries = std.ArrayList(IndexEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn load(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !Index {
        const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
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
        
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        // Read header
        var signature: [4]u8 = undefined;
        _ = try reader.readAll(&signature);
        if (!std.mem.eql(u8, &signature, "DIRC")) return error.InvalidIndex;

        const version = try reader.readInt(u32, .big);
        if (version < 2 or version > 4) return error.UnsupportedIndexVersion;

        const entry_count = try reader.readInt(u32, .big);

        // Read entries
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            const entry = try self.readIndexEntry(reader, version);
            try self.entries.append(entry);
        }

        // Handle extensions (read and skip them)
        try self.readExtensions(reader, data);

        // Verify SHA-1 checksum
        try self.verifyChecksum(data);
    }

    /// Read a single index entry with version-specific handling
    fn readIndexEntry(self: *Index, reader: anytype, version: u32) !IndexEntry {
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
        const path_len = flags & 0xFFF;
        if (version >= 4) {
            // In v4, if path length is 0xFFF, path length is stored separately
            if (path_len == 0xFFF) {
                // For now, treat this as an error since we don't fully support v4 variable-length paths
                return error.UnsupportedIndexVersion;
            }
        }
        
        const path_bytes = try self.allocator.alloc(u8, path_len);
        _ = try reader.readAll(path_bytes);
        
        // Calculate and skip padding
        const entry_size = 62 + (if (version >= 3 and (flags & 0x4000) != 0) @as(usize, 2) else @as(usize, 0)) + path_len;
        const pad_len = (8 - (entry_size % 8)) % 8;
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

    /// Read and skip index extensions
    fn readExtensions(self: *Index, reader: anytype, data: []const u8) !void {
        _ = self; // Not used currently
        
        while (true) {
            // Check if we have enough bytes left for checksum (20 bytes)
            const current_pos = try reader.context.getPos();
            if (current_pos + 20 >= data.len) break;
            
            // Try to read extension signature
            var sig: [4]u8 = undefined;
            _ = reader.readAll(&sig) catch break; // EOF or not enough data
            
            // Check if this is actually the start of the SHA-1 checksum
            // Extensions have printable ASCII signatures, checksum starts with hash bytes
            if (sig[0] < 32 or sig[0] > 126) {
                // Likely the start of checksum, rewind
                try reader.context.seekTo(current_pos);
                break;
            }
            
            // Read extension size
            const ext_size = reader.readInt(u32, .big) catch {
                // Rewind if we can't read size
                try reader.context.seekTo(current_pos);
                break;
            };
            
            // Skip extension data
            reader.skipBytes(ext_size, .{}) catch {
                // If we can't skip the extension, we're probably at the checksum
                try reader.context.seekTo(current_pos);
                break;
            };
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
            return error.ChecksumMismatch;
        }
    }

    pub fn save(self: Index, git_dir: []const u8, platform_impl: anytype) !void {
        const index_path = try std.fmt.allocPrint(self.allocator, "{s}/index", .{git_dir});
        defer self.allocator.free(index_path);

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        const writer = buffer.writer();

        // Write header
        try writer.writeAll("DIRC");
        try writer.writeInt(u32, 2, .big); // Version 2
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
        // Read file content
        const content = try platform_impl.fs.readFile(self.allocator, file_path);
        defer self.allocator.free(content);

        // Create blob object and store it
        const blob = try objects.createBlobObject(content, self.allocator);
        defer blob.deinit(self.allocator);
        const hash_str = try blob.store(git_dir, platform_impl, self.allocator);
        defer self.allocator.free(hash_str);

        var hash_bytes: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash_bytes, hash_str);

        // Create a simple stat structure (we don't have real stat info from platform abstraction)
        const fake_stat = std.fs.File.Stat{
            .inode = 0,
            .size = content.len,
            .mode = 33188, // 100644 in octal
            .kind = .file,
            .atime = 0,
            .mtime = 0,
            .ctime = 0,
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