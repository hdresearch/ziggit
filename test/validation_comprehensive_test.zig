const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");
const config = @import("../src/git/config.zig");

// Mock platform implementation for testing
const MockPlatform = struct {
    fs: MockFs,
    
    const MockFs = struct {
        files: std.StringHashMap([]const u8),
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator) MockFs {
            return MockFs{
                .files = std.StringHashMap([]const u8).init(allocator),
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *MockFs) void {
            var iterator = self.files.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.files.deinit();
        }
        
        pub fn setFile(self: *MockFs, path: []const u8, data: []const u8) !void {
            const owned_path = try self.allocator.dupe(u8, path);
            const owned_data = try self.allocator.dupe(u8, data);
            try self.files.put(owned_path, owned_data);
        }
        
        pub fn readFile(self: MockFs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (self.files.get(path)) |data| {
                return try allocator.dupe(u8, data);
            }
            return error.FileNotFound;
        }
        
        pub fn writeFile(self: MockFs, path: []const u8, data: []const u8) !void {
            _ = self;
            _ = path;
            _ = data;
        }
        
        pub fn makeDir(self: MockFs, path: []const u8) !void {
            _ = self;
            _ = path;
        }
    };
    
    pub fn init(allocator: std.mem.Allocator) MockPlatform {
        return MockPlatform{
            .fs = MockFs.init(allocator),
        };
    }
    
    pub fn deinit(self: *MockPlatform) void {
        self.fs.deinit();
    }
};

test "pack file validation with valid pack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    // Create a minimal valid pack file
    var pack_data = std.ArrayList(u8).init(allocator);
    defer pack_data.deinit();
    
    // Pack header: "PACK" + version + object count
    try pack_data.appendSlice("PACK");
    try pack_data.writer().writeInt(u32, 2, .big);
    try pack_data.writer().writeInt(u32, 1, .big);
    
    // Single blob object
    // Object header: type (3=blob) + size
    try pack_data.append(0x13); // Type 3, size 3 (lower 4 bits)
    
    // Compressed "foo" using zlib
    const content = "foo";
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    
    var content_stream = std.io.fixedBufferStream(content);
    try std.compress.zlib.compress(content_stream.reader(), compressed.writer(), .{});
    try pack_data.appendSlice(compressed.items);
    
    // Calculate and append checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack_data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack_data.appendSlice(&checksum);
    
    try platform.fs.setFile("/test/valid.pack", pack_data.items);
    
    // Test validation
    var result = try objects.validatePackFile("/test/valid.pack", platform, allocator);
    defer result.deinit();
    
    try testing.expect(result.is_valid);
    try testing.expect(result.checksum_valid);
    try testing.expectEqual(@as(u32, 2), result.version);
    try testing.expectEqual(@as(u32, 1), result.total_objects);
    try testing.expectEqual(@as(usize, 0), result.errors.items.len);
}

test "pack file validation with corrupted pack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    // Create an invalid pack file (wrong signature)
    const bad_pack = "BADPACK" ++ [_]u8{0} ** 20;
    try platform.fs.setFile("/test/bad.pack", &bad_pack);
    
    var result = try objects.validatePackFile("/test/bad.pack", platform, allocator);
    defer result.deinit();
    
    try testing.expect(!result.is_valid);
    try testing.expect(result.errors.items.len > 0);
    try testing.expectEqualStrings("Invalid pack file signature", result.errors.items[0]);
}

test "pack file validation with corrupted checksum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    // Create a pack with valid structure but wrong checksum
    var pack_data = std.ArrayList(u8).init(allocator);
    defer pack_data.deinit();
    
    try pack_data.appendSlice("PACK");
    try pack_data.writer().writeInt(u32, 2, .big);
    try pack_data.writer().writeInt(u32, 0, .big); // Zero objects
    
    // Wrong checksum
    const bad_checksum = [_]u8{0xFF} ** 20;
    try pack_data.appendSlice(&bad_checksum);
    
    try platform.fs.setFile("/test/bad_checksum.pack", pack_data.items);
    
    var result = try objects.validatePackFile("/test/bad_checksum.pack", platform, allocator);
    defer result.deinit();
    
    try testing.expect(!result.is_valid);
    try testing.expect(!result.checksum_valid);
    try testing.expect(result.errors.items.len > 0);
    
    // Should have both zero objects error and checksum mismatch error
    var found_checksum_error = false;
    var found_zero_objects_error = false;
    
    for (result.errors.items) |err| {
        if (std.mem.indexOf(u8, err, "checksum mismatch") != null) {
            found_checksum_error = true;
        }
        if (std.mem.indexOf(u8, err, "zero objects") != null) {
            found_zero_objects_error = true;
        }
    }
    
    try testing.expect(found_checksum_error);
    try testing.expect(found_zero_objects_error);
}

test "config validation with valid config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create a temporary config file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const config_content =
        \\[user]
        \\    name = Test User
        \\    email = test@example.com
        \\
        \\[core]
        \\    autocrlf = true
        \\    filemode = true
        \\
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
    ;
    
    try tmp_dir.dir.writeFile("config", config_content);
    
    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "config");
    defer allocator.free(config_path);
    
    const config_manager = config.ConfigManager.init(allocator, "/fake/git/dir");
    var result = try config_manager.validateConfigFile(config_path);
    defer result.deinit();
    
    try testing.expect(result.is_valid);
    try testing.expect(result.total_entries > 0);
    try testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try testing.expect(result.section_count >= 3); // user, core, remote
}

test "config validation with invalid config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    // Config with invalid email and autocrlf value
    const bad_config_content =
        \\[user]
        \\    name = Test User
        \\    email = not_an_email
        \\
        \\[core]
        \\    autocrlf = maybe
        \\    filemode = 42
        \\
        \\[remote "origin"]
        \\    url = 
    ;
    
    try tmp_dir.dir.writeFile("bad_config", bad_config_content);
    
    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "bad_config");
    defer allocator.free(config_path);
    
    const config_manager = config.ConfigManager.init(allocator, "/fake/git/dir");
    var result = try config_manager.validateConfigFile(config_path);
    defer result.deinit();
    
    try testing.expect(result.is_valid); // Should still be valid as it parses successfully
    try testing.expect(result.warnings.items.len > 0); // But should have warnings
    
    // Check for specific warnings
    var found_email_warning = false;
    var found_autocrlf_warning = false;
    var found_filemode_warning = false;
    var found_url_warning = false;
    
    for (result.warnings.items) |warning| {
        if (std.mem.indexOf(u8, warning, "email") != null and std.mem.indexOf(u8, warning, "@") != null) {
            found_email_warning = true;
        }
        if (std.mem.indexOf(u8, warning, "autocrlf") != null) {
            found_autocrlf_warning = true;
        }
        if (std.mem.indexOf(u8, warning, "filemode") != null) {
            found_filemode_warning = true;
        }
        if (std.mem.indexOf(u8, warning, "URL is empty") != null) {
            found_url_warning = true;
        }
    }
    
    try testing.expect(found_email_warning);
    try testing.expect(found_autocrlf_warning);
    try testing.expect(found_filemode_warning);
    try testing.expect(found_url_warning);
}

test "config validation with missing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const config_manager = config.ConfigManager.init(allocator, "/fake/git/dir");
    var result = try config_manager.validateConfigFile("/nonexistent/config");
    defer result.deinit();
    
    try testing.expect(!result.is_valid);
    try testing.expect(result.errors.items.len > 0);
    try testing.expectEqualStrings("Config file not found", result.errors.items[0]);
}

test "config validation with binary file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    // Create a file with null bytes (binary content)
    const binary_content = "valid start\x00binary\x00content";
    try tmp_dir.dir.writeFile("binary_config", binary_content);
    
    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "binary_config");
    defer allocator.free(config_path);
    
    const config_manager = config.ConfigManager.init(allocator, "/fake/git/dir");
    var result = try config_manager.validateConfigFile(config_path);
    defer result.deinit();
    
    try testing.expect(!result.is_valid);
    try testing.expect(result.errors.items.len > 0);
    
    var found_null_byte_error = false;
    for (result.errors.items) |err| {
        if (std.mem.indexOf(u8, err, "null byte") != null) {
            found_null_byte_error = true;
            break;
        }
    }
    try testing.expect(found_null_byte_error);
}

test "config validation with empty file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    try tmp_dir.dir.writeFile("empty_config", "");
    
    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "empty_config");
    defer allocator.free(config_path);
    
    const config_manager = config.ConfigManager.init(allocator, "/fake/git/dir");
    var result = try config_manager.validateConfigFile(config_path);
    defer result.deinit();
    
    try testing.expect(result.is_valid); // Empty config is valid
    try testing.expect(result.warnings.items.len > 0);
    
    var found_empty_warning = false;
    for (result.warnings.items) |warning| {
        if (std.mem.indexOf(u8, warning, "empty") != null) {
            found_empty_warning = true;
            break;
        }
    }
    try testing.expect(found_empty_warning);
}

test "comprehensive pack file format validation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    // Test various invalid pack file formats
    
    // 1. Too small file
    const too_small = "PACK";
    try platform.fs.setFile("/test/too_small.pack", too_small);
    
    var result1 = try objects.validatePackFile("/test/too_small.pack", platform, allocator);
    defer result1.deinit();
    try testing.expect(!result1.is_valid);
    
    // 2. Unsupported version
    var bad_version = std.ArrayList(u8).init(allocator);
    defer bad_version.deinit();
    try bad_version.appendSlice("PACK");
    try bad_version.writer().writeInt(u32, 99, .big); // Bad version
    try bad_version.writer().writeInt(u32, 0, .big);
    
    // Add dummy checksum
    for (0..20) |_| try bad_version.append(0);
    
    try platform.fs.setFile("/test/bad_version.pack", bad_version.items);
    
    var result2 = try objects.validatePackFile("/test/bad_version.pack", platform, allocator);
    defer result2.deinit();
    try testing.expect(!result2.is_valid);
    try testing.expectEqual(@as(u32, 99), result2.version);
    
    // 3. Unreasonable object count
    var huge_count = std.ArrayList(u8).init(allocator);
    defer huge_count.deinit();
    try huge_count.appendSlice("PACK");
    try huge_count.writer().writeInt(u32, 2, .big); // Version 2
    try huge_count.writer().writeInt(u32, 0xFFFFFFFF, .big); // Huge object count
    
    // Add dummy checksum
    for (0..20) |_| try huge_count.append(0);
    
    try platform.fs.setFile("/test/huge_count.pack", huge_count.items);
    
    var result3 = try objects.validatePackFile("/test/huge_count.pack", platform, allocator);
    defer result3.deinit();
    try testing.expect(!result3.is_valid);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), result3.total_objects);
}

test "pack file validation with file system errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    // Test file not found
    var result1 = try objects.validatePackFile("/nonexistent/pack.pack", platform, allocator);
    defer result1.deinit();
    try testing.expect(!result1.is_valid);
    
    var found_not_found = false;
    for (result1.errors.items) |err| {
        if (std.mem.indexOf(u8, err, "not found") != null) {
            found_not_found = true;
            break;
        }
    }
    try testing.expect(found_not_found);
}