const std = @import("std");

pub fn createDelta(allocator: std.mem.Allocator, base: []const u8, target: []const u8) ![]u8 {
    var delta: std.ArrayListUnmanaged(u8) = .{};
    defer delta.deinit(allocator);
    
    try writeVarint(allocator, &delta, base.len);
    try writeVarint(allocator, &delta, target.len);
    
    var pos: usize = 0;
    while (pos < target.len) {
        const chunk_size = @min(127, target.len - pos);
        try delta.append(allocator, @intCast(chunk_size));
        try delta.appendSlice(allocator, target[pos..pos + chunk_size]);
        pos += chunk_size;
    }
    
    return delta.toOwnedSlice(allocator);
}

pub fn deltaSize(base: []const u8, target: []const u8) usize {
    _ = base;
    return target.len + (target.len + 126) / 127 + 2;
}

fn writeVarint(allocator: std.mem.Allocator, delta: *std.ArrayListUnmanaged(u8), value: usize) !void {
    var val = value;
    while (val >= 0x80) {
        try delta.append(allocator, @intCast((val & 0x7F) | 0x80));
        val >>= 7;
    }
    try delta.append(allocator, @intCast(val & 0x7F));
}
