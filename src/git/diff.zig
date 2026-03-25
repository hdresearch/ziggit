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

const EditType = enum { keep, delete, insert };

const Edit = struct {
    type: EditType,
    old_index: usize,
    new_index: usize,
};

pub fn generateUnifiedDiff(old_content: []const u8, new_content: []const u8, file_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var old_lines = std.ArrayList([]const u8).init(allocator);
    defer old_lines.deinit();
    
    var new_lines = std.ArrayList([]const u8).init(allocator);
    defer new_lines.deinit();
    
    // Split content into lines, preserving empty lines
    var old_iter = std.mem.split(u8, old_content, "\n");
    while (old_iter.next()) |line| {
        try old_lines.append(line);
    }
    
    var new_iter = std.mem.split(u8, new_content, "\n");
    while (new_iter.next()) |line| {
        try new_lines.append(line);
    }
    
    // Generate diff using improved Myers algorithm
    var hunks = std.ArrayList(DiffHunk).init(allocator);
    defer {
        for (hunks.items) |*hunk| {
            hunk.deinit(allocator);
        }
        hunks.deinit();
    }
    
    try generateDiffHunks(old_lines.items, new_lines.items, &hunks, allocator);
    
    // If no differences, return empty diff
    if (hunks.items.len == 0) {
        return try allocator.dupe(u8, "");
    }
    
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
    if (old_lines.len == 0 and new_lines.len == 0) return;
    
    // Use Myers diff algorithm to find the longest common subsequence
    const lcs = try findLCS(old_lines, new_lines, allocator);
    defer lcs.deinit();
    
    // Convert LCS to edit script
    var edits = try generateEditScript(old_lines, new_lines, lcs.items, allocator);
    defer edits.deinit();
    
    // Group edits into hunks with context
    try generateHunksFromEdits(old_lines, new_lines, edits.items, hunks, allocator);
}

fn findLCS(old_lines: []const []const u8, new_lines: []const []const u8, allocator: std.mem.Allocator) !std.ArrayList(usize) {
    const m = old_lines.len;
    const n = new_lines.len;
    
    // Create LCS table
    var lcs_table = try allocator.alloc([]u32, m + 1);
    defer {
        for (lcs_table) |row| {
            allocator.free(row);
        }
        allocator.free(lcs_table);
    }
    
    for (lcs_table) |*row| {
        row.* = try allocator.alloc(u32, n + 1);
        @memset(row.*, 0);
    }
    
    // Fill LCS table
    for (1..m + 1) |i| {
        for (1..n + 1) |j| {
            if (std.mem.eql(u8, old_lines[i - 1], new_lines[j - 1])) {
                lcs_table[i][j] = lcs_table[i - 1][j - 1] + 1;
            } else {
                lcs_table[i][j] = @max(lcs_table[i - 1][j], lcs_table[i][j - 1]);
            }
        }
    }
    
    // Backtrack to find LCS
    var lcs = std.ArrayList(usize).init(allocator);
    var i: usize = m;
    var j: usize = n;
    
    while (i > 0 and j > 0) {
        if (std.mem.eql(u8, old_lines[i - 1], new_lines[j - 1])) {
            try lcs.insert(0, i - 1); // Store old line index
            i -= 1;
            j -= 1;
        } else if (lcs_table[i - 1][j] > lcs_table[i][j - 1]) {
            i -= 1;
        } else {
            j -= 1;
        }
    }
    
    return lcs;
}

fn generateEditScript(old_lines: []const []const u8, new_lines: []const []const u8, lcs: []const usize, allocator: std.mem.Allocator) !std.ArrayList(Edit) {
    var edits = std.ArrayList(Edit).init(allocator);
    
    var old_idx: usize = 0;
    var new_idx: usize = 0;
    var lcs_idx: usize = 0;
    
    while (old_idx < old_lines.len or new_idx < new_lines.len) {
        // Check if we have a common line
        if (lcs_idx < lcs.len and old_idx == lcs[lcs_idx]) {
            // Find corresponding new line
            while (new_idx < new_lines.len and !std.mem.eql(u8, old_lines[old_idx], new_lines[new_idx])) {
                try edits.append(Edit{ .type = .insert, .old_index = old_idx, .new_index = new_idx });
                new_idx += 1;
            }
            
            if (new_idx < new_lines.len) {
                try edits.append(Edit{ .type = .keep, .old_index = old_idx, .new_index = new_idx });
                new_idx += 1;
            }
            old_idx += 1;
            lcs_idx += 1;
        } else if (old_idx < old_lines.len) {
            try edits.append(Edit{ .type = .delete, .old_index = old_idx, .new_index = new_idx });
            old_idx += 1;
        } else {
            try edits.append(Edit{ .type = .insert, .old_index = old_idx, .new_index = new_idx });
            new_idx += 1;
        }
    }
    
    return edits;
}

fn generateHunksFromEdits(old_lines: []const []const u8, new_lines: []const []const u8, edits: []const Edit, hunks: *std.ArrayList(DiffHunk), allocator: std.mem.Allocator) !void {
    if (edits.len == 0) return;
    
    const context_lines = 3;
    var current_hunk: ?DiffHunk = null;
    var last_change_idx: usize = 0;
    
    for (edits, 0..) |edit, idx| {
        switch (edit.type) {
            .keep => {
                if (current_hunk != null) {
                    // Add context line to current hunk
                    try current_hunk.?.addLine(.context, old_lines[edit.old_index], allocator);
                    
                    // Check if we should close this hunk
                    var consecutive_context: usize = 0;
                    var check_idx = idx;
                    while (check_idx < edits.len and edits[check_idx].type == .keep) : (check_idx += 1) {
                        consecutive_context += 1;
                        if (consecutive_context > context_lines * 2) {
                            // Close current hunk
                            try hunks.append(current_hunk.?);
                            current_hunk = null;
                            break;
                        }
                    }
                }
            },
            .delete, .insert => {
                if (current_hunk == null) {
                    // Start new hunk with context
                    current_hunk = DiffHunk.init(allocator);
                    const start_context = if (edit.old_index >= context_lines) context_lines else edit.old_index;
                    current_hunk.?.old_start = @intCast(edit.old_index - start_context + 1);
                    current_hunk.?.new_start = @intCast(edit.new_index - start_context + 1);
                    
                    // Add leading context
                    var ctx_idx: usize = edit.old_index - start_context;
                    while (ctx_idx < edit.old_index) : (ctx_idx += 1) {
                        try current_hunk.?.addLine(.context, old_lines[ctx_idx], allocator);
                    }
                }
                
                // Add the actual change
                switch (edit.type) {
                    .delete => try current_hunk.?.addLine(.remove, old_lines[edit.old_index], allocator),
                    .insert => try current_hunk.?.addLine(.add, new_lines[edit.new_index], allocator),
                    else => unreachable,
                }
                
                last_change_idx = idx;
            },
        }
    }
    
    // Close final hunk if exists
    if (current_hunk != null) {
        // Add trailing context
        const max_context = @min(context_lines, old_lines.len - edits[last_change_idx].old_index - 1);
        var ctx_idx: usize = 0;
        while (ctx_idx < max_context and edits[last_change_idx].old_index + 1 + ctx_idx < old_lines.len) : (ctx_idx += 1) {
            try current_hunk.?.addLine(.context, old_lines[edits[last_change_idx].old_index + 1 + ctx_idx], allocator);
        }
        
        try hunks.append(current_hunk.?);
    }
}