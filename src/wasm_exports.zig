const zlib_compat = @import("git/zlib_compat.zig");
const stream_utils = @import("git/stream_utils.zig");
const DeltaCache = @import("git/delta_cache.zig").DeltaCache;
const gitignore = @import("git/gitignore.zig");
const validation = @import("git/validation.zig");
const diff = @import("git/diff.zig");
const blame = @import("git/blame.zig");
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

    var compressed = std.array_list.Managed(u8).init(allocator);
    defer compressed.deinit();

    var comp = zlib_compat.compressorWriter(compressed.writer(), .{}) catch return -3;
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
    var request_buf = std.array_list.Managed(u8).init(allocator);
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

// ========== In-memory pack store ==========
// After clone_bare downloads a pack, these globals hold the pack + idx in WASM memory
// for efficient object lookups without re-reading from the host filesystem.

var global_pack_data: ?[]u8 = null;
var global_idx_data: ?[]u8 = null;

/// After clone_bare downloads a pack, call this to index it for object lookups.
/// path_ptr/path_len: repo path (e.g. "/repo")
/// Reads pack from host FS, generates idx, stores both as globals.
/// Returns 0 on success, negative on error.
export fn ziggit_index_pack(path_ptr: [*]const u8, path_len: u32) i32 {
    const allocator = getAllocator();
    const path = path_ptr[0..path_len];

    // Free previous data if any
    if (global_pack_data) |d| allocator.free(d);
    if (global_idx_data) |d| allocator.free(d);
    global_pack_data = null;
    global_idx_data = null;

    // Read pack file from host filesystem
    const pack_data = readHostFile(allocator, path, ".git/objects/pack/pack-clone.pack") catch return -1;

    // Generate idx from pack data
    const idx_data = generateIdxFromPackData(allocator, pack_data) catch {
        allocator.free(pack_data);
        return -2;
    };

    global_pack_data = pack_data;
    global_idx_data = idx_data;
    return 0;
}

/// Read a git object by its hex SHA-1 hash from the in-memory pack.
/// hash_ptr: pointer to 40 hex chars
/// out_ptr: buffer to write object data
/// out_cap: capacity of out buffer
/// type_out: pointer to write object type (1=commit, 2=tree, 3=blob, 4=tag)
/// Returns data length on success, negative on error.
export fn ziggit_read_object(hash_ptr: [*]const u8, hash_len: u32, out_ptr: [*]u8, out_cap: u32, type_out: *u32) i32 {
    if (hash_len < 40) return -1;
    const allocator = getAllocator();
    const pack_data = global_pack_data orelse return -2;
    const idx_data = global_idx_data orelse return -3;

    // Parse hex hash to binary
    var target_hash: [20]u8 = undefined;
    for (0..20) |i| {
        target_hash[i] = std.fmt.parseInt(u8, hash_ptr[i * 2 .. i * 2 + 2], 16) catch return -4;
    }

    // Find offset in idx
    const offset = findOffsetInIdx(idx_data, target_hash) orelse return -5;

    // Read object from pack
    const obj = readPackedObjectFromData(pack_data, offset, allocator) catch return -6;
    defer obj.deinit(allocator);

    if (obj.data.len > out_cap) return -7;

    @memcpy(out_ptr[0..obj.data.len], obj.data);
    type_out.* = switch (obj.obj_type) {
        .commit => 1,
        .tree => 2,
        .blob => 3,
        .tag => 4,
    };
    return @intCast(obj.data.len);
}

/// Get commit log as JSON. Walks parent chain from HEAD.
/// path_ptr/path_len: repo path
/// max_count: max commits to return
/// out_ptr/out_cap: output buffer for JSON
/// Returns bytes written, or negative on error.
/// Format: [{"hash":"abc...","message":"...","author":"...","parent":"def..."},...]
export fn ziggit_log(path_ptr: [*]const u8, path_len: u32, max_count: u32, out_ptr: [*]u8, out_cap: u32) i32 {
    const allocator = getAllocator();
    const pack_data = global_pack_data orelse return -1;
    const idx_data = global_idx_data orelse return -2;

    // Get HEAD hash
    var head_buf: [40]u8 = undefined;
    const head_rc = ziggit_rev_parse_head(path_ptr, path_len, &head_buf);
    if (head_rc != 0) return -3;

    var json = std.array_list.Managed(u8).init(allocator);
    defer json.deinit();
    json.appendSlice("[") catch return -4;

    var current_hash: [40]u8 = head_buf;
    var count: u32 = 0;

    while (count < max_count) : (count += 1) {
        // Parse hex hash
        var hash_bytes: [20]u8 = undefined;
        for (0..20) |i| {
            hash_bytes[i] = std.fmt.parseInt(u8, current_hash[i * 2 .. i * 2 + 2], 16) catch break;
        }

        const offset = findOffsetInIdx(idx_data, hash_bytes) orelse break;
        const obj = readPackedObjectFromData(pack_data, offset, allocator) catch break;
        defer obj.deinit(allocator);

        if (obj.obj_type != .commit) break;

        // Parse commit object
        const commit_data = obj.data;
        var parent_hash: ?[]const u8 = null;
        var author: []const u8 = "";
        var message: []const u8 = "";

        var line_iter = std.mem.splitScalar(u8, commit_data, '\n');
        var in_headers = true;
        var msg_start: usize = 0;
        var pos: usize = 0;

        // Find headers and message
        var lines_buf = std.array_list.Managed(u8).init(allocator);
        defer lines_buf.deinit();

        while (line_iter.next()) |line| {
            pos += line.len + 1;
            if (in_headers) {
                if (line.len == 0) {
                    in_headers = false;
                    msg_start = pos;
                    continue;
                }
                if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                    parent_hash = line[7..47];
                } else if (std.mem.startsWith(u8, line, "author ")) {
                    // Extract author name (before email)
                    const rest = line[7..];
                    if (std.mem.indexOf(u8, rest, " <")) |email_start| {
                        author = rest[0..email_start];
                    } else {
                        author = rest;
                    }
                }
            }
        }

        // Message is everything after blank line
        if (msg_start < commit_data.len) {
            message = std.mem.trimRight(u8, commit_data[msg_start..], "\n\r ");
            // Take only first line of message
            if (std.mem.indexOfScalar(u8, message, '\n')) |nl| {
                message = message[0..nl];
            }
        }

        if (count > 0) json.appendSlice(",") catch return -4;
        json.appendSlice("{\"hash\":\"") catch return -4;
        json.appendSlice(&current_hash) catch return -4;
        json.appendSlice("\",\"message\":\"") catch return -4;
        appendJsonEscaped(&json, message) catch return -4;
        json.appendSlice("\",\"author\":\"") catch return -4;
        appendJsonEscaped(&json, author) catch return -4;
        json.appendSlice("\",\"parent\":\"") catch return -4;
        if (parent_hash) |ph| {
            json.appendSlice(ph) catch return -4;
        }
        json.appendSlice("\"}") catch return -4;

        // Follow parent
        if (parent_hash) |ph| {
            @memcpy(&current_hash, ph[0..40]);
        } else {
            count += 1;
            break;
        }
    }

    json.appendSlice("]") catch return -4;

    if (json.items.len > out_cap) return -5;
    @memcpy(out_ptr[0..json.items.len], json.items);
    return @intCast(json.items.len);
}

/// List files in a tree object. Writes JSON to out_ptr.
/// Format: [{"mode":"100644","name":"file.txt","hash":"abc...","type":"blob"},...]
/// tree_hash_ptr: 40 hex chars of tree hash
/// Returns bytes written, or negative on error.
export fn ziggit_ls_tree(tree_hash_ptr: [*]const u8, tree_hash_len: u32, out_ptr: [*]u8, out_cap: u32) i32 {
    if (tree_hash_len < 40) return -1;
    const allocator = getAllocator();
    const pack_data = global_pack_data orelse return -2;
    const idx_data = global_idx_data orelse return -3;

    // Read tree object
    var hash_bytes: [20]u8 = undefined;
    for (0..20) |i| {
        hash_bytes[i] = std.fmt.parseInt(u8, tree_hash_ptr[i * 2 .. i * 2 + 2], 16) catch return -4;
    }

    const offset = findOffsetInIdx(idx_data, hash_bytes) orelse return -5;
    const obj = readPackedObjectFromData(pack_data, offset, allocator) catch return -6;
    defer obj.deinit(allocator);

    if (obj.obj_type != .tree) return -7;

    // Parse tree entries: each entry is "<mode> <name>\0<20-byte-hash>"
    var json = std.array_list.Managed(u8).init(allocator);
    defer json.deinit();
    json.appendSlice("[") catch return -8;

    var pos: usize = 0;
    var first = true;
    const data = obj.data;

    while (pos < data.len) {
        // Find space (separates mode from name)
        const space = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse break;
        const mode = data[pos..space];

        // Find null (separates name from hash)
        const null_pos = std.mem.indexOfScalarPos(u8, data, space + 1, 0) orelse break;
        const name = data[space + 1 .. null_pos];

        if (null_pos + 21 > data.len) break;
        const entry_hash = data[null_pos + 1 .. null_pos + 21];

        // Determine type from mode
        const entry_type: []const u8 = if (std.mem.eql(u8, mode, "40000") or std.mem.eql(u8, mode, "040000"))
            "tree"
        else if (std.mem.eql(u8, mode, "160000"))
            "commit"
        else
            "blob";

        if (!first) json.appendSlice(",") catch return -8;
        first = false;

        json.appendSlice("{\"mode\":\"") catch return -8;
        json.appendSlice(mode) catch return -8;
        json.appendSlice("\",\"name\":\"") catch return -8;
        appendJsonEscaped(&json, name) catch return -8;
        json.appendSlice("\",\"hash\":\"") catch return -8;
        const hex = std.fmt.bytesToHex(entry_hash[0..20].*, .lower);
        json.appendSlice(&hex) catch return -8;
        json.appendSlice("\",\"type\":\"") catch return -8;
        json.appendSlice(entry_type) catch return -8;
        json.appendSlice("\"}") catch return -8;

        pos = null_pos + 21;
    }

    json.appendSlice("]") catch return -8;
    if (json.items.len > out_cap) return -9;
    @memcpy(out_ptr[0..json.items.len], json.items);
    return @intCast(json.items.len);
}

/// Read a file from the repo at a given commit.
/// Resolves: commit → tree → walk path → blob → data
/// Returns bytes written, or negative on error.
export fn ziggit_read_file(commit_hash_ptr: [*]const u8, commit_hash_len: u32, file_path_ptr: [*]const u8, file_path_len: u32, out_ptr: [*]u8, out_cap: u32) i32 {
    if (commit_hash_len < 40) return -1;
    const allocator = getAllocator();
    const pack_data = global_pack_data orelse return -2;
    const idx_data = global_idx_data orelse return -3;

    // Read commit to get tree hash
    var commit_hash_bytes: [20]u8 = undefined;
    for (0..20) |i| {
        commit_hash_bytes[i] = std.fmt.parseInt(u8, commit_hash_ptr[i * 2 .. i * 2 + 2], 16) catch return -4;
    }

    const commit_offset = findOffsetInIdx(idx_data, commit_hash_bytes) orelse return -5;
    const commit_obj = readPackedObjectFromData(pack_data, commit_offset, allocator) catch return -6;
    defer commit_obj.deinit(allocator);

    if (commit_obj.obj_type != .commit) return -7;

    // Extract tree hash from commit (first line: "tree <40hex>")
    const commit_data = commit_obj.data;
    if (!std.mem.startsWith(u8, commit_data, "tree ") or commit_data.len < 45) return -8;
    const tree_hash_hex = commit_data[5..45];

    // Walk path segments through trees
    const file_path = file_path_ptr[0..file_path_len];
    var current_tree_hex: [40]u8 = undefined;
    @memcpy(&current_tree_hex, tree_hash_hex);

    var path_iter = std.mem.splitScalar(u8, file_path, '/');
    while (path_iter.next()) |segment| {
        if (segment.len == 0) continue;

        // Read current tree
        var tree_hash_bytes: [20]u8 = undefined;
        for (0..20) |i| {
            tree_hash_bytes[i] = std.fmt.parseInt(u8, current_tree_hex[i * 2 .. i * 2 + 2], 16) catch return -9;
        }

        const tree_offset = findOffsetInIdx(idx_data, tree_hash_bytes) orelse return -10;
        const tree_obj = readPackedObjectFromData(pack_data, tree_offset, allocator) catch return -11;
        defer tree_obj.deinit(allocator);

        if (tree_obj.obj_type != .tree) return -12;

        // Search for entry matching segment
        var found = false;
        var pos: usize = 0;
        const tdata = tree_obj.data;
        while (pos < tdata.len) {
            const space = std.mem.indexOfScalarPos(u8, tdata, pos, ' ') orelse break;
            const null_pos = std.mem.indexOfScalarPos(u8, tdata, space + 1, 0) orelse break;
            const name = tdata[space + 1 .. null_pos];
            if (null_pos + 21 > tdata.len) break;
            const entry_hash = tdata[null_pos + 1 .. null_pos + 21];

            if (std.mem.eql(u8, name, segment)) {
                const hex = std.fmt.bytesToHex(entry_hash[0..20].*, .lower);
                @memcpy(&current_tree_hex, &hex);
                found = true;
                break;
            }
            pos = null_pos + 21;
        }
        if (!found) return -13; // path not found
    }

    // current_tree_hex now points to the blob (or subtree)
    var blob_hash_bytes: [20]u8 = undefined;
    for (0..20) |i| {
        blob_hash_bytes[i] = std.fmt.parseInt(u8, current_tree_hex[i * 2 .. i * 2 + 2], 16) catch return -14;
    }

    const blob_offset = findOffsetInIdx(idx_data, blob_hash_bytes) orelse return -15;
    const blob_obj = readPackedObjectFromData(pack_data, blob_offset, allocator) catch return -16;
    defer blob_obj.deinit(allocator);

    if (blob_obj.obj_type != .blob) return -17;
    if (blob_obj.data.len > out_cap) return -18;

    @memcpy(out_ptr[0..blob_obj.data.len], blob_obj.data);
    return @intCast(blob_obj.data.len);
}

/// Get tree hash from a commit. Writes 40 hex chars to out_ptr.
/// Returns 0 on success, negative on error.
export fn ziggit_commit_tree(commit_hash_ptr: [*]const u8, commit_hash_len: u32, out_ptr: [*]u8) i32 {
    if (commit_hash_len < 40) return -1;
    const allocator = getAllocator();
    const pack_data = global_pack_data orelse return -2;
    const idx_data = global_idx_data orelse return -3;

    var hash_bytes: [20]u8 = undefined;
    for (0..20) |i| {
        hash_bytes[i] = std.fmt.parseInt(u8, commit_hash_ptr[i * 2 .. i * 2 + 2], 16) catch return -4;
    }

    const offset = findOffsetInIdx(idx_data, hash_bytes) orelse return -5;
    const obj = readPackedObjectFromData(pack_data, offset, allocator) catch return -6;
    defer obj.deinit(allocator);

    if (obj.obj_type != .commit) return -7;
    if (!std.mem.startsWith(u8, obj.data, "tree ") or obj.data.len < 45) return -8;
    @memcpy(out_ptr[0..40], obj.data[5..45]);
    return 0;
}

// ========== Pure in-memory pack/idx implementations ==========
// These are self-contained — no filesystem, no platform_impl needed.

const PackObjType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

const InMemoryObjType = enum { commit, tree, blob, tag };

const InMemoryGitObject = struct {
    obj_type: InMemoryObjType,
    data: []const u8,

    fn deinit(self: InMemoryGitObject, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Read a packed object from raw pack data at the given offset.
/// Handles commit/tree/blob/tag and OFS_DELTA. REF_DELTA requires idx lookup
/// which is done via the global idx_data.
fn readPackedObjectFromData(pack_data: []const u8, offset: usize, allocator: std.mem.Allocator) !InMemoryGitObject {
    if (offset >= pack_data.len) return error.ObjectNotFound;

    var pos = offset;
    const first_byte = pack_data[pos];
    pos += 1;

    const pack_type_num: u3 = @intCast((first_byte >> 4) & 7);
    const pack_type = std.meta.intToEnum(PackObjType, pack_type_num) catch return error.ObjectNotFound;

    // Read variable-length size
    var size: usize = @intCast(first_byte & 15);
    const ShiftT = std.math.Log2Int(usize);
    var shift: ShiftT = 4;
    var current_byte = first_byte;
    while (current_byte & 0x80 != 0 and pos < pack_data.len) {
        current_byte = pack_data[pos];
        pos += 1;
        size |= @as(usize, @intCast(current_byte & 0x7F)) << shift;
        if (shift < 60) shift += 7 else break;
    }

    switch (pack_type) {
        .commit, .tree, .blob, .tag => {
            if (pos >= pack_data.len) return error.ObjectNotFound;
            const decompressed = zlib_compat.decompressSlice(allocator, pack_data[pos..]) catch return error.ObjectNotFound;
            const obj_type: InMemoryObjType = switch (pack_type) {
                .commit => .commit,
                .tree => .tree,
                .blob => .blob,
                .tag => .tag,
                else => unreachable,
            };
            return InMemoryGitObject{ .obj_type = obj_type, .data = decompressed };
        },
        .ofs_delta => {
            if (pos >= pack_data.len) return error.ObjectNotFound;
            var base_offset_delta: usize = 0;
            var first_offset_byte = true;
            while (pos < pack_data.len) {
                const offset_byte = pack_data[pos];
                pos += 1;
                if (first_offset_byte) {
                    base_offset_delta = @intCast(offset_byte & 0x7F);
                    first_offset_byte = false;
                } else {
                    base_offset_delta = (base_offset_delta + 1) << 7;
                    base_offset_delta += @intCast(offset_byte & 0x7F);
                }
                if (offset_byte & 0x80 == 0) break;
            }
            if (base_offset_delta >= offset) return error.ObjectNotFound;
            const base_offset = offset - base_offset_delta;
            const base_object = try readPackedObjectFromData(pack_data, base_offset, allocator);
            defer base_object.deinit(allocator);
            const delta_data_slice = zlib_compat.decompressSlice(allocator, pack_data[pos..]) catch return error.ObjectNotFound;
            defer allocator.free(delta_data_slice);
            const result_data = try applyDelta(base_object.data, delta_data_slice, allocator);
            return InMemoryGitObject{ .obj_type = base_object.obj_type, .data = result_data };
        },
        .ref_delta => {
            // REF_DELTA: look up base object by SHA-1 in idx
            if (pos + 20 > pack_data.len) return error.ObjectNotFound;
            const base_sha1 = pack_data[pos .. pos + 20];
            pos += 20;
            const idx_data = global_idx_data orelse return error.ObjectNotFound;
            const base_offset = findOffsetInIdx(idx_data, base_sha1[0..20].*) orelse return error.ObjectNotFound;
            const base_object = try readPackedObjectFromData(pack_data, base_offset, allocator);
            defer base_object.deinit(allocator);
            const delta_data_slice = zlib_compat.decompressSlice(allocator, pack_data[pos..]) catch return error.ObjectNotFound;
            defer allocator.free(delta_data_slice);
            const result_data = try applyDelta(base_object.data, delta_data_slice, allocator);
            return InMemoryGitObject{ .obj_type = base_object.obj_type, .data = result_data };
        },
    }
}

/// Apply a git delta to a base object, producing the result.
fn applyDelta(base_data: []const u8, delta: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var pos: usize = 0;

    // Read base size (variable-length int) — skip it, we trust base_data.len
    {
        const ShiftType = std.math.Log2Int(usize);
        var shift_s: ShiftType = 0;
        _ = &shift_s;
        while (pos < delta.len) {
            const b = delta[pos];
            pos += 1;
            if (b & 0x80 == 0) break;
        }
    }

    // Read result size
    var result_size: usize = 0;
    const ShiftType2 = std.math.Log2Int(usize);
    var shift: ShiftType2 = 0;
    while (pos < delta.len) {
        const b = delta[pos];
        pos += 1;
        result_size |= @as(usize, b & 0x7F) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
    }

    var result = try std.array_list.Managed(u8).initCapacity(allocator, result_size);
    errdefer result.deinit();

    while (pos < delta.len) {
        const cmd = delta[pos];
        pos += 1;

        if (cmd & 0x80 != 0) {
            // Copy from base
            var copy_offset: usize = 0;
            var copy_size: usize = 0;

            if (cmd & 0x01 != 0) { copy_offset = delta[pos]; pos += 1; }
            if (cmd & 0x02 != 0) { copy_offset |= @as(usize, delta[pos]) << 8; pos += 1; }
            if (cmd & 0x04 != 0) { copy_offset |= @as(usize, delta[pos]) << 16; pos += 1; }
            if (cmd & 0x08 != 0) { copy_offset |= @as(usize, delta[pos]) << 24; pos += 1; }

            if (cmd & 0x10 != 0) { copy_size = delta[pos]; pos += 1; }
            if (cmd & 0x20 != 0) { copy_size |= @as(usize, delta[pos]) << 8; pos += 1; }
            if (cmd & 0x40 != 0) { copy_size |= @as(usize, delta[pos]) << 16; pos += 1; }

            if (copy_size == 0) copy_size = 0x10000;

            if (copy_offset + copy_size > base_data.len) return error.DeltaCopyOutOfBounds;
            try result.appendSlice(base_data[copy_offset .. copy_offset + copy_size]);
        } else if (cmd > 0) {
            // Insert from delta
            const insert_size: usize = cmd;
            if (pos + insert_size > delta.len) return error.DeltaInsertOutOfBounds;
            try result.appendSlice(delta[pos .. pos + insert_size]);
            pos += insert_size;
        } else {
            // cmd == 0 is reserved
            return error.DeltaReservedCommand;
        }
    }

    return try result.toOwnedSlice();
}

/// Binary search for object offset in a v2 pack index.
fn findOffsetInIdx(idx_data: []const u8, target_hash: [20]u8) ?usize {
    if (idx_data.len < 8) return null;

    const magic = std.mem.readInt(u32, idx_data[0..4], .big);
    if (magic != 0xff744f63) return null; // Only v2 supported

    const fanout_start: usize = 8;
    const first_byte = target_hash[0];

    if (idx_data.len < fanout_start + 256 * 4) return null;

    const start_index: u32 = if (first_byte == 0) 0 else std.mem.readInt(u32, idx_data[fanout_start + (@as(usize, first_byte) - 1) * 4 ..][0..4], .big);
    const end_index = std.mem.readInt(u32, idx_data[fanout_start + @as(usize, first_byte) * 4 ..][0..4], .big);

    if (start_index >= end_index) return null;

    const total_objects = std.mem.readInt(u32, idx_data[fanout_start + 255 * 4 ..][0..4], .big);
    const sha1_table_start = fanout_start + 256 * 4;
    const crc_table_start = sha1_table_start + @as(usize, total_objects) * 20;
    const offset_table_start = crc_table_start + @as(usize, total_objects) * 4;

    var low = start_index;
    var high = end_index;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const sha_offset = sha1_table_start + @as(usize, mid) * 20;
        if (sha_offset + 20 > idx_data.len) return null;

        const obj_hash = idx_data[sha_offset .. sha_offset + 20];
        const cmp = std.mem.order(u8, obj_hash, &target_hash);

        switch (cmp) {
            .eq => {
                const off_offset = offset_table_start + @as(usize, mid) * 4;
                if (off_offset + 4 > idx_data.len) return null;
                var offset_val: u64 = std.mem.readInt(u32, idx_data[off_offset..][0..4], .big);

                if (offset_val & 0x80000000 != 0) {
                    const large_idx: usize = @intCast(offset_val & 0x7FFFFFFF);
                    const large_table_start = offset_table_start + @as(usize, total_objects) * 4;
                    const large_off = large_table_start + large_idx * 8;
                    if (large_off + 8 > idx_data.len) return null;
                    offset_val = std.mem.readInt(u64, idx_data[large_off..][0..8], .big);
                }
                return @intCast(offset_val);
            },
            .lt => low = mid + 1,
            .gt => high = mid,
        }
    }
    return null;
}

/// Generate a v2 pack index from raw pack data (pure in-memory).
fn generateIdxFromPackData(allocator: std.mem.Allocator, pack_data: []const u8) ![]u8 {
    if (pack_data.len < 32) return error.PackFileTooSmall;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackSignature;

    const object_count = std.mem.readInt(u32, pack_data[8..12], .big);
    const content_end = pack_data.len - 20;
    const pack_checksum = pack_data[content_end..][0..20];

    const IdxEntry = struct {
        sha1: [20]u8,
        offset: u32,
        crc: u32,
    };

    var entries = std.array_list.Managed(IdxEntry).init(allocator);
    defer entries.deinit();
    try entries.ensureTotalCapacity(object_count);

    // Cache for delta resolution: offset -> (type_str, data)
    const CachedObj = struct { type_str: []const u8, data: []const u8 };
    var cache = std.AutoHashMap(usize, CachedObj).init(allocator);
    defer {
        var it = cache.valueIterator();
        while (it.next()) |v| allocator.free(v.data);
        cache.deinit();
    }

    var decompressed = std.array_list.Managed(u8).init(allocator);
    defer decompressed.deinit();

    var pos: usize = 12;
    var obj_idx: u32 = 0;

    while (obj_idx < object_count and pos < content_end) {
        const obj_start = pos;
        const first_byte = pack_data[pos];
        pos += 1;
        const pack_type_num: u3 = @intCast((first_byte >> 4) & 7);
        var size: usize = @intCast(first_byte & 0x0F);
        var shift_val: std.math.Log2Int(usize) = 4;
        var cur_byte = first_byte;
        while (cur_byte & 0x80 != 0 and pos < content_end) {
            cur_byte = pack_data[pos];
            pos += 1;
            size |= @as(usize, @intCast(cur_byte & 0x7F)) << shift_val;
            if (shift_val < 60) shift_val += 7 else break;
        }

        var base_offset: ?usize = null;
        var base_sha1: ?[20]u8 = null;

        if (pack_type_num == 6) {
            var delta_off: usize = 0;
            var first_delta_byte = true;
            while (pos < content_end) {
                const b = pack_data[pos];
                pos += 1;
                if (first_delta_byte) {
                    delta_off = @intCast(b & 0x7F);
                    first_delta_byte = false;
                } else {
                    delta_off = (delta_off + 1) << 7;
                    delta_off += @intCast(b & 0x7F);
                }
                if (b & 0x80 == 0) break;
            }
            if (delta_off <= obj_start) base_offset = obj_start - delta_off;
        } else if (pack_type_num == 7) {
            if (pos + 20 <= content_end) {
                var sha1: [20]u8 = undefined;
                @memcpy(&sha1, pack_data[pos .. pos + 20]);
                base_sha1 = sha1;
                pos += 20;
            }
        }

        // Decompress using decompressSliceWithConsumed for accurate byte tracking
        decompressed.clearRetainingCapacity();
        const compressed_start = pos;
        const decomp_result = zlib_compat.decompressSliceWithConsumed(allocator, pack_data[pos..content_end]) catch {
            obj_idx += 1;
            continue;
        };
        defer allocator.free(decomp_result.data);
        decompressed.appendSlice(decomp_result.data) catch {
            obj_idx += 1;
            continue;
        };
        pos = compressed_start + decomp_result.consumed;

        const crc = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]);

        var obj_sha1: [20]u8 = undefined;

        if (pack_type_num >= 1 and pack_type_num <= 4) {
            const type_str: []const u8 = switch (pack_type_num) {
                1 => "commit",
                2 => "tree",
                3 => "blob",
                4 => "tag",
                else => unreachable,
            };
            var hdr_buf: [64]u8 = undefined;
            const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ type_str, decompressed.items.len }) catch unreachable;
            var sha_hasher = std.crypto.hash.Sha1.init(.{});
            sha_hasher.update(header);
            sha_hasher.update(decompressed.items);
            sha_hasher.final(&obj_sha1);
            try cache.put(obj_start, .{ .type_str = type_str, .data = try allocator.dupe(u8, decompressed.items) });
        } else if (pack_type_num == 6) {
            if (base_offset) |bo| {
                const base = cache.get(bo) orelse { obj_idx += 1; continue; };
                const result_data = applyDelta(base.data, decompressed.items, allocator) catch { obj_idx += 1; continue; };
                defer allocator.free(result_data);
                var hdr_buf: [64]u8 = undefined;
                const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ base.type_str, result_data.len }) catch unreachable;
                var sha_hasher = std.crypto.hash.Sha1.init(.{});
                sha_hasher.update(header);
                sha_hasher.update(result_data);
                sha_hasher.final(&obj_sha1);
                try cache.put(obj_start, .{ .type_str = base.type_str, .data = try allocator.dupe(u8, result_data) });
            } else { obj_idx += 1; continue; }
        } else if (pack_type_num == 7) {
            if (base_sha1) |target_sha| {
                var found_base: ?CachedObj = null;
                for (entries.items) |entry| {
                    if (std.mem.eql(u8, &entry.sha1, &target_sha)) {
                        found_base = cache.get(entry.offset);
                        break;
                    }
                }
                if (found_base) |base| {
                    const result_data = applyDelta(base.data, decompressed.items, allocator) catch { obj_idx += 1; continue; };
                    defer allocator.free(result_data);
                    var hdr_buf: [64]u8 = undefined;
                    const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ base.type_str, result_data.len }) catch unreachable;
                    var sha_hasher = std.crypto.hash.Sha1.init(.{});
                    sha_hasher.update(header);
                    sha_hasher.update(result_data);
                    sha_hasher.final(&obj_sha1);
                    try cache.put(obj_start, .{ .type_str = base.type_str, .data = try allocator.dupe(u8, result_data) });
                } else { obj_idx += 1; continue; }
            } else { obj_idx += 1; continue; }
        } else { obj_idx += 1; continue; }

        try entries.append(.{ .sha1 = obj_sha1, .offset = @intCast(obj_start), .crc = crc });
        obj_idx += 1;
    }

    // Sort entries by SHA-1
    std.mem.sort(IdxEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: IdxEntry, b: IdxEntry) bool {
            return std.mem.order(u8, &a.sha1, &b.sha1) == .lt;
        }
    }.lessThan);

    // Build v2 idx
    const total: u32 = @intCast(entries.items.len);
    // Header(8) + fanout(1024) + sha1_table(total*20) + crc_table(total*4) + offset_table(total*4) + pack_checksum(20) + idx_checksum(20)
    const idx_size = 8 + 1024 + @as(usize, total) * 20 + @as(usize, total) * 4 + @as(usize, total) * 4 + 20 + 20;
    var idx = try allocator.alloc(u8, idx_size);
    errdefer allocator.free(idx);

    var wp: usize = 0;

    // Magic + version
    std.mem.writeInt(u32, idx[wp..][0..4], 0xff744f63, .big);
    wp += 4;
    std.mem.writeInt(u32, idx[wp..][0..4], 2, .big);
    wp += 4;

    // Fanout table
    var fanout: [256]u32 = undefined;
    @memset(&fanout, 0);
    for (entries.items) |entry| {
        const bucket = entry.sha1[0];
        var i: usize = bucket;
        while (i < 256) : (i += 1) {
            fanout[i] += 1;
        }
    }
    for (fanout) |f| {
        std.mem.writeInt(u32, idx[wp..][0..4], f, .big);
        wp += 4;
    }

    // SHA-1 table
    for (entries.items) |entry| {
        @memcpy(idx[wp .. wp + 20], &entry.sha1);
        wp += 20;
    }

    // CRC table
    for (entries.items) |entry| {
        std.mem.writeInt(u32, idx[wp..][0..4], entry.crc, .big);
        wp += 4;
    }

    // Offset table
    for (entries.items) |entry| {
        std.mem.writeInt(u32, idx[wp..][0..4], entry.offset, .big);
        wp += 4;
    }

    // Pack checksum
    @memcpy(idx[wp .. wp + 20], pack_checksum);
    wp += 20;

    // Idx checksum
    var idx_hasher = std.crypto.hash.Sha1.init(.{});
    idx_hasher.update(idx[0..wp]);
    var idx_checksum: [20]u8 = undefined;
    idx_hasher.final(&idx_checksum);
    @memcpy(idx[wp .. wp + 20], &idx_checksum);

    return idx;
}

/// Escape a string for JSON output.
fn appendJsonEscaped(list: *std.array_list.Managed(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice("\\\""),
            '\\' => try list.appendSlice("\\\\"),
            '\n' => try list.appendSlice("\\n"),
            '\r' => try list.appendSlice("\\r"),
            '\t' => try list.appendSlice("\\t"),
            else => {
                if (c < 0x20) {
                    try list.writer().print("\\u{x:0>4}", .{c});
                } else {
                    try list.append(c);
                }
            },
        }
    }
}

// ========== Zlib decompression exports for browser use ==========

/// Decompress zlib data in WASM memory.
/// input_ptr/input_len: compressed zlib data
/// out_ptr: pointer to write decompressed data pointer (u32)
/// out_len: pointer to write decompressed data length (u32)
/// consumed_out: pointer to write number of input bytes consumed (u32)
/// Returns 0 on success, negative on error.
export fn ziggit_zlib_decompress(input_ptr: [*]const u8, input_len: u32, out_ptr: *u32, out_len: *u32, consumed_out: *u32) i32 {
    const allocator = getAllocator();
    const input = input_ptr[0..input_len];
    const result = zlib_compat.decompressSliceWithConsumed(allocator, input) catch return -1;
    out_ptr.* = @intFromPtr(result.data.ptr);
    out_len.* = @intCast(result.data.len);
    consumed_out.* = @intCast(result.consumed);
    return 0;
}

/// Compute SHA-1 hash of data. Writes 20 bytes to out_ptr.
export fn ziggit_sha1(data_ptr: [*]const u8, data_len: u32, out_ptr: [*]u8) void {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(data_ptr[0..data_len]);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    @memcpy(out_ptr[0..20], &digest);
}

/// Apply a git delta: base + delta -> result.
/// Returns result data length on success, negative on error.
/// Result is written starting at result_ptr (must be pre-allocated with enough space).
export fn ziggit_apply_delta(base_ptr: [*]const u8, base_len: u32, delta_ptr: [*]const u8, delta_len: u32, result_ptr_out: *u32, result_len_out: *u32) i32 {
    const allocator = getAllocator();
    const base = base_ptr[0..base_len];
    const delta = delta_ptr[0..delta_len];
    const result = applyDelta(base, delta, allocator) catch return -1;
    result_ptr_out.* = @intFromPtr(result.ptr);
    result_len_out.* = @intCast(result.len);
    return 0;
}

/// Load raw pack data directly into WASM memory for indexing.
/// pack_ptr/pack_len: raw pack bytes (starting with PACK header)
/// Returns 0 on success, negative on error.
/// After this call, use ziggit_read_object() to retrieve objects.
export fn ziggit_load_pack(pack_ptr: [*]const u8, pack_len: u32) i32 {
    const allocator = getAllocator();
    const pack_data = pack_ptr[0..pack_len];

    // Free previous data
    if (global_pack_data) |d| allocator.free(d);
    if (global_idx_data) |d| allocator.free(d);
    global_pack_data = null;
    global_idx_data = null;

    // Copy pack data to our own allocation
    const owned_pack = allocator.dupe(u8, pack_data) catch return -1;

    // Generate index
    const idx = generateIdxFromPackData(allocator, owned_pack) catch {
        allocator.free(owned_pack);
        return -2;
    };

    global_pack_data = owned_pack;
    global_idx_data = idx;
    return 0;
}

/// Get the number of objects in the loaded pack.
/// Returns count on success, negative if no pack loaded.
export fn ziggit_pack_object_count() i32 {
    const idx_data = global_idx_data orelse return -1;
    if (idx_data.len < 8 + 256 * 4) return -2;
    const total = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    return @intCast(total);
}

/// Decompress zlib data and compute SHA-1 hash in one pass.
/// type_ptr/type_len: git object type ("blob", "commit", etc.)
/// input_ptr/input_len: compressed data
/// sha1_out: pointer to write 20-byte SHA-1
/// size_out: pointer to write decompressed size
/// consumed_out: pointer to write bytes consumed from input
/// Returns 0 on success, negative on error.
export fn ziggit_decompress_and_hash(
    type_ptr: [*]const u8, type_len: u32,
    input_ptr: [*]const u8, input_len: u32,
    object_size: u32,
    sha1_out: [*]u8, size_out: *u32, consumed_out: *u32,
) i32 {
    const result = stream_utils.decompressAndHash(
        input_ptr[0..input_len],
        type_ptr[0..type_len],
        object_size,
    ) catch return -1;
    @memcpy(sha1_out[0..20], &result.sha1);
    size_out.* = @intCast(result.decompressed_size);
    consumed_out.* = @intCast(result.bytes_consumed);
    return 0;
}

/// Parse a pack object header at the given offset.
/// Returns type in type_out, size in size_out, header length in hdr_len_out.
/// Returns 0 on success, negative on error.
export fn ziggit_parse_pack_header(
    data_ptr: [*]const u8, data_len: u32, offset: u32,
    type_out: *u32, size_out: *u32, hdr_len_out: *u32,
) i32 {
    const hdr = stream_utils.parsePackObjectHeader(data_ptr[0..data_len], offset) catch return -1;
    type_out.* = hdr.type_num;
    size_out.* = @intCast(hdr.size);
    hdr_len_out.* = @intCast(hdr.header_len);
    return 0;
}

// ========== Gitignore pattern matching ==========

/// Global gitignore state for browser use
var global_gitignore: ?gitignore.GitIgnore = null;

/// Initialize gitignore with patterns from a .gitignore file content.
/// content_ptr/content_len: text content of .gitignore file
/// Returns 0 on success, negative on error.
export fn ziggit_gitignore_init(content_ptr: [*]const u8, content_len: u32) i32 {
    const allocator = getAllocator();
    if (global_gitignore) |*gi| gi.deinit();
    global_gitignore = gitignore.GitIgnore.init(allocator);
    var gi = &global_gitignore.?;
    gi.addPatterns(content_ptr[0..content_len]);
    return 0;
}

/// Check if a path matches gitignore patterns.
/// Returns 1 if ignored, 0 if not ignored, negative on error.
export fn ziggit_gitignore_match(path_ptr: [*]const u8, path_len: u32, is_dir: u32) i32 {
    var gi = global_gitignore orelse return -1;
    const path = path_ptr[0..path_len];
    const result = gi.isIgnoredPath(path, is_dir != 0);
    _ = &gi;
    return if (result) @as(i32, 1) else @as(i32, 0);
}

/// Free gitignore state.
export fn ziggit_gitignore_free() void {
    if (global_gitignore) |*gi| {
        gi.deinit();
        global_gitignore = null;
    }
}

// ========== Validation exports ==========

/// Validate a SHA-1 hash string (40 hex chars).
/// Returns 0 if valid, 1 if invalid.
export fn ziggit_validate_sha1(hash_ptr: [*]const u8, hash_len: u32) i32 {
    validation.validateSHA1Hash(hash_ptr[0..hash_len]) catch return 1;
    return 0;
}

/// Validate a git ref name.
/// Returns 0 if valid, 1 if invalid.
export fn ziggit_validate_ref(ref_ptr: [*]const u8, ref_len: u32) i32 {
    validation.validateRefName(ref_ptr[0..ref_len]) catch return 1;
    return 0;
}

/// Validate path security (no .git traversal attacks, etc.).
/// Returns 0 if safe, 1 if unsafe.
export fn ziggit_validate_path(path_ptr: [*]const u8, path_len: u32) i32 {
    validation.validatePathSecurity(path_ptr[0..path_len]) catch return 1;
    return 0;
}

// ========== Diff exports ==========

/// Generate unified diff between two texts.
/// old_ptr/old_len: old content
/// new_ptr/new_len: new content
/// path_ptr/path_len: file path for header
/// out_ptr/out_len: pointers to write result data pointer and length
/// Returns 0 on success, negative on error.
export fn ziggit_diff(old_ptr: [*]const u8, old_len: u32, new_ptr: [*]const u8, new_len: u32, path_ptr: [*]const u8, path_len: u32, out_ptr: *u32, out_len: *u32) i32 {
    const allocator = getAllocator();
    const result = diff.generateUnifiedDiff(
        old_ptr[0..old_len],
        new_ptr[0..new_len],
        path_ptr[0..path_len],
        allocator,
    ) catch return -1;
    out_ptr.* = @intFromPtr(result.ptr);
    out_len.* = @intCast(result.len);
    return 0;
}

/// Split text into lines. Returns JSON array of line strings.
/// Useful for diff/blame operations in the browser.
export fn ziggit_split_lines(text_ptr: [*]const u8, text_len: u32, out_ptr: *u32, out_len: *u32) i32 {
    const allocator = getAllocator();
    var lines = blame.splitLines(allocator, text_ptr[0..text_len]) catch return -1;
    defer lines.deinit();

    // Build JSON array
    var json = std.array_list.Managed(u8).init(allocator);
    json.appendSlice("[") catch return -2;
    for (lines.items, 0..) |line, i| {
        if (i > 0) json.appendSlice(",") catch return -2;
        json.appendSlice("\"") catch return -2;
        appendJsonEscaped(&json, line) catch return -2;
        json.appendSlice("\"") catch return -2;
    }
    json.appendSlice("]") catch return -2;

    const owned = json.toOwnedSlice() catch return -3;
    out_ptr.* = @intFromPtr(owned.ptr);
    out_len.* = @intCast(owned.len);
    return 0;
}

// ========== Recursive tree walk ==========

/// Recursively walk a tree and return all file paths as JSON.
/// tree_hash_ptr: 40 hex chars of root tree hash
/// out_ptr/out_len: pointers to write result JSON
/// Format: [{"path":"src/main.zig","hash":"abc...","mode":"100644","size":123},...]
/// Returns 0 on success, negative on error.
export fn ziggit_tree_walk(tree_hash_ptr: [*]const u8, tree_hash_len: u32, out_ptr: *u32, out_len: *u32) i32 {
    if (tree_hash_len < 40) return -1;
    const allocator = getAllocator();
    const pack_data = global_pack_data orelse return -2;
    const idx_data = global_idx_data orelse return -3;

    var json = std.array_list.Managed(u8).init(allocator);
    defer json.deinit();
    json.appendSlice("[") catch return -4;

    var first = true;
    walkTreeRecursive(pack_data, idx_data, tree_hash_ptr[0..40], "", allocator, &json, &first, 0) catch return -5;

    json.appendSlice("]") catch return -4;
    const owned = json.toOwnedSlice() catch return -6;
    out_ptr.* = @intFromPtr(owned.ptr);
    out_len.* = @intCast(owned.len);
    return 0;
}

fn walkTreeRecursive(
    pack_data: []const u8,
    idx_data: []const u8,
    tree_hash_hex: []const u8,
    prefix: []const u8,
    allocator: std.mem.Allocator,
    json: *std.array_list.Managed(u8),
    first: *bool,
    depth: u32,
) !void {
    if (depth > 20) return; // prevent infinite recursion

    var hash_bytes: [20]u8 = undefined;
    for (0..20) |i| {
        hash_bytes[i] = std.fmt.parseInt(u8, tree_hash_hex[i * 2 .. i * 2 + 2], 16) catch return;
    }

    const offset = findOffsetInIdx(idx_data, hash_bytes) orelse return;
    const obj = readPackedObjectFromData(pack_data, offset, allocator) catch return;
    defer obj.deinit(allocator);

    if (obj.obj_type != .tree) return;
    const data = obj.data;
    var pos: usize = 0;

    while (pos < data.len) {
        const space = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse break;
        const mode = data[pos..space];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space + 1, 0) orelse break;
        const name = data[space + 1 .. null_pos];
        if (null_pos + 21 > data.len) break;
        const entry_hash = data[null_pos + 1 .. null_pos + 21];
        pos = null_pos + 21;

        const hex = std.fmt.bytesToHex(entry_hash[0..20].*, .lower);
        const full_path = if (prefix.len > 0)
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name }) catch continue
        else
            allocator.dupe(u8, name) catch continue;
        defer allocator.free(full_path);

        const is_tree = std.mem.eql(u8, mode, "40000") or std.mem.eql(u8, mode, "040000");

        if (is_tree) {
            walkTreeRecursive(pack_data, idx_data, &hex, full_path, allocator, json, first, depth + 1) catch {};
        } else {
            // Emit entry
            if (!first.*) json.appendSlice(",") catch return;
            first.* = false;
            json.appendSlice("{\"path\":\"") catch return;
            appendJsonEscaped(json, full_path) catch return;
            json.appendSlice("\",\"hash\":\"") catch return;
            json.appendSlice(&hex) catch return;
            json.appendSlice("\",\"mode\":\"") catch return;
            json.appendSlice(mode) catch return;
            json.appendSlice("\"}") catch return;
        }
    }
}
