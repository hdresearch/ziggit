const std = @import("std");

// ============================================================================
// Types
// ============================================================================

pub const Oid = [40]u8;

pub const Ref = struct {
    hash: Oid,
    name: []const u8,
};

pub const RefDiscovery = struct {
    refs: []Ref,
    capabilities: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RefDiscovery) void {
        for (self.refs) |ref| {
            self.allocator.free(ref.name);
        }
        self.allocator.free(self.refs);
        self.allocator.free(self.capabilities);
    }
};

pub const CloneResult = struct {
    refs: []Ref,
    capabilities: []const u8,
    pack_data: []u8,
    shallow_commits: []Oid,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CloneResult) void {
        for (self.refs) |ref| {
            self.allocator.free(ref.name);
        }
        self.allocator.free(self.refs);
        self.allocator.free(self.capabilities);
        self.allocator.free(self.pack_data);
        self.allocator.free(self.shallow_commits);
    }
};

pub const FetchResult = struct {
    refs: []Ref,
    capabilities: []const u8,
    pack_data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FetchResult) void {
        for (self.refs) |ref| {
            self.allocator.free(ref.name);
        }
        self.allocator.free(self.refs);
        self.allocator.free(self.capabilities);
        self.allocator.free(self.pack_data);
    }
};

pub const SmartHttpError = error{
    InvalidPktLine,
    InvalidResponse,
    ServerError,
    HttpError,
    InvalidUrl,
    SideBandError,
    NoPackData,
    OutOfMemory,
    Overflow,
    InvalidCharacter,
    EndOfStream,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    UnexpectedReadFailure,
    TlsFailure,
    UnexpectedWriteFailure,
    HttpRedirectError,
    TooManyHttpRedirects,
    UriMissingHost,
    CertificateBundleError,
};

// ============================================================================
// Pkt-line parsing and writing
// ============================================================================

pub const PktLineType = enum {
    data,
    flush,
    delim,
};

pub const PktLine = struct {
    line_type: PktLineType,
    data: []const u8, // payload without the 4-byte length prefix
};

/// Parse a single pkt-line from the given data. Returns the parsed line and
/// the number of bytes consumed from the input.
pub fn parsePktLine(data: []const u8) !struct { pkt: PktLine, consumed: usize } {
    if (data.len < 4) return error.InvalidPktLine;

    const len_hex = data[0..4];

    // Check for flush (0000) and delim (0001)
    if (std.mem.eql(u8, len_hex, "0000")) {
        return .{ .pkt = .{ .line_type = .flush, .data = "" }, .consumed = 4 };
    }
    if (std.mem.eql(u8, len_hex, "0001")) {
        return .{ .pkt = .{ .line_type = .delim, .data = "" }, .consumed = 4 };
    }

    const pkt_len = std.fmt.parseInt(u16, len_hex, 16) catch return error.InvalidPktLine;
    if (pkt_len < 4) return error.InvalidPktLine;
    const total_len: usize = @intCast(pkt_len);
    if (data.len < total_len) return error.InvalidPktLine;

    return .{
        .pkt = .{ .line_type = .data, .data = data[4..total_len] },
        .consumed = total_len,
    };
}

/// Parse all pkt-lines from data. Returns slice of PktLines (data slices point into input).
pub fn parseAllPktLines(allocator: std.mem.Allocator, data: []const u8) ![]PktLine {
    var lines = std.array_list.Managed(PktLine).init(allocator);
    errdefer lines.deinit();

    var offset: usize = 0;
    while (offset < data.len) {
        const result = try parsePktLine(data[offset..]);
        try lines.append(result.pkt);
        offset += result.consumed;
    }

    return lines.toOwnedSlice();
}

/// Write a pkt-line for the given payload (including trailing \n if desired).
/// The caller should include \n in the payload if needed.
pub fn writePktLine(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const total_len = payload.len + 4;
    if (total_len > 65535) return error.Overflow;

    var buf = try allocator.alloc(u8, total_len);
    _ = std.fmt.bufPrint(buf[0..4], "{x:0>4}", .{total_len}) catch unreachable;
    @memcpy(buf[4..], payload);
    return buf;
}

/// Write a flush packet.
pub fn writeFlushPkt() []const u8 {
    return "0000";
}

/// Build the request body for git-upload-pack.
/// If depth > 0, sends "deepen N" for shallow clone support.
pub fn buildUploadPackRequest(allocator: std.mem.Allocator, wants: []const Oid, haves: []const Oid) ![]u8 {
    return buildUploadPackRequestWithDepth(allocator, wants, haves, 0);
}

pub fn buildUploadPackRequestWithDepth(allocator: std.mem.Allocator, wants: []const Oid, haves: []const Oid, depth: u32) ![]u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    errdefer body.deinit();

    // Include "shallow" and "deepen-since" in capabilities when doing shallow clone
    // "no-progress" suppresses progress messages, reducing response size and parse work
    const capabilities = if (depth > 0)
        "multi_ack_detailed thin-pack side-band-64k ofs-delta shallow deepen-since deepen-not no-progress"
    else
        "multi_ack_detailed thin-pack side-band-64k ofs-delta no-progress";

    for (wants, 0..) |want, i| {
        var line_buf: [256]u8 = undefined;
        const line = if (i == 0)
            std.fmt.bufPrint(&line_buf, "want {s} {s}\n", .{ want, capabilities }) catch unreachable
        else
            std.fmt.bufPrint(&line_buf, "want {s}\n", .{want}) catch unreachable;

        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // Send deepen command before flush if depth is specified
    if (depth > 0) {
        var deepen_buf: [64]u8 = undefined;
        const deepen_line = std.fmt.bufPrint(&deepen_buf, "deepen {d}\n", .{depth}) catch unreachable;
        const deepen_pkt_len = deepen_line.len + 4;
        var deepen_hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&deepen_hdr, "{x:0>4}", .{deepen_pkt_len}) catch unreachable;
        try body.appendSlice(&deepen_hdr);
        try body.appendSlice(deepen_line);
    }

    // Flush after wants (and deepen)
    try body.appendSlice("0000");

    // Haves
    for (haves) |have| {
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "have {s}\n", .{have}) catch unreachable;
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // done
    try body.appendSlice("0009done\n");

    return body.toOwnedSlice();
}

// ============================================================================
// HTTP helpers
// ============================================================================

const max_response_size = 256 * 1024 * 1024; // 256MB

/// Authentication info extracted from URL or environment
const AuthInfo = struct {
    token: ?[]const u8,
    clean_url: []const u8,
    needs_free: bool,
};

fn extractAuth(allocator: std.mem.Allocator, url: []const u8) !AuthInfo {
    // Check for x-access-token format: https://x-access-token:TOKEN@github.com/...
    if (std.mem.indexOf(u8, url, "x-access-token:")) |start| {
        const prefix_end = start + "x-access-token:".len;
        if (std.mem.indexOfScalarPos(u8, url, prefix_end, '@')) |at_pos| {
            const token = url[prefix_end..at_pos];
            // Reconstruct URL without auth: https:// + rest after @
            const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
            const clean = try std.fmt.allocPrint(allocator, "{s}{s}", .{
                url[0 .. scheme_end + 3],
                url[at_pos + 1 ..],
            });
            return .{ .token = token, .clean_url = clean, .needs_free = true };
        }
    }

    // Check GITHUB_TOKEN env var, then fall back to GIT_TOKEN
    // Use std.posix.getenv (no allocation) instead of getEnvVarOwned
    if (std.posix.getenv("GITHUB_TOKEN") orelse std.posix.getenv("GIT_TOKEN")) |t| {
        return .{ .token = t, .clean_url = url, .needs_free = false };
    }

    return .{ .token = null, .clean_url = url, .needs_free = false };
}

fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    return httpGetWithClient(allocator, null, url);
}

fn httpGetWithClient(allocator: std.mem.Allocator, existing_client: ?*std.http.Client, url: []const u8) ![]u8 {
    return httpGetWithClientOpts(allocator, existing_client, url, false);
}

fn httpGetWithClientV2(allocator: std.mem.Allocator, existing_client: ?*std.http.Client, url: []const u8) ![]u8 {
    return httpGetWithClientOpts(allocator, existing_client, url, true);
}

fn httpGetWithClientOpts(allocator: std.mem.Allocator, existing_client: ?*std.http.Client, url: []const u8, v2: bool) ![]u8 {
    const auth = try extractAuth(allocator, url);
    defer if (auth.needs_free) allocator.free(@constCast(auth.clean_url));

    var owned_client: ?std.http.Client = if (existing_client == null) std.http.Client{ .allocator = allocator } else null;
    defer if (owned_client) |*c| c.deinit();
    const client = if (existing_client) |c| c else &(owned_client.?);

    const uri = std.Uri.parse(auth.clean_url) catch return error.InvalidUrl;

    // Build extra headers
    var headers_buf: [4]std.http.Header = undefined;
    var n_headers: usize = 0;
    headers_buf[n_headers] = .{ .name = "User-Agent", .value = "ziggit/0.1" };
    n_headers += 1;
    if (v2) {
        headers_buf[n_headers] = .{ .name = "Git-Protocol", .value = "version=2" };
        n_headers += 1;
    }
    if (auth.token) |token| {
        var bearer_buf: [512]u8 = undefined;
        const bearer = std.fmt.bufPrint(&bearer_buf, "Bearer {s}", .{token}) catch return error.Overflow;
        headers_buf[n_headers] = .{ .name = "Authorization", .value = bearer };
        n_headers += 1;
    }

    var req = client.request(.GET, uri, .{
        .extra_headers = headers_buf[0..n_headers],
    }) catch return error.HttpError;
    defer req.deinit();

    req.sendBodiless() catch return error.HttpError;

    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.HttpError;

    if (response.head.status != .ok) return error.HttpError;

    var transfer_buf: [65536]u8 = undefined;
    return response.reader(&transfer_buf).allocRemaining(allocator, .limited(max_response_size)) catch return error.HttpError;
}

fn httpPost(allocator: std.mem.Allocator, url: []const u8, body: []const u8, content_type: []const u8) ![]u8 {
    return httpPostWithClient(allocator, null, url, body, content_type);
}

fn httpPostWithClient(allocator: std.mem.Allocator, existing_client: ?*std.http.Client, url: []const u8, body: []const u8, content_type: []const u8) ![]u8 {
    return httpPostWithClientOpts(allocator, existing_client, url, body, content_type, false);
}

fn httpPostWithClientV2(allocator: std.mem.Allocator, existing_client: ?*std.http.Client, url: []const u8, body: []const u8, content_type: []const u8) ![]u8 {
    return httpPostWithClientOpts(allocator, existing_client, url, body, content_type, true);
}

fn httpPostWithClientOpts(allocator: std.mem.Allocator, existing_client: ?*std.http.Client, url: []const u8, body: []const u8, content_type: []const u8, v2: bool) ![]u8 {
    const trace_timing = std.posix.getenv("ZIGGIT_TRACE_TIMING") != null;
    var post_timer = if (trace_timing) std.time.Timer.start() catch null else null;

    const auth = try extractAuth(allocator, url);
    defer if (auth.needs_free) allocator.free(@constCast(auth.clean_url));

    var owned_client: ?std.http.Client = if (existing_client == null) std.http.Client{ .allocator = allocator } else null;
    defer if (owned_client) |*c| c.deinit();
    const client = if (existing_client) |c| c else &(owned_client.?);

    var server_header_buffer: [16384]u8 = undefined;
    const uri = std.Uri.parse(auth.clean_url) catch return error.InvalidUrl;

    var headers_buf: [5]std.http.Header = undefined;
    var n_headers: usize = 0;
    headers_buf[n_headers] = .{ .name = "User-Agent", .value = "ziggit/0.1" };
    n_headers += 1;
    headers_buf[n_headers] = .{ .name = "Content-Type", .value = content_type };
    n_headers += 1;
    if (v2) {
        headers_buf[n_headers] = .{ .name = "Git-Protocol", .value = "version=2" };
        n_headers += 1;
    }
    if (auth.token) |token| {
        var bearer_buf: [512]u8 = undefined;
        const bearer = std.fmt.bufPrint(&bearer_buf, "Bearer {s}", .{token}) catch return error.Overflow;
        headers_buf[n_headers] = .{ .name = "Authorization", .value = bearer };
        n_headers += 1;
    }

    var req = client.request(.POST, uri, .{
        .extra_headers = headers_buf[0..n_headers],
    }) catch return error.HttpError;
    defer req.deinit();

    if (trace_timing) {
        if (post_timer) |*t| {
            std.debug.print("[timing]       POST connect: {}ms\n", .{t.read() / std.time.ns_per_ms});
            t.reset();
        }
    }

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = req.sendBodyUnflushed(&server_header_buffer) catch return error.HttpError;
    body_writer.writer.writeAll(body) catch return error.HttpError;
    body_writer.end() catch return error.HttpError;
    req.connection.?.flush() catch return error.HttpError;

    if (trace_timing) {
        if (post_timer) |*t| {
            std.debug.print("[timing]       POST send body ({} bytes): {}ms\n", .{ body.len, t.read() / std.time.ns_per_ms });
            t.reset();
        }
    }

    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.HttpError;

    if (trace_timing) {
        if (post_timer) |*t| {
            std.debug.print("[timing]       POST recv headers: {}ms\n", .{t.read() / std.time.ns_per_ms});
            t.reset();
        }
    }

    if (response.head.status != .ok) return error.HttpError;

    // Read response body (use allocRemaining which handles chunked transfer correctly)
    // Use 256KB buffer to reduce number of read syscalls for pack data responses
    var transfer_buf3: [262144]u8 = undefined;
    const result = response.reader(&transfer_buf3).allocRemaining(allocator, .limited(max_response_size)) catch return error.HttpError;

    if (trace_timing) {
        if (post_timer) |*t| {
            std.debug.print("[timing]       POST recv body ({} bytes): {}ms\n", .{ result.len, t.read() / std.time.ns_per_ms });
        }
    }

    return result;
}

// ============================================================================
// discoverRefs
// ============================================================================

pub fn discoverRefs(allocator: std.mem.Allocator, url: []const u8) !RefDiscovery {
    return discoverRefsWithClient(allocator, null, url);
}

fn discoverRefsWithClient(allocator: std.mem.Allocator, client: ?*std.http.Client, url: []const u8) !RefDiscovery {
    // Normalize URL: strip trailing /
    var base = url;
    while (base.len > 0 and base[base.len - 1] == '/') {
        base = base[0 .. base.len - 1];
    }

    const ref_url = try std.fmt.allocPrint(allocator, "{s}/info/refs?service=git-upload-pack", .{base});
    defer allocator.free(ref_url);

    const body = try httpGetWithClient(allocator, client, ref_url);
    defer allocator.free(body);

    return parseRefDiscoveryResponse(allocator, body);
}

/// Parse the response body of GET /info/refs?service=git-upload-pack
pub fn parseRefDiscoveryResponse(allocator: std.mem.Allocator, data: []const u8) !RefDiscovery {
    var refs = std.array_list.Managed(Ref).init(allocator);
    errdefer {
        for (refs.items) |ref| allocator.free(ref.name);
        refs.deinit();
    }
    var capabilities: []const u8 = "";
    var caps_allocated = false;

    var offset: usize = 0;
    var first_ref = true;

    while (offset < data.len) {
        const result = parsePktLine(data[offset..]) catch break;
        offset += result.consumed;

        if (result.pkt.line_type != .data) continue;

        var line = result.pkt.data;
        // Skip the service announcement line (starts with #)
        if (line.len > 0 and line[0] == '#') continue;

        // Strip trailing newline
        if (line.len > 0 and line[line.len - 1] == '\n') {
            line = line[0 .. line.len - 1];
        }
        if (line.len < 41) continue; // hash(40) + space(1) + name(1+)

        // First 40 chars = hash, then space, then ref name
        // First ref line may have \0 followed by capabilities
        const hash = line[0..40];
        const rest = line[41..]; // after space

        var ref_name: []const u8 = rest;
        if (first_ref) {
            if (std.mem.indexOfScalar(u8, rest, 0)) |nul_pos| {
                ref_name = rest[0..nul_pos];
                const caps_str = rest[nul_pos + 1 ..];
                capabilities = try allocator.dupe(u8, caps_str);
                caps_allocated = true;
            }
            first_ref = false;
        }

        try refs.append(.{
            .hash = hash[0..40].*,
            .name = try allocator.dupe(u8, ref_name),
        });
    }

    if (!caps_allocated) {
        capabilities = try allocator.dupe(u8, "");
    }

    return .{
        .refs = try refs.toOwnedSlice(),
        .capabilities = capabilities,
        .allocator = allocator,
    };
}

// ============================================================================
// fetchPack
// ============================================================================

pub fn fetchPack(allocator: std.mem.Allocator, url: []const u8, wants: []const Oid, haves: []const Oid) ![]u8 {
    return fetchPackWithClient(allocator, null, url, wants, haves);
}

fn fetchPackWithClient(allocator: std.mem.Allocator, client: ?*std.http.Client, url: []const u8, wants: []const Oid, haves: []const Oid) ![]u8 {
    var base = url;
    while (base.len > 0 and base[base.len - 1] == '/') {
        base = base[0 .. base.len - 1];
    }

    const post_url = try std.fmt.allocPrint(allocator, "{s}/git-upload-pack", .{base});
    defer allocator.free(post_url);

    const request_body = try buildUploadPackRequest(allocator, wants, haves);
    defer allocator.free(request_body);

    const response = try httpPostWithClient(allocator, client, post_url, request_body, "application/x-git-upload-pack-request");
    defer allocator.free(response);

    return parseFetchPackResponse(allocator, response);
}

/// Result of a shallow fetch containing pack data and shallow boundary commits
pub const ShallowFetchResult = struct {
    pack_data: []u8,
    shallow_commits: []Oid,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ShallowFetchResult) void {
        self.allocator.free(self.pack_data);
        self.allocator.free(self.shallow_commits);
    }
};

pub fn fetchPackShallow(allocator: std.mem.Allocator, url: []const u8, wants: []const Oid, haves: []const Oid, depth: u32) !ShallowFetchResult {
    return fetchPackShallowWithClient(allocator, null, url, wants, haves, depth);
}

fn fetchPackShallowWithClient(allocator: std.mem.Allocator, client: ?*std.http.Client, url: []const u8, wants: []const Oid, haves: []const Oid, depth: u32) !ShallowFetchResult {
    const trace_timing = std.posix.getenv("ZIGGIT_TRACE_TIMING") != null;
    var fetch_timer = std.time.Timer.start() catch null;

    var base = url;
    while (base.len > 0 and base[base.len - 1] == '/') {
        base = base[0 .. base.len - 1];
    }

    const post_url = try std.fmt.allocPrint(allocator, "{s}/git-upload-pack", .{base});
    defer allocator.free(post_url);

    const request_body = try buildUploadPackRequestWithDepth(allocator, wants, haves, depth);
    defer allocator.free(request_body);

    const response = try httpPostWithClient(allocator, client, post_url, request_body, "application/x-git-upload-pack-request");
    defer allocator.free(response);

    if (trace_timing) {
        if (fetch_timer) |*t| {
            std.debug.print("[timing]     HTTP POST+response: {}ms, response_size={}\n", .{ t.read() / std.time.ns_per_ms, response.len });
            t.reset();
        }
    }

    const result = try parseShallowFetchPackResponse(allocator, response);

    if (trace_timing) {
        if (fetch_timer) |*t| {
            std.debug.print("[timing]     parse response: {}ms\n", .{t.read() / std.time.ns_per_ms});
            t.reset();
        }
    }

    return result;
}

/// Parse the response from POST /git-upload-pack.
/// Handles side-band-64k demuxing.
pub fn parseFetchPackResponse(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var pack_data = std.array_list.Managed(u8).init(allocator);
    try pack_data.ensureTotalCapacity(data.len * 9 / 10);
    errdefer pack_data.deinit();

    var offset: usize = 0;
    var using_sideband = false;

    while (offset < data.len) {
        const result = parsePktLine(data[offset..]) catch break;
        offset += result.consumed;

        if (result.pkt.line_type == .flush) continue;
        if (result.pkt.line_type == .delim) continue;

        const payload = result.pkt.data;
        if (payload.len == 0) continue;

        // Check for NAK/ACK lines
        if (std.mem.startsWith(u8, payload, "NAK")) continue;
        if (std.mem.startsWith(u8, payload, "ACK")) continue;

        // Side-band demuxing: first byte is channel
        const channel = payload[0];
        if (channel == 1) {
            // Pack data
            using_sideband = true;
            try pack_data.appendSlice(payload[1..]);
        } else if (channel == 2) {
            // Progress - ignore
            using_sideband = true;
            continue;
        } else if (channel == 3) {
            // Error
            return error.SideBandError;
        } else if (!using_sideband) {
            // No side-band: raw data after NAK
            // This could be the start of pack data
            try pack_data.appendSlice(payload);
        } else {
            // Unknown channel in sideband mode, treat as pack data
            try pack_data.appendSlice(payload);
        }
    }

    // If we're not using sideband and there's remaining data after pkt-lines, it's raw pack data
    if (!using_sideband and offset < data.len) {
        try pack_data.appendSlice(data[offset..]);
    }

    const result = try pack_data.toOwnedSlice();
    if (result.len == 0) return error.NoPackData;

    // Verify PACK magic
    if (result.len < 4 or !std.mem.eql(u8, result[0..4], "PACK")) {
        // Maybe there's some prefix junk, try to find PACK
        if (std.mem.indexOf(u8, result, "PACK")) |pack_start| {
            if (pack_start > 0) {
                const trimmed = try allocator.dupe(u8, result[pack_start..]);
                allocator.free(result);
                return trimmed;
            }
        }
    }

    return result;
}

/// Parse fetch response that may contain shallow lines.
/// Returns pack data and any shallow boundary commit OIDs.
pub fn parseShallowFetchPackResponse(allocator: std.mem.Allocator, data: []const u8) !ShallowFetchResult {
    var pack_data = std.array_list.Managed(u8).init(allocator);
    // Pre-allocate: pack data is ~90% of total response after sideband overhead
    try pack_data.ensureTotalCapacity(data.len * 9 / 10);
    errdefer pack_data.deinit();
    var shallow_commits = std.array_list.Managed(Oid).init(allocator);
    errdefer shallow_commits.deinit();

    var offset: usize = 0;
    var using_sideband = false;

    while (offset < data.len) {
        const result = parsePktLine(data[offset..]) catch break;
        offset += result.consumed;

        if (result.pkt.line_type == .flush) continue;
        if (result.pkt.line_type == .delim) continue;

        const payload = result.pkt.data;
        if (payload.len == 0) continue;

        // Check for NAK/ACK lines
        if (std.mem.startsWith(u8, payload, "NAK")) continue;
        if (std.mem.startsWith(u8, payload, "ACK")) continue;

        // Parse "shallow <hash>\n" lines from the server response
        if (std.mem.startsWith(u8, payload, "shallow ")) {
            const rest = payload["shallow ".len..];
            // Strip trailing newline
            const hash_str = if (rest.len > 0 and rest[rest.len - 1] == '\n')
                rest[0 .. rest.len - 1]
            else
                rest;
            if (hash_str.len >= 40) {
                try shallow_commits.append(hash_str[0..40].*);
            }
            continue;
        }

        // Skip "unshallow" lines (used when deepening)
        if (std.mem.startsWith(u8, payload, "unshallow ")) continue;

        // Side-band demuxing: first byte is channel
        const channel = payload[0];
        if (channel == 1) {
            using_sideband = true;
            try pack_data.appendSlice(payload[1..]);
        } else if (channel == 2) {
            using_sideband = true;
            continue;
        } else if (channel == 3) {
            return error.SideBandError;
        } else if (!using_sideband) {
            try pack_data.appendSlice(payload);
        } else {
            try pack_data.appendSlice(payload);
        }
    }

    if (!using_sideband and offset < data.len) {
        try pack_data.appendSlice(data[offset..]);
    }

    const pack_result = try pack_data.toOwnedSlice();
    if (pack_result.len == 0) {
        allocator.free(pack_result);
        return error.NoPackData;
    }

    // Verify PACK magic, trim prefix junk if needed
    var final_pack = pack_result;
    if (pack_result.len < 4 or !std.mem.eql(u8, pack_result[0..4], "PACK")) {
        if (std.mem.indexOf(u8, pack_result, "PACK")) |pack_start| {
            if (pack_start > 0) {
                final_pack = try allocator.dupe(u8, pack_result[pack_start..]);
                allocator.free(pack_result);
            }
        }
    }

    return .{
        .pack_data = final_pack,
        .shallow_commits = try shallow_commits.toOwnedSlice(),
        .allocator = allocator,
    };
}

// ============================================================================
// clonePack
// ============================================================================

/// Check if a ref name is relevant for cloning (HEAD, branches, tags).
/// Skips pull request refs, GitHub internal refs, etc.
fn isCloneRelevantRef(name: []const u8) bool {
    if (std.mem.eql(u8, name, "HEAD")) return true;
    if (std.mem.startsWith(u8, name, "refs/heads/")) return true;
    if (std.mem.startsWith(u8, name, "refs/tags/")) return true;
    return false;
}

pub fn clonePack(allocator: std.mem.Allocator, url: []const u8) !CloneResult {
<<<<<<< Updated upstream
    // Use a single HTTP client for both requests (TLS connection reuse)
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
=======
    // Write trace using raw syscall to avoid any zig/bun interception
    const rc = std.os.linux.open("/tmp/ziggit_net_trace.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    if (rc < 4096) { // valid fd
        const msg = "clonePack ENTER\n";
        _ = std.os.linux.write(@intCast(rc), msg.ptr, msg.len);
        _ = std.os.linux.close(@intCast(rc));
    }
    var clone_timer = std.time.Timer.start() catch null;
    // Use global pool for implicit connection reuse across clonePack calls
    const client = getOrCreateGlobalPool(allocator);
>>>>>>> Stashed changes

    const discovery = try discoverRefsWithClient(allocator, &client, url);

<<<<<<< Updated upstream
    // Collect unique want hashes — only for relevant refs (HEAD, branches, tags)
    // Skip pull request refs (refs/pull/*) which can add thousands of unwanted objects
    var want_set = std.StringHashMap(void).init(allocator);
    defer want_set.deinit();
=======
    // Strategy: single-RT v2 (1 request) → 2-RT v2 (2 requests) → v1 (2 requests)
    // Single-RT uses want-ref to eliminate the ls-refs round trip, saving ~50-100ms
    if (clonePackV2SingleRTFull(allocator, client, url)) |result| {
        if (clone_timer) |*t| std.debug.print("[NET] clonePack single-RT: {}ms {s}\n", .{ t.read() / std.time.ns_per_ms, url });
        return result;
    } else |err| {
        if (clone_timer) |*t| std.debug.print("[NET] single-RT FAIL ({s}): {}ms, trying 2-RT: {s}\n", .{ @errorName(err), t.read() / std.time.ns_per_ms, url });
        if (clonePackV2(allocator, client, url)) |result2| {
            if (clone_timer) |*t| std.debug.print("[NET] clonePack 2-RT: {}ms {s}\n", .{ t.read() / std.time.ns_per_ms, url });
            return result2;
        } else |err2| {
            if (clone_timer) |*t| std.debug.print("[NET] 2-RT FAIL ({s}): {}ms, trying v1: {s}\n", .{ @errorName(err2), t.read() / std.time.ns_per_ms, url });
            const result3 = try clonePackV1(allocator, client, url);
            if (clone_timer) |*t| std.debug.print("[NET] clonePack v1: {}ms {s}\n", .{ t.read() / std.time.ns_per_ms, url });
            return result3;
        }
    }
}
>>>>>>> Stashed changes

    var wants = std.array_list.Managed(Oid).init(allocator);
    defer wants.deinit();

    for (discovery.refs) |ref| {
        if (!isCloneRelevantRef(ref.name)) continue;
        const hash_str = ref.hash;
        if (!want_set.contains(&hash_str)) {
            try want_set.put(try allocator.dupe(u8, &hash_str), {});
            try wants.append(hash_str);
        }
    }
    // Free the hashmap keys
    defer {
        var it = want_set.keyIterator();
        while (it.next()) |key| allocator.free(@constCast(key.*));
    }

<<<<<<< Updated upstream
    const pack_data = try fetchPackWithClient(allocator, &client, url, wants.items, &.{});
=======
    return .{
        .refs = discovery.refs,
        .capabilities = discovery.capabilities,
        .pack_data = shallow_result.pack_data,
        .shallow_commits = shallow_result.shallow_commits,
        .allocator = allocator,
    };
}

fn writeTraceFile(msg: []const u8) void {
    writeTraceLog(msg);
}

fn writeTraceLog(msg: []const u8) void {
    // Use POSIX open directly to avoid std.fs CWD issues
    const fd = std.posix.open("/tmp/ziggit_net_trace.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch return;
    defer std.posix.close(fd);
    _ = std.posix.write(fd, msg) catch return;
}

fn writeTimingLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeTraceLog(msg);
}

fn clonePackV1(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8) !CloneResult {
    const discovery = try discoverRefsWithClient(allocator, client, url);

    // Deduplicate wants using simple linear scan (faster than HashMap for <100 refs,
    // which is the common case after filtering to HEAD/branches/tags).
    var wants = std.array_list.Managed(Oid).init(allocator);
    defer wants.deinit();
    try wants.ensureTotalCapacity(discovery.refs.len);

    for (discovery.refs) |ref| {
        // Refs are already filtered to clone-relevant in parseRefDiscoveryResponse
        var dup = false;
        for (wants.items) |existing| {
            if (std.mem.eql(u8, &existing, &ref.hash)) {
                dup = true;
                break;
            }
        }
        if (!dup) wants.appendAssumeCapacity(ref.hash);
    }

    const pack_data = try fetchPackWithClient(allocator, client, url, wants.items, &.{});
>>>>>>> Stashed changes

    return .{
        .refs = discovery.refs,
        .capabilities = discovery.capabilities,
        .pack_data = pack_data,
        .shallow_commits = try allocator.alloc(Oid, 0),
        .allocator = allocator,
    };
}

/// Check if a ref is relevant for shallow clone (HEAD + branches only, no tags).
/// Tags often point to historical commits which defeats the purpose of shallow clone.
fn isShallowCloneRelevantRef(name: []const u8) bool {
    if (std.mem.eql(u8, name, "HEAD")) return true;
    if (std.mem.startsWith(u8, name, "refs/heads/")) return true;
    return false;
}

// ============================================================================
// Protocol v2 support
// ============================================================================

/// Check if server supports protocol v2 by examining the capability advertisement response.
fn checkV2Support(data: []const u8) bool {
    // v2 response has "version 2" as a pkt-line after the service announcement
    var offset: usize = 0;
    while (offset < data.len) {
        const result = parsePktLine(data[offset..]) catch break;
        offset += result.consumed;
        if (result.pkt.line_type != .data) continue;
        var line = result.pkt.data;
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        if (std.mem.eql(u8, line, "version 2")) return true;
    }
    return false;
}

/// Build a v2 ls-refs request body with ref-prefix filtering.
fn buildV2LsRefsRequest(allocator: std.mem.Allocator, ref_prefixes: []const []const u8, symrefs: bool) ![]u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    errdefer body.deinit();

    // Command header section
    const cmd_lines = [_][]const u8{
        "command=ls-refs\n",
        "agent=ziggit/0.1\n",
        "object-format=sha1\n",
    };
    for (cmd_lines) |line| {
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // Delimiter
    try body.appendSlice("0001");

    // Arguments
    if (symrefs) {
        const line = "symrefs\n";
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    for (ref_prefixes) |prefix| {
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "ref-prefix {s}\n", .{prefix}) catch unreachable;
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // Flush
    try body.appendSlice("0000");

    return body.toOwnedSlice();
}

/// Result of v2 ls-refs parsing, includes symref info.
const V2LsRefsResult = struct {
    discovery: RefDiscovery,
    /// If HEAD has a symref-target, this is the target ref name (e.g., "refs/heads/master").
    /// Points into allocated memory owned by RefDiscovery.
    head_symref_target: ?[]const u8,
};

/// Parse v2 ls-refs response into RefDiscovery, extracting symref info.
fn parseV2LsRefsResponse(allocator: std.mem.Allocator, data: []const u8) !RefDiscovery {
    const result = try parseV2LsRefsResponseFull(allocator, data);
    return result.discovery;
}

fn parseV2LsRefsResponseFull(allocator: std.mem.Allocator, data: []const u8) !V2LsRefsResult {
    var refs = std.array_list.Managed(Ref).init(allocator);
    errdefer {
        for (refs.items) |ref| allocator.free(ref.name);
        refs.deinit();
    }
    var head_symref_target: ?[]const u8 = null;

    var offset: usize = 0;
    while (offset < data.len) {
        const result = parsePktLine(data[offset..]) catch break;
        offset += result.consumed;
        if (result.pkt.line_type != .data) continue;

        var line = result.pkt.data;
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        if (line.len < 41) continue;

        const hash = line[0..40];
        const rest = line[41..];

        // rest may be "refname symref-target:refs/heads/xxx" etc.
        // Split on space to get ref name and symref info
        var ref_name = rest;
        var symref_target: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
            ref_name = rest[0..sp];
            // Parse remaining attributes
            var attrs = rest[sp + 1 ..];
            while (attrs.len > 0) {
                if (std.mem.startsWith(u8, attrs, "symref-target:")) {
                    const target_start = "symref-target:".len;
                    const target_end = std.mem.indexOfScalar(u8, attrs[target_start..], ' ') orelse (attrs.len - target_start);
                    symref_target = attrs[target_start .. target_start + target_end];
                }
                // Skip to next attribute
                if (std.mem.indexOfScalar(u8, attrs, ' ')) |next_sp| {
                    attrs = attrs[next_sp + 1 ..];
                } else break;
            }
        }

        const duped_name = try allocator.dupe(u8, ref_name);
        try refs.append(.{
            .hash = hash[0..40].*,
            .name = duped_name,
        });

        // If this is HEAD and has a symref target, synthesize the branch ref too
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            if (symref_target) |target| {
                head_symref_target = try allocator.dupe(u8, target);
                // Synthesize the branch ref so callers see it
                try refs.append(.{
                    .hash = hash[0..40].*,
                    .name = try allocator.dupe(u8, target),
                });
            }
        }
    }

    return .{
        .discovery = .{
            .refs = try refs.toOwnedSlice(),
            .capabilities = try allocator.dupe(u8, ""),
            .allocator = allocator,
        },
        .head_symref_target = head_symref_target,
    };
}

/// Build a v2 fetch command request body for shallow clone.
fn buildV2FetchRequest(allocator: std.mem.Allocator, wants: []const Oid, haves: []const Oid, depth: u32) ![]u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    errdefer body.deinit();

    // Command header
    const cmd_lines = [_][]const u8{
        "command=fetch\n",
        "agent=ziggit/0.1\n",
        "object-format=sha1\n",
    };
    for (cmd_lines) |line| {
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // Delimiter
    try body.appendSlice("0001");

    // Arguments: thin-pack, no-progress, ofs-delta
    const args = [_][]const u8{
        "thin-pack\n",
        "no-progress\n",
        "ofs-delta\n",
    };
    for (args) |arg| {
        const pkt_len = arg.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(arg);
    }

    // Depth
    if (depth > 0) {
        var deepen_buf: [64]u8 = undefined;
        const deepen_line = std.fmt.bufPrint(&deepen_buf, "deepen {d}\n", .{depth}) catch unreachable;
        const pkt_len = deepen_line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(deepen_line);
    }

    // Wants
    for (wants) |want| {
        var line_buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "want {s}\n", .{want}) catch unreachable;
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // Haves
    for (haves) |have| {
        var line_buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "have {s}\n", .{have}) catch unreachable;
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // done
    {
        const line = "done\n";
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // Flush
    try body.appendSlice("0000");

    return body.toOwnedSlice();
}

/// Parse v2 fetch response. The v2 fetch response has sections delimited by
/// delimiters (0001) and contains: shallow-info, packfile-uris, then packfile section.
fn parseV2FetchResponse(allocator: std.mem.Allocator, data: []const u8) !ShallowFetchResult {
    var pack_data = std.array_list.Managed(u8).init(allocator);
    // Pre-allocate: pack data is ~90% of total response after sideband/pkt-line overhead
    try pack_data.ensureTotalCapacity(data.len * 9 / 10);
    errdefer pack_data.deinit();
    var shallow_commits = std.array_list.Managed(Oid).init(allocator);
    errdefer shallow_commits.deinit();

    var offset: usize = 0;
    var in_packfile = false;

    while (offset < data.len) {
        const result = parsePktLine(data[offset..]) catch break;
        offset += result.consumed;

        if (result.pkt.line_type == .flush) continue;
        if (result.pkt.line_type == .delim) continue;

        const payload = result.pkt.data;
        if (payload.len == 0) continue;

        // Check for section markers and metadata
        if (std.mem.startsWith(u8, payload, "shallow-info")) continue;
        if (std.mem.startsWith(u8, payload, "acknowledgments")) continue;
        if (std.mem.startsWith(u8, payload, "packfile\n") or std.mem.eql(u8, payload, "packfile")) {
            in_packfile = true;
            continue;
        }

        if (std.mem.startsWith(u8, payload, "shallow ")) {
            const rest = payload["shallow ".len..];
            const hash_str = if (rest.len > 0 and rest[rest.len - 1] == '\n')
                rest[0 .. rest.len - 1]
            else
                rest;
            if (hash_str.len >= 40) {
                try shallow_commits.append(hash_str[0..40].*);
            }
            continue;
        }

        if (in_packfile) {
            // Side-band demuxing (hot path — skip all prefix checks)
            const channel = payload[0];
            if (channel == 1) {
                try pack_data.appendSlice(payload[1..]);
            } else if (channel == 2) {
                continue; // progress
            } else if (channel == 3) {
                return error.SideBandError;
            }
            continue;
        }

        if (std.mem.startsWith(u8, payload, "NAK")) continue;
        if (std.mem.startsWith(u8, payload, "ACK")) continue;
        if (std.mem.startsWith(u8, payload, "ready")) continue;
    }

    const pack_result = try pack_data.toOwnedSlice();
    if (pack_result.len == 0) {
        allocator.free(pack_result);
        return error.NoPackData;
    }

    // Verify PACK magic
    var final_pack = pack_result;
    if (pack_result.len < 4 or !std.mem.eql(u8, pack_result[0..4], "PACK")) {
        if (std.mem.indexOf(u8, pack_result, "PACK")) |pack_start| {
            if (pack_start > 0) {
                final_pack = try allocator.dupe(u8, pack_result[pack_start..]);
                allocator.free(pack_result);
            }
        }
    }

    return .{
        .pack_data = final_pack,
        .shallow_commits = try shallow_commits.toOwnedSlice(),
        .allocator = allocator,
    };
}

/// Perform a shallow clone using protocol v2 with ls-refs filtering.
/// This avoids downloading all refs (including PRs) and only fetches relevant ones.
fn clonePackShallowV2(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, depth: u32) !CloneResult {
    const trace_timing = std.posix.getenv("ZIGGIT_TRACE_TIMING") != null;
    var net_timer = std.time.Timer.start() catch null;

    var base = url;
    while (base.len > 0 and base[base.len - 1] == '/') {
        base = base[0 .. base.len - 1];
    }

    const post_url = try std.fmt.allocPrint(allocator, "{s}/git-upload-pack", .{base});
    defer allocator.free(post_url);

    // Step 1: ls-refs with prefix filtering
    // For shallow single-branch clones, only request HEAD (symrefs gives us the branch name).
    // For full clones, request all relevant refs.
    const shallow_prefixes = [_][]const u8{"HEAD"};
    const full_prefixes = [_][]const u8{ "HEAD", "refs/heads/", "refs/tags/" };
    const ref_prefixes: []const []const u8 = if (depth > 0) &shallow_prefixes else &full_prefixes;
    const ls_refs_body = try buildV2LsRefsRequest(allocator, ref_prefixes, true);
    defer allocator.free(ls_refs_body);

    const ls_refs_response = try httpPostWithClientV2(allocator, client, post_url, ls_refs_body, "application/x-git-upload-pack-request");
    defer allocator.free(ls_refs_response);

    const ls_refs_result = try parseV2LsRefsResponseFull(allocator, ls_refs_response);
    const discovery = ls_refs_result.discovery;

    if (trace_timing) {
        if (net_timer) |*t| {
            std.debug.print("[timing]   v2 ls-refs: {}ms, refs_count={}\n", .{ t.read() / std.time.ns_per_ms, discovery.refs.len });
            t.reset();
        }
    }

    // Step 2: Build want list — for shallow, just HEAD's hash (deduplicated)
    var wants: [1]Oid = undefined;
    var wants_len: usize = 0;
    if (depth > 0) {
        for (discovery.refs) |ref| {
            if (std.mem.eql(u8, ref.name, "HEAD")) {
                wants[0] = ref.hash;
                wants_len = 1;
                break;
            }
        }
    } else {
        // Full clone: collect all unique wants
        // (falls through to old path via wants_list below)
    }

    // For full clone, use dynamic want list
    var wants_list = std.array_list.Managed(Oid).init(allocator);
    defer wants_list.deinit();
    if (depth == 0) {
        var want_set = std.StringHashMap(void).init(allocator);
        defer {
            var it = want_set.keyIterator();
            while (it.next()) |key| allocator.free(@constCast(key.*));
            want_set.deinit();
        }
        for (discovery.refs) |ref| {
            if (!isCloneRelevantRef(ref.name)) continue;
            if (!want_set.contains(&ref.hash)) {
                try want_set.put(try allocator.dupe(u8, &ref.hash), {});
                try wants_list.append(ref.hash);
            }
        }
    }
    const effective_wants: []const Oid = if (depth > 0) wants[0..wants_len] else wants_list.items;

    if (trace_timing) {
        if (net_timer) |*t| {
            std.debug.print("[timing]   v2 want list: {}ms, wants={}\n", .{ t.read() / std.time.ns_per_ms, effective_wants.len });
            t.reset();
        }
    }

    // Step 3: Fetch pack using v2 fetch command
    const fetch_body = try buildV2FetchRequest(allocator, effective_wants, &.{}, depth);
    defer allocator.free(fetch_body);

    const fetch_response = try httpPostWithClientV2(allocator, client, post_url, fetch_body, "application/x-git-upload-pack-request");
    defer allocator.free(fetch_response);

    const shallow_result = try parseV2FetchResponse(allocator, fetch_response);

    if (trace_timing) {
        if (net_timer) |*t| {
            std.debug.print("[timing]   v2 fetch: {}ms, pack_size={}\n", .{ t.read() / std.time.ns_per_ms, shallow_result.pack_data.len });
            t.reset();
        }
    }

    // Free symref target if allocated (it was used internally for ref synthesis)
    if (ls_refs_result.head_symref_target) |target| {
        allocator.free(target);
    }

    return .{
        .refs = discovery.refs,
        .capabilities = discovery.capabilities,
        .pack_data = shallow_result.pack_data,
        .shallow_commits = shallow_result.shallow_commits,
        .allocator = allocator,
    };
}

/// Hybrid v1-refs + v2-fetch shallow clone: uses v1 GET info/refs (returns all
/// refs in one response) to both warm TLS AND get ref hashes, then v2 POST fetch
/// to get the pack. This saves one round-trip vs pure v2 (which needs separate
/// POST ls-refs + POST fetch). Total: GET + POST = 2 round-trips.
fn clonePackShallowHybrid(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, depth: u32) !CloneResult {
    const trace_timing = std.posix.getenv("ZIGGIT_TRACE_TIMING") != null;
    var net_timer = std.time.Timer.start() catch null;

    var base = url;
    while (base.len > 0 and base[base.len - 1] == '/') {
        base = base[0 .. base.len - 1];
    }

    // Step 1: GET info/refs (v1 style) — warms TLS AND returns all ref hashes
    const ref_url = try std.fmt.allocPrint(allocator, "{s}/info/refs?service=git-upload-pack", .{base});
    defer allocator.free(ref_url);

    const ref_body = try httpGetWithClient(allocator, client, ref_url);
    defer allocator.free(ref_body);

    const discovery = try parseRefDiscoveryResponse(allocator, ref_body);

    if (trace_timing) {
        if (net_timer) |*t| {
            std.debug.print("[timing]   hybrid GET refs: {}ms, refs_count={}\n", .{ t.read() / std.time.ns_per_ms, discovery.refs.len });
            t.reset();
        }
    }

    // Step 2: Build wants — single-branch for shallow
    var head_hash: ?Oid = null;
    var head_branch: ?[]const u8 = null;
    if (depth > 0) {
        for (discovery.refs) |ref| {
            if (std.mem.eql(u8, ref.name, "HEAD")) {
                head_hash = ref.hash;
                break;
            }
        }
        if (head_hash) |hh| {
            for (discovery.refs) |ref| {
                if (std.mem.startsWith(u8, ref.name, "refs/heads/") and
                    std.mem.eql(u8, &ref.hash, &hh))
                {
                    head_branch = ref.name;
                    break;
                }
            }
        }
    }

    var want_set = std.StringHashMap(void).init(allocator);
    defer want_set.deinit();
    var wants = std.array_list.Managed(Oid).init(allocator);
    defer wants.deinit();

    for (discovery.refs) |ref| {
        const relevant = if (depth > 0) blk: {
            if (std.mem.eql(u8, ref.name, "HEAD")) break :blk true;
            if (head_branch) |hb| {
                if (std.mem.eql(u8, ref.name, hb)) break :blk true;
            }
            break :blk false;
        } else isCloneRelevantRef(ref.name);
        if (!relevant) continue;
        const hash_str = ref.hash;
        if (!want_set.contains(&hash_str)) {
            try want_set.put(try allocator.dupe(u8, &hash_str), {});
            try wants.append(hash_str);
        }
    }
    defer {
        var it = want_set.keyIterator();
        while (it.next()) |key| allocator.free(@constCast(key.*));
    }

    // Step 3: Try v2 fetch POST (TLS is warm from step 1)
    // If v2 fetch fails, fall back to v1 fetch
    const post_url = try std.fmt.allocPrint(allocator, "{s}/git-upload-pack", .{base});
    defer allocator.free(post_url);

    const fetch_body = try buildV2FetchRequest(allocator, wants.items, &.{}, depth);
    defer allocator.free(fetch_body);

    if (httpPostWithClientV2(allocator, client, post_url, fetch_body, "application/x-git-upload-pack-request")) |fetch_response| {
        defer allocator.free(fetch_response);
        if (parseV2FetchResponse(allocator, fetch_response)) |shallow_result| {
            if (trace_timing) {
                if (net_timer) |*t| {
                    std.debug.print("[timing]   hybrid v2 fetch: {}ms, pack_size={}\n", .{ t.read() / std.time.ns_per_ms, shallow_result.pack_data.len });
                }
            }
            return .{
                .refs = discovery.refs,
                .capabilities = discovery.capabilities,
                .pack_data = shallow_result.pack_data,
                .shallow_commits = shallow_result.shallow_commits,
                .allocator = allocator,
            };
        } else |_| {}
    } else |_| {}

    // Fallback: v1 fetch
    const shallow_result = try fetchPackShallowWithClient(allocator, client, url, wants.items, &.{}, depth);

    if (trace_timing) {
        if (net_timer) |*t| {
            std.debug.print("[timing]   hybrid v1 fetch: {}ms, pack_size={}\n", .{ t.read() / std.time.ns_per_ms, shallow_result.pack_data.len });
        }
    }

    return .{
        .refs = discovery.refs,
        .capabilities = discovery.capabilities,
        .pack_data = shallow_result.pack_data,
        .shallow_commits = shallow_result.shallow_commits,
        .allocator = allocator,
    };
}

/// Build a v2 fetch request body using want-ref (by name) instead of want (by OID).
/// This eliminates the need for a separate ls-refs round-trip.
fn buildV2FetchRequestWithWantRef(allocator: std.mem.Allocator, want_refs: []const []const u8, depth: u32) ![]u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    errdefer body.deinit();

    // Command header
    const cmd_lines = [_][]const u8{
        "command=fetch\n",
        "agent=ziggit/0.1\n",
        "object-format=sha1\n",
    };
    for (cmd_lines) |line| {
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // Delimiter
    try body.appendSlice("0001");

    // Arguments
    const args = [_][]const u8{
        "thin-pack\n",
        "no-progress\n",
        "ofs-delta\n",
    };
    for (args) |arg| {
        const pkt_len = arg.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(arg);
    }

    // Depth
    if (depth > 0) {
        var deepen_buf: [64]u8 = undefined;
        const deepen_line = std.fmt.bufPrint(&deepen_buf, "deepen {d}\n", .{depth}) catch unreachable;
        const pkt_len = deepen_line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(deepen_line);
    }

    // want-ref lines (by name, server resolves OID)
    for (want_refs) |ref_name| {
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "want-ref {s}\n", .{ref_name}) catch unreachable;
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // done
    {
        const line = "done\n";
        const pkt_len = line.len + 4;
        var hdr: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{pkt_len}) catch unreachable;
        try body.appendSlice(&hdr);
        try body.appendSlice(line);
    }

    // Flush
    try body.appendSlice("0000");

    return body.toOwnedSlice();
}

/// Extended shallow fetch result that also includes resolved wanted-refs.
const WantRefFetchResult = struct {
    pack_data: []u8,
    shallow_commits: []Oid,
    refs: []Ref,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WantRefFetchResult) void {
        self.allocator.free(self.pack_data);
        self.allocator.free(self.shallow_commits);
        for (self.refs) |ref| self.allocator.free(ref.name);
        self.allocator.free(self.refs);
    }
};

/// Parse v2 fetch response that includes wanted-refs section.
/// Returns pack data, shallow commits, AND resolved ref OIDs.
fn parseV2FetchResponseWithRefs(allocator: std.mem.Allocator, data: []const u8) !WantRefFetchResult {
    var pack_data = std.array_list.Managed(u8).init(allocator);
    try pack_data.ensureTotalCapacity(data.len * 9 / 10);
    errdefer pack_data.deinit();
    var shallow_commits = std.array_list.Managed(Oid).init(allocator);
    errdefer shallow_commits.deinit();
    var refs = std.array_list.Managed(Ref).init(allocator);
    errdefer {
        for (refs.items) |ref| allocator.free(ref.name);
        refs.deinit();
    }

    var offset: usize = 0;
    var in_packfile = false;
    var in_wanted_refs = false;

    while (offset < data.len) {
        const result = parsePktLine(data[offset..]) catch break;
        offset += result.consumed;

        if (result.pkt.line_type == .flush) continue;
        if (result.pkt.line_type == .delim) {
            // Delimiter resets section context
            in_wanted_refs = false;
            continue;
        }

        const payload = result.pkt.data;
        if (payload.len == 0) continue;

        // Section markers
        if (std.mem.startsWith(u8, payload, "shallow-info")) continue;
        if (std.mem.startsWith(u8, payload, "acknowledgments")) continue;
        if (std.mem.startsWith(u8, payload, "wanted-refs\n") or std.mem.eql(u8, payload, "wanted-refs")) {
            in_wanted_refs = true;
            continue;
        }
        if (std.mem.startsWith(u8, payload, "packfile\n") or std.mem.eql(u8, payload, "packfile")) {
            in_wanted_refs = false;
            in_packfile = true;
            continue;
        }

        // Parse wanted-refs entries: "<oid> <refname>\n"
        if (in_wanted_refs) {
            var line = payload;
            if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
            if (line.len >= 42) { // 40 hex + space + at least 1 char name
                const hash = line[0..40];
                const ref_name = line[41..];
                try refs.append(.{
                    .hash = hash[0..40].*,
                    .name = try allocator.dupe(u8, ref_name),
                });
            }
            continue;
        }

        if (std.mem.startsWith(u8, payload, "shallow ")) {
            const rest = payload["shallow ".len..];
            const hash_str = if (rest.len > 0 and rest[rest.len - 1] == '\n')
                rest[0 .. rest.len - 1]
            else
                rest;
            if (hash_str.len >= 40) {
                try shallow_commits.append(hash_str[0..40].*);
            }
            continue;
        }

        if (in_packfile) {
            const channel = payload[0];
            if (channel == 1) {
                try pack_data.appendSlice(payload[1..]);
            } else if (channel == 2) {
                continue;
            } else if (channel == 3) {
                return error.SideBandError;
            }
            continue;
        }

        if (std.mem.startsWith(u8, payload, "NAK")) continue;
        if (std.mem.startsWith(u8, payload, "ACK")) continue;
        if (std.mem.startsWith(u8, payload, "ready")) continue;
    }

    const pack_result = try pack_data.toOwnedSlice();
    if (pack_result.len == 0) {
        allocator.free(pack_result);
        return error.NoPackData;
    }

    var final_pack = pack_result;
    if (pack_result.len < 4 or !std.mem.eql(u8, pack_result[0..4], "PACK")) {
        if (std.mem.indexOf(u8, pack_result, "PACK")) |pack_start| {
            if (pack_start > 0) {
                final_pack = try allocator.dupe(u8, pack_result[pack_start..]);
                allocator.free(pack_result);
            }
        }
    }

    return .{
        .pack_data = final_pack,
        .shallow_commits = try shallow_commits.toOwnedSlice(),
        .refs = try refs.toOwnedSlice(),
        .allocator = allocator,
    };
}

/// Single-round-trip v2 shallow clone using want-ref.
/// Sends a single POST with want-ref HEAD, server resolves the OID and returns
/// both the wanted-refs mapping and the pack data. Eliminates the ls-refs round-trip.
fn clonePackShallowV2SingleRT(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, depth: u32) !CloneResult {
    const trace_timing = std.posix.getenv("ZIGGIT_TRACE_TIMING") != null;
    var net_timer = std.time.Timer.start() catch null;

    var base = url;
    while (base.len > 0 and base[base.len - 1] == '/') {
        base = base[0 .. base.len - 1];
    }

    const post_url = try std.fmt.allocPrint(allocator, "{s}/git-upload-pack", .{base});
    defer allocator.free(post_url);

    // For shallow single-branch clone, just want-ref HEAD.
    // For full clone, want-ref all standard refs (but that's less common).
    const want_refs = [_][]const u8{"HEAD"};
    const fetch_body = try buildV2FetchRequestWithWantRef(allocator, &want_refs, depth);
    defer allocator.free(fetch_body);

    const fetch_response = try httpPostWithClientV2(allocator, client, post_url, fetch_body, "application/x-git-upload-pack-request");
    defer allocator.free(fetch_response);

    const wantref_result = try parseV2FetchResponseWithRefs(allocator, fetch_response);

    if (trace_timing) {
        if (net_timer) |*t| {
            std.debug.print("[timing]   v2 single-RT fetch: {}ms, pack_size={}, refs={}\n", .{ t.read() / std.time.ns_per_ms, wantref_result.pack_data.len, wantref_result.refs.len });
        }
    }

    // Build the refs list for the caller. wanted-refs gives us the branch ref;
    // we also need to synthesize HEAD pointing to the same hash.
    var all_refs = std.array_list.Managed(Ref).init(allocator);
    errdefer {
        for (all_refs.items) |ref| allocator.free(ref.name);
        all_refs.deinit();
    }

    // Add HEAD
    var head_hash: ?Oid = null;
    for (wantref_result.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) {
            head_hash = ref.hash;
        }
        try all_refs.append(.{
            .hash = ref.hash,
            .name = try allocator.dupe(u8, ref.name),
        });
    }

    // If we got HEAD in wanted-refs but no branch ref, that's fine —
    // the caller will figure out the branch from HEAD's hash.
    // If wanted-refs didn't include HEAD explicitly (some servers return
    // the resolved branch ref instead), add a HEAD entry.
    if (head_hash == null and wantref_result.refs.len > 0) {
        // Use the first ref's hash as HEAD
        head_hash = wantref_result.refs[0].hash;
        try all_refs.append(.{
            .hash = wantref_result.refs[0].hash,
            .name = try allocator.dupe(u8, "HEAD"),
        });
    }

    // Free the wantref_result refs (we duped what we need)
    for (wantref_result.refs) |ref| allocator.free(ref.name);
    allocator.free(wantref_result.refs);

    return .{
        .refs = try all_refs.toOwnedSlice(),
        .capabilities = try allocator.dupe(u8, ""),
        .pack_data = wantref_result.pack_data,
        .shallow_commits = wantref_result.shallow_commits,
        .allocator = allocator,
    };
}

/// Clone a repository with shallow depth support.
/// When depth > 0, sends "deepen N" to the server for a shallow clone.
/// Implements --single-branch behavior by default for shallow clones (like git does):
/// only fetches the HEAD branch to minimize transfer size.
pub fn clonePackShallow(allocator: std.mem.Allocator, url: []const u8, depth: u32) !CloneResult {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Strategy selection for shallow clone:
    // - ZIGGIT_FORCE_V1: pure v1 (GET info/refs + POST upload-pack v1)
    // - ZIGGIT_FORCE_V2: pure v2 (POST ls-refs + POST fetch, 2 round-trips)
    // - ZIGGIT_FORCE_HYBRID: hybrid (GET info/refs for refs + POST v2 fetch)
    // - ZIGGIT_FORCE_SINGLE_RT: single-round-trip v2 with want-ref (requires server support)
    // - Default: v2 (2 round-trips), fall back to v1
    if (std.posix.getenv("ZIGGIT_FORCE_V1") != null) {
        return clonePackShallowV1(allocator, &client, url, depth);
    }
    if (std.posix.getenv("ZIGGIT_FORCE_HYBRID") != null) {
        return clonePackShallowHybrid(allocator, &client, url, depth);
    }
    if (std.posix.getenv("ZIGGIT_FORCE_SINGLE_RT") != null) {
        return clonePackShallowV2SingleRT(allocator, &client, url, depth);
    }
    return clonePackShallowV2(allocator, &client, url, depth) catch |e| {
        if (std.posix.getenv("ZIGGIT_TRACE_TIMING") != null)
            std.debug.print("[debug] v2 failed: {}, falling back to v1\n", .{e});
        return clonePackShallowV1(allocator, &client, url, depth);
    };
}

fn clonePackShallowV1(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, depth: u32) !CloneResult {
    const trace_timing = std.posix.getenv("ZIGGIT_TRACE_TIMING") != null;
    var net_timer = std.time.Timer.start() catch null;

    const discovery = try discoverRefsWithClient(allocator, client, url);

    if (trace_timing) {
        if (net_timer) |*t| {
            std.debug.print("[timing]   ref discovery: {}ms, refs_count={}\n", .{ t.read() / std.time.ns_per_ms, discovery.refs.len });
            t.reset();
        }
    }

    // For shallow clones with depth > 0, use single-branch behavior (like git --depth implies --single-branch).
    // Find what HEAD points to and only fetch that branch's hash.
    var head_hash: ?Oid = null;
    var head_branch: ?[]const u8 = null;
    if (depth > 0) {
        for (discovery.refs) |ref| {
            if (std.mem.eql(u8, ref.name, "HEAD")) {
                head_hash = ref.hash;
                break;
            }
        }
        // Find the branch that HEAD points to (same hash)
        if (head_hash) |hh| {
            for (discovery.refs) |ref| {
                if (std.mem.startsWith(u8, ref.name, "refs/heads/") and
                    std.mem.eql(u8, &ref.hash, &hh))
                {
                    head_branch = ref.name;
                    break;
                }
            }
        }
    }

    // Collect unique want hashes
    // For shallow clones, only want HEAD (single-branch) to minimize transfer size
    var want_set = std.StringHashMap(void).init(allocator);
    defer want_set.deinit();

    var wants = std.array_list.Managed(Oid).init(allocator);
    defer wants.deinit();

    for (discovery.refs) |ref| {
        const relevant = if (depth > 0) blk: {
            // Single-branch: only HEAD and its matching branch ref
            if (std.mem.eql(u8, ref.name, "HEAD")) break :blk true;
            if (head_branch) |hb| {
                if (std.mem.eql(u8, ref.name, hb)) break :blk true;
            }
            break :blk false;
        } else isCloneRelevantRef(ref.name);
        if (!relevant) continue;
        const hash_str = ref.hash;
        if (!want_set.contains(&hash_str)) {
            try want_set.put(try allocator.dupe(u8, &hash_str), {});
            try wants.append(hash_str);
        }
    }
    defer {
        var it = want_set.keyIterator();
        while (it.next()) |key| allocator.free(@constCast(key.*));
    }

    if (trace_timing) {
        if (net_timer) |*t| {
            std.debug.print("[timing]   want list build: {}ms, wants={}\n", .{ t.read() / std.time.ns_per_ms, wants.items.len });
            t.reset();
        }
    }

    if (depth > 0) {
        // Use shallow fetch
        const shallow_result = try fetchPackShallowWithClient(allocator, client, url, wants.items, &.{}, depth);

        if (trace_timing) {
            if (net_timer) |*t| {
                std.debug.print("[timing]   pack fetch+parse: {}ms, pack_size={}\n", .{ t.read() / std.time.ns_per_ms, shallow_result.pack_data.len });
                t.reset();
            }
        }

        // Transfer ownership - don't deinit shallow_result
        return .{
            .refs = discovery.refs,
            .capabilities = discovery.capabilities,
            .pack_data = shallow_result.pack_data,
            .shallow_commits = shallow_result.shallow_commits,
            .allocator = allocator,
        };
    } else {
        const pack_data = try fetchPackWithClient(allocator, client, url, wants.items, &.{});

        return .{
            .refs = discovery.refs,
            .capabilities = discovery.capabilities,
            .pack_data = pack_data,
            .shallow_commits = try allocator.alloc(Oid, 0),
            .allocator = allocator,
        };
    }
}

// ============================================================================
// fetchNewPack
// ============================================================================

pub const LocalRef = struct {
    hash: Oid,
    name: []const u8,
};

pub fn fetchNewPack(allocator: std.mem.Allocator, url: []const u8, local_refs: []const LocalRef) !?FetchResult {
    // Use a single HTTP client for both requests (TLS connection reuse)
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var discovery = try discoverRefsWithClient(allocator, &client, url);
    // On error paths below, we must free discovery since we won't transfer ownership
    errdefer discovery.deinit();

    // Build set of local hashes for each ref name
    // Use owned keys to avoid use-after-free if local_refs backing memory changes
    var local_map = std.StringHashMap(Oid).init(allocator);
    defer local_map.deinit();
    for (local_refs) |lr| {
        try local_map.put(lr.name, lr.hash);
    }

    // Determine wants and haves
    var wants = std.array_list.Managed(Oid).init(allocator);
    defer wants.deinit();
    var haves = std.array_list.Managed(Oid).init(allocator);
    defer haves.deinit();

    // Collect unique want and have hashes
    var want_set = std.StringHashMap(void).init(allocator);
    defer {
        var it = want_set.keyIterator();
        while (it.next()) |key| allocator.free(@constCast(key.*));
        want_set.deinit();
    }
    var have_set = std.StringHashMap(void).init(allocator);
    defer {
        var it = have_set.keyIterator();
        while (it.next()) |key| allocator.free(@constCast(key.*));
        have_set.deinit();
    }

    for (discovery.refs) |ref| {
        // Skip pull request refs and other non-essential refs during fetch
        if (!isCloneRelevantRef(ref.name)) continue;

        if (local_map.get(ref.name)) |local_hash| {
            if (!std.mem.eql(u8, &local_hash, &ref.hash)) {
                // Updated ref - want new, have old
                if (!want_set.contains(&ref.hash)) {
                    try want_set.put(try allocator.dupe(u8, &ref.hash), {});
                    try wants.append(ref.hash);
                }
                if (!have_set.contains(&local_hash)) {
                    try have_set.put(try allocator.dupe(u8, &local_hash), {});
                    try haves.append(local_hash);
                }
            }
            // If equal, already up to date for this ref
        } else {
            // New ref - deduplicate wants
            if (!want_set.contains(&ref.hash)) {
                try want_set.put(try allocator.dupe(u8, &ref.hash), {});
                try wants.append(ref.hash);
            }
        }
    }

    if (wants.items.len == 0) {
        // Already up to date — discovery ownership not transferred, errdefer will clean up
        // But we need to explicitly deinit since this is not an error return
        discovery.deinit();
        return null;
    }

    // Reuse the same HTTP client for the pack fetch (saves TLS handshake)
    const pack_data = try fetchPackWithClient(allocator, &client, url, wants.items, haves.items);

    // Transfer ownership of discovery refs/capabilities to the result
    // (errdefer on discovery is disarmed by successful return)
    return .{
        .refs = discovery.refs,
        .capabilities = discovery.capabilities,
        .pack_data = pack_data,
        .allocator = allocator,
    };
}
