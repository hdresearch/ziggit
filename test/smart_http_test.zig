const std = @import("std");
const smart_http = @import("smart_http");

// ============================================================================
// Pkt-line parsing tests (pure, no network)
// ============================================================================

test "parsePktLine on '0006a\\n' should return 'a\\n'" {
    const result = try smart_http.parsePktLine("0006a\n");
    try std.testing.expectEqual(smart_http.PktLineType.data, result.pkt.line_type);
    try std.testing.expectEqualStrings("a\n", result.pkt.data);
    try std.testing.expectEqual(@as(usize, 6), result.consumed);
}

test "parsePktLine on '0000' (flush) should return null-equivalent" {
    const result = try smart_http.parsePktLine("0000");
    try std.testing.expectEqual(smart_http.PktLineType.flush, result.pkt.line_type);
    try std.testing.expectEqualStrings("", result.pkt.data);
    try std.testing.expectEqual(@as(usize, 4), result.consumed);
}

test "parsePktLine on multi-line input should parse sequentially" {
    const input = "0006a\n0006b\n0000";

    // First line
    const r1 = try smart_http.parsePktLine(input);
    try std.testing.expectEqual(smart_http.PktLineType.data, r1.pkt.line_type);
    try std.testing.expectEqualStrings("a\n", r1.pkt.data);
    try std.testing.expectEqual(@as(usize, 6), r1.consumed);

    // Second line
    const r2 = try smart_http.parsePktLine(input[r1.consumed..]);
    try std.testing.expectEqual(smart_http.PktLineType.data, r2.pkt.line_type);
    try std.testing.expectEqualStrings("b\n", r2.pkt.data);
    try std.testing.expectEqual(@as(usize, 6), r2.consumed);

    // Flush
    const r3 = try smart_http.parsePktLine(input[r1.consumed + r2.consumed ..]);
    try std.testing.expectEqual(smart_http.PktLineType.flush, r3.pkt.line_type);
}

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

test "parse multiple pkt-lines with parseAllPktLines" {
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
    const first_want = std.mem.indexOf(u8, body, "want 7fd1a60b") orelse unreachable;
    const second_want = std.mem.indexOfPos(u8, body, first_want + 1, "want 553c2077") orelse unreachable;
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

test "parse ref discovery response - extract refs correctly" {
    const allocator = std.testing.allocator;

    // Simulate a typical /info/refs response
    const response =
        "001e# service=git-upload-pack\n" ++
        "0000" ++
        "006c7fd1a60b01f91b314f59955a4e4d4e80d8edf11d HEAD\x00multi_ack thin-pack side-band-64k ofs-delta agent=git/2.0\n" ++
        "003d7fd1a60b01f91b314f59955a4e4d4e80d8edf11d refs/heads/main\n" ++
        "0000";

    var disc = try smart_http.parseRefDiscoveryResponse(allocator, response);
    defer disc.deinit();

    // Should find exactly 2 refs
    try std.testing.expectEqual(@as(usize, 2), disc.refs.len);

    // Verify ref names
    try std.testing.expectEqualStrings("HEAD", disc.refs[0].name);
    try std.testing.expectEqualStrings("refs/heads/main", disc.refs[1].name);

    // Verify hashes
    try std.testing.expectEqualStrings("7fd1a60b01f91b314f59955a4e4d4e80d8edf11d", &disc.refs[0].hash);
    try std.testing.expectEqualStrings("7fd1a60b01f91b314f59955a4e4d4e80d8edf11d", &disc.refs[1].hash);

    // Capabilities should be extracted from the first ref line
    try std.testing.expect(disc.capabilities.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, disc.capabilities, "multi_ack") != null);
    try std.testing.expect(std.mem.indexOf(u8, disc.capabilities, "side-band-64k") != null);
}

test "parse ref discovery - multiple refs with different hashes" {
    const allocator = std.testing.allocator;

    const response =
        "001e# service=git-upload-pack\n" ++
        "0000" ++
        "004aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HEAD\x00multi_ack side-band-64k\n" ++
        "003dbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/heads/main\n" ++
        "003ecccccccccccccccccccccccccccccccccccccccc refs/tags/v1.0.0\n" ++
        "0000";

    var disc = try smart_http.parseRefDiscoveryResponse(allocator, response);
    defer disc.deinit();

    try std.testing.expectEqual(@as(usize, 3), disc.refs.len);
    try std.testing.expectEqualStrings("HEAD", disc.refs[0].name);
    try std.testing.expectEqualStrings("refs/heads/main", disc.refs[1].name);
    try std.testing.expectEqualStrings("refs/tags/v1.0.0", disc.refs[2].name);

    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &disc.refs[0].hash);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", &disc.refs[1].hash);
    try std.testing.expectEqualStrings("cccccccccccccccccccccccccccccccccccccccc", &disc.refs[2].hash);
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
// Additional pkt-line edge cases
// ============================================================================

test "parsePktLine - empty input" {
    const result = smart_http.parsePktLine("");
    try std.testing.expectError(error.InvalidPktLine, result);
}

test "parsePktLine - exactly 4 bytes non-special" {
    // "0004" means pkt-line of length 4, which has 0 bytes of payload
    const result = try smart_http.parsePktLine("0004");
    try std.testing.expectEqual(smart_http.PktLineType.data, result.pkt.line_type);
    try std.testing.expectEqualStrings("", result.pkt.data);
    try std.testing.expectEqual(@as(usize, 4), result.consumed);
}

test "parsePktLine - length exceeds available data" {
    // Says 20 bytes total but only 10 available
    const result = smart_http.parsePktLine("0014short");
    try std.testing.expectError(error.InvalidPktLine, result);
}

test "parsePktLine - maximum single-byte payload" {
    // "0005X" = length 5, payload "X"
    const result = try smart_http.parsePktLine("0005X");
    try std.testing.expectEqual(smart_http.PktLineType.data, result.pkt.line_type);
    try std.testing.expectEqualStrings("X", result.pkt.data);
    try std.testing.expectEqual(@as(usize, 5), result.consumed);
}

test "parsePktLine - length 0002 is invalid (less than 4)" {
    const result = smart_http.parsePktLine("0002xx");
    try std.testing.expectError(error.InvalidPktLine, result);
}

test "parsePktLine - mixed case hex should still parse" {
    // "000A" = 10 decimal, same as "000a"
    const input = "000Ahello\n";
    const result = try smart_http.parsePktLine(input);
    try std.testing.expectEqual(smart_http.PktLineType.data, result.pkt.line_type);
    try std.testing.expectEqualStrings("hello\n", result.pkt.data);
}

test "parseAllPktLines - empty input" {
    const allocator = std.testing.allocator;
    const lines = try smart_http.parseAllPktLines(allocator, "");
    defer allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

test "parseAllPktLines - just a flush" {
    const allocator = std.testing.allocator;
    const lines = try smart_http.parseAllPktLines(allocator, "0000");
    defer allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(smart_http.PktLineType.flush, lines[0].line_type);
}

test "parseAllPktLines - multiple flushes" {
    const allocator = std.testing.allocator;
    const lines = try smart_http.parseAllPktLines(allocator, "000000000000");
    defer allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    for (lines) |line| {
        try std.testing.expectEqual(smart_http.PktLineType.flush, line.line_type);
    }
}

test "parseAllPktLines - data then delim then data" {
    const allocator = std.testing.allocator;
    const input = "0005A0001" ++ "0005B";
    const lines = try smart_http.parseAllPktLines(allocator, input);
    defer allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqual(smart_http.PktLineType.data, lines[0].line_type);
    try std.testing.expectEqualStrings("A", lines[0].data);
    try std.testing.expectEqual(smart_http.PktLineType.delim, lines[1].line_type);
    try std.testing.expectEqual(smart_http.PktLineType.data, lines[2].line_type);
    try std.testing.expectEqualStrings("B", lines[2].data);
}

// ============================================================================
// Pkt-line write round-trip tests
// ============================================================================

test "write then parse pkt-line round-trip" {
    const allocator = std.testing.allocator;
    const payload = "test payload data\n";
    const written = try smart_http.writePktLine(allocator, payload);
    defer allocator.free(written);

    const parsed = try smart_http.parsePktLine(written);
    try std.testing.expectEqual(smart_http.PktLineType.data, parsed.pkt.line_type);
    try std.testing.expectEqualStrings(payload, parsed.pkt.data);
    try std.testing.expectEqual(written.len, parsed.consumed);
}

test "write pkt-line - empty payload" {
    const allocator = std.testing.allocator;
    const written = try smart_http.writePktLine(allocator, "");
    defer allocator.free(written);
    try std.testing.expectEqualStrings("0004", written);

    const parsed = try smart_http.parsePktLine(written);
    try std.testing.expectEqual(smart_http.PktLineType.data, parsed.pkt.line_type);
    try std.testing.expectEqualStrings("", parsed.pkt.data);
}

// ============================================================================
// Ref discovery edge cases
// ============================================================================

test "parse ref discovery - no service announcement" {
    const allocator = std.testing.allocator;
    // Some servers might not send the service announcement
    const response =
        "004aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HEAD\x00multi_ack side-band-64k\n" ++
        "003dbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/heads/main\n" ++
        "0000";

    var disc = try smart_http.parseRefDiscoveryResponse(allocator, response);
    defer disc.deinit();

    try std.testing.expectEqual(@as(usize, 2), disc.refs.len);
    try std.testing.expectEqualStrings("HEAD", disc.refs[0].name);
    try std.testing.expectEqualStrings("refs/heads/main", disc.refs[1].name);
}

test "parse ref discovery - capabilities extraction" {
    const allocator = std.testing.allocator;
    const response =
        "001e# service=git-upload-pack\n" ++
        "0000" ++
        "006faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HEAD\x00multi_ack thin-pack side-band-64k ofs-delta agent=git/2.39.0\n" ++
        "0000";

    var disc = try smart_http.parseRefDiscoveryResponse(allocator, response);
    defer disc.deinit();

    try std.testing.expect(std.mem.indexOf(u8, disc.capabilities, "multi_ack") != null);
    try std.testing.expect(std.mem.indexOf(u8, disc.capabilities, "thin-pack") != null);
    try std.testing.expect(std.mem.indexOf(u8, disc.capabilities, "agent=git/2.39.0") != null);
}

test "parse ref discovery - refs with peeled tags" {
    const allocator = std.testing.allocator;
    const response =
        "001e# service=git-upload-pack\n" ++
        "0000" ++
        "004aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HEAD\x00multi_ack side-band-64k\n" ++
        "003ebbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/tags/v1.0.0\n" ++
        "0041cccccccccccccccccccccccccccccccccccccccc refs/tags/v1.0.0^{}\n" ++
        "0000";

    var disc = try smart_http.parseRefDiscoveryResponse(allocator, response);
    defer disc.deinit();

    try std.testing.expectEqual(@as(usize, 3), disc.refs.len);
    try std.testing.expectEqualStrings("refs/tags/v1.0.0^{}", disc.refs[2].name);
}

// ============================================================================
// Fetch pack response edge cases
// ============================================================================

test "parse fetch pack response - empty yields NoPackData" {
    const allocator = std.testing.allocator;
    const result = smart_http.parseFetchPackResponse(allocator, "0000");
    try std.testing.expectError(error.NoPackData, result);
}

test "parse fetch pack response - NAK only yields NoPackData" {
    const allocator = std.testing.allocator;
    const result = smart_http.parseFetchPackResponse(allocator, "0008NAK\n0000");
    try std.testing.expectError(error.NoPackData, result);
}

test "parse fetch pack response - multiple sideband pack chunks" {
    const allocator = std.testing.allocator;

    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

    try response.appendSlice("0008NAK\n");

    // First chunk: channel 1 with PACK header
    const chunk1 = "\x01PACK";
    var hdr: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{chunk1.len + 4}) catch unreachable;
    try response.appendSlice(&hdr);
    try response.appendSlice(chunk1);

    // Second chunk: more pack data
    const chunk2 = "\x01\x00\x00\x00\x02\x00\x00\x00\x01";
    _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{chunk2.len + 4}) catch unreachable;
    try response.appendSlice(&hdr);
    try response.appendSlice(chunk2);

    try response.appendSlice("0000");

    const pack_data = try smart_http.parseFetchPackResponse(allocator, response.items);
    defer allocator.free(pack_data);

    // Should concatenate both chunks (minus channel byte)
    try std.testing.expectEqualStrings("PACK", pack_data[0..4]);
    try std.testing.expect(pack_data.len == 4 + 8); // "PACK" + 8 bytes from chunk2
}

test "parse fetch pack response - progress messages ignored" {
    const allocator = std.testing.allocator;

    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

    try response.appendSlice("0008NAK\n");

    // Progress (channel 2)
    const prog = "\x02remote: Counting objects: 100%\n";
    var hdr: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{prog.len + 4}) catch unreachable;
    try response.appendSlice(&hdr);
    try response.appendSlice(prog);

    // Pack data (channel 1)
    const pack = "\x01PACK\x00\x00\x00\x02\x00\x00\x00\x00";
    _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pack.len + 4}) catch unreachable;
    try response.appendSlice(&hdr);
    try response.appendSlice(pack);

    try response.appendSlice("0000");

    const pack_data = try smart_http.parseFetchPackResponse(allocator, response.items);
    defer allocator.free(pack_data);

    try std.testing.expectEqualStrings("PACK", pack_data[0..4]);
}

// ============================================================================
// Upload pack request structure tests
// ============================================================================

test "build upload-pack request - empty wants" {
    const allocator = std.testing.allocator;
    const body = try smart_http.buildUploadPackRequest(allocator, &.{}, &.{});
    defer allocator.free(body);

    // Should have: flush + done
    try std.testing.expect(std.mem.indexOf(u8, body, "0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "0009done\n") != null);
    // Should NOT have any want lines
    try std.testing.expect(std.mem.indexOf(u8, body, "want") == null);
}

test "build upload-pack request - multiple haves" {
    const allocator = std.testing.allocator;
    const want: smart_http.Oid = "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d".*;
    const have1: smart_http.Oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".*;
    const have2: smart_http.Oid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".*;
    const wants = [_]smart_http.Oid{want};
    const haves = [_]smart_http.Oid{ have1, have2 };

    const body = try smart_http.buildUploadPackRequest(allocator, &wants, &haves);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "have aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "have bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") != null);
}

test "build upload-pack request ends with done" {
    const allocator = std.testing.allocator;
    const want: smart_http.Oid = "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d".*;
    const wants = [_]smart_http.Oid{want};
    const body = try smart_http.buildUploadPackRequest(allocator, &wants, &.{});
    defer allocator.free(body);

    try std.testing.expect(std.mem.endsWith(u8, body, "0009done\n"));
}
