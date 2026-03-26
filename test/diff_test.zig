const std = @import("std");
const testing = std.testing;
const diff = @import("../src/git/diff.zig");

test "simple line addition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const old_content = "line1\nline2\nline3";
    const new_content = "line1\nline2\nINSERTED\nline3";
    
    const result = try diff.generateUnifiedDiff(old_content, new_content, "test.txt", allocator);
    
    // Should contain the added line
    try testing.expect(std.mem.contains(u8, result, "+INSERTED"));
    try testing.expect(std.mem.contains(u8, result, "@@"));
}

test "simple line removal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const old_content = "line1\nREMOVED\nline2\nline3";
    const new_content = "line1\nline2\nline3";
    
    const result = try diff.generateUnifiedDiff(old_content, new_content, "test.txt", allocator);
    
    // Should contain the removed line
    try testing.expect(std.mem.contains(u8, result, "-REMOVED"));
    try testing.expect(std.mem.contains(u8, result, "@@"));
}

test "line modification" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const old_content = "line1\nOLD_LINE\nline3";
    const new_content = "line1\nNEW_LINE\nline3";
    
    const result = try diff.generateUnifiedDiff(old_content, new_content, "test.txt", allocator);
    
    // Should show both removal and addition
    try testing.expect(std.mem.contains(u8, result, "-OLD_LINE"));
    try testing.expect(std.mem.contains(u8, result, "+NEW_LINE"));
}

test "no changes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const content = "line1\nline2\nline3";
    
    const result = try diff.generateUnifiedDiff(content, content, "test.txt", allocator);
    
    // Should return empty diff
    try testing.expect(result.len == 0);
}

test "empty files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const result1 = try diff.generateUnifiedDiff("", "", "test.txt", allocator);
    try testing.expect(result1.len == 0);
    
    const result2 = try diff.generateUnifiedDiff("", "new content", "test.txt", allocator);
    try testing.expect(std.mem.contains(u8, result2, "+new content"));
    
    const result3 = try diff.generateUnifiedDiff("old content", "", "test.txt", allocator);
    try testing.expect(std.mem.contains(u8, result3, "-old content"));
}

test "large file diff performance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create large content
    var old_content = std.ArrayList(u8).init(allocator);
    defer old_content.deinit();
    var new_content = std.ArrayList(u8).init(allocator);
    defer new_content.deinit();
    
    for (0..1000) |i| {
        try old_content.writer().print("line{d}\n", .{i});
        if (i == 500) {
            try new_content.writer().print("MODIFIED_LINE_{d}\n", .{i});
        } else {
            try new_content.writer().print("line{d}\n", .{i});
        }
    }
    
    const start_time = std.time.milliTimestamp();
    
    const result = try diff.generateUnifiedDiff(old_content.items, new_content.items, "large.txt", allocator);
    
    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;
    
    // Should complete in reasonable time (less than 1 second for 1000 lines)
    try testing.expect(duration < 1000);
    
    // Should contain the modification
    try testing.expect(std.mem.contains(u8, result, "-line500"));
    try testing.expect(std.mem.contains(u8, result, "+MODIFIED_LINE_500"));
}

test "context lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const old_content = 
        \\context1
        \\context2
        \\context3
        \\old_line
        \\context4
        \\context5
        \\context6
    ;
    
    const new_content = 
        \\context1
        \\context2
        \\context3
        \\new_line
        \\context4
        \\context5
        \\context6
    ;
    
    const result = try diff.generateUnifiedDiff(old_content, new_content, "test.txt", allocator);
    
    // Should include context lines around the change
    try testing.expect(std.mem.contains(u8, result, " context2"));
    try testing.expect(std.mem.contains(u8, result, " context3"));
    try testing.expect(std.mem.contains(u8, result, "-old_line"));
    try testing.expect(std.mem.contains(u8, result, "+new_line"));
    try testing.expect(std.mem.contains(u8, result, " context4"));
    try testing.expect(std.mem.contains(u8, result, " context5"));
}

test "multiple hunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var old_lines = std.ArrayList([]const u8).init(allocator);
    defer old_lines.deinit();
    var new_lines = std.ArrayList([]const u8).init(allocator);
    defer new_lines.deinit();
    
    // Create content with changes far apart
    for (0..50) |i| {
        const line = try std.fmt.allocPrint(allocator, "line{d}", .{i});
        if (i == 5) {
            try old_lines.append("old_line5");
            try new_lines.append("new_line5");
        } else if (i == 45) {
            try old_lines.append("old_line45");
            try new_lines.append("new_line45");
        } else {
            try old_lines.append(line);
            try new_lines.append(line);
        }
    }
    
    const old_content = try std.mem.join(allocator, "\n", old_lines.items);
    const new_content = try std.mem.join(allocator, "\n", new_lines.items);
    
    const result = try diff.generateUnifiedDiff(old_content, new_content, "test.txt", allocator);
    
    // Should have multiple @@ hunk headers
    const hunk_count = std.mem.count(u8, result, "@@");
    try testing.expect(hunk_count >= 2);
}

test "diff with custom hashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const old_content = "old content";
    const new_content = "new content";
    const old_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const new_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    
    const result = try diff.generateUnifiedDiffWithHashes(
        old_content, new_content, "test.txt", old_hash, new_hash, allocator
    );
    
    try testing.expect(std.mem.contains(u8, result, old_hash));
    try testing.expect(std.mem.contains(u8, result, new_hash));
    try testing.expect(std.mem.contains(u8, result, "index"));
}

test "diff line types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test DiffLine creation
    const line1 = diff.DiffLine.init(.context, "context line", 1, 1);
    const line2 = diff.DiffLine.init(.add, "added line", null, 2);
    const line3 = diff.DiffLine.init(.remove, "removed line", 2, null);
    
    try testing.expect(line1.type == .context);
    try testing.expect(line1.old_line.? == 1);
    try testing.expect(line1.new_line.? == 1);
    
    try testing.expect(line2.type == .add);
    try testing.expect(line2.old_line == null);
    try testing.expect(line2.new_line.? == 2);
    
    try testing.expect(line3.type == .remove);
    try testing.expect(line3.old_line.? == 2);
    try testing.expect(line3.new_line == null);
}

test "diff hunk creation and manipulation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var hunk = diff.DiffHunk.init(allocator);
    defer hunk.deinit(allocator);
    
    hunk.old_start = 10;
    hunk.new_start = 10;
    
    try hunk.addLine(.context, "unchanged", allocator);
    try hunk.addLine(.remove, "removed", allocator);
    try hunk.addLine(.add, "added", allocator);
    try hunk.addLine(.context, "more context", allocator);
    
    try testing.expect(hunk.lines.items.len == 4);
    try testing.expect(hunk.old_count == 3); // context + remove + context
    try testing.expect(hunk.new_count == 3); // context + add + context
    
    try testing.expect(hunk.lines.items[0].type == .context);
    try testing.expect(hunk.lines.items[1].type == .remove);
    try testing.expect(hunk.lines.items[2].type == .add);
    try testing.expect(hunk.lines.items[3].type == .context);
}

test "whitespace handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const old_content = "line with spaces   \nline2";
    const new_content = "line with spaces\nline2";
    
    const result = try diff.generateUnifiedDiff(old_content, new_content, "test.txt", allocator);
    
    // Should detect the whitespace change
    try testing.expect(std.mem.contains(u8, result, "-line with spaces   "));
    try testing.expect(std.mem.contains(u8, result, "+line with spaces"));
}

test "binary-like content handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const old_content = "line1\x00\x01\x02binary\nline3";
    const new_content = "line1\x00\x01\x03binary\nline3";
    
    const result = try diff.generateUnifiedDiff(old_content, new_content, "test.txt", allocator);
    
    // Should still generate a diff even with binary content
    try testing.expect(result.len > 0);
}