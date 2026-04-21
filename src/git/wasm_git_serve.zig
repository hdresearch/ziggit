const std = @import("std");
const objects = @import("objects.zig");
const HostCallbackStorage = @import("host_callback_storage.zig").HostCallbackStorage;
const ObjectData = @import("host_callback_storage.zig").ObjectData;
const RefList = @import("host_callback_storage.zig").RefList;

// Host callback for streaming output
extern fn host_emit_bytes(data_ptr: [*]const u8, data_len: u32) void;

// ============================================================================
// Pkt-line utilities (buffer-only, no std.net.Stream / posix dependencies)
// ============================================================================

const PktLine = struct {
    /// Append a pkt-line (4-hex-digit length prefix + payload) to a buffer.
    fn appendTo(list: *std.array_list.Managed(u8), payload: []const u8) !void {
        const total_len = payload.len + 4;
        if (total_len > 65535) return error.Overflow;
        var len_buf: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&len_buf, "{x:0>4}", .{total_len}) catch unreachable;
        try list.appendSlice(&len_buf);
        try list.appendSlice(payload);
    }

    /// Append a flush packet "0000".
    fn appendFlush(list: *std.array_list.Managed(u8)) !void {
        try list.appendSlice("0000");
    }

    /// Read one pkt-line from `data` at `offset`.
    /// Returns null if there's not enough data.
    /// For a flush packet the payload is empty.
    fn readFrom(data: []const u8, offset: usize) ?struct { payload: []const u8, next: usize, is_flush: bool } {
        if (offset + 4 > data.len) return null;
        const len_bytes = data[offset .. offset + 4];
        if (std.mem.eql(u8, len_bytes, "0000")) {
            return .{ .payload = &.{}, .next = offset + 4, .is_flush = true };
        }
        const pkt_len = std.fmt.parseInt(u16, len_bytes, 16) catch return null;
        if (pkt_len < 4) return null;
        const data_len = pkt_len - 4;
        if (offset + 4 + data_len > data.len) return null;
        return .{
            .payload = data[offset + 4 .. offset + 4 + data_len],
            .next = offset + 4 + data_len,
            .is_flush = false,
        };
    }
};

/// Append a side-band-64k framed chunk (channel byte + data) to a buffer.
fn appendSideBand(list: *std.array_list.Managed(u8), channel: u8, data: []const u8) !void {
    const max_chunk = 65515; // 65535 - 4 (pkt header) - 1 (channel byte) - some margin
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

const SIDEBAND_DATA: u8 = 1;
const SIDEBAND_PROGRESS: u8 = 2;
const SIDEBAND_ERROR: u8 = 3;

// ============================================================================
// WasmGitServer
// ============================================================================

pub const WasmGitServer = struct {
    allocator: std.mem.Allocator,
    storage: HostCallbackStorage,

    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) WasmGitServer {
        return .{
            .allocator = allocator,
            .storage = HostCallbackStorage.init(allocator, git_dir),
        };
    }

    pub fn deinit(self: *WasmGitServer) void {
        self.storage.deinit();
    }

    // ====================================================================
    // Ref advertisement  (info/refs?service=…)
    // ====================================================================

    /// Generate ref advertisement for the info/refs endpoint.
    /// service: 0 = git-upload-pack, 1 = git-receive-pack
    pub fn serveRefAdvertisement(self: *WasmGitServer, service: u32) !void {
        var output = std.array_list.Managed(u8).init(self.allocator);
        defer output.deinit();

        const service_name = if (service == 0) "git-upload-pack" else "git-receive-pack";

        const upload_caps = "multi_ack thin-pack side-band side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress include-tag multi_ack_detailed allow-tip-sha1-in-want allow-reachable-sha1-in-want no-done symref=HEAD:refs/heads/main filter object-format=sha1 agent=ziggit/1.0";
        const receive_caps = "report-status report-status-v2 delete-refs side-band-64k quiet atomic ofs-delta object-format=sha1 agent=ziggit/1.0";
        const capabilities = if (service == 0) upload_caps else receive_caps;

        // Service header pkt-line
        var svc_hdr = std.array_list.Managed(u8).init(self.allocator);
        defer svc_hdr.deinit();
        try svc_hdr.appendSlice("# service=");
        try svc_hdr.appendSlice(service_name);
        try svc_hdr.appendSlice("\n");
        try PktLine.appendTo(&output, svc_hdr.items);
        try PktLine.appendFlush(&output);

        // Refs
        var ref_list = try self.storage.listRefs();
        defer ref_list.deinit();

        if (ref_list.entries.len == 0) {
            // Empty repo — advertise zero-id with capabilities
            const line = try std.fmt.allocPrint(self.allocator, "0000000000000000000000000000000000000000 capabilities^{{}}\x00{s}\n", .{capabilities});
            defer self.allocator.free(line);
            try PktLine.appendTo(&output, line);
        } else {
            for (ref_list.entries, 0..) |ref, i| {
                if (i == 0) {
                    const line = try std.fmt.allocPrint(self.allocator, "{s} {s}\x00{s}\n", .{ ref.hash, ref.name, capabilities });
                    defer self.allocator.free(line);
                    try PktLine.appendTo(&output, line);
                } else {
                    const line = try std.fmt.allocPrint(self.allocator, "{s} {s}\n", .{ ref.hash, ref.name });
                    defer self.allocator.free(line);
                    try PktLine.appendTo(&output, line);
                }
            }
        }

        try PktLine.appendFlush(&output);
        host_emit_bytes(output.items.ptr, @intCast(output.items.len));
    }

    // ====================================================================
    // git-upload-pack  (clone / fetch)
    // ====================================================================

    /// Process a git-upload-pack request body.
    ///
    /// The `request` bytes contain the client's want/have/done negotiation
    /// (everything after the ref advertisement, i.e. the POST body of
    /// `/git-upload-pack`).
    pub fn serveUploadPack(self: *WasmGitServer, request: []const u8) !void {
        var output = std.array_list.Managed(u8).init(self.allocator);
        defer output.deinit();

        // --- Parse client request ------------------------------------------
        var wants = std.array_list.Managed([40]u8).init(self.allocator);
        defer wants.deinit();
        var haves = std.array_list.Managed([40]u8).init(self.allocator);
        defer haves.deinit();
        var use_side_band = false;
        var done_received = false;
        var deepen_depth: u32 = 0;

        var offset: usize = 0;
        var past_first_flush = false;
        while (true) {
            const pkt = PktLine.readFrom(request, offset) orelse break;
            offset = pkt.next;

            if (pkt.is_flush) {
                if (past_first_flush) break; // second flush = end of haves
                past_first_flush = true;
                continue;
            }

            const line = std.mem.trimRight(u8, pkt.payload, "\n\r");

            if (std.mem.startsWith(u8, line, "want ") and line.len >= 45) {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, line[5..45]);
                try wants.append(hash);

                // Capabilities are appended after the first want's hash
                if (line.len > 45) {
                    const caps = line[46..];
                    if (std.mem.indexOf(u8, caps, "side-band-64k") != null) {
                        use_side_band = true;
                    }
                }
            } else if (std.mem.startsWith(u8, line, "have ") and line.len >= 45) {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, line[5..45]);
                try haves.append(hash);
            } else if (std.mem.startsWith(u8, line, "deepen ")) {
                deepen_depth = std.fmt.parseInt(u32, line[7..], 10) catch 0;
            } else if (std.mem.eql(u8, line, "done")) {
                done_received = true;
            }
        }

        if (wants.items.len == 0) {
            try PktLine.appendFlush(&output);
            host_emit_bytes(output.items.ptr, @intCast(output.items.len));
            return;
        }

        // --- Shallow boundary (if requested) --------------------------------
        if (deepen_depth > 0) {
            var shallow_out = std.array_list.Managed(u8).init(self.allocator);
            defer shallow_out.deinit();

            for (wants.items) |want_hash| {
                var boundary = try self.computeShallowBoundary(&want_hash, deepen_depth);
                defer {
                    for (boundary.items) |b| self.allocator.free(b);
                    boundary.deinit();
                }
                for (boundary.items) |commit_hash| {
                    const sline = try std.fmt.allocPrint(self.allocator, "shallow {s}\n", .{commit_hash});
                    defer self.allocator.free(sline);
                    try PktLine.appendTo(&shallow_out, sline);
                }
            }
            try PktLine.appendFlush(&shallow_out);
            try output.appendSlice(shallow_out.items);
        }

        // --- NAK (we don't do multi_ack negotiation in WASM server) ---------
        try PktLine.appendTo(&output, "NAK\n");

        if (!done_received and haves.items.len == 0) {
            // No "done" and no "haves" — the client is likely using no-done
            // or the request included everything inline. Proceed to pack.
        }

        // --- Generate pack data ---------------------------------------------
        const pack_data = try self.generatePackData(wants.items, haves.items);
        defer self.allocator.free(pack_data);

        if (use_side_band) {
            try appendSideBand(&output, SIDEBAND_DATA, pack_data);
            try appendSideBand(&output, SIDEBAND_PROGRESS, "Counting objects done.\n");
            try PktLine.appendFlush(&output);
        } else {
            try output.appendSlice(pack_data);
        }

        host_emit_bytes(output.items.ptr, @intCast(output.items.len));
    }

    // ====================================================================
    // git-receive-pack  (push)
    // ====================================================================

    /// Process a git-receive-pack request body.
    ///
    /// The `request` bytes contain the ref-update commands followed by
    /// a PACK stream (everything after the ref advertisement, i.e. the
    /// POST body of `/git-receive-pack`).
    pub fn serveReceivePack(self: *WasmGitServer, request: []const u8) !void {
        var output = std.array_list.Managed(u8).init(self.allocator);
        defer output.deinit();

        const zero_hash = "0000000000000000000000000000000000000000";

        // --- Parse ref update commands --------------------------------------
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

        var offset: usize = 0;
        // Read pkt-lines until flush (ref update commands)
        while (true) {
            const pkt = PktLine.readFrom(request, offset) orelse break;
            offset = pkt.next;
            if (pkt.is_flush) break;

            const line = std.mem.trimRight(u8, pkt.payload, "\n\r");
            // Format: "<old-hex> <new-hex> <refname>[\0<capabilities>]"
            if (line.len < 83) continue;

            var update: RefUpdate = undefined;
            @memcpy(&update.old_hash, line[0..40]);
            // skip space at 40
            @memcpy(&update.new_hash, line[41..81]);
            // skip space at 81

            const ref_and_caps = line[82..];
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

        if (updates.items.len == 0) {
            try PktLine.appendFlush(&output);
            host_emit_bytes(output.items.ptr, @intCast(output.items.len));
            return;
        }

        // --- Ingest PACK data -----------------------------------------------
        // Remaining bytes after the flush are the raw PACK stream.
        var has_non_delete = false;
        for (updates.items) |u| {
            if (!std.mem.eql(u8, &u.new_hash, zero_hash)) {
                has_non_delete = true;
                break;
            }
        }

        var unpack_ok = true;
        if (has_non_delete and offset < request.len) {
            const pack_data = request[offset..];
            if (pack_data.len >= 12 and std.mem.eql(u8, pack_data[0..4], "PACK")) {
                self.ingestPack(pack_data) catch {
                    unpack_ok = false;
                };
            }
        }

        // --- Apply ref updates ----------------------------------------------
        var all_ok = unpack_ok;
        for (updates.items) |update| {
            self.applyRefUpdate(&update.old_hash, &update.new_hash, update.ref_name) catch {
                all_ok = false;
            };
        }

        // --- Send report-status ---------------------------------------------
        if (report_status) {
            var status_buf = std.array_list.Managed(u8).init(self.allocator);
            defer status_buf.deinit();

            if (unpack_ok) {
                try PktLine.appendTo(&status_buf, "unpack ok\n");
            } else {
                try PktLine.appendTo(&status_buf, "unpack error\n");
            }

            for (updates.items) |update| {
                if (all_ok) {
                    const s = try std.fmt.allocPrint(self.allocator, "ok {s}\n", .{update.ref_name});
                    defer self.allocator.free(s);
                    try PktLine.appendTo(&status_buf, s);
                } else {
                    const s = try std.fmt.allocPrint(self.allocator, "ng {s} update rejected\n", .{update.ref_name});
                    defer self.allocator.free(s);
                    try PktLine.appendTo(&status_buf, s);
                }
            }
            try PktLine.appendFlush(&status_buf);

            if (use_side_band) {
                try appendSideBand(&output, SIDEBAND_DATA, status_buf.items);
                try PktLine.appendFlush(&output);
            } else {
                try output.appendSlice(status_buf.items);
            }
        }

        host_emit_bytes(output.items.ptr, @intCast(output.items.len));
    }

    // ====================================================================
    // Protocol v2 commands  (ls-refs, fetch)
    // ====================================================================

    /// Process a protocol-v2 command.
    ///
    /// The `request` bytes are the POST body for `/git-upload-pack` when
    /// the client negotiated `version=2`.  The first pkt-line is
    /// `command=<name>`, followed by capability-list delimited by a flush.
    pub fn serveV2Command(self: *WasmGitServer, request: []const u8) !void {
        var output = std.array_list.Managed(u8).init(self.allocator);
        defer output.deinit();

        // Parse the command name from the first pkt-line
        var offset: usize = 0;
        const first = PktLine.readFrom(request, offset) orelse {
            try PktLine.appendFlush(&output);
            host_emit_bytes(output.items.ptr, @intCast(output.items.len));
            return;
        };
        offset = first.next;

        const cmd_line = std.mem.trimRight(u8, first.payload, "\n\r");

        if (std.mem.startsWith(u8, cmd_line, "command=ls-refs")) {
            try self.handleV2LsRefs(request, offset, &output);
        } else if (std.mem.startsWith(u8, cmd_line, "command=fetch")) {
            try self.handleV2Fetch(request, offset, &output);
        } else {
            // Unknown v2 command — return flush
            try PktLine.appendFlush(&output);
        }

        host_emit_bytes(output.items.ptr, @intCast(output.items.len));
    }

    /// Handle protocol v2 `ls-refs`.
    fn handleV2LsRefs(self: *WasmGitServer, request: []const u8, start_offset: usize, output: *std.array_list.Managed(u8)) !void {
        // Parse optional arguments (ref-prefix, symrefs, peel)
        var ref_prefixes = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (ref_prefixes.items) |p| self.allocator.free(p);
            ref_prefixes.deinit();
        }
        var want_symrefs = false;

        var offset = start_offset;
        // Skip capability-list lines until delimiter (0001) or flush (0000)
        while (true) {
            const pkt = PktLine.readFrom(request, offset) orelse break;
            offset = pkt.next;
            if (pkt.is_flush) break;

            // Check for delimiter packet (0001)
            if (offset >= 4 and std.mem.eql(u8, request[offset - pkt.payload.len - 4 .. offset - pkt.payload.len], "0001")) {
                break;
            }

            const line = std.mem.trimRight(u8, pkt.payload, "\n\r");
            if (std.mem.startsWith(u8, line, "ref-prefix ")) {
                try ref_prefixes.append(try self.allocator.dupe(u8, line[11..]));
            } else if (std.mem.eql(u8, line, "symrefs")) {
                want_symrefs = true;
            }
        }

        // Continue reading arguments after a delimiter
        while (true) {
            const pkt = PktLine.readFrom(request, offset) orelse break;
            offset = pkt.next;
            if (pkt.is_flush) break;

            const line = std.mem.trimRight(u8, pkt.payload, "\n\r");
            if (std.mem.startsWith(u8, line, "ref-prefix ")) {
                try ref_prefixes.append(try self.allocator.dupe(u8, line[11..]));
            } else if (std.mem.eql(u8, line, "symrefs")) {
                want_symrefs = true;
            }
        }

        var ref_list = try self.storage.listRefs();
        defer ref_list.deinit();

        for (ref_list.entries) |ref| {
            // Filter by prefix if any were specified
            if (ref_prefixes.items.len > 0) {
                var matched = false;
                for (ref_prefixes.items) |prefix| {
                    if (std.mem.startsWith(u8, ref.name, prefix)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) continue;
            }

            if (want_symrefs and std.mem.eql(u8, ref.name, "HEAD")) {
                // HEAD is typically a symbolic ref
                const head_val = self.storage.readHead() catch continue;
                switch (head_val) {
                    .symbolic => |target| {
                        defer self.allocator.free(target);
                        const line = try std.fmt.allocPrint(self.allocator, "{s} {s} symref-target:{s}\n", .{ ref.hash, ref.name, target });
                        defer self.allocator.free(line);
                        try PktLine.appendTo(output, line);
                        continue;
                    },
                    .direct => {},
                }
            }

            const line = try std.fmt.allocPrint(self.allocator, "{s} {s}\n", .{ ref.hash, ref.name });
            defer self.allocator.free(line);
            try PktLine.appendTo(output, line);
        }

        try PktLine.appendFlush(output);
    }

    /// Handle protocol v2 `fetch`.
    fn handleV2Fetch(self: *WasmGitServer, request: []const u8, start_offset: usize, output: *std.array_list.Managed(u8)) !void {
        var wants = std.array_list.Managed([40]u8).init(self.allocator);
        defer wants.deinit();
        var haves = std.array_list.Managed([40]u8).init(self.allocator);
        defer haves.deinit();
        var deepen_depth: u32 = 0;

        var offset = start_offset;
        // Read arguments
        while (true) {
            const pkt = PktLine.readFrom(request, offset) orelse break;
            offset = pkt.next;
            if (pkt.is_flush) break;

            const line = std.mem.trimRight(u8, pkt.payload, "\n\r");

            if (std.mem.startsWith(u8, line, "want ") and line.len >= 45) {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, line[5..45]);
                try wants.append(hash);
            } else if (std.mem.startsWith(u8, line, "have ") and line.len >= 45) {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, line[5..45]);
                try haves.append(hash);
            } else if (std.mem.startsWith(u8, line, "deepen ")) {
                deepen_depth = std.fmt.parseInt(u32, line[7..], 10) catch 0;
            }
        }

        if (wants.items.len == 0) {
            try PktLine.appendFlush(output);
            return;
        }

        // Shallow info
        if (deepen_depth > 0) {
            for (wants.items) |want_hash| {
                var boundary = try self.computeShallowBoundary(&want_hash, deepen_depth);
                defer {
                    for (boundary.items) |b| self.allocator.free(b);
                    boundary.deinit();
                }
                for (boundary.items) |commit_hash| {
                    const sline = try std.fmt.allocPrint(self.allocator, "shallow {s}\n", .{commit_hash});
                    defer self.allocator.free(sline);
                    try PktLine.appendTo(output, sline);
                }
            }
        }

        // In v2, the server sends "packfile\n" before the pack data section
        try PktLine.appendTo(output, "packfile\n");

        // Generate pack data
        const pack_data = try self.generatePackData(wants.items, haves.items);
        defer self.allocator.free(pack_data);

        // v2 always uses side-band-64k for the packfile section
        try appendSideBand(output, SIDEBAND_DATA, pack_data);
        try appendSideBand(output, SIDEBAND_PROGRESS, "Counting objects done.\n");
        try PktLine.appendFlush(output);
    }

    // ====================================================================
    // Pack generation  (shared by upload-pack and v2 fetch)
    // ====================================================================

    /// Generate a PACK stream containing all objects reachable from `wants`
    /// that are NOT reachable from `haves`.
    fn generatePackData(self: *WasmGitServer, wants: [][40]u8, haves: [][40]u8) ![]u8 {
        // Build the "already have" set
        var have_set = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = have_set.keyIterator();
            while (it.next()) |k| self.allocator.free(@constCast(k.*));
            have_set.deinit();
        }

        for (haves) |have| {
            self.walkReachable(&have, &have_set) catch {};
        }

        // Build the "want" set
        var want_set = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = want_set.keyIterator();
            while (it.next()) |k| self.allocator.free(@constCast(k.*));
            want_set.deinit();
        }
        var want_list = std.array_list.Managed([]const u8).init(self.allocator);
        defer want_list.deinit();

        for (wants) |want| {
            self.walkReachableCollect(&want, &want_set, &want_list) catch {};
        }

        // Remove objects the client already has
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

        return try self.buildPackFromObjects(want_list.items);
    }

    /// Walk all objects reachable from `start_hash`, adding them to `set`.
    fn walkReachable(self: *WasmGitServer, start_hash: *const [40]u8, set: *std.StringHashMap(void)) !void {
        var worklist = std.array_list.Managed([40]u8).init(self.allocator);
        defer worklist.deinit();
        try worklist.append(start_hash.*);

        while (worklist.items.len > 0) {
            const hash = worklist.pop().?;
            if (set.contains(&hash)) continue;

            var obj = self.storage.readObject(&hash) catch continue;
            defer obj.deinit();

            const key = try self.allocator.dupe(u8, &hash);
            try set.put(key, {});

            try self.enqueueChildren(obj.obj_type, obj.data, &worklist);
        }
    }

    /// Walk all objects reachable from `start_hash`, adding to both `set`
    /// and `list` (list preserves order for pack generation).
    fn walkReachableCollect(
        self: *WasmGitServer,
        start_hash: *const [40]u8,
        set: *std.StringHashMap(void),
        list: *std.array_list.Managed([]const u8),
    ) !void {
        var worklist = std.array_list.Managed([40]u8).init(self.allocator);
        defer worklist.deinit();
        try worklist.append(start_hash.*);

        while (worklist.items.len > 0) {
            const hash = worklist.pop().?;
            if (set.contains(&hash)) continue;

            var obj = self.storage.readObject(&hash) catch continue;
            defer obj.deinit();

            const key = try self.allocator.dupe(u8, &hash);
            try set.put(key, {});
            try list.append(key);

            try self.enqueueChildren(obj.obj_type, obj.data, &worklist);
        }
    }

    /// Parse an object's data and enqueue child object hashes for traversal.
    fn enqueueChildren(
        _: *WasmGitServer,
        obj_type: objects.ObjectType,
        data: []const u8,
        worklist: *std.array_list.Managed([40]u8),
    ) !void {
        switch (obj_type) {
            .commit => {
                // Extract tree and parent hashes from the header portion
                var line_iter = std.mem.splitScalar(u8, data, '\n');
                while (line_iter.next()) |line| {
                    if (line.len == 0) break; // blank line = end of headers
                    if (std.mem.startsWith(u8, line, "tree ") and line.len >= 45) {
                        var hash: [40]u8 = undefined;
                        @memcpy(&hash, line[5..45]);
                        try worklist.append(hash);
                    } else if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                        var hash: [40]u8 = undefined;
                        @memcpy(&hash, line[7..47]);
                        try worklist.append(hash);
                    }
                }
            },
            .tree => {
                // Tree entries: "<mode> <name>\0<20-byte-sha1>"
                var pos: usize = 0;
                while (pos < data.len) {
                    const null_pos = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse break;
                    if (null_pos + 21 > data.len) break;
                    const sha_bytes = data[null_pos + 1 .. null_pos + 21];
                    var hex: [40]u8 = undefined;
                    for (sha_bytes, 0..) |b, idx| {
                        const hc = "0123456789abcdef";
                        hex[idx * 2] = hc[b >> 4];
                        hex[idx * 2 + 1] = hc[b & 0xf];
                    }
                    try worklist.append(hex);
                    pos = null_pos + 21;
                }
            },
            .tag => {
                var line_iter = std.mem.splitScalar(u8, data, '\n');
                while (line_iter.next()) |line| {
                    if (line.len == 0) break;
                    if (std.mem.startsWith(u8, line, "object ") and line.len >= 47) {
                        var hash: [40]u8 = undefined;
                        @memcpy(&hash, line[7..47]);
                        try worklist.append(hash);
                    }
                }
            },
            .blob => {},
        }
    }

    /// Build a valid PACK byte stream from a list of object hashes.
    fn buildPackFromObjects(self: *WasmGitServer, object_hashes: []const []const u8) ![]u8 {
        var pack = std.array_list.Managed(u8).init(self.allocator);
        errdefer pack.deinit();

        // PACK header
        try pack.appendSlice("PACK");
        const version: u32 = 2;
        try pack.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, version)));
        // Placeholder for object count
        const count_pos = pack.items.len;
        try pack.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));

        var actual_count: u32 = 0;

        for (object_hashes) |hash| {
            if (hash.len != 40) continue;

            var obj = self.storage.readObject(hash[0..40]) catch continue;
            defer obj.deinit();

            const type_num: u8 = switch (obj.obj_type) {
                .commit => 1,
                .tree => 2,
                .blob => 3,
                .tag => 4,
            };

            // Encode object header (variable-length encoding)
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

            // Compress object data with zlib
            const compressed = objects.cCompressSlice(self.allocator, obj.data) catch continue;
            defer self.allocator.free(compressed);
            try pack.appendSlice(compressed);
            actual_count += 1;
        }

        // Patch the object count
        const count_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, actual_count));
        @memcpy(pack.items[count_pos..][0..4], &count_bytes);

        // SHA-1 checksum of entire pack
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(pack.items);
        const checksum = sha1.finalResult();
        try pack.appendSlice(&checksum);

        return pack.toOwnedSlice();
    }

    // ====================================================================
    // Receive-pack helpers
    // ====================================================================

    /// Parse a PACK stream and store each object via HostCallbackStorage.
    fn ingestPack(self: *WasmGitServer, pack_data: []const u8) !void {
        if (pack_data.len < 12) return error.InvalidPackData;
        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackData;

        const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

        var pos: usize = 12;
        var obj_count: u32 = 0;
        while (obj_count < num_objects and pos < pack_data.len -| 20) : (obj_count += 1) {
            // Decode variable-length header
            var c = pack_data[pos];
            pos += 1;
            const obj_type_num: u8 = (c >> 4) & 0x07;
            var obj_size: u64 = c & 0x0F;
            var shift: u6 = 4;
            while (c & 0x80 != 0 and pos < pack_data.len) {
                c = pack_data[pos];
                pos += 1;
                obj_size |= @as(u64, c & 0x7F) << shift;
                shift +|= 7;
            }

            // Skip OFS_DELTA / REF_DELTA base reference bytes
            if (obj_type_num == 6) {
                // OFS_DELTA: variable-length negative offset
                c = pack_data[pos];
                pos += 1;
                while (c & 0x80 != 0 and pos < pack_data.len) {
                    c = pack_data[pos];
                    pos += 1;
                }
                // For OFS_DELTA we'd need to resolve the base — skip for now
                const compressed = pack_data[pos..@min(pos + obj_size + 4096, pack_data.len)];
                const decomp = objects.cDecompressWithConsumed(self.allocator, compressed, @intCast(@min(obj_size, 1 << 24))) orelse continue;
                defer self.allocator.free(decomp.data);
                pos += decomp.consumed;
                continue;
            } else if (obj_type_num == 7) {
                // REF_DELTA: 20-byte base SHA
                pos += 20;
                const compressed = pack_data[pos..@min(pos + obj_size + 4096, pack_data.len)];
                const decomp = objects.cDecompressWithConsumed(self.allocator, compressed, @intCast(@min(obj_size, 1 << 24))) orelse continue;
                defer self.allocator.free(decomp.data);
                pos += decomp.consumed;
                continue;
            }

            // Regular object (types 1-4)
            if (obj_type_num < 1 or obj_type_num > 4) {
                // Unknown type — try to skip by decompressing
                const compressed = pack_data[pos..@min(pos + obj_size + 4096, pack_data.len)];
                const decomp = objects.cDecompressWithConsumed(self.allocator, compressed, @intCast(@min(obj_size, 1 << 24))) orelse break;
                defer self.allocator.free(decomp.data);
                pos += decomp.consumed;
                continue;
            }

            const compressed = pack_data[pos..@min(pos + obj_size + 4096, pack_data.len)];
            const decomp = objects.cDecompressWithConsumed(self.allocator, compressed, @intCast(@min(obj_size, 1 << 24))) orelse continue;
            pos += decomp.consumed;

            const obj_type: objects.ObjectType = switch (obj_type_num) {
                1 => .commit,
                2 => .tree,
                3 => .blob,
                4 => .tag,
                else => unreachable,
            };

            // Store via host callbacks
            _ = self.storage.writeObject(obj_type, decomp.data) catch {
                self.allocator.free(decomp.data);
                continue;
            };
            self.allocator.free(decomp.data);
        }
    }

    /// Apply a single ref update via HostCallbackStorage.
    fn applyRefUpdate(self: *WasmGitServer, old_hash: *const [40]u8, new_hash: *const [40]u8, ref_name: []const u8) !void {
        const zero_hash = "0000000000000000000000000000000000000000";

        if (std.mem.eql(u8, new_hash, zero_hash)) {
            // Delete
            try self.storage.deleteRef(ref_name);
            return;
        }

        // Optionally verify old hash
        if (!std.mem.eql(u8, old_hash, zero_hash)) {
            const current = try self.storage.readRef(ref_name);
            if (current) |cur_hash| {
                if (!std.mem.eql(u8, &cur_hash, old_hash)) {
                    return error.RefUpdateRejected;
                }
            } else {
                return error.RefUpdateRejected;
            }
        }

        // Set new value
        try self.storage.writeRef(ref_name, new_hash.*);
    }

    // ====================================================================
    // Shallow boundary computation
    // ====================================================================

    /// Walk commits from `start_hash` and return those at depth > `max_depth`
    /// (the shallow boundary).
    fn computeShallowBoundary(
        self: *WasmGitServer,
        start_hash: *const [40]u8,
        max_depth: u32,
    ) !std.array_list.Managed([]const u8) {
        const Entry = struct { hash: [40]u8, depth: u32 };

        var worklist = std.array_list.Managed(Entry).init(self.allocator);
        defer worklist.deinit();
        var visited = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = visited.keyIterator();
            while (it.next()) |k| self.allocator.free(@constCast(k.*));
            visited.deinit();
        }
        var boundary = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer {
            for (boundary.items) |b| self.allocator.free(b);
            boundary.deinit();
        }

        try worklist.append(.{ .hash = start_hash.*, .depth = 1 });

        while (worklist.items.len > 0) {
            const entry = worklist.orderedRemove(0);

            if (visited.contains(&entry.hash)) continue;
            const key = try self.allocator.dupe(u8, &entry.hash);
            try visited.put(key, {});

            if (entry.depth > max_depth) {
                try boundary.append(try self.allocator.dupe(u8, &entry.hash));
                continue;
            }

            var obj = self.storage.readObject(&entry.hash) catch continue;
            defer obj.deinit();

            if (obj.obj_type != .commit) continue;

            var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
            while (line_iter.next()) |line| {
                if (line.len == 0) break;
                if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                    var hash: [40]u8 = undefined;
                    @memcpy(&hash, line[7..47]);
                    try worklist.append(.{ .hash = hash, .depth = entry.depth + 1 });
                }
            }
        }

        return boundary;
    }
};
