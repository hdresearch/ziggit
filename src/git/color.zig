const std = @import("std");

// ── ANSI escape codes ──────────────────────────────────────────────────
pub const reset = "\x1b[m";
pub const bold = "\x1b[1m";
pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const cyan = "\x1b[36m";
pub const bold_red = "\x1b[1;31m";
pub const bold_green = "\x1b[1;32m";
pub const bold_cyan = "\x1b[1;36m";

// ── Git-compatible color slot names ────────────────────────────────────
// status
pub const status_header = bold;
pub const status_added = green; // staged (changes to be committed)
pub const status_changed = red; // unstaged modifications
pub const status_untracked = red;
pub const status_branch = green; // current branch name
pub const status_nobranch = red; // detached HEAD

// diff
pub const diff_meta = bold; // "diff --git", "index", "---", "+++"
pub const diff_frag = cyan; // "@@ ... @@"
pub const diff_old = red; // removed lines
pub const diff_new = green; // added lines

// log
pub const log_commit = yellow; // commit hash
pub const log_decorate_head = bold_cyan; // HEAD ->
pub const log_decorate_branch = green; // local branch
pub const log_decorate_remote = red; // remote branch
pub const log_decorate_tag = yellow; // tag

// branch
pub const branch_current = green; // current branch (with *)
pub const branch_remote = red; // remote-tracking branches
pub const branch_plain = ""; // other local branches (no color)

// ── Determine whether to colorize ──────────────────────────────────────
/// Resolve color mode from explicit flag + environment + config.
/// Returns true when output should include ANSI escapes.
///
///  explicit = value of --color / --no-color flag if the user gave one
///             ("always", "never", "auto", or null if no flag)
///  git_path = .git directory path (may be null)
///  config_key = per-command config key, e.g. "color.status" (checked
///               before the global "color.ui")
pub fn shouldColorize(
    explicit: ?[]const u8,
    git_path: ?[]const u8,
    config_key: ?[]const u8,
    allocator: std.mem.Allocator,
) bool {
    const is_freestanding = comptime @import("builtin").os.tag == .freestanding;
    if (is_freestanding) return false;

    // 1. Honour explicit --color=always / --no-color
    if (explicit) |mode| {
        if (std.ascii.eqlIgnoreCase(mode, "always") or
            std.ascii.eqlIgnoreCase(mode, "true"))
            return true;
        if (std.ascii.eqlIgnoreCase(mode, "never") or
            std.ascii.eqlIgnoreCase(mode, "false"))
            return false;
        // "auto" falls through to tty check
    }

    // 2. NO_COLOR convention (https://no-color.org)
    if (comptime !is_freestanding) {
        if (std.posix.getenv("NO_COLOR")) |_| return false;
    }

    // 3. If no explicit flag, check per-command config then color.ui
    if (explicit == null) {
        if (resolveConfigColor(git_path, config_key, allocator)) |val| {
            if (std.ascii.eqlIgnoreCase(val, "always") or
                std.ascii.eqlIgnoreCase(val, "true"))
                return true;
            if (std.ascii.eqlIgnoreCase(val, "never") or
                std.ascii.eqlIgnoreCase(val, "false"))
                return false;
            // "auto" falls through
        }
    }

    // 4. Auto mode: colorize when stdout is a terminal
    if (comptime !is_freestanding) {
        return std.posix.isatty(std.posix.STDOUT_FILENO);
    }
    return false;
}

/// Look up per-command color config, falling back to color.ui.
fn resolveConfigColor(
    git_path: ?[]const u8,
    config_key: ?[]const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const gp = git_path orelse return null;
    const helpers = @import("../git_helpers.zig");

    // Per-command key first (e.g. "color.status")
    if (config_key) |key| {
        if (helpers.getConfigValueByKey(gp, key, allocator)) |val| {
            defer allocator.free(val);
            // Return a static string so caller doesn't need to free
            return staticColorVal(val);
        }
    }
    // Global fallback
    if (helpers.getConfigValueByKey(gp, "color.ui", allocator)) |val| {
        defer allocator.free(val);
        return staticColorVal(val);
    }
    // Git default: color.ui = auto
    return "auto";
}

fn staticColorVal(val: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(val, "always") or std.ascii.eqlIgnoreCase(val, "true")) return "always";
    if (std.ascii.eqlIgnoreCase(val, "never") or std.ascii.eqlIgnoreCase(val, "false")) return "never";
    if (std.ascii.eqlIgnoreCase(val, "auto")) return "auto";
    return null;
}

// ── Convenience: wrap a string with color ──────────────────────────────
/// Write `prefix ++ text ++ reset` if color is on, otherwise just `text`.
pub inline fn colored(use_color: bool, prefix: []const u8, text: []const u8, buf: *std.array_list.Managed(u8)) !void {
    if (use_color and prefix.len > 0) try buf.appendSlice(prefix);
    try buf.appendSlice(text);
    if (use_color and prefix.len > 0) try buf.appendSlice(reset);
}
