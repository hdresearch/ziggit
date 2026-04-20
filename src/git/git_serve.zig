const std = @import("std");
const objects = @import("objects.zig");

/// A ref entry for advertisement.
const RefEntry = struct {
    name: []const u8,
    hash: []const u8,
};

/// Pkt-line format utilities for the git protocol.
pub const PktLine = struct {
    /// Format a pkt-line: 4 hex-digit length prefix + payload.
    /// Length includes the 4-byte prefix itself.
    pub fn format(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
        const total_len = payload.len + 4;
        if (total_len > 65535) return error.Overflow;
        var buf = try allocator.alloc(u8, total_len);
        _ = std.fmt.bufPrint(buf[0..4], "{x:0>4}", .{total_len}) catch unreachable;
        @memcpy(buf[4..], payload);
        return buf;
    }

    /// Return the flush packet "0000".
    pub fn flush() []const u8 {
        return "0000";
    }

    /// Write a pkt-line to a byte buffer.
    pub fn appendTo(list: *std.array_list.Managed(u8), payload: []const u8) !void {
        const total_len = payload.len + 4;
        if (total_len > 65535) return error.Overflow;
        var len_buf: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&len_buf, "{x:0>4}", .{total_len}) catch unreachable;
        try list.appendSlice(&len_buf);
        try list.appendSlice(payload);
    }

    /// Append a flush packet.
    pub fn appendFlush(list: *std.array_list.Managed(u8)) !void {
        try list.appendSlice("0000");
    }

    /// Read a pkt-line from raw bytes at given offset. Returns payload and new offset.
    /// Returns null for flush packet.
    pub fn readFrom(data: []const u8, offset: usize) ?struct { payload: []const u8, next: usize } {
        if (offset + 4 > data.len) return null;
        const len_bytes = data[offset .. offset + 4];
        if (std.mem.eql(u8, len_bytes, "0000")) {
            return .{ .payload = &.{}, .next = offset + 4 };
        }
        const pkt_len = std.fmt.parseInt(u16, len_bytes, 16) catch return null;
        if (pkt_len < 4) return null;
        const data_len = pkt_len - 4;
        if (offset + 4 + data_len > data.len) return null;
        return .{
            .payload = data[offset + 4 .. offset + 4 + data_len],
            .next = offset + 4 + data_len,
        };
    }

    /// Parse a pkt-line from a reader (reads exactly one pkt-line).
    /// Returns null for flush packet. Caller owns returned memory.
    pub fn readFromStream(allocator: std.mem.Allocator, stream: std.net.Stream) !?[]u8 {
        var len_buf: [4]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < 4) {
            const n = stream.read(len_buf[total_read..]) catch return null;
            if (n == 0) return null;
            total_read += n;
        }

        if (std.mem.eql(u8, &len_buf, "0000")) return null;

        const pkt_len = std.fmt.parseInt(u16, &len_buf, 16) catch return null;
        if (pkt_len < 4) return null;
        const data_len = pkt_len - 4;
        if (data_len == 0) return try allocator.alloc(u8, 0);

        const buf = try allocator.alloc(u8, data_len);
        errdefer allocator.free(buf);
        var read_count: usize = 0;
        while (read_count < data_len) {
            const n = stream.read(buf[read_count..]) catch {
                allocator.free(buf);
                return null;
            };
            if (n == 0) {
                allocator.free(buf);
                return null;
            }
            read_count += n;
        }
        return buf;
    }

    /// Write a pkt-line to a stream.
    pub fn writeToStream(stream: std.net.Stream, payload: []const u8) !void {
        const total_len = payload.len + 4;
        if (total_len > 65535) return error.Overflow;
        var len_buf: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&len_buf, "{x:0>4}", .{total_len}) catch unreachable;
        try stream.writeAll(&len_buf);
        try stream.writeAll(payload);
    }

    /// Write a flush to a stream.
    pub fn writeFlushToStream(stream: std.net.Stream) !void {
        try stream.writeAll("0000");
    }
};

/// Side-band channel IDs per git protocol spec.
pub const SideBand = struct {
    pub const PACK_DATA: u8 = 1;
    pub const PROGRESS: u8 = 2;
    pub const ERROR: u8 = 3;

    /// Write a side-band-64k packet to a stream.
    pub fn writeToStream(stream: std.net.Stream, channel: u8, data: []const u8) !void {
        const max_chunk = 65515;
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk_len = @min(data.len - offset, max_chunk);
            const total_len = chunk_len + 4 + 1;
            var len_buf: [4]u8 = undefined;
            _ = std.fmt.bufPrint(&len_buf, "{x:0>4}", .{total_len}) catch unreachable;
            try stream.writeAll(&len_buf);
            try stream.writeAll(&[_]u8{channel});
            try stream.writeAll(data[offset .. offset + chunk_len]);
            offset += chunk_len;
        }
    }

    /// Write a side-band-64k packet to a buffer.
    pub fn appendTo(list: *std.array_list.Managed(u8), channel: u8, data: []const u8) !void {
        const max_chunk = 65515;
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk_len = @min(data.len - offset, max_chunk);
            const total_len = chunk_len + 4 + 1;
            var len_buf: [4]u8 = undefined;
            _ = std.fmt.bufPrint(&len_buf, "{x:0>4}", .{total_len}) catch unreachable;
            try list.appendSlice(&len_buf);
            try list.append(channel);
            try list.appendSlice(data[offset .. offset + chunk_len]);
            offset += chunk_len;
        }
    }
};

pub const GitServer = struct {
    allocator: std.mem.Allocator,
    repo_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, repo_path: []const u8) GitServer {
        return GitServer{
            .allocator = allocator,
            .repo_path = repo_path,
        };
    }

    pub fn deinit(self: *GitServer) void {
        _ = self;
    }

    /// Start a TCP server on the given port serving the git protocol.
    pub fn serve(self: *GitServer, port: u16) !void {
        std.debug.print("Git server started on port {d}\n", .{port});
        std.debug.print("Repository: {s}\n", .{self.repo_path});
        std.debug.print("Supported protocols: git-upload-pack, git-receive-pack\n", .{});

        const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        var server = try address.listen(.{
            .reuse_address = true,
        });
        defer server.deinit();

        std.debug.print("Server ready to accept git protocol connections on port {d}\n", .{port});

        while (true) {
            const conn = server.accept() catch |err| {
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            };
            self.handleConnection(conn.stream) catch |err| {
                std.debug.print("Connection error: {}\n", .{err});
            };
            conn.stream.close();
        }
    }

    /// Handle a single git protocol connection.
    fn handleConnection(self: *GitServer, stream: std.net.Stream) !void {
        const request_line = try PktLine.readFromStream(self.allocator, stream) orelse return;
        defer self.allocator.free(request_line);

        // Git protocol request: "git-upload-pack /repo\0host=...\0"
        const trimmed = std.mem.trimRight(u8, request_line, "\x00");
        var parts_iter = std.mem.splitScalar(u8, trimmed, 0);
        const command_part = parts_iter.first();

        if (std.mem.startsWith(u8, command_part, "git-upload-pack ")) {
            try self.handleUploadPack(stream);
        } else if (std.mem.startsWith(u8, command_part, "git-receive-pack ")) {
            try self.handleReceivePack(stream);
        } else {
            try PktLine.writeToStream(stream, "ERR unknown command\n");
        }
    }

    // ========================================================================
    // git-upload-pack protocol handler (serves fetch/clone)
    // ========================================================================

    pub fn handleUploadPack(self: *GitServer, stream: std.net.Stream) !void {
        const git_dir = try self.resolveGitDir();
        defer self.allocator.free(git_dir);

        // Phase 1: Reference advertisement
        var ref_list = try self.collectAllRefs(git_dir);
        defer {
            for (ref_list.items) |entry| {
                self.allocator.free(entry.name);
                self.allocator.free(entry.hash);
            }
            ref_list.deinit();
        }

        const capabilities = "multi_ack thin-pack side-band side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress include-tag multi_ack_detailed symref=HEAD:refs/heads/master object-format=sha1 agent=ziggit/1.0";

        // Build and send ref advertisement
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();
        try self.advertiseRefs(&out, ref_list.items, capabilities);
        try PktLine.appendFlush(&out);
        try stream.writeAll(out.items);

        // Phase 2: Negotiation
        var wants = std.array_list.Managed([40]u8).init(self.allocator);
        defer wants.deinit();
        var haves = std.array_list.Managed([40]u8).init(self.allocator);
        defer haves.deinit();
        var done_received = false;
        var use_side_band = false;

        // Read want lines
        while (true) {
            const line = try PktLine.readFromStream(self.allocator, stream) orelse break;
            defer self.allocator.free(line);
            const trimmed_line = std.mem.trimRight(u8, line, "\n\r");

            if (std.mem.startsWith(u8, trimmed_line, "want ") and trimmed_line.len >= 45) {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, trimmed_line[5..45]);
                try wants.append(hash);

                if (trimmed_line.len > 45) {
                    const caps = trimmed_line[46..];
                    if (std.mem.indexOf(u8, caps, "side-band-64k") != null) {
                        use_side_band = true;
                    }
                }
            }
        }

        if (wants.items.len == 0) return;

        // Read have lines and negotiate
        while (true) {
            const line = try PktLine.readFromStream(self.allocator, stream) orelse {
                // Flush after haves
                var nak_buf = std.array_list.Managed(u8).init(self.allocator);
                defer nak_buf.deinit();
                try PktLine.appendTo(&nak_buf, "NAK\n");
                try stream.writeAll(nak_buf.items);
                continue;
            };
            defer self.allocator.free(line);
            const trimmed_line = std.mem.trimRight(u8, line, "\n\r");

            if (std.mem.startsWith(u8, trimmed_line, "have ") and trimmed_line.len >= 45) {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, trimmed_line[5..45]);
                try haves.append(hash);
            } else if (std.mem.eql(u8, trimmed_line, "done")) {
                done_received = true;
                break;
            }
        }

        // Send NAK
        {
            var nak_buf = std.array_list.Managed(u8).init(self.allocator);
            defer nak_buf.deinit();
            try PktLine.appendTo(&nak_buf, "NAK\n");
            try stream.writeAll(nak_buf.items);
        }

        if (!done_received) return;

        // Phase 3: Generate and send pack data
        const pack_data = try self.generatePackData(git_dir, wants.items, haves.items);
        defer self.allocator.free(pack_data);

        if (use_side_band) {
            try SideBand.writeToStream(stream, SideBand.PACK_DATA, pack_data);
            try SideBand.writeToStream(stream, SideBand.PROGRESS, "Counting objects done.\n");
            try PktLine.writeFlushToStream(stream);
        } else {
            try stream.writeAll(pack_data);
        }
    }

    // ========================================================================
    // git-receive-pack protocol handler (serves push)
    // ========================================================================

    pub fn handleReceivePack(self: *GitServer, stream: std.net.Stream) !void {
        const git_dir = try self.resolveGitDir();
        defer self.allocator.free(git_dir);

        // Phase 1: Reference advertisement
        var ref_list = try self.collectAllRefs(git_dir);
        defer {
            for (ref_list.items) |entry| {
                self.allocator.free(entry.name);
                self.allocator.free(entry.hash);
            }
            ref_list.deinit();
        }

        const capabilities = "report-status report-status-v2 delete-refs side-band-64k quiet atomic ofs-delta object-format=sha1 agent=ziggit/1.0";

        var out_buf = std.array_list.Managed(u8).init(self.allocator);
        defer out_buf.deinit();
        try self.advertiseRefs(&out_buf, ref_list.items, capabilities);
        try PktLine.appendFlush(&out_buf);
        try stream.writeAll(out_buf.items);

        // Phase 2: Read ref update commands
        const RefUpdate = struct {
            old_hash: [40]u8,
            new_hash: [40]u8,
            ref_name: []const u8,
        };

        var updates = std.array_list.Managed(RefUpdate).init(self.allocator);
        defer {
            for (updates.items) |u| self.allocator.free(u.ref_name);
            updates.deinit();
        }
        var use_side_band = false;
        var report_status = false;

        while (true) {
            const line = try PktLine.readFromStream(self.allocator, stream) orelse break;
            defer self.allocator.free(line);
            const trimmed_line = std.mem.trimRight(u8, line, "\n\r");

            if (trimmed_line.len < 83) continue;

            var update: RefUpdate = undefined;
            @memcpy(&update.old_hash, trimmed_line[0..40]);
            @memcpy(&update.new_hash, trimmed_line[41..81]);

            const ref_and_caps = trimmed_line[82..];
            if (std.mem.indexOfScalar(u8, ref_and_caps, 0)) |null_pos| {
                update.ref_name = try self.allocator.dupe(u8, ref_and_caps[0..null_pos]);
                const caps = ref_and_caps[null_pos + 1 ..];
                if (std.mem.indexOf(u8, caps, "side-band-64k") != null) use_side_band = true;
                if (std.mem.indexOf(u8, caps, "report-status") != null) report_status = true;
            } else {
                update.ref_name = try self.allocator.dupe(u8, ref_and_caps);
            }

            try updates.append(update);
        }

        if (updates.items.len == 0) return;

        // Phase 3: Read pack data
        const zero_hash = "0000000000000000000000000000000000000000";
        var has_non_delete = false;
        for (updates.items) |u| {
            if (!std.mem.eql(u8, &u.new_hash, zero_hash)) {
                has_non_delete = true;
                break;
            }
        }

        if (has_non_delete) {
            var pack_buf = std.array_list.Managed(u8).init(self.allocator);
            defer pack_buf.deinit();

            var header: [12]u8 = undefined;
            var hdr_read: usize = 0;
            while (hdr_read < 12) {
                const n = stream.read(header[hdr_read..]) catch break;
                if (n == 0) break;
                hdr_read += n;
            }

            if (hdr_read == 12 and std.mem.eql(u8, header[0..4], "PACK")) {
                try pack_buf.appendSlice(&header);
                var read_buf: [8192]u8 = undefined;
                while (true) {
                    const n = stream.read(&read_buf) catch break;
                    if (n == 0) break;
                    try pack_buf.appendSlice(read_buf[0..n]);
                }
            }

            if (pack_buf.items.len > 0) {
                self.savePackToRepo(git_dir, pack_buf.items) catch |err| {
                    std.debug.print("Failed to save pack: {}\n", .{err});
                    if (report_status) {
                        self.sendReceivePackStatus(stream, updates.items, use_side_band, false, "unpack error") catch {};
                    }
                    return;
                };
            }
        }

        // Phase 4: Apply ref updates
        var all_ok = true;
        for (updates.items) |update| {
            self.applyRefUpdate(git_dir, &update.old_hash, &update.new_hash, update.ref_name) catch {
                all_ok = false;
            };
        }

        // Phase 5: Send report-status
        if (report_status) {
            try self.sendReceivePackStatus(stream, updates.items, use_side_band, all_ok, null);
        }
    }

    // ========================================================================
    // Shared helpers
    // ========================================================================

    fn resolveGitDir(self: *GitServer) ![]u8 {
        const dot_git = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{self.repo_path});
        const is_dot_git = blk: {
            std.fs.cwd().access(dot_git, .{}) catch {
                self.allocator.free(dot_git);
                break :blk false;
            };
            break :blk true;
        };
        if (is_dot_git) return dot_git;

        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.repo_path});
        defer self.allocator.free(head_path);
        std.fs.cwd().access(head_path, .{}) catch return error.NotAGitRepository;
        return try self.allocator.dupe(u8, self.repo_path);
    }

    fn collectAllRefs(self: *GitServer, git_dir: []const u8) !std.array_list.Managed(RefEntry) {
        var ref_list = std.array_list.Managed(RefEntry).init(self.allocator);
        errdefer {
            for (ref_list.items) |entry| {
                self.allocator.free(entry.name);
                self.allocator.free(entry.hash);
            }
            ref_list.deinit();
        }

        try self.readHead(git_dir, &ref_list);
        try self.collectLooseRefs(git_dir, "refs", &ref_list);
        try self.collectPackedRefs(git_dir, &ref_list);

        // Sort: HEAD first, then alphabetical
        var i: usize = 0;
        while (i < ref_list.items.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < ref_list.items.len) : (j += 1) {
                const swap = blk: {
                    if (std.mem.eql(u8, ref_list.items[j].name, "HEAD")) break :blk true;
                    if (std.mem.eql(u8, ref_list.items[i].name, "HEAD")) break :blk false;
                    break :blk std.mem.order(u8, ref_list.items[i].name, ref_list.items[j].name) == .gt;
                };
                if (swap) {
                    const tmp = ref_list.items[i];
                    ref_list.items[i] = ref_list.items[j];
                    ref_list.items[j] = tmp;
                }
            }
        }

        return ref_list;
    }

    fn readHead(self: *GitServer, git_dir: []const u8, ref_list: *std.array_list.Managed(RefEntry)) !void {
        const head_file = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{git_dir});
        defer self.allocator.free(head_file);
        const head_content = std.fs.cwd().readFileAlloc(self.allocator, head_file, 1024) catch return;
        defer self.allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \t\r\n");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_name = trimmed[5..];
            const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ git_dir, ref_name });
            defer self.allocator.free(ref_path);
            if (std.fs.cwd().readFileAlloc(self.allocator, ref_path, 1024)) |ref_content| {
                defer self.allocator.free(ref_content);
                const hash = std.mem.trim(u8, ref_content, " \t\r\n");
                if (hash.len >= 40) {
                    try ref_list.append(.{
                        .name = try self.allocator.dupe(u8, "HEAD"),
                        .hash = try self.allocator.dupe(u8, hash[0..40]),
                    });
                }
            } else |_| {
                if (self.resolvePackedRef(git_dir, ref_name)) |hash| {
                    try ref_list.append(.{
                        .name = try self.allocator.dupe(u8, "HEAD"),
                        .hash = hash,
                    });
                } else |_| {}
            }
        } else if (trimmed.len >= 40) {
            try ref_list.append(.{
                .name = try self.allocator.dupe(u8, "HEAD"),
                .hash = try self.allocator.dupe(u8, trimmed[0..40]),
            });
        }
    }

    fn collectLooseRefs(self: *GitServer, git_dir: []const u8, prefix: []const u8, ref_list: *std.array_list.Managed(RefEntry)) !void {
        const dir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ git_dir, prefix });
        defer self.allocator.free(dir_path);

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const full_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            if (entry.kind == .directory) {
                defer self.allocator.free(full_name);
                try self.collectLooseRefs(git_dir, full_name, ref_list);
            } else {
                const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ git_dir, full_name });
                defer self.allocator.free(file_path);
                if (std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024)) |content| {
                    defer self.allocator.free(content);
                    const hash = std.mem.trim(u8, content, " \t\r\n");
                    if (hash.len >= 40) {
                        try ref_list.append(.{
                            .name = full_name,
                            .hash = try self.allocator.dupe(u8, hash[0..40]),
                        });
                    } else {
                        self.allocator.free(full_name);
                    }
                } else |_| {
                    self.allocator.free(full_name);
                }
            }
        }
    }

    fn collectPackedRefs(self: *GitServer, git_dir: []const u8, ref_list: *std.array_list.Managed(RefEntry)) !void {
        const packed_path = try std.fmt.allocPrint(self.allocator, "{s}/packed-refs", .{git_dir});
        defer self.allocator.free(packed_path);
        const content = std.fs.cwd().readFileAlloc(self.allocator, packed_path, 10 * 1024 * 1024) catch return;
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
                const hash = line[0..sp];
                const name = line[sp + 1 ..];
                if (hash.len >= 40 and std.mem.startsWith(u8, name, "refs/")) {
                    var found = false;
                    for (ref_list.items) |existing| {
                        if (std.mem.eql(u8, existing.name, name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try ref_list.append(.{
                            .name = try self.allocator.dupe(u8, name),
                            .hash = try self.allocator.dupe(u8, hash[0..40]),
                        });
                    }
                }
            }
        }
    }

    fn resolvePackedRef(self: *GitServer, git_dir: []const u8, ref_name: []const u8) ![]const u8 {
        const packed_path = try std.fmt.allocPrint(self.allocator, "{s}/packed-refs", .{git_dir});
        defer self.allocator.free(packed_path);
        const content = try std.fs.cwd().readFileAlloc(self.allocator, packed_path, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
                const hash = line[0..sp];
                const name = line[sp + 1 ..];
                if (std.mem.eql(u8, name, ref_name) and hash.len >= 40) {
                    return try self.allocator.dupe(u8, hash[0..40]);
                }
            }
        }
        return error.NotFound;
    }

    fn advertiseRefs(self: *GitServer, out: *std.array_list.Managed(u8), ref_entries: []const RefEntry, capabilities: []const u8) !void {
        if (ref_entries.len == 0) {
            const line = try std.fmt.allocPrint(self.allocator, "0000000000000000000000000000000000000000 capabilities^{{}}\x00{s}\n", .{capabilities});
            defer self.allocator.free(line);
            try PktLine.appendTo(out, line);
        } else {
            for (ref_entries, 0..) |entry, i| {
                if (i == 0) {
                    const line = try std.fmt.allocPrint(self.allocator, "{s} {s}\x00{s}\n", .{ entry.hash, entry.name, capabilities });
                    defer self.allocator.free(line);
                    try PktLine.appendTo(out, line);
                } else {
                    const line = try std.fmt.allocPrint(self.allocator, "{s} {s}\n", .{ entry.hash, entry.name });
                    defer self.allocator.free(line);
                    try PktLine.appendTo(out, line);
                }
            }
        }
    }

    fn generatePackData(self: *GitServer, git_dir: []const u8, wants: [][40]u8, haves: [][40]u8) ![]u8 {
        var have_set = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = have_set.keyIterator();
            while (it.next()) |k| self.allocator.free(@constCast(k.*));
            have_set.deinit();
        }
        var have_list = std.array_list.Managed([]const u8).init(self.allocator);
        defer have_list.deinit();

        for (haves) |have| {
            self.walkReachable(git_dir, &have, &have_set, &have_list) catch {};
        }

        var want_set = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = want_set.keyIterator();
            while (it.next()) |k| self.allocator.free(@constCast(k.*));
            want_set.deinit();
        }
        var want_list = std.array_list.Managed([]const u8).init(self.allocator);
        defer want_list.deinit();

        for (wants) |want| {
            self.walkReachable(git_dir, &want, &want_set, &want_list) catch {};
        }

        // Remove objects already in have_set
        {
            var i: usize = 0;
            while (i < want_list.items.len) {
                if (have_set.contains(want_list.items[i])) {
                    _ = want_list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        return try self.buildPackFromObjects(git_dir, want_list.items);
    }

    fn walkReachable(
        self: *GitServer,
        git_dir: []const u8,
        start_hash: []const u8,
        set: *std.StringHashMap(void),
        list: *std.array_list.Managed([]const u8),
    ) !void {
        var worklist = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (worklist.items) |item| self.allocator.free(item);
            worklist.deinit();
        }
        try worklist.append(try self.allocator.dupe(u8, start_hash));

        while (worklist.items.len > 0) {
            const hash = worklist.pop() orelse break;
            defer self.allocator.free(hash);

            if (set.contains(hash)) continue;

            const obj = objects.GitObject.load(hash, git_dir, FakePlatform{}, self.allocator) catch continue;
            defer obj.deinit(self.allocator);

            const duped = try self.allocator.dupe(u8, hash);
            try set.put(duped, {});
            try list.append(duped);

            switch (obj.type) {
                .commit => {
                    var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
                    while (line_iter.next()) |line| {
                        if (line.len == 0) break;
                        if (std.mem.startsWith(u8, line, "tree ") and line.len >= 45) {
                            try worklist.append(try self.allocator.dupe(u8, line[5..45]));
                        } else if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                            try worklist.append(try self.allocator.dupe(u8, line[7..47]));
                        }
                    }
                },
                .tree => {
                    var tpos: usize = 0;
                    while (tpos < obj.data.len) {
                        const null_pos = std.mem.indexOfScalarPos(u8, obj.data, tpos, 0) orelse break;
                        if (null_pos + 21 > obj.data.len) break;
                        const entry_hash_bytes = obj.data[null_pos + 1 .. null_pos + 21];
                        var entry_hex: [40]u8 = undefined;
                        for (entry_hash_bytes, 0..) |b, idx| {
                            const hc = "0123456789abcdef";
                            entry_hex[idx * 2] = hc[b >> 4];
                            entry_hex[idx * 2 + 1] = hc[b & 0xf];
                        }
                        try worklist.append(try self.allocator.dupe(u8, &entry_hex));
                        tpos = null_pos + 21;
                    }
                },
                .tag => {
                    var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
                    while (line_iter.next()) |line| {
                        if (line.len == 0) break;
                        if (std.mem.startsWith(u8, line, "object ") and line.len >= 47) {
                            try worklist.append(try self.allocator.dupe(u8, line[7..47]));
                        }
                    }
                },
                .blob => {},
            }
        }
    }

    fn buildPackFromObjects(self: *GitServer, git_dir: []const u8, object_hashes: []const []const u8) ![]u8 {
        var pack = std.array_list.Managed(u8).init(self.allocator);
        errdefer pack.deinit();

        try pack.appendSlice("PACK");
        const version: u32 = 2;
        try pack.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, version)));
        const count_pos = pack.items.len;
        try pack.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));

        var actual_count: u32 = 0;
        for (object_hashes) |hash| {
            const obj = objects.GitObject.load(hash, git_dir, FakePlatform{}, self.allocator) catch continue;
            defer obj.deinit(self.allocator);

            const type_num: u8 = switch (obj.type) {
                .commit => 1,
                .tree => 2,
                .blob => 3,
                .tag => 4,
            };

            var obj_size = obj.data.len;
            var first_byte: u8 = (type_num << 4) | @as(u8, @intCast(obj_size & 0x0F));
            obj_size >>= 4;
            if (obj_size > 0) first_byte |= 0x80;
            try pack.append(first_byte);
            while (obj_size > 0) {
                var byte: u8 = @intCast(obj_size & 0x7F);
                obj_size >>= 7;
                if (obj_size > 0) byte |= 0x80;
                try pack.append(byte);
            }

            const compressed = objects.cCompressSlice(self.allocator, obj.data) catch continue;
            defer self.allocator.free(compressed);
            try pack.appendSlice(compressed);
            actual_count += 1;
        }

        const count_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, actual_count));
        @memcpy(pack.items[count_pos..][0..4], &count_bytes);

        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(pack.items);
        const checksum = sha1.finalResult();
        try pack.appendSlice(&checksum);

        return pack.toOwnedSlice();
    }

    fn savePackToRepo(self: *GitServer, git_dir: []const u8, pack_data: []const u8) !void {
        if (pack_data.len < 32) return error.InvalidPackData;
        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackData;

        const pack_content = pack_data[0 .. pack_data.len - 20];
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(pack_content);
        const checksum = sha1.finalResult();
        var checksum_hex: [40]u8 = undefined;
        for (checksum, 0..) |b, i| {
            const hc = "0123456789abcdef";
            checksum_hex[i * 2] = hc[b >> 4];
            checksum_hex[i * 2 + 1] = hc[b & 0xf];
        }

        const pack_dir = try std.fmt.allocPrint(self.allocator, "{s}/objects/pack", .{git_dir});
        defer self.allocator.free(pack_dir);
        std.fs.cwd().makePath(pack_dir) catch {};

        const pack_path = try std.fmt.allocPrint(self.allocator, "{s}/pack-{s}.pack", .{ pack_dir, checksum_hex });
        defer self.allocator.free(pack_path);
        const pack_file = try std.fs.cwd().createFile(pack_path, .{});
        defer pack_file.close();
        try pack_file.writeAll(pack_data);

        // Generate index using self-contained implementation
        try self.generatePackIndex(pack_data, pack_dir, &checksum_hex);
    }

    fn applyRefUpdate(self: *GitServer, git_dir: []const u8, old_hash: *const [40]u8, new_hash: *const [40]u8, ref_name: []const u8) !void {
        const zero_hash = "0000000000000000000000000000000000000000";

        if (std.mem.eql(u8, new_hash, zero_hash)) {
            const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ git_dir, ref_name });
            defer self.allocator.free(ref_path);
            std.fs.cwd().deleteFile(ref_path) catch {};
            return;
        }

        if (!std.mem.eql(u8, old_hash, zero_hash)) {
            const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ git_dir, ref_name });
            defer self.allocator.free(ref_path);
            if (std.fs.cwd().readFileAlloc(self.allocator, ref_path, 1024)) |current| {
                defer self.allocator.free(current);
                const current_hash = std.mem.trim(u8, current, " \t\r\n");
                if (current_hash.len >= 40 and !std.mem.eql(u8, current_hash[0..40], old_hash)) {
                    return error.RefUpdateRejected;
                }
            } else |_| {
                return error.RefUpdateRejected;
            }
        }

        const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ git_dir, ref_name });
        defer self.allocator.free(ref_path);

        if (std.mem.lastIndexOfScalar(u8, ref_path, '/')) |last_slash| {
            std.fs.cwd().makePath(ref_path[0..last_slash]) catch {};
        }

        const ref_file = try std.fs.cwd().createFile(ref_path, .{});
        defer ref_file.close();
        try ref_file.writeAll(new_hash);
        try ref_file.writeAll("\n");
    }

    /// Generate a v2 pack index file for the given pack data.
    fn generatePackIndex(self: *GitServer, pack_data: []const u8, pack_dir: []const u8, hash_hex: *const [40]u8) !void {
        if (pack_data.len < 12) return;
        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return;

        const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

        var object_shas = std.array_list.Managed([20]u8).init(self.allocator);
        defer object_shas.deinit();
        var offsets_list = std.array_list.Managed(u32).init(self.allocator);
        defer offsets_list.deinit();
        var crcs = std.array_list.Managed(u32).init(self.allocator);
        defer crcs.deinit();

        var pos: usize = 12;
        var obj_count: usize = 0;
        while (obj_count < num_objects and pos < pack_data.len -| 20) : (obj_count += 1) {
            const entry_offset = pos;
            try offsets_list.append(@intCast(entry_offset));

            var c = pack_data[pos];
            pos += 1;
            const obj_type = (pack_data[entry_offset] >> 4) & 0x07;
            var obj_size: u64 = c & 0x0F;
            var shift: u6 = 4;
            while (c & 0x80 != 0 and pos < pack_data.len) {
                c = pack_data[pos];
                pos += 1;
                obj_size |= @as(u64, c & 0x7F) << shift;
                shift +|= 7;
            }

            if (obj_type == 6) {
                c = pack_data[pos];
                pos += 1;
                while (c & 0x80 != 0 and pos < pack_data.len) {
                    c = pack_data[pos];
                    pos += 1;
                }
            } else if (obj_type == 7) {
                pos += 20;
            }

            // Decompress to find end of compressed data and compute SHA
            const compressed = pack_data[pos..@min(pos + obj_size + 1024, pack_data.len)];
            const decomp = objects.cDecompressWithConsumed(self.allocator, compressed, @intCast(@min(obj_size, 1 << 24))) orelse {
                try object_shas.append(std.mem.zeroes([20]u8));
                try crcs.append(0);
                continue;
            };
            defer self.allocator.free(decomp.data);
            pos += decomp.consumed;

            const crc = std.hash.crc.Crc32IsoHdlc.hash(pack_data[entry_offset..pos]);
            try crcs.append(crc);

            var sha: [20]u8 = std.mem.zeroes([20]u8);
            if (obj_type >= 1 and obj_type <= 4) {
                const type_str: []const u8 = switch (obj_type) {
                    1 => "commit",
                    2 => "tree",
                    3 => "blob",
                    4 => "tag",
                    else => "blob",
                };
                const header = try std.fmt.allocPrint(self.allocator, "{s} {d}\x00", .{ type_str, decomp.data.len });
                defer self.allocator.free(header);
                var hasher = std.crypto.hash.Sha1.init(.{});
                hasher.update(header);
                hasher.update(decomp.data);
                sha = hasher.finalResult();
            }
            try object_shas.append(sha);
        }

        // Build v2 idx
        var idx = std.array_list.Managed(u8).init(self.allocator);
        defer idx.deinit();

        try idx.appendSlice("\xfftOc");
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 2)));

        // Sort indices by SHA
        const indices = try self.allocator.alloc(usize, object_shas.items.len);
        defer self.allocator.free(indices);
        for (indices, 0..) |*iv, j| iv.* = j;

        const SortCtx = struct {
            shas: [][20]u8,
            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, &ctx.shas[a], &ctx.shas[b]).compare(.lt);
            }
        };
        std.mem.sort(usize, indices, SortCtx{ .shas = object_shas.items }, SortCtx.lessThan);

        // Fanout table
        var fanout: [256]u32 = std.mem.zeroes([256]u32);
        for (indices) |iv| {
            const first_byte = object_shas.items[iv][0];
            var fb: usize = first_byte;
            while (fb < 256) : (fb += 1) {
                fanout[fb] += 1;
            }
        }
        for (fanout) |f| {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, f)));
        }

        // SHA-1 table
        for (indices) |iv| {
            try idx.appendSlice(&object_shas.items[iv]);
        }

        // CRC32 table
        for (indices) |iv| {
            if (iv < crcs.items.len) {
                try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, crcs.items[iv])));
            } else {
                try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
            }
        }

        // Offset table
        for (indices) |iv| {
            if (iv < offsets_list.items.len) {
                try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, offsets_list.items[iv])));
            } else {
                try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
            }
        }

        // Pack checksum
        if (pack_data.len >= 20) {
            try idx.appendSlice(pack_data[pack_data.len - 20 ..]);
        }

        // Idx checksum
        var idx_sha = std.crypto.hash.Sha1.init(.{});
        idx_sha.update(idx.items);
        const idx_checksum = idx_sha.finalResult();
        try idx.appendSlice(&idx_checksum);

        // Write file
        const idx_path = try std.fmt.allocPrint(self.allocator, "{s}/pack-{s}.idx", .{ pack_dir, hash_hex });
        defer self.allocator.free(idx_path);
        const idx_file = try std.fs.cwd().createFile(idx_path, .{});
        defer idx_file.close();
        try idx_file.writeAll(idx.items);
    }

    fn sendReceivePackStatus(
        self: *GitServer,
        stream: std.net.Stream,
        updates: anytype,
        use_side_band: bool,
        all_ok: bool,
        unpack_error: ?[]const u8,
    ) !void {
        var status_buf = std.array_list.Managed(u8).init(self.allocator);
        defer status_buf.deinit();

        // Build status pkt-lines
        if (unpack_error) |err_msg| {
            const line = try std.fmt.allocPrint(self.allocator, "unpack {s}\n", .{err_msg});
            defer self.allocator.free(line);
            try PktLine.appendTo(&status_buf, line);
        } else {
            try PktLine.appendTo(&status_buf, "unpack ok\n");
        }

        for (updates) |update| {
            if (all_ok) {
                const status = try std.fmt.allocPrint(self.allocator, "ok {s}\n", .{update.ref_name});
                defer self.allocator.free(status);
                try PktLine.appendTo(&status_buf, status);
            } else {
                const status = try std.fmt.allocPrint(self.allocator, "ng {s} update rejected\n", .{update.ref_name});
                defer self.allocator.free(status);
                try PktLine.appendTo(&status_buf, status);
            }
        }
        try PktLine.appendFlush(&status_buf);

        if (use_side_band) {
            try SideBand.writeToStream(stream, SideBand.PACK_DATA, status_buf.items);
            try PktLine.writeFlushToStream(stream);
        } else {
            try stream.writeAll(status_buf.items);
        }
    }
};

/// Minimal platform implementation for object loading in server context.
/// Provides the duck-type interface that objects.zig expects via anytype.
const FakePlatform = struct {
    fs: FakeFs = .{},

    pub fn writeStderr(_: FakePlatform, _: []const u8) !void {}
    pub fn writeStdout(_: FakePlatform, _: []const u8) !void {}

    const FakeFs = struct {
        pub fn readFile(_: FakeFs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024);
        }
        pub fn writeFile(_: FakeFs, path: []const u8, data: []const u8) !void {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(data);
        }
        pub fn makeDir(_: FakeFs, path: []const u8) !void {
            std.fs.cwd().makePath(path) catch {};
        }
        pub fn exists(_: FakeFs, path: []const u8) !bool {
            std.fs.cwd().access(path, .{}) catch return false;
            return true;
        }
        pub fn deleteFile(_: FakeFs, path: []const u8) !void {
            try std.fs.cwd().deleteFile(path);
        }
        pub fn getCwd(_: FakeFs, allocator: std.mem.Allocator) ![]u8 {
            const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
            return cwd;
        }
        pub fn chdir(_: FakeFs, _: []const u8) !void {}
        pub fn readDir(_: FakeFs, _: std.mem.Allocator, _: []const u8) ![][]u8 {
            return &.{};
        }
        pub fn stat(_: FakeFs, path: []const u8) !std.fs.File.Stat {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            return try file.stat();
        }
    };
};

// ============================================================================
// Tests
// ============================================================================

test "PktLine.format basic" {
    const allocator = std.testing.allocator;
    const result = try PktLine.format(allocator, "hello\n");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("000ahello\n", result);
}

test "PktLine.format empty" {
    const allocator = std.testing.allocator;
    const result = try PktLine.format(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("0004", result);
}

test "PktLine.flush" {
    try std.testing.expectEqualStrings("0000", PktLine.flush());
}

test "PktLine appendTo round-trip" {
    const allocator = std.testing.allocator;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    const payload = "want 0123456789abcdef0123456789abcdef01234567\n";
    try PktLine.appendTo(&buf, payload);

    // Verify format
    const expected_len = payload.len + 4;
    var expected_hex: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&expected_hex, "{x:0>4}", .{expected_len}) catch unreachable;
    try std.testing.expectEqualStrings(&expected_hex, buf.items[0..4]);
    try std.testing.expectEqualStrings(payload, buf.items[4..]);
}

test "PktLine.readFrom" {
    const data = "000ahello\n0000";

    // Read first pkt-line
    const result1 = PktLine.readFrom(data, 0).?;
    try std.testing.expectEqualStrings("hello\n", result1.payload);

    // Read flush
    const result2 = PktLine.readFrom(data, result1.next).?;
    try std.testing.expectEqualStrings("", result2.payload);
}

test "PktLine.readFrom flush" {
    const data = "0000";
    const result = PktLine.readFrom(data, 0).?;
    try std.testing.expectEqualStrings("", result.payload);
    try std.testing.expectEqual(@as(usize, 4), result.next);
}

test "GitServer init and deinit" {
    const allocator = std.testing.allocator;
    var server = GitServer.init(allocator, "/tmp/test-repo");
    defer server.deinit();
    try std.testing.expectEqualStrings("/tmp/test-repo", server.repo_path);
}

test "PktLine format ref advertisement line" {
    const allocator = std.testing.allocator;

    const hash = "0123456789abcdef0123456789abcdef01234567";
    const ref_name = "HEAD";
    const caps = "multi_ack side-band-64k";
    const line = try std.fmt.allocPrint(allocator, "{s} {s}\x00{s}\n", .{ hash, ref_name, caps });
    defer allocator.free(line);

    const pkt = try PktLine.format(allocator, line);
    defer allocator.free(pkt);

    const expected_len = line.len + 4;
    var expected_hex: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&expected_hex, "{x:0>4}", .{expected_len}) catch unreachable;
    try std.testing.expectEqualStrings(&expected_hex, pkt[0..4]);
    try std.testing.expectEqualStrings(line, pkt[4..]);
}

test "SideBand appendTo" {
    const allocator = std.testing.allocator;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try SideBand.appendTo(&buf, SideBand.PACK_DATA, "test data");

    // length = 4 + 1 + 9 = 14 = 0x000e
    try std.testing.expectEqualStrings("000e", buf.items[0..4]);
    try std.testing.expectEqual(@as(u8, 1), buf.items[4]);
    try std.testing.expectEqualStrings("test data", buf.items[5..]);
}

test "Multiple PktLine round-trip via buffer" {
    const allocator = std.testing.allocator;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try PktLine.appendTo(&buf, "line one\n");
    try PktLine.appendTo(&buf, "line two\n");
    try PktLine.appendFlush(&buf);

    // Read them back with readFrom
    var offset: usize = 0;
    const r1 = PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("line one\n", r1.payload);
    offset = r1.next;

    const r2 = PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("line two\n", r2.payload);
    offset = r2.next;

    // Flush
    const r3 = PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("", r3.payload);
}

test "PktLine ref advertisement format for empty repo" {
    const allocator = std.testing.allocator;

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    // Simulate empty repo advertisement
    const caps = "report-status side-band-64k";
    const line = try std.fmt.allocPrint(allocator, "0000000000000000000000000000000000000000 capabilities^{{}}\x00{s}\n", .{caps});
    defer allocator.free(line);
    try PktLine.appendTo(&out, line);
    try PktLine.appendFlush(&out);

    // Verify it starts with a valid pkt-line
    const r = PktLine.readFrom(out.items, 0).?;
    try std.testing.expect(std.mem.startsWith(u8, r.payload, "0000000000000000000000000000000000000000"));
    try std.testing.expect(std.mem.indexOf(u8, r.payload, "capabilities^{}") != null);
}
