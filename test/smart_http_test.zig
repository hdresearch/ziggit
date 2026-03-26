const std = @import("std");
const smart_http = @import("smart_http");

// ============================================================================
// Pkt-line parsing tests (pure, no network)
// ============================================================================

test "parse flush packet" {
    const result = try smart_http.parsePktLine("0000rest");
    try std.testing.expectEqual(smart_http.PktLineType.flush, result.pkt.line_type);
    try std.testing.expectEqual(@as(usize, 4), result.consumed);
    try std.testing.expectEqualStrings("", result.pkt.data);
}

test "parse delim packet" {
    const result = try smart_http.parsePktLine("0001rest");
    try std.testing.expectEqual(smart_http.PktLineType.delim, result.pkt.line_type);
    try std.testing.expectEqual(@as(usize, 4), result.consumed);
}

test "parse data packet" {
    const input = "000ahello\n";
    const result = try smart_http.parsePktLine(input);
    try std.testing.expectEqual(smart_http.PktLineType.data, result.pkt.line_type);
    try std.testing.expectEqualStrings("hello\n", result.pkt.data);
    try std.testing.expectEqual(@as(usize, 10), result.consumed);
}

test "parse service announcement line" {
    const input = "001e# service=git-upload-pack\n";
    const result = try smart_http.parsePktLine(input);
    try std.testing.expectEqual(smart_http.PktLineType.data, result.pkt.line_type);
    try std.testing.expectEqualStrings("# service=git-upload-pack\n", result.pkt.data);
    try std.testing.expectEqual(@as(usize, 30), result.consumed);
}

test "parse multiple pkt-lines" {
    const allocator = std.testing.allocator;
    const input = "000ahello\n0000000bworld!\n";
    const lines = try smart_http.parseAllPktLines(allocator, input);
    defer allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqual(smart_http.PktLineType.data, lines[0].line_type);
    try std.testing.expectEqualStrings("hello\n", lines[0].data);
    try std.testing.expectEqual(smart_http.PktLineType.flush, lines[1].line_type);
    try std.testing.expectEqual(smart_http.PktLineType.data, lines[2].line_type);
    try std.testing.expectEqualStrings("world!\n", lines[2].data);
}

test "parse invalid pkt-line - too short" {
    const result = smart_http.parsePktLine("00");
    try std.testing.expectError(error.InvalidPktLine, result);
}

test "parse invalid pkt-line - bad hex" {
    const result = smart_http.parsePktLine("gggg");
    try std.testing.expectError(error.InvalidPktLine, result);
}

test "parse invalid pkt-line - length too small" {
    const result = smart_http.parsePktLine("0003xxx");
    try std.testing.expectError(error.InvalidPktLine, result);
}

// ============================================================================
// Pkt-line writing tests
// ============================================================================

test "write pkt-line" {
    const allocator = std.testing.allocator;
    const line = try smart_http.writePktLine(allocator, "hello\n");
    defer allocator.free(line);
    try std.testing.expectEqualStrings("000ahello\n", line);
}

test "write pkt-line for service announcement" {
    const allocator = std.testing.allocator;
    const line = try smart_http.writePktLine(allocator, "# service=git-upload-pack\n");
    defer allocator.free(line);
    try std.testing.expectEqualStrings("001e# service=git-upload-pack\n", line);
}

test "flush packet constant" {
    try std.testing.expectEqualStrings("0000", smart_http.writeFlushPkt());
}

// ============================================================================
// Upload pack request building tests
// ============================================================================

test "build upload-pack request - single want, no haves" {
    const allocator = std.testing.allocator;
    const want: smart_http.Oid = "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d".*;
    const wants = [_]smart_http.Oid{want};

    const body = try smart_http.buildUploadPackRequest(allocator, &wants, &.{});
    defer allocator.free(body);

    // Should contain: want line with caps, flush, done
    try std.testing.expect(std.mem.indexOf(u8, body, "want 7fd1a60b01f91b314f59955a4e4d4e80d8edf11d multi_ack_detailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "0009done\n") != null);

    // Verify the pkt-line length of the first want line is correct
    // "want {40} multi_ack_detailed thin-pack side-band-64k ofs-delta\n"
    const expected_payload = "want 7fd1a60b01f91b314f59955a4e4d4e80d8edf11d multi_ack_detailed thin-pack side-band-64k ofs-delta\n";
    const expected_len = expected_payload.len + 4;
    var expected_hdr: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&expected_hdr, "{x:0>4}", .{expected_len}) catch unreachable;
    try std.testing.expect(std.mem.startsWith(u8, body, &expected_hdr));
}

test "build upload-pack request - multiple wants" {
    const allocator = std.testing.allocator;
    const want1: smart_http.Oid = "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d".*;
    const want2: smart_http.Oid = "553c2077f0edc3d5dc5d17262f6aa498e69d6f8e".*;
    const wants = [_]smart_http.Oid{ want1, want2 };

    const body = try smart_http.buildUploadPackRequest(allocator, &wants, &.{});
    defer allocator.free(body);

    // First want has capabilities
    try std.testing.expect(std.mem.indexOf(u8, body, "multi_ack_detailed") != null);
    // Second want should NOT have capabilities
    // Find the second "want" occurrence
    const first_want = std.mem.indexOf(u8, body, "want 7fd1a60b") orelse unreachable;
    const second_want = std.mem.indexOfPos(u8, body, first_want + 1, "want 553c2077") orelse unreachable;
    // Check that no capabilities appear in the second want line
    const second_line_end = std.mem.indexOfScalarPos(u8, body, second_want, '\n') orelse unreachable;
    const second_line = body[second_want..second_line_end];
    try std.testing.expect(std.mem.indexOf(u8, second_line, "multi_ack_detailed") == null);
}

test "build upload-pack request - with haves" {
    const allocator = std.testing.allocator;
    const want: smart_http.Oid = "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d".*;
    const have: smart_http.Oid = "553c2077f0edc3d5dc5d17262f6aa498e69d6f8e".*;
    const wants = [_]smart_http.Oid{want};
    const haves = [_]smart_http.Oid{have};

    const body = try smart_http.buildUploadPackRequest(allocator, &wants, &haves);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "have 553c2077f0edc3d5dc5d17262f6aa498e69d6f8e") != null);
}

// ============================================================================
// Ref discovery response parsing tests
// ============================================================================

test "parse ref discovery response" {
    const allocator = std.testing.allocator;

    // Simulate a typical response
    const response =
        "001e# service=git-upload-pack\n" ++
        "0000" ++
        "006c7fd1a60b01f91b314f59955a4e4d4e80d8edf11d HEAD\x00multi_ack thin-pack side-band-64k ofs-delta agent=git/2.0\n" ++
        "003d7fd1a60b01f91b314f59955a4e4d4e80d8edf11d refs/heads/main\n" ++
        "0000";

    var disc = try smart_http.parseRefDiscoveryResponse(allocator, response);
    defer disc.deinit();

    try std.testing.expect(disc.refs.len >= 2);
    try std.testing.expectEqualStrings("HEAD", disc.refs[0].name);
    try std.testing.expectEqualStrings("refs/heads/main", disc.refs[1].name);
    try std.testing.expectEqualStrings("7fd1a60b01f91b314f59955a4e4d4e80d8edf11d", &disc.refs[0].hash);

    // Capabilities should be extracted
    try std.testing.expect(disc.capabilities.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, disc.capabilities, "multi_ack") != null);
}

test "parse ref discovery - empty refs" {
    const allocator = std.testing.allocator;
    const response = "001e# service=git-upload-pack\n0000" ++ "0000";

    var disc = try smart_http.parseRefDiscoveryResponse(allocator, response);
    defer disc.deinit();

    try std.testing.expectEqual(@as(usize, 0), disc.refs.len);
}

// ============================================================================
// Side-band demuxing tests
// ============================================================================

test "parse fetch pack response with sideband" {
    const allocator = std.testing.allocator;

    // Build a mock response: NAK, then sideband channel 1 with PACK data
    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

    // NAK line
    try response.appendSlice("0008NAK\n");

    // Channel 1 (pack data): \x01 + "PACK" + some bytes
    const pack_payload = "\x01PACK\x00\x00\x00\x02\x00\x00\x00\x00";
    var hdr: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pack_payload.len + 4}) catch unreachable;
    try response.appendSlice(&hdr);
    try response.appendSlice(pack_payload);

    // Channel 2 (progress): \x02 + message
    const progress_payload = "\x02Counting objects: 5\n";
    _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{progress_payload.len + 4}) catch unreachable;
    try response.appendSlice(&hdr);
    try response.appendSlice(progress_payload);

    // Flush
    try response.appendSlice("0000");

    const pack_data = try smart_http.parseFetchPackResponse(allocator, response.items);
    defer allocator.free(pack_data);

    // Should get the PACK data without the channel byte
    try std.testing.expect(pack_data.len >= 4);
    try std.testing.expectEqualStrings("PACK", pack_data[0..4]);
}

test "parse fetch pack response - sideband error" {
    const allocator = std.testing.allocator;

    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

    try response.appendSlice("0008NAK\n");

    // Channel 3 (error)
    const err_payload = "\x03fatal: repo not found\n";
    var hdr: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{err_payload.len + 4}) catch unreachable;
    try response.appendSlice(&hdr);
    try response.appendSlice(err_payload);
    try response.appendSlice("0000");

    const result = smart_http.parseFetchPackResponse(allocator, response.items);
    try std.testing.expectError(error.SideBandError, result);
}

// ============================================================================
// Live HTTP tests (require network)
// ============================================================================

test "live: discoverRefs from octocat/Hello-World" {
    const allocator = std.testing.allocator;

    var disc = smart_http.discoverRefs(allocator, "https://github.com/octocat/Hello-World.git") catch |err| {
        std.debug.print("Skipping live test (network error: {})\n", .{err});
        return;
    };
    defer disc.deinit();

    // Should have at least HEAD and refs/heads/master
    try std.testing.expect(disc.refs.len > 0);

    // Find HEAD
    var found_head = false;
    var found_master = false;
    for (disc.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) found_head = true;
        if (std.mem.eql(u8, ref.name, "refs/heads/master")) found_master = true;
    }
    try std.testing.expect(found_head);
    try std.testing.expect(found_master);

    // Capabilities should include common ones
    try std.testing.expect(std.mem.indexOf(u8, disc.capabilities, "side-band-64k") != null);
}

test "live: clonePack from octocat/Hello-World" {
    const allocator = std.testing.allocator;

    var result = smart_http.clonePack(allocator, "https://github.com/octocat/Hello-World.git") catch |err| {
        std.debug.print("Skipping live test (network error: {})\n", .{err});
        return;
    };
    defer result.deinit();

    // Should have refs
    try std.testing.expect(result.refs.len > 0);

    // Pack data should start with PACK magic
    try std.testing.expect(result.pack_data.len >= 12);
    try std.testing.expectEqualStrings("PACK", result.pack_data[0..4]);

    // Pack version should be 2
    const version = std.mem.readInt(u32, result.pack_data[4..8], .big);
    try std.testing.expectEqual(@as(u32, 2), version);

    // Should have some objects
    const num_objects = std.mem.readInt(u32, result.pack_data[8..12], .big);
    try std.testing.expect(num_objects > 0);
    std.debug.print("Clone got {} refs, pack: {} bytes, {} objects\n", .{
        result.refs.len, result.pack_data.len, num_objects,
    });
}

test "live: fetchNewPack with no local refs (same as clone)" {
    const allocator = std.testing.allocator;

    const result = smart_http.fetchNewPack(allocator, "https://github.com/octocat/Hello-World.git", &.{}) catch |err| {
        std.debug.print("Skipping live test (network error: {})\n", .{err});
        return;
    };

    if (result) |*r| {
        var res = r.*;
        defer res.deinit();
        try std.testing.expect(res.pack_data.len > 0);
        try std.testing.expectEqualStrings("PACK", res.pack_data[0..4]);
    } else {
        // Should not be null with no local refs
        return error.NoPackData;
    }
}

test "live: fetchNewPack already up to date" {
    const allocator = std.testing.allocator;

    // First discover refs to get current state
    var disc = smart_http.discoverRefs(allocator, "https://github.com/octocat/Hello-World.git") catch |err| {
        std.debug.print("Skipping live test (network error: {})\n", .{err});
        return;
    };
    defer disc.deinit();

    // Build local refs matching remote
    var local_refs = std.ArrayList(smart_http.LocalRef).init(allocator);
    defer local_refs.deinit();
    for (disc.refs) |ref| {
        try local_refs.append(.{ .hash = ref.hash, .name = ref.name });
    }

    const result = smart_http.fetchNewPack(allocator, "https://github.com/octocat/Hello-World.git", local_refs.items) catch |err| {
        std.debug.print("Skipping live test (network error: {})\n", .{err});
        return;
    };

    // Should be null (already up to date)
    try std.testing.expect(result == null);
}
