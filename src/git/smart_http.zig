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
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CloneResult) void {
        for (self.refs) |ref| {
            self.allocator.free(ref.name);
        }
        self.allocator.free(self.refs);
        self.allocator.free(self.capabilities);
        self.allocator.free(self.pack_data);
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
    var lines = std.ArrayList(PktLine).init(allocator);
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
pub fn buildUploadPackRequest(allocator: std.mem.Allocator, wants: []const Oid, haves: []const Oid) ![]u8 {
    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();

    const capabilities = "multi_ack_detailed thin-pack side-band-64k ofs-delta";

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

    // Flush after wants
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
    const env_token = std.process.getEnvVarOwned(allocator, "GITHUB_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "GIT_TOKEN") catch |err2| switch (err2) {
            error.EnvironmentVariableNotFound => null,
            else => return error.OutOfMemory,
        },
        else => return error.OutOfMemory,
    };
    if (env_token) |t| {
        return .{ .token = t, .clean_url = url, .needs_free = false };
    }

    return .{ .token = null, .clean_url = url, .needs_free = false };
}

fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    return httpGetWithClient(allocator, null, url);
}

fn httpGetWithClient(allocator: std.mem.Allocator, existing_client: ?*std.http.Client, url: []const u8) ![]u8 {
    const auth = try extractAuth(allocator, url);
    defer if (auth.needs_free) allocator.free(@constCast(auth.clean_url));

    var owned_client: ?std.http.Client = if (existing_client == null) std.http.Client{ .allocator = allocator } else null;
    defer if (owned_client) |*c| c.deinit();
    const client = if (existing_client) |c| c else &(owned_client.?);

    var server_header_buffer: [16384]u8 = undefined;
    const uri = std.Uri.parse(auth.clean_url) catch return error.InvalidUrl;

    // Build extra headers
    var headers_buf: [3]std.http.Header = undefined;
    var n_headers: usize = 0;
    headers_buf[n_headers] = .{ .name = "User-Agent", .value = "ziggit/0.1" };
    n_headers += 1;
    if (auth.token) |token| {
        var bearer_buf: [512]u8 = undefined;
        const bearer = std.fmt.bufPrint(&bearer_buf, "Bearer {s}", .{token}) catch return error.Overflow;
        headers_buf[n_headers] = .{ .name = "Authorization", .value = bearer };
        n_headers += 1;
    }

    var req = client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = headers_buf[0..n_headers],
    }) catch return error.HttpError;
    defer req.deinit();

    req.send() catch return error.HttpError;
    req.wait() catch return error.HttpError;

    if (req.response.status != .ok) return error.HttpError;

    return req.reader().readAllAlloc(allocator, max_response_size) catch return error.HttpError;
}

fn httpPost(allocator: std.mem.Allocator, url: []const u8, body: []const u8, content_type: []const u8) ![]u8 {
    return httpPostWithClient(allocator, null, url, body, content_type);
}

fn httpPostWithClient(allocator: std.mem.Allocator, existing_client: ?*std.http.Client, url: []const u8, body: []const u8, content_type: []const u8) ![]u8 {
    const auth = try extractAuth(allocator, url);
    defer if (auth.needs_free) allocator.free(@constCast(auth.clean_url));

    var owned_client: ?std.http.Client = if (existing_client == null) std.http.Client{ .allocator = allocator } else null;
    defer if (owned_client) |*c| c.deinit();
    const client = if (existing_client) |c| c else &(owned_client.?);

    var server_header_buffer: [16384]u8 = undefined;
    const uri = std.Uri.parse(auth.clean_url) catch return error.InvalidUrl;

    var headers_buf: [4]std.http.Header = undefined;
    var n_headers: usize = 0;
    headers_buf[n_headers] = .{ .name = "User-Agent", .value = "ziggit/0.1" };
    n_headers += 1;
    headers_buf[n_headers] = .{ .name = "Content-Type", .value = content_type };
    n_headers += 1;
    if (auth.token) |token| {
        var bearer_buf: [512]u8 = undefined;
        const bearer = std.fmt.bufPrint(&bearer_buf, "Bearer {s}", .{token}) catch return error.Overflow;
        headers_buf[n_headers] = .{ .name = "Authorization", .value = bearer };
        n_headers += 1;
    }

    var req = client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = headers_buf[0..n_headers],
    }) catch return error.HttpError;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    req.send() catch return error.HttpError;
    req.writer().writeAll(body) catch return error.HttpError;
    req.finish() catch return error.HttpError;
    req.wait() catch return error.HttpError;

    if (req.response.status != .ok) return error.HttpError;

    // Read response - may be chunked
    var response_data = std.ArrayList(u8).init(allocator);
    errdefer response_data.deinit();

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = req.reader().read(&buf) catch return error.HttpError;
        if (n == 0) break;
        try response_data.appendSlice(buf[0..n]);
    }

    return response_data.toOwnedSlice();
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
    var refs = std.ArrayList(Ref).init(allocator);
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

/// Parse the response from POST /git-upload-pack.
/// Handles side-band-64k demuxing.
pub fn parseFetchPackResponse(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var pack_data = std.ArrayList(u8).init(allocator);
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
    // Use a single HTTP client for both requests (TLS connection reuse)
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const discovery = try discoverRefsWithClient(allocator, &client, url);

    // Collect unique want hashes — only for relevant refs (HEAD, branches, tags)
    // Skip pull request refs (refs/pull/*) which can add thousands of unwanted objects
    var want_set = std.StringHashMap(void).init(allocator);
    defer want_set.deinit();

    var wants = std.ArrayList(Oid).init(allocator);
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

    const pack_data = try fetchPackWithClient(allocator, &client, url, wants.items, &.{});

    return .{
        .refs = discovery.refs,
        .capabilities = discovery.capabilities,
        .pack_data = pack_data,
        .allocator = allocator,
    };
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
    var wants = std.ArrayList(Oid).init(allocator);
    defer wants.deinit();
    var haves = std.ArrayList(Oid).init(allocator);
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
