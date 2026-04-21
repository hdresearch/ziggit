const std = @import("std");
const objects = @import("objects.zig");
const git_serve = @import("git_serve.zig");
const HostCallbackStorage = @import("host_callback_storage.zig").HostCallbackStorage;

// Host callback for streaming output
extern fn host_emit_bytes(data_ptr: [*]const u8, data_len: u32) void;

pub const WasmGitServer = struct {
    allocator: std.mem.Allocator,
    storage: HostCallbackStorage,

    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) WasmGitServer {
        return .{
            .allocator = allocator,
            .storage = HostCallbackStorage.init(allocator, git_dir),
        };
    }

    pub fn deinit(self: *WasmGitServer) void {
        self.storage.deinit();
    }

    /// Generate ref advertisement for info/refs endpoint.
    /// service: 0 = git-upload-pack, 1 = git-receive-pack
    /// Streams response via host_emit_bytes.
    pub fn serveRefAdvertisement(self: *WasmGitServer, service: u32) !void {
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        // Get all refs from storage
        const ref_list = self.storage.listRefs() catch |err| {
            std.log.err("Failed to list refs: {}", .{err});
            return err;
        };
        defer ref_list.deinit();

        // Build capabilities line
        const service_name = if (service == 0) "git-upload-pack" else "git-receive-pack";
        var capabilities = std.ArrayList(u8).init(self.allocator);
        defer capabilities.deinit();

        try capabilities.appendSlice("multi_ack thin-pack side-band side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress include-tag multi_ack_detailed allow-tip-sha1-in-want allow-reachable-sha1-in-want no-done symref=HEAD:refs/heads/main filter");

        // Write service header
        var service_header = std.ArrayList(u8).init(self.allocator);
        defer service_header.deinit();
        try service_header.appendSlice("# service=");
        try service_header.appendSlice(service_name);
        try service_header.appendSlice("\n");

        // Format as git packet
        const header_packet = try self.formatPacket(service_header.items);
        defer self.allocator.free(header_packet);
        try output.appendSlice(header_packet);

        // Add flush packet
        try output.appendSlice("0000");

        // Write refs with capabilities on first ref
        var first_ref = true;
        for (ref_list.entries) |ref| {
            var ref_line = std.ArrayList(u8).init(self.allocator);
            defer ref_line.deinit();

            try ref_line.appendSlice(&ref.hash);
            try ref_line.appendSlice(" ");
            try ref_line.appendSlice(ref.name);

            if (first_ref) {
                try ref_line.appendSlice("\x00");
                try ref_line.appendSlice(capabilities.items);
                first_ref = false;
            }

            try ref_line.appendSlice("\n");

            const ref_packet = try self.formatPacket(ref_line.items);
            defer self.allocator.free(ref_packet);
            try output.appendSlice(ref_packet);
        }

        // Add final flush packet
        try output.appendSlice("0000");

        // Stream output via host callback
        host_emit_bytes(output.items.ptr, @intCast(output.items.len));
    }

    /// Process git-upload-pack request (fetch/clone).
    pub fn serveUploadPack(self: *WasmGitServer, request: []const u8) !void {
        // Create a git server instance using our storage
        var git_server = git_serve.GitServer.init(self.allocator);
        defer git_server.deinit();

        // Parse the request and generate pack data
        // For now, emit a simple response
        const response = "0000"; // Empty pack for minimal implementation
        host_emit_bytes(response.ptr, @intCast(response.len));
    }

    /// Process git-receive-pack request (push).
    pub fn serveReceivePack(self: *WasmGitServer, request: []const u8) !void {
        _ = self;
        _ = request;
        // Minimal implementation - just acknowledge
        const response = "0000";
        host_emit_bytes(response.ptr, @intCast(response.len));
    }

    /// Process protocol v2 command.
    pub fn serveV2Command(self: *WasmGitServer, request: []const u8) !void {
        _ = self;
        _ = request;
        // Minimal implementation for v2 protocol
        const response = "0000";
        host_emit_bytes(response.ptr, @intCast(response.len));
    }

    /// Format data as a git packet with length prefix.
    fn formatPacket(self: *WasmGitServer, data: []const u8) ![]u8 {
        const packet_len = data.len + 4; // 4 bytes for length prefix
        var result = try self.allocator.alloc(u8, packet_len + 4);
        
        // Format length as 4-digit hex
        _ = try std.fmt.bufPrint(result[0..4], "{:0>4x}", .{packet_len});
        
        // Copy data
        @memcpy(result[4..], data);
        
        return result;
    }
};
