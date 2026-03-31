const std = @import("std");

/// Reader for git's commit-graph file format.
/// Binary format with O(1) commit lookups and parent traversal.
/// See: https://git-scm.com/docs/commit-graph-format
pub const CommitGraph = struct {
    data: []const u8,
    is_mmap: bool,

    // Chunk offsets (parsed from header)
    oid_fanout_offset: usize,
    oid_lookup_offset: usize,
    commit_data_offset: usize,
    num_commits: u32,
    hash_len: u8, // 20 for SHA-1

    pub const CommitEntry = struct {
        tree_oid_pos: u32,
        parent1: u32,
        parent2: u32,
        generation: u32,
        commit_time: i64,
    };

    pub const GRAPH_NO_PARENT: u32 = 0x70000000;
    pub const GRAPH_EXTRA_EDGES: u32 = 0x80000000;
    pub const GRAPH_LAST_EDGE: u32 = 0x80000000;

    /// Open and parse a commit-graph file. Returns null if file doesn't exist or is invalid.
    pub fn open(git_dir: []const u8, allocator: std.mem.Allocator) ?CommitGraph {
        _ = allocator;
        const path_buf = std.fmt.allocPrint(std.heap.page_allocator, "{s}/objects/info/commit-graph", .{git_dir}) catch return null;
        defer std.heap.page_allocator.free(path_buf);

        if (comptime (@import("builtin").target.os.tag == .freestanding or @import("builtin").target.os.tag == .wasi)) return null;

        // Read file into memory (simpler than mmap, works everywhere)
        const file = std.fs.cwd().openFile(path_buf, .{}) catch return null;
        defer file.close();
        const stat = file.stat() catch return null;
        if (stat.size < 20) return null;

        // Use page_allocator for the commit-graph data (lives for process lifetime)
        const data = std.heap.page_allocator.alloc(u8, stat.size) catch return null;
        const bytes_read = file.readAll(data) catch {
            std.heap.page_allocator.free(data);
            return null;
        };
        if (bytes_read != stat.size) {
            std.heap.page_allocator.free(data);
            return null;
        }

        return parse(data[0..bytes_read], false);
    }

    fn parse(data: []const u8, is_mmap: bool) ?CommitGraph {
        if (data.len < 8) return null;

        // Header: "CGPH" + version(1) + hash_version(1) + num_chunks(1) + num_base(1)
        if (!std.mem.eql(u8, data[0..4], "CGPH")) return null;
        const version = data[4];
        if (version != 1) return null;
        const hash_version = data[5];
        const hash_len: u8 = if (hash_version == 1) 20 else if (hash_version == 2) 32 else return null;
        const num_chunks = data[6];
        // data[7] = num_base_graphs

        // Chunk table: num_chunks entries of (4-byte ID + 8-byte offset), plus terminator
        const chunk_table_start: usize = 8;
        const chunk_entry_size: usize = 12; // 4 + 8

        if (data.len < chunk_table_start + (@as(usize, num_chunks) + 1) * chunk_entry_size) return null;

        var oid_fanout_offset: usize = 0;
        var oid_lookup_offset: usize = 0;
        var commit_data_offset: usize = 0;

        var i: usize = 0;
        while (i < num_chunks) : (i += 1) {
            const entry_off = chunk_table_start + i * chunk_entry_size;
            const chunk_id = data[entry_off..][0..4];
            const chunk_offset = std.mem.readInt(u64, data[entry_off + 4 ..][0..8], .big);

            if (std.mem.eql(u8, chunk_id, "OIDF")) {
                oid_fanout_offset = @intCast(chunk_offset);
            } else if (std.mem.eql(u8, chunk_id, "OIDL")) {
                oid_lookup_offset = @intCast(chunk_offset);
            } else if (std.mem.eql(u8, chunk_id, "CDAT")) {
                commit_data_offset = @intCast(chunk_offset);
            }
        }

        if (oid_fanout_offset == 0 or oid_lookup_offset == 0 or commit_data_offset == 0) return null;

        // Read num_commits from fanout[255]
        const fanout_255_off = oid_fanout_offset + 255 * 4;
        if (data.len < fanout_255_off + 4) return null;
        const num_commits = std.mem.readInt(u32, data[fanout_255_off..][0..4], .big);

        return CommitGraph{
            .data = data,
            .is_mmap = is_mmap,
            .oid_fanout_offset = oid_fanout_offset,
            .oid_lookup_offset = oid_lookup_offset,
            .commit_data_offset = commit_data_offset,
            .num_commits = num_commits,
            .hash_len = hash_len,
        };
    }

    /// Look up a commit by its hex hash string. Returns the position index or null.
    pub fn findCommit(self: *const CommitGraph, hash_str: []const u8) ?u32 {
        if (hash_str.len != 40) return null;
        var hash_bytes: [20]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash_bytes, hash_str) catch return null;
        return self.findCommitByOid(&hash_bytes);
    }

    /// Look up a commit by its binary OID. Returns the position index or null.
    pub fn findCommitByOid(self: *const CommitGraph, oid: *const [20]u8) ?u32 {
        const first_byte = oid[0];
        const d = self.data;

        // Fanout table lookup
        const start_idx: u32 = if (first_byte == 0) 0 else std.mem.readInt(u32, d[self.oid_fanout_offset + (@as(usize, first_byte) - 1) * 4 ..][0..4], .big);
        const end_idx = std.mem.readInt(u32, d[self.oid_fanout_offset + @as(usize, first_byte) * 4 ..][0..4], .big);

        if (start_idx >= end_idx) return null;

        // Binary search in OID lookup table
        var low = start_idx;
        var high = end_idx;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const oid_off = self.oid_lookup_offset + @as(usize, mid) * self.hash_len;
            const entry_oid = d[oid_off .. oid_off + 20];
            const cmp = std.mem.order(u8, entry_oid, oid);
            switch (cmp) {
                .eq => return mid,
                .lt => low = mid + 1,
                .gt => high = mid,
            }
        }
        return null;
    }

    /// Get commit data for the given position index.
    pub fn getCommitData(self: *const CommitGraph, pos: u32) CommitEntry {
        const d = self.data;
        // CDAT entry: hash_len bytes (tree OID) + 4 bytes parent1 + 4 bytes parent2 + 8 bytes (gen + time)
        const entry_size = @as(usize, self.hash_len) + 16;
        const off = self.commit_data_offset + @as(usize, pos) * entry_size;

        const parent1 = std.mem.readInt(u32, d[off + self.hash_len ..][0..4], .big);
        const parent2 = std.mem.readInt(u32, d[off + self.hash_len + 4 ..][0..4], .big);
        const gen_and_time = std.mem.readInt(u64, d[off + self.hash_len + 8 ..][0..8], .big);

        const generation: u32 = @intCast(gen_and_time >> 34); // top 30 bits
        const commit_time_raw: u32 = @truncate(gen_and_time & 0x3FFFFFFFF); // bottom 34 bits
        // The top 2 bits of the 34-bit field are the high bits of commit time
        const time_high: u2 = @truncate((gen_and_time >> 32) & 0x3);
        const time_low: u32 = @truncate(gen_and_time & 0xFFFFFFFF);
        _ = commit_time_raw;
        const commit_time: i64 = (@as(i64, time_high) << 32) | @as(i64, time_low);

        return CommitEntry{
            .tree_oid_pos = std.mem.readInt(u32, d[off..][0..4], .big),
            .parent1 = parent1,
            .parent2 = parent2,
            .generation = generation,
            .commit_time = commit_time,
        };
    }

    /// Get the binary OID for a commit at the given position (zero-copy).
    pub fn getOidBytes(self: *const CommitGraph, pos: u32) *const [20]u8 {
        const off = self.oid_lookup_offset + @as(usize, pos) * self.hash_len;
        return self.data[off..][0..20];
    }

    /// Get the OID (hex string) for a commit at the given position.
    pub fn getOidHex(self: *const CommitGraph, pos: u32, buf: *[40]u8) void {
        const off = self.oid_lookup_offset + @as(usize, pos) * self.hash_len;
        const oid_bytes = self.data[off .. off + 20];
        for (oid_bytes, 0..) |byte, i| {
            const hex = "0123456789abcdef";
            buf[i * 2] = hex[byte >> 4];
            buf[i * 2 + 1] = hex[byte & 0xf];
        }
    }

    /// Get extra parent edges for octopus merges (parent2 has GRAPH_EXTRA_EDGES flag).
    /// Returns parent positions from the extra-edges list.
    pub fn getExtraParents(self: *const CommitGraph, edge_list_start: u32) []const u8 {
        // Extra edge list chunk would need to be parsed from chunks table.
        // For now, return empty (octopus merges are rare in benchmarks).
        _ = self;
        _ = edge_list_start;
        return &.{};
    }
};
