const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

pub fn cmdInitAgent(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = args_iter; // No additional arguments expected for now

    const ziggit_md_content =
        \\# ziggit
        \\
        \\**Drop-in replacement for `git`.** Use `ziggit` exactly like `git` for all operations.
        \\
        \\## Notice for AI Agents
        \\- **Succinct Mode:** Output is heavily compressed by default to save tokens. If you need standard verbose output to understand a complex state, use `ziggit --no-succinct <cmd>`.
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
        \\Refer to CLAUDE.md for full command reference.
    ;

    // 1. Create ziggit.md in the current directory
    try std.fs.cwd().writeFile(.{ .sub_path = "ziggit.md", .data = ziggit_md_content });
    try platform_impl.writeStdout("Created ziggit.md\n");

    // 2. Append "@ziggit.md" to ~/.claude/CLAUDE.md
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch {
        try platform_impl.writeStderr("Error: HOME environment variable not found.\n");
        return;
    };
    defer allocator.free(home_dir);

    const claude_md_path = try std.fs.path.join(allocator, &.{ home_dir, ".claude", "CLAUDE.md" });
    defer allocator.free(claude_md_path);

    // Check if ~/.claude exists, if not, create it
    const claude_dir_path = try std.fs.path.join(allocator, &.{ home_dir, ".claude" });
    defer allocator.free(claude_dir_path);
    std.fs.makeDirAbsolute(claude_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Open CLAUDE.md in read/write mode, or create it if it doesn't exist
    var file = try std.fs.createFileAbsolute(claude_md_path, .{ .read = true, .truncate = false });
    defer file.close();

    // Check if it already contains @ziggit.md
    const stat = try file.stat();
    if (stat.size > 0) {
        // Read file content to check for existing reference
        try file.seekTo(0);
        const content = try file.readToEndAlloc(allocator, 1024 * 1024); // max 1MB
        defer allocator.free(content);
        
        if (std.mem.indexOf(u8, content, "@ziggit.md") != null) {
            try platform_impl.writeStdout("~/.claude/CLAUDE.md already contains @ziggit.md\n");
            return;
        }

        // Seek to end to append
        try file.seekFromEnd(0);
        if (content[content.len - 1] != '\n') {
            try file.writeAll("\n");
        }
    }

    try file.writeAll("@ziggit.md\n");
    try platform_impl.writeStdout("Appended \"@ziggit.md\" to ~/.claude/CLAUDE.md\n");
}
