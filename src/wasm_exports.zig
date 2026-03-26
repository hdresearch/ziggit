/// WASM exports for browser integration
/// Provides a C-ABI compatible interface to ziggit's git operations.
/// All strings are passed as (ptr, len) pairs. Errors return negative values.
///
/// For freestanding (browser) builds, this module avoids importing the full
/// platform abstraction (which uses std.fs.File.Stat, unavailable on freestanding).
/// Instead, it provides a pure WASM API that delegates to JS host functions.
const std = @import("std");
const builtin = @import("builtin");

// ========== Host function declarations ==========
// These must be implemented by the JavaScript runtime loading the WASM module.

extern fn host_write_stdout(ptr: [*]const u8, len: u32) void;
extern fn host_write_stderr(ptr: [*]const u8, len: u32) void;
extern fn host_read_file(path_ptr: [*]const u8, path_len: u32, data_ptr: *[*]u8, data_len: *u32) bool;
extern fn host_write_file(path_ptr: [*]const u8, path_len: u32, data_ptr: [*]const u8, data_len: u32) bool;
extern fn host_file_exists(path_ptr: [*]const u8, path_len: u32) bool;
extern fn host_make_dir(path_ptr: [*]const u8, path_len: u32) bool;
extern fn host_delete_file(path_ptr: [*]const u8, path_len: u32) bool;
extern fn host_get_cwd(data_ptr: *[*]u8, data_len: *u32) bool;

// HTTP host functions for clone/fetch operations
extern fn host_http_get(url_ptr: [*]const u8, url_len: u32, response_ptr: *[*]u8, response_len: *u32) i32;
extern fn host_http_post(url_ptr: [*]const u8, url_len: u32, body_ptr: [*]const u8, body_len: u32, content_type_ptr: [*]const u8, content_type_len: u32, response_ptr: *[*]u8, response_len: *u32) i32;

// ========== Memory management ==========

fn getAllocator() std.mem.Allocator {
    return std.heap.wasm_allocator;
}

/// Allocate memory accessible from JS. Returns pointer, or 0 on failure.
export fn ziggit_alloc(size: u32) u32 {
    const slice = getAllocator().alloc(u8, size) catch return 0;
    return @intFromPtr(slice.ptr);
}

/// Free memory previously allocated by ziggit_alloc.
export fn ziggit_free(ptr: u32, size: u32) void {
    if (ptr == 0) return;
    const slice_ptr: [*]u8 = @ptrFromInt(ptr);
    getAllocator().free(slice_ptr[0..size]);
}

// ========== Git operations ==========

/// Initialize a new git repository at the given path.
/// Creates .git directory structure with HEAD, config, objects/, refs/.
/// Returns 0 on success, negative on error.
export fn ziggit_init(path_ptr: [*]const u8, path_len: u32) i32 {
    const path = path_ptr[0..path_len];

    // Create .git directory structure
    const dirs = [_][]const u8{
        ".git",
        ".git/objects",
        ".git/objects/pack",
        ".git/refs",
        ".git/refs/heads",
        ".git/refs/tags",
    };

    const allocator = getAllocator();

    for (dirs) |dir| {
        const full = if (path.len > 0 and !std.mem.eql(u8, path, "."))
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, dir }) catch return -1
        else
            allocator.dupe(u8, dir) catch return -1;
        defer allocator.free(full);

        if (!host_make_dir(full.ptr, @intCast(full.len))) {
            // Ignore errors for existing directories
        }
    }

    // Write HEAD
    const head_content = "ref: refs/heads/main\n";
    writeHostFile(allocator, path, ".git/HEAD", head_content) catch return -2;

    // Write config
    const config_content = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n";
    writeHostFile(allocator, path, ".git/config", config_content) catch return -3;

    return 0;
}

fn writeHostFile(allocator: std.mem.Allocator, base: []const u8, rel: []const u8, data: []const u8) !void {
    const full = if (base.len > 0 and !std.mem.eql(u8, base, "."))
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, rel })
    else
        try allocator.dupe(u8, rel);
    defer allocator.free(full);

    if (!host_write_file(full.ptr, @intCast(full.len), data.ptr, @intCast(data.len))) {
        return error.WriteFileFailed;
    }
}

fn readHostFile(allocator: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    const full = if (base.len > 0 and !std.mem.eql(u8, base, "."))
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, rel })
    else
        try allocator.dupe(u8, rel);
    defer allocator.free(full);

    var data_ptr: [*]u8 = undefined;
    var data_len: u32 = undefined;

    if (host_read_file(full.ptr, @intCast(full.len), &data_ptr, &data_len)) {
        const result = try allocator.alloc(u8, data_len);
        @memcpy(result, data_ptr[0..data_len]);
        return result;
    }
    return error.FileNotFound;
}

/// Check if a directory contains a git repository.
/// Returns 1 if yes, 0 if no.
export fn ziggit_is_repo(path_ptr: [*]const u8, path_len: u32) i32 {
    const allocator = getAllocator();
    const path = path_ptr[0..path_len];

    const head_path = if (path.len > 0 and !std.mem.eql(u8, path, "."))
        std.fmt.allocPrint(allocator, "{s}/.git/HEAD", .{path}) catch return -1
    else
        allocator.dupe(u8, ".git/HEAD") catch return -1;
    defer allocator.free(head_path);

    return if (host_file_exists(head_path.ptr, @intCast(head_path.len))) @as(i32, 1) else @as(i32, 0);
}

/// Get HEAD commit hash. Writes 40 hex chars to out_ptr.
/// Returns 0 on success, negative on error.
export fn ziggit_rev_parse_head(path_ptr: [*]const u8, path_len: u32, out_ptr: [*]u8) i32 {
    const allocator = getAllocator();
    const path = path_ptr[0..path_len];

    // Read .git/HEAD
    const head = readHostFile(allocator, path, ".git/HEAD") catch return -1;
    defer allocator.free(head);

    const trimmed = std.mem.trimRight(u8, head, "\n\r ");

    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        // Symbolic ref — read the pointed-to file
        const ref_path = std.fmt.allocPrint(allocator, ".git/{s}", .{trimmed[5..]}) catch return -2;
        defer allocator.free(ref_path);

        const ref_data = readHostFile(allocator, path, ref_path) catch return -3;
        defer allocator.free(ref_data);

        const hash = std.mem.trimRight(u8, ref_data, "\n\r ");
        if (hash.len >= 40) {
            @memcpy(out_ptr[0..40], hash[0..40]);
            return 0;
        }
        return -4;
    } else if (trimmed.len >= 40) {
        // Detached HEAD — direct hash
        @memcpy(out_ptr[0..40], trimmed[0..40]);
        return 0;
    }
    return -5;
}

/// Get current branch name. Writes to out_ptr, returns length or negative error.
export fn ziggit_current_branch(path_ptr: [*]const u8, path_len: u32, out_ptr: [*]u8, out_cap: u32) i32 {
    const allocator = getAllocator();
    const path = path_ptr[0..path_len];

    const head = readHostFile(allocator, path, ".git/HEAD") catch return -1;
    defer allocator.free(head);

    const trimmed = std.mem.trimRight(u8, head, "\n\r ");
    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
        const branch = trimmed["ref: refs/heads/".len..];
        const copy_len = @min(branch.len, out_cap);
        @memcpy(out_ptr[0..copy_len], branch[0..copy_len]);
        return @intCast(copy_len);
    }
    return -1; // detached HEAD
}

/// Hash a blob and return its SHA-1 (40 hex chars to out_ptr).
/// Does NOT store the object. Returns 0 on success.
export fn ziggit_hash_blob(data_ptr: [*]const u8, data_len: u32, out_ptr: [*]u8) i32 {
    const allocator = getAllocator();
    const data = data_ptr[0..data_len];

    // Git blob format: "blob <size>\0<data>"
    const header = std.fmt.allocPrint(allocator, "blob {d}\x00", .{data.len}) catch return -1;
    defer allocator.free(header);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out_ptr[0..40], &hex);
    return 0;
}

/// Store a blob object in the repository. Writes SHA-1 hex to out_ptr.
/// Returns 0 on success, negative on error.
export fn ziggit_store_blob(path_ptr: [*]const u8, path_len: u32, data_ptr: [*]const u8, data_len: u32, out_ptr: [*]u8) i32 {
    const allocator = getAllocator();
    const path = path_ptr[0..path_len];
    const data = data_ptr[0..data_len];

    // Create blob content
    const header = std.fmt.allocPrint(allocator, "blob {d}\x00", .{data.len}) catch return -1;
    defer allocator.free(header);

    // Hash
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out_ptr[0..40], &hex);

    // Compress with zlib
    const full_content = std.fmt.allocPrint(allocator, "{s}{s}", .{ header, data }) catch return -2;
    defer allocator.free(full_content);

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();

    var comp = std.compress.zlib.compressor(compressed.writer(), .{}) catch return -3;
    _ = comp.write(full_content) catch return -3;
    comp.finish() catch return -3;

    // Write to .git/objects/<xx>/<rest>
    const dir_name = std.fmt.allocPrint(allocator, ".git/objects/{s}", .{hex[0..2]}) catch return -4;
    defer allocator.free(dir_name);

    const dir_full = if (path.len > 0 and !std.mem.eql(u8, path, "."))
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, dir_name }) catch return -4
    else
        allocator.dupe(u8, dir_name) catch return -4;
    defer allocator.free(dir_full);
    _ = host_make_dir(dir_full.ptr, @intCast(dir_full.len));

    const obj_path = std.fmt.allocPrint(allocator, ".git/objects/{s}/{s}", .{ hex[0..2], hex[2..] }) catch return -5;
    defer allocator.free(obj_path);
    writeHostFile(allocator, path, obj_path, compressed.items) catch return -6;

    return 0;
}

/// Perform an HTTP GET via the JS host. Returns response data.
/// On success, writes response pointer and length. Returns 0 or negative error.
export fn ziggit_http_get(url_ptr: [*]const u8, url_len: u32, response_ptr_out: *u32, response_len_out: *u32) i32 {
    var resp_ptr: [*]u8 = undefined;
    var resp_len: u32 = undefined;
    const rc = host_http_get(url_ptr, url_len, &resp_ptr, &resp_len);
    if (rc == 0) {
        response_ptr_out.* = @intFromPtr(resp_ptr);
        response_len_out.* = resp_len;
        return 0;
    }
    return rc;
}

/// Perform an HTTP POST via the JS host. Returns response data.
export fn ziggit_http_post(url_ptr: [*]const u8, url_len: u32, body_ptr: [*]const u8, body_len: u32, ct_ptr: [*]const u8, ct_len: u32, response_ptr_out: *u32, response_len_out: *u32) i32 {
    var resp_ptr: [*]u8 = undefined;
    var resp_len: u32 = undefined;
    const rc = host_http_post(url_ptr, url_len, body_ptr, body_len, ct_ptr, ct_len, &resp_ptr, &resp_len);
    if (rc == 0) {
        response_ptr_out.* = @intFromPtr(resp_ptr);
        response_len_out.* = resp_len;
        return 0;
    }
    return rc;
}

/// Clone a bare repository via HTTPS. Uses JS host HTTP functions.
/// This implements the git smart HTTP protocol:
///   1. GET /info/refs?service=git-upload-pack  (discover refs)
///   2. POST /git-upload-pack  (negotiate and receive pack)
///   3. Store pack + refs in target_path/.git/
/// Returns 0 on success, negative on error.
export fn ziggit_clone_bare(url_ptr: [*]const u8, url_len: u32, target_ptr: [*]const u8, target_len: u32) i32 {
    const allocator = getAllocator();
    const url = url_ptr[0..url_len];
    const target = target_ptr[0..target_len];

    // Step 0: Initialize bare repo structure
    const init_rc = ziggit_init(target_ptr, target_len);
    if (init_rc < 0) return -1;

    // Mark as bare
    writeHostFile(allocator, target, ".git/config", "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n") catch return -2;

    // Step 1: Discover refs via smart HTTP
    const info_url = std.fmt.allocPrint(allocator, "{s}/info/refs?service=git-upload-pack", .{url}) catch return -3;
    defer allocator.free(info_url);

    var refs_resp_ptr: [*]u8 = undefined;
    var refs_resp_len: u32 = undefined;
    const get_rc = host_http_get(info_url.ptr, @intCast(info_url.len), &refs_resp_ptr, &refs_resp_len);
    if (get_rc != 0) return -4;

    const refs_data = refs_resp_ptr[0..refs_resp_len];

    // Parse pkt-line refs response to find HEAD and branch refs
    var head_hash: ?[]const u8 = null;
    var main_ref: ?[]const u8 = null;
    var pos: usize = 0;

    while (pos + 4 <= refs_data.len) {
        // Read pkt-line length (4 hex digits)
        const len_hex = refs_data[pos .. pos + 4];
        const pkt_len = std.fmt.parseInt(u16, len_hex, 16) catch break;

        if (pkt_len == 0) {
            pos += 4; // flush packet
            continue;
        }
        if (pkt_len < 4 or pos + pkt_len > refs_data.len) break;

        const line = refs_data[pos + 4 .. pos + pkt_len];
        pos += pkt_len;

        // Skip service announcement and comments
        if (line.len > 0 and line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "# ")) continue;

        // Look for hash + ref lines
        // Format: "<40-hex-hash> <refname>\n" possibly with NUL-separated capabilities
        if (line.len >= 41 and line[40] == ' ') {
            const hash = line[0..40];
            // Find ref name (may have \0 for capabilities or \n at end)
            var ref_end = line.len;
            for (line[41..], 0..) |c, i| {
                if (c == '\n' or c == 0) {
                    ref_end = 41 + i;
                    break;
                }
            }
            const ref_name = line[41..ref_end];

            if (std.mem.eql(u8, ref_name, "HEAD")) {
                head_hash = hash;
            } else if (std.mem.eql(u8, ref_name, "refs/heads/main") or std.mem.eql(u8, ref_name, "refs/heads/master")) {
                main_ref = ref_name;
                // Write ref
                writeHostFile(allocator, target, std.fmt.allocPrint(allocator, ".git/{s}", .{ref_name}) catch continue, hash) catch {};
                // Update HEAD symref
                const head_ref = std.fmt.allocPrint(allocator, "ref: {s}\n", .{ref_name}) catch continue;
                defer allocator.free(head_ref);
                writeHostFile(allocator, target, ".git/HEAD", head_ref) catch {};
            } else if (std.mem.startsWith(u8, ref_name, "refs/")) {
                // Store other refs too
                const ref_file = std.fmt.allocPrint(allocator, ".git/{s}", .{ref_name}) catch continue;
                defer allocator.free(ref_file);
                writeHostFile(allocator, target, ref_file, hash) catch {};
            }
        }
    }

    if (head_hash == null) return -5; // No HEAD found

    // Step 2: Send want/have negotiation to get pack
    const upload_url = std.fmt.allocPrint(allocator, "{s}/git-upload-pack", .{url}) catch return -6;
    defer allocator.free(upload_url);

    // Build want request: "want <hash>\n" for HEAD
    const want_line = std.fmt.allocPrint(allocator, "want {s}\n", .{head_hash.?}) catch return -7;
    defer allocator.free(want_line);

    const want_pkt = std.fmt.allocPrint(allocator, "{x:0>4}{s}", .{ want_line.len + 4, want_line }) catch return -7;
    defer allocator.free(want_pkt);

    // Full request: want pkt + flush + done pkt
    const done_pkt = "0009done\n";
    const body = std.fmt.allocPrint(allocator, "{s}00000032want {s}\n0000{s}", .{ want_pkt, head_hash.?, done_pkt }) catch return -8;
    defer allocator.free(body);

    // Actually, simplify: just send the standard clone request
    var request_buf = std.ArrayList(u8).init(allocator);
    defer request_buf.deinit();

    // want HEAD
    const want_str = std.fmt.allocPrint(allocator, "want {s} no-progress\n", .{head_hash.?}) catch return -8;
    defer allocator.free(want_str);

    // pkt-line encode
    const want_pkt_len = want_str.len + 4;
    request_buf.writer().print("{x:0>4}", .{want_pkt_len}) catch return -8;
    request_buf.appendSlice(want_str) catch return -8;
    request_buf.appendSlice("0000") catch return -8; // flush
    request_buf.appendSlice("0009done\n") catch return -8;

    const content_type = "application/x-git-upload-pack-request";
    var pack_resp_ptr: [*]u8 = undefined;
    var pack_resp_len: u32 = undefined;
    const post_rc = host_http_post(upload_url.ptr, @intCast(upload_url.len), request_buf.items.ptr, @intCast(request_buf.items.len), content_type.ptr, @intCast(content_type.len), &pack_resp_ptr, &pack_resp_len);
    if (post_rc != 0) return -9;

    const pack_data = pack_resp_ptr[0..pack_resp_len];

    // Step 3: Find and save pack data (skip NAK/ACK pkt-lines before PACK header)
    var pack_start: usize = 0;
    for (0..pack_data.len -| 3) |i| {
        if (std.mem.eql(u8, pack_data[i .. i + 4], "PACK")) {
            pack_start = i;
            break;
        }
    }

    if (pack_start == 0 and (pack_data.len < 4 or !std.mem.eql(u8, pack_data[0..4], "PACK"))) {
        return -10; // No PACK signature found
    }

    // Save pack file
    const pack_filename = ".git/objects/pack/pack-clone.pack";
    writeHostFile(allocator, target, pack_filename, pack_data[pack_start..]) catch return -11;

    return 0;
}

/// List refs in a remote repository via smart HTTP.
/// Writes newline-separated "hash refname" pairs to out_ptr.
/// Returns bytes written, or negative error.
export fn ziggit_ls_remote(url_ptr: [*]const u8, url_len: u32, out_ptr: [*]u8, out_cap: u32) i32 {
    const allocator = getAllocator();
    const url = url_ptr[0..url_len];

    const info_url = std.fmt.allocPrint(allocator, "{s}/info/refs?service=git-upload-pack", .{url}) catch return -1;
    defer allocator.free(info_url);

    var resp_ptr: [*]u8 = undefined;
    var resp_len: u32 = undefined;
    const rc = host_http_get(info_url.ptr, @intCast(info_url.len), &resp_ptr, &resp_len);
    if (rc != 0) return -2;

    const data = resp_ptr[0..resp_len];
    var written: u32 = 0;
    var pos: usize = 0;

    while (pos + 4 <= data.len) {
        const len_hex = data[pos .. pos + 4];
        const pkt_len = std.fmt.parseInt(u16, len_hex, 16) catch break;
        if (pkt_len == 0) { pos += 4; continue; }
        if (pkt_len < 4 or pos + pkt_len > data.len) break;
        const line = data[pos + 4 .. pos + pkt_len];
        pos += pkt_len;

        if (line.len >= 41 and line[40] == ' ') {
            const hash = line[0..40];
            var ref_end = line.len;
            for (line[41..], 0..) |c, i| {
                if (c == '\n' or c == 0) { ref_end = 41 + i; break; }
            }
            const ref_name = line[41..ref_end];
            const entry_len = 40 + 1 + ref_name.len + 1; // "hash ref\n"
            if (written + entry_len > out_cap) break;
            @memcpy(out_ptr[written .. written + 40], hash);
            out_ptr[written + 40] = ' ';
            @memcpy(out_ptr[written + 41 .. written + 41 + ref_name.len], ref_name);
            out_ptr[written + 41 + ref_name.len] = '\n';
            written += @intCast(entry_len);
        }
    }

    return @intCast(written);
}

/// Get ziggit version string. Returns length written to out_ptr.
export fn ziggit_version(out_ptr: [*]u8, out_cap: u32) u32 {
    const version = "ziggit 0.1.0 (wasm-browser)";
    const copy_len = @min(version.len, out_cap);
    @memcpy(out_ptr[0..copy_len], version[0..copy_len]);
    return @intCast(copy_len);
}
