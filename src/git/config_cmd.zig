const std = @import("std");
const platform_mod = @import("../platform/platform.zig");
const main_mod = @import("../main_common.zig");

const Allocator = std.mem.Allocator;

// Re-export types from main_common
const ConfigOverride = struct { key: []const u8, value: []const u8 };

// Our own override struct that tracks has_equals for proper boolean handling
const CfgOverride = struct {
    key: []const u8,
    value: []const u8,
    has_equals: bool, // true if '=' was explicitly present (even with empty value)
    source: []const u8, // "command" for -c, "environment" for --config-env
};

const BuildOverridesError = error{ BogusConfigParameters, OutOfMemory };

fn buildConfigOverrides(allocator: Allocator) BuildOverridesError!std.array_list.Managed(CfgOverride) {
    var overrides = std.array_list.Managed(CfgOverride).init(allocator);
    errdefer {
        for (overrides.items) |item| {
            allocator.free(item.key);
            allocator.free(item.value);
        }
        overrides.deinit();
    }

    // First, figure out how many GIT_CONFIG_PARAMETERS entries there are
    // so we can skip them in main_mod's overrides (which includes both -c and GIT_CONFIG_PARAMETERS)
    var gcp_count: usize = 0;
    {
        const params_str = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_PARAMETERS") catch null;
        if (params_str) |params| {
            defer allocator.free(params);
            var temp = std.array_list.Managed(CfgOverride).init(allocator);
            defer {
                for (temp.items) |item| {
                    allocator.free(item.key);
                    allocator.free(item.value);
                }
                temp.deinit();
            }
            parseGitConfigParams(params, &temp, allocator) catch |e| {
                if (e == error.BogusConfigParameters) return error.BogusConfigParameters;
                return error.OutOfMemory;
            };
            gcp_count = temp.items.len;
        }
    }

    // Add -c overrides from main_mod (all except the last gcp_count entries)
    if (main_mod.global_config_overrides) |mo_overrides| {
        const total = mo_overrides.items.len;
        const c_count = if (total >= gcp_count) total - gcp_count else 0;
        for (mo_overrides.items[0..c_count]) |ov| {
            const key_dup = try allocator.dupe(u8, ov.key);
            const val_dup = try allocator.dupe(u8, ov.value);
            try overrides.append(.{ .key = key_dup, .value = val_dup, .has_equals = true, .source = "command" });
        }
    }

    // Handle --config-env from command line args (read from /proc/self/cmdline)
    {
        const cmdline = std.fs.cwd().readFileAlloc(allocator, "/proc/self/cmdline", 1024 * 1024) catch null;
        if (cmdline) |cl| {
            defer allocator.free(cl);
            var arg_iter = std.mem.splitScalar(u8, cl, 0);
            var prev_was_config_env = false;
            while (arg_iter.next()) |arg| {
                if (arg.len == 0) continue;
                if (prev_was_config_env) {
                    prev_was_config_env = false;
                    // arg is "key=ENVVAR"
                    processConfigEnvArg(arg, &overrides, allocator) catch continue;
                } else if (std.mem.startsWith(u8, arg, "--config-env=")) {
                    const rest = arg["--config-env=".len..];
                    processConfigEnvArg(rest, &overrides, allocator) catch continue;
                } else if (std.mem.eql(u8, arg, "--config-env")) {
                    prev_was_config_env = true;
                }
            }
        }
    }

    // Now add our properly parsed GIT_CONFIG_PARAMETERS entries
    {
        const params2 = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_PARAMETERS") catch null;
        if (params2) |params| {
            defer allocator.free(params);
            parseGitConfigParams(params, &overrides, allocator) catch |e| {
                if (e == error.BogusConfigParameters) return error.BogusConfigParameters;
                return error.OutOfMemory;
            };
        }
    }

    // GIT_CONFIG_COUNT/KEY_N/VALUE_N are already included from main_mod's overrides
    // (they're processed first in zigzitMain, before -c and GIT_CONFIG_PARAMETERS)
    // We need to mark the first entries from main_mod that came from GIT_CONFIG_COUNT
    // with the "environment" source instead of "command"
    {
        const count_str = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_COUNT") catch null;
        if (count_str) |cs| {
            defer allocator.free(cs);
            const count = std.fmt.parseInt(usize, cs, 10) catch 0;
            // The first 'count' entries from main_mod are GIT_CONFIG_COUNT entries
            for (overrides.items[0..@min(count, overrides.items.len)]) |*ov| {
                ov.source = "environment";
            }
        }
    }

    return overrides;
}

fn parseGitConfigParams(params: []const u8, overrides: *std.array_list.Managed(CfgOverride), allocator: Allocator) !void {
    var i: usize = 0;
    var key_buf = std.array_list.Managed(u8).init(allocator);
    defer key_buf.deinit();
    var val_buf = std.array_list.Managed(u8).init(allocator);
    defer val_buf.deinit();

    while (i < params.len) {
        // Skip whitespace
        while (i < params.len and (params[i] == ' ' or params[i] == '\t')) i += 1;
        if (i >= params.len) break;

        if (params[i] == '\'') {
            const after_first = gcpExtract(params, i, &key_buf) orelse break;
            i = after_first;

            // Check if followed by = (new-style: 'key'='value' or 'key'=)
            if (i < params.len and params[i] == '=') {
                i += 1; // skip =
                if (i < params.len and params[i] == '\'') {
                    const after_val = gcpExtract(params, i, &val_buf) orelse break;
                    i = after_val;
                    // After closing quote, must be whitespace or end
                    if (i < params.len and params[i] != ' ' and params[i] != '\t') return error.BogusConfigParameters;
                    // New-style with quoted value
                    const key_dup = try normalizeConfigKey(allocator, key_buf.items);
                    const val_dup = try allocator.dupe(u8, val_buf.items);
                    try overrides.append(.{ .key = key_dup, .value = val_dup, .has_equals = true, .source = "command" });
                } else {
                    // New-style: 'key'= with no quoted value (empty value)
                    // Read unquoted value until whitespace
                    const vs = i;
                    while (i < params.len and params[i] != ' ' and params[i] != '\t') i += 1;
                    const key_dup = try normalizeConfigKey(allocator, key_buf.items);
                    const val_dup = try allocator.dupe(u8, params[vs..i]);
                    try overrides.append(.{ .key = key_dup, .value = val_dup, .has_equals = true, .source = "command" });
                }
            } else if (i >= params.len or params[i] == ' ' or params[i] == '\t') {
                // Old-style: 'key=value' all in one quoted string
                const content = key_buf.items;
                if (std.mem.indexOfScalar(u8, content, '=')) |eq| {
                    const key_dup = try normalizeConfigKey(allocator, content[0..eq]);
                    const val_dup = try allocator.dupe(u8, content[eq + 1 ..]);
                    try overrides.append(.{ .key = key_dup, .value = val_dup, .has_equals = true, .source = "command" });
                } else {
                    // No = means boolean true
                    const key_dup = try normalizeConfigKey(allocator, content);
                    const val_dup = try allocator.dupe(u8, "");
                    try overrides.append(.{ .key = key_dup, .value = val_dup, .has_equals = false, .source = "command" });
                }
            } else {
                // Invalid character after closing quote (e.g., backslash) - bogus
                return error.BogusConfigParameters;
            }
        } else {
            const start2 = i;
            while (i < params.len and params[i] != ' ' and params[i] != '\t') i += 1;
            const entry = params[start2..i];
            if (entry.len > 0) {
                if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                    const key_dup = try normalizeConfigKey(allocator, entry[0..eq]);
                    const val_dup = try allocator.dupe(u8, entry[eq + 1 ..]);
                    try overrides.append(.{ .key = key_dup, .value = val_dup, .has_equals = true, .source = "command" });
                } else {
                    const key_dup = try normalizeConfigKey(allocator, entry);
                    const val_dup = try allocator.dupe(u8, "");
                    try overrides.append(.{ .key = key_dup, .value = val_dup, .has_equals = false, .source = "command" });
                }
            }
        }
    }
}

fn gcpExtract(params: []const u8, start: usize, buf: *std.array_list.Managed(u8)) ?usize {
    var i = start;
    if (i >= params.len or params[i] != '\'') return null;
    i += 1;
    buf.clearRetainingCapacity();
    while (i < params.len) {
        if (params[i] == '\'') {
            // Check for '\'' escape (shell-style: end quote, escaped quote, start quote)
            if (i + 3 < params.len and params[i + 1] == '\\' and params[i + 2] == '\'' and params[i + 3] == '\'') {
                buf.append('\'') catch return null;
                i += 4;
                continue;
            }
            // Just a closing quote
            i += 1;
            return i;
        }
        buf.append(params[i]) catch return null;
        i += 1;
    }
    return null; // unterminated
}

fn processConfigEnvArg(arg: []const u8, overrides: *std.array_list.Managed(CfgOverride), allocator: Allocator) !void {
    // arg is "key=ENVVAR" - find the first = to split key from env var name
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return;
    const key_raw = arg[0..eq];
    const envvar_name = arg[eq + 1 ..];
    if (key_raw.len == 0) return;
    if (envvar_name.len == 0) return;
    // Look up the environment variable
    const val = std.process.getEnvVarOwned(allocator, envvar_name) catch |e| {
        if (e == error.EnvironmentVariableNotFound) return;
        return error.OutOfMemory;
    };
    const key_dup = try normalizeConfigKey(allocator, key_raw);
    try overrides.append(.{ .key = key_dup, .value = val, .has_equals = true, .source = "command" });
}

fn normalizeConfigKey(allocator: Allocator, key: []const u8) ![]u8 {
    var result = try allocator.dupe(u8, key);
    // Normalize: lowercase section and variable parts, preserve subsection
    if (std.mem.lastIndexOfScalar(u8, result, '.')) |last_dot| {
        if (std.mem.indexOfScalar(u8, result, '.')) |first_dot| {
            // Lowercase section (before first dot)
            for (result[0..first_dot]) |*c| c.* = std.ascii.toLower(c.*);
            // Lowercase variable (after last dot)
            for (result[last_dot + 1 ..]) |*c| c.* = std.ascii.toLower(c.*);
        }
    }
    return result;
}

pub const ConfigType = enum { none, bool_type, int_type, bool_or_int, path_type, expiry_date, color_type };

pub const ConfigSource = struct {
    path: []const u8,
    scope: []const u8,
    needs_free: bool,
};

pub const CfgEntry = struct {
    full_key: []u8,
    value: []u8,
    has_equals: bool,
    line_number: usize = 0,
    source_path: ?[]const u8 = null,
    source_scope: ?[]const u8 = null,
    fn deinit(self: *CfgEntry, alloc: Allocator) void {
        alloc.free(self.full_key);
        alloc.free(self.value);
        if (self.source_path) |sp| alloc.free(sp);
        if (self.source_scope) |ss| alloc.free(ss);
    }
};

const CfgParsedKey = struct { section: []u8, subsection: ?[]u8, variable: []u8 };

const CfgAction = enum {
    none,
    get,
    get_all,
    get_regexp,
    set,
    replace_all,
    add,
    unset,
    unset_all,
    list,
    rename_section,
    remove_section,
    edit,
    get_color,
    get_colorbool,
    get_urlmatch,
};

fn readStdin(allocator: Allocator, max_size: usize) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    const f = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch break;
        if (n == 0) break;
        try result.appendSlice(buf[0..n]);
        if (result.items.len > max_size) return error.StreamTooLong;
    }
    return result.toOwnedSlice();
}

pub fn run(allocator: Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    // Collect all remaining args
    var config_args = std.array_list.Managed([]const u8).init(allocator);
    defer config_args.deinit();
    while (args.next()) |arg| {
        try config_args.append(arg);
    }

    var action: CfgAction = .none;
    var config_type: ConfigType = .none;
    var type_count: u32 = 0;
    var config_comment: ?[]const u8 = null;
    var use_global = false;
    var use_system = false;
    var use_local = false;
    var use_worktree = false;
    var config_file: ?[]const u8 = null;
    var null_terminator = false;
    var show_names = false;
    var show_origin = false;
    var show_scope = false;
    var default_value: ?[]const u8 = null;
    var fixed_value = false;
    var sub_value_pattern: ?[]const u8 = null;
    var positionals = std.array_list.Managed([]const u8).init(allocator);
    defer positionals.deinit();
    var new_style_sub = false;
    var do_all = false;
    var action_name: ?[]const u8 = null;
    var blob_ref: ?[]const u8 = null;
    var url_match: ?[]const u8 = null;
    var includes_flag = false;

    var i: usize = 0;
    while (i < config_args.items.len) : (i += 1) {
        const arg = config_args.items[i];
        if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            if (action != .none and action != .list) {
                const em = try std.fmt.allocPrint(allocator, "error: options '--list' and '{s}' cannot be used together\n", .{action_name orelse "--unknown"});
                defer allocator.free(em);
                try platform_impl.writeStderr(em);
                std.process.exit(129);
            }
            action = .list;
            action_name = "--list";
        } else if (std.mem.eql(u8, arg, "--get")) {
            if (action != .none and action != .get) {
                const em = try std.fmt.allocPrint(allocator, "error: options '--get' and '{s}' cannot be used together\n", .{action_name orelse "--unknown"});
                defer allocator.free(em);
                try platform_impl.writeStderr(em);
                std.process.exit(129);
            }
            action = .get;
            action_name = "--get";
        } else if (std.mem.eql(u8, arg, "--get-all")) {
            if (action != .none and action != .get_all) {
                const em = try std.fmt.allocPrint(allocator, "error: options '--get-all' and '{s}' cannot be used together\n", .{action_name orelse "--unknown"});
                defer allocator.free(em);
                try platform_impl.writeStderr(em);
                std.process.exit(129);
            }
            action = .get_all;
            action_name = "--get-all";
        } else if (std.mem.eql(u8, arg, "--get-regexp")) {
            if (action != .none and action != .get_regexp) {
                const em = try std.fmt.allocPrint(allocator, "error: options '--get-regexp' and '{s}' cannot be used together\n", .{action_name orelse "--unknown"});
                defer allocator.free(em);
                try platform_impl.writeStderr(em);
                std.process.exit(129);
            }
            action = .get_regexp;
            action_name = "--get-regexp";
        } else if (std.mem.eql(u8, arg, "--unset")) {
            if (action != .none and action != .unset) {
                const em = try std.fmt.allocPrint(allocator, "error: options '--unset' and '{s}' cannot be used together\n", .{action_name orelse "--unknown"});
                defer allocator.free(em);
                try platform_impl.writeStderr(em);
                std.process.exit(129);
            }
            action = .unset;
            action_name = "--unset";
        } else if (std.mem.eql(u8, arg, "--unset-all")) {
            if (action != .none and action != .unset_all) {
                const em = try std.fmt.allocPrint(allocator, "error: options '--unset-all' and '{s}' cannot be used together\n", .{action_name orelse "--unknown"});
                defer allocator.free(em);
                try platform_impl.writeStderr(em);
                std.process.exit(129);
            }
            action = .unset_all;
            action_name = "--unset-all";
        } else if (std.mem.eql(u8, arg, "--add") or std.mem.eql(u8, arg, "--append")) {
            action = .add;
        } else if (std.mem.eql(u8, arg, "--remove-section")) {
            action = .remove_section;
        } else if (std.mem.eql(u8, arg, "--rename-section")) {
            action = .rename_section;
        } else if (std.mem.eql(u8, arg, "--replace-all")) {
            action = .replace_all;
        } else if (std.mem.eql(u8, arg, "--bool")) {
            const new_t: ConfigType = .bool_type;
            if (type_count > 0 and config_type != new_t) {
                try platform_impl.writeStderr("error: only one type at a time\n");
                std.process.exit(129);
            }
            config_type = new_t;
            type_count += 1;
        } else if (std.mem.eql(u8, arg, "--int")) {
            const new_t: ConfigType = .int_type;
            if (type_count > 0 and config_type != new_t) {
                try platform_impl.writeStderr("error: only one type at a time\n");
                std.process.exit(129);
            }
            config_type = new_t;
            type_count += 1;
        } else if (std.mem.eql(u8, arg, "--bool-or-int")) {
            const new_t: ConfigType = .bool_or_int;
            if (type_count > 0 and config_type != new_t) {
                try platform_impl.writeStderr("error: only one type at a time\n");
                std.process.exit(129);
            }
            config_type = new_t;
            type_count += 1;
        } else if (std.mem.eql(u8, arg, "--path")) {
            const new_t: ConfigType = .path_type;
            if (type_count > 0 and config_type != new_t) {
                try platform_impl.writeStderr("error: only one type at a time\n");
                std.process.exit(129);
            }
            config_type = new_t;
            type_count += 1;
        } else if (std.mem.eql(u8, arg, "--expiry-date")) {
            const new_t: ConfigType = .expiry_date;
            if (type_count > 0 and config_type != new_t) {
                try platform_impl.writeStderr("error: only one type at a time\n");
                std.process.exit(129);
            }
            config_type = new_t;
            type_count += 1;
        } else if (std.mem.eql(u8, arg, "--type") or std.mem.startsWith(u8, arg, "--type=")) {
            const type_str = if (std.mem.startsWith(u8, arg, "--type=")) arg["--type=".len..] else blk: {
                i += 1;
                if (i >= config_args.items.len) {
                    try platform_impl.writeStderr("error: --type requires a value\n");
                    std.process.exit(129);
                }
                break :blk config_args.items[i];
            };
            const new_t: ConfigType = if (std.mem.eql(u8, type_str, "bool"))
                .bool_type
            else if (std.mem.eql(u8, type_str, "int"))
                .int_type
            else if (std.mem.eql(u8, type_str, "bool-or-int"))
                .bool_or_int
            else if (std.mem.eql(u8, type_str, "path"))
                .path_type
            else if (std.mem.eql(u8, type_str, "expiry-date"))
                .expiry_date
            else if (std.mem.eql(u8, type_str, "color"))
                .color_type
            else {
                const emsg = try std.fmt.allocPrint(allocator, "error: unrecognized --type argument, {s}\n", .{type_str});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
            };
            if (type_count > 0 and config_type != new_t) {
                try platform_impl.writeStderr("error: only one type at a time\n");
                std.process.exit(129);
            }
            config_type = new_t;
            type_count += 1;
        } else if (std.mem.eql(u8, arg, "--no-type")) {
            config_type = .none;
            type_count = 0;
        } else if (std.mem.eql(u8, arg, "--global")) {
            use_global = true;
        } else if (std.mem.eql(u8, arg, "--system")) {
            use_system = true;
        } else if (std.mem.eql(u8, arg, "--local")) {
            use_local = true;
        } else if (std.mem.eql(u8, arg, "--worktree")) {
            use_worktree = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i < config_args.items.len) config_file = config_args.items[i];
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            config_file = arg["--file=".len..];
        } else if (std.mem.startsWith(u8, arg, "-f") and arg.len > 2) {
            config_file = arg[2..];
        } else if (std.mem.eql(u8, arg, "--blob") or std.mem.startsWith(u8, arg, "--blob=")) {
            if (std.mem.startsWith(u8, arg, "--blob=")) {
                blob_ref = arg["--blob=".len..];
            } else {
                i += 1;
                if (i < config_args.items.len) blob_ref = config_args.items[i];
            }
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--null")) {
            null_terminator = true;
        } else if (std.mem.eql(u8, arg, "--name-only") or std.mem.eql(u8, arg, "--name")) {
            show_names = true;
        } else if (std.mem.eql(u8, arg, "--show-names")) {
            // subcommand mode: show names with values (not name-only)
        } else if (std.mem.eql(u8, arg, "--show-origin")) {
            show_origin = true;
        } else if (std.mem.eql(u8, arg, "--show-scope")) {
            show_scope = true;
        } else if (std.mem.startsWith(u8, arg, "--default=")) {
            default_value = arg["--default=".len..];
        } else if (std.mem.eql(u8, arg, "--default")) {
            i += 1;
            if (i < config_args.items.len) default_value = config_args.items[i];
        } else if (std.mem.eql(u8, arg, "--fixed-value")) {
            fixed_value = true;
        } else if (std.mem.eql(u8, arg, "--edit") or std.mem.eql(u8, arg, "-e")) {
            action = .edit;
        } else if (std.mem.eql(u8, arg, "--get-color")) {
            action = .get_color;
        } else if (std.mem.eql(u8, arg, "--get-colorbool")) {
            action = .get_colorbool;
        } else if (std.mem.startsWith(u8, arg, "--comment=")) {
            config_comment = arg["--comment=".len..];
        } else if (std.mem.eql(u8, arg, "--comment")) {
            i += 1;
            if (i < config_args.items.len) config_comment = config_args.items[i];
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git config [<options>]\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < config_args.items.len) : (i += 1) {
                try positionals.append(config_args.items[i]);
            }
        } else if (std.mem.eql(u8, arg, "--all") and new_style_sub) {
            do_all = true;
        } else if (std.mem.eql(u8, arg, "--get-urlmatch")) {
            action = .get_urlmatch;
            action_name = "--get-urlmatch";
        } else if (std.mem.eql(u8, arg, "--includes")) {
            includes_flag = true;
        } else if (std.mem.eql(u8, arg, "--url") or std.mem.startsWith(u8, arg, "--url=")) {
            if (std.mem.startsWith(u8, arg, "--url=")) {
                url_match = arg["--url=".len..];
            } else {
                i += 1;
                if (i < config_args.items.len) url_match = config_args.items[i];
            }
        } else if (std.mem.eql(u8, arg, "--regexp") and new_style_sub and action == .get) {
            action = .get_regexp;
        } else if ((std.mem.eql(u8, arg, "--value") or std.mem.startsWith(u8, arg, "--value=")) and new_style_sub) {
            if (std.mem.startsWith(u8, arg, "--value=")) {
                sub_value_pattern = arg["--value=".len..];
            } else {
                i += 1;
                if (i < config_args.items.len) sub_value_pattern = config_args.items[i];
            }
        } else if (std.mem.eql(u8, arg, "set") and positionals.items.len == 0 and action == .none) {
            new_style_sub = true;
            action = .set;
        } else if (std.mem.eql(u8, arg, "get") and positionals.items.len == 0 and action == .none) {
            new_style_sub = true;
            action = .get;
        } else if (std.mem.eql(u8, arg, "unset") and positionals.items.len == 0 and action == .none) {
            new_style_sub = true;
            action = .unset;
        } else if (std.mem.eql(u8, arg, "list") and positionals.items.len == 0 and action == .none) {
            new_style_sub = true;
            action = .list;
        } else if (std.mem.eql(u8, arg, "rename-section") and positionals.items.len == 0 and action == .none) {
            new_style_sub = true;
            action = .rename_section;
        } else if (std.mem.eql(u8, arg, "remove-section") and positionals.items.len == 0 and action == .none) {
            new_style_sub = true;
            action = .remove_section;
        } else if (std.mem.eql(u8, arg, "edit") and positionals.items.len == 0 and action == .none) {
            new_style_sub = true;
            action = .edit;
        } else if (std.mem.startsWith(u8, arg, "--no-") and !std.mem.eql(u8, arg, "--no-type")) {
            const em = try std.fmt.allocPrint(allocator, "error: unknown option `{s}'\n", .{arg[2..]});
            defer allocator.free(em);
            try platform_impl.writeStderr(em);
            std.process.exit(129);
        } else {
            try positionals.append(arg);
        }
    }

    // --worktree requires repo
    if (use_worktree) {
        const gpc: ?[]const u8 = main_mod.findGitDirectory(allocator, platform_impl) catch null;
        if (gpc) |gp2| allocator.free(gp2) else {
            try platform_impl.writeStderr("fatal: --worktree can only be used inside a git repository\n");
            std.process.exit(128);
        }
    }

    // Subcommand mode adjustments
    if (new_style_sub and action == .get and do_all) action = .get_all;
    if (new_style_sub and action == .set and do_all) action = .replace_all;
    if (new_style_sub and action == .unset and do_all) action = .unset_all;

    // Infer action from positionals
    if (action == .none) {
        if (positionals.items.len == 0) {
            try platform_impl.writeStderr("error: no action specified\n");
            std.process.exit(2);
        } else if (positionals.items.len == 1) {
            action = .get;
        } else {
            action = .set;
        }
    }

    // Validate --fixed-value usage (after action inference)
    if (fixed_value) {
        switch (action) {
            .get, .get_all, .get_regexp, .set, .replace_all, .unset, .unset_all => {},
            .add, .get_urlmatch, .rename_section, .remove_section, .list, .get_color, .get_colorbool, .edit => {
                try platform_impl.writeStderr("error: --fixed-value only applies with 'get', 'set', 'unset'\n");
                std.process.exit(129);
            },
            .none => {
                try platform_impl.writeStderr("error: --fixed-value only applies with 'get', 'set', 'unset'\n");
                std.process.exit(129);
            },
        }
    }

    // url_match on subcommand get implies get_urlmatch behavior
    if (url_match != null and action == .get) {
        action = .get_urlmatch;
    }

    const git_path_opt: ?[]const u8 = main_mod.findGitDirectory(allocator, platform_impl) catch null;
    defer if (git_path_opt) |gp| allocator.free(gp);

    // --local requires repo
    if ((use_local or use_worktree) and git_path_opt == null) {
        try platform_impl.writeStderr("fatal: --local can only be used inside a git repository\n");
        std.process.exit(128);
    }

    // Env vars
    const env_cfg_global = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_GLOBAL") catch null;
    defer if (env_cfg_global) |eg| allocator.free(eg);
    const env_cfg_system = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_SYSTEM") catch null;
    defer if (env_cfg_system) |es| allocator.free(es);
    const env_cfg_nosystem = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_NOSYSTEM") catch null;
    defer if (env_cfg_nosystem) |en| allocator.free(en);

    // GIT_CONFIG overrides config file
    const env_git_config_owned = if (config_file == null)
        (std.process.getEnvVarOwned(allocator, "GIT_CONFIG") catch null)
    else
        null;
    defer if (env_git_config_owned) |egc| allocator.free(egc);
    if (env_git_config_owned) |egc| config_file = egc;

    // Stdin restrictions
    if (config_file != null and std.mem.eql(u8, config_file.?, "-")) {
        switch (action) {
            .set, .replace_all, .add, .unset, .unset_all, .rename_section, .remove_section => {
                try platform_impl.writeStderr("fatal: writing to stdin is not supported\n");
                std.process.exit(128);
            },
            .edit => {
                try platform_impl.writeStderr("fatal: editing stdin is not supported\n");
                std.process.exit(128);
            },
            else => {},
        }
    }

    // Build source list
    var sources = std.array_list.Managed(ConfigSource).init(allocator);
    defer {
        for (sources.items) |s| {
            if (s.needs_free) allocator.free(s.path);
        }
        sources.deinit();
    }
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (home_dir) |h| allocator.free(h);

    // Blob content (read once if --blob is used)
    var blob_content: ?[]u8 = null;
    defer if (blob_content) |bc| allocator.free(bc);
    var blob_display_name: ?[]u8 = null;
    defer if (blob_display_name) |bn| allocator.free(bn);

    if (blob_ref) |br| {
        // --blob mode: read config from a git blob using git cat-file
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "/usr/bin/git", "cat-file", "-p", br },
        }) catch {
            const em = try std.fmt.allocPrint(allocator, "fatal: unable to read blob object '{s}'\n", .{br});
            defer allocator.free(em);
            try platform_impl.writeStderr(em);
            std.process.exit(128);
        };
        defer allocator.free(result.stderr);
        if (result.term.Exited != 0) {
            const em = try std.fmt.allocPrint(allocator, "fatal: unable to read blob object '{s}'\n", .{br});
            defer allocator.free(em);
            try platform_impl.writeStderr(em);
            allocator.free(result.stdout);
            std.process.exit(128);
        }
        blob_content = result.stdout;
        blob_display_name = try std.fmt.allocPrint(allocator, "blob:{s}", .{br});
    } else if (config_file) |cf| {
        try sources.append(.{ .path = cf, .scope = "command", .needs_free = false });
    } else if (use_system) {
        if (env_cfg_system) |es| {
            try sources.append(.{ .path = es, .scope = "system", .needs_free = false });
        } else {
            try sources.append(.{ .path = "/etc/gitconfig", .scope = "system", .needs_free = false });
        }
    } else if (use_global) {
        if (env_cfg_global) |eg| {
            try sources.append(.{ .path = eg, .scope = "global", .needs_free = false });
        } else if (home_dir) |h| {
            const p = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{h});
            try sources.append(.{ .path = p, .scope = "global", .needs_free = true });
        }
    } else if (use_local) {
        if (git_path_opt) |gp| {
            const abs_p = try std.fmt.allocPrint(allocator, "{s}/config", .{gp});
            defer allocator.free(abs_p);
            const p = try cfgMakeRelativePath(abs_p, allocator);
            try sources.append(.{ .path = p, .scope = "local", .needs_free = true });
        }
    } else {
        // Default: system + global + local
        // FIX: GIT_CONFIG_NOSYSTEM should check value, not just existence
        const nosystem = if (env_cfg_nosystem) |en|
            (en.len > 0 and !std.mem.eql(u8, en, "false") and !std.mem.eql(u8, en, "0") and !std.mem.eql(u8, en, "no") and !std.mem.eql(u8, en, "off"))
        else
            false;
        if (!nosystem) {
            if (env_cfg_system) |es| {
                if (!std.mem.eql(u8, es, "/dev/null"))
                    try sources.append(.{ .path = es, .scope = "system", .needs_free = false });
            } else {
                try sources.append(.{ .path = "/etc/gitconfig", .scope = "system", .needs_free = false });
            }
        }
        if (env_cfg_global) |eg| {
            if (!std.mem.eql(u8, eg, "/dev/null"))
                try sources.append(.{ .path = eg, .scope = "global", .needs_free = false });
        } else {
            const xdg = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
            defer if (xdg) |x| allocator.free(x);
            if (xdg) |x| {
                const p = try std.fmt.allocPrint(allocator, "{s}/git/config", .{x});
                try sources.append(.{ .path = p, .scope = "global", .needs_free = true });
            } else if (home_dir) |h| {
                const p = try std.fmt.allocPrint(allocator, "{s}/.config/git/config", .{h});
                try sources.append(.{ .path = p, .scope = "global", .needs_free = true });
            }
            if (home_dir) |h| {
                const p = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{h});
                try sources.append(.{ .path = p, .scope = "global", .needs_free = true });
            }
        }
        if (git_path_opt) |gp| {
            const abs_p = try std.fmt.allocPrint(allocator, "{s}/config", .{gp});
            defer allocator.free(abs_p);
            const p = try cfgMakeRelativePath(abs_p, allocator);
            try sources.append(.{ .path = p, .scope = "local", .needs_free = true });
        }
    }

    // Follow includes only when not restricted to a single scope
    const follow_includes = includes_flag or (!use_global and !use_system and !use_local and !use_worktree and config_file == null);

    // Build our own config override list with proper has_equals tracking
    var cfg_overrides = buildConfigOverrides(allocator) catch |e| {
        if (e == error.BogusConfigParameters) {
            try platform_impl.writeStderr("error: bogus format in GIT_CONFIG_PARAMETERS\n");
            std.process.exit(129);
        }
        return e;
    };
    defer {
        for (cfg_overrides.items) |item| {
            allocator.free(item.key);
            allocator.free(item.value);
        }
        cfg_overrides.deinit();
    }

    // Write path helper
    const getWritePath = struct {
        fn f(alloc: Allocator, cf: ?[]const u8, ug: bool, us: bool, home: ?[]const u8, gp: ?[]const u8, ecg: ?[]const u8, ecs: ?[]const u8, pi: *const platform_mod.Platform) ![]u8 {
            if (cf) |file| return try alloc.dupe(u8, file);
            if (ug) {
                if (ecg) |eg| return try alloc.dupe(u8, eg);
                if (home) |h| return try std.fmt.allocPrint(alloc, "{s}/.gitconfig", .{h});
                try pi.writeStderr("fatal: $HOME not set\n");
                std.process.exit(128);
            }
            if (us) {
                if (ecs) |es| return try alloc.dupe(u8, es);
                return try alloc.dupe(u8, "/etc/gitconfig");
            }
            if (gp) |g| return try std.fmt.allocPrint(alloc, "{s}/config", .{g});
            try pi.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
            std.process.exit(128);
        }
    };

    // For --file, check that file exists for read operations
    if (config_file) |cf| {
        if (!std.mem.eql(u8, cf, "-")) {
            switch (action) {
                .list, .get, .get_all, .get_regexp => {
                    _ = platform_impl.fs.readFile(allocator, cf) catch |err| switch (err) {
                        error.FileNotFound => {
                            if (default_value != null and action == .get) {
                                const dv = default_value.?;
                                const fmt_dv = cfgFormatType(dv, config_type, allocator, platform_impl) catch {
                                    try platform_impl.writeStderr("error: failed to format default config value\n");
                                    std.process.exit(1);
                                };
                                defer allocator.free(fmt_dv);
                                const dv_term: []const u8 = if (null_terminator) "\x00" else "\n";
                                const dv_out = try std.fmt.allocPrint(allocator, "{s}{s}", .{ fmt_dv, dv_term });
                                defer allocator.free(dv_out);
                                try platform_impl.writeStdout(dv_out);
                                return;
                            }
                            const em = try std.fmt.allocPrint(allocator, "fatal: unable to read config file '{s}': No such file or directory\n", .{cf});
                            defer allocator.free(em);
                            try platform_impl.writeStderr(em);
                            std.process.exit(1);
                        },
                        else => {},
                    };
                },
                else => {},
            }
        }
    }

    if (default_value != null) {
        switch (action) {
            .get, .get_all, .get_regexp => {},
            else => {
                try platform_impl.writeStderr("error: --default is only applicable to --get\n");
                std.process.exit(129);
            },
        }
    }

    // Validate --fixed-value requires value-pattern
    if (fixed_value) {
        const has_vpat = sub_value_pattern != null or (positionals.items.len >= 2 and (action == .get or action == .get_all or action == .get_regexp or action == .unset or action == .unset_all)) or (positionals.items.len >= 3 and (action == .set or action == .replace_all));
        if (!has_vpat) {
            switch (action) {
                .get, .get_all, .get_regexp, .set, .replace_all, .unset, .unset_all => {
                    try platform_impl.writeStderr("error: --fixed-value requires a value argument\n");
                    std.process.exit(129);
                },
                else => {},
            }
        }
    }

    switch (action) {
        .list => {
            // Collect all entries with include support
            var all_entries = std.array_list.Managed(CfgEntry).init(allocator);
            defer {
                for (all_entries.items) |*e| e.deinit(allocator);
                all_entries.deinit();
            }

            // Handle blob content
            if (blob_content) |bc| {
                const bdn = blob_display_name orelse "blob:";
                try cfgValidateAndReport(bc, bdn, allocator, platform_impl);
                try collectEntriesWithIncludes(bc, bdn, "command", allocator, platform_impl, &all_entries, git_path_opt, false);
            }

            if (blob_content == null) {
                for (sources.items) |source| {
                    if (std.mem.eql(u8, source.path, "-")) {
                        const content = readStdin(allocator, 10 * 1024 * 1024) catch continue;
                        defer allocator.free(content);
                        try cfgValidateAndReport(content, "standard input", allocator, platform_impl);
                        try collectEntriesWithIncludes(content, "standard input", source.scope, allocator, platform_impl, &all_entries, git_path_opt, follow_includes);
                    } else {
                        const content = platform_impl.fs.readFile(allocator, source.path) catch |err| {
                            // For scoped operations, missing file is an error
                            if (err == error.FileNotFound and (use_global or use_system or use_local)) {
                                const em = try std.fmt.allocPrint(allocator, "fatal: unable to read config file '{s}': No such file or directory\n", .{source.path});
                                defer allocator.free(em);
                                try platform_impl.writeStderr(em);
                                std.process.exit(1);
                            }
                            continue;
                        };
                        defer allocator.free(content);
                        try cfgValidateAndReport(content, source.path, allocator, platform_impl);
                        try collectEntriesWithIncludes(content, source.path, source.scope, allocator, platform_impl, &all_entries, git_path_opt, follow_includes);
                    }
                }
            }

            for (all_entries.items) |e| {
                const term: []const u8 = if (null_terminator) "\x00" else "\n";
                const origin_sep: u8 = if (null_terminator) '\x00' else '\t';
                var out = std.array_list.Managed(u8).init(allocator);
                defer out.deinit();
                if (show_scope) {
                    try out.appendSlice(e.source_scope orelse "local");
                    try out.append('\t');
                }
                if (show_origin) {
                    try cfgAppendOrigin(&out, e.source_path orelse "");
                    try out.append(origin_sep);
                }
                if (show_names) {
                    try out.appendSlice(e.full_key);
                } else if (config_type != .none) {
                    const fmt2 = cfgFormatTypeSilent(cfgEffectiveValue(e), config_type, allocator) catch continue;
                    defer allocator.free(fmt2);
                    try out.appendSlice(e.full_key);
                    if (null_terminator) try out.append('\n') else try out.append('=');
                    try out.appendSlice(fmt2);
                } else if (e.has_equals) {
                    try out.appendSlice(e.full_key);
                    if (null_terminator) try out.append('\n') else try out.append('=');
                    try out.appendSlice(e.value);
                } else {
                    try out.appendSlice(e.full_key);
                }
                try out.appendSlice(term);
                try platform_impl.writeStdout(out.items);
            }
            // Also list config overrides
            for (cfg_overrides.items) |ov| {
                const term3: []const u8 = if (null_terminator) "\x00" else "\n";
                const origin_sep3: u8 = if (null_terminator) '\x00' else '\t';
                var out3 = std.array_list.Managed(u8).init(allocator);
                defer out3.deinit();
                if (show_scope) {
                    try out3.appendSlice(ov.source);
                    try out3.append('\t');
                }
                if (show_origin) {
                    try out3.appendSlice("command line:");
                    try out3.append(origin_sep3);
                }
                if (show_names) {
                    try out3.appendSlice(ov.key);
                } else {
                    try out3.appendSlice(ov.key);
                    if (ov.has_equals or ov.value.len > 0) {
                        if (null_terminator) try out3.append('\n') else try out3.append('=');
                        try out3.appendSlice(ov.value);
                    }
                }
                try out3.appendSlice(term3);
                try platform_impl.writeStdout(out3.items);
            }
            return;
        },
        .edit => {
            const cfg_path = try getWritePath.f(allocator, config_file, use_global, use_system, home_dir, git_path_opt, env_cfg_global, env_cfg_system, platform_impl);
            defer allocator.free(cfg_path);
            _ = platform_impl.fs.readFile(allocator, cfg_path) catch |err| blk: {
                if (err == error.FileNotFound) try platform_impl.fs.writeFile(cfg_path, "");
                break :blk @as([]u8, "");
            };
            // Editor priority: GIT_EDITOR env, core.editor config, VISUAL env, EDITOR env, vi
            // For core.editor lookup, always use main config sources (not the -f file)
            var editor_sources = std.array_list.Managed(ConfigSource).init(allocator);
            defer {
                for (editor_sources.items) |es| {
                    if (es.needs_free) allocator.free(es.path);
                }
                editor_sources.deinit();
            }
            if (git_path_opt) |gp| {
                const abs_p2 = try std.fmt.allocPrint(allocator, "{s}/config", .{gp});
                defer allocator.free(abs_p2);
                const p2 = try cfgMakeRelativePath(abs_p2, allocator);
                try editor_sources.append(.{ .path = p2, .scope = "local", .needs_free = true });
            }
            if (home_dir) |h| {
                const p2 = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{h});
                try editor_sources.append(.{ .path = p2, .scope = "global", .needs_free = true });
            }
            const editor = blk_editor: {
                if (std.process.getEnvVarOwned(allocator, "GIT_EDITOR")) |e| break :blk_editor e else |_| {}
                if (cfgLookup(editor_sources.items, "core.editor", allocator, platform_impl)) |e| break :blk_editor e else |_| {}
                if (std.process.getEnvVarOwned(allocator, "VISUAL")) |e| break :blk_editor e else |_| {}
                if (std.process.getEnvVarOwned(allocator, "EDITOR")) |e| break :blk_editor e else |_| {}
                break :blk_editor try allocator.dupe(u8, "vi");
            };
            defer allocator.free(editor);
            const shell_cmd = try std.fmt.allocPrint(allocator, "{s} \"{s}\"", .{ editor, cfg_path });
            defer allocator.free(shell_cmd);
            const shell_argv = [_][]const u8{ "/bin/sh", "-c", shell_cmd };
            var child = std.process.Child.init(&shell_argv, allocator);
            child.spawn() catch {
                try platform_impl.writeStderr("error: could not launch editor\n");
                std.process.exit(1);
            };
            _ = child.wait() catch {};
            return;
        },
        .rename_section => {
            if (positionals.items.len < 2) {
                try platform_impl.writeStderr("usage: git config --rename-section <old-name> <new-name>\n");
                std.process.exit(2);
            }
            const old_s = positionals.items[0];
            const new_s = positionals.items[1];
            if (old_s.len == 0) {
                try platform_impl.writeStderr("error: invalid section name: \n");
                std.process.exit(2);
            }
            if (!cfgIsValidSectionName(new_s)) {
                const em = try std.fmt.allocPrint(allocator, "error: invalid section name: {s}\n", .{new_s});
                defer allocator.free(em);
                try platform_impl.writeStderr(em);
                std.process.exit(2);
            }
            const cfg_path = try getWritePath.f(allocator, config_file, use_global, use_system, home_dir, git_path_opt, env_cfg_global, env_cfg_system, platform_impl);
            defer allocator.free(cfg_path);
            try cfgRenameSection(cfg_path, old_s, new_s, allocator, platform_impl);
            return;
        },
        .remove_section => {
            if (positionals.items.len < 1) {
                try platform_impl.writeStderr("error: missing section name\n");
                std.process.exit(2);
            }
            const cfg_path = try getWritePath.f(allocator, config_file, use_global, use_system, home_dir, git_path_opt, env_cfg_global, env_cfg_system, platform_impl);
            defer allocator.free(cfg_path);
            try cfgRemoveSection(cfg_path, positionals.items[0], allocator, platform_impl);
            return;
        },
        .get_color => {
            const key2 = if (positionals.items.len >= 1) positionals.items[0] else {
                try platform_impl.writeStderr("error: --get-color requires a key\n");
                std.process.exit(2);
            };
            const def = if (positionals.items.len >= 2) positionals.items[1] else "";
            const val = if (key2.len > 0) (cfgLookup(sources.items, key2, allocator, platform_impl) catch null) else null;
            defer if (val) |v| allocator.free(v);
            const color_str = val orelse def;
            const ansi = colorToAnsiAlloc(allocator, color_str) catch {
                std.process.exit(1);
            };
            defer allocator.free(ansi);
            try platform_impl.writeStdout(ansi);
            return;
        },
        .get_colorbool => {
            try platform_impl.writeStdout("false\n");
            return;
        },
        .get_urlmatch => {
            if (positionals.items.len < 1) {
                try platform_impl.writeStderr("error: --get-urlmatch requires a key and URL\n");
                std.process.exit(2);
            }
            const key_or_section = positionals.items[0];
            const match_url = url_match orelse (if (positionals.items.len >= 2) positionals.items[1] else {
                try platform_impl.writeStderr("error: --get-urlmatch requires a URL\n");
                std.process.exit(2);
            });

            // Collect all entries
            var all_entries = std.array_list.Managed(CfgEntry).init(allocator);
            defer {
                for (all_entries.items) |*e| e.deinit(allocator);
                all_entries.deinit();
            }
            for (sources.items) |source| {
                const content = cfgReadSource(source.path, allocator, platform_impl) orelse continue;
                defer allocator.free(content);
                cfgValidateAndReport(content, source.path, allocator, platform_impl) catch {};
                collectEntriesWithIncludes(content, source.path, source.scope, allocator, platform_impl, &all_entries, git_path_opt, follow_includes) catch continue;
            }

            // Check if key_or_section contains a dot (key) or not (section)
            const is_section = (std.mem.indexOfScalar(u8, key_or_section, '.') == null);

            if (is_section) {
                // Section mode: return all matching keys from the best-matching URL subsection
                // Find entries in [section] and [section "url-pattern"] that match
                const lower_section = try std.ascii.allocLowerString(allocator, key_or_section);
                defer allocator.free(lower_section);

                // Collect results: for each variable, find the best URL match
                const UrlResult = struct { value: []const u8, specificity: usize, scope: []const u8, has_equals: bool };
                var results = std.StringHashMap(UrlResult).init(allocator);
                defer {
                    var it = results.iterator();
                    while (it.next()) |_| {}
                    results.deinit();
                }

                for (all_entries.items) |e| {
                    const last_dot = std.mem.lastIndexOfScalar(u8, e.full_key, '.') orelse continue;
                    const var_name = e.full_key[last_dot + 1 ..];
                    const prefix = e.full_key[0..last_dot];
                    const first_dot = std.mem.indexOfScalar(u8, prefix, '.');

                    if (first_dot) |fd| {
                        // Has subsection: [section "subsection"]
                        const sec = prefix[0..fd];
                        const subsec = prefix[fd + 1 ..];
                        if (!std.ascii.eqlIgnoreCase(sec, lower_section)) continue;
                        // subsec is a URL pattern - check if it matches match_url
                        const specificity = urlMatchSpecificity(subsec, match_url);
                        if (specificity == 0) continue;
                        const var_lower = try std.ascii.allocLowerString(allocator, var_name);
                        defer allocator.free(var_lower);
                        if (results.get(var_lower)) |existing| {
                            if (specificity >= existing.specificity) {
                                results.put(var_lower, .{ .value = e.value, .specificity = specificity, .scope = e.source_scope orelse "local", .has_equals = e.has_equals }) catch continue;
                            }
                        } else {
                            results.put(var_lower, .{ .value = e.value, .specificity = specificity, .scope = e.source_scope orelse "local", .has_equals = e.has_equals }) catch continue;
                        }
                    } else {
                        // No subsection: [section] - base values (specificity=1)
                        if (!std.ascii.eqlIgnoreCase(prefix, lower_section)) continue;
                        const var_lower = try std.ascii.allocLowerString(allocator, var_name);
                        defer allocator.free(var_lower);
                        if (results.get(var_lower)) |existing| {
                            if (1 >= existing.specificity) {
                                results.put(var_lower, .{ .value = cfgEffectiveValue(e), .specificity = 1, .scope = e.source_scope orelse "local", .has_equals = e.has_equals }) catch continue;
                            }
                        } else {
                            results.put(var_lower, .{ .value = cfgEffectiveValue(e), .specificity = 1, .scope = e.source_scope orelse "local", .has_equals = e.has_equals }) catch continue;
                        }
                    }
                }

                if (results.count() == 0) {
                    std.process.exit(1);
                }

                // Collect and sort by variable name
                var keys_list = std.array_list.Managed([]const u8).init(allocator);
                defer keys_list.deinit();
                var it = results.iterator();
                while (it.next()) |entry| {
                    try keys_list.append(entry.key_ptr.*);
                }
                std.mem.sort([]const u8, keys_list.items, {}, struct {
                    fn cmp(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.cmp);

                for (keys_list.items) |var_key| {
                    const entry = results.get(var_key).?;
                    const fmt_val = if (config_type != .none)
                        (cfgFormatTypeSilent(entry.value, config_type, allocator) catch continue)
                    else
                        try allocator.dupe(u8, entry.value);
                    defer allocator.free(fmt_val);
                    var out = std.array_list.Managed(u8).init(allocator);
                    defer out.deinit();
                    if (show_scope) {
                        try out.appendSlice(entry.scope);
                        try out.append('\t');
                    }
                    try out.appendSlice(lower_section);
                    try out.append('.');
                    try out.appendSlice(var_key);
                    // Only append value if entry has = or config_type forces it
                    if (entry.has_equals or config_type != .none) {
                        try out.append(' ');
                        try out.appendSlice(fmt_val);
                    }
                    try out.append('\n');
                    try platform_impl.writeStdout(out.items);
                }
            } else {
                // Key mode: find the best-matching value for this key
                const last_dot = std.mem.lastIndexOfScalar(u8, key_or_section, '.') orelse {
                    std.process.exit(1);
                };
                const key_section = key_or_section[0..last_dot];
                const key_var = key_or_section[last_dot + 1 ..];

                var best_value: ?[]const u8 = null;
                var best_specificity: usize = 0;
                var best_scope: []const u8 = "local";

                for (all_entries.items) |e| {
                    const e_last_dot = std.mem.lastIndexOfScalar(u8, e.full_key, '.') orelse continue;
                    const e_var = e.full_key[e_last_dot + 1 ..];
                    const e_prefix = e.full_key[0..e_last_dot];

                    if (!std.ascii.eqlIgnoreCase(e_var, key_var)) continue;

                    const e_first_dot = std.mem.indexOfScalar(u8, e_prefix, '.');
                    if (e_first_dot) |fd| {
                        const sec = e_prefix[0..fd];
                        const subsec = e_prefix[fd + 1 ..];
                        if (!std.ascii.eqlIgnoreCase(sec, key_section)) continue;
                        const specificity = urlMatchSpecificity(subsec, match_url);
                        if (specificity == 0) continue;
                        if (specificity >= best_specificity) {
                            best_value = e.value;
                            best_specificity = specificity;
                            best_scope = e.source_scope orelse "local";
                        }
                    } else {
                        if (!std.ascii.eqlIgnoreCase(e_prefix, key_section)) continue;
                        // Base value, specificity=1
                        if (1 >= best_specificity) {
                            best_value = cfgEffectiveValue(e);
                            best_specificity = 1;
                            best_scope = e.source_scope orelse "local";
                        }
                    }
                }

                if (best_value) |val| {
                    const fmt_val = try cfgFormatType(val, config_type, allocator, platform_impl);
                    defer allocator.free(fmt_val);
                    var out = std.array_list.Managed(u8).init(allocator);
                    defer out.deinit();
                    if (show_scope) {
                        try out.appendSlice(best_scope);
                        try out.append('\t');
                    }
                    try out.appendSlice(fmt_val);
                    try out.append('\n');
                    try platform_impl.writeStdout(out.items);
                } else {
                    std.process.exit(1);
                }
            }
            return;
        },
        .get, .get_all => {
            if (positionals.items.len < 1) {
                try platform_impl.writeStderr("error: missing key\n");
                std.process.exit(2);
            }
            const key2 = positionals.items[0];
            const vpat = sub_value_pattern orelse (if (positionals.items.len >= 2) positionals.items[1] else null);

            // Collect all entries with include support
            var all_entries = std.array_list.Managed(CfgEntry).init(allocator);
            defer {
                for (all_entries.items) |*e| e.deinit(allocator);
                all_entries.deinit();
            }
            if (blob_content) |bc| {
                const bdn = blob_display_name orelse "blob:";
                cfgValidateAndReport(bc, bdn, allocator, platform_impl) catch {};
                collectEntriesWithIncludes(bc, bdn, "command", allocator, platform_impl, &all_entries, git_path_opt, false) catch {};
            }
            if (blob_content == null) for (sources.items) |source| {
                const content = cfgReadSource(source.path, allocator, platform_impl) orelse continue;
                defer allocator.free(content);
                cfgValidateAndReport(content, source.path, allocator, platform_impl) catch {};
                collectEntriesWithIncludes(content, source.path, source.scope, allocator, platform_impl, &all_entries, git_path_opt, follow_includes) catch continue;
            };

            if (action == .get_all) {
                var found_any = false;
                for (all_entries.items) |e| {
                    if (!cfgKeyMatches(e.full_key, key2)) continue;
                    if (vpat) |vp| {
                        if (!cfgValueMatchesPattern(e.value, vp, fixed_value)) continue;
                    }
                    found_any = true;
                    const fmt2 = try cfgFormatTypeWithContext(cfgEffectiveValue(e), config_type, key2, e.source_path, allocator, platform_impl);
                    defer allocator.free(fmt2);
                    const term: []const u8 = if (null_terminator) "\x00" else "\n";
                    var out = std.array_list.Managed(u8).init(allocator);
                    defer out.deinit();
                    if (show_scope) {
                        try out.appendSlice(e.source_scope orelse "local");
                        try out.append('\t');
                    }
                    if (show_origin) {
                        try cfgAppendOrigin(&out, e.source_path orelse "");
                        try out.append('\t');
                    }
                    try out.appendSlice(fmt2);
                    try out.appendSlice(term);
                    try platform_impl.writeStdout(out.items);
                }
                if (!found_any) std.process.exit(1);
            } else {
                // --get: return last
                var last_val: ?[]u8 = null;
                var last_scope: []const u8 = "";
                var last_origin: []const u8 = "";
                var last_has_equals: bool = true;
                var last_line_number: usize = 0;
                defer if (last_val) |v| allocator.free(v);
                for (all_entries.items) |e| {
                    if (!cfgKeyMatches(e.full_key, key2)) continue;
                    if (vpat) |vp| {
                        if (!cfgValueMatchesPattern(e.value, vp, fixed_value)) continue;
                    }
                    if (last_val) |v| allocator.free(v);
                    last_val = try allocator.dupe(u8, cfgEffectiveValue(e));
                    last_has_equals = e.has_equals;
                    last_line_number = e.line_number;
                    last_scope = e.source_scope orelse "local";
                    last_origin = e.source_path orelse "";
                }
                // Check our own config overrides (last one wins)
                for (cfg_overrides.items) |cov| {
                    if (cfgKeyMatches(cov.key, key2)) {
                        if (last_val) |v| allocator.free(v);
                        last_val = try allocator.dupe(u8, if (cov.has_equals) cov.value else "true");
                        last_has_equals = cov.has_equals;
                        last_scope = cov.source;
                        last_origin = "";
                    }
                }
                const eff = last_val orelse if (default_value) |dv| blk: {
                    last_scope = "command";
                    break :blk try allocator.dupe(u8, dv);
                } else null;
                defer if (last_val == null) {
                    if (eff) |ev| allocator.free(ev);
                };
                if (eff) |v| {
                    // --path on a boolean variable (no = sign) is an error
                    if (config_type == .path_type and !last_has_equals) {
                        if (last_origin.len > 0 and last_line_number > 0) {
                            const em = try std.fmt.allocPrint(allocator, "fatal: bad config variable '{s}' in file {s} at line {d}\n", .{ key2, last_origin, last_line_number });
                            defer allocator.free(em);
                            try platform_impl.writeStderr(em);
                        } else {
                            const em = try std.fmt.allocPrint(allocator, "fatal: bad config variable '{s}'\n", .{key2});
                            defer allocator.free(em);
                            try platform_impl.writeStderr(em);
                        }
                        std.process.exit(128);
                    }
                    const fmt2 = try cfgFormatTypeWithContext(v, config_type, key2, if (last_origin.len > 0) last_origin else null, allocator, platform_impl);
                    defer allocator.free(fmt2);
                    // Color type with empty key outputs without trailing newline (like --get-color)
                    const term: []const u8 = if (config_type == .color_type and key2.len == 0) "" else if (null_terminator) "\x00" else "\n";
                    var out = std.array_list.Managed(u8).init(allocator);
                    defer out.deinit();
                    if (show_scope) {
                        try out.appendSlice(last_scope);
                        try out.append('\t');
                    }
                    if (show_origin) {
                        if (last_origin.len > 0) {
                            try cfgAppendOrigin(&out, last_origin);
                        } else try out.appendSlice("command line:");
                        try out.append('\t');
                    }
                    try out.appendSlice(fmt2);
                    try out.appendSlice(term);
                    try platform_impl.writeStdout(out.items);
                } else std.process.exit(1);
            }
            return;
        },
        .get_regexp => {
            if (positionals.items.len < 1) {
                try platform_impl.writeStderr("error: missing key pattern\n");
                std.process.exit(2);
            }
            const pattern = positionals.items[0];
            const vpat = sub_value_pattern orelse (if (positionals.items.len >= 2) positionals.items[1] else null);

            // Collect all entries with include support
            var all_entries = std.array_list.Managed(CfgEntry).init(allocator);
            defer {
                for (all_entries.items) |*e| e.deinit(allocator);
                all_entries.deinit();
            }
            if (blob_content) |bc| {
                const bdn = blob_display_name orelse "blob:";
                cfgValidateAndReport(bc, bdn, allocator, platform_impl) catch {};
                collectEntriesWithIncludes(bc, bdn, "command", allocator, platform_impl, &all_entries, git_path_opt, false) catch {};
            }
            if (blob_content == null) for (sources.items) |source| {
                const content = cfgReadSource(source.path, allocator, platform_impl) orelse continue;
                defer allocator.free(content);
                cfgValidateAndReport(content, source.path, allocator, platform_impl) catch {};
                collectEntriesWithIncludes(content, source.path, source.scope, allocator, platform_impl, &all_entries, git_path_opt, follow_includes) catch continue;
            };

            var found_any = false;
            for (all_entries.items) |e| {
                if (!simpleRegexMatch(e.full_key, pattern)) continue;
                if (vpat) |vp| {
                    if (fixed_value) {
                        if (!std.mem.eql(u8, e.value, vp)) continue;
                    } else {
                        if (!simpleRegexMatch(e.value, vp)) continue;
                    }
                }
                found_any = true;
                const term: []const u8 = if (null_terminator) "\x00" else "\n";
                var out = std.array_list.Managed(u8).init(allocator);
                defer out.deinit();
                if (show_scope) {
                    try out.appendSlice(e.source_scope orelse "local");
                    try out.append('\t');
                }
                if (show_origin) {
                    try cfgAppendOrigin(&out, e.source_path orelse "");
                    try out.append('\t');
                }
                if (show_names) {
                    try out.appendSlice(e.full_key);
                } else {
                    const fmt2 = try cfgFormatType(cfgEffectiveValue(e), config_type, allocator, platform_impl);
                    defer allocator.free(fmt2);
                    try out.appendSlice(e.full_key);
                    if (e.value.len > 0 or e.has_equals or config_type != .none) {
                        const sep: u8 = if (null_terminator) '\n' else ' ';
                        try out.append(sep);
                        try out.appendSlice(fmt2);
                    }
                }
                try out.appendSlice(term);
                try platform_impl.writeStdout(out.items);
            }
            // Also check config overrides
            for (cfg_overrides.items) |ov| {
                if (!simpleRegexMatch(ov.key, pattern)) continue;
                const ov_effective_value = if (ov.has_equals) ov.value else "true";
                if (vpat) |vp| {
                    if (!simpleRegexMatch(ov_effective_value, vp)) continue;
                }
                found_any = true;
                const term2: []const u8 = if (null_terminator) "\x00" else "\n";
                var out2 = std.array_list.Managed(u8).init(allocator);
                defer out2.deinit();
                if (show_scope) {
                    try out2.appendSlice(ov.source);
                    try out2.append('\t');
                }
                if (show_origin) {
                    try out2.appendSlice("command line:");
                    try out2.append('\t');
                }
                if (show_names) {
                    try out2.appendSlice(ov.key);
                } else {
                    try out2.appendSlice(ov.key);
                    if (ov_effective_value.len > 0) {
                        try out2.append(if (null_terminator) '\n' else ' ');
                        try out2.appendSlice(ov_effective_value);
                    }
                }
                try out2.appendSlice(term2);
                try platform_impl.writeStdout(out2.items);
            }
            if (!found_any) std.process.exit(1);
            return;
        },
        .set, .replace_all, .add => {
            if (positionals.items.len < 2) {
                try platform_impl.writeStderr("error: wrong number of arguments, should be 2\n");
                std.process.exit(2);
            }
            const key2 = positionals.items[0];
            const value2 = positionals.items[1];
            const vreg = sub_value_pattern orelse (if (positionals.items.len >= 3) positionals.items[2] else null);
            if (!cfgIsValidKey(key2)) {
                const em = try std.fmt.allocPrint(allocator, "error: invalid key: {s}\n", .{key2});
                defer allocator.free(em);
                try platform_impl.writeStderr(em);
                std.process.exit(1);
            }
            if (config_comment) |cc| {
                if (std.mem.indexOfScalar(u8, cc, '\n') != null) {
                    try platform_impl.writeStderr("error: invalid comment character: '\\n'\n");
                    std.process.exit(1);
                }
            }
            const effective_value = if (config_type == .color_type) blk: {
                if (!cfgValidateColor(std.mem.trim(u8, value2, " \t"))) {
                    const em2 = try std.fmt.allocPrint(allocator, "error: cannot parse color '{s}'\n", .{value2});
                    defer allocator.free(em2);
                    try platform_impl.writeStderr(em2);
                    std.process.exit(1);
                }
                break :blk try allocator.dupe(u8, value2);
            } else if (config_type != .none and config_type != .path_type and config_type != .expiry_date) blk: {
                const norm = try cfgFormatType(value2, config_type, allocator, platform_impl);
                break :blk norm;
            } else try allocator.dupe(u8, value2);
            defer allocator.free(effective_value);

            const cfg_path = try getWritePath.f(allocator, config_file, use_global, use_system, home_dir, git_path_opt, env_cfg_global, env_cfg_system, platform_impl);
            defer allocator.free(cfg_path);
            try cfgSetValue(cfg_path, key2, effective_value, action == .add, action == .replace_all, vreg, fixed_value, config_comment, allocator, platform_impl);
            return;
        },
        .unset, .unset_all => {
            if (positionals.items.len < 1) {
                try platform_impl.writeStderr("error: missing key\n");
                std.process.exit(2);
            }
            const key2 = positionals.items[0];
            const vreg = sub_value_pattern orelse (if (positionals.items.len >= 2) positionals.items[1] else null);
            const cfg_path = try getWritePath.f(allocator, config_file, use_global, use_system, home_dir, git_path_opt, env_cfg_global, env_cfg_system, platform_impl);
            defer allocator.free(cfg_path);
            try cfgUnsetValue(cfg_path, key2, action == .unset_all, vreg, fixed_value, allocator, platform_impl);
            return;
        },
        .none => {
            try platform_impl.writeStderr("usage: git config [<options>]\n");
            std.process.exit(129);
        },
    }
}

// ============ Helper Functions ============

fn cfgMakeRelativePath(abs_path: []const u8, allocator: Allocator) ![]u8 {
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return try allocator.dupe(u8, abs_path);
    defer allocator.free(cwd);
    if (std.mem.startsWith(u8, abs_path, cwd)) {
        const rel = abs_path[cwd.len..];
        if (rel.len > 0 and rel[0] == '/') return try allocator.dupe(u8, rel[1..]);
        if (rel.len == 0) return try allocator.dupe(u8, ".");
    }
    return try allocator.dupe(u8, abs_path);
}

/// Strip exactly one trailing \r (CRLF line ending)
fn stripOneTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn cfgReadSource(path: []const u8, allocator: Allocator, platform_impl: *const platform_mod.Platform) ?[]u8 {
    if (std.mem.eql(u8, path, "-")) {
        return readStdin(allocator, 10 * 1024 * 1024) catch null;
    }
    return platform_impl.fs.readFile(allocator, path) catch null;
}

const CfgParseError = struct {
    line_number: usize,
    message: []const u8,
};

fn cfgValidateConfig(content: []const u8, allocator: Allocator) ?CfgParseError {
    _ = allocator;
    var line_iter = std.mem.splitSequence(u8, content, "\n");
    var line_num: usize = 0;
    while (line_iter.next()) |raw_line| {
        line_num += 1;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;
        if (trimmed[0] == '[') {
            if (std.mem.indexOfScalar(u8, trimmed, ']') == null) {
                return .{ .line_number = line_num, .message = "bad section header" };
            }
            continue;
        }
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            var raw_value = trimmed[eq_pos + 1 ..];
            var in_quotes = false;
            while (true) {
                const tv = std.mem.trimRight(u8, raw_value, " \t");
                var ii: usize = 0;
                while (ii < tv.len) : (ii += 1) {
                    if (tv[ii] == '\\' and ii + 1 < tv.len) {
                        ii += 1;
                        continue;
                    }
                    if (tv[ii] == '"') in_quotes = !in_quotes;
                }
                if (tv.len > 0 and tv[tv.len - 1] == '\\') {
                    if (line_iter.next()) |nl| {
                        line_num += 1;
                        raw_value = stripOneTrailingCR(nl);
                    } else break;
                } else break;
            }
            if (in_quotes) {
                return .{ .line_number = line_num, .message = "bad config line" };
            }
        } else {
            const cp = std.mem.indexOfScalar(u8, trimmed, '#') orelse std.mem.indexOfScalar(u8, trimmed, ';');
            const clean = if (cp) |c| std.mem.trimRight(u8, trimmed[0..c], " \t") else trimmed;
            if (clean.len > 0) {
                if (std.mem.indexOfScalar(u8, clean, ' ') != null or std.mem.indexOfScalar(u8, clean, '\t') != null) {
                    return .{ .line_number = line_num, .message = "bad config line" };
                }
            }
        }
    }
    return null;
}

fn cfgValidateAndReport(content: []const u8, source_path: []const u8, allocator: Allocator, platform_impl: *const platform_mod.Platform) !void {
    if (cfgValidateConfig(content, allocator)) |err| {
        const is_stdin = std.mem.eql(u8, source_path, "-") or std.mem.eql(u8, source_path, "standard input");
        const source_name = if (is_stdin) "standard input" else source_path;
        const em = try std.fmt.allocPrint(allocator, "fatal: bad config line {d} in {s}{s}\n", .{
            err.line_number,
            if (is_stdin) @as([]const u8, "") else @as([]const u8, "file "),
            source_name,
        });
        defer allocator.free(em);
        try platform_impl.writeStderr(em);
        std.process.exit(128);
    }
}

pub fn cfgParseEntries(content: []const u8, entries: *std.array_list.Managed(CfgEntry), allocator: Allocator) !void {
    var line_iter = std.mem.splitSequence(u8, content, "\n");
    var current_section: ?[]u8 = null;
    var line_num: usize = 0;
    defer if (current_section) |s| allocator.free(s);
    while (line_iter.next()) |raw_line| {
        line_num += 1;
        const line = stripOneTrailingCR(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;
        if (trimmed[0] == '[') {
            if (current_section) |s| allocator.free(s);
            current_section = try cfgParseSectionToKey(trimmed, allocator);
            const close = std.mem.indexOf(u8, trimmed, "]") orelse continue;
            const after = std.mem.trim(u8, trimmed[close + 1 ..], " \t");
            if (after.len == 0 or after[0] == '#' or after[0] == ';') continue;
            if (std.mem.indexOf(u8, after, "=")) |eq| {
                const k = std.mem.trim(u8, after[0..eq], " \t");
                var vbuf = std.array_list.Managed(u8).init(allocator);
                defer vbuf.deinit();
                try cfgAppendValuePart(&vbuf, after[eq + 1 ..]);
                try entries.append(.{
                    .full_key = try cfgMakeKey(current_section, k, allocator),
                    .value = try vbuf.toOwnedSlice(),
                    .has_equals = true,
                    .line_number = line_num,
                });
            } else {
                try entries.append(.{
                    .full_key = try cfgMakeKey(current_section, after, allocator),
                    .value = try allocator.dupe(u8, ""),
                    .has_equals = false,
                    .line_number = line_num,
                });
            }
            continue;
        }
        if (current_section == null) continue;
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const k = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            // Use untrimmed line to preserve embedded \r in values
            const untrimmed = std.mem.trimLeft(u8, raw_line, " \t");
            const ut_eq = std.mem.indexOf(u8, untrimmed, "=") orelse eq_pos;
            var raw_value = untrimmed[ut_eq + 1 ..];
            var vbuf = std.array_list.Managed(u8).init(allocator);
            defer vbuf.deinit();
            while (true) {
                const tv = std.mem.trimRight(u8, raw_value, " \t");
                if (tv.len > 0 and tv[tv.len - 1] == '\\' and cfgIsContinuation(tv)) {
                    try cfgAppendValuePart(&vbuf, tv[0 .. tv.len - 1]);
                    raw_value = if (line_iter.next()) |nl|
                        std.mem.trim(u8, stripOneTrailingCR(nl), " \t")
                    else
                        break;
                } else {
                    try cfgAppendValuePart(&vbuf, raw_value);
                    break;
                }
            }
            try entries.append(.{
                .full_key = try cfgMakeKey(current_section, k, allocator),
                .value = try vbuf.toOwnedSlice(),
                .has_equals = true,
                .line_number = line_num,
            });
        } else {
            const cp = std.mem.indexOf(u8, trimmed, "#") orelse std.mem.indexOf(u8, trimmed, ";");
            const clean = if (cp) |c| std.mem.trimRight(u8, trimmed[0..c], " \t") else trimmed;
            if (clean.len > 0 and clean[0] != '[') {
                try entries.append(.{
                    .full_key = try cfgMakeKey(current_section, clean, allocator),
                    .value = try allocator.dupe(u8, ""),
                    .has_equals = false,
                    .line_number = line_num,
                });
            }
        }
    }
}

/// Collect entries from config content, following include.path and includeIf directives
fn collectEntriesWithIncludes(
    content: []const u8,
    source_path: []const u8,
    scope: []const u8,
    allocator: Allocator,
    platform_impl: *const platform_mod.Platform,
    all_entries: *std.array_list.Managed(CfgEntry),
    git_path_opt: ?[]const u8,
    follow_includes: bool,
) !void {
    var entries = std.array_list.Managed(CfgEntry).init(allocator);
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit();
    }
    try cfgParseEntries(content, &entries, allocator);

    for (entries.items) |e| {
        // Check for include.path
        if (follow_includes and cfgKeyMatches(e.full_key, "include.path")) {
            // Add the include.path entry itself first
            const src_path_dup_inc = try allocator.dupe(u8, source_path);
            const src_scope_dup_inc = try allocator.dupe(u8, scope);
            try all_entries.append(.{
                .full_key = try allocator.dupe(u8, e.full_key),
                .value = try allocator.dupe(u8, e.value),
                .has_equals = e.has_equals,
                .line_number = e.line_number,
                .source_path = src_path_dup_inc,
                .source_scope = src_scope_dup_inc,
            });
            // Then follow the include
            const inc_path = resolveIncludePath(e.value, source_path, allocator) catch continue;
            defer allocator.free(inc_path);
            const inc_content = platform_impl.fs.readFile(allocator, inc_path) catch continue;
            defer allocator.free(inc_content);
            const display_path = computeIncludeDisplayPath(source_path, e.value, allocator) catch inc_path;
            const needs_free_dp = !std.mem.eql(u8, display_path, inc_path);
            defer if (needs_free_dp) allocator.free(display_path);
            collectEntriesWithIncludes(inc_content, display_path, scope, allocator, platform_impl, all_entries, git_path_opt, true) catch continue;
            continue;
        }
        // Check for includeIf.*.path
        if (follow_includes and (std.mem.startsWith(u8, e.full_key, "includeif.") or std.mem.startsWith(u8, e.full_key, "includeIf."))) {
            const rest = e.full_key[10..]; // after "includeif." or "includeIf."
            if (std.mem.lastIndexOfScalar(u8, rest, '.')) |last_dot| {
                const variable = rest[last_dot + 1 ..];
                if (std.ascii.eqlIgnoreCase(variable, "path")) {
                    const condition = rest[0..last_dot];
                    // Add the includeIf entry itself
                    const src_path_dup_ii = try allocator.dupe(u8, source_path);
                    const src_scope_dup_ii = try allocator.dupe(u8, scope);
                    try all_entries.append(.{
                        .full_key = try allocator.dupe(u8, e.full_key),
                        .value = try allocator.dupe(u8, e.value),
                        .has_equals = e.has_equals,
                        .line_number = e.line_number,
                        .source_path = src_path_dup_ii,
                        .source_scope = src_scope_dup_ii,
                    });
                    // For hasconfig conditions, pass all entries from the current file
                    const use_entries: ?[]const CfgEntry = if (std.mem.startsWith(u8, condition, "hasconfig:"))
                        entries.items
                    else
                        null;
                    if (evaluateIncludeConditionEx(condition, source_path, allocator, platform_impl, git_path_opt, use_entries)) {
                        const inc_path = resolveIncludePath(e.value, source_path, allocator) catch continue;
                        defer allocator.free(inc_path);
                        const inc_content = platform_impl.fs.readFile(allocator, inc_path) catch continue;
                        defer allocator.free(inc_content);
                        const display_path = computeIncludeDisplayPath(source_path, e.value, allocator) catch inc_path;
                        const needs_free_dp = !std.mem.eql(u8, display_path, inc_path);
                        defer if (needs_free_dp) allocator.free(display_path);
                        collectEntriesWithIncludes(inc_content, display_path, scope, allocator, platform_impl, all_entries, git_path_opt, true) catch continue;
                    }
                    continue;
                }
            }
        }
        // Normal entry - add with source info
        const src_path_dup = try allocator.dupe(u8, source_path);
        const src_scope_dup = try allocator.dupe(u8, scope);
        try all_entries.append(.{
            .full_key = try allocator.dupe(u8, e.full_key),
            .value = try allocator.dupe(u8, e.value),
            .has_equals = e.has_equals,
            .line_number = e.line_number,
            .source_path = src_path_dup,
            .source_scope = src_scope_dup,
        });
    }
}

fn resolveIncludePath(path: []const u8, source_path: []const u8, allocator: Allocator) ![]u8 {
    if (path.len == 0) return error.EmptyPath;

    // Expand ~/ to HOME
    if (path[0] == '~' and path.len > 1 and path[1] == '/') {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHome;
        defer allocator.free(home);
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
    }

    // Absolute path
    if (path[0] == '/') {
        return try allocator.dupe(u8, path);
    }

    // Relative path - resolve relative to the source file's directory
    if (std.mem.lastIndexOfScalar(u8, source_path, '/')) |slash| {
        const dir = source_path[0..slash];
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, path });
    }

    return try allocator.dupe(u8, path);
}

fn computeIncludeDisplayPath(source_path: []const u8, rel_path: []const u8, allocator: Allocator) ![]u8 {
    if (rel_path.len == 0) return error.EmptyPath;
    if (rel_path[0] == '/' or (rel_path[0] == '~' and rel_path.len > 1 and rel_path[1] == '/')) {
        // For absolute and ~/ paths, use the resolved path
        return resolveIncludePath(rel_path, source_path, allocator);
    }
    // For relative paths, show as source_dir/../rel_path for display
    if (std.mem.lastIndexOfScalar(u8, source_path, '/')) |slash| {
        const dir = source_path[0..slash];
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, rel_path });
    }
    return try allocator.dupe(u8, rel_path);
}

fn evaluateIncludeCondition(condition: []const u8, source_path: []const u8, allocator: Allocator, platform_impl: *const platform_mod.Platform, git_path_opt: ?[]const u8) bool {
    return evaluateIncludeConditionEx(condition, source_path, allocator, platform_impl, git_path_opt, null);
}

fn evaluateIncludeConditionEx(condition: []const u8, source_path: []const u8, allocator: Allocator, platform_impl: *const platform_mod.Platform, git_path_opt: ?[]const u8, all_config_entries: ?[]const CfgEntry) bool {
    _ = source_path;
    _ = platform_impl;
    if (std.mem.startsWith(u8, condition, "gitdir:") or std.mem.startsWith(u8, condition, "gitdir/i:")) {
        // gitdir condition
        const gp = git_path_opt orelse return false;
        const pattern = if (std.mem.startsWith(u8, condition, "gitdir/i:"))
            condition["gitdir/i:".len..]
        else
            condition["gitdir:".len..];
        // Expand ~/ in pattern
        var expanded_pattern: []u8 = undefined;
        if (pattern.len > 0 and pattern[0] == '~' and pattern.len > 1 and pattern[1] == '/') {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch return false;
            defer allocator.free(home);
            expanded_pattern = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, pattern[1..] }) catch return false;
        } else {
            expanded_pattern = allocator.dupe(u8, pattern) catch return false;
        }
        defer allocator.free(expanded_pattern);
        // Simple glob match
        return simpleGlobMatch(gp, expanded_pattern);
    }
    if (std.mem.startsWith(u8, condition, "onbranch:")) {
        // onbranch condition - check current branch
        return false; // TODO
    }
    if (std.mem.startsWith(u8, condition, "hasconfig:remote.")) {
        // hasconfig:remote.*.url:PATTERN
        const hc = condition["hasconfig:".len..];
        // hc = "remote.*.url:PATTERN"
        if (std.mem.indexOf(u8, hc, ":")) |colon| {
            const key_glob = hc[0..colon]; // "remote.*.url"
            const url_pattern = hc[colon + 1 ..]; // the URL pattern
            if (all_config_entries) |entries| {
                for (entries) |e| {
                    // Check if entry key matches the glob (e.g., remote.*.url)
                    if (cfgKeyMatchesGlob(e.full_key, key_glob)) {
                        // Check if entry value matches the URL pattern
                        if (simpleGlobMatch(e.value, url_pattern)) return true;
                    }
                }
            }
        }
        return false;
    }
    return false;
}

fn simpleGlobMatch(text: []const u8, pattern: []const u8) bool {
    return simpleGlobMatchImpl(text, 0, pattern, 0);
}

fn simpleGlobMatchImpl(text: []const u8, tpos: usize, pat: []const u8, ppos: usize) bool {
    var tp = tpos;
    var pp = ppos;
    while (pp < pat.len) {
        if (pat[pp] == '*') {
            if (pp + 1 < pat.len and pat[pp + 1] == '*') {
                // ** matches everything including /
                pp += 2;
                if (pp < pat.len and pat[pp] == '/') pp += 1; // skip trailing /
                if (pp >= pat.len) return true;
                while (tp <= text.len) {
                    if (simpleGlobMatchImpl(text, tp, pat, pp)) return true;
                    if (tp >= text.len) break;
                    tp += 1;
                }
                return false;
            }
            pp += 1;
            // * matches everything except /
            while (tp <= text.len) {
                if (simpleGlobMatchImpl(text, tp, pat, pp)) return true;
                if (tp >= text.len or text[tp] == '/') break;
                tp += 1;
            }
            return false;
        }
        if (tp >= text.len) return false;
        if (pat[pp] == '?') {
            if (text[tp] == '/') return false;
            tp += 1;
            pp += 1;
        } else if (pat[pp] == text[tp]) {
            tp += 1;
            pp += 1;
        } else {
            return false;
        }
    }
    return tp == text.len;
}

fn cfgMakeKey(section: ?[]const u8, variable: []const u8, allocator: Allocator) ![]u8 {
    const sec = section orelse return try allocator.dupe(u8, variable);
    const full = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sec, variable });
    const last_dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    for (full[last_dot + 1 ..]) |*c| c.* = std.ascii.toLower(c.*);
    return full;
}

fn cfgParseSectionToKey(header: []const u8, allocator: Allocator) ![]u8 {
    const close = std.mem.indexOf(u8, header, "]") orelse return try allocator.dupe(u8, "");
    const inner = header[1..close];
    if (std.mem.indexOf(u8, inner, "\"")) |q_start| {
        const section = std.mem.trim(u8, inner[0..q_start], " \t");
        var rest = inner[q_start + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, rest, '"')) |q_end| rest = rest[0..q_end];
        var sub = std.array_list.Managed(u8).init(allocator);
        defer sub.deinit();
        var si: usize = 0;
        while (si < rest.len) : (si += 1) {
            if (rest[si] == '\\' and si + 1 < rest.len) {
                si += 1;
                try sub.append(rest[si]);
            } else try sub.append(rest[si]);
        }
        const sec_lower = try allocator.dupe(u8, section);
        defer allocator.free(sec_lower);
        for (sec_lower) |*c| c.* = std.ascii.toLower(c.*);
        return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sec_lower, sub.items });
    }
    // Old-style [section.sub] (no quotes)
    const section = std.mem.trim(u8, inner, " \t");
    if (std.mem.indexOf(u8, section, ".")) |dot| {
        const sec_lower = try allocator.dupe(u8, section[0..dot]);
        defer allocator.free(sec_lower);
        for (sec_lower) |*c| c.* = std.ascii.toLower(c.*);
        const sub_lower = try allocator.dupe(u8, section[dot + 1 ..]);
        defer allocator.free(sub_lower);
        for (sub_lower) |*c| c.* = std.ascii.toLower(c.*);
        return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sec_lower, sub_lower });
    }
    const lower = try allocator.dupe(u8, section);
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    return lower;
}

fn cfgQuoteValue(value: []const u8, allocator: Allocator) ![]u8 {
    var needs_quoting = false;
    if (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) needs_quoting = true;
    if (value.len > 0 and (value[value.len - 1] == ' ' or value[value.len - 1] == '\t')) needs_quoting = true;
    for (value) |c| {
        if (c == '#' or c == ';' or c == '\n' or c == '\\' or c == '"') {
            needs_quoting = true;
            break;
        }
    }
    if (!needs_quoting) return try allocator.dupe(u8, value);
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try buf.append('"');
    for (value) |c| {
        switch (c) {
            '\n' => try buf.appendSlice("\\n"),
            '\t' => try buf.appendSlice("\\t"),
            '\\' => try buf.appendSlice("\\\\"),
            '"' => try buf.appendSlice("\\\""),
            else => try buf.append(c),
        }
    }
    try buf.append('"');
    return try buf.toOwnedSlice();
}

fn cfgIsContinuation(tv: []const u8) bool {
    var in_quotes = false;
    var ii: usize = 0;
    while (ii < tv.len) : (ii += 1) {
        const c = tv[ii];
        if (c == '\\' and ii + 1 < tv.len) {
            ii += 1;
            continue;
        }
        if (c == '"') in_quotes = !in_quotes;
        if (!in_quotes and (c == '#' or c == ';')) return false;
    }
    return true;
}

fn cfgEffectiveValue(e: CfgEntry) []const u8 {
    if (!e.has_equals and e.value.len == 0) return "true";
    return e.value;
}

fn cfgValueMatchesPattern(val: []const u8, pattern: []const u8, fixed_val: bool) bool {
    const negated = pattern.len > 0 and pattern[0] == '!';
    const actual = if (negated) pattern[1..] else pattern;
    const m = if (fixed_val) std.mem.eql(u8, val, actual) else simpleRegexMatch(val, actual);
    return if (negated) !m else m;
}

fn cfgAppendValuePart(buf: *std.array_list.Managed(u8), raw: []const u8) !void {
    const trimmed = std.mem.trimLeft(u8, raw, " \t");
    var in_quotes = false;
    var last_quoted_end: usize = 0;
    var ii: usize = 0;
    while (ii < trimmed.len) : (ii += 1) {
        const c = trimmed[ii];
        if (c == '\\' and ii + 1 < trimmed.len) {
            ii += 1;
            switch (trimmed[ii]) {
                'n' => try buf.append('\n'),
                't' => try buf.append('\t'),
                'b' => try buf.append(0x08),
                '"' => try buf.append('"'),
                '\\' => try buf.append('\\'),
                else => {
                    try buf.append('\\');
                    try buf.append(trimmed[ii]);
                },
            }
            if (in_quotes) last_quoted_end = buf.items.len;
        } else if (c == '"') {
            if (in_quotes) last_quoted_end = buf.items.len;
            in_quotes = !in_quotes;
        } else if (!in_quotes and (c == '#' or c == ';')) {
            break;
        } else {
            try buf.append(c);
            if (in_quotes) last_quoted_end = buf.items.len;
        }
    }
    if (!in_quotes) {
        while (buf.items.len > last_quoted_end and
            (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t'))
            _ = buf.pop();
    }
}

pub fn cfgKeyMatches(full_key: []const u8, query: []const u8) bool {
    const q_last = std.mem.lastIndexOfScalar(u8, query, '.') orelse return false;
    const k_last = std.mem.lastIndexOfScalar(u8, full_key, '.') orelse return false;
    if (!std.ascii.eqlIgnoreCase(full_key[k_last + 1 ..], query[q_last + 1 ..])) return false;
    const q_prefix = query[0..q_last];
    const k_prefix = full_key[0..k_last];
    const q_first = std.mem.indexOfScalar(u8, q_prefix, '.');
    const k_first = std.mem.indexOfScalar(u8, k_prefix, '.');
    if (q_first != null and k_first != null) {
        if (!std.ascii.eqlIgnoreCase(q_prefix[0..q_first.?], k_prefix[0..k_first.?])) return false;
        return std.mem.eql(u8, k_prefix[k_first.? + 1 ..], q_prefix[q_first.? + 1 ..]);
    }
    if (q_first == null and k_first == null) return std.ascii.eqlIgnoreCase(k_prefix, q_prefix);
    return false;
}

fn cfgAppendOrigin(out: *std.array_list.Managed(u8), source_path: []const u8) !void {
    if (std.mem.eql(u8, source_path, "standard input")) {
        try out.appendSlice("standard input:");
    } else if (std.mem.eql(u8, source_path, "command line") or source_path.len == 0) {
        try out.appendSlice("command line:");
    } else if (std.mem.startsWith(u8, source_path, "blob:")) {
        try out.appendSlice(source_path);
    } else {
        var needs_quote = false;
        for (source_path) |c| {
            if (c == '"' or c == '\t' or c == '\n') {
                needs_quote = true;
                break;
            }
        }
        if (needs_quote) {
            try out.appendSlice("file:\"");
            for (source_path) |c| {
                if (c == '"') {
                    try out.appendSlice("\\\"");
                } else try out.append(c);
            }
            try out.append('"');
        } else {
            try out.appendSlice("file:");
            try out.appendSlice(source_path);
        }
    }
}

fn cfgValidateColor(color: []const u8) bool {
    if (color.len == 0) return true;
    const valid = [_][]const u8{ "normal", "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "default", "reset", "bold", "dim", "ul", "blink", "reverse", "italic", "strike", "nobold", "nodim", "noul", "noblink", "noreverse", "noitalic", "nostrike", "no-bold", "no-dim", "no-ul", "no-blink", "no-reverse", "no-italic", "no-strike", "brightred", "brightgreen", "brightyellow", "brightblue", "brightmagenta", "brightcyan", "brightwhite" };
    var parts = std.mem.splitSequence(u8, color, " ");
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        var found = false;
        for (valid) |vc| {
            if (std.ascii.eqlIgnoreCase(part, vc)) {
                found = true;
                break;
            }
        }
        if (!found) {
            if (part[0] == '#' and part.len == 7) {
                found = true;
            } else if (std.fmt.parseInt(u8, part, 10)) |_| {
                found = true;
            } else |_| {}
        }
        if (!found) return false;
    }
    return true;
}

fn cfgFormatType(value: []const u8, config_type: ConfigType, allocator: Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    switch (config_type) {
        .bool_type => {
            const lower = try std.ascii.allocLowerString(allocator, value);
            defer allocator.free(lower);
            if (value.len == 0) return try allocator.dupe(u8, "false");
            if (std.mem.eql(u8, lower, "true") or std.mem.eql(u8, lower, "yes") or std.mem.eql(u8, lower, "on") or std.mem.eql(u8, lower, "1"))
                return try allocator.dupe(u8, "true");
            if (std.mem.eql(u8, lower, "false") or std.mem.eql(u8, lower, "no") or std.mem.eql(u8, lower, "off") or std.mem.eql(u8, lower, "0"))
                return try allocator.dupe(u8, "false");
            const tbm = std.mem.trim(u8, value, " \t");
            if (std.fmt.parseInt(i64, tbm, 10)) |num|
                return try allocator.dupe(u8, if (num != 0) "true" else "false")
            else |_| {
                if (tbm.len > 1) {
                    const l = tbm[tbm.len - 1];
                    if (l == 'k' or l == 'K' or l == 'm' or l == 'M' or l == 'g' or l == 'G') {
                        if (std.fmt.parseInt(i64, tbm[0 .. tbm.len - 1], 10)) |n|
                            return try allocator.dupe(u8, if (n != 0) "true" else "false")
                        else |_| {}
                    }
                }
            }
            const em = try std.fmt.allocPrint(allocator, "fatal: bad boolean config value '{s}'\n", .{value});
            defer allocator.free(em);
            try platform_impl.writeStderr(em);
            std.process.exit(128);
        },
        .int_type => {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len == 0) {
                try platform_impl.writeStderr("fatal: bad numeric config value\n");
                std.process.exit(128);
            }
            const last = trimmed[trimmed.len - 1];
            if (last == 'k' or last == 'K' or last == 'm' or last == 'M' or last == 'g' or last == 'G') {
                if (std.fmt.parseInt(i64, trimmed[0 .. trimmed.len - 1], 10)) |num| {
                    const mult: i64 = switch (last) {
                        'k', 'K' => 1024,
                        'm', 'M' => 1048576,
                        'g', 'G' => 1073741824,
                        else => 1,
                    };
                    return try std.fmt.allocPrint(allocator, "{d}", .{num * mult});
                } else |_| {}
            }
            if (std.fmt.parseInt(i64, trimmed, 10)) |n| return try std.fmt.allocPrint(allocator, "{d}", .{n}) else |_| {}
            const em = try std.fmt.allocPrint(allocator, "fatal: bad numeric config value '{s}'\n", .{value});
            defer allocator.free(em);
            try platform_impl.writeStderr(em);
            std.process.exit(128);
        },
        .bool_or_int => {
            const lower = try std.ascii.allocLowerString(allocator, value);
            defer allocator.free(lower);
            if (value.len == 0) return try allocator.dupe(u8, "false");
            if (std.mem.eql(u8, lower, "true") or std.mem.eql(u8, lower, "yes") or std.mem.eql(u8, lower, "on"))
                return try allocator.dupe(u8, "true");
            if (std.mem.eql(u8, lower, "false") or std.mem.eql(u8, lower, "no") or std.mem.eql(u8, lower, "off"))
                return try allocator.dupe(u8, "false");
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len > 0) {
                const l = trimmed[trimmed.len - 1];
                if (l == 'k' or l == 'K' or l == 'm' or l == 'M' or l == 'g' or l == 'G') {
                    if (std.fmt.parseInt(i64, trimmed[0 .. trimmed.len - 1], 10)) |num| {
                        const mult: i64 = switch (l) {
                            'k', 'K' => 1024,
                            'm', 'M' => 1048576,
                            'g', 'G' => 1073741824,
                            else => 1,
                        };
                        return try std.fmt.allocPrint(allocator, "{d}", .{num * mult});
                    } else |_| {}
                }
                if (std.fmt.parseInt(i64, trimmed, 10)) |n| return try std.fmt.allocPrint(allocator, "{d}", .{n}) else |_| {}
            }
            return try allocator.dupe(u8, value);
        },
        .path_type => {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len == 0) {
                try platform_impl.writeStderr("fatal: no path for 'path' type\n");
                std.process.exit(128);
            }
            if (trimmed[0] == '~' and (trimmed.len == 1 or trimmed[1] == '/')) {
                const h = std.process.getEnvVarOwned(allocator, "HOME") catch {
                    try platform_impl.writeStderr("fatal: failed to expand user dir in: '~/'\n");
                    std.process.exit(128);
                };
                defer allocator.free(h);
                if (trimmed.len == 1) return try allocator.dupe(u8, h);
                return try std.fmt.allocPrint(allocator, "{s}{s}", .{ h, trimmed[1..] });
            }
            return try allocator.dupe(u8, trimmed);
        },
        .expiry_date => {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (std.mem.eql(u8, trimmed, "never") or std.mem.eql(u8, trimmed, "false")) return try allocator.dupe(u8, "0");
            if (std.mem.eql(u8, trimmed, "now")) return try std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
            if (std.fmt.parseInt(i64, trimmed, 10)) |n| return try std.fmt.allocPrint(allocator, "{d}", .{n}) else |_| {}
            // Try date parsing
            if (cfgParseDate(trimmed, allocator)) |ts| return ts;
            const em = try std.fmt.allocPrint(allocator, "fatal: '{s}' is not a valid timestamp\n", .{value});
            defer allocator.free(em);
            try platform_impl.writeStderr(em);
            std.process.exit(128);
        },
        .color_type => {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (cfgValidateColor(trimmed)) return try cfgColorToAnsiAlloc(trimmed, allocator);
            const em = try std.fmt.allocPrint(allocator, "error: invalid color value: {s}\n", .{value});
            defer allocator.free(em);
            try platform_impl.writeStderr(em);
            std.process.exit(1);
        },
        .none => return try allocator.dupe(u8, value),
    }
}

fn cfgFormatTypeWithContext(value: []const u8, config_type: ConfigType, key_name: ?[]const u8, source_path: ?[]const u8, allocator: Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    switch (config_type) {
        .bool_type => {
            const r = cfgFormatTypeSilent(value, config_type, allocator) catch {
                if (key_name) |kn| {
                    const em = try std.fmt.allocPrint(allocator, "fatal: bad boolean config value '{s}' for '{s}'\n", .{ value, kn });
                    defer allocator.free(em);
                    try platform_impl.writeStderr(em);
                } else {
                    const em = try std.fmt.allocPrint(allocator, "fatal: bad boolean config value '{s}'\n", .{value});
                    defer allocator.free(em);
                    try platform_impl.writeStderr(em);
                }
                std.process.exit(128);
            };
            return r;
        },
        .int_type => {
            const r = cfgFormatTypeSilent(value, config_type, allocator) catch {
                if (key_name) |kn| {
                    if (source_path) |sp| {
                        const em = try std.fmt.allocPrint(allocator, "fatal: bad numeric config value '{s}' for '{s}' in file {s}: invalid unit\n", .{ value, kn, sp });
                        defer allocator.free(em);
                        try platform_impl.writeStderr(em);
                    } else {
                        const em = try std.fmt.allocPrint(allocator, "fatal: bad numeric config value '{s}' for '{s}': invalid unit\n", .{ value, kn });
                        defer allocator.free(em);
                        try platform_impl.writeStderr(em);
                    }
                } else {
                    const em = try std.fmt.allocPrint(allocator, "fatal: bad numeric config value '{s}'\n", .{value});
                    defer allocator.free(em);
                    try platform_impl.writeStderr(em);
                }
                std.process.exit(128);
            };
            return r;
        },
        .path_type => {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len == 0) return try allocator.dupe(u8, "");
            if (trimmed[0] == '~' and (trimmed.len == 1 or trimmed[1] == '/')) {
                const h = std.process.getEnvVarOwned(allocator, "HOME") catch {
                    const em = try std.fmt.allocPrint(allocator, "fatal: failed to expand user dir in: '{s}'\n", .{trimmed});
                    defer allocator.free(em);
                    try platform_impl.writeStderr(em);
                    std.process.exit(128);
                };
                defer allocator.free(h);
                if (trimmed.len == 1) return try allocator.dupe(u8, h);
                return try std.fmt.allocPrint(allocator, "{s}{s}", .{ h, trimmed[1..] });
            }
            return try allocator.dupe(u8, trimmed);
        },
        else => return cfgFormatType(value, config_type, allocator, platform_impl),
    }
}

fn cfgFormatTypeSilent(value: []const u8, config_type: ConfigType, allocator: Allocator) ![]u8 {
    switch (config_type) {
        .bool_type => {
            const lower = try std.ascii.allocLowerString(allocator, value);
            defer allocator.free(lower);
            if (value.len == 0) return try allocator.dupe(u8, "false");
            if (std.mem.eql(u8, lower, "true") or std.mem.eql(u8, lower, "yes") or std.mem.eql(u8, lower, "on") or std.mem.eql(u8, lower, "1"))
                return try allocator.dupe(u8, "true");
            if (std.mem.eql(u8, lower, "false") or std.mem.eql(u8, lower, "no") or std.mem.eql(u8, lower, "off") or std.mem.eql(u8, lower, "0"))
                return try allocator.dupe(u8, "false");
            const tb = std.mem.trim(u8, value, " \t");
            if (std.fmt.parseInt(i64, tb, 10)) |num|
                return try allocator.dupe(u8, if (num != 0) "true" else "false")
            else |_| {
                if (tb.len > 1) {
                    const l = tb[tb.len - 1];
                    if (l == 'k' or l == 'K' or l == 'm' or l == 'M' or l == 'g' or l == 'G') {
                        if (std.fmt.parseInt(i64, tb[0 .. tb.len - 1], 10)) |n|
                            return try allocator.dupe(u8, if (n != 0) "true" else "false")
                        else |_| {}
                    }
                }
            }
            return error.InvalidValue;
        },
        .int_type => {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len == 0) return error.InvalidValue;
            if (!std.ascii.isDigit(trimmed[0]) and trimmed[0] != '-' and trimmed[0] != '+') return error.InvalidValue;
            const last = trimmed[trimmed.len - 1];
            if (last == 'k' or last == 'K' or last == 'm' or last == 'M' or last == 'g' or last == 'G') {
                if (std.fmt.parseInt(i64, trimmed[0 .. trimmed.len - 1], 10)) |num| {
                    const mult: i64 = switch (last) {
                        'k', 'K' => 1024,
                        'm', 'M' => 1048576,
                        'g', 'G' => 1073741824,
                        else => 1,
                    };
                    return try std.fmt.allocPrint(allocator, "{d}", .{num * mult});
                } else |_| {}
            }
            if (std.fmt.parseInt(i64, trimmed, 10)) |n| return try std.fmt.allocPrint(allocator, "{d}", .{n}) else |_| {}
            return error.InvalidValue;
        },
        .bool_or_int => {
            const lower = try std.ascii.allocLowerString(allocator, value);
            defer allocator.free(lower);
            if (value.len == 0) return try allocator.dupe(u8, "false");
            if (std.mem.eql(u8, lower, "true") or std.mem.eql(u8, lower, "yes") or std.mem.eql(u8, lower, "on"))
                return try allocator.dupe(u8, "true");
            if (std.mem.eql(u8, lower, "false") or std.mem.eql(u8, lower, "no") or std.mem.eql(u8, lower, "off"))
                return try allocator.dupe(u8, "false");
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len > 0) {
                const l = trimmed[trimmed.len - 1];
                if (l == 'k' or l == 'K' or l == 'm' or l == 'M' or l == 'g' or l == 'G') {
                    if (std.fmt.parseInt(i64, trimmed[0 .. trimmed.len - 1], 10)) |num| {
                        const mult: i64 = switch (l) {
                            'k', 'K' => 1024,
                            'm', 'M' => 1048576,
                            'g', 'G' => 1073741824,
                            else => 1,
                        };
                        return try std.fmt.allocPrint(allocator, "{d}", .{num * mult});
                    } else |_| {}
                }
                if (std.fmt.parseInt(i64, trimmed, 10)) |n| return try std.fmt.allocPrint(allocator, "{d}", .{n}) else |_| {}
            }
            return error.InvalidValue;
        },
        .path_type => return try allocator.dupe(u8, std.mem.trim(u8, value, " \t")),
        .expiry_date => {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (std.mem.eql(u8, trimmed, "never") or std.mem.eql(u8, trimmed, "false")) return try allocator.dupe(u8, "0");
            if (std.mem.eql(u8, trimmed, "now")) return try std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
            if (std.fmt.parseInt(i64, trimmed, 10)) |n| return try std.fmt.allocPrint(allocator, "{d}", .{n}) else |_| {}
            if (cfgParseDate(trimmed, allocator)) |ts| return ts;
            return error.InvalidValue;
        },
        .color_type => {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (cfgValidateColor(trimmed)) return try cfgColorToAnsiAlloc(trimmed, allocator);
            return error.InvalidValue;
        },
        .none => return try allocator.dupe(u8, value),
    }
}

fn cfgParseDate(date_str: []const u8, allocator: Allocator) ?[]u8 {
    // Normalize: replace dots with spaces (git's approxidate does this)
    var normalized = allocator.alloc(u8, date_str.len) catch return null;
    defer allocator.free(normalized);
    for (date_str, 0..) |c, idx| {
        normalized[idx] = if (c == '.') ' ' else c;
    }

    // Check if this looks like a relative date (contains words like weeks, days, etc.)
    if (cfgIsRelativeDate(normalized)) {
        // Git's approxidate treats relative references as "ago" by default
        // Convert "3 weeks 5 days 00:00" to "3 weeks ago 5 days ago 00:00" for GNU date
        if (cfgConvertRelativeDate(normalized, allocator)) |converted| {
            defer allocator.free(converted);
            if (cfgParseDateWith(converted, allocator)) |r| return r;
        }
    }

    // Try the normalized string directly
    if (cfgParseDateWith(normalized, allocator)) |r| return r;
    // Try the original string
    if (cfgParseDateWith(date_str, allocator)) |r| return r;
    return null;
}

fn cfgIsRelativeDate(s: []const u8) bool {
    const rel_words = [_][]const u8{ "second", "minute", "hour", "day", "week", "month", "year", "seconds", "minutes", "hours", "days", "weeks", "months", "years" };
    var iter = std.mem.tokenizeAny(u8, s, " \t");
    while (iter.next()) |word| {
        var lower_buf: [20]u8 = undefined;
        if (word.len > lower_buf.len) continue;
        for (word, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        const lower = lower_buf[0..word.len];
        for (rel_words) |rw| {
            if (std.mem.eql(u8, lower, rw)) return true;
        }
    }
    return false;
}

fn cfgConvertRelativeDate(s: []const u8, allocator: Allocator) ?[]u8 {
    // Convert "3 weeks 5 days 00:00" -> "3 weeks ago 5 days ago 00:00"
    // by inserting "ago" after each relative unit
    const rel_units = [_][]const u8{ "second", "minute", "hour", "day", "week", "month", "year", "seconds", "minutes", "hours", "days", "weeks", "months", "years" };
    var result = std.array_list.Managed(u8).init(allocator);
    var iter = std.mem.tokenizeAny(u8, s, " \t");
    var has_ago = false;
    // Check if "ago" is already present
    var check_iter = std.mem.tokenizeAny(u8, s, " \t");
    while (check_iter.next()) |w| {
        if (std.mem.eql(u8, w, "ago")) { has_ago = true; break; }
    }
    if (has_ago) return null; // already has "ago", let date handle it

    while (iter.next()) |word| {
        if (result.items.len > 0) result.append(' ') catch return null;
        result.appendSlice(word) catch return null;
        // Check if this word is a relative unit
        var lower_buf: [20]u8 = undefined;
        if (word.len <= lower_buf.len) {
            for (word, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
            const lower = lower_buf[0..word.len];
            for (rel_units) |rw| {
                if (std.mem.eql(u8, lower, rw)) {
                    result.appendSlice(" ago") catch return null;
                    break;
                }
            }
        }
    }
    return result.toOwnedSlice() catch null;
}

fn cfgParseDateWith(date_str: []const u8, allocator: Allocator) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "date", "-d", date_str, "+%s" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term.Exited != 0) return null;
    const trimmed = std.mem.trimRight(u8, result.stdout, " \t\n\r");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

fn cfgColorToAnsiAlloc(color: []const u8, allocator: Allocator) ![]u8 {
    if (color.len == 0) return try allocator.dupe(u8, "");
    // Use the colorToAnsiAlloc function
    return colorToAnsiAlloc(allocator, color);
}

fn cfgLookup(sources: []const ConfigSource, key: []const u8, allocator: Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    var result: ?[]u8 = null;
    for (sources) |source| {
        const content = cfgReadSource(source.path, allocator, platform_impl) orelse continue;
        defer allocator.free(content);
        var entries = std.array_list.Managed(CfgEntry).init(allocator);
        defer {
            for (entries.items) |*e| e.deinit(allocator);
            entries.deinit();
        }
        cfgParseEntries(content, &entries, allocator) catch continue;
        for (entries.items) |e| {
            if (cfgKeyMatches(e.full_key, key)) {
                if (result) |prev| allocator.free(prev);
                result = try allocator.dupe(u8, e.value);
            }
        }
    }
    if (main_mod.getConfigOverride(key)) |ov| {
        if (result) |prev| allocator.free(prev);
        return try allocator.dupe(u8, ov);
    }
    return result orelse error.KeyNotFound;
}

fn cfgIsValidKey(key: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, key, '.') orelse return false;
    if (dot == 0) return false;
    if (!std.ascii.isAlphanumeric(key[0])) return false;
    for (key[0..dot]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    const last_dot = std.mem.lastIndexOfScalar(u8, key, '.') orelse return false;
    if (last_dot + 1 >= key.len) return false;
    const vn = key[last_dot + 1 ..];
    if (!std.ascii.isAlphabetic(vn[0])) return false;
    for (vn) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

fn cfgIsValidSectionName(name: []const u8) bool {
    if (name.len == 0) return false;
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const section = if (dot) |d| name[0..d] else name;
    if (section.len == 0) return false;
    if (!std.ascii.isAlphabetic(section[0])) return false;
    for (section) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

fn cfgFormatComment(comment_raw: ?[]const u8, allocator: Allocator) ![]u8 {
    if (comment_raw) |c| {
        if (c.len > 0 and c[0] == '#') return try std.fmt.allocPrint(allocator, " {s}", .{c});
        if (c.len > 0 and c[0] == '\t') return try allocator.dupe(u8, c);
        return try std.fmt.allocPrint(allocator, " # {s}", .{c});
    }
    return try allocator.dupe(u8, "");
}

fn cfgParseKey(key: []const u8, allocator: Allocator) !CfgParsedKey {
    const last_dot = std.mem.lastIndexOfScalar(u8, key, '.') orelse return error.InvalidKey;
    const variable = key[last_dot + 1 ..];
    const prefix = key[0..last_dot];
    if (std.mem.indexOfScalar(u8, prefix, '.')) |first_dot| {
        return .{
            .section = try allocator.dupe(u8, prefix[0..first_dot]),
            .subsection = try allocator.dupe(u8, prefix[first_dot + 1 ..]),
            .variable = try allocator.dupe(u8, variable),
        };
    }
    return .{ .section = try allocator.dupe(u8, prefix), .subsection = null, .variable = try allocator.dupe(u8, variable) };
}

fn cfgSectionMatches(file_section: []const u8, file_subsection: ?[]const u8, parsed: CfgParsedKey) bool {
    return cfgSectionMatchesEx(file_section, file_subsection, false, parsed);
}

fn cfgSectionMatchesEx(file_section: []const u8, file_subsection: ?[]const u8, is_old_style: bool, parsed: CfgParsedKey) bool {
    if (!std.ascii.eqlIgnoreCase(file_section, parsed.section)) return false;
    if (parsed.subsection) |ps| {
        if (file_subsection) |fs| {
            // For new-style [section "subsection"], subsection comparison is case-sensitive.
            // For old-style [section.subsection], subsection comparison is case-insensitive.
            if (is_old_style) return std.ascii.eqlIgnoreCase(fs, ps);
            return std.mem.eql(u8, fs, ps);
        }
        return false;
    }
    return file_subsection == null;
}

fn cfgSetValue(cfg_path: []const u8, key: []const u8, value: []const u8, do_add: bool, replace_all: bool, value_regex: ?[]const u8, fixed_val: bool, comment: ?[]const u8, allocator: Allocator, platform_impl: *const platform_mod.Platform) !void {
    const pk = cfgParseKey(key, allocator) catch {
        try platform_impl.writeStderr("error: key does not contain a section\n");
        std.process.exit(2);
    };
    defer allocator.free(pk.section);
    defer if (pk.subsection) |s| allocator.free(s);
    defer allocator.free(pk.variable);

    const content = platform_impl.fs.readFile(allocator, cfg_path) catch |err| switch (err) {
        error.FileNotFound => {
            const cs = try cfgFormatComment(comment, allocator);
            defer allocator.free(cs);
            var out = std.array_list.Managed(u8).init(allocator);
            defer out.deinit();
            const qv = try cfgQuoteValue(value, allocator);
            defer allocator.free(qv);
            if (pk.subsection) |sub| {
                try out.writer().print("[{s} \"{s}\"]\n", .{ pk.section, sub });
            } else {
                try out.writer().print("[{s}]\n", .{pk.section});
            }
            try out.writer().print("\t{s} = {s}{s}\n", .{ pk.variable, qv, cs });
            try platform_impl.fs.writeFile(cfg_path, out.items);
            return;
        },
        else => return err,
    };
    defer allocator.free(content);

    const LI = struct { start: usize, end: usize, cont_end: usize, is_key: bool, regex_ok: bool, inline_on_header: bool };
    var infos = std.array_list.Managed(LI).init(allocator);
    defer infos.deinit();

    var cur_sec: ?[]u8 = null;
    var cur_sub: ?[]u8 = null;
    var is_old_style_sec = false;
    defer if (cur_sec) |s| allocator.free(s);
    defer if (cur_sub) |s| allocator.free(s);
    var in_target = false;
    var in_section_for_add = false;
    var last_target_end: usize = 0;
    var section_found = false;

    var pos: usize = 0;
    while (pos < content.len) {
        const ls = pos;
        const nl = std.mem.indexOfPos(u8, content, pos, "\n") orelse content.len;
        const line = content[pos..nl];
        const le = if (nl < content.len) nl + 1 else nl;
        pos = le;
        const trimmed = std.mem.trim(u8, std.mem.trimRight(u8, line, "\r"), " \t");

        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (cur_sec) |s| allocator.free(s);
            if (cur_sub) |s| allocator.free(s);
            cur_sec = null;
            cur_sub = null;
            is_old_style_sec = false;
            const close = std.mem.indexOf(u8, trimmed, "]");
            if (close) |cl| {
                const inner = trimmed[1..cl];
                if (std.mem.indexOf(u8, inner, "\"")) |q| {
                    cur_sec = try allocator.dupe(u8, std.mem.trim(u8, inner[0..q], " \t"));
                    var r = inner[q + 1 ..];
                    if (std.mem.lastIndexOfScalar(u8, r, '"')) |q2| r = r[0..q2];
                    var sb = std.array_list.Managed(u8).init(allocator);
                    defer sb.deinit();
                    var si: usize = 0;
                    while (si < r.len) : (si += 1) {
                        if (r[si] == '\\' and si + 1 < r.len) {
                            si += 1;
                            try sb.append(r[si]);
                        } else try sb.append(r[si]);
                    }
                    cur_sub = try sb.toOwnedSlice();
                } else if (std.mem.indexOf(u8, inner, ".")) |d| {
                    cur_sec = try allocator.dupe(u8, std.mem.trim(u8, inner[0..d], " \t"));
                    cur_sub = try allocator.dupe(u8, inner[d + 1 ..]);
                    is_old_style_sec = true;
                } else {
                    cur_sec = try allocator.dupe(u8, std.mem.trim(u8, inner, " \t"));
                }
            }
            // For section finding (where to add new entries), use case-insensitive for old-style
            in_section_for_add = if (cur_sec) |cs| cfgSectionMatchesEx(cs, cur_sub, is_old_style_sec, pk) else false;
            if (in_section_for_add) section_found = true;
            // For variable matching (replace existing keys), use case-sensitive with lowered old-style subsection
            if (is_old_style_sec and cur_sub != null) {
                // Compare lowered subsection with key's subsection (case-sensitive)
                const matches_exact = std.ascii.eqlIgnoreCase(cur_sec.?, pk.section);
                if (matches_exact) {
                    if (pk.subsection) |ps| {
                        // Old-style: lowercase file subsection and compare case-sensitively
                        var has_match = true;
                        if (cur_sub.?.len != ps.len) {
                            has_match = false;
                        } else {
                            for (cur_sub.?, 0..) |c, ci| {
                                if (std.ascii.toLower(c) != ps[ci]) {
                                    has_match = false;
                                    break;
                                }
                            }
                        }
                        in_target = has_match;
                    } else in_target = false;
                } else in_target = false;
            } else {
                in_target = in_section_for_add;
            }
            // Check for inline key=value or boolean key after ]
            if (in_target and close != null) {
                const after_bracket = std.mem.trim(u8, trimmed[close.? + 1 ..], " \t");
                if (after_bracket.len > 0 and after_bracket[0] != '#' and after_bracket[0] != ';') {
                    if (std.mem.indexOf(u8, after_bracket, "=")) |aeq| {
                        const ak = std.mem.trim(u8, after_bracket[0..aeq], " \t");
                        if (std.ascii.eqlIgnoreCase(ak, pk.variable)) {
                            var vbuf2 = std.array_list.Managed(u8).init(allocator);
                            defer vbuf2.deinit();
                            cfgAppendValuePart(&vbuf2, after_bracket[aeq + 1 ..]) catch {};
                            var rok2 = true;
                            if (value_regex) |vr| {
                                const neg2 = vr.len > 0 and vr[0] == '!';
                                const act2 = if (neg2) vr[1..] else vr;
                                const m2 = if (fixed_val) std.mem.eql(u8, vbuf2.items, act2) else simpleRegexMatch(vbuf2.items, act2);
                                rok2 = if (neg2) !m2 else m2;
                            }
                            try infos.append(.{ .start = ls, .end = le, .cont_end = le, .is_key = true, .regex_ok = rok2, .inline_on_header = true });
                            last_target_end = le;
                            continue;
                        }
                    } else {
                        const inline_key = after_bracket;
                        if (std.ascii.eqlIgnoreCase(inline_key, pk.variable)) {
                            var rok2 = true;
                            if (value_regex) |vr| {
                                const neg2 = vr.len > 0 and vr[0] == '!';
                                const act2 = if (neg2) vr[1..] else vr;
                                const m2 = if (fixed_val) std.mem.eql(u8, "", act2) else simpleRegexMatch("", act2);
                                rok2 = if (neg2) !m2 else m2;
                            }
                            try infos.append(.{ .start = ls, .end = le, .cont_end = le, .is_key = true, .regex_ok = rok2, .inline_on_header = true });
                            last_target_end = le;
                            continue;
                        }
                    }
                }
            }
            try infos.append(.{ .start = ls, .end = le, .cont_end = le, .is_key = false, .regex_ok = false, .inline_on_header = false });
            if (in_section_for_add) last_target_end = le;
            continue;
        }

        if (in_target and trimmed.len > 0 and trimmed[0] != '#' and trimmed[0] != ';') {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
                const k = std.mem.trim(u8, trimmed[0..eq], " \t");
                if (std.ascii.eqlIgnoreCase(k, pk.variable)) {
                    var ce = le;
                    const raw_v = trimmed[eq + 1 ..];
                    const tv = std.mem.trimRight(u8, raw_v, " \t");
                    if (tv.len > 0 and tv[tv.len - 1] == '\\' and cfgIsContinuation(tv)) {
                        var sp = pos;
                        while (sp < content.len) {
                            const cnl = std.mem.indexOfPos(u8, content, sp, "\n") orelse content.len;
                            const cl2 = content[sp..cnl];
                            ce = if (cnl < content.len) cnl + 1 else cnl;
                            sp = ce;
                            const ct = std.mem.trimRight(u8, std.mem.trimRight(u8, cl2, "\r"), " \t");
                            if (ct.len == 0 or ct[ct.len - 1] != '\\') break;
                        }
                    }
                    var vbuf = std.array_list.Managed(u8).init(allocator);
                    defer vbuf.deinit();
                    cfgAppendValuePart(&vbuf, raw_v) catch {};
                    if (ce > le) {
                        vbuf.clearRetainingCapacity();
                        var vl = trimmed[eq + 1 ..];
                        var vp2 = pos;
                        while (true) {
                            const vt = std.mem.trimRight(u8, vl, " \t");
                            if (vt.len > 0 and vt[vt.len - 1] == '\\') {
                                cfgAppendValuePart(&vbuf, vt[0 .. vt.len - 1]) catch {};
                                if (vp2 < content.len) {
                                    const vnl = std.mem.indexOfPos(u8, content, vp2, "\n") orelse content.len;
                                    vl = std.mem.trim(u8, std.mem.trimRight(u8, content[vp2..vnl], "\r"), " \t");
                                    vp2 = if (vnl < content.len) vnl + 1 else vnl;
                                } else break;
                            } else {
                                cfgAppendValuePart(&vbuf, vl) catch {};
                                break;
                            }
                        }
                    }
                    var rok = true;
                    if (value_regex) |vr| {
                        const neg = vr.len > 0 and vr[0] == '!';
                        const act = if (neg) vr[1..] else vr;
                        const m = if (fixed_val) std.mem.eql(u8, vbuf.items, act) else simpleRegexMatch(vbuf.items, act);
                        rok = if (neg) !m else m;
                    }
                    try infos.append(.{ .start = ls, .end = le, .cont_end = ce, .is_key = true, .regex_ok = rok, .inline_on_header = false });
                    last_target_end = ce;
                    if (ce > le) pos = ce;
                    continue;
                }
            } else {
                // Boolean key (no =)
                const bk = std.mem.trim(u8, trimmed, " \t");
                if (std.ascii.eqlIgnoreCase(bk, pk.variable)) {
                    var rok = true;
                    if (value_regex) |vr| {
                        const neg = vr.len > 0 and vr[0] == '!';
                        const act = if (neg) vr[1..] else vr;
                        const m = if (fixed_val) std.mem.eql(u8, "true", act) else simpleRegexMatch("true", act);
                        rok = if (neg) !m else m;
                    }
                    try infos.append(.{ .start = ls, .end = le, .cont_end = le, .is_key = true, .regex_ok = rok, .inline_on_header = false });
                    last_target_end = le;
                    continue;
                }
            }
        }
        try infos.append(.{ .start = ls, .end = le, .cont_end = le, .is_key = false, .regex_ok = false, .inline_on_header = false });
        if (in_section_for_add) last_target_end = le;
    }

    var match_count: usize = 0;
    var rmatch_count: usize = 0;
    for (infos.items) |li| {
        if (li.is_key) match_count += 1;
        if (li.is_key and li.regex_ok) rmatch_count += 1;
    }

    const cs = try cfgFormatComment(comment, allocator);
    defer allocator.free(cs);
    const qv = try cfgQuoteValue(value, allocator);
    defer allocator.free(qv);
    const new_line = try std.fmt.allocPrint(allocator, "\t{s} = {s}{s}\n", .{ pk.variable, qv, cs });
    defer allocator.free(new_line);

    const writeReplacement = struct {
        fn f(res: *std.array_list.Managed(u8), li: LI, nl2: []const u8, cont: []const u8) !void {
            if (li.inline_on_header) {
                const line_data = cont[li.start..li.end];
                const cb = std.mem.indexOf(u8, line_data, "]");
                if (cb) |c| {
                    try res.appendSlice(line_data[0 .. c + 1]);
                    try res.append('\n');
                }
                try res.appendSlice(nl2);
            } else {
                try res.appendSlice(nl2);
            }
        }
    };

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    if (do_add) {
        if (section_found) {
            try result.appendSlice(content[0..last_target_end]);
            try result.appendSlice(new_line);
            if (last_target_end < content.len) try result.appendSlice(content[last_target_end..]);
        } else {
            try result.appendSlice(content);
            if (pk.subsection) |sub| {
                try result.writer().print("[{s} \"{s}\"]\n", .{ pk.section, sub });
            } else {
                try result.writer().print("[{s}]\n", .{pk.section});
            }
            try result.appendSlice(new_line);
        }
        try platform_impl.fs.writeFile(cfg_path, result.items);
        return;
    }

    if (replace_all) {
        if (rmatch_count == 0 and match_count == 0) {
            if (section_found) {
                try result.appendSlice(content[0..last_target_end]);
                try result.appendSlice(new_line);
                if (last_target_end < content.len) try result.appendSlice(content[last_target_end..]);
            } else {
                try result.appendSlice(content);
                if (pk.subsection) |sub| {
                    try result.writer().print("[{s} \"{s}\"]\n", .{ pk.section, sub });
                } else {
                    try result.writer().print("[{s}]\n", .{pk.section});
                }
                try result.appendSlice(new_line);
            }
        } else {
            var last_idx: ?usize = null;
            for (infos.items, 0..) |li, idx| {
                if (li.is_key and li.regex_ok) last_idx = idx;
            }
            for (infos.items, 0..) |li, idx| {
                if (li.is_key and li.regex_ok) {
                    if (idx == last_idx.?) {
                        try writeReplacement.f(&result, li, new_line, content);
                    } else if (li.inline_on_header) {
                        // Keep the section header, remove the inline key
                        const line_data = content[li.start..li.end];
                        const cbi = std.mem.indexOf(u8, line_data, "]");
                        if (cbi) |c| {
                            try result.appendSlice(line_data[0 .. c + 1]);
                            try result.append('\n');
                        }
                    }
                    // else: skip entirely (non-inline key being removed)
                } else try result.appendSlice(content[li.start..li.cont_end]);
            }
        }
        // FIX: Remove empty sections after replace-all
        const cleaned = try cfgRemoveTargetEmptySections(result.items, pk, allocator);
        defer allocator.free(cleaned);
        try platform_impl.fs.writeFile(cfg_path, cleaned);
        return;
    }

    // Normal set
    if (value_regex != null) {
        if (rmatch_count == 0) {
            if (section_found) {
                try result.appendSlice(content[0..last_target_end]);
                try result.appendSlice(new_line);
                if (last_target_end < content.len) try result.appendSlice(content[last_target_end..]);
            } else {
                try result.appendSlice(content);
                if (pk.subsection) |sub| {
                    try result.writer().print("[{s} \"{s}\"]\n", .{ pk.section, sub });
                } else {
                    try result.writer().print("[{s}]\n", .{pk.section});
                }
                try result.appendSlice(new_line);
            }
        } else if (rmatch_count > 1) {
            try platform_impl.writeStderr("warning: key has multiple values matching regex\n");
            std.process.exit(5);
        } else {
            var replaced = false;
            for (infos.items) |li| {
                if (li.is_key and li.regex_ok and !replaced) {
                    try writeReplacement.f(&result, li, new_line, content);
                    replaced = true;
                } else try result.appendSlice(content[li.start..li.cont_end]);
            }
        }
        try platform_impl.fs.writeFile(cfg_path, result.items);
        return;
    }

    // No value_regex
    if (match_count == 0) {
        if (section_found) {
            try result.appendSlice(content[0..last_target_end]);
            try result.appendSlice(new_line);
            if (last_target_end < content.len) try result.appendSlice(content[last_target_end..]);
        } else {
            try result.appendSlice(content);
            if (pk.subsection) |sub| {
                try result.writer().print("[{s} \"{s}\"]\n", .{ pk.section, sub });
            } else {
                try result.writer().print("[{s}]\n", .{pk.section});
            }
            try result.appendSlice(new_line);
        }
    } else {
        var last_idx: ?usize = null;
        for (infos.items, 0..) |li, idx| {
            if (li.is_key) last_idx = idx;
        }
        for (infos.items, 0..) |li, idx| {
            if (li.is_key and idx == last_idx.?) try writeReplacement.f(&result, li, new_line, content) else try result.appendSlice(content[li.start..li.cont_end]);
        }
    }
    try platform_impl.fs.writeFile(cfg_path, result.items);
}

fn cfgUnsetValue(cfg_path: []const u8, key: []const u8, unset_all: bool, value_regex: ?[]const u8, fixed_val: bool, allocator: Allocator, platform_impl: *const platform_mod.Platform) !void {
    const pk = cfgParseKey(key, allocator) catch {
        try platform_impl.writeStderr("error: key does not contain a section\n");
        std.process.exit(2);
    };
    defer allocator.free(pk.section);
    defer if (pk.subsection) |s| allocator.free(s);
    defer allocator.free(pk.variable);

    const content = platform_impl.fs.readFile(allocator, cfg_path) catch {
        std.process.exit(5);
    };
    defer allocator.free(content);

    // Count matches first
    var match_count: usize = 0;
    var rmatch_count: usize = 0;
    {
        var ents = std.array_list.Managed(CfgEntry).init(allocator);
        defer {
            for (ents.items) |*e| e.deinit(allocator);
            ents.deinit();
        }
        cfgParseEntries(content, &ents, allocator) catch {};
        for (ents.items) |e| {
            if (cfgKeyMatches(e.full_key, key)) {
                match_count += 1;
                if (value_regex) |vr| {
                    const neg = vr.len > 0 and vr[0] == '!';
                    const act = if (neg) vr[1..] else vr;
                    const m = if (fixed_val) std.mem.eql(u8, e.value, act) else simpleRegexMatch(e.value, act);
                    if (if (neg) !m else m) rmatch_count += 1;
                } else rmatch_count += 1;
            }
        }
    }

    if (match_count == 0 or (value_regex != null and rmatch_count == 0)) std.process.exit(5);
    if (!unset_all and rmatch_count > 1) {
        try platform_impl.writeStderr("warning: ");
        try platform_impl.writeStderr(key);
        try platform_impl.writeStderr(" has multiple values\n");
        std.process.exit(5);
    }

    // Build output
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    var cur_sec: ?[]u8 = null;
    var cur_sub: ?[]u8 = null;
    var is_old_style_sec = false;
    defer if (cur_sec) |s| allocator.free(s);
    defer if (cur_sub) |s| allocator.free(s);
    var in_target = false;
    var first_line = true;

    var line_iter = std.mem.splitSequence(u8, content, "\n");
    while (line_iter.next()) |raw_line| {
        const ln = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, ln, " \t");

        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (cur_sec) |s| allocator.free(s);
            if (cur_sub) |s| allocator.free(s);
            cur_sec = null;
            cur_sub = null;
            is_old_style_sec = false;
            const close = std.mem.indexOf(u8, trimmed, "]");
            if (close) |cl| {
                const inner = trimmed[1..cl];
                if (std.mem.indexOf(u8, inner, "\"")) |q| {
                    cur_sec = try allocator.dupe(u8, std.mem.trim(u8, inner[0..q], " \t"));
                    var r = inner[q + 1 ..];
                    if (std.mem.lastIndexOfScalar(u8, r, '"')) |q2| r = r[0..q2];
                    var sb = std.array_list.Managed(u8).init(allocator);
                    defer sb.deinit();
                    var si: usize = 0;
                    while (si < r.len) : (si += 1) {
                        if (r[si] == '\\' and si + 1 < r.len) {
                            si += 1;
                            try sb.append(r[si]);
                        } else try sb.append(r[si]);
                    }
                    cur_sub = try sb.toOwnedSlice();
                } else if (std.mem.indexOf(u8, inner, ".")) |d| {
                    cur_sec = try allocator.dupe(u8, std.mem.trim(u8, inner[0..d], " \t"));
                    cur_sub = try allocator.dupe(u8, inner[d + 1 ..]);
                    is_old_style_sec = true;
                } else {
                    cur_sec = try allocator.dupe(u8, std.mem.trim(u8, inner, " \t"));
                }
            }
            in_target = if (cur_sec) |cs2| cfgSectionMatchesEx(cs2, cur_sub, is_old_style_sec, pk) else false;
        }

        var skip = false;
        if (in_target and trimmed.len > 0 and trimmed[0] != '[' and trimmed[0] != '#' and trimmed[0] != ';') {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
                const k = std.mem.trim(u8, trimmed[0..eq], " \t");
                if (std.ascii.eqlIgnoreCase(k, pk.variable)) {
                    var should_rm = true;
                    if (value_regex) |vr| {
                        var vbuf = std.array_list.Managed(u8).init(allocator);
                        defer vbuf.deinit();
                        cfgAppendValuePart(&vbuf, trimmed[eq + 1 ..]) catch {};
                        const neg = vr.len > 0 and vr[0] == '!';
                        const act = if (neg) vr[1..] else vr;
                        const m = if (fixed_val) std.mem.eql(u8, vbuf.items, act) else simpleRegexMatch(vbuf.items, act);
                        should_rm = if (neg) !m else m;
                    }
                    if (should_rm and (unset_all or rmatch_count <= 1)) {
                        skip = true;
                        const tv = std.mem.trimRight(u8, raw_line, " \t\r\n");
                        if (tv.len > 0 and tv[tv.len - 1] == '\\' and cfgIsContinuation(tv)) {
                            while (line_iter.next()) |cont| {
                                const ct = std.mem.trimRight(u8, cont, " \t\r\n");
                                if (ct.len == 0 or ct[ct.len - 1] != '\\') break;
                            }
                        }
                    }
                }
            } else {
                const ck = std.mem.trim(u8, trimmed, " \t");
                if (std.ascii.eqlIgnoreCase(ck, pk.variable)) {
                    if (value_regex == null and (unset_all or rmatch_count <= 1)) skip = true;
                }
            }
        }

        if (!skip) {
            if (!first_line) try result.append('\n');
            try result.appendSlice(raw_line);
            first_line = false;
        }
    }

    if (content.len > 0 and content[content.len - 1] == '\n') {
        if (result.items.len == 0 or result.items[result.items.len - 1] != '\n')
            try result.append('\n');
    }

    // FIX: Only remove sections that match the target and are empty
    const cleaned = try cfgRemoveTargetEmptySections(result.items, pk, allocator);
    defer allocator.free(cleaned);
    try platform_impl.fs.writeFile(cfg_path, cleaned);
}

/// Remove only empty sections that match the given parsed key's section/subsection.
/// Git's heuristic: remove an empty section only if there are no comment lines
/// between the previous section header (or start of file) and this section header.
fn cfgRemoveTargetEmptySections(cont: []const u8, pk: CfgParsedKey, allocator: Allocator) ![]u8 {
    var lines_list = std.array_list.Managed([]const u8).init(allocator);
    defer lines_list.deinit();
    var iter_sec = std.mem.splitSequence(u8, cont, "\n");
    while (iter_sec.next()) |line| try lines_list.append(line);
    const lines_arr = lines_list.items;
    var res = std.array_list.Managed(u8).init(allocator);
    defer res.deinit();
    var idx_s: usize = 0;
    while (idx_s < lines_arr.len) {
        const line = lines_arr[idx_s];
        const tr = std.mem.trim(u8, line, " \t\r");
        if (tr.len > 0 and tr[0] == '[') {
            const close_b = std.mem.indexOf(u8, tr, "]");
            if (close_b) |cb| {
                // Check for inline content after ]
                const after = std.mem.trim(u8, tr[cb + 1 ..], " \t");
                if (after.len > 0 and after[0] != '#' and after[0] != ';') {
                    if (res.items.len > 0) try res.append('\n');
                    try res.appendSlice(line);
                    idx_s += 1;
                    continue;
                }

                const inner = tr[1..cb];
                var sec_matches = false;
                var fsec: ?[]const u8 = null;
                var fsub: ?[]const u8 = null;
                var sub_buf: [512]u8 = undefined;
                var slen: usize = 0;
                var is_old = false;
                if (std.mem.indexOf(u8, inner, "\"")) |q| {
                    fsec = std.mem.trim(u8, inner[0..q], " \t");
                    var r = inner[q + 1 ..];
                    if (std.mem.lastIndexOfScalar(u8, r, '"')) |q2| r = r[0..q2];
                    var si: usize = 0;
                    while (si < r.len and slen < sub_buf.len) : (si += 1) {
                        if (r[si] == '\\' and si + 1 < r.len) {
                            si += 1;
                            sub_buf[slen] = r[si];
                            slen += 1;
                        } else {
                            sub_buf[slen] = r[si];
                            slen += 1;
                        }
                    }
                    fsub = sub_buf[0..slen];
                } else if (std.mem.indexOf(u8, inner, ".")) |d| {
                    fsec = std.mem.trim(u8, inner[0..d], " \t");
                    fsub = inner[d + 1 ..];
                    is_old = true;
                } else {
                    fsec = std.mem.trim(u8, inner, " \t");
                }

                if (fsec) |fs| {
                    sec_matches = cfgSectionMatchesEx(fs, fsub, is_old, pk);
                }

                if (sec_matches) {
                    // Check if section is empty (only comments/blank lines until next section)
                    var has_content = false;
                    var has_comments_in_section = false;
                    var j: usize = idx_s + 1;
                    while (j < lines_arr.len) {
                        const nl = std.mem.trim(u8, lines_arr[j], " \t\r");
                        if (nl.len > 0 and nl[0] == '[') break;
                        if (nl.len > 0 and nl[0] != '#' and nl[0] != ';') {
                            has_content = true;
                            break;
                        }
                        if (nl.len > 0 and (nl[0] == '#' or nl[0] == ';')) {
                            has_comments_in_section = true;
                        }
                        j += 1;
                    }
                    if (!has_content) {
                        // Check if there are standalone comment lines preceding this section header
                        // (between previous section and this one, not inside continuation lines)
                        var has_preceding_comments = false;
                        if (idx_s > 0) {
                            var k: usize = idx_s - 1;
                            while (true) {
                                const prev = std.mem.trim(u8, lines_arr[k], " \t\r");
                                if (prev.len > 0 and prev[0] == '[') break; // Previous section header
                                if (prev.len > 0 and (prev[0] == '#' or prev[0] == ';')) {
                                    // Check if this comment is part of a continuation line
                                    var is_continuation = false;
                                    if (k > 0) {
                                        const prev2_raw = lines_arr[k - 1];
                                        const prev2 = std.mem.trimRight(u8, prev2_raw, " \t\r\n");
                                        if (prev2.len > 0 and prev2[prev2.len - 1] == '\\') {
                                            is_continuation = true;
                                        }
                                        // Also check if it's inside a quoted string
                                        if (std.mem.indexOf(u8, prev, "\"") != null) {
                                            is_continuation = true;
                                        }
                                    }
                                    if (!is_continuation) {
                                        has_preceding_comments = true;
                                        break;
                                    }
                                }
                                if (prev.len > 0) break; // Some other content
                                if (k == 0) break;
                                k -= 1;
                            }
                        }
                        if (!has_preceding_comments and !has_comments_in_section) {
                            // Safe to remove: skip section header and blank/comment lines
                            idx_s = j;
                            continue;
                        }
                        // Has preceding comments: keep the section header but still
                        // need to check if the section has only blank lines/comments
                        // In that case, keep it all
                    }
                }
            }
        }
        if (res.items.len > 0) try res.append('\n');
        try res.appendSlice(line);
        idx_s += 1;
    }
    if (cont.len > 0 and cont[cont.len - 1] == '\n') {
        if (res.items.len > 0 and res.items[res.items.len - 1] != '\n')
            try res.append('\n');
    }
    return try res.toOwnedSlice();
}

fn cfgRenameSection(cfg_path: []const u8, old_name: []const u8, new_name: []const u8, allocator: Allocator, platform_impl: *const platform_mod.Platform) !void {
    const content = platform_impl.fs.readFile(allocator, cfg_path) catch {
        try platform_impl.writeStderr("fatal: could not read config file\n");
        std.process.exit(128);
    };
    defer allocator.free(content);

    const old_dot = std.mem.indexOfScalar(u8, old_name, '.');
    const old_sec = if (old_dot) |d| old_name[0..d] else old_name;
    const old_sub = if (old_dot) |d| old_name[d + 1 ..] else null;
    const new_dot = std.mem.indexOfScalar(u8, new_name, '.');
    const new_sec = if (new_dot) |d| new_name[0..d] else new_name;
    const new_sub = if (new_dot) |d| new_name[d + 1 ..] else null;

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    var found = false;
    var first_line = true;

    var line_iter = std.mem.splitSequence(u8, content, "\n");
    var line_num: usize = 0;
    while (line_iter.next()) |raw_line| {
        line_num += 1;
        if (raw_line.len > 512 * 1024) {
            const em = try std.fmt.allocPrint(allocator, "error: refusing to work with overly long line in '{s}' on line {d}\n", .{ cfg_path, line_num });
            defer allocator.free(em);
            try platform_impl.writeStderr(em);
            std.process.exit(1);
        }
        const trimmed = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            const close = std.mem.indexOf(u8, trimmed, "]");
            if (close) |cl| {
                const inner = trimmed[1..cl];
                var fsec: ?[]const u8 = null;
                var fsub: ?[]const u8 = null;
                var sub_buf_d: [512]u8 = undefined;
                var slen: usize = 0;

                if (std.mem.indexOf(u8, inner, "\"")) |q| {
                    fsec = std.mem.trim(u8, inner[0..q], " \t");
                    var r = inner[q + 1 ..];
                    if (std.mem.lastIndexOfScalar(u8, r, '"')) |q2| r = r[0..q2];
                    var si: usize = 0;
                    while (si < r.len and slen < sub_buf_d.len) : (si += 1) {
                        if (r[si] == '\\' and si + 1 < r.len) {
                            si += 1;
                            sub_buf_d[slen] = r[si];
                            slen += 1;
                        } else {
                            sub_buf_d[slen] = r[si];
                            slen += 1;
                        }
                    }
                    fsub = sub_buf_d[0..slen];
                } else if (std.mem.indexOf(u8, inner, ".")) |d| {
                    fsec = std.mem.trim(u8, inner[0..d], " \t");
                    fsub = inner[d + 1 ..];
                } else {
                    fsec = std.mem.trim(u8, inner, " \t");
                }

                var matches = false;
                if (fsec) |fs| {
                    if (std.ascii.eqlIgnoreCase(fs, old_sec)) {
                        if (old_sub) |os| {
                            if (fsub) |fss| matches = std.mem.eql(u8, fss, os);
                        } else matches = (fsub == null);
                    }
                }

                if (matches) {
                    found = true;
                    if (!first_line) try result.append('\n');
                    if (new_sub) |ns| {
                        try result.writer().print("[{s} \"{s}\"]", .{ new_sec, ns });
                    } else {
                        try result.writer().print("[{s}]", .{new_sec});
                    }
                    const after2 = std.mem.trim(u8, trimmed[cl + 1 ..], " \t");
                    if (after2.len > 0 and after2[0] != '#' and after2[0] != ';') {
                        try result.append('\n');
                        try result.append('\t');
                        try result.appendSlice(after2);
                    } else if (after2.len > 0) {
                        try result.appendSlice(trimmed[cl + 1 ..]);
                    }
                    first_line = false;
                    continue;
                }
            }
        }
        if (!first_line) try result.append('\n');
        try result.appendSlice(raw_line);
        first_line = false;
    }

    if (!found) {
        const msg = try std.fmt.allocPrint(allocator, "error: no such section: {s}\n", .{old_name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(2);
    }

    if (content.len > 0 and content[content.len - 1] == '\n') {
        if (result.items.len == 0 or result.items[result.items.len - 1] != '\n') try result.append('\n');
    }
    try platform_impl.fs.writeFile(cfg_path, result.items);
}

fn cfgRemoveSection(cfg_path: []const u8, section_name: []const u8, allocator: Allocator, platform_impl: *const platform_mod.Platform) !void {
    const content = platform_impl.fs.readFile(allocator, cfg_path) catch {
        try platform_impl.writeStderr("fatal: could not read config file\n");
        std.process.exit(128);
    };
    defer allocator.free(content);

    const sec_dot = std.mem.indexOfScalar(u8, section_name, '.');
    const rm_sec = if (sec_dot) |d| section_name[0..d] else section_name;
    const rm_sub = if (sec_dot) |d| section_name[d + 1 ..] else null;

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    var in_removed = false;
    var found = false;
    var first_line = true;

    var line_iter = std.mem.splitSequence(u8, content, "\n");
    while (line_iter.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            const close = std.mem.indexOf(u8, trimmed, "]");
            if (close) |_| {
                const inner2 = trimmed[1..std.mem.indexOf(u8, trimmed, "]").?];
                var fsec: ?[]const u8 = null;
                var fsub: ?[]const u8 = null;
                var sbd: [512]u8 = undefined;
                var sl: usize = 0;

                if (std.mem.indexOf(u8, inner2, "\"")) |q| {
                    fsec = std.mem.trim(u8, inner2[0..q], " \t");
                    var r = inner2[q + 1 ..];
                    if (std.mem.lastIndexOfScalar(u8, r, '"')) |q2| r = r[0..q2];
                    var si: usize = 0;
                    while (si < r.len and sl < sbd.len) : (si += 1) {
                        if (r[si] == '\\' and si + 1 < r.len) {
                            si += 1;
                            sbd[sl] = r[si];
                            sl += 1;
                        } else {
                            sbd[sl] = r[si];
                            sl += 1;
                        }
                    }
                    fsub = sbd[0..sl];
                } else if (std.mem.indexOf(u8, inner2, ".")) |d| {
                    fsec = std.mem.trim(u8, inner2[0..d], " \t");
                    fsub = inner2[d + 1 ..];
                } else {
                    fsec = std.mem.trim(u8, inner2, " \t");
                }

                var matches = false;
                if (fsec) |fs| {
                    if (std.ascii.eqlIgnoreCase(fs, rm_sec)) {
                        if (rm_sub) |rs| {
                            if (fsub) |fss| matches = std.mem.eql(u8, fss, rs);
                        } else matches = (fsub == null);
                    }
                }

                if (matches) {
                    in_removed = true;
                    found = true;
                    continue;
                } else in_removed = false;
            }
        }
        if (!in_removed) {
            if (!first_line) try result.append('\n');
            try result.appendSlice(raw_line);
            first_line = false;
        }
    }

    if (!found) {
        const msg = try std.fmt.allocPrint(allocator, "fatal: no such section: {s}\n", .{section_name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    }

    if (content.len > 0 and content[content.len - 1] == '\n') {
        if (result.items.len == 0 or result.items[result.items.len - 1] != '\n') try result.append('\n');
    }
    try platform_impl.fs.writeFile(cfg_path, result.items);
}

// ============ Color functions ============

fn parseColorName(word: []const u8) ?i16 {
    if (std.mem.eql(u8, word, "normal") or std.mem.eql(u8, word, "default")) return -1;
    if (std.mem.eql(u8, word, "black")) return 0;
    if (std.mem.eql(u8, word, "red")) return 1;
    if (std.mem.eql(u8, word, "green")) return 2;
    if (std.mem.eql(u8, word, "yellow")) return 3;
    if (std.mem.eql(u8, word, "blue")) return 4;
    if (std.mem.eql(u8, word, "magenta")) return 5;
    if (std.mem.eql(u8, word, "cyan")) return 6;
    if (std.mem.eql(u8, word, "white")) return 7;
    return null;
}

fn colorToAnsiAlloc(allocator: Allocator, color_str: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, color_str, " \t");
    if (trimmed.len == 0) return try allocator.dupe(u8, "");
    if (std.mem.eql(u8, trimmed, "normal") or std.mem.eql(u8, trimmed, "-1")) {
        return try allocator.dupe(u8, "");
    }

    var fg_color: i16 = -2;
    var bg_color: i16 = -2;
    var fg_set = false;
    var bg_set = false;
    var fg_rgb: ?[3]u8 = null;
    var bg_rgb: ?[3]u8 = null;
    var attrs = std.array_list.Managed(u8).init(allocator);
    defer attrs.deinit();
    var has_reset = false;

    var word_iter = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (word_iter.next()) |word| {
        if (word.len == 7 and word[0] == '#') {
            const r = std.fmt.parseInt(u8, word[1..3], 16) catch return error.InvalidColor;
            const g = std.fmt.parseInt(u8, word[3..5], 16) catch return error.InvalidColor;
            const b = std.fmt.parseInt(u8, word[5..7], 16) catch return error.InvalidColor;
            if (!fg_set) {
                fg_rgb = .{ r, g, b };
                fg_color = -3;
                fg_set = true;
            } else {
                bg_rgb = .{ r, g, b };
                bg_color = -3;
                bg_set = true;
            }
            continue;
        }
        // Attributes
        if (std.mem.eql(u8, word, "reset")) { has_reset = true; continue; }
        if (std.mem.eql(u8, word, "bold")) { try attrs.append(1); continue; }
        if (std.mem.eql(u8, word, "dim")) { try attrs.append(2); continue; }
        if (std.mem.eql(u8, word, "italic")) { try attrs.append(3); continue; }
        if (std.mem.eql(u8, word, "ul")) { try attrs.append(4); continue; }
        if (std.mem.eql(u8, word, "blink")) { try attrs.append(5); continue; }
        if (std.mem.eql(u8, word, "reverse")) { try attrs.append(7); continue; }
        if (std.mem.eql(u8, word, "strike")) { try attrs.append(9); continue; }
        if (std.mem.eql(u8, word, "nobold") or std.mem.eql(u8, word, "no-bold")) { try attrs.append(22); continue; }
        if (std.mem.eql(u8, word, "nodim") or std.mem.eql(u8, word, "no-dim")) { try attrs.append(22); continue; }
        if (std.mem.eql(u8, word, "noitalic") or std.mem.eql(u8, word, "no-italic")) { try attrs.append(23); continue; }
        if (std.mem.eql(u8, word, "noul") or std.mem.eql(u8, word, "no-ul")) { try attrs.append(24); continue; }
        if (std.mem.eql(u8, word, "noblink") or std.mem.eql(u8, word, "no-blink")) { try attrs.append(25); continue; }
        if (std.mem.eql(u8, word, "noreverse") or std.mem.eql(u8, word, "no-reverse")) { try attrs.append(27); continue; }
        if (std.mem.eql(u8, word, "nostrike") or std.mem.eql(u8, word, "no-strike")) { try attrs.append(29); continue; }
        // Bright colors
        if (word.len > 6 and std.mem.startsWith(u8, word, "bright")) {
            if (parseColorName(word[6..])) |b| {
                if (b >= 0) {
                    if (!fg_set) { fg_color = b + 8; fg_set = true; } else { bg_color = b + 8; bg_set = true; }
                    continue;
                }
            }
            return error.InvalidColor;
        }
        // Color names
        if (parseColorName(word)) |c| {
            if (!fg_set) { fg_color = c; fg_set = true; } else { bg_color = c; bg_set = true; }
            continue;
        }
        // Numeric color
        if (std.fmt.parseInt(i16, word, 10)) |n| {
            if (n < -1 or n > 255) return error.InvalidColor;
            if (!fg_set) { fg_color = n; fg_set = true; } else { bg_color = n; bg_set = true; }
            continue;
        } else |_| {}
        return error.InvalidColor;
    }

    var codes = std.array_list.Managed(u8).init(allocator);
    defer codes.deinit();
    var first = true;

    if (has_reset) {
        if (!first) try codes.append(';');
        first = false;
    }

    for (attrs.items) |attr_code| {
        if (!first) try codes.append(';');
        var buf2: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf2, "{d}", .{attr_code}) catch unreachable;
        try codes.appendSlice(s);
        first = false;
    }

    if (fg_set) {
        if (fg_color == -3) {
            if (fg_rgb) |rgb| {
                if (!first) try codes.append(';');
                var buf2: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf2, "38;2;{d};{d};{d}", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable;
                try codes.appendSlice(s);
                first = false;
            }
        } else if (fg_color == -1) {
            if (!first) try codes.append(';');
            try codes.appendSlice("39");
            first = false;
        } else if (fg_color >= 0 and fg_color <= 7) {
            if (!first) try codes.append(';');
            var buf2: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf2, "{d}", .{@as(u16, @intCast(fg_color)) + 30}) catch unreachable;
            try codes.appendSlice(s);
            first = false;
        } else if (fg_color >= 8 and fg_color <= 15) {
            if (!first) try codes.append(';');
            var buf2: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf2, "{d}", .{@as(u16, @intCast(fg_color)) - 8 + 90}) catch unreachable;
            try codes.appendSlice(s);
            first = false;
        } else if (fg_color >= 16 and fg_color <= 255) {
            if (!first) try codes.append(';');
            var buf2: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf2, "38;5;{d}", .{@as(u16, @intCast(fg_color))}) catch unreachable;
            try codes.appendSlice(s);
            first = false;
        }
    }

    if (bg_set) {
        if (bg_color == -3) {
            if (bg_rgb) |rgb| {
                if (!first) try codes.append(';');
                var buf2: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf2, "48;2;{d};{d};{d}", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable;
                try codes.appendSlice(s);
                first = false;
            }
        } else if (bg_color == -1) {
            if (!first) try codes.append(';');
            try codes.appendSlice("49");
            first = false;
        } else if (bg_color >= 0 and bg_color <= 7) {
            if (!first) try codes.append(';');
            var buf2: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf2, "{d}", .{@as(u16, @intCast(bg_color)) + 40}) catch unreachable;
            try codes.appendSlice(s);
            first = false;
        } else if (bg_color >= 8 and bg_color <= 15) {
            if (!first) try codes.append(';');
            var buf2: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf2, "{d}", .{@as(u16, @intCast(bg_color)) - 8 + 100}) catch unreachable;
            try codes.appendSlice(s);
            first = false;
        } else if (bg_color >= 16 and bg_color <= 255) {
            if (!first) try codes.append(';');
            var buf2: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf2, "48;5;{d}", .{@as(u16, @intCast(bg_color))}) catch unreachable;
            try codes.appendSlice(s);
            first = false;
        }
    }

    if (codes.items.len == 0 and !fg_set and !bg_set and attrs.items.len == 0 and !has_reset) {
        return try allocator.dupe(u8, "");
    }

    var out_result = std.array_list.Managed(u8).init(allocator);
    try out_result.append(0x1b);
    try out_result.append('[');
    try out_result.appendSlice(codes.items);
    try out_result.append('m');
    return try out_result.toOwnedSlice();
}

// ============ Regex functions ============

pub fn simpleRegexMatch(text: []const u8, pattern: []const u8) bool {
    var anchored_start = false;
    var anchored_end = false;
    var ep = pattern;
    if (ep.len > 0 and ep[0] == '^') { anchored_start = true; ep = ep[1..]; }
    if (ep.len > 0 and ep[ep.len - 1] == '$' and (ep.len < 2 or ep[ep.len - 2] != '\\')) {
        anchored_end = true;
        ep = ep[0 .. ep.len - 1];
    }
    const end_pos: usize = if (anchored_start) 1 else text.len + 1;
    var ti: usize = 0;
    while (ti < end_pos) : (ti += 1) {
        if (simpleRegexMatchAt(text, ti, ep, 0)) |match_end| {
            if (anchored_end and match_end != text.len) continue;
            return true;
        }
    }
    return false;
}

fn simpleRegexMatchAt(text: []const u8, tpos: usize, pat: []const u8, ppos: usize) ?usize {
    var tp = tpos;
    var pp = ppos;
    while (pp < pat.len) {
        if (pat[pp] == '[') {
            const close = std.mem.indexOfPos(u8, pat, pp + 1, "]") orelse return null;
            const class = pat[pp + 1 .. close];
            const next_pp = close + 1;
            const cq: u8 = if (next_pp < pat.len and (pat[next_pp] == '*' or pat[next_pp] == '+' or pat[next_pp] == '?')) pat[next_pp] else 0;
            if (cq == '*' or cq == '?') {
                if (simpleRegexMatchAt(text, tp, pat, next_pp + 1)) |end| return end;
            }
            if (cq == '*' or cq == '+') {
                var tp2 = tp;
                while (tp2 < text.len and matchCharClass(text[tp2], class)) tp2 += 1;
                while (tp2 >= tp) {
                    if (simpleRegexMatchAt(text, tp2, pat, next_pp + 1)) |end| return end;
                    if (tp2 == tp) break;
                    tp2 -= 1;
                }
                return null;
            }
            if (cq == '?') {
                if (tp < text.len and matchCharClass(text[tp], class)) {
                    if (simpleRegexMatchAt(text, tp + 1, pat, next_pp + 1)) |end| return end;
                }
                return simpleRegexMatchAt(text, tp, pat, next_pp + 1);
            }
            if (tp >= text.len) return null;
            if (!matchCharClass(text[tp], class)) return null;
            tp += 1;
            pp = next_pp;
            continue;
        }
        if (pat[pp] == '\\' and pp + 1 < pat.len) {
            if (tp >= text.len or text[tp] != pat[pp + 1]) return null;
            tp += 1;
            pp += 2;
            continue;
        }
        const has_quant = pp + 1 < pat.len and (pat[pp + 1] == '*' or pat[pp + 1] == '+' or pat[pp + 1] == '?');
        if (pat[pp] == '.' and !has_quant) {
            if (tp >= text.len) return null;
            tp += 1;
            pp += 1;
            continue;
        }
        if (pat[pp] == '.' and has_quant) {
            const quant = pat[pp + 1];
            if (quant == '*') {
                var tp2 = text.len;
                while (tp2 >= tp) {
                    if (simpleRegexMatchAt(text, tp2, pat, pp + 2)) |end| return end;
                    if (tp2 == 0) break;
                    tp2 -= 1;
                }
                return null;
            }
            if (quant == '+') {
                if (tp >= text.len) return null;
                var tp2 = text.len;
                while (tp2 > tp) {
                    if (simpleRegexMatchAt(text, tp2, pat, pp + 2)) |end| return end;
                    tp2 -= 1;
                }
                return null;
            }
            if (quant == '?') {
                if (tp < text.len) {
                    if (simpleRegexMatchAt(text, tp + 1, pat, pp + 2)) |end| return end;
                }
                return simpleRegexMatchAt(text, tp, pat, pp + 2);
            }
        }
        if (has_quant) {
            const lit = pat[pp];
            const quant = pat[pp + 1];
            if (quant == '*') {
                var tp2 = tp;
                while (tp2 < text.len and text[tp2] == lit) tp2 += 1;
                while (tp2 >= tp) {
                    if (simpleRegexMatchAt(text, tp2, pat, pp + 2)) |end| return end;
                    if (tp2 == tp) break;
                    tp2 -= 1;
                }
                return null;
            }
            if (quant == '+') {
                if (tp >= text.len or text[tp] != lit) return null;
                var tp2 = tp;
                while (tp2 < text.len and text[tp2] == lit) tp2 += 1;
                while (tp2 > tp) {
                    if (simpleRegexMatchAt(text, tp2, pat, pp + 2)) |end| return end;
                    tp2 -= 1;
                }
                return null;
            }
            if (quant == '?') {
                if (tp < text.len and text[tp] == lit) {
                    if (simpleRegexMatchAt(text, tp + 1, pat, pp + 2)) |end| return end;
                }
                return simpleRegexMatchAt(text, tp, pat, pp + 2);
            }
        }
        if (tp >= text.len or text[tp] != pat[pp]) return null;
        tp += 1;
        pp += 1;
    }
    return tp;
}

fn matchCharClass(c: u8, class: []const u8) bool {
    var negated = false;
    var idx: usize = 0;
    if (idx < class.len and class[idx] == '^') { negated = true; idx += 1; }
    var matched = false;
    while (idx < class.len) {
        if (idx + 2 < class.len and class[idx + 1] == '-') {
            if (c >= class[idx] and c <= class[idx + 2]) matched = true;
            idx += 3;
        } else {
            if (c == class[idx]) matched = true;
            idx += 1;
        }
    }
    return if (negated) !matched else matched;
}

fn cfgKeyMatchesGlob(key: []const u8, glob: []const u8) bool {
    // Match a config key against a glob pattern like "remote.*.url"
    return simpleGlobMatch(key, glob);
}

/// URL match specificity: returns 0 if pattern doesn't match url, >0 for how specific
fn urlMatchSpecificity(pattern: []const u8, url: []const u8) usize {
    // Parse both URLs to compare scheme, host, port, path
    const p = parseUrlParts(pattern);
    const u = parseUrlParts(url);

    // Scheme must match (case-insensitive)
    if (p.scheme.len > 0 and u.scheme.len > 0) {
        if (!std.ascii.eqlIgnoreCase(p.scheme, u.scheme)) return 0;
    }

    // Host must match (case-insensitive), with wildcard support
    if (p.host.len > 0) {
        if (!urlHostMatches(p.host, u.host)) return 0;
    }

    // Port must match if specified in pattern
    if (p.port.len > 0) {
        if (!std.mem.eql(u8, p.port, u.port)) {
            // Default ports
            const p_port = if (p.port.len == 0) defaultPort(p.scheme) else p.port;
            const u_port = if (u.port.len == 0) defaultPort(u.scheme) else u.port;
            if (!std.mem.eql(u8, p_port, u_port)) return 0;
        }
    }

    // User must match if specified in pattern
    if (p.user.len > 0) {
        if (!std.mem.eql(u8, p.user, u.user)) return 0;
    }

    // Path: pattern path must be a prefix of url path
    if (p.path.len > 0) {
        if (!urlPathMatches(p.path, u.path)) return 0;
    }

    // Calculate specificity based on git's URL matching rules.
    // Git computes a score where:
    // 1. Path length is the PRIMARY factor (longer path prefix = more specific)
    // 2. User match adds minor specificity (tiebreaker when paths are equal)
    // 3. Exact host > wildcard host
    // 4. Port adds minor specificity
    // Use bit-shifting to ensure path dominates
    var specificity: usize = 1;

    // Path specificity (highest weight - shifted left significantly)
    var path_len = p.path.len;
    while (path_len > 0 and p.path[path_len - 1] == '/') path_len -= 1;
    specificity += path_len * 10000;

    // Host specificity: exact > wildcard
    if (p.host.len > 0) {
        if (std.mem.indexOfScalar(u8, p.host, '*') != null) {
            specificity += p.host.len; // wildcard: less specific
        } else {
            specificity += p.host.len + 100; // exact: more specific
        }
    }

    // User adds minor specificity (only matters as tiebreaker)
    if (p.user.len > 0) specificity += p.user.len + 50;

    // Port adds minor specificity
    if (p.port.len > 0) specificity += 10;

    return specificity;
}

const UrlParts = struct {
    scheme: []const u8,
    user: []const u8,
    host: []const u8,
    port: []const u8,
    path: []const u8,
};

fn parseUrlParts(url: []const u8) UrlParts {
    var result = UrlParts{ .scheme = "", .user = "", .host = "", .port = "", .path = "" };
    var rest = url;

    // Extract scheme
    if (std.mem.indexOf(u8, rest, "://")) |idx| {
        result.scheme = rest[0..idx];
        rest = rest[idx + 3 ..];
    }

    // Extract path (everything after first / that's part of the path)
    if (std.mem.indexOfScalar(u8, rest, '/')) |idx| {
        result.path = rest[idx..];
        rest = rest[0..idx];
    }

    // Extract user@
    if (std.mem.indexOfScalar(u8, rest, '@')) |idx| {
        result.user = rest[0..idx];
        rest = rest[idx + 1 ..];
    }

    // Extract host:port
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |idx| {
        result.host = rest[0..idx];
        result.port = rest[idx + 1 ..];
    } else {
        result.host = rest;
    }

    return result;
}

fn defaultPort(scheme: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return "80";
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return "443";
    if (std.ascii.eqlIgnoreCase(scheme, "ftp")) return "21";
    return "";
}

fn urlHostMatches(pattern_host: []const u8, url_host: []const u8) bool {
    // Support wildcard * at the start of pattern host
    if (pattern_host.len > 0 and pattern_host[0] == '*') {
        // *.example.com matches foo.example.com but NOT deep.nested.example.com
        const suffix = pattern_host[1..]; // ".example.com"
        if (suffix.len == 0) return true;
        if (url_host.len > suffix.len) {
            if (!std.ascii.eqlIgnoreCase(url_host[url_host.len - suffix.len ..], suffix)) return false;
            // Check that the prefix (the part matching *) has no dots (single level)
            const prefix = url_host[0 .. url_host.len - suffix.len];
            if (std.mem.indexOfScalar(u8, prefix, '.') != null) return false;
            return true;
        }
        // Exact match with suffix (e.g., *.example.com doesn't match example.com)
        return false;
    }
    return std.ascii.eqlIgnoreCase(pattern_host, url_host);
}

fn urlPathMatches(pattern_path: []const u8, url_path: []const u8) bool {
    // Pattern path must be a prefix of url path
    // Trailing / in pattern is optional; "/" matches empty
    var pp = pattern_path;
    while (pp.len > 0 and pp[pp.len - 1] == '/') pp = pp[0 .. pp.len - 1];
    var up = url_path;
    while (up.len > 0 and up[up.len - 1] == '/') up = up[0 .. up.len - 1];

    if (pp.len == 0) return true;
    if (up.len < pp.len) return false;
    if (!std.ascii.eqlIgnoreCase(up[0..pp.len], pp)) return false;
    // After the match, url must either end or have a /
    if (up.len == pp.len) return true;
    if (up[pp.len] == '/') return true;
    return false;
}
