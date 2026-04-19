const std = @import("std");

pub fn createDelta(allocator: std.mem.Allocator, base: []const u8, target: []const u8) ![]u8 {
    if (std.mem.eql(u8, base, target)) {
        return createIdenticalDelta(allocator, base.len, target.len);
    }
    
    var delta: std.ArrayListUnmanaged(u8) = .{};
    defer delta.deinit(allocator);
    
    try writeVarint(allocator, &delta, base.len);
    try writeVarint(allocator, &delta, target.len);
    
    var target_pos: usize = 0;
    var pending_insert: std.ArrayListUnmanaged(u8) = .{};
    defer pending_insert.deinit(allocator);
    
    while (target_pos < target.len) {
        var best_match_offset: usize = 0;
        var best_match_len: usize = 0;
        
        if (target_pos + 4 <= target.len) {
            var base_pos: usize = 0;
            while (base_pos + 4 <= base.len) : (base_pos += 1) {
                const match_len = findMatchLength(base, base_pos, target, target_pos);
                if (match_len >= 4 and match_len > best_match_len) {
                    best_match_offset = base_pos;
                    best_match_len = match_len;
                }
            }
        }
        
        if (best_match_len >= 4) {
            if (pending_insert.items.len > 0) {
                try emitInsert(allocator, &delta, pending_insert.items);
                pending_insert.clearRetainingCapacity();
            }
            
            try emitCopy(allocator, &delta, best_match_offset, best_match_len);
            target_pos += best_match_len;
        } else {
            try pending_insert.append(allocator, target[target_pos]);
            target_pos += 1;
            
            if (pending_insert.items.len >= 127) {
                try emitInsert(allocator, &delta, pending_insert.items);
                pending_insert.clearRetainingCapacity();
            }
        }
    }
    
    if (pending_insert.items.len > 0) {
        try emitInsert(allocator, &delta, pending_insert.items);
    }
    
    return delta.toOwnedSlice(allocator);
}

pub fn deltaSize(base: []const u8, target: []const u8) usize {
    const header_size = varintSize(base.len) + varintSize(target.len);
    const worst_case_body = target.len + (target.len + 126) / 127;
    return header_size + worst_case_body;
}

fn createIdenticalDelta(allocator: std.mem.Allocator, base_len: usize, target_len: usize) ![]u8 {
    var delta: std.ArrayListUnmanaged(u8) = .{};
    defer delta.deinit(allocator);
    
    try writeVarint(allocator, &delta, base_len);
    try writeVarint(allocator, &delta, target_len);
    
    if (target_len > 0) {
        try emitCopy(allocator, &delta, 0, target_len);
    }
    
    return delta.toOwnedSlice(allocator);
}

fn findMatchLength(base: []const u8, base_offset: usize, target: []const u8, target_offset: usize) usize {
    var len: usize = 0;
    while (base_offset + len < base.len and 
           target_offset + len < target.len and
           base[base_offset + len] == target[target_offset + len]) {
        len += 1;
    }
    return len;
}

fn emitCopy(allocator: std.mem.Allocator, delta: *std.ArrayListUnmanaged(u8), offset: usize, size: usize) !void {
    var cmd: u8 = 0x80;
    
    if (offset & 0xFF != 0) { cmd |= 0x01; }
    if (offset & 0xFF00 != 0) { cmd |= 0x02; }
    if (offset & 0xFF0000 != 0) { cmd |= 0x04; }
    if (offset & 0xFF000000 != 0) { cmd |= 0x08; }
    
    if (size & 0xFF != 0) { cmd |= 0x10; }
    if (size & 0xFF00 != 0) { cmd |= 0x20; }
    if (size & 0xFF0000 != 0) { cmd |= 0x40; }
    
    try delta.append(allocator, cmd);
    
    if (cmd & 0x01 != 0) try delta.append(allocator, @intCast(offset & 0xFF));
    if (cmd & 0x02 != 0) try delta.append(allocator, @intCast((offset >> 8) & 0xFF));
    if (cmd & 0x04 != 0) try delta.append(allocator, @intCast((offset >> 16) & 0xFF));
    if (cmd & 0x08 != 0) try delta.append(allocator, @intCast((offset >> 24) & 0xFF));
    
    if (cmd & 0x10 != 0) try delta.append(allocator, @intCast(size & 0xFF));
    if (cmd & 0x20 != 0) try delta.append(allocator, @intCast((size >> 8) & 0xFF));
    if (cmd & 0x40 != 0) try delta.append(allocator, @intCast((size >> 16) & 0xFF));
}

fn emitInsert(allocator: std.mem.Allocator, delta: *std.ArrayListUnmanaged(u8), data: []const u8) !void {
    try delta.append(allocator, @intCast(data.len));
    try delta.appendSlice(allocator, data);
}

fn writeVarint(allocator: std.mem.Allocator, delta: *std.ArrayListUnmanaged(u8), value: usize) !void {
    var val = value;
    while (val >= 0x80) {
        try delta.append(allocator, @intCast((val & 0x7F) | 0x80));
        val >>= 7;
    }
    try delta.append(allocator, @intCast(val & 0x7F));
}

fn varintSize(value: usize) usize {
    var val = value;
    var size: usize = 1;
    while (val >= 0x80) {
        size += 1;
        val >>= 7;
    }
    return size;
}
