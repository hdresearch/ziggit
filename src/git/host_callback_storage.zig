const std = @import("std");
const objects = @import("objects.zig");

// Define the types locally to avoid circular imports
pub const ObjectData = struct {
    obj_type: objects.GitObject.ObjectType,
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ObjectData) void {
        self.allocator.free(self.data);
    }
};

pub const HeadValue = union(enum) {
    symbolic: []const u8,
    direct: [40]u8,

    pub fn deinit(self: *HeadValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .symbolic => |s| allocator.free(s),
            .direct => {},
        }
    }
};

pub const RefEntry = struct {
    name: []const u8,
    hash: [40]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RefEntry) void {
        self.allocator.free(self.name);
    }
};

pub const RefList = struct {
    entries: []RefEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RefList) void {
        for (self.entries) |*entry| {
            entry.deinit();
        }
        self.allocator.free(self.entries);
    }
};

// Host callback imports for WASM builds
extern fn host_get_object(hash_ptr: [*]const u8, hash_len: u32, data_ptr: *[*]u8, data_len: *u32, type_out: *u32) bool;
extern fn host_put_object(hash_ptr: [*]const u8, hash_len: u32, data_ptr: [*]const u8, data_len: u32, obj_type: u32) bool;
extern fn host_object_exists(hash_ptr: [*]const u8, hash_len: u32) bool;
extern fn host_get_ref(name_ptr: [*]const u8, name_len: u32, hash_out: [*]u8) bool;
extern fn host_set_ref(name_ptr: [*]const u8, name_len: u32, hash_ptr: [*]const u8) bool;
extern fn host_delete_ref(name_ptr: [*]const u8, name_len: u32) bool;
extern fn host_list_refs(refs_ptr: *[*]u8, refs_len: *u32) bool;

pub const HostCallbackStorage = struct {
    allocator: std.mem.Allocator,
    git_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) HostCallbackStorage {
        return .{
            .allocator = allocator,
            .git_dir = git_dir,
        };
    }

    pub fn deinit(self: *HostCallbackStorage) void {
        _ = self;
    }

    pub fn objectExists(self: *HostCallbackStorage, hash_hex: []const u8) bool {
        _ = self;
        if (hash_hex.len != 40) return false;
        return host_object_exists(hash_hex.ptr, 40);
    }

    pub fn readObject(self: *HostCallbackStorage, hash_hex: []const u8) !ObjectData {
        if (hash_hex.len != 40) return error.InvalidHash;

        var data_ptr: [*]u8 = undefined;
        var data_len: u32 = 0;
        var type_out: u32 = 0;

        if (!host_get_object(hash_hex.ptr, 40, &data_ptr, &data_len, &type_out)) {
            return error.ObjectNotFound;
        }

        const data = data_ptr[0..data_len];
        const owned_data = try self.allocator.dupe(u8, data);

        const obj_type: objects.GitObject.ObjectType = switch (type_out) {
            1 => .commit,
            2 => .tree,
            3 => .blob,
            4 => .tag,
            else => return error.InvalidObjectType,
        };

        return ObjectData{
            .obj_type = obj_type,
            .data = owned_data,
            .allocator = self.allocator,
        };
    }

    pub fn writeObject(self: *HostCallbackStorage, obj_type: objects.GitObject.ObjectType, data: []const u8) ![40]u8 {
        const type_str = switch (obj_type) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        };

        const header = try std.fmt.allocPrint(self.allocator, "{s} {d}\x00", .{ type_str, data.len });
        defer self.allocator.free(header);

        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(header);
        hasher.update(data);
        const hash_bytes = hasher.finalResult();

        var hash_hex: [40]u8 = undefined;
        for (hash_bytes, 0..) |b, i| {
            const hc = "0123456789abcdef";
            hash_hex[i * 2] = hc[b >> 4];
            hash_hex[i * 2 + 1] = hc[b & 0xf];
        }

        const type_num: u32 = switch (obj_type) {
            .commit => 1,
            .tree => 2,
            .blob => 3,
            .tag => 4,
        };

        var full_content = std.array_list.Managed(u8).init(self.allocator);
        defer full_content.deinit();
        try full_content.appendSlice(header);
        try full_content.appendSlice(data);

        if (!host_put_object(&hash_hex, 40, full_content.items.ptr, @intCast(full_content.items.len), type_num)) {
            return error.FailedToWriteObject;
        }

        return hash_hex;
    }

    pub fn readRef(self: *HostCallbackStorage, ref_name: []const u8) !?[40]u8 {
        _ = self;
        var hash_out: [40]u8 = undefined;

        if (host_get_ref(ref_name.ptr, @intCast(ref_name.len), &hash_out)) {
            return hash_out;
        }

        return null;
    }

    pub fn writeRef(self: *HostCallbackStorage, ref_name: []const u8, hash: [40]u8) !void {
        _ = self;
        if (!host_set_ref(ref_name.ptr, @intCast(ref_name.len), &hash)) {
            return error.FailedToWriteRef;
        }
    }

    pub fn deleteRef(self: *HostCallbackStorage, ref_name: []const u8) !void {
        _ = self;
        if (!host_delete_ref(ref_name.ptr, @intCast(ref_name.len))) {
            return error.FailedToDeleteRef;
        }
    }

    pub fn readHead(self: *HostCallbackStorage) !HeadValue {
        const head_ref = try self.readRef("HEAD");
        if (head_ref) |hash| {
            return HeadValue{ .direct = hash };
        }
        return error.HeadNotFound;
    }

    pub fn listRefs(self: *HostCallbackStorage) !RefList {
        var refs_ptr: [*]u8 = undefined;
        var refs_len: u32 = 0;

        if (!host_list_refs(&refs_ptr, &refs_len)) {
            return error.FailedToListRefs;
        }

        const refs_data = refs_ptr[0..refs_len];
        defer self.allocator.free(refs_data);

        var entries = std.array_list.Managed(RefEntry).init(self.allocator);
        defer entries.deinit();

        var lines = std.mem.splitScalar(u8, refs_data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            var parts = std.mem.splitScalar(u8, line, ':');
            const name_part = parts.next() orelse continue;
            const hash_part = parts.next() orelse continue;

            if (hash_part.len != 40) continue;

            const name = try self.allocator.dupe(u8, name_part);
            var hash: [40]u8 = undefined;
            @memcpy(&hash, hash_part);

            try entries.append(RefEntry{
                .name = name,
                .hash = hash,
                .allocator = self.allocator,
            });
        }

        return RefList{
            .entries = try entries.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }
};
