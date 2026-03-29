// Auto-generated from main_common.zig - cmd_update_ref
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_reflog = @import("cmd_reflog.zig");
const cmd_gc = @import("cmd_gc.zig");

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

pub fn cmdUpdateRef(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var delete_mode = false;
    var no_deref = false;
    var create_reflog = false;
    var stdin_mode = false;
    var msg: ?[]const u8 = null;
    var positional = std.ArrayList([]const u8).init(allocator);
    defer positional.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d")) {
            delete_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-deref")) {
            no_deref = true;
        } else if (std.mem.eql(u8, arg, "--create-reflog")) {
            create_reflog = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            msg = args.next();
        } else if (std.mem.eql(u8, arg, "--")) {
            // rest are positional
            while (args.next()) |rest| try positional.append(rest);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positional.append(arg);
        }
    }

    const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    if (stdin_mode) {
        try updateRefStdin(git_dir, create_reflog, no_deref, allocator, platform_impl);
        return;
    }

    if (delete_mode) {
        if (positional.items.len < 1) {
            try platform_impl.writeStderr("usage: git update-ref -d <refname> [<old-val>]\n");
            std.process.exit(128);
            unreachable;
        }
        const ref_name = positional.items[0];
        // helpers.If old-value was specified, verify it matches current value
        if (positional.items.len >= 2) {
            const old_val = positional.items[1];
            if (old_val.len > 0) {
                const current = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
                defer if (current) |c| allocator.free(c);
                if (current) |cur| {
                    if (!std.mem.eql(u8, cur, old_val)) {
                        const err_msg = try std.fmt.allocPrint(allocator, "error: cannot lock ref '{s}': is at {s} but expected {s}\n", .{ ref_name, cur, old_val });
                        defer allocator.free(err_msg);
                        try platform_impl.writeStderr(err_msg);
                        std.process.exit(1);
                        unreachable;
                    }
                }
            }
        }
        
        // helpers.Delete loose ref file
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
        defer allocator.free(ref_path);
        std.fs.cwd().deleteFile(ref_path) catch |err| {
            if (err != error.FileNotFound) {
                const err_msg = try std.fmt.allocPrint(allocator, "fatal: cannot delete ref '{s}': {}\n", .{ ref_name, err });
                defer allocator.free(err_msg);
                try platform_impl.writeStderr(err_msg);
                std.process.exit(1);
                unreachable;
            }
        };
        // (loose ref deletion handled above)
        
        // helpers.Also remove from packed-helpers.refs if present
        const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
        defer allocator.free(packed_refs_path);
        if (platform_impl.fs.readFile(allocator, packed_refs_path)) |packed_data| {
            defer allocator.free(packed_data);
            var new_packed = std.ArrayList(u8).init(allocator);
            defer new_packed.deinit();
            var lines_iter = std.mem.splitScalar(u8, packed_data, '\n');
            while (lines_iter.next()) |line| {
                if (line.len == 0) continue;
                if (line[0] == '#') {
                    try new_packed.appendSlice(line);
                    try new_packed.append('\n');
                    continue;
                }
                if (line[0] == '^') {
                    // Peeled ref - skip if previous ref was deleted
                    continue;
                }
                // helpers.Check if this line references our ref
                if (line.len > 41) {
                    const line_ref = std.mem.trimRight(u8, line[41..], " \t\r");
                    if (std.mem.eql(u8, line_ref, ref_name)) {
                        continue; // skip this ref
                    }
                }
                try new_packed.appendSlice(line);
                try new_packed.append('\n');
            }
            platform_impl.fs.writeFile(packed_refs_path, new_packed.items) catch {};
        } else |_| {}
        
        // helpers.Try to clean up empty parent dirs
        cmd_gc.cleanEmptyRefDirs(git_dir, ref_name, allocator);
        return;
    }

    if (positional.items.len < 2) {
        try platform_impl.writeStderr("usage: git update-ref [-d] [-m <reason>] <refname> <new-value> [<old-value>]\n");
        std.process.exit(128);
        unreachable;
    }

    const ref_name = positional.items[0];
    const new_value = positional.items[1];

    // helpers.Resolve new_value to a full hash
    var resolved_new: []const u8 = undefined;
    var free_resolved = false;
    if (new_value.len == 40 and helpers.isValidHashPrefix(new_value)) {
        resolved_new = new_value;
    } else {
        resolved_new = helpers.resolveCommittish(git_dir, new_value, platform_impl, allocator) catch {
            const err_msg = try std.fmt.allocPrint(allocator, "fatal: {s}: not a valid SHA1\n", .{new_value});
            defer allocator.free(err_msg);
            try platform_impl.writeStderr(err_msg);
            std.process.exit(128);
            unreachable;
        };
        free_resolved = true;
    }
    defer if (free_resolved) allocator.free(resolved_new);

    // Old value verification
    if (positional.items.len >= 3) {
        const old_val = positional.items[2];
        if (old_val.len > 0 and !std.mem.eql(u8, old_val, "0000000000000000000000000000000000000000")) {
            const current = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
            defer if (current) |c| allocator.free(c);
            if (current) |cur| {
                if (!std.mem.eql(u8, cur, old_val)) {
                    const err_msg2 = try std.fmt.allocPrint(allocator, "error: cannot lock ref '{s}': is at {s} but expected {s}\n", .{ ref_name, cur, old_val });
                    defer allocator.free(err_msg2);
                    try platform_impl.writeStderr(err_msg2);
                    std.process.exit(1);
                    unreachable;
                }
            } else {
                // Ref doesn't exist but old value was specified
                const err_msg2 = try std.fmt.allocPrint(allocator, "error: cannot lock ref '{s}': unable to resolve reference '{s}'\n", .{ ref_name, ref_name });
                defer allocator.free(err_msg2);
                try platform_impl.writeStderr(err_msg2);
                std.process.exit(1);
                unreachable;
            }
        }
    }

    // helpers.Get old value for reflog
    const old_hash = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
    defer if (old_hash) |h| allocator.free(h);

    // helpers.Write the ref
    try refs.updateRef(git_dir, ref_name, resolved_new, platform_impl, allocator);
    
    // helpers.Create reflog dir and write entry if needed
    if (create_reflog or cmd_reflog.shouldLogRef(git_dir, ref_name, platform_impl, allocator)) {
        helpers.writeReflogEntry(git_dir, ref_name, old_hash orelse "0000000000000000000000000000000000000000", resolved_new, msg orelse "", allocator, platform_impl) catch {};
    }

}


pub fn updateRefStdin(git_dir: []const u8, create_reflog: bool, no_deref: bool, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    _ = no_deref;
    const stdin_data = helpers.readStdin(allocator, 10 * 1024 * 1024) catch {
        try platform_impl.writeStderr("fatal: unable to read from stdin\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(stdin_data);
    
    const zero_hash = "0000000000000000000000000000000000000000";
    
    var lines = std.mem.splitScalar(u8, stdin_data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        
        if (std.mem.startsWith(u8, trimmed, "update ")) {
            // update <ref> <new-oid> [<old-oid>]
            const rest = trimmed["update ".len..];
            var parts = std.mem.splitScalar(u8, rest, ' ');
            const ref_name = parts.next() orelse continue;
            const new_val_raw = parts.next() orelse continue;
            const old_val = parts.next();
            
            // helpers.Resolve new value
            const new_val = if (new_val_raw.len == 40 and helpers.isValidHexString(new_val_raw))
                try allocator.dupe(u8, new_val_raw)
            else
                helpers.resolveRevision(git_dir, new_val_raw, platform_impl, allocator) catch {
                    const emsg = try std.fmt.allocPrint(allocator, "fatal: {s}: not a valid SHA1\n", .{ref_name});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    std.process.exit(128);
                    unreachable;
                };
            defer allocator.free(new_val);
            
            // helpers.Verify old value if specified
            if (old_val) |ov| {
                if (ov.len > 0) {
                    const resolved_old = if (ov.len == 40 and helpers.isValidHexString(ov))
                        try allocator.dupe(u8, ov)
                    else
                        helpers.resolveRevision(git_dir, ov, platform_impl, allocator) catch {
                            const emsg = try std.fmt.allocPrint(allocator, "fatal: cannot lock ref '{s}': unable to resolve reference\n", .{ref_name});
                            defer allocator.free(emsg);
                            try platform_impl.writeStderr(emsg);
                            std.process.exit(128);
                            unreachable;
                        };
                    defer allocator.free(resolved_old);
                    
                    const current = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
                    defer if (current) |c| allocator.free(c);
                    
                    if (std.mem.eql(u8, resolved_old, zero_hash)) {
                        // old=0 means ref must not exist
                        if (current != null) {
                            const emsg = try std.fmt.allocPrint(allocator, "fatal: cannot lock ref '{s}': reference already exists\n", .{ref_name});
                            defer allocator.free(emsg);
                            try platform_impl.writeStderr(emsg);
                            std.process.exit(128);
                            unreachable;
                        }
                    } else {
                        if (current == null or !std.mem.eql(u8, current.?, resolved_old)) {
                            const emsg = try std.fmt.allocPrint(allocator, "fatal: cannot lock ref '{s}': is at {s} but expected {s}\n", .{ ref_name, current orelse zero_hash, resolved_old });
                            defer allocator.free(emsg);
                            try platform_impl.writeStderr(emsg);
                            std.process.exit(128);
                            unreachable;
                        }
                    }
                }
            }
            
            const old_hash = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
            defer if (old_hash) |h| allocator.free(h);
            
            try refs.updateRef(git_dir, ref_name, new_val, platform_impl, allocator);
            
            if (create_reflog or cmd_reflog.shouldLogRef(git_dir, ref_name, platform_impl, allocator)) {
                helpers.writeReflogEntry(git_dir, ref_name, old_hash orelse zero_hash, new_val, "", allocator, platform_impl) catch {};
            }
        } else if (std.mem.startsWith(u8, trimmed, "create ")) {
            // create <ref> <new-oid>
            const rest = trimmed["create ".len..];
            var parts = std.mem.splitScalar(u8, rest, ' ');
            const ref_name = parts.next() orelse continue;
            const new_val_raw = parts.next() orelse continue;
            
            // Ref must not exist
            if (refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null) |existing| {
                allocator.free(existing);
                const emsg = try std.fmt.allocPrint(allocator, "fatal: cannot lock ref '{s}': reference already exists\n", .{ref_name});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(128);
                unreachable;
            }
            
            const new_val = if (new_val_raw.len == 40 and helpers.isValidHexString(new_val_raw))
                try allocator.dupe(u8, new_val_raw)
            else
                helpers.resolveRevision(git_dir, new_val_raw, platform_impl, allocator) catch {
                    const emsg = try std.fmt.allocPrint(allocator, "fatal: {s}: not a valid SHA1\n", .{ref_name});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    std.process.exit(128);
                    unreachable;
                };
            defer allocator.free(new_val);
            
            try refs.updateRef(git_dir, ref_name, new_val, platform_impl, allocator);
            
            if (create_reflog or cmd_reflog.shouldLogRef(git_dir, ref_name, platform_impl, allocator)) {
                helpers.writeReflogEntry(git_dir, ref_name, zero_hash, new_val, "", allocator, platform_impl) catch {};
            }
        } else if (std.mem.startsWith(u8, trimmed, "delete ")) {
            // delete <ref> [<old-oid>]
            const rest = trimmed["delete ".len..];
            var parts = std.mem.splitScalar(u8, rest, ' ');
            const ref_name = parts.next() orelse continue;
            const old_val = parts.next();
            
            // helpers.Verify old value if specified
            if (old_val) |ov| {
                if (ov.len > 0 and !std.mem.eql(u8, ov, zero_hash)) {
                    const current = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
                    defer if (current) |c| allocator.free(c);
                    
                    const resolved_old = if (ov.len == 40 and helpers.isValidHexString(ov))
                        try allocator.dupe(u8, ov)
                    else
                        helpers.resolveRevision(git_dir, ov, platform_impl, allocator) catch {
                            try platform_impl.writeStderr("fatal: cannot resolve old value\n");
                            std.process.exit(128);
                            unreachable;
                        };
                    defer allocator.free(resolved_old);
                    
                    if (current == null or !std.mem.eql(u8, current.?, resolved_old)) {
                        const emsg = try std.fmt.allocPrint(allocator, "fatal: cannot lock ref '{s}'\n", .{ref_name});
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        std.process.exit(128);
                        unreachable;
                    }
                }
            }
            
            // helpers.Delete the ref
            const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
            defer allocator.free(ref_path);
            std.fs.cwd().deleteFile(ref_path) catch {};
            
            // helpers.Remove from packed-helpers.refs too
            helpers.removeFromPackedRefs(git_dir, ref_name, allocator, platform_impl);
            cmd_gc.cleanEmptyRefDirs(git_dir, ref_name, allocator);
        } else if (std.mem.startsWith(u8, trimmed, "verify ")) {
            // verify <ref> [<old-oid>]
            const rest = trimmed["verify ".len..];
            var parts = std.mem.splitScalar(u8, rest, ' ');
            const ref_name = parts.next() orelse continue;
            const expected = parts.next();
            
            const current = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
            defer if (current) |c| allocator.free(c);
            
            if (expected) |exp| {
                if (std.mem.eql(u8, exp, zero_hash)) {
                    if (current != null) {
                        const emsg = try std.fmt.allocPrint(allocator, "fatal: cannot lock ref '{s}': reference exists\n", .{ref_name});
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        std.process.exit(128);
                        unreachable;
                    }
                } else {
                    if (current == null or !std.mem.eql(u8, current.?, exp)) {
                        const emsg = try std.fmt.allocPrint(allocator, "fatal: cannot lock ref '{s}': is at {s} but expected {s}\n", .{ ref_name, current orelse zero_hash, exp });
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        std.process.exit(128);
                        unreachable;
                    }
                }
            }
        }
    }
}
