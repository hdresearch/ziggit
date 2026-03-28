const std = @import("std");

fn writeDiffHeader(writer: anytype, file_path: []const u8, old_hash: []const u8, new_hash: []const u8, old_content: []const u8, new_content: []const u8) !void {
    writer.print("diff --git a/{s} b/{s}\n", .{ file_path, file_path }) catch {};
    if (old_content.len == 0 and new_content.len > 0) {
        writer.print("new file mode 100644\n", .{}) catch {};
        writer.print("index {s}..{s}\n", .{ old_hash, new_hash }) catch {};
        writer.print("--- /dev/null\n", .{}) catch {};
        writer.print("+++ b/{s}\n", .{file_path}) catch {};
    } else if (new_content.len == 0 and old_content.len > 0) {
        writer.print("deleted file mode 100644\n", .{}) catch {};
        writer.print("index {s}..{s}\n", .{ old_hash, new_hash }) catch {};
        writer.print("--- a/{s}\n", .{file_path}) catch {};
        writer.print("+++ /dev/null\n", .{}) catch {};
    } else {
        writer.print("index {s}..{s} 100644\n", .{ old_hash, new_hash }) catch {};
        writer.print("--- a/{s}\n", .{file_path}) catch {};
        writer.print("+++ b/{s}\n", .{file_path}) catch {};
    }
}

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

/// Diff options for customizing diff generation
pub const DiffOptions = struct {
    context_lines: u32 = 3,
    ignore_whitespace: bool = false,
    ignore_case: bool = false,
    word_diff: bool = false,
    show_function_names: bool = false,
    
    pub fn default() DiffOptions {
        return DiffOptions{};
    }
};

/// Statistics about a diff
pub const DiffStats = struct {
    files_changed: u32 = 1,
    insertions: u32 = 0,
    deletions: u32 = 0,
    
    pub fn print(self: DiffStats) void {
        std.debug.print("DiffStats: {} files, +{} insertions, -{} deletions\n", 
                       .{self.files_changed, self.insertions, self.deletions});
    }
};

pub const DiffHunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: std.array_list.Managed(DiffLine),

    pub fn init(allocator: std.mem.Allocator) DiffHunk {
        return DiffHunk{
            .old_start = 0,
            .old_count = 0,
            .new_start = 0,
            .new_count = 0,
            .lines = std.array_list.Managed(DiffLine).init(allocator),
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

fn writeHunkHeader(writer: anytype, old_start: usize, old_count: usize, new_start: usize, new_count: usize) !void {
    // Git format: omit count when it's 1, show 0 explicitly
    // When count is 0, start should be 0 too (git convention)
    const actual_old_start = if (old_count == 0) 0 else old_start;
    const actual_new_start = if (new_count == 0) 0 else new_start;
    try writer.writeAll("@@ -");
    try writer.print("{}", .{actual_old_start});
    if (old_count != 1) try writer.print(",{}", .{old_count});
    try writer.writeAll(" +");
    try writer.print("{}", .{actual_new_start});
    if (new_count != 1) try writer.print(",{}", .{new_count});
    try writer.writeAll(" @@\n");
}

pub fn generateUnifiedDiff(old_content: []const u8, new_content: []const u8, file_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return generateUnifiedDiffWithHashes(old_content, new_content, file_path, "0000000", "1111111", allocator);
}

pub fn generateUnifiedDiffWithHashes(old_content: []const u8, new_content: []const u8, file_path: []const u8, old_hash: []const u8, new_hash: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var old_lines = std.array_list.Managed([]const u8).init(allocator);
    defer old_lines.deinit();
    
    var new_lines = std.array_list.Managed([]const u8).init(allocator);
    defer new_lines.deinit();
    
    // Split content into lines; strip trailing empty element from newline-terminated content
    if (old_content.len > 0) {
        var old_iter = std.mem.splitSequence(u8, old_content, "\n");
        while (old_iter.next()) |line| {
            try old_lines.append(line);
        }
        if (old_lines.items.len > 0 and old_content[old_content.len - 1] == '\n') {
            _ = old_lines.pop();
        }
    }
    
    if (new_content.len > 0) {
        var new_iter = std.mem.splitSequence(u8, new_content, "\n");
        while (new_iter.next()) |line| {
            try new_lines.append(line);
        }
        if (new_lines.items.len > 0 and new_content[new_content.len - 1] == '\n') {
            _ = new_lines.pop();
        }
    }
    
    // Generate diff using improved Myers algorithm
    var hunks = std.array_list.Managed(DiffHunk).init(allocator);
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
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    
    const writer = result.writer();
    
    // Diff header
    try writeDiffHeader(writer, file_path, old_hash, new_hash, old_content, new_content);
    
    // Hunks
    for (hunks.items) |hunk| {
        try writeHunkHeader(writer, hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count);
        
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

fn generateDiffHunks(old_lines: []const []const u8, new_lines: []const []const u8, hunks: *std.array_list.Managed(DiffHunk), allocator: std.mem.Allocator) !void {
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

fn findLCS(old_lines: []const []const u8, new_lines: []const []const u8, allocator: std.mem.Allocator) !std.array_list.Managed(usize) {
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
    var lcs = std.array_list.Managed(usize).init(allocator);
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

fn generateEditScript(old_lines: []const []const u8, new_lines: []const []const u8, lcs: []const usize, allocator: std.mem.Allocator) !std.array_list.Managed(Edit) {
    var edits = std.array_list.Managed(Edit).init(allocator);
    
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

fn generateHunksFromEdits(old_lines: []const []const u8, new_lines: []const []const u8, edits: []const Edit, hunks: *std.array_list.Managed(DiffHunk), allocator: std.mem.Allocator) !void {
    if (edits.len == 0) return;
    const ctx: u32 = 3;
    var cs = std.array_list.Managed(usize).init(allocator);
    defer cs.deinit();
    var ce = std.array_list.Managed(usize).init(allocator);
    defer ce.deinit();
    var ic = false;
    for (0..edits.len) |eidx| {
        if (edits[eidx].type != .keep) { if (!ic) { try cs.append(eidx); ic = true; } } else { if (ic) { try ce.append(eidx); ic = false; } }
    }
    if (ic) try ce.append(edits.len);
    if (cs.items.len == 0) return;
    var gs2 = std.array_list.Managed(usize).init(allocator);
    defer gs2.deinit();
    var ge2 = std.array_list.Managed(usize).init(allocator);
    defer ge2.deinit();
    try gs2.append(0);
    { var gi: usize = 1; while (gi < cs.items.len) : (gi += 1) { if (cs.items[gi] - ce.items[gi-1] > ctx*2) { try ge2.append(gi-1); try gs2.append(gi); } } }
    try ge2.append(cs.items.len - 1);
    for (gs2.items, ge2.items) |gsi, gei| {
        var hunk = DiffHunk.init(allocator);
        const fe = edits[cs.items[gsi]];
        const lc = @min(ctx, fe.old_index);
        hunk.old_start = @intCast(fe.old_index - lc + 1);
        hunk.new_start = @intCast(fe.new_index - lc + 1);
        { var ci: usize = fe.old_index - lc; while (ci < fe.old_index) : (ci += 1) { try hunk.addLine(.context, old_lines[ci], allocator); } }
        { var ei: usize = cs.items[gsi]; while (ei < ce.items[gei]) : (ei += 1) {
            switch (edits[ei].type) { .keep => try hunk.addLine(.context, old_lines[edits[ei].old_index], allocator), .delete => try hunk.addLine(.remove, old_lines[edits[ei].old_index], allocator), .insert => try hunk.addLine(.add, new_lines[edits[ei].new_index], allocator), }
        } }
        { const le = edits[ce.items[gei]-1]; const ts: usize = switch(le.type) { .delete => le.old_index+1, .insert => le.old_index, .keep => le.old_index+1 };
          const rem = if (ts < old_lines.len) old_lines.len - ts else 0;
          const tc = @min(ctx, rem);
          var ti: usize = 0; while (ti < tc) : (ti += 1) { try hunk.addLine(.context, old_lines[ts+ti], allocator); } }
        try hunks.append(hunk);
    }
}
