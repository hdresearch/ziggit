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
    hash: [20]u8,
    flags: u16,
    path: []const u8,

    pub fn init(path: []const u8, stat: std.fs.File.Stat, hash: [20]u8) IndexEntry {
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
            .hash = hash,
            .flags = @intCast(path.len),
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
        try writer.writeAll(&self.hash);
        try writer.writeInt(u16, self.flags, .big);
        try writer.writeAll(self.path);
        
        // Pad to multiple of 8 bytes
        const total_len = 62 + self.path.len;
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
        
        var hash: [20]u8 = undefined;
        _ = try reader.readAll(&hash);
        
        const flags = try reader.readInt(u16, .big);
        const path_len = flags & 0xFFF;
        
        const path_bytes = try allocator.alloc(u8, path_len);
        _ = try reader.readAll(path_bytes);
        
        // Skip padding
        const total_len = 62 + path_len;
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
            .hash = hash,
            .flags = flags,
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

    pub fn load(git_dir: []const u8, allocator: std.mem.Allocator) !Index {
        const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
        defer allocator.free(index_path);

        var index = Index.init(allocator);
        
        const file = std.fs.openFileAbsolute(index_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return index, // Empty index if file doesn't exist
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB limit
        defer allocator.free(data);

        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        // Read header
        var signature: [4]u8 = undefined;
        _ = try reader.readAll(&signature);
        if (!std.mem.eql(u8, &signature, "DIRC")) return error.InvalidIndex;

        const version = try reader.readInt(u32, .big);
        if (version != 2) return error.UnsupportedIndexVersion;

        const entry_count = try reader.readInt(u32, .big);

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            const entry = try IndexEntry.readFromBuffer(reader, allocator);
            try index.entries.append(entry);
        }

        return index;
    }

    pub fn save(self: Index, git_dir: []const u8) !void {
        const index_path = try std.fmt.allocPrint(self.allocator, "{s}/index", .{git_dir});
        defer self.allocator.free(index_path);

        const file = try std.fs.createFileAbsolute(index_path, .{ .truncate = true });
        defer file.close();

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

        try file.writeAll(buffer.items);
    }

    pub fn add(self: *Index, path: []const u8, file_path: []const u8) !void {
        // Read file content
        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();
        
        const stat = try file.stat();
        const content = try file.readToEndAlloc(self.allocator, stat.size);
        defer self.allocator.free(content);

        // Create blob object and get hash
        const blob = objects.createBlobObject(content);
        const hash_str = try blob.hash(self.allocator);
        defer self.allocator.free(hash_str);

        var hash_bytes: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash_bytes, hash_str);

        // Find existing entry or add new one
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.path, path)) {
                // Update existing entry
                entry.deinit(self.allocator);
                self.entries.items[i] = IndexEntry.init(try self.allocator.dupe(u8, path), stat, hash_bytes);
                return;
            }
        }

        // Add new entry
        const entry = IndexEntry.init(try self.allocator.dupe(u8, path), stat, hash_bytes);
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
};