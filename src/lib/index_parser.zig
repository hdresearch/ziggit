const std = @import("std");

pub const IndexEntry = struct {
    ctime_seconds: u32,
    ctime_nanoseconds: u32,
    mtime_seconds: u32,
    mtime_nanoseconds: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u32,
    sha1: [20]u8,
    flags: u16,
    path: []u8,
    
    pub fn deinit(self: *IndexEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const GitIndex = struct {
    entries: std.array_list.Managed(IndexEntry),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) GitIndex {
        return GitIndex{
            .entries = std.array_list.Managed(IndexEntry).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *GitIndex) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }
    
    pub fn readFromFile(allocator: std.mem.Allocator, index_path: []const u8) !GitIndex {
        const file = try std.fs.openFileAbsolute(index_path, .{});
        defer file.close();
        
        const file_size = try file.getEndPos();
        const content = try allocator.alloc(u8, file_size);
        defer allocator.free(content);
        _ = try file.readAll(content);
        
        return parseIndex(allocator, content);
    }
    
    pub fn parseIndex(allocator: std.mem.Allocator, data: []const u8) !GitIndex {
        if (data.len < 12) return error.InvalidIndex;
        
        // Check signature "DIRC"
        if (!std.mem.eql(u8, data[0..4], "DIRC")) {
            return error.InvalidIndexSignature;
        }
        
        // Read version (big endian)
        const version = std.mem.readInt(u32, data[4..8][0..4], .big);
        if (version != 2 and version != 3 and version != 4) {
            return error.UnsupportedIndexVersion;
        }
        
        // Read number of entries (big endian)
        const num_entries = std.mem.readInt(u32, data[8..12][0..4], .big);
        
        var index = GitIndex.init(allocator);
        errdefer index.deinit();
        
        var pos: usize = 12;
        
        for (0..num_entries) |_| {
            const entry = try parseIndexEntry(allocator, data, &pos);
            try index.entries.append(entry);
        }
        
        return index;
    }
    
    pub fn findEntry(self: *const GitIndex, path: []const u8) ?*const IndexEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                return entry;
            }
        }
        return null;
    }
    
    pub fn writeToFile(self: *const GitIndex, index_path: []const u8) !void {
        const file = try std.fs.createFileAbsolute(index_path, .{ .truncate = true });
        defer file.close();
        
        // Use buffered writer to batch small writes into large syscalls
        var bw = std.io.bufferedWriter(file.writer());
        const writer = bw.writer();
        
        try writer.writeAll("DIRC");
        try writer.writeInt(u32, 2, .big); // version
        try writer.writeInt(u32, @intCast(self.entries.items.len), .big);
        
        for (self.entries.items) |entry| {
            try writeIndexEntryBuffered(writer, entry);
        }
        
        const dummy_hash = [_]u8{0} ** 20;
        try writer.writeAll(&dummy_hash);
        try bw.flush();
    }
};

fn writeIndexEntry(file: std.fs.File, entry: IndexEntry) !void {
    try writeU32BigEndian(file, entry.ctime_seconds);
    try writeU32BigEndian(file, entry.ctime_nanoseconds);
    try writeU32BigEndian(file, entry.mtime_seconds);
    try writeU32BigEndian(file, entry.mtime_nanoseconds);
    try writeU32BigEndian(file, entry.dev);
    try writeU32BigEndian(file, entry.ino);
    try writeU32BigEndian(file, entry.mode);
    try writeU32BigEndian(file, entry.uid);
    try writeU32BigEndian(file, entry.gid);
    try writeU32BigEndian(file, entry.size);
    try file.writeAll(&entry.sha1);
    try writeU16BigEndian(file, entry.flags);
    try file.writeAll(entry.path);
    // Write null terminator to match what the parser expects
    const null_terminator = [_]u8{0};
    try file.writeAll(&null_terminator);
    const entry_size = 62 + entry.path.len + 1; // +1 for null terminator
    const padding_needed = (8 - (entry_size % 8)) % 8;
    if (padding_needed > 0) {
        const padding = [_]u8{0} ** 8;
        try file.writeAll(padding[0..padding_needed]);
    }
}

/// Write index entry using buffered writer (avoids per-field syscalls)
fn writeIndexEntryBuffered(writer: anytype, entry: IndexEntry) !void {
    // Write all fixed-size fields in a single batch
    var buf: [62]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], entry.ctime_seconds, .big);
    std.mem.writeInt(u32, buf[4..8], entry.ctime_nanoseconds, .big);
    std.mem.writeInt(u32, buf[8..12], entry.mtime_seconds, .big);
    std.mem.writeInt(u32, buf[12..16], entry.mtime_nanoseconds, .big);
    std.mem.writeInt(u32, buf[16..20], entry.dev, .big);
    std.mem.writeInt(u32, buf[20..24], entry.ino, .big);
    std.mem.writeInt(u32, buf[24..28], entry.mode, .big);
    std.mem.writeInt(u32, buf[28..32], entry.uid, .big);
    std.mem.writeInt(u32, buf[32..36], entry.gid, .big);
    std.mem.writeInt(u32, buf[36..40], entry.size, .big);
    @memcpy(buf[40..60], &entry.sha1);
    std.mem.writeInt(u16, buf[60..62], entry.flags, .big);
    try writer.writeAll(&buf);
    try writer.writeAll(entry.path);
    // Null terminator + padding
    const entry_size = 62 + entry.path.len + 1;
    const padding_needed = (8 - (entry_size % 8)) % 8;
    const zeros = [_]u8{0} ** 8;
    try writer.writeAll(zeros[0 .. 1 + padding_needed]); // 1 for null + padding
}

fn writeU32BigEndian(file: std.fs.File, value: u32) !void {
    const bytes = [_]u8{
        @intCast((value >> 24) & 0xFF),
        @intCast((value >> 16) & 0xFF),
        @intCast((value >> 8) & 0xFF),
        @intCast(value & 0xFF),
    };
    try file.writeAll(&bytes);
}

fn writeU16BigEndian(file: std.fs.File, value: u16) !void {
    const bytes = [_]u8{
        @intCast((value >> 8) & 0xFF),
        @intCast(value & 0xFF),
    };
    try file.writeAll(&bytes);
}

fn parseIndexEntry(allocator: std.mem.Allocator, data: []const u8, pos: *usize) !IndexEntry {
    if (data.len < pos.* + 62) return error.InvalidIndexEntry;
    
    const entry_start = pos.*;
    
    // Read fixed-size fields (all big endian)
    const ctime_seconds = std.mem.readInt(u32, data[entry_start + 0..entry_start + 4][0..4], .big);
    const ctime_nanoseconds = std.mem.readInt(u32, data[entry_start + 4..entry_start + 8][0..4], .big);
    const mtime_seconds = std.mem.readInt(u32, data[entry_start + 8..entry_start + 12][0..4], .big);
    const mtime_nanoseconds = std.mem.readInt(u32, data[entry_start + 12..entry_start + 16][0..4], .big);
    const dev = std.mem.readInt(u32, data[entry_start + 16..entry_start + 20][0..4], .big);
    const ino = std.mem.readInt(u32, data[entry_start + 20..entry_start + 24][0..4], .big);
    const mode = std.mem.readInt(u32, data[entry_start + 24..entry_start + 28][0..4], .big);
    const uid = std.mem.readInt(u32, data[entry_start + 28..entry_start + 32][0..4], .big);
    const gid = std.mem.readInt(u32, data[entry_start + 32..entry_start + 36][0..4], .big);
    const size = std.mem.readInt(u32, data[entry_start + 36..entry_start + 40][0..4], .big);
    
    // Read SHA-1 hash (20 bytes)
    var sha1: [20]u8 = undefined;
    @memcpy(&sha1, data[entry_start + 40..entry_start + 60]);
    
    // Read flags (16-bit big endian)
    const flags = std.mem.readInt(u16, data[entry_start + 60..entry_start + 62][0..2], .big);
    const path_length = flags & 0x0FFF; // Lower 12 bits contain path length
    
    pos.* = entry_start + 62;
    
    // Read path
    const path_end = pos.* + path_length;
    if (data.len < path_end) return error.InvalidIndexEntry;
    
    const path = try allocator.dupe(u8, data[pos.*..path_end]);
    pos.* = path_end;
    
    // Handle null terminator if present
    if (pos.* < data.len and data[pos.*] == 0) {
        pos.* += 1;
    }
    
    // Align to 8-byte boundary
    const padding = (8 - ((62 + path_length + 1) % 8)) % 8;
    pos.* += padding;
    
    return IndexEntry{
        .ctime_seconds = ctime_seconds,
        .ctime_nanoseconds = ctime_nanoseconds,
        .mtime_seconds = mtime_seconds,
        .mtime_nanoseconds = mtime_nanoseconds,
        .dev = dev,
        .ino = ino,
        .mode = mode,
        .uid = uid,
        .gid = gid,
        .size = size,
        .sha1 = sha1,
        .flags = flags,
        .path = path,
    };
}