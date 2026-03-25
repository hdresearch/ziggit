const std = @import("std");

pub const DiffLine = struct {
    type: enum { context, add, remove },
    content: []const u8,
    old_line: ?u32,
    new_line: ?u32,

    pub fn init(line_type: @TypeOf(@as(@This(), undefined).type), content: []const u8, old_line: ?u32, new_line: ?u32) DiffLine {
        return DiffLine{
            .type = line_type,
            .content = content,
            .old_line = old_line,
            .new_line = new_line,
        };
    }
};

pub const DiffHunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: std.ArrayList(DiffLine),

    pub fn init(allocator: std.mem.Allocator) DiffHunk {
        return DiffHunk{
            .old_start = 0,
            .old_count = 0,
            .new_start = 0,
            .new_count = 0,
            .lines = std.ArrayList(DiffLine).init(allocator),
        };
    }

    pub fn deinit(self: *DiffHunk, allocator: std.mem.Allocator) void {
        for (self.lines.items) |line| {
            allocator.free(line.content);
        }
        self.lines.deinit();
    }

    pub fn addLine(self: *DiffHunk, line_type: @TypeOf(@as(DiffLine, undefined).type), content: []const u8, allocator: std.mem.Allocator) !void {
        const content_copy = try allocator.dupe(u8, content);
        const old_line = if (line_type != .add) self.old_start + self.old_count else null;
        const new_line = if (line_type != .remove) self.new_start + self.new_count else null;
        
        try self.lines.append(DiffLine.init(line_type, content_copy, old_line, new_line));
        
        switch (line_type) {
            .context => {
                self.old_count += 1;
                self.new_count += 1;
            },
            .add => self.new_count += 1,
            .remove => self.old_count += 1,
        }
    }
};

pub fn generateUnifiedDiff(old_content: []const u8, new_content: []const u8, file_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var old_lines = std.ArrayList([]const u8).init(allocator);
    defer old_lines.deinit();
    
    var new_lines = std.ArrayList([]const u8).init(allocator);
    defer new_lines.deinit();
    
    // Split content into lines
    var old_iter = std.mem.split(u8, old_content, "\n");
    while (old_iter.next()) |line| {
        try old_lines.append(line);
    }
    
    var new_iter = std.mem.split(u8, new_content, "\n");
    while (new_iter.next()) |line| {
        try new_lines.append(line);
    }
    
    // Generate diff using Myers algorithm (simplified version)
    var hunks = std.ArrayList(DiffHunk).init(allocator);
    defer {
        for (hunks.items) |*hunk| {
            hunk.deinit(allocator);
        }
        hunks.deinit();
    }
    
    try generateDiffHunks(old_lines.items, new_lines.items, &hunks, allocator);
    
    // Generate unified diff output
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    const writer = result.writer();
    
    // Diff header
    try writer.print("diff --git a/{s} b/{s}\n", .{ file_path, file_path });
    try writer.print("index 0000000..1111111 100644\n", .{});
    try writer.print("--- a/{s}\n", .{file_path});
    try writer.print("+++ b/{s}\n", .{file_path});
    
    // Hunks
    for (hunks.items) |hunk| {
        try writer.print("@@ -{},{} +{},{} @@\n", .{ hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count });
        
        for (hunk.lines.items) |line| {
            const prefix = switch (line.type) {
                .context => " ",
                .add => "+",
                .remove => "-",
            };
            try writer.print("{s}{s}\n", .{ prefix, line.content });
        }
    }
    
    return try result.toOwnedSlice();
}

fn generateDiffHunks(old_lines: []const []const u8, new_lines: []const []const u8, hunks: *std.ArrayList(DiffHunk), allocator: std.mem.Allocator) !void {
    // Simplified diff algorithm - just detect all differences as one big hunk
    // For a production implementation, you'd want to use Myers algorithm or similar
    
    if (old_lines.len == 0 and new_lines.len == 0) return;
    
    var hunk = DiffHunk.init(allocator);
    hunk.old_start = 1;
    hunk.new_start = 1;
    
    var old_idx: usize = 0;
    var new_idx: usize = 0;
    
    while (old_idx < old_lines.len or new_idx < new_lines.len) {
        if (old_idx < old_lines.len and new_idx < new_lines.len) {
            if (std.mem.eql(u8, old_lines[old_idx], new_lines[new_idx])) {
                // Lines match - context
                try hunk.addLine(.context, old_lines[old_idx], allocator);
                old_idx += 1;
                new_idx += 1;
            } else {
                // Lines don't match - show as remove + add
                try hunk.addLine(.remove, old_lines[old_idx], allocator);
                try hunk.addLine(.add, new_lines[new_idx], allocator);
                old_idx += 1;
                new_idx += 1;
            }
        } else if (old_idx < old_lines.len) {
            // Only old lines left - removals
            try hunk.addLine(.remove, old_lines[old_idx], allocator);
            old_idx += 1;
        } else {
            // Only new lines left - additions
            try hunk.addLine(.add, new_lines[new_idx], allocator);
            new_idx += 1;
        }
    }
    
    if (hunk.lines.items.len > 0) {
        try hunks.append(hunk);
    } else {
        hunk.deinit(allocator);
    }
}