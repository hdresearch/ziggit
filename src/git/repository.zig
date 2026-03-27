const std = @import("std");
const platform = @import("../platform/platform.zig");
const index = @import("index.zig");
const refs = @import("refs.zig");
const objects = @import("objects.zig");
const gitignore = @import("gitignore.zig");
const tree = @import("tree_enhanced.zig");

/// File status in the repository
pub const FileStatus = enum {
    unmodified,     // File unchanged
    modified,       // File modified in working tree
    added,          // File added to index
    deleted,        // File deleted from working tree
    renamed,        // File renamed
    copied,         // File copied
    unmerged,       // File has merge conflicts
    untracked,      // File not tracked by git
    ignored,        // File explicitly ignored
    
    pub fn toChar(self: FileStatus) u8 {
        return switch (self) {
            .unmodified => ' ',
            .modified => 'M',
            .added => 'A', 
            .deleted => 'D',
            .renamed => 'R',
            .copied => 'C',
            .unmerged => 'U',
            .untracked => '?',
            .ignored => '!',
        };
    }
};

/// Status entry for a single file
pub const StatusEntry = struct {
    path: []const u8,
    index_status: FileStatus,
    worktree_status: FileStatus,
    old_path: ?[]const u8, // For renames/copies
    
    pub fn init(path: []const u8, index_status: FileStatus, worktree_status: FileStatus) StatusEntry {
        return StatusEntry{
            .path = path,
            .index_status = index_status,
            .worktree_status = worktree_status,
            .old_path = null,
        };
    }
    
    pub fn deinit(self: StatusEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.old_path) |old_path| {
            allocator.free(old_path);
        }
    }
    
    pub fn isStaged(self: StatusEntry) bool {
        return self.index_status != .unmodified;
    }
    
    pub fn isUnstaged(self: StatusEntry) bool {
        return self.worktree_status != .unmodified and self.worktree_status != .ignored;
    }
    
    pub fn isUntracked(self: StatusEntry) bool {
        return self.index_status == .unmodified and self.worktree_status == .untracked;
    }
    
    pub fn isIgnored(self: StatusEntry) bool {
        return self.worktree_status == .ignored;
    }
};

/// Repository status information
pub const RepositoryStatus = struct {
    entries: std.ArrayList(StatusEntry),
    branch: ?[]const u8,
    upstream_branch: ?[]const u8,
    ahead: u32,
    behind: u32,
    
    pub fn init(allocator: std.mem.Allocator) RepositoryStatus {
        return RepositoryStatus{
            .entries = std.ArrayList(StatusEntry).init(allocator),
            .branch = null,
            .upstream_branch = null,
            .ahead = 0,
            .behind = 0,
        };
    }
    
    pub fn deinit(self: *RepositoryStatus, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            entry.deinit(allocator);
        }
        self.entries.deinit();
        
        if (self.branch) |branch| {
            allocator.free(branch);
        }
        if (self.upstream_branch) |upstream| {
            allocator.free(upstream);
        }
    }
    
    pub fn addEntry(self: *RepositoryStatus, entry: StatusEntry) !void {
        try self.entries.append(entry);
    }
    
    pub fn getStagedFiles(self: RepositoryStatus) std.ArrayList(StatusEntry) {
        var staged = std.ArrayList(StatusEntry).init(self.entries.allocator);
        for (self.entries.items) |entry| {
            if (entry.isStaged()) {
                staged.append(entry) catch {};
            }
        }
        return staged;
    }
    
    pub fn getUnstagedFiles(self: RepositoryStatus) std.ArrayList(StatusEntry) {
        var unstaged = std.ArrayList(StatusEntry).init(self.entries.allocator);
        for (self.entries.items) |entry| {
            if (entry.isUnstaged()) {
                unstaged.append(entry) catch {};
            }
        }
        return unstaged;
    }
    
    pub fn getUntrackedFiles(self: RepositoryStatus) std.ArrayList(StatusEntry) {
        var untracked = std.ArrayList(StatusEntry).init(self.entries.allocator);
        for (self.entries.items) |entry| {
            if (entry.isUntracked()) {
                untracked.append(entry) catch {};
            }
        }
        return untracked;
    }
};

pub const Repository = struct {
    path: []const u8,
    allocator: std.mem.Allocator,
    plat: platform.Platform,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, plat: platform.Platform) Repository {
        return Repository{
            .path = path,
            .allocator = allocator,
            .plat = plat,
        };
    }

    pub fn initRepository(self: *Repository) !void {
        // Create the repository directory if it doesn't exist
        if (!std.mem.eql(u8, self.path, ".")) {
            self.plat.fs.makeDir(self.path) catch |err| switch (err) {
                error.PathAlreadyExists => {}, // Already exists, that's fine
                else => return err,
            };
        }

        const git_dir = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{self.path});
        defer self.allocator.free(git_dir);

        // Create .git directory
        self.plat.fs.makeDir(git_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // Already exists, that's fine
            else => return err,
        };

        // Create subdirectories
        const subdirs = [_][]const u8{ 
            "objects", "objects/info", "objects/pack", 
            "refs", "refs/heads", "refs/tags", "refs/remotes",
            "hooks", "info"
        };
        for (subdirs) |subdir| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ git_dir, subdir });
            defer self.allocator.free(full_path);
            
            self.plat.fs.makeDir(full_path) catch |err| switch (err) {
                error.PathAlreadyExists => {}, // Already exists, that's fine
                else => return err,
            };
        }

        // Create HEAD file
        const head_file = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{git_dir});
        defer self.allocator.free(head_file);
        try self.plat.fs.writeFile(head_file, "ref: refs/heads/master\n");
        
        // Create basic config file
        const config_file = try std.fmt.allocPrint(self.allocator, "{s}/config", .{git_dir});
        defer self.allocator.free(config_file);
        const config_content = 
            \\[core]
            \\    repositoryformatversion = 0
            \\    filemode = true
            \\    bare = false
            \\    logallrefupdates = true
            \\
        ;
        try self.plat.fs.writeFile(config_file, config_content);
        
        // Create description file
        const desc_file = try std.fmt.allocPrint(self.allocator, "{s}/description", .{git_dir});
        defer self.allocator.free(desc_file);
        try self.plat.fs.writeFile(desc_file, "Unnamed repository; edit this file 'description' to name the repository.\n");

        try self.plat.writeStdout("Initialized empty Git repository\n");
    }

    pub fn exists(self: *Repository) !bool {
        const git_dir = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{self.path});
        defer self.allocator.free(git_dir);
        return self.plat.fs.exists(git_dir);
    }
    
    /// Get the .git directory path
    pub fn getGitDir(self: Repository, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{s}/.git", .{self.path});
    }
    
    /// Get the current branch name
    pub fn getCurrentBranch(self: Repository) !?[]u8 {
        const git_dir = try self.getGitDir(self.allocator);
        defer self.allocator.free(git_dir);
        
        return refs.getCurrentBranch(git_dir, self.plat, self.allocator) catch null;
    }
    
    /// Get repository status
    pub fn getStatus(self: Repository) !RepositoryStatus {
        var status = RepositoryStatus.init(self.allocator);
        errdefer status.deinit(self.allocator);
        
        const git_dir = try self.getGitDir(self.allocator);
        defer self.allocator.free(git_dir);
        
        // Get current branch
        status.branch = self.getCurrentBranch() catch null;
        
        // Load index
        var repo_index = index.Index.load(git_dir, self.plat, self.allocator) catch index.Index.init(self.allocator);
        defer repo_index.deinit();
        
        // Load gitignore patterns
        var ignore_patterns = gitignore.GitignorePattern.init(self.allocator);
        defer ignore_patterns.deinit();
        
        // Compare index with working tree
        try self.buildWorkingTreeStatus(&status, &repo_index, &ignore_patterns);
        
        return status;
    }
    
    /// Build status by comparing index with working tree
    fn buildWorkingTreeStatus(
        self: Repository, 
        status: *RepositoryStatus, 
        repo_index: *index.Index, 
        _: *gitignore.GitignorePattern
    ) !void {
        // Create a set of indexed files for quick lookup
        var indexed_files = std.StringHashMap(index.IndexEntry).init(self.allocator);
        defer indexed_files.deinit();
        
        for (repo_index.entries.items) |entry| {
            try indexed_files.put(entry.path, entry);
        }
        
        // Scan working directory (simplified - real implementation would use filesystem traversal)
        // For now, just process the indexed files to check their status
        
        for (repo_index.entries.items) |entry| {
            const index_status: FileStatus = .unmodified;
            const worktree_status: FileStatus = .unmodified;
            
            // Check if file exists in working tree
            const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.path, entry.path });
            defer self.allocator.free(file_path);
            
            if (self.plat.fs.exists(file_path) catch false) {
                // File exists, check if it's modified
                const file_stat = self.plat.fs.stat(file_path) catch {
                    worktree_status = .deleted;
                    const status_entry = StatusEntry.init(
                        try self.allocator.dupe(u8, entry.path),
                        index_status,
                        worktree_status
                    );
                    try status.addEntry(status_entry);
                    continue;
                };
                
                // Simple modification check (in real implementation, would compare hashes)
                if (file_stat.mtime != entry.mtime_sec * std.time.ns_per_s + entry.mtime_nsec or
                    file_stat.size != entry.size) {
                    worktree_status = .modified;
                }
            } else {
                worktree_status = .deleted;
            }
            
            // Add status entry if there are changes
            if (index_status != .unmodified or worktree_status != .unmodified) {
                const status_entry = StatusEntry.init(
                    try self.allocator.dupe(u8, entry.path),
                    index_status,
                    worktree_status
                );
                try status.addEntry(status_entry);
            }
        }
        
        // TODO: Add scanning for untracked files in working directory
        // This would require platform filesystem traversal capabilities
    }
    
    /// Check if repository is clean (no staged or unstaged changes)
    pub fn isClean(self: Repository) !bool {
        var status = try self.getStatus();
        defer status.deinit(self.allocator);
        
        return status.entries.items.len == 0;
    }
    
    /// Get HEAD commit hash
    pub fn getHeadCommit(self: Repository) !?[]u8 {
        const git_dir = try self.getGitDir(self.allocator);
        defer self.allocator.free(git_dir);
        
        return refs.resolveRef("HEAD", git_dir, self.plat, self.allocator) catch null;
    }
    
    /// Add file to index
    pub fn addFile(self: Repository, file_path: []const u8) !void {
        const git_dir = try self.getGitDir(self.allocator);
        defer self.allocator.free(git_dir);
        
        // Load current index
        var repo_index = index.Index.load(git_dir, self.plat, self.allocator) catch index.Index.init(self.allocator);
        defer repo_index.deinit();
        
        // Get file info
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.path, file_path });
        defer self.allocator.free(full_path);
        
        const file_stat = try self.plat.fs.stat(full_path);
        
        // Read file content and create blob
        const content = try self.plat.fs.readFile(self.allocator, full_path);
        defer self.allocator.free(content);
        
        var blob = try objects.createBlobObject(content, self.allocator);
        defer blob.deinit(self.allocator);
        
        const blob_hash_str = try blob.store(git_dir, self.plat, self.allocator);
        defer self.allocator.free(blob_hash_str);
        
        // Convert hash string to bytes
        var blob_hash: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&blob_hash, blob_hash_str);
        
        // Add to index
        try repo_index.addFile(file_path, file_stat, blob_hash);
        
        // Save index
        try repo_index.save(git_dir, self.plat);
    }
    
    /// Remove file from index and working tree
    pub fn removeFile(self: Repository, file_path: []const u8, from_working_tree: bool) !void {
        const git_dir = try self.getGitDir(self.allocator);
        defer self.allocator.free(git_dir);
        
        var repo_index = index.Index.load(git_dir, self.plat, self.allocator) catch {
            return error.IndexNotFound;
        };
        defer repo_index.deinit();
        
        // Remove from index
        _ = repo_index.removeFile(file_path);
        
        // Remove from working tree if requested
        if (from_working_tree) {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.path, file_path });
            defer self.allocator.free(full_path);
            
            // Note: Would need platform.fs.deleteFile method
            // std.fs.cwd().deleteFile(full_path) catch {};
        }
        
        // Save index
        try repo_index.save(git_dir, self.plat);
    }
    
    /// Create a commit
    pub fn commit(self: Repository, message: []const u8, author: []const u8) ![]u8 {
        const git_dir = try self.getGitDir(self.allocator);
        defer self.allocator.free(git_dir);
        
        // Load index
        var repo_index = index.Index.load(git_dir, self.plat, self.allocator) catch {
            return error.NothingToCommit;
        };
        defer repo_index.deinit();
        
        if (repo_index.entries.items.len == 0) {
            return error.NothingToCommit;
        }
        
        // Create tree from index
        const tree_hash = try self.createTreeFromIndex(&repo_index, git_dir);
        defer self.allocator.free(tree_hash);
        
        // Get parent commit
        const parent = self.getHeadCommit() catch null;
        defer if (parent) |p| self.allocator.free(p);
        
        const parent_hashes = if (parent) |p| [_][]const u8{p} else [_][]const u8{};
        
        // Create commit object
        const timestamp = std.time.timestamp();
        const author_str = try std.fmt.allocPrint(self.allocator, "{s} {d} +0000", .{ author, timestamp });
        defer self.allocator.free(author_str);
        
        var commit_obj = try objects.createCommitObject(
            tree_hash, 
            &parent_hashes, 
            author_str, 
            author_str, 
            message, 
            self.allocator
        );
        defer commit_obj.deinit(self.allocator);
        
        const commit_hash = try commit_obj.store(git_dir, self.plat, self.allocator);
        
        // Update HEAD
        if (self.getCurrentBranch()) |branch| {
            defer self.allocator.free(branch);
            const ref_path = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
            defer self.allocator.free(ref_path);
            try refs.updateRef(ref_path, commit_hash, git_dir, self.plat, self.allocator);
        } else |_| {
            // Detached HEAD
            try refs.updateRef("HEAD", commit_hash, git_dir, self.plat, self.allocator);
        }
        
        return commit_hash;
    }
    
    /// Create tree object from index entries
    fn createTreeFromIndex(self: Repository, repo_index: *index.Index, git_dir: []const u8) ![]u8 {
        var git_tree = tree.GitTree.init(self.allocator);
        defer git_tree.deinit();
        
        for (repo_index.entries.items) |entry| {
            const mode = switch (entry.mode & 0o170000) {
                0o040000 => tree.FileMode.directory,
                0o120000 => tree.FileMode.symlink,
                0o100000 => if (entry.mode & 0o111 != 0) tree.FileMode.executable_file else tree.FileMode.regular_file,
                else => tree.FileMode.regular_file,
            };
            
            try git_tree.addEntry(mode, entry.path, entry.sha1);
        }
        
        return tree.createTreeObject(git_tree, git_dir, self.plat, self.allocator);
    }
};