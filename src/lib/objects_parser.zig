const zlib_compat = @import("../git/zlib_compat.zig");
const std = @import("std");
const zlib = zlib_compat;

pub const GitObjectType = enum {
    commit,
    tree,
    blob,
    tag,
    
    pub fn fromString(s: []const u8) ?GitObjectType {
        if (std.mem.eql(u8, s, "commit")) return .commit;
        if (std.mem.eql(u8, s, "tree")) return .tree;
        if (std.mem.eql(u8, s, "blob")) return .blob;
        if (std.mem.eql(u8, s, "tag")) return .tag;
        return null;
    }
    
    pub fn toString(self: GitObjectType) []const u8 {
        return switch (self) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        };
    }
};

pub const GitObject = struct {
    type: GitObjectType,
    size: usize,
    content: []u8,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *GitObject) void {
        self.allocator.free(self.content);
    }
};

pub const TreeEntry = struct {
    mode: u32,
    name: []const u8,
    sha1: [20]u8,
};

pub const CommitInfo = struct {
    tree_sha: [20]u8,
    parent_shas: [][20]u8,
    author: []const u8,
    committer: []const u8,
    message: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *CommitInfo) void {
        self.allocator.free(self.parent_shas);
        self.allocator.free(self.author);
        self.allocator.free(self.committer);
        self.allocator.free(self.message);
    }
};

pub fn readObject(allocator: std.mem.Allocator, objects_dir: []const u8, sha_hex: []const u8) !GitObject {
    if (sha_hex.len < 40) return error.InvalidSha;
    
    // Convert hex to directory/filename format
    const dir_name = sha_hex[0..2];
    const file_name = sha_hex[2..];
    
    const object_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ objects_dir, dir_name, file_name });
    defer allocator.free(object_path);
    
    // Try to read the file
    const file = std.fs.openFileAbsolute(object_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ObjectNotFound,
        else => return err,
    };
    defer file.close();
    
    // Read compressed content
    const compressed_content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(compressed_content);
    
    // Decompress using zlib
    var buffer_stream = std.io.fixedBufferStream(compressed_content);
    var decompressor = zlib.decompressor(buffer_stream.reader());
    
    const decompressed = try decompressor.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(decompressed);
    
    // Parse object header (type size\0content)
    const null_pos = std.mem.indexOf(u8, decompressed, "\x00") orelse return error.InvalidObjectFormat;
    const header = decompressed[0..null_pos];
    const content = decompressed[null_pos + 1 ..];
    
    // Parse type and size from header
    const space_pos = std.mem.indexOf(u8, header, " ") orelse return error.InvalidObjectFormat;
    const type_str = header[0..space_pos];
    const size_str = header[space_pos + 1 ..];
    
    const object_type = GitObjectType.fromString(type_str) orelse return error.UnknownObjectType;
    const object_size = try std.fmt.parseInt(usize, size_str, 10);
    
    if (content.len != object_size) return error.ObjectSizeMismatch;
    
    const content_copy = try allocator.dupe(u8, content);
    
    return GitObject{
        .type = object_type,
        .size = object_size,
        .content = content_copy,
        .allocator = allocator,
    };
}

pub fn parseCommit(allocator: std.mem.Allocator, commit_content: []const u8) !CommitInfo {
    var tree_sha: [20]u8 = undefined;
    var parents = std.ArrayList([20]u8).init(allocator);
    errdefer parents.deinit();
    
    var author: []const u8 = "";
    var committer: []const u8 = "";
    _ = "";
    
    var lines = std.mem.splitSequence(u8, commit_content, "\n");
    var message_started = false;
    var message_lines = std.ArrayList([]const u8).init(allocator);
    defer message_lines.deinit();
    
    while (lines.next()) |line| {
        if (message_started) {
            try message_lines.append(line);
            continue;
        }
        
        if (line.len == 0) {
            message_started = true;
            continue;
        }
        
        if (std.mem.startsWith(u8, line, "tree ")) {
            const sha_hex = line[5..];
            if (sha_hex.len != 40) return error.InvalidTreeSha;
            hexToBytes(sha_hex, &tree_sha);
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            const sha_hex = line[7..];
            if (sha_hex.len != 40) return error.InvalidParentSha;
            var parent_sha: [20]u8 = undefined;
            hexToBytes(sha_hex, &parent_sha);
            try parents.append(parent_sha);
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author = line[7..];
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            committer = line[10..];
        }
    }
    
    // Join message lines
    const message_content = try std.mem.join(allocator, "\n", message_lines.items);
    
    return CommitInfo{
        .tree_sha = tree_sha,
        .parent_shas = try parents.toOwnedSlice(),
        .author = try allocator.dupe(u8, author),
        .committer = try allocator.dupe(u8, committer),
        .message = message_content,
        .allocator = allocator,
    };
}

pub fn parseTree(tree_content: []const u8, entries: *std.ArrayList(TreeEntry)) !void {
    var pos: usize = 0;
    
    while (pos < tree_content.len) {
        // Find space separator between mode and name
        const space_pos = std.mem.indexOfScalarPos(u8, tree_content, pos, ' ') orelse return error.InvalidTreeEntry;
        
        // Parse mode
        const mode_str = tree_content[pos..space_pos];
        const mode = try std.fmt.parseInt(u32, mode_str, 8); // Octal mode
        
        pos = space_pos + 1;
        
        // Find null separator between name and SHA
        const null_pos = std.mem.indexOfScalarPos(u8, tree_content, pos, 0) orelse return error.InvalidTreeEntry;
        
        const name = tree_content[pos..null_pos];
        pos = null_pos + 1;
        
        // Read 20-byte SHA
        if (pos + 20 > tree_content.len) return error.InvalidTreeEntry;
        var sha1: [20]u8 = undefined;
        @memcpy(&sha1, tree_content[pos..pos + 20]);
        pos += 20;
        
        try entries.append(TreeEntry{
            .mode = mode,
            .name = name,
            .sha1 = sha1,
        });
    }
}

pub fn shaToHex(sha: []const u8, hex_buf: []u8) void {
    const chars = "0123456789abcdef";
    for (sha, 0..) |byte, i| {
        hex_buf[i * 2] = chars[byte >> 4];
        hex_buf[i * 2 + 1] = chars[byte & 0xF];
    }
}

pub fn hexToBytes(hex: []const u8, bytes: []u8) void {
    for (0..bytes.len) |i| {
        const hex_byte = hex[i * 2..i * 2 + 2];
        bytes[i] = std.fmt.parseInt(u8, hex_byte, 16) catch 0;
    }
}

pub fn isValidHex(hex: []const u8) bool {
    for (hex) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}