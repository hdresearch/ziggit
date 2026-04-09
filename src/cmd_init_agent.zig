const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

/// Known agent config directories and their instruction files.
/// Each entry is { dot_dir_name, instruction_filename }.
const AgentTarget = struct {
    dir: []const u8,
    file: []const u8,
};

const agent_targets = [_]AgentTarget{
    .{ .dir = ".claude", .file = "CLAUDE.md" },
    .{ .dir = ".gemini", .file = "GEMINI.md" },
    .{ .dir = ".codex", .file = "CODEX.md" },
    .{ .dir = ".github", .file = "copilot-instructions.md" },
    .{ .dir = ".cursor", .file = "rules" },
};

pub fn cmdInitAgent(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    // Parse arguments
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try platform_impl.writeStdout(
                \\usage: ziggit init-agent
                \\
                \\Set up AI agent context for the current project.
                \\
                \\Actions:
                \\  1. Creates ziggit.md in the current working directory with
                \\     instructions for AI agents on how to use ziggit.
                \\
                \\  2. Scans ~/.<agent>/ for known agent config directories and
                \\     appends an @ziggit.md reference to their instruction file
                \\     if not already present.
                \\
                \\Supported agents:
                \\  ~/.claude/CLAUDE.md                (Claude Code)
                \\  ~/.gemini/GEMINI.md                (Gemini CLI)
                \\  ~/.codex/CODEX.md                  (OpenAI Codex CLI)
                \\  ~/.github/copilot-instructions.md  (GitHub Copilot)
                \\  ~/.cursor/rules                    (Cursor)
                \\
            );
            return;
        }
    }

    const ziggit_md_content =
        \\# ziggit
        \\
        \\**Drop-in replacement for `git`.** Use `ziggit` exactly like `git` for all operations.
        \\
        \\## Notice for AI Agents
        \\- **Succinct Mode:** Output is heavily compressed by default to save tokens. If you need standard verbose output to understand a complex state, use `GIT_SUCCINCT=0 GIT_TRACE=1 ZIGGIT_TRACE_TIMING=1 ziggit <cmd>`.
        \\
        \\## Workflow Commands
        \\Convenient aliases for development loops:
        \\- `ziggit restart` : `fetch` + `rebase` onto `origin/main`
        \\- `ziggit start` : `stash` + `restart` + `pop` (safe restart with dirty tree)
        \\- `ziggit progress "msg"` : `add -A` + `commit` + `push` + `restart`
        \\
        \\## Verification
        \\- `ziggit --version-info`
        \\
        \\Refer to your agent's instruction file for full command reference.
    ;

    // 1. Create ziggit.md in the current directory
    try std.fs.cwd().writeFile(.{ .sub_path = "ziggit.md", .data = ziggit_md_content });
    try platform_impl.writeStdout("Created ziggit.md\n");

    // 2. Scan for known agent config directories and append @ziggit.md
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch {
        try platform_impl.writeStderr("Error: HOME environment variable not found.\n");
        return;
    };
    defer allocator.free(home_dir);

    var found_any = false;
    for (agent_targets) |target| {
        const agent_dir = try std.fs.path.join(allocator, &.{ home_dir, target.dir });
        defer allocator.free(agent_dir);

        // Only update agents whose config directory already exists
        std.fs.accessAbsolute(agent_dir, .{}) catch continue;
        found_any = true;

        const instruction_path = try std.fs.path.join(allocator, &.{ agent_dir, target.file });
        defer allocator.free(instruction_path);

        try appendReference(allocator, instruction_path, target.dir, target.file, platform_impl);
    }

    if (!found_any) {
        try platform_impl.writeStdout("No agent config directories found in ~/\n");
    }
}

/// Append "@ziggit.md" to an agent instruction file if not already present.
fn appendReference(
    allocator: std.mem.Allocator,
    path: []const u8,
    dir_name: []const u8,
    file_name: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    // Open or create the file
    var file = std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "warning: could not open ~/{s}/{s}: {}\n", .{ dir_name, file_name, err });
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        return;
    };
    defer file.close();

    // Check if it already contains @ziggit.md
    const stat = try file.stat();
    if (stat.size > 0) {
        try file.seekTo(0);
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        if (std.mem.indexOf(u8, content, "@ziggit.md") != null) {
            const msg = try std.fmt.allocPrint(allocator, "~/{s}/{s} already contains @ziggit.md\n", .{ dir_name, file_name });
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
            return;
        }

        // Seek to end; ensure trailing newline before appending
        try file.seekFromEnd(0);
        if (content[content.len - 1] != '\n') {
            try file.writeAll("\n");
        }
    }

    try file.writeAll("@ziggit.md\n");
    const msg = try std.fmt.allocPrint(allocator, "Appended @ziggit.md to ~/{s}/{s}\n", .{ dir_name, file_name });
    defer allocator.free(msg);
    try platform_impl.writeStdout(msg);
}
