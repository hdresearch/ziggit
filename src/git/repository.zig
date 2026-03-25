const std = @import("std");
const platform = @import("../platform/platform.zig");

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

        const ziggit_dir = try std.fmt.allocPrint(self.allocator, "{s}/.ziggit", .{self.path});
        defer self.allocator.free(ziggit_dir);

        // Create .ziggit directory
        self.plat.fs.makeDir(ziggit_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // Already exists, that's fine
            else => return err,
        };

        // Create subdirectories
        const subdirs = [_][]const u8{ "objects", "refs", "refs/heads", "refs/remotes" };
        for (subdirs) |subdir| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ ziggit_dir, subdir });
            defer self.allocator.free(full_path);
            
            self.plat.fs.makeDir(full_path) catch |err| switch (err) {
                error.PathAlreadyExists => {}, // Already exists, that's fine
                else => return err,
            };
        }

        // Create HEAD file
        const head_file = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{ziggit_dir});
        defer self.allocator.free(head_file);
        try self.plat.fs.writeFile(head_file, "ref: refs/heads/main\n");

        try self.plat.writeStdout("Initialized empty ziggit repository\n");
    }

    pub fn exists(self: *Repository) !bool {
        const ziggit_dir = try std.fmt.allocPrint(self.allocator, "{s}/.ziggit", .{self.path});
        defer self.allocator.free(ziggit_dir);
        return self.plat.fs.exists(ziggit_dir);
    }
};