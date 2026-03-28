const std = @import("std");
const objects = @import("objects.zig");
const refs = @import("refs.zig");

const Mark = struct {
    hash: [40]u8,
};

pub fn run(allocator: std.mem.Allocator, platform_impl: anytype, options: Options, git_dir: []const u8) !void {

    var state = State(@TypeOf(platform_impl)).init(allocator, git_dir, platform_impl);
    defer state.deinit();

    // Import marks if requested
    if (options.import_marks) |path| {
        state.loadMarks(path) catch {};
    }
    if (options.import_marks_if_exists) |path| {
        state.loadMarks(path) catch {};
    }

    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdin_content = stdin_file.readToEndAlloc(allocator, 512 * 1024 * 1024) catch {
        try platform_impl.writeStderr("fatal: read error\n");
        std.process.exit(1);
    };
    defer allocator.free(stdin_content);

    var pos: usize = 0;
    var saw_done = false;

    while (pos < stdin_content.len) {
        // Skip blank lines and comments
        if (stdin_content[pos] == '\n') {
            pos += 1;
            continue;
        }
        if (stdin_content[pos] == '#') {
            pos = skipLine(stdin_content, pos);
            continue;
        }

        const line_end = std.mem.indexOfPos(u8, stdin_content, pos, "\n") orelse stdin_content.len;
        const line = stdin_content[pos..line_end];

        if (std.mem.eql(u8, line, "done")) {
            saw_done = true;
            break;
        } else if (std.mem.startsWith(u8, line, "blob")) {
            pos = line_end + 1;
            pos = try state.parseBlob(stdin_content, pos);
        } else if (std.mem.startsWith(u8, line, "commit ")) {
            pos = line_end + 1;
            pos = try state.parseCommit(stdin_content, pos, line[7..]);
        } else if (std.mem.startsWith(u8, line, "tag ")) {
            pos = line_end + 1;
            pos = try state.parseTag(stdin_content, pos, line[4..]);
        } else if (std.mem.startsWith(u8, line, "reset ")) {
            pos = line_end + 1;
            pos = try state.parseReset(stdin_content, pos, line[6..]);
        } else if (std.mem.startsWith(u8, line, "feature ")) {
            pos = line_end + 1;
            const feature = line[8..];
            if (std.mem.eql(u8, feature, "done")) {
                options.expect_done.* = true;
            }
            // Accept other features silently
        } else if (std.mem.startsWith(u8, line, "progress ")) {
            // Output progress message to stderr
            try platform_impl.writeStderr(line);
            try platform_impl.writeStderr("\n");
            pos = line_end + 1;
        } else if (std.mem.startsWith(u8, line, "checkpoint")) {
            pos = line_end + 1;
            // Checkpoint - flush everything (no-op for us since we write immediately)
        } else if (std.mem.startsWith(u8, line, "cat-blob ")) {
            // cat-blob - output blob content to stdout
            pos = line_end + 1;
            const ref = line[9..];
            state.catBlob(ref) catch {};
        } else if (std.mem.startsWith(u8, line, "ls ")) {
            pos = line_end + 1;
            // ls command - skip for now
        } else if (std.mem.startsWith(u8, line, "option ")) {
            pos = line_end + 1;
            // Ignore options
        } else {
            pos = line_end + 1;
        }
    }

    if (options.expect_done.* and !saw_done) {
        // "done" feature requested but not found is already handled by --done flag
    }

    // Export marks if requested
    if (options.export_marks) |path| {
        state.saveMarks(path) catch {};
    }

    // Print stats to stderr
    if (!options.quiet) {
        const stats_msg = std.fmt.allocPrint(allocator, "fast-import statistics:\n", .{}) catch return;
        defer allocator.free(stats_msg);
        // Minimal stats
    }
}

pub const Options = struct {
    done: bool = false,
    force: bool = false,
    quiet: bool = false,
    stats: bool = true,
    import_marks: ?[]const u8 = null,
    import_marks_if_exists: ?[]const u8 = null,
    export_marks: ?[]const u8 = null,
    expect_done: *bool,
};

fn findGitDir(allocator: std.mem.Allocator) ?[]const u8 {
    // Check GIT_DIR env
    const env_map = std.process.getEnvMap(allocator) catch return null;
    defer {
        var m = env_map;
        m.deinit();
    }
    if (env_map.get("GIT_DIR")) |gd| {
        return allocator.dupe(u8, gd) catch null;
    }

    // Walk up looking for .git
    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch return null;

    var path = allocator.dupe(u8, cwd) catch return null;
    while (true) {
        const git_path = std.fs.path.join(allocator, &.{ path, ".git" }) catch {
            allocator.free(path);
            return null;
        };
        defer allocator.free(git_path);

        if (std.fs.cwd().access(git_path, .{})) |_| {
            // Check if it's a file (gitdir: reference) or directory
            const stat = std.fs.cwd().statFile(git_path) catch {
                return allocator.dupe(u8, git_path) catch null;
            };
            if (stat.kind == .directory) {
                return allocator.dupe(u8, git_path) catch null;
            }
            // It's a file - read gitdir reference
            const content = std.fs.cwd().readFileAlloc(allocator, git_path, 4096) catch {
                return allocator.dupe(u8, git_path) catch null;
            };
            defer allocator.free(content);
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "gitdir: ")) {
                const ref_path = trimmed[8..];
                if (std.fs.path.isAbsolute(ref_path)) {
                    return allocator.dupe(u8, ref_path) catch null;
                }
                const parent = std.fs.path.dirname(git_path) orelse ".";
                return std.fs.path.join(allocator, &.{ parent, ref_path }) catch null;
            }
            return allocator.dupe(u8, git_path) catch null;
        } else |_| {}

        const parent = std.fs.path.dirname(path) orelse {
            allocator.free(path);
            return null;
        };
        const new_path = allocator.dupe(u8, parent) catch {
            allocator.free(path);
            return null;
        };
        allocator.free(path);
        path = new_path;
        if (std.mem.eql(u8, path, "/") or path.len == 0) {
            allocator.free(path);
            return null;
        }
    }
}

fn State(comptime PlatformType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        git_dir: []const u8,
        platform: PlatformType,
        marks: std.AutoHashMap(u64, [40]u8),
        // Track last commit for each ref
        ref_commits: std.StringHashMap([40]u8),

        fn init(allocator: std.mem.Allocator, git_dir: []const u8, platform: PlatformType) Self {
            return .{
                .allocator = allocator,
                .git_dir = git_dir,
                .platform = platform,
                .marks = std.AutoHashMap(u64, [40]u8).init(allocator),
                .ref_commits = std.StringHashMap([40]u8).init(allocator),
            };
        }

        fn deinit(self: *Self) void {
            self.marks.deinit();
            var it = self.ref_commits.keyIterator();
            while (it.next()) |key| {
                self.allocator.free(key.*);
            }
            self.ref_commits.deinit();
        }

        fn resolveDataref(self: *Self, dataref: []const u8) ?[40]u8 {
            if (dataref.len > 0 and dataref[0] == ':') {
                // Mark reference
                const mark_id = std.fmt.parseInt(u64, dataref[1..], 10) catch return null;
                return self.marks.get(mark_id);
            } else if (dataref.len == 40) {
                // Direct SHA1
                var hash: [40]u8 = undefined;
                @memcpy(&hash, dataref);
                return hash;
            }
            return null;
        }

        fn resolveRef(self: *Self, ref_name: []const u8) ?[40]u8 {
            // Check our local cache first
            if (self.ref_commits.get(ref_name)) |hash| {
                return hash;
            }
            // Try reading from disk
            const hash = refs.getRef(self.git_dir, ref_name, self.platform, self.allocator) catch return null;
            defer self.allocator.free(hash);
            var result: [40]u8 = undefined;
            @memcpy(&result, hash.ptr);
            return result;
        }

        fn parseBlob(self: *Self, data: []const u8, start_pos: usize) !usize {
            var pos = start_pos;
            var mark_id: ?u64 = null;

            // Check for mark
            if (pos < data.len) {
                const line_end = std.mem.indexOfPos(u8, data, pos, "\n") orelse data.len;
                const line = data[pos..line_end];
                if (std.mem.startsWith(u8, line, "mark :")) {
                    mark_id = std.fmt.parseInt(u64, line[6..], 10) catch null;
                    pos = line_end + 1;
                }
            }

            // Read data
            const blob_data = try self.readData(data, pos);
            pos = blob_data.end_pos;
            defer self.allocator.free(blob_data.content);

            // Store blob object
            const blob_obj = objects.GitObject.init(.blob, blob_data.content);
            const hash_str = try blob_obj.store(self.git_dir, self.platform, self.allocator);
            defer self.allocator.free(hash_str);

            if (mark_id) |mid| {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, hash_str.ptr);
                try self.marks.put(mid, hash);
            }

            return pos;
        }

        fn parseCommit(self: *Self, data: []const u8, start_pos: usize, ref_name: []const u8) !usize {
            var pos = start_pos;
            var mark_id: ?u64 = null;
            var author_line: ?[]const u8 = null;
            var committer_line: ?[]const u8 = null;
            var encoding_line: ?[]const u8 = null;
            var from_ref: ?[]const u8 = null;
            var merge_refs = std.array_list.Managed([]const u8).init(self.allocator);
            defer merge_refs.deinit();

            // Parse headers
            while (pos < data.len) {
                const line_end = std.mem.indexOfPos(u8, data, pos, "\n") orelse data.len;
                const line = data[pos..line_end];

                if (std.mem.startsWith(u8, line, "mark :")) {
                    mark_id = std.fmt.parseInt(u64, line[6..], 10) catch null;
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "author ")) {
                    author_line = line[7..];
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "committer ")) {
                    committer_line = line[10..];
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "encoding ")) {
                    encoding_line = line[9..];
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "from ")) {
                    from_ref = line[5..];
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "merge ")) {
                    try merge_refs.append(line[6..]);
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "data ")) {
                    break;
                } else if (std.mem.startsWith(u8, line, "original-oid ")) {
                    pos = line_end + 1;
                } else {
                    break;
                }
            }

            // Read commit message
            const msg_data = try self.readData(data, pos);
            pos = msg_data.end_pos;
            const message = msg_data.content;
            defer self.allocator.free(message);

            // Resolve parent commit
            var parent_hash: ?[40]u8 = null;
            if (from_ref) |fr| {
                if (self.resolveDataref(fr)) |h| {
                    parent_hash = h;
                } else {
                    // Try as ref name (e.g., refs/heads/main^0)
                    var clean_ref = fr;
                    if (std.mem.endsWith(u8, clean_ref, "^0")) {
                        clean_ref = clean_ref[0 .. clean_ref.len - 2];
                    }
                    if (self.resolveRef(clean_ref)) |h| {
                        parent_hash = h;
                    }
                }
            } else {
                // Implicit from: use last commit on this ref
                if (self.ref_commits.get(ref_name)) |h| {
                    parent_hash = h;
                } else if (self.resolveRef(ref_name)) |h| {
                    parent_hash = h;
                }
            }

            // Build tree from file operations
            // Start with parent tree if any
            var tree_entries = std.StringArrayHashMap(TreeFileEntry).init(self.allocator);
            defer {
                var it = tree_entries.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.hash);
                    self.allocator.free(entry.value_ptr.mode);
                }
                tree_entries.deinit();
            }

            var deleteall = false;

            // Load parent tree entries if we have a parent
            if (parent_hash) |ph| {
                try self.loadTreeEntries(&tree_entries, &ph);
            }

            // Parse file commands (M, D, deleteall, etc.)
            while (pos < data.len) {
                // Skip blank lines between file commands
                if (data[pos] == '\n') {
                    pos += 1;
                    continue;
                }

                const line_end = std.mem.indexOfPos(u8, data, pos, "\n") orelse data.len;
                const line = data[pos..line_end];

                if (line.len == 0) {
                    pos = line_end + 1;
                    continue;
                }

                if (std.mem.startsWith(u8, line, "M ")) {
                    pos = line_end + 1;
                    // M <mode> <dataref> <path>
                    // or M <mode> inline <path> followed by data
                    const rest = line[2..];
                    const space1 = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
                    const raw_mode = rest[0..space1];
                    // Normalize mode: 644 -> 100644, 755 -> 100755, etc.
                    const mode = normalizeMode(raw_mode);
                    const after_mode = rest[space1 + 1 ..];
                    const space2 = std.mem.indexOfScalar(u8, after_mode, ' ') orelse continue;
                    const dataref = after_mode[0..space2];
                    const path = unquotePath(after_mode[space2 + 1 ..], self.allocator) catch continue;

                    var file_hash: [40]u8 = undefined;
                    if (std.mem.eql(u8, dataref, "inline")) {
                        // Read inline data
                        const inline_data = self.readData(data, pos) catch continue;
                        pos = inline_data.end_pos;
                        defer self.allocator.free(inline_data.content);

                        const blob_obj = objects.GitObject.init(.blob, inline_data.content);
                        const h = blob_obj.store(self.git_dir, self.platform, self.allocator) catch continue;
                        defer self.allocator.free(h);
                        @memcpy(&file_hash, h.ptr);
                    } else {
                        const resolved = self.resolveDataref(dataref) orelse continue;
                        file_hash = resolved;
                    }

                    // Remove old entry if exists
                    if (tree_entries.fetchSwapRemove(path)) |old| {
                        self.allocator.free(old.key);
                        self.allocator.free(old.value.hash);
                        self.allocator.free(old.value.mode);
                        // path was freed as the key for a non-owned version
                    }

                    const owned_path = self.allocator.dupe(u8, path) catch continue;
                    const owned_mode = self.allocator.dupe(u8, mode) catch {
                        self.allocator.free(owned_path);
                        continue;
                    };
                    const owned_hash = self.allocator.dupe(u8, &file_hash) catch {
                        self.allocator.free(owned_path);
                        self.allocator.free(owned_mode);
                        continue;
                    };

                    // Free the unquoted path if it was allocated
                    if (path.ptr != after_mode[space2 + 1 ..].ptr) {
                        self.allocator.free(path);
                    }

                    tree_entries.put(owned_path, .{ .mode = owned_mode, .hash = owned_hash }) catch {
                        self.allocator.free(owned_path);
                        self.allocator.free(owned_mode);
                        self.allocator.free(owned_hash);
                        continue;
                    };
                } else if (std.mem.startsWith(u8, line, "D ")) {
                    pos = line_end + 1;
                    const path = line[2..];
                    if (tree_entries.fetchSwapRemove(path)) |old| {
                        self.allocator.free(old.key);
                        self.allocator.free(old.value.hash);
                        self.allocator.free(old.value.mode);
                    }
                } else if (std.mem.eql(u8, line, "deleteall")) {
                    pos = line_end + 1;
                    deleteall = true;
                    // Clear all entries
                    var it = tree_entries.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.hash);
                        self.allocator.free(entry.value_ptr.mode);
                    }
                    tree_entries.clearRetainingCapacity();
                } else if (std.mem.startsWith(u8, line, "N ")) {
                    // Note command - skip
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "C ") or std.mem.startsWith(u8, line, "R ")) {
                    // Copy/Rename - skip for now
                    pos = line_end + 1;
                } else {
                    // Not a file command - this line belongs to the next command
                    break;
                }
            }

            // Build tree object(s)
            const tree_hash = try self.buildTree(&tree_entries);
            defer self.allocator.free(tree_hash);

            // Build parent list
            var parents = std.array_list.Managed([]const u8).init(self.allocator);
            defer parents.deinit();

            if (parent_hash) |*ph| {
                try parents.append(ph);
            }
            for (merge_refs.items) |mr| {
                if (self.resolveDataref(mr)) |*h| {
                    // Need to store this somewhere stable
                    const heap_hash = try self.allocator.create([40]u8);
                    heap_hash.* = h.*;
                    try parents.append(heap_hash);
                }
            }
            defer {
                // Free merge parent hashes (skip first which is stack-allocated)
                for (parents.items[if (parent_hash != null) @as(usize, 1) else 0..]) |p| {
                    const ptr: *[40]u8 = @constCast(@ptrCast(@alignCast(p.ptr)));
                    self.allocator.destroy(ptr);
                }
            }

            // Use author if provided, otherwise use committer
            const author = author_line orelse committer_line orelse "Unknown <unknown> 0 +0000";
            const committer = committer_line orelse "Unknown <unknown> 0 +0000";

            // Create commit message - trim trailing newline if data had one
            var msg = message;
            if (msg.len > 0 and msg[msg.len - 1] == '\n') {
                msg = msg[0 .. msg.len - 1];
            }

            // Build commit content manually to support encoding header
            var commit_content = std.array_list.Managed(u8).init(self.allocator);
            defer commit_content.deinit();

            try commit_content.writer().print("tree {s}\n", .{tree_hash});
            for (parents.items) |p| {
                try commit_content.writer().print("parent {s}\n", .{p[0..40]});
            }
            try commit_content.writer().print("author {s}\n", .{author});
            try commit_content.writer().print("committer {s}\n", .{committer});
            if (encoding_line) |enc| {
                try commit_content.writer().print("encoding {s}\n", .{enc});
            }
            try commit_content.writer().print("\n{s}\n", .{msg});

            const commit_data = try commit_content.toOwnedSlice();
            defer self.allocator.free(commit_data);

            const commit_obj = objects.GitObject.init(.commit, commit_data);
            const commit_hash = try commit_obj.store(self.git_dir, self.platform, self.allocator);
            defer self.allocator.free(commit_hash);

            // Store mark
            if (mark_id) |mid| {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, commit_hash.ptr);
                try self.marks.put(mid, hash);
            }

            // Update ref
            const ref_copy = try self.allocator.dupe(u8, ref_name);
            var hash: [40]u8 = undefined;
            @memcpy(&hash, commit_hash.ptr);

            // Remove old key if present
            if (self.ref_commits.fetchRemove(ref_name)) |old| {
                self.allocator.free(old.key);
            }
            try self.ref_commits.put(ref_copy, hash);

            try refs.updateRef(self.git_dir, ref_name, commit_hash, self.platform, self.allocator);

            return pos;
        }

        fn parseTag(self: *Self, data: []const u8, start_pos: usize, tag_name: []const u8) !usize {
            var pos = start_pos;
            var from_ref: ?[]const u8 = null;
            var tagger_line: ?[]const u8 = null;
            var mark_id: ?u64 = null;

            // Parse headers
            while (pos < data.len) {
                const line_end = std.mem.indexOfPos(u8, data, pos, "\n") orelse data.len;
                const line = data[pos..line_end];

                if (std.mem.startsWith(u8, line, "from ")) {
                    from_ref = line[5..];
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "tagger ")) {
                    tagger_line = line[7..];
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "mark :")) {
                    mark_id = std.fmt.parseInt(u64, line[6..], 10) catch null;
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "original-oid ")) {
                    pos = line_end + 1;
                } else if (std.mem.startsWith(u8, line, "data ")) {
                    break;
                } else {
                    break;
                }
            }

            // Read tag message
            const msg_data = try self.readData(data, pos);
            pos = msg_data.end_pos;
            defer self.allocator.free(msg_data.content);

            // Resolve from ref
            var target_hash: [40]u8 = undefined;
            if (from_ref) |fr| {
                if (self.resolveDataref(fr)) |h| {
                    target_hash = h;
                } else {
                    var clean_ref = fr;
                    if (std.mem.endsWith(u8, clean_ref, "^0")) {
                        clean_ref = clean_ref[0 .. clean_ref.len - 2];
                    }
                    if (self.resolveRef(clean_ref)) |h| {
                        target_hash = h;
                    } else {
                        return pos; // Can't resolve target
                    }
                }
            } else {
                return pos;
            }

            // Determine target type
            const target_obj = objects.GitObject.load(&target_hash, self.git_dir, self.platform, self.allocator) catch return pos;
            defer target_obj.deinit(self.allocator);

            const type_str = switch (target_obj.type) {
                .commit => "commit",
                .tree => "tree",
                .blob => "blob",
                .tag => "tag",
            };

            // Build tag object
            var tag_content = std.array_list.Managed(u8).init(self.allocator);
            defer tag_content.deinit();

            try tag_content.writer().print("object {s}\ntype {s}\ntag {s}\n", .{ &target_hash, type_str, tag_name });
            if (tagger_line) |tagger| {
                try tag_content.writer().print("tagger {s}\n", .{tagger});
            }
            var msg = msg_data.content;
            if (msg.len > 0 and msg[msg.len - 1] == '\n') {
                msg = msg[0 .. msg.len - 1];
            }
            try tag_content.writer().print("\n{s}\n", .{msg});

            const tag_data = try tag_content.toOwnedSlice();
            defer self.allocator.free(tag_data);

            const tag_obj = objects.GitObject.init(.tag, tag_data);
            const tag_hash = try tag_obj.store(self.git_dir, self.platform, self.allocator);
            defer self.allocator.free(tag_hash);

            // Store mark
            if (mark_id) |mid| {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, tag_hash.ptr);
                try self.marks.put(mid, hash);
            }

            // Update ref
            const tag_ref = std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{tag_name}) catch return pos;
            defer self.allocator.free(tag_ref);

            try refs.updateRef(self.git_dir, tag_ref, tag_hash, self.platform, self.allocator);

            return pos;
        }

        fn parseReset(self: *Self, data: []const u8, start_pos: usize, ref_name: []const u8) !usize {
            var pos = start_pos;

            // Optional 'from' line
            if (pos < data.len) {
                const line_end = std.mem.indexOfPos(u8, data, pos, "\n") orelse data.len;
                const line = data[pos..line_end];

                if (std.mem.startsWith(u8, line, "from ")) {
                    const from_ref = line[5..];
                    pos = line_end + 1;

                    if (self.resolveDataref(from_ref)) |hash| {
                        try refs.updateRef(self.git_dir, ref_name, &hash, self.platform, self.allocator);
                        // Update local cache
                        const ref_copy = try self.allocator.dupe(u8, ref_name);
                        if (self.ref_commits.fetchRemove(ref_name)) |old| {
                            self.allocator.free(old.key);
                        }
                        try self.ref_commits.put(ref_copy, hash);
                    } else {
                        // Try as ref name
                        var clean_ref = from_ref;
                        if (std.mem.endsWith(u8, clean_ref, "^0")) {
                            clean_ref = clean_ref[0 .. clean_ref.len - 2];
                        }
                        if (self.resolveRef(clean_ref)) |hash| {
                            try refs.updateRef(self.git_dir, ref_name, &hash, self.platform, self.allocator);
                            const ref_copy = try self.allocator.dupe(u8, ref_name);
                            if (self.ref_commits.fetchRemove(ref_name)) |old| {
                                self.allocator.free(old.key);
                            }
                            try self.ref_commits.put(ref_copy, hash);
                        }
                    }
                } else if (line.len == 0) {
                    pos = line_end + 1;
                }
            }

            // Skip blank line after reset
            if (pos < data.len and data[pos] == '\n') {
                pos += 1;
            }

            return pos;
        }

        const DataResult = struct {
            content: []u8,
            end_pos: usize,
        };

        fn readData(self: *Self, data: []const u8, start_pos: usize) !DataResult {
            var pos = start_pos;
            if (pos >= data.len) return DataResult{ .content = try self.allocator.alloc(u8, 0), .end_pos = pos };

            const line_end = std.mem.indexOfPos(u8, data, pos, "\n") orelse data.len;
            const line = data[pos..line_end];

            if (std.mem.startsWith(u8, line, "data <<")) {
                // Delimited format
                const delim = line[7..];
                pos = line_end + 1;

                // Find end delimiter
                var content = std.array_list.Managed(u8).init(self.allocator);
                defer content.deinit();

                while (pos < data.len) {
                    const next_end = std.mem.indexOfPos(u8, data, pos, "\n") orelse data.len;
                    const next_line = data[pos..next_end];
                    if (std.mem.eql(u8, next_line, delim)) {
                        pos = next_end + 1;
                        break;
                    }
                    if (content.items.len > 0) try content.append('\n');
                    try content.appendSlice(next_line);
                    pos = next_end + 1;
                }

                return DataResult{
                    .content = try content.toOwnedSlice(),
                    .end_pos = pos,
                };
            } else if (std.mem.startsWith(u8, line, "data ")) {
                // Exact byte count format
                const count_str = line[5..];
                const count = std.fmt.parseInt(usize, count_str, 10) catch 0;
                pos = line_end + 1;

                if (count == 0) {
                    return DataResult{ .content = try self.allocator.alloc(u8, 0), .end_pos = pos };
                }

                const end = @min(pos + count, data.len);
                const content = try self.allocator.dupe(u8, data[pos..end]);
                pos = end;

                // Skip LF after data if present
                if (pos < data.len and data[pos] == '\n') {
                    pos += 1;
                }

                return DataResult{ .content = content, .end_pos = pos };
            }

            return DataResult{ .content = try self.allocator.alloc(u8, 0), .end_pos = pos };
        }

        const TreeFileEntry = struct {
            mode: []u8,
            hash: []u8,
        };

        fn loadTreeEntries(self: *Self, entries: *std.StringArrayHashMap(TreeFileEntry), commit_hash: []const u8) !void {
            const commit_obj = objects.GitObject.load(commit_hash, self.git_dir, self.platform, self.allocator) catch return;
            defer commit_obj.deinit(self.allocator);

            // Extract tree hash from commit
            var tree_hash: ?[]const u8 = null;
            var line_iter = std.mem.splitScalar(u8, commit_obj.data, '\n');
            while (line_iter.next()) |line| {
                if (std.mem.startsWith(u8, line, "tree ")) {
                    tree_hash = line[5..];
                    break;
                }
            }

            if (tree_hash) |th| {
                try self.loadTreeEntriesRecursive(entries, th, "");
            }
        }

        fn loadTreeEntriesRecursive(self: *Self, entries: *std.StringArrayHashMap(TreeFileEntry), tree_hash: []const u8, prefix: []const u8) !void {
            const tree_obj = objects.GitObject.load(tree_hash, self.git_dir, self.platform, self.allocator) catch return;
            defer tree_obj.deinit(self.allocator);

            var tpos: usize = 0;
            while (tpos < tree_obj.data.len) {
                const space_pos = std.mem.indexOfPos(u8, tree_obj.data, tpos, " ") orelse break;
                const null_pos = std.mem.indexOfPos(u8, tree_obj.data, space_pos, &[_]u8{0}) orelse break;
                const mode = tree_obj.data[tpos..space_pos];
                const name = tree_obj.data[space_pos + 1 .. null_pos];
                if (null_pos + 21 > tree_obj.data.len) break;
                const hash_bytes = tree_obj.data[null_pos + 1 .. null_pos + 21];

                const hex_hash = std.fmt.bytesToHex(hash_bytes[0..20].*, .lower);

                const full_path = if (prefix.len > 0)
                    std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, name }) catch break
                else
                    self.allocator.dupe(u8, name) catch break;

                if (std.mem.eql(u8, mode, "40000")) {
                    // Recurse into subdirectory
                    self.loadTreeEntriesRecursive(entries, &hex_hash, full_path) catch {};
                    self.allocator.free(full_path);
                } else {
                    const owned_mode = self.allocator.dupe(u8, mode) catch {
                        self.allocator.free(full_path);
                        break;
                    };
                    const owned_hash = self.allocator.dupe(u8, &hex_hash) catch {
                        self.allocator.free(full_path);
                        self.allocator.free(owned_mode);
                        break;
                    };
                    entries.put(full_path, .{ .mode = owned_mode, .hash = owned_hash }) catch {
                        self.allocator.free(full_path);
                        self.allocator.free(owned_mode);
                        self.allocator.free(owned_hash);
                        break;
                    };
                }

                tpos = null_pos + 21;
            }
        }

        fn buildTree(self: *Self, entries: *std.StringArrayHashMap(TreeFileEntry)) ![]u8 {
            // Build a hierarchical tree structure
            // Group entries by top-level directory
            var dirs = std.StringHashMap(std.StringArrayHashMap(TreeFileEntry)).init(self.allocator);
            defer {
                var it = dirs.iterator();
                while (it.next()) |entry| {
                    // Don't free entries - they're borrowed
                    var map = entry.value_ptr.*;
                    map.deinit();
                }
                dirs.deinit();
            }

            var direct_entries = std.array_list.Managed(objects.TreeEntry).init(self.allocator);
            defer direct_entries.deinit();

            var it = entries.iterator();
            while (it.next()) |entry| {
                const path = entry.key_ptr.*;
                const value = entry.value_ptr.*;

                if (std.mem.indexOfScalar(u8, path, '/')) |slash_pos| {
                    const dir_name = path[0..slash_pos];
                    const rest = path[slash_pos + 1 ..];

                    var dir_map = dirs.getPtr(dir_name);
                    if (dir_map == null) {
                        const new_map = std.StringArrayHashMap(TreeFileEntry).init(self.allocator);
                        dirs.put(dir_name, new_map) catch continue;
                        dir_map = dirs.getPtr(dir_name);
                    }
                    if (dir_map) |dm| {
                        dm.put(rest, value) catch continue;
                    }
                } else {
                    try direct_entries.append(objects.TreeEntry{
                        .mode = value.mode,
                        .name = path,
                        .hash = value.hash,
                    });
                }
            }

            // Recursively build subtrees
            var dir_it = dirs.iterator();
            while (dir_it.next()) |dir_entry| {
                const dir_name = dir_entry.key_ptr.*;
                var sub_entries = dir_entry.value_ptr.*;
                const sub_hash = try self.buildTree(&sub_entries);

                try direct_entries.append(objects.TreeEntry{
                    .mode = "40000",
                    .name = dir_name,
                    .hash = sub_hash,
                });
            }

            // Sort entries by name (git requires sorted trees)
            std.sort.insertion(objects.TreeEntry, direct_entries.items, {}, struct {
                fn lessThan(_: void, a: objects.TreeEntry, b: objects.TreeEntry) bool {
                    // Git sorts tree entries with directories having trailing /
                    const a_name = a.name;
                    const b_name = b.name;
                    const a_is_dir = std.mem.eql(u8, a.mode, "40000");
                    const b_is_dir = std.mem.eql(u8, b.mode, "40000");

                    // For comparison, append '/' to directory names
                    if (a_is_dir and !b_is_dir) {
                        // Compare a_name/ with b_name
                        const order = std.mem.order(u8, a_name, b_name[0..@min(a_name.len, b_name.len)]);
                        if (order != .eq) return order == .lt;
                        if (a_name.len < b_name.len) return '/' < b_name[a_name.len];
                        return true; // a_name/ vs b_name (same prefix but a has /)
                    } else if (!a_is_dir and b_is_dir) {
                        const order = std.mem.order(u8, a_name[0..@min(a_name.len, b_name.len)], b_name);
                        if (order != .eq) return order == .lt;
                        if (a_name.len > b_name.len) return a_name[b_name.len] < '/';
                        return false;
                    }
                    return std.mem.order(u8, a_name, b_name) == .lt;
                }
            }.lessThan);

            // Create tree object
            const tree_obj = objects.createTreeObject(direct_entries.items, self.allocator) catch return error.OutOfMemory;
            defer tree_obj.deinit(self.allocator);
            const hash = try tree_obj.store(self.git_dir, self.platform, self.allocator);

            return hash;
        }

        fn catBlob(self: *Self, dataref: []const u8) !void {
            const hash = self.resolveDataref(dataref) orelse return;
            const obj = objects.GitObject.load(&hash, self.git_dir, self.platform, self.allocator) catch return;
            defer obj.deinit(self.allocator);

            // Output: <sha1> SP 'blob' SP <size> LF <data> LF
            const output = try std.fmt.allocPrint(self.allocator, "{s} blob {d}\n{s}\n", .{ &hash, obj.data.len, obj.data });
            defer self.allocator.free(output);
            try self.platform.writeStdout(output);
        }

        fn loadMarks(self: *Self, path: []const u8) !void {
            const content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch return;
            defer self.allocator.free(content);

            var line_iter = std.mem.splitScalar(u8, content, '\n');
            while (line_iter.next()) |line| {
                if (line.len == 0) continue;
                // Format: :markid SHA1
                if (line[0] != ':') continue;
                const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
                const mark_id = std.fmt.parseInt(u64, line[1..space], 10) catch continue;
                const hash_str = line[space + 1 ..];
                if (hash_str.len < 40) continue;
                var hash: [40]u8 = undefined;
                @memcpy(&hash, hash_str[0..40]);
                try self.marks.put(mark_id, hash);
            }
        }

        fn saveMarks(self: *Self, path: []const u8) !void {
            var file = try std.fs.cwd().createFile(path, .{});
            defer file.close();

            var it = self.marks.iterator();
            while (it.next()) |entry| {
                var buf: [64]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, ":{d} {s}\n", .{ entry.key_ptr.*, &entry.value_ptr.* }) catch continue;
                file.writeAll(line) catch continue;
            }
        }
    };
}

fn skipLine(data: []const u8, pos: usize) usize {
    const end = std.mem.indexOfPos(u8, data, pos, "\n") orelse data.len;
    return end + 1;
}

fn unquotePath(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') {
        // Unquote C-style string
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();

        var i: usize = 1;
        while (i < path.len - 1) {
            if (path[i] == '\\' and i + 1 < path.len - 1) {
                i += 1;
                switch (path[i]) {
                    'n' => try result.append('\n'),
                    't' => try result.append('\t'),
                    '\\' => try result.append('\\'),
                    '"' => try result.append('"'),
                    else => {
                        try result.append('\\');
                        try result.append(path[i]);
                    },
                }
            } else {
                try result.append(path[i]);
            }
            i += 1;
        }
        return result.toOwnedSlice();
    }
    return path;
}
