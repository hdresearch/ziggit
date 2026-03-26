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

pub fn generateUnifiedDiff(old_content: []const u8, new_content: []const u8, file_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return generateUnifiedDiffWithHashes(old_content, new_content, file_path, "0000000", "1111111", allocator);
}

pub fn generateUnifiedDiffWithHashes(old_content: []const u8, new_content: []const u8, file_path: []const u8, old_hash: []const u8, new_hash: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var old_lines = std.array_list.Managed([]const u8).init(allocator);
    defer old_lines.deinit();
    
    var new_lines = std.array_list.Managed([]const u8).init(allocator);
    defer new_lines.deinit();
    
    // Split content into lines, preserving empty lines
    var old_iter = std.mem.splitSequence(u8, old_content, "\n");
    while (old_iter.next()) |line| {
        try old_lines.append(line);
    }
    
    var new_iter = std.mem.splitSequence(u8, new_content, "\n");
    while (new_iter.next()) |line| {
        try new_lines.append(line);
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
    try writer.print("diff --git a/{s} b/{s}\n", .{ file_path, file_path });
    try writer.print("index {s}..{s} 100644\n", .{ old_hash, new_hash });
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
        const remaining_lines = if (edits[last_change_idx].old_index + 1 < old_lines.len) 
            old_lines.len - (edits[last_change_idx].old_index + 1)
        else 
            0;
        const max_context = @min(context_lines, remaining_lines);
        var ctx_idx: usize = 0;
        while (ctx_idx < max_context and edits[last_change_idx].old_index + 1 + ctx_idx < old_lines.len) : (ctx_idx += 1) {
            try current_hunk.?.addLine(.context, old_lines[edits[last_change_idx].old_index + 1 + ctx_idx], allocator);
        }
        
        try hunks.append(current_hunk.?);
    }
}

/// Enhanced diff generation with options
pub fn generateUnifiedDiffWithOptions(
    old_content: []const u8, 
    new_content: []const u8, 
    file_path: []const u8, 
    old_hash: []const u8, 
    new_hash: []const u8, 
    options: DiffOptions,
    allocator: std.mem.Allocator
) !struct { diff: []u8, stats: DiffStats } {
    var old_lines = std.array_list.Managed([]const u8).init(allocator);
    defer old_lines.deinit();
    
    var new_lines = std.array_list.Managed([]const u8).init(allocator);
    defer new_lines.deinit();
    
    // Preprocess content based on options
    const processed_old = if (options.ignore_case) 
        try toLowercase(old_content, allocator) 
    else 
        old_content;
    defer if (options.ignore_case) allocator.free(processed_old);
    
    const processed_new = if (options.ignore_case) 
        try toLowercase(new_content, allocator) 
    else 
        new_content;
    defer if (options.ignore_case) allocator.free(processed_new);
    
    // Split content into lines
    var old_iter = std.mem.splitSequence(u8, processed_old, "\n");
    while (old_iter.next()) |line| {
        const clean_line = if (options.ignore_whitespace) 
            std.mem.trim(u8, line, " \t") 
        else 
            line;
        try old_lines.append(clean_line);
    }
    
    var new_iter = std.mem.splitSequence(u8, processed_new, "\n");
    while (new_iter.next()) |line| {
        const clean_line = if (options.ignore_whitespace) 
            std.mem.trim(u8, line, " \t") 
        else 
            line;
        try new_lines.append(clean_line);
    }
    
    // Generate diff hunks
    var hunks = std.array_list.Managed(DiffHunk).init(allocator);
    defer {
        for (hunks.items) |*hunk| {
            hunk.deinit(allocator);
        }
        hunks.deinit();
    }
    
    try generateDiffHunksWithOptions(old_lines.items, new_lines.items, &hunks, options, allocator);
    
    // Calculate statistics
    var stats = DiffStats{};
    for (hunks.items) |hunk| {
        for (hunk.lines.items) |line| {
            switch (line.type) {
                .add => stats.insertions += 1,
                .remove => stats.deletions += 1,
                .context => {},
            }
        }
    }
    
    // If no differences, return empty diff
    if (hunks.items.len == 0) {
        return .{ .diff = try allocator.dupe(u8, ""), .stats = stats };
    }
    
    // Generate unified diff output
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    
    const writer = result.writer();
    
    // Diff header
    try writer.print("diff --git a/{s} b/{s}\n", .{ file_path, file_path });
    try writer.print("index {s}..{s} 100644\n", .{ old_hash, new_hash });
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
    
    return .{ .diff = try result.toOwnedSlice(), .stats = stats };
}

fn generateDiffHunksWithOptions(
    old_lines: []const []const u8, 
    new_lines: []const []const u8, 
    hunks: *std.array_list.Managed(DiffHunk), 
    options: DiffOptions,
    allocator: std.mem.Allocator
) !void {
    if (old_lines.len == 0 and new_lines.len == 0) return;
    
    // Use Myers diff algorithm to find the longest common subsequence
    const lcs = try findLCSWithOptions(old_lines, new_lines, options, allocator);
    defer lcs.deinit();
    
    // Convert LCS to edit script
    var edits = try generateEditScript(old_lines, new_lines, lcs.items, allocator);
    defer edits.deinit();
    
    // Group edits into hunks with context
    try generateHunksFromEditsWithOptions(old_lines, new_lines, edits.items, hunks, options, allocator);
}

fn findLCSWithOptions(
    old_lines: []const []const u8, 
    new_lines: []const []const u8, 
    options: DiffOptions,
    allocator: std.mem.Allocator
) !std.array_list.Managed(usize) {
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
    
    // Fill LCS table with line comparison function
    for (1..m + 1) |i| {
        for (1..n + 1) |j| {
            if (linesEqual(old_lines[i - 1], new_lines[j - 1], options)) {
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
        if (linesEqual(old_lines[i - 1], new_lines[j - 1], options)) {
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

fn generateHunksFromEditsWithOptions(
    old_lines: []const []const u8, 
    new_lines: []const []const u8, 
    edits: []const Edit, 
    hunks: *std.array_list.Managed(DiffHunk), 
    options: DiffOptions,
    allocator: std.mem.Allocator
) !void {
    if (edits.len == 0) return;
    
    const context_lines = options.context_lines;
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
        const remaining_lines = if (edits[last_change_idx].old_index + 1 < old_lines.len) 
            old_lines.len - (edits[last_change_idx].old_index + 1)
        else 
            0;
        const max_context = @min(context_lines, remaining_lines);
        var ctx_idx: usize = 0;
        while (ctx_idx < max_context and edits[last_change_idx].old_index + 1 + ctx_idx < old_lines.len) : (ctx_idx += 1) {
            try current_hunk.?.addLine(.context, old_lines[edits[last_change_idx].old_index + 1 + ctx_idx], allocator);
        }
        
        try hunks.append(current_hunk.?);
    }
}

/// Compare lines with options
fn linesEqual(line1: []const u8, line2: []const u8, options: DiffOptions) bool {
    var l1 = line1;
    var l2 = line2;
    
    // Handle whitespace ignoring
    if (options.ignore_whitespace) {
        // For simplicity, just trim whitespace. A full implementation 
        // would normalize internal whitespace too
        l1 = std.mem.trim(u8, l1, " \t");
        l2 = std.mem.trim(u8, l2, " \t");
    }
    
    // Handle case insensitive comparison
    if (options.ignore_case) {
        return std.ascii.eqlIgnoreCase(l1, l2);
    } else {
        return std.mem.eql(u8, l1, l2);
    }
}

/// Convert string to lowercase
fn toLowercase(content: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result = try allocator.alloc(u8, content.len);
    for (content, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return result;
}

/// Detect if content is binary
pub fn isBinary(content: []const u8) bool {
    // Empty content is not binary
    if (content.len == 0) return false;
    
    // Simple heuristic: if we find null bytes in first 8KB, consider it binary
    const check_size = @min(content.len, 8192);
    for (content[0..check_size]) |byte| {
        if (byte == 0) return true;
    }
    
    // Check for high ratio of non-printable characters
    var non_printable: usize = 0;
    for (content[0..check_size]) |byte| {
        if (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') {
            non_printable += 1;
        }
    }
    
    // If more than 30% non-printable, consider binary
    return (non_printable * 100 / check_size) > 30;
}

/// Generate summary diff for binary files
pub fn generateBinaryDiff(old_size: usize, new_size: usize, file_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    
    const writer = result.writer();
    
    try writer.print("diff --git a/{s} b/{s}\n", .{ file_path, file_path });
    try writer.print("index binary..binary\n", .{});
    try writer.print("GIT binary patch\n", .{});
    try writer.print("Binary files a/{s} and b/{s} differ\n", .{ file_path, file_path });
    try writer.print("Old size: {} bytes, New size: {} bytes\n", .{ old_size, new_size });
    
    return try result.toOwnedSlice();
}

/// Generate word-level diff within a line
pub fn generateWordDiff(old_line: []const u8, new_line: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var old_words = std.array_list.Managed([]const u8).init(allocator);
    defer old_words.deinit();
    var new_words = std.array_list.Managed([]const u8).init(allocator);
    defer new_words.deinit();
    
    // Split lines into words
    var old_iter = std.mem.tokenize(u8, old_line, " \t");
    while (old_iter.next()) |word| {
        try old_words.append(word);
    }
    
    var new_iter = std.mem.tokenize(u8, new_line, " \t");
    while (new_iter.next()) |word| {
        try new_words.append(word);
    }
    
    // Find word-level LCS
    const lcs = try findLCS(old_words.items, new_words.items, allocator);
    defer lcs.deinit();
    
    // Generate word-level edits
    var edits = try generateEditScript(old_words.items, new_words.items, lcs.items, allocator);
    defer edits.deinit();
    
    // Build result with markup
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    
    for (edits.items) |edit| {
        switch (edit.type) {
            .keep => {
                try result.appendSlice(old_words.items[edit.old_index]);
                try result.append(' ');
            },
            .delete => {
                try result.appendSlice("[-");
                try result.appendSlice(old_words.items[edit.old_index]);
                try result.appendSlice("-] ");
            },
            .insert => {
                try result.appendSlice("{+");
                try result.appendSlice(new_words.items[edit.new_index]);
                try result.appendSlice("+} ");
            },
        }
    }
    
    return try result.toOwnedSlice();
}

/// Apply a unified diff to content (simple implementation)
pub fn applyDiff(original: []const u8, diff_content: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();
    
    // Split original content into lines
    var iter = std.mem.splitSequence(u8, original, "\n");
    while (iter.next()) |line| {
        try lines.append(line);
    }
    
    // Parse and apply diff (simplified - real implementation would be more robust)
    var diff_lines = std.mem.splitSequence(u8, diff_content, "\n");
    var current_line: usize = 0;
    
    while (diff_lines.next()) |line| {
        if (line.len == 0) continue;
        
        switch (line[0]) {
            ' ' => { // Context line
                current_line += 1;
            },
            '-' => { // Removal
                if (current_line < lines.items.len) {
                    _ = lines.swapRemove(current_line);
                }
            },
            '+' => { // Addition
                const new_line = try allocator.dupe(u8, line[1..]);
                try lines.insert(current_line, new_line);
                current_line += 1;
            },
            else => {}, // Header lines, ignore
        }
    }
    
    return try std.mem.join(allocator, "\n", lines.items);
}