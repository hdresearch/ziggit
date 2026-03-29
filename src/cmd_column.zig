// Auto-generated from main_common.zig - cmd_column
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

// Re-export commonly used types from helpers
const objects = helpers.objects;
const index_mod = helpers.index_mod;
const refs = helpers.refs;
const tree_mod = helpers.tree_mod;
const gitignore_mod = helpers.gitignore_mod;
const config_mod = helpers.config_mod;
const config_helpers_mod = helpers.config_helpers_mod;
const diff_mod = helpers.diff_mod;
const diff_stats_mod = helpers.diff_stats_mod;
const network = helpers.network;
const zlib_compat_mod = helpers.zlib_compat_mod;
const build_options = @import("build_options");
const version_mod = @import("version.zig");
const wildmatch_mod = @import("wildmatch.zig");

pub fn nativeCmdColumn(_: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    // git column formats stdin into columns
    const allocator = std.heap.page_allocator;
    var mode: []const u8 = "always";
    var width: u32 = if (std.process.getEnvVarOwned(allocator, "COLUMNS")) |cols_str| blk: {
        defer allocator.free(cols_str);
        break :blk std.fmt.parseInt(u32, cols_str, 10) catch 80;
    } else |_| 80;
    var padding: u32 = 1;
    var indent: []const u8 = "";
    var nl: []const u8 = "\n";
    
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--mode=")) {
            mode = arg["--mode=".len..];
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            width = std.fmt.parseInt(u32, arg["--width=".len..], 10) catch 80;
        } else if (std.mem.startsWith(u8, arg, "--padding=")) {
            const pad_str = arg["--padding=".len..];
            if (pad_str.len > 0 and pad_str[0] == '-') {
                try platform_impl.writeStdout("fatal: --padding must be non-negative\n");
                std.process.exit(128);
            }
            padding = std.fmt.parseInt(u32, pad_str, 10) catch 1;
        } else if (std.mem.eql(u8, arg, "--padding")) {
            if (args.next()) |next| {
                if (next.len > 0 and next[0] == '-') {
                    try platform_impl.writeStdout("fatal: --padding must be non-negative\n");
                    std.process.exit(128);
                }
                padding = std.fmt.parseInt(u32, next, 10) catch 1;
            }
        } else if (std.mem.startsWith(u8, arg, "--indent=")) {
            indent = arg["--indent=".len..];
        } else if (std.mem.eql(u8, arg, "--indent")) {
            if (args.next()) |next| indent = next;
        } else if (std.mem.startsWith(u8, arg, "--nl=")) {
            nl = arg["--nl=".len..];
        } else if (std.mem.eql(u8, arg, "--raw-mode")) {
            // Ignore
        }
    }
    
    if (std.mem.eql(u8, mode, "never")) {
        // Pass through without formatting
        const data = helpers.readStdin(allocator, 10 * 1024 * 1024) catch return;
        defer allocator.free(data);
        try platform_impl.writeStdout(data);
        return;
    }
    
    if (std.mem.eql(u8, mode, "plain")) {
        // Each line gets indent prefix and nl suffix
        const data = helpers.readStdin(allocator, 10 * 1024 * 1024) catch return;
        defer allocator.free(data);
        var line_it = std.mem.splitScalar(u8, data, '\n');
        while (line_it.next()) |line| {
            if (line.len == 0) continue;
            try platform_impl.writeStdout(indent);
            try platform_impl.writeStdout(line);
            try platform_impl.writeStdout(nl);
        }
        return;
    }
    
    // helpers.Read all lines from stdin
    const data = helpers.readStdin(allocator, 10 * 1024 * 1024) catch return;
    defer allocator.free(data);
    
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();
    var max_len: u32 = 0;
    
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0 and lines.items.len > 0) continue;
        if (line.len > 0) {
            try lines.append(line);
            if (line.len > max_len) max_len = @intCast(line.len);
        }
    }
    
    if (lines.items.len == 0) return;
    
    const dense = std.mem.indexOf(u8, mode, "dense") != null and std.mem.indexOf(u8, mode, "nodense") == null;
    const row_first = std.mem.indexOf(u8, mode, "row") != null;
    const effective_width = if (width > @as(u32, @intCast(indent.len))) width - @as(u32, @intCast(indent.len)) else width;

    if (dense) {
        // Dense mode: find the maximum number of columns that fit, using per-column widths
        // helpers.Try from max possible columns down to 1
        const max_possible_cols = @max(1, effective_width / 2); // minimum 2 chars per col
        var best_cols: usize = 1;
        var best_rows: usize = lines.items.len;
        // helpers.Store per-column widths for best layout
        var best_col_widths: [256]u32 = undefined;
        best_col_widths[0] = max_len + padding;

        var try_cols: usize = if (max_possible_cols > 256) 256 else max_possible_cols;
        while (try_cols > 1) : (try_cols -= 1) {
            const try_rows = (lines.items.len + try_cols - 1) / try_cols;
            // helpers.Compute per-column widths
            var col_widths: [256]u32 = undefined;
            var total_w: u32 = 0;
            var fits = true;
            var c: usize = 0;
            while (c < try_cols) : (c += 1) {
                var cw: u32 = 0;
                var r: usize = 0;
                while (r < try_rows) : (r += 1) {
                    const idx = if (row_first) r * try_cols + c else c * try_rows + r;
                    if (idx < lines.items.len) {
                        const l: u32 = @intCast(lines.items[idx].len);
                        if (l > cw) cw = l;
                    }
                }
                col_widths[c] = if (c + 1 < try_cols) cw + padding else cw;
                total_w += col_widths[c];
                if (total_w > effective_width) {
                    fits = false;
                    break;
                }
            }
            if (fits) {
                best_cols = try_cols;
                best_rows = try_rows;
                @memcpy(best_col_widths[0..try_cols], col_widths[0..try_cols]);
                break;
            }
        }

        if (row_first) {
            var i: usize = 0;
            while (i < lines.items.len) {
                if (indent.len > 0) try platform_impl.writeStdout(indent);
                var col: usize = 0;
                while (col < best_cols and i + col < lines.items.len) : (col += 1) {
                    try platform_impl.writeStdout(lines.items[i + col]);
                    if (col + 1 < best_cols and i + col + 1 < lines.items.len) {
                        var p: usize = lines.items[i + col].len;
                        while (p < best_col_widths[col]) : (p += 1) {
                            try platform_impl.writeStdout(" ");
                        }
                    }
                }
                try platform_impl.writeStdout("\n");
                i += best_cols;
            }
        } else {
            var row: usize = 0;
            while (row < best_rows) : (row += 1) {
                if (indent.len > 0) try platform_impl.writeStdout(indent);
                var col: usize = 0;
                while (col < best_cols) : (col += 1) {
                    const idx = col * best_rows + row;
                    if (idx >= lines.items.len) break;
                    try platform_impl.writeStdout(lines.items[idx]);
                    const next_idx = (col + 1) * best_rows + row;
                    if (col + 1 < best_cols and next_idx < lines.items.len) {
                        var p: usize = lines.items[idx].len;
                        while (p < best_col_widths[col]) : (p += 1) {
                            try platform_impl.writeStdout(" ");
                        }
                    }
                }
                try platform_impl.writeStdout("\n");
            }
        }
    } else {
        // Non-dense: uniform column widths
        const col_width = max_len + padding;
        const num_cols = if (col_width > 0) @max(1, effective_width / col_width) else 1;
        const num_rows = (lines.items.len + num_cols - 1) / num_cols;

        if (row_first) {
            // Row-first layout
            var i: usize = 0;
            while (i < lines.items.len) {
                if (indent.len > 0) try platform_impl.writeStdout(indent);
                var col: usize = 0;
                while (col < num_cols and i + col < lines.items.len) : (col += 1) {
                    try platform_impl.writeStdout(lines.items[i + col]);
                    // helpers.Pad unless last item on line
                    if (col + 1 < num_cols and i + col + 1 < lines.items.len) {
                        var pad_c: usize = lines.items[i + col].len;
                        while (pad_c < col_width) : (pad_c += 1) {
                            try platform_impl.writeStdout(" ");
                        }
                    }
                }
                try platform_impl.writeStdout("\n");
                i += num_cols;
            }
        } else {
            // Column-first layout (default)
            var row: usize = 0;
            while (row < num_rows) : (row += 1) {
                if (indent.len > 0) try platform_impl.writeStdout(indent);
                var col: usize = 0;
                while (col < num_cols) : (col += 1) {
                    const idx = col * num_rows + row;
                    if (idx >= lines.items.len) break;
                    try platform_impl.writeStdout(lines.items[idx]);
                    // helpers.Pad to col_width unless it's the last item on the line
                    const next_idx = (col + 1) * num_rows + row;
                    if (col + 1 < num_cols and next_idx < lines.items.len) {
                        var pad_amt: usize = lines.items[idx].len;
                        while (pad_amt < col_width) : (pad_amt += 1) {
                            try platform_impl.writeStdout(" ");
                        }
                    }
                }
                try platform_impl.writeStdout("\n");
            }
        }
    }
}
