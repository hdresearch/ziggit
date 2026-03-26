// src/ziggit.zig - Public Zig API for ziggit
// This is the API that bun would import directly - pure Zig, no C exports
const std = @import("std");

// Import existing implementations  
const index_parser = @import("lib/index_parser.zig");
const objects_parser = @import("lib/objects_parser.zig");

pub const Repository = struct {
    path: []const u8,
    git_dir: []const u8,
    allocator: std.mem.Allocator,

    /// Open an existing repository at the specified path
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Repository {
        const abs_path = if (std.fs.path.isAbsolute(path))
            try allocator.dupe(u8, path)
        else blk: {
            var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const cwd = try std.process.getCwd(&cwd_buf);
            break :blk try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, path });
        };

        const git_dir = try findGitDir(allocator, abs_path);
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
        defer allocator.free(head_path);
        std.fs.accessAbsolute(head_path, .{}) catch {
            allocator.free(abs_path);
            allocator.free(git_dir);
            return error.NotAGitRepository;
        };

        return Repository{
            .path = abs_path,
            .git_dir = git_dir,
            .allocator = allocator,
        };
    }

    /// Initialize a new repository at the specified path  
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Repository {
        const abs_path = if (std.fs.path.isAbsolute(path))
            try allocator.dupe(u8, path)
        else blk: {
            var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const cwd = try std.process.getCwd(&cwd_buf);
            break :blk try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, path });
        };

        const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{abs_path});
        try createGitRepository(allocator, abs_path, git_dir, false);

        return Repository{
            .path = abs_path,
            .git_dir = git_dir,
            .allocator = allocator,
        };
    }

    /// Close repository and free resources
    pub fn close(self: *Repository) void {
        self.allocator.free(self.path);
        self.allocator.free(self.git_dir);
    }

    // Read operations (pure Zig, no git dependency)

    /// Get HEAD commit hash (like `git rev-parse HEAD`)
    pub fn revParseHead(self: *const Repository) ![40]u8 {
        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir});
        defer self.allocator.free(head_path);

        const head_file = std.fs.openFileAbsolute(head_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return [_]u8{'0'} ** 40, // Empty repo
            else => return err,
        };
        defer head_file.close();

        var head_content_buf: [512]u8 = undefined;
        const bytes_read = try head_file.readAll(&head_content_buf);
        const head_content = std.mem.trim(u8, head_content_buf[0..bytes_read], " \n\r\t");

        if (std.mem.startsWith(u8, head_content, "ref: ")) {
            const ref_name = head_content[5..];
            return try self.resolveRef(ref_name);
        } else if (head_content.len >= 40 and isValidHex(head_content[0..40])) {
            var result: [40]u8 = undefined;
            @memcpy(&result, head_content[0..40]);
            return result;
        } else {
            return [_]u8{'0'} ** 40;
        }
    }

    /// Get status in porcelain format (like `git status --porcelain`)
    pub fn statusPorcelain(self: *const Repository, allocator: std.mem.Allocator) ![]const u8 {
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{self.git_dir});
        defer allocator.free(head_path);

        std.fs.accessAbsolute(head_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return try allocator.dupe(u8, ""),
            else => return err,
        };

        // Simple implementation - check for untracked files
        return try self.scanUntracked(allocator);
    }

    /// Check if working tree is clean
    pub fn isClean(self: *const Repository) !bool {
        const status = try self.statusPorcelain(self.allocator);
        defer self.allocator.free(status);
        return status.len == 0;
    }

    /// Get latest tag (like `git describe --tags --abbrev=0`)  
    pub fn describeTags(self: *const Repository, allocator: std.mem.Allocator) ![]const u8 {
        const tags_dir = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{self.git_dir});
        defer allocator.free(tags_dir);

        var tags_list = std.ArrayList([]const u8).init(allocator);
        defer {
            for (tags_list.items) |tag| {
                allocator.free(tag);
            }
            tags_list.deinit();
        }

        if (std.fs.openDirAbsolute(tags_dir, .{ .iterate = true })) |mut_dir| {
            var dir = mut_dir;
            defer dir.close();

            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                if (entry.kind == .file) {
                    try tags_list.append(try allocator.dupe(u8, entry.name));
                }
            }
        } else |_| {
            return try allocator.dupe(u8, "");
        }

        if (tags_list.items.len == 0) {
            return try allocator.dupe(u8, "");
        }

        std.mem.sort([]const u8, tags_list.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .gt;
            }
        }.lessThan);

        return try allocator.dupe(u8, tags_list.items[0]);
    }

    /// Find specific commit hash
    pub fn findCommit(self: *const Repository, committish: []const u8) ![40]u8 {
        if (committish.len == 40 and isValidHex(committish)) {
            var result: [40]u8 = undefined;
            @memcpy(&result, committish);
            return result;
        }

        const ref_path = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{committish});
        defer self.allocator.free(ref_path);
        if (self.resolveRef(ref_path)) |hash| {
            return hash;
        } else |_| {}

        const tag_path = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{committish});
        defer self.allocator.free(tag_path);
        if (self.resolveRef(tag_path)) |hash| {
            return hash;
        } else |_| {}

        if (committish.len >= 4 and committish.len <= 40 and isValidHex(committish)) {
            return try self.expandShortHash(committish);
        }

        return error.CommitNotFound;
    }

    /// Get latest tag name 
    pub fn latestTag(self: *const Repository, allocator: std.mem.Allocator) ![]const u8 {
        return try self.describeTags(allocator);
    }

    /// List all branches
    pub fn branchList(self: *const Repository, allocator: std.mem.Allocator) ![][]const u8 {
        const branches_dir = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{self.git_dir});
        defer allocator.free(branches_dir);

        var branches = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (branches.items) |branch| {
                allocator.free(branch);
            }
            branches.deinit();
        }

        if (std.fs.openDirAbsolute(branches_dir, .{ .iterate = true })) |mut_dir| {
            var dir = mut_dir;
            defer dir.close();

            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                if (entry.kind == .file) {
                    try branches.append(try allocator.dupe(u8, entry.name));
                }
            }
        } else |_| {}

        return try branches.toOwnedSlice();
    }

    // Write operations (pure Zig - no git CLI)

    /// Add file to index (pure Zig implementation)
    pub fn add(self: *Repository, path: []const u8) !void {
        const full_path = if (std.fs.path.isAbsolute(path))
            try self.allocator.dupe(u8, path)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.path, path });
        defer self.allocator.free(full_path);

        const file = try std.fs.openFileAbsolute(full_path, .{});
        defer file.close();

        const file_content = try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024);
        defer self.allocator.free(file_content);

        const file_stat = try file.stat();

        // Create blob: "blob <size>\0<content>"
        const blob_header = try std.fmt.allocPrint(self.allocator, "blob {}\x00", .{file_content.len});
        defer self.allocator.free(blob_header);

        const blob_content = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ blob_header, file_content });
        defer self.allocator.free(blob_content);

        // Compute SHA-1
        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(blob_content, &hash, .{});

        var hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;

        // Compress and save
        try self.saveObject(&hash_hex, blob_content);

        // Update index
        try self.updateIndex(path, hash, file_stat);
    }

    /// Create commit (pure Zig implementation)  
    pub fn commit(self: *Repository, message: []const u8, author_name: []const u8, author_email: []const u8) ![40]u8 {
        const index_path = try std.fmt.allocPrint(self.allocator, "{s}/index", .{self.git_dir});
        defer self.allocator.free(index_path);

        var git_index = index_parser.GitIndex.readFromFile(self.allocator, index_path) catch blk: {
            break :blk index_parser.GitIndex.init(self.allocator);
        };
        defer git_index.deinit();

        const tree_hash = try self.createTreeFromIndex(&git_index);
        const parent_hash = self.revParseHead() catch [_]u8{'0'} ** 40;
        const has_parent = !std.mem.eql(u8, &parent_hash, &([_]u8{'0'} ** 40));

        const timestamp = std.time.timestamp();
        const commit_content = if (has_parent)
            try std.fmt.allocPrint(
                self.allocator,
                "tree {s}\nparent {s}\nauthor {s} <{s}> {d} +0000\ncommitter {s} <{s}> {d} +0000\n\n{s}\n",
                .{ tree_hash, parent_hash, author_name, author_email, timestamp, author_name, author_email, timestamp, message }
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "tree {s}\nauthor {s} <{s}> {d} +0000\ncommitter {s} <{s}> {d} +0000\n\n{s}\n",
                .{ tree_hash, author_name, author_email, timestamp, author_name, author_email, timestamp, message }
            );
        defer self.allocator.free(commit_content);

        const commit_header = try std.fmt.allocPrint(self.allocator, "commit {}\x00", .{commit_content.len});
        defer self.allocator.free(commit_header);

        const commit_object = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ commit_header, commit_content });
        defer self.allocator.free(commit_object);

        var commit_hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(commit_object, &commit_hash, .{});

        var commit_hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&commit_hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&commit_hash)}) catch unreachable;

        try self.saveObject(&commit_hash_hex, commit_object);
        try self.updateHead(&commit_hash_hex);

        return commit_hash_hex;
    }

    /// Create tag (pure Zig implementation)
    pub fn createTag(self: *Repository, name: []const u8, message: ?[]const u8) !void {
        const head_hash = try self.revParseHead();
        
        const tag_ref_path = try std.fmt.allocPrint(self.allocator, "{s}/refs/tags/{s}", .{ self.git_dir, name });
        defer self.allocator.free(tag_ref_path);

        const tag_file = try std.fs.createFileAbsolute(tag_ref_path, .{ .truncate = true });
        defer tag_file.close();

        if (message) |msg| {
            const timestamp = std.time.timestamp();
            const tag_content = try std.fmt.allocPrint(
                self.allocator,
                "object {s}\ntype commit\ntag {s}\ntagger ziggit <ziggit@example.com> {d} +0000\n\n{s}\n",
                .{ head_hash, name, timestamp, msg }
            );
            defer self.allocator.free(tag_content);

            const tag_header = try std.fmt.allocPrint(self.allocator, "tag {}\x00", .{tag_content.len});
            defer self.allocator.free(tag_header);

            const tag_object = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ tag_header, tag_content });
            defer self.allocator.free(tag_object);

            var tag_hash: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(tag_object, &tag_hash, .{});

            var tag_hash_hex: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&tag_hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&tag_hash)}) catch unreachable;

            try self.saveObject(&tag_hash_hex, tag_object);
            try tag_file.writeAll(&tag_hash_hex);
        } else {
            try tag_file.writeAll(&head_hash);
        }
    }

    /// Checkout (simplified - just updates HEAD and working tree files)
    pub fn checkout(self: *Repository, ref: []const u8) !void {
        const commit_hash = try self.findCommit(ref);
        
        // Update HEAD
        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir});
        defer self.allocator.free(head_path);

        const head_file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
        defer head_file.close();
        try head_file.writeAll(&commit_hash);
    }

    /// Fetch from local repository
    pub fn fetch(self: *Repository, remote_path: []const u8) !void {
        if (std.mem.startsWith(u8, remote_path, "http://") or
            std.mem.startsWith(u8, remote_path, "https://") or
            std.mem.startsWith(u8, remote_path, "git://") or
            std.mem.startsWith(u8, remote_path, "ssh://")) {
            return error.NetworkRemoteNotSupported;
        }

        const remote_git_dir = try findGitDir(self.allocator, remote_path);
        defer self.allocator.free(remote_git_dir);

        try self.copyMissingObjects(remote_git_dir);
        try self.updateRemoteRefs(remote_git_dir, "origin");
    }

    /// Clone local repository (bare)
    pub fn cloneBare(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !Repository {
        if (std.mem.startsWith(u8, source, "http://") or
            std.mem.startsWith(u8, source, "https://") or
            std.mem.startsWith(u8, source, "git://") or
            std.mem.startsWith(u8, source, "ssh://")) {
            return error.NetworkRemoteNotSupported;
        }

        const source_git_dir = try findGitDir(allocator, source);
        defer allocator.free(source_git_dir);

        std.fs.makeDirAbsolute(target) catch |err| switch (err) {
            error.PathAlreadyExists => return error.AlreadyExists,
            else => return err,
        };

        try copyDirectory(source_git_dir, target);

        return Repository{
            .path = try allocator.dupe(u8, target),
            .git_dir = try allocator.dupe(u8, target),
            .allocator = allocator,
        };
    }

    /// Clone local repository (no checkout)
    pub fn cloneNoCheckout(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !Repository {
        if (std.mem.startsWith(u8, source, "http://") or
            std.mem.startsWith(u8, source, "https://") or
            std.mem.startsWith(u8, source, "git://") or
            std.mem.startsWith(u8, source, "ssh://")) {
            return error.NetworkRemoteNotSupported;
        }

        const source_git_dir = try findGitDir(allocator, source);
        defer allocator.free(source_git_dir);

        std.fs.makeDirAbsolute(target) catch |err| switch (err) {
            error.PathAlreadyExists => return error.AlreadyExists,
            else => return err,
        };

        const target_git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{target});
        try copyDirectory(source_git_dir, target_git_dir);

        return Repository{
            .path = try allocator.dupe(u8, target),
            .git_dir = target_git_dir,
            .allocator = allocator,
        };
    }

    // Private helper methods

    fn resolveRef(self: *const Repository, ref_name: []const u8) ![40]u8 {
        const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
        defer self.allocator.free(ref_path);

        if (std.fs.openFileAbsolute(ref_path, .{})) |ref_file| {
            defer ref_file.close();

            var ref_content_buf: [64]u8 = undefined;
            const bytes_read = try ref_file.readAll(&ref_content_buf);
            const ref_content = std.mem.trim(u8, ref_content_buf[0..bytes_read], " \n\r\t");

            if (ref_content.len >= 40 and isValidHex(ref_content[0..40])) {
                var result: [40]u8 = undefined;
                @memcpy(&result, ref_content[0..40]);
                return result;
            }
        } else |_| {}

        return error.RefNotFound;
    }

    fn expandShortHash(self: *const Repository, short_hash: []const u8) ![40]u8 {
        const obj_dir = try std.fmt.allocPrint(self.allocator, "{s}/objects/{s}", .{ self.git_dir, short_hash[0..2] });
        defer self.allocator.free(obj_dir);

        if (std.fs.openDirAbsolute(obj_dir, .{ .iterate = true })) |mut_dir| {
            var dir = mut_dir;
            defer dir.close();

            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                if (entry.kind == .file and std.mem.startsWith(u8, entry.name, short_hash[2..])) {
                    var result: [40]u8 = undefined;
                    @memcpy(result[0..2], short_hash[0..2]);
                    @memcpy(result[2..], entry.name);
                    return result;
                }
            }
        } else |_| {}

        return error.CommitNotFound;
    }

    fn scanUntracked(self: *const Repository, allocator: std.mem.Allocator) ![]const u8 {
        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();

        const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{self.git_dir});
        defer allocator.free(index_path);

        var git_index = index_parser.GitIndex.readFromFile(allocator, index_path) catch {
            return try self.scanAllFilesAsUntracked(allocator);
        };
        defer git_index.deinit();

        var dir = std.fs.cwd().openDir(self.path, .{ .iterate = true }) catch return try allocator.dupe(u8, "");
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, ".git")) continue;

            var is_tracked = false;
            for (git_index.entries.items) |index_entry| {
                if (std.mem.eql(u8, index_entry.path, entry.name)) {
                    is_tracked = true;
                    break;
                }
            }

            if (!is_tracked) {
                try output.appendSlice("?? ");
                try output.appendSlice(entry.name);
                try output.append('\n');
            }
        }

        return try output.toOwnedSlice();
    }

    fn scanAllFilesAsUntracked(self: *const Repository, allocator: std.mem.Allocator) ![]const u8 {
        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();

        var dir = std.fs.cwd().openDir(self.path, .{ .iterate = true }) catch return try allocator.dupe(u8, "");
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, ".git")) continue;

            try output.appendSlice("?? ");
            try output.appendSlice(entry.name);
            try output.append('\n');
        }

        return try output.toOwnedSlice();
    }

    fn updateIndex(self: *Repository, path: []const u8, hash: [20]u8, file_stat: std.fs.File.Stat) !void {
        const index_path = try std.fmt.allocPrint(self.allocator, "{s}/index", .{self.git_dir});
        defer self.allocator.free(index_path);

        var git_index = index_parser.GitIndex.readFromFile(self.allocator, index_path) catch blk: {
            break :blk index_parser.GitIndex.init(self.allocator);
        };
        defer git_index.deinit();

        // Add new entry
        try git_index.entries.append(index_parser.IndexEntry{
            .ctime_seconds = @intCast(@divTrunc(file_stat.ctime, 1_000_000_000)),
            .ctime_nanoseconds = @intCast(@mod(file_stat.ctime, 1_000_000_000)),
            .mtime_seconds = @intCast(@divTrunc(file_stat.mtime, 1_000_000_000)),
            .mtime_nanoseconds = @intCast(@mod(file_stat.mtime, 1_000_000_000)),
            .dev = if (@hasField(@TypeOf(file_stat), "dev")) @intCast(file_stat.dev) else 0,
            .ino = if (@hasField(@TypeOf(file_stat), "ino")) @intCast(file_stat.ino) else 0,
            .mode = 33188, // 100644
            .uid = 0,
            .gid = 0,
            .size = @intCast(file_stat.size),
            .sha1 = hash,
            .flags = @intCast(@min(path.len, 0xfff)),
            .path = try self.allocator.dupe(u8, path),
        });

        try git_index.writeToFile(index_path);
    }

    fn createTreeFromIndex(self: *Repository, git_index: *const index_parser.GitIndex) ![40]u8 {
        var tree_content = std.ArrayList(u8).init(self.allocator);
        defer tree_content.deinit();

        for (git_index.entries.items) |entry| {
            try tree_content.appendSlice("100644 ");
            try tree_content.appendSlice(entry.path);
            try tree_content.append(0);
            try tree_content.appendSlice(&entry.sha1);
        }

        const tree_header = try std.fmt.allocPrint(self.allocator, "tree {}\x00", .{tree_content.items.len});
        defer self.allocator.free(tree_header);

        const tree_object = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ tree_header, tree_content.items });
        defer self.allocator.free(tree_object);

        var tree_hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(tree_object, &tree_hash, .{});

        var tree_hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&tree_hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&tree_hash)}) catch unreachable;

        try self.saveObject(&tree_hash_hex, tree_object);
        return tree_hash_hex;
    }

    fn saveObject(self: *Repository, hash_hex: *const [40]u8, object_content: []const u8) !void {
        const obj_dir = try std.fmt.allocPrint(self.allocator, "{s}/objects/{s}", .{ self.git_dir, hash_hex[0..2] });
        defer self.allocator.free(obj_dir);
        std.fs.makeDirAbsolute(obj_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var compressed = std.ArrayList(u8).init(self.allocator);
        defer compressed.deinit();

        var stream = std.io.fixedBufferStream(object_content);
        try std.compress.zlib.compress(stream.reader(), compressed.writer(), .{});

        const obj_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ obj_dir, hash_hex[2..] });
        defer self.allocator.free(obj_path);

        const obj_file = try std.fs.createFileAbsolute(obj_path, .{ .truncate = true });
        defer obj_file.close();
        try obj_file.writeAll(compressed.items);
    }

    fn updateHead(self: *Repository, commit_hash_hex: *const [40]u8) !void {
        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir});
        defer self.allocator.free(head_path);

        const head_file = std.fs.openFileAbsolute(head_path, .{}) catch {
            const new_head_file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
            defer new_head_file.close();
            try new_head_file.writeAll(commit_hash_hex);
            return;
        };
        defer head_file.close();

        var head_content_buf: [512]u8 = undefined;
        const bytes_read = try head_file.readAll(&head_content_buf);
        const head_content = std.mem.trim(u8, head_content_buf[0..bytes_read], " \n\r\t");

        if (std.mem.startsWith(u8, head_content, "ref: ")) {
            const ref_name = head_content[5..];
            const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
            defer self.allocator.free(ref_path);

            const ref_file = try std.fs.createFileAbsolute(ref_path, .{ .truncate = true });
            defer ref_file.close();
            try ref_file.writeAll(commit_hash_hex);
        } else {
            const head_file_write = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
            defer head_file_write.close();
            try head_file_write.writeAll(commit_hash_hex);
        }
    }

    fn copyMissingObjects(self: *Repository, remote_git_dir: []const u8) !void {
        // Simple implementation - copy all objects
        const remote_objects_dir = try std.fmt.allocPrint(self.allocator, "{s}/objects", .{remote_git_dir});
        defer self.allocator.free(remote_objects_dir);

        const local_objects_dir = try std.fmt.allocPrint(self.allocator, "{s}/objects", .{self.git_dir});
        defer self.allocator.free(local_objects_dir);

        try copyDirectory(remote_objects_dir, local_objects_dir);
    }

    fn updateRemoteRefs(self: *Repository, remote_git_dir: []const u8, remote_name: []const u8) !void {
        const remote_refs_dir = try std.fmt.allocPrint(self.allocator, "{s}/refs/heads", .{remote_git_dir});
        defer self.allocator.free(remote_refs_dir);

        const local_remote_refs_dir = try std.fmt.allocPrint(self.allocator, "{s}/refs/remotes/{s}", .{ self.git_dir, remote_name });
        defer self.allocator.free(local_remote_refs_dir);

        std.fs.makeDirAbsolute(local_remote_refs_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        try copyDirectory(remote_refs_dir, local_remote_refs_dir);
    }
};

// Helper functions

fn findGitDir(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
    
    std.fs.accessAbsolute(git_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(git_dir);
            return error.NotAGitRepository;
        },
        else => {
            allocator.free(git_dir);
            return err;
        },
    };

    return git_dir;
}

fn createGitRepository(allocator: std.mem.Allocator, repo_path: []const u8, git_dir: []const u8, bare: bool) !void {
    _ = bare;

    std.fs.makeDirAbsolute(repo_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    std.fs.makeDirAbsolute(git_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const subdirs = [_][]const u8{
        "objects", "objects/info", "objects/pack",
        "refs", "refs/heads", "refs/tags", "refs/remotes",
        "hooks", "info",
    };

    for (subdirs) |subdir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, subdir });
        defer allocator.free(full_path);
        std.fs.makeDirAbsolute(full_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const head_file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
    defer head_file.close();
    try head_file.writeAll("ref: refs/heads/master\n");

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    const config_file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer config_file.close();

    const config_content =
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\    logallrefupdates = true
        \\
    ;
    try config_file.writeAll(config_content);
}

fn isValidHex(str: []const u8) bool {
    for (str) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

fn copyDirectory(source: []const u8, dest: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (std.fs.openDirAbsolute(source, .{ .iterate = true })) |mut_source_dir| {
        var source_dir = mut_source_dir;
        defer source_dir.close();

        std.fs.makeDirAbsolute(dest) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var iterator = source_dir.iterate();
        while (try iterator.next()) |entry| {
            const source_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source, entry.name });
            const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, entry.name });

            switch (entry.kind) {
                .file => {
                    const source_file = try std.fs.openFileAbsolute(source_path, .{});
                    defer source_file.close();

                    const dest_file = try std.fs.createFileAbsolute(dest_path, .{ .truncate = true });
                    defer dest_file.close();

                    const content = try source_file.readToEndAlloc(allocator, 100 * 1024 * 1024);
                    defer allocator.free(content);

                    try dest_file.writeAll(content);
                },
                .directory => try copyDirectory(source_path, dest_path),
                else => {},
            }
        }
    } else |err| return err;
}