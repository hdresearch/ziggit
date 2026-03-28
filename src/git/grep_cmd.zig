const std = @import("std");
const objects = @import("objects.zig");
const index_mod = @import("../git/index.zig");
const platform_mod = @import("../platform/platform.zig");

// Import main_common for shared utilities
const main_common = @import("../main_common.zig");

const Allocator = std.mem.Allocator;

/// Pattern type for grep
const PatternType = enum {
    basic, // BRE (default)
    extended, // ERE (-E)
    fixed, // Fixed string (-F)
    perl, // PCRE (-P)
};

/// A single grep pattern
const GrepPattern = struct {
    text: []const u8,
    is_negated: bool = false,
};

/// Expression node for boolean expression tree
const ExprNode = union(enum) {
    pattern: usize, // index into patterns array
    not_expr: *ExprNode,
    and_expr: struct { left: *ExprNode, right: *ExprNode },
    or_expr: struct { left: *ExprNode, right: *ExprNode },
};

/// Expression token for boolean expression parsing
const ExprToken = union(enum) {
    pattern: []const u8,
    op_and,
    op_or,
    op_not,
    open_paren,
    close_paren,
};

/// Grep options
const GrepOptions = struct {
    patterns: std.array_list.Managed([]const u8),
    pattern_type: PatternType = .basic,
    case_insensitive: bool = false,
    word_match: bool = false,
    invert_match: bool = false,
    files_only: bool = false, // -l
    files_without_match: bool = false, // -L
    count_only: bool = false, // -c
    show_line_number: bool = false, // -n (default off, like real git)
    show_line_number_explicit: bool = false, // user explicitly set -n
    no_line_number: bool = false,
    show_column: bool = false,
    only_matching: bool = false, // -o
    quiet: bool = false, // -q
    max_depth: ?i32 = null,
    max_count: ?i32 = null,
    context_before: i32 = 0, // -B
    context_after: i32 = 0, // -A
    show_function: bool = false, // -p
    function_body: bool = false, // -W
    no_heading: bool = true, // default
    show_heading: bool = false,
    show_break: bool = false,
    null_separator: bool = false, // -z
    full_name: bool = false,
    no_index: bool = false,
    cached: bool = false,
    untracked: bool = false,
    color: ColorMode = .auto,
    pathspecs: std.array_list.Managed([]const u8),
    tree_ish: ?[]const u8 = null,
    suppress_filename: bool = false, // -h
    show_filename: bool = true, // -H (default)
    threads: ?u32 = null,
    // Boolean expression support
    has_boolean_expr: bool = false,
    expr_root: ?*ExprNode = null,
    expr_tokens: std.array_list.Managed(ExprToken),
    expr_tokens_initialized: bool = false,
    // Pattern files
    pattern_files: std.array_list.Managed([]const u8),
    // Config-driven settings
    config_pattern_type: ?PatternType = null,
    config_extended_regexp: ?bool = null,
    extended_regexp_values: std.array_list.Managed(bool),
    pattern_type_values: std.array_list.Managed(?PatternType),
    // Track whether line number was configured
    config_linenumber: ?bool = null,
    // Exclude standard
    exclude_standard: bool = false,
    no_exclude_standard: bool = false,
    // Recursive
    recursive: bool = true,

    fn init(allocator: Allocator) GrepOptions {
        return .{
            .patterns = std.array_list.Managed([]const u8).init(allocator),
            .pathspecs = std.array_list.Managed([]const u8).init(allocator),
            .pattern_files = std.array_list.Managed([]const u8).init(allocator),
            .extended_regexp_values = std.array_list.Managed(bool).init(allocator),
            .pattern_type_values = std.array_list.Managed(?PatternType).init(allocator),
            .expr_tokens = std.array_list.Managed(ExprToken).init(allocator),
            .expr_tokens_initialized = true,
        };
    }

    fn deinit(self: *GrepOptions) void {
        self.patterns.deinit();
        if (self.expr_tokens_initialized) self.expr_tokens.deinit();
        self.pathspecs.deinit();
        self.pattern_files.deinit();
        self.extended_regexp_values.deinit();
        self.pattern_type_values.deinit();
    }

    fn effectivePatternType(self: *const GrepOptions) PatternType {
        // Command-line flags (-G, -E, -F, -P) override everything
        // But we track them through the same last-one-wins mechanism
        // The actual logic: grep.patternType and grep.extendedRegexp interact
        // If patternType is explicitly set (not "default"), it wins
        // If patternType is "default", then extendedRegexp is consulted
        // All values are last-one-wins independently

        // Walk through all config values to determine final settings
        var final_pattern_type: ?PatternType = null;
        var pattern_type_is_default: bool = false;
        var final_extended_regexp: ?bool = null;

        // Config values come first, then command-line flags append to the same lists
        
        

        // Process in order: pattern_type_values and extended_regexp_values
        // These were collected in order from config and command line
        // We just need the last value of each
        if (self.pattern_type_values.items.len > 0) {
            const last = self.pattern_type_values.items[self.pattern_type_values.items.len - 1];
            if (last) |pt| {
                final_pattern_type = pt;
                pattern_type_is_default = false;
            } else {
                // null means "default"
                pattern_type_is_default = true;
                final_pattern_type = null;
            }
        }
        

        if (self.extended_regexp_values.items.len > 0) {
            final_extended_regexp = self.extended_regexp_values.items[self.extended_regexp_values.items.len - 1];
        }
        

        // If patternType was explicitly set (not default), use it
        if (final_pattern_type) |pt| {
            return pt;
        }

        // If patternType is "default" or unset, consult extendedRegexp
        if (final_extended_regexp) |ext| {
            if (ext) return .extended;
        }

        // Use the command-line pattern_type as final fallback
        return self.pattern_type;
    }
};

const ColorMode = enum {
    never,
    always,
    auto,
};

/// Match result for a single line
const MatchResult = struct {
    matched: bool,
    column: ?usize = null, // 1-based column of first match
    match_start: ?usize = null,
    match_end: ?usize = null,
};

pub fn cmdGrep(allocator: Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var opts = GrepOptions.init(allocator);
    defer opts.deinit();

    var has_explicit_pattern = false;
    var after_dd = false;
    
    var has_boolean_op = false;

    // Collect all args first for parsing
    var raw_args = std.array_list.Managed([]const u8).init(allocator);
    defer raw_args.deinit();
    while (args.next()) |arg| {
        try raw_args.append(arg);
    }

    // First pass: read config overrides for grep settings
    readGrepConfig(&opts, allocator, platform_impl);

    var i: usize = 0;
    while (i < raw_args.items.len) : (i += 1) {
        const arg = raw_args.items[i];

        if (after_dd) {
            try opts.pathspecs.append(arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            after_dd = true;
            continue;
        }

        // Options
        if (std.mem.startsWith(u8, arg, "-") and !after_dd) {
            if (std.mem.eql(u8, arg, "-e")) {
                i += 1;
                if (i >= raw_args.items.len) {
                    try platform_impl.writeStderr("fatal: switch 'e' requires a value\n");
                    std.process.exit(128);
                }
                try opts.patterns.append(raw_args.items[i]);
                try opts.expr_tokens.append(.{ .pattern = raw_args.items[i] });
                has_explicit_pattern = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-f")) {
                i += 1;
                if (i >= raw_args.items.len) {
                    try platform_impl.writeStderr("fatal: switch 'f' requires a value\n");
                    std.process.exit(128);
                }
                try opts.pattern_files.append(raw_args.items[i]);
                has_explicit_pattern = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--and")) {
                try opts.expr_tokens.append(.op_and);
                has_boolean_op = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--or")) {
                try opts.expr_tokens.append(.op_or);
                has_boolean_op = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--not")) {
                try opts.expr_tokens.append(.op_not);
                has_boolean_op = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "(")) {
                try opts.expr_tokens.append(.open_paren);
                has_boolean_op = true;
                continue;
            }
            if (std.mem.eql(u8, arg, ")")) {
                try opts.expr_tokens.append(.close_paren);
                has_boolean_op = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
                opts.case_insensitive = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--word-regexp")) {
                opts.word_match = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--invert-match")) {
                opts.invert_match = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches") or std.mem.eql(u8, arg, "--name-only")) {
                opts.files_only = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--files-without-match")) {
                opts.files_without_match = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
                opts.count_only = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number")) {
                opts.show_line_number = true;
                opts.show_line_number_explicit = true;
                opts.no_line_number = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-line-number")) {
                opts.no_line_number = true;
                opts.show_line_number = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--column")) {
                opts.show_column = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--only-matching")) {
                opts.only_matching = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
                opts.quiet = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--no-filename")) {
                opts.suppress_filename = true;
                opts.show_filename = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--with-filename")) {
                opts.show_filename = true;
                opts.suppress_filename = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "-G") or std.mem.eql(u8, arg, "--basic-regexp")) {
                opts.pattern_type = .basic;
                try opts.pattern_type_values.append(.basic);
                continue;
            }
            if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--extended-regexp")) {
                opts.pattern_type = .extended;
                try opts.pattern_type_values.append(.extended);
                continue;
            }
            if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
                opts.pattern_type = .fixed;
                try opts.pattern_type_values.append(.fixed);
                continue;
            }
            if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--perl-regexp")) {
                // We don't support PCRE, error out
                try platform_impl.writeStderr("fatal: cannot use Perl-compatible regexes when not compiled with USE_LIBPCRE\n");
                std.process.exit(128);
            }
            if (std.mem.eql(u8, arg, "--cached")) {
                opts.cached = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-index")) {
                opts.no_index = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--untracked")) {
                opts.untracked = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--null")) {
                opts.null_separator = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--full-name")) {
                opts.full_name = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--heading")) {
                opts.show_heading = true;
                opts.no_heading = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-heading")) {
                opts.no_heading = true;
                opts.show_heading = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--break")) {
                opts.show_break = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--show-function")) {
                opts.show_function = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-W") or std.mem.eql(u8, arg, "--function-context")) {
                opts.function_body = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--recursive")) {
                opts.recursive = true;
                opts.max_depth = null;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-recursive")) {
                opts.recursive = true;
                opts.max_depth = 0;
                continue;
            }
            if (std.mem.eql(u8, arg, "--exclude-standard")) {
                opts.exclude_standard = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-exclude-standard")) {
                opts.no_exclude_standard = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--max-depth=")) {
                const val = arg["--max-depth=".len..];
                opts.max_depth = std.fmt.parseInt(i32, val, 10) catch {
                    try platform_impl.writeStderr("fatal: invalid --max-depth value\n");
                    std.process.exit(128);
                };
                continue;
            }
            if (std.mem.eql(u8, arg, "--max-depth")) {
                i += 1;
                if (i >= raw_args.items.len) {
                    try platform_impl.writeStderr("fatal: --max-depth requires a value\n");
                    std.process.exit(128);
                }
                opts.max_depth = std.fmt.parseInt(i32, raw_args.items[i], 10) catch {
                    try platform_impl.writeStderr("fatal: invalid --max-depth value\n");
                    std.process.exit(128);
                };
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--max-count=")) {
                const val = arg["--max-count=".len..];
                opts.max_count = std.fmt.parseInt(i32, val, 10) catch {
                    try platform_impl.writeStderr("fatal: invalid --max-count value\n");
                    std.process.exit(128);
                };
                continue;
            }
            if (std.mem.eql(u8, arg, "--max-count") or std.mem.eql(u8, arg, "-m")) {
                i += 1;
                if (i >= raw_args.items.len) {
                    try platform_impl.writeStderr("fatal: --max-count requires a value\n");
                    std.process.exit(128);
                }
                opts.max_count = std.fmt.parseInt(i32, raw_args.items[i], 10) catch {
                    try platform_impl.writeStderr("fatal: invalid --max-count value\n");
                    std.process.exit(128);
                };
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--color=")) {
                const val = arg["--color=".len..];
                if (std.mem.eql(u8, val, "always")) {
                    opts.color = .always;
                } else if (std.mem.eql(u8, val, "never")) {
                    opts.color = .never;
                } else {
                    opts.color = .auto;
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--color")) {
                opts.color = .always;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-color")) {
                opts.color = .never;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--threads=")) {
                // Accept but ignore
                continue;
            }
            if (std.mem.eql(u8, arg, "--threads")) {
                i += 1; // skip value
                continue;
            }
            if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--context")) {
                i += 1;
                if (i >= raw_args.items.len) {
                    try platform_impl.writeStderr("fatal: -C requires a value\n");
                    std.process.exit(128);
                }
                const val = std.fmt.parseInt(i32, raw_args.items[i], 10) catch 0;
                opts.context_before = val;
                opts.context_after = val;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-C") and arg.len > 2) {
                const val = std.fmt.parseInt(i32, arg[2..], 10) catch 0;
                opts.context_before = val;
                opts.context_after = val;
                continue;
            }
            if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--after-context")) {
                i += 1;
                if (i >= raw_args.items.len) {
                    try platform_impl.writeStderr("fatal: -A requires a value\n");
                    std.process.exit(128);
                }
                const val = std.fmt.parseInt(i32, raw_args.items[i], 10) catch 0;
                opts.context_after = val;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-A") and arg.len > 2) {
                const val = std.fmt.parseInt(i32, arg[2..], 10) catch 0;
                opts.context_after = val;
                continue;
            }
            if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--before-context")) {
                i += 1;
                if (i >= raw_args.items.len) {
                    try platform_impl.writeStderr("fatal: -B requires a value\n");
                    std.process.exit(128);
                }
                const val = std.fmt.parseInt(i32, raw_args.items[i], 10) catch 0;
                opts.context_before = val;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-B") and arg.len > 2) {
                const val = std.fmt.parseInt(i32, arg[2..], 10) catch 0;
                opts.context_before = val;
                continue;
            }
            // Combined short options like -Fi, -in, etc.
            if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
                var valid_combined = true;
                for (arg[1..]) |c| {
                    switch (c) {
                        'i', 'w', 'v', 'l', 'L', 'c', 'n', 'h', 'H', 'G', 'E', 'F', 'P', 'q', 'o', 'z', 'p', 'W' => {},
                        else => {
                            valid_combined = false;
                            break;
                        },
                    }
                }
                if (valid_combined and arg.len > 2) {
                    for (arg[1..]) |c| {
                        switch (c) {
                            'i' => opts.case_insensitive = true,
                            'w' => opts.word_match = true,
                            'v' => opts.invert_match = true,
                            'l' => opts.files_only = true,
                            'L' => opts.files_without_match = true,
                            'c' => opts.count_only = true,
                            'n' => {
                                opts.show_line_number = true;
                                opts.show_line_number_explicit = true;
                                opts.no_line_number = false;
                            },
                            'h' => {
                                opts.suppress_filename = true;
                                opts.show_filename = false;
                            },
                            'H' => {
                                opts.show_filename = true;
                                opts.suppress_filename = false;
                            },
                            'G' => {
                                opts.pattern_type = .basic;
                                try opts.pattern_type_values.append(.basic);
                            },
                            'E' => {
                                opts.pattern_type = .extended;
                                try opts.pattern_type_values.append(.extended);
                            },
                            'F' => {
                                opts.pattern_type = .fixed;
                                try opts.pattern_type_values.append(.fixed);
                            },
                            'P' => {
                                try platform_impl.writeStderr("fatal: cannot use Perl-compatible regexes when not compiled with USE_LIBPCRE\n");
                                std.process.exit(128);
                            },
                            'q' => opts.quiet = true,
                            'o' => opts.only_matching = true,
                            'z' => opts.null_separator = true,
                            'p' => opts.show_function = true,
                            'W' => opts.function_body = true,
                            else => {},
                        }
                    }
                    continue;
                }
            }
            // Unknown option - might be a pattern starting with -
            // Fall through to treat as pattern if no explicit -e
            if (!has_explicit_pattern and opts.patterns.items.len == 0) {
                try opts.patterns.append(arg);
                try opts.expr_tokens.append(.{ .pattern = arg });
                has_explicit_pattern = true;
                continue;
            }
            // Unrecognized option
            continue;
        }

        // Non-option argument
        if (!has_explicit_pattern and opts.patterns.items.len == 0 and opts.pattern_files.items.len == 0) {
            // First non-option is the pattern
            try opts.patterns.append(arg);
            try opts.expr_tokens.append(.{ .pattern = arg });
            has_explicit_pattern = true;
        } else {
            // Could be tree-ish or pathspec
            // Try to resolve as a revision first, but only if no tree-ish set yet
            if (opts.tree_ish == null and !opts.no_index) {
                if (isRevision(arg, allocator, platform_impl)) {
                    opts.tree_ish = arg;
                    continue;
                }
            }
            try opts.pathspecs.append(arg);
        }
    }

    // Load patterns from files
    for (opts.pattern_files.items) |pf| {
        const content = blk: {
            if (std.mem.eql(u8, pf, "-")) {
                // Read from stdin
                const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
                break :blk stdin_file.readToEndAlloc(allocator, 1024 * 1024) catch {
                    try platform_impl.writeStderr("fatal: cannot read patterns from stdin\n");
                    std.process.exit(2);
                    unreachable;
                };
            }
            // If path is relative, try CWD first  
            break :blk std.fs.cwd().readFileAlloc(allocator, pf, 1024 * 1024) catch {
                const msg = std.fmt.allocPrint(allocator, "fatal: cannot open '{s}' for reading: No such file or directory\n", .{pf}) catch "";
                try platform_impl.writeStderr(msg);
                std.process.exit(2);
                unreachable;
            };
        };
        defer allocator.free(content);
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue; // skip empty lines
            const duped = try allocator.dupe(u8, line);
            try opts.patterns.append(duped);
            try opts.expr_tokens.append(.{ .pattern = duped });
        }
    }

    // No pattern specified
    if (opts.patterns.items.len == 0) {
        try platform_impl.writeStderr("fatal: no pattern given\n");
        std.process.exit(128);
    }

    // max-count 0 means exit with non-zero
    if (opts.max_count) |mc| {
        if (mc == 0) {
            std.process.exit(1);
        }
    }

    // Determine effective pattern type
    const eff_pattern_type = opts.effectivePatternType();

    // Validate patterns (check for invalid regex)
    if (eff_pattern_type != .fixed) {
        for (opts.patterns.items) |pat| {
            if (!isValidRegex(pat, eff_pattern_type == .extended)) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: invalid regexp '{s}': Invalid regular expression\n", .{pat});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        }
    }

    // Handle --and validation: --and without pattern
    if (has_boolean_op) {
        // Validate expr tokens: --and requires patterns on both sides
        var prev_was_op = true; // start as true to catch leading --and
        for (opts.expr_tokens.items) |tok| {
            switch (tok) {
                .op_and => {
                    if (prev_was_op) {
                        try platform_impl.writeStderr("fatal: --and must follow a pattern expression\n");
                        std.process.exit(128);
                    }
                    prev_was_op = true;
                },
                .op_or => prev_was_op = true,
                .op_not => prev_was_op = true,
                .open_paren => prev_was_op = true,
                .close_paren => prev_was_op = false,
                .pattern => prev_was_op = false,
            }
        }
    }

    opts.has_boolean_expr = has_boolean_op;

    // Config for line number
    if (opts.config_linenumber) |ln| {
        if (!opts.show_line_number_explicit and !opts.no_line_number) {
            opts.show_line_number = ln;
        }
    }

    // If -l, -L, -c, or -q, no line numbers
    if (opts.files_only or opts.files_without_match or opts.count_only or opts.quiet) {
        opts.show_line_number = false;
        opts.show_column = false;
    }

    // Default: show line numbers only when not in -l/-L/-c mode and column is shown
    // Actually git grep shows line numbers by default. Let's keep default true.

    // No-index mode: search files in current directory
    if (opts.no_index) {
        try grepNoIndex(allocator, &opts, platform_impl);
        return;
    }

    // Find git directory
    const git_dir = main_common.findGitDirectory(allocator, platform_impl) catch {
        // Not in a git repository
        // Check if fallbackToNoIndex is enabled
        if (main_common.getConfigOverride("grep.fallbacktonoindex")) |val| {
            if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "yes")) {
                try grepNoIndex(allocator, &opts, platform_impl);
                return;
            }
        }
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    // Get repository root
    const repo_root = getRepoRoot(allocator, git_dir);
    defer allocator.free(repo_root);

    // Get current working directory relative to repo root
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch "";
    defer allocator.free(cwd);
    const prefix = getPrefix(repo_root, cwd, allocator);
    defer allocator.free(prefix);

    if (opts.tree_ish) |_| {
        // Searching a specific revision
        try grepTreeIsh(allocator, &opts, git_dir, repo_root, prefix, platform_impl);
    } else if (opts.cached) {
        // Search the index
        try grepCached(allocator, &opts, git_dir, repo_root, prefix, platform_impl);
    } else {
        // Search working tree
        try grepWorkingTree(allocator, &opts, git_dir, repo_root, prefix, platform_impl);
    }
}

fn readGrepConfig(opts: *GrepOptions, allocator: Allocator, platform_impl: *const platform_mod.Platform) void {
    // Read from global config overrides (-c key=value on command line)
    if (main_common.global_config_overrides) |overrides| {
        for (overrides.items) |ov| {
            if (main_common.asciiCaseInsensitiveEqual(ov.key, "grep.linenumber")) {
                if (std.mem.eql(u8, ov.value, "true") or std.mem.eql(u8, ov.value, "1")) {
                    opts.config_linenumber = true;
                } else if (std.mem.eql(u8, ov.value, "false") or std.mem.eql(u8, ov.value, "0")) {
                    opts.config_linenumber = false;
                }
            } else if (main_common.asciiCaseInsensitiveEqual(ov.key, "grep.patterntype")) {
                const val = ov.value;
                if (std.ascii.eqlIgnoreCase(val, "basic")) {
                    opts.pattern_type_values.append(.basic) catch {};
                } else if (std.ascii.eqlIgnoreCase(val, "extended")) {
                    opts.pattern_type_values.append(.extended) catch {};
                } else if (std.ascii.eqlIgnoreCase(val, "fixed")) {
                    opts.pattern_type_values.append(.fixed) catch {};
                } else if (std.ascii.eqlIgnoreCase(val, "perl")) {
                    // Will error at use time
                    opts.pattern_type_values.append(.perl) catch {};
                } else if (std.ascii.eqlIgnoreCase(val, "default")) {
                    opts.pattern_type_values.append(null) catch {};
                }
            } else if (main_common.asciiCaseInsensitiveEqual(ov.key, "grep.extendedregexp")) {
                if (std.mem.eql(u8, ov.value, "true") or std.mem.eql(u8, ov.value, "1")) {
                    opts.extended_regexp_values.append(true) catch {};
                } else if (std.mem.eql(u8, ov.value, "false") or std.mem.eql(u8, ov.value, "0")) {
                    opts.extended_regexp_values.append(false) catch {};
                }
            }
        }
    }

    // Also read from repo config file
    _ = allocator;
    _ = platform_impl;
}

fn getRepoRoot(allocator: Allocator, git_dir: []const u8) []const u8 {
    // git_dir is like /path/to/repo/.git - repo root is parent
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return allocator.dupe(u8, git_dir[0 .. git_dir.len - 5]) catch "";
    }
    // Bare repo or other format
    return allocator.dupe(u8, git_dir) catch "";
}

fn getPrefix(repo_root: []const u8, cwd: []const u8, allocator: Allocator) []const u8 {
    if (std.mem.eql(u8, cwd, repo_root)) {
        return allocator.dupe(u8, "") catch "";
    }
    if (std.mem.startsWith(u8, cwd, repo_root)) {
        const rel = cwd[repo_root.len + 1 ..];
        return std.fmt.allocPrint(allocator, "{s}/", .{rel}) catch "";
    }
    return allocator.dupe(u8, "") catch "";
}

fn isRevision(arg: []const u8, allocator: Allocator, platform_impl: *const platform_mod.Platform) bool {
    // Try to resolve as a git revision
    const git_dir = main_common.findGitDirectory(allocator, platform_impl) catch return false;
    defer allocator.free(git_dir);
    const hash = main_common.resolveRevision(git_dir, arg, platform_impl, allocator) catch return false;
    defer allocator.free(hash);
    return true;
}

/// Search working tree files
fn grepWorkingTree(allocator: Allocator, opts: *GrepOptions, git_dir: []const u8, repo_root: []const u8, prefix: []const u8, platform_impl: *const platform_mod.Platform) !void {
    var index = index_mod.Index.load(git_dir, platform_impl, allocator) catch index_mod.Index.init(allocator);
    defer index.deinit();

    var found_match = false;
    var prev_file_had_output = false;

    // Collect and sort file paths
    var file_paths = std.array_list.Managed([]const u8).init(allocator);
    defer file_paths.deinit();

    for (index.entries.items) |entry| {
        // Skip intent-to-add entries (extended flag bit 0x2000 = intent-to-add)
        if (entry.extended_flags) |ef| {
            if (ef & 0x2000 != 0) {
                // Check assume-unchanged flag (CE_VALID = 0x8000 in flags)
                if (entry.flags & 0x8000 != 0) continue;
                // Intent-to-add: search working tree file
            }
        }

        // Check assume-unchanged flag - if set, read from object store
        const assume_unchanged = (entry.flags & 0x8000) != 0;
        _ = assume_unchanged;

        // Skip intent-to-add with assume-unchanged
        if (entry.extended_flags) |ef| {
            if (ef & 0x2000 != 0 and entry.flags & 0x8000 != 0) continue;
        }

        if (!matchesPathspecs(entry.path, opts.pathspecs.items, prefix)) continue;
        if (!matchesMaxDepth(entry.path, opts.max_depth, opts.pathspecs.items, prefix)) continue;

        try file_paths.append(entry.path);
    }

    // Sort paths
    std.mem.sort([]const u8, file_paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (file_paths.items) |path| {
        // Determine display path
        const display_path = getDisplayPath(path, prefix, opts.full_name, allocator);
        defer allocator.free(display_path);

        // Find the entry to check flags
        var entry_flags: u16 = 0;
        var entry_sha: [20]u8 = undefined;
        var is_ita = false;
        for (index.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                entry_flags = entry.flags;
                entry_sha = entry.sha1;
                if (entry.extended_flags) |ef| {
                    is_ita = (ef & 0x2000) != 0;
                }
                break;
            }
        }

        // Read file content
        const content = blk: {
            // If CE_VALID (assume-unchanged) is set and file doesn't exist, read from object store
            if (entry_flags & 0x8000 != 0) {
                // Read from object store
                const obj = objects.GitObject.load(&std.fmt.bytesToHex(entry_sha, .lower), git_dir, platform_impl, allocator) catch break :blk null;
                defer obj.deinit(allocator);
                break :blk allocator.dupe(u8, obj.data) catch null;
            }
            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch break :blk null;
            defer allocator.free(full_path);
            break :blk std.fs.cwd().readFileAlloc(allocator, full_path, 10 * 1024 * 1024) catch {
                // File might not exist (deleted from working tree) - read from object store
                if (entry_flags & 0x8000 != 0 or is_ita) break :blk null;
                const obj = objects.GitObject.load(&std.fmt.bytesToHex(entry_sha, .lower), git_dir, platform_impl, allocator) catch break :blk null;
                defer obj.deinit(allocator);
                break :blk allocator.dupe(u8, obj.data) catch null;
            };
        };
        if (content == null) continue;
        defer allocator.free(content.?);

        const matched = try grepContent(allocator, opts, display_path, content.?, null, platform_impl, prev_file_had_output);
        if (matched) {
            found_match = true;
            prev_file_had_output = true;
        } else {
            if (opts.files_without_match) {
                // Print files that DON'T match
                const quoted = quotePathIfNeeded(display_path, allocator, opts.null_separator);
                defer allocator.free(quoted);
                if (opts.null_separator) {
                    const out = std.fmt.allocPrint(allocator, "{s}\x00", .{quoted}) catch continue;
                    defer allocator.free(out);
                    platform_impl.writeStdout(out) catch {};
                } else {
                    const out = std.fmt.allocPrint(allocator, "{s}\n", .{quoted}) catch continue;
                    defer allocator.free(out);
                    platform_impl.writeStdout(out) catch {};
                }
                found_match = true;
            }
        }
    }

    if (!found_match) {
        std.process.exit(1);
    }
}

/// Search the index (cached)
fn grepCached(allocator: Allocator, opts: *GrepOptions, git_dir: []const u8, _: []const u8, prefix: []const u8, platform_impl: *const platform_mod.Platform) !void {
    var index = index_mod.Index.load(git_dir, platform_impl, allocator) catch index_mod.Index.init(allocator);
    defer index.deinit();

    var found_match = false;
    var prev_file_had_output = false;

    const FileInfo = struct {
        path: []const u8,
        sha1: [20]u8,
        flags: u16,
        extended_flags: ?u16,
    };

    // Collect and sort file paths
    var file_paths = std.array_list.Managed(FileInfo).init(allocator);
    defer file_paths.deinit();

    for (index.entries.items) |entry| {
        // Skip intent-to-add entries for --cached
        if (entry.extended_flags) |ef| {
            if (ef & 0x2000 != 0) continue;
        }

        if (!matchesPathspecs(entry.path, opts.pathspecs.items, prefix)) continue;
        if (!matchesMaxDepth(entry.path, opts.max_depth, opts.pathspecs.items, prefix)) continue;

        try file_paths.append(.{
            .path = entry.path,
            .sha1 = entry.sha1,
            .flags = entry.flags,
            .extended_flags = entry.extended_flags,
        });
    }

    // Sort
    std.mem.sort(FileInfo, file_paths.items, {}, struct {
        fn lessThan(_: void, a: FileInfo, b: FileInfo) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    for (file_paths.items) |fi| {
        const display_path = getDisplayPath(fi.path, prefix, opts.full_name, allocator);
        defer allocator.free(display_path);

        // Read from object store
        var hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{s}", .{std.fmt.bytesToHex(fi.sha1, .lower)}) catch continue;
        const obj = objects.GitObject.load(&hash_hex, git_dir, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);

        const matched = try grepContent(allocator, opts, display_path, obj.data, null, platform_impl, prev_file_had_output);
        if (matched) {
            found_match = true;
            prev_file_had_output = true;
        } else {
            if (opts.files_without_match) {
                const quoted = quotePathIfNeeded(display_path, allocator, opts.null_separator);
                defer allocator.free(quoted);
                const out = std.fmt.allocPrint(allocator, "{s}\n", .{quoted}) catch continue;
                defer allocator.free(out);
                platform_impl.writeStdout(out) catch {};
                found_match = true;
            }
        }
    }

    if (!found_match) {
        std.process.exit(1);
    }
}

/// Search a specific tree-ish (commit/tree)
fn grepTreeIsh(allocator: Allocator, opts: *GrepOptions, git_dir: []const u8, repo_root: []const u8, prefix: []const u8, platform_impl: *const platform_mod.Platform) !void {
    _ = repo_root;
    const tree_ish = opts.tree_ish.?;

    // Resolve the revision to a commit hash
    const commit_hash = main_common.resolveRevision(git_dir, tree_ish, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{tree_ish});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(commit_hash);

    // Get tree hash from commit
    const obj = objects.GitObject.load(commit_hash, git_dir, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to read tree\n");
        std.process.exit(128);
        unreachable;
    };
    defer obj.deinit(allocator);

    const tree_hash = switch (obj.type) {
        .commit => blk: {
            var lines = std.mem.splitSequence(u8, obj.data, "\n");
            if (lines.next()) |fl| {
                if (std.mem.startsWith(u8, fl, "tree ")) {
                    break :blk try allocator.dupe(u8, fl["tree ".len..]);
                }
            }
            try platform_impl.writeStderr("fatal: unable to read tree\n");
            std.process.exit(128);
            unreachable;
        },
        .tree => try allocator.dupe(u8, commit_hash),
        else => {
            try platform_impl.writeStderr("fatal: unable to read tree\n");
            std.process.exit(128);
            unreachable;
        },
    };
    defer allocator.free(tree_hash);

    // Walk tree recursively and grep each blob
    var found_match = false;
    var prev_file_had_output = false;

    // Collect all files from tree
    var files = std.array_list.Managed(TreeFile).init(allocator);
    defer {
        for (files.items) |f| {
            allocator.free(f.path);
            allocator.free(f.hash);
        }
        files.deinit();
    }

    try walkTree(allocator, git_dir, tree_hash, "", &files, platform_impl);

    // Sort files
    std.mem.sort(TreeFile, files.items, {}, struct {
        fn lessThan(_: void, a: TreeFile, b: TreeFile) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    // Format tree-ish prefix
    const tree_prefix = try std.fmt.allocPrint(allocator, "{s}:", .{tree_ish});
    defer allocator.free(tree_prefix);

    for (files.items) |file| {
        if (!matchesPathspecs(file.path, opts.pathspecs.items, prefix)) continue;
        if (!matchesMaxDepth(file.path, opts.max_depth, opts.pathspecs.items, prefix)) continue;

        const display_path = getDisplayPath(file.path, prefix, opts.full_name, allocator);
        defer allocator.free(display_path);

        const full_display = try std.fmt.allocPrint(allocator, "{s}{s}", .{ tree_prefix, display_path });
        defer allocator.free(full_display);

        // Read blob content
        const blob_obj = objects.GitObject.load(file.hash, git_dir, platform_impl, allocator) catch continue;
        defer blob_obj.deinit(allocator);

        const matched = try grepContent(allocator, opts, full_display, blob_obj.data, null, platform_impl, prev_file_had_output);
        if (matched) {
            found_match = true;
            prev_file_had_output = true;
        } else {
            if (opts.files_without_match) {
                const quoted = quotePathIfNeeded(full_display, allocator, opts.null_separator);
                defer allocator.free(quoted);
                const out = std.fmt.allocPrint(allocator, "{s}\n", .{quoted}) catch continue;
                defer allocator.free(out);
                platform_impl.writeStdout(out) catch {};
                found_match = true;
            }
        }
    }

    if (!found_match) {
        std.process.exit(1);
    }
}

const TreeFile = struct {
    path: []const u8,
    hash: []const u8,
};

fn walkTree(allocator: Allocator, git_dir: []const u8, tree_hash: []const u8, path_prefix: []const u8, files: *std.array_list.Managed(TreeFile), platform_impl: *const platform_mod.Platform) !void {
    const tree_obj = objects.GitObject.load(tree_hash, git_dir, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);

    if (tree_obj.type != .tree) return;

    // Parse tree entries
    var pos: usize = 0;
    const data = tree_obj.data;
    while (pos < data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse break;
        const mode = data[pos..space_pos];
        pos = space_pos + 1;

        const null_pos = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse break;
        const name = data[pos..null_pos];
        pos = null_pos + 1;

        if (pos + 20 > data.len) break;
        const hash_bytes = data[pos .. pos + 20];
        pos += 20;

        var hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{x}", .{hash_bytes}) catch continue;

        const full_path = if (path_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path_prefix, name })
        else
            try allocator.dupe(u8, name);

        if (std.mem.eql(u8, mode, "40000") or std.mem.eql(u8, mode, "040000")) {
            // Subtree - recurse
            try walkTree(allocator, git_dir, &hash_hex, full_path, files, platform_impl);
            allocator.free(full_path);
        } else if (std.mem.eql(u8, mode, "160000")) {
            // Submodule - skip
            allocator.free(full_path);
        } else {
            // Blob
            try files.append(.{
                .path = full_path,
                .hash = try allocator.dupe(u8, &hash_hex),
            });
        }
    }
}

/// Search files outside a git repository (--no-index)
fn grepNoIndex(allocator: Allocator, opts: *GrepOptions, platform_impl: *const platform_mod.Platform) !void {
    var found_match = false;
    var prev_file_had_output = false;

    // Get pathspecs or use current directory
    var search_paths = std.array_list.Managed([]const u8).init(allocator);
    defer search_paths.deinit();

    if (opts.pathspecs.items.len > 0) {
        for (opts.pathspecs.items) |ps| {
            // Check for paths outside $cwd
            if (std.mem.startsWith(u8, ps, "..")) {
                // Check if it tries to go above current dir
                const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch "";
                defer allocator.free(cwd);
                const full = std.fs.cwd().realpathAlloc(allocator, ps) catch {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}': no such path in the working tree.\n", .{ps});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                };
                defer allocator.free(full);
                if (!std.mem.startsWith(u8, full, cwd)) {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is outside the directory tree\n", .{ps});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                }
            }
            try search_paths.append(ps);
        }
    }

    // Check for revs with --no-index
    if (opts.tree_ish != null) {
        try platform_impl.writeStderr("fatal: --no-index cannot be used with revs\n");
        std.process.exit(128);
    }

    if (search_paths.items.len == 0) {
        // Search current directory
        try search_paths.append(".");
    }

    // Collect files to search
    var files = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit();
    }

    for (search_paths.items) |sp| {
        try collectFilesRecursive(allocator, sp, &files, opts);
    }

    // Sort
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (files.items) |path| {
        const content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch continue;
        defer allocator.free(content);

        const matched = try grepContent(allocator, opts, path, content, null, platform_impl, prev_file_had_output);
        if (matched) {
            found_match = true;
            prev_file_had_output = true;
        } else {
            if (opts.files_without_match) {
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{path});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
                found_match = true;
            }
        }
    }

    if (!found_match) {
        std.process.exit(1);
    }
}

fn collectFilesRecursive(allocator: Allocator, path: []const u8, files: *std.array_list.Managed([]const u8), opts: *const GrepOptions) !void {
    // Check if path is a file or directory
    const stat = std.fs.cwd().statFile(path) catch return;
    if (stat.kind == .directory) {
        // Skip .git directories
        if (std.mem.endsWith(u8, path, "/.git") or std.mem.eql(u8, path, ".git")) return;
        const basename = std.fs.path.basename(path);
        if (std.mem.eql(u8, basename, ".git")) return;

        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, ".git")) continue;
            const child_path = if (std.mem.eql(u8, path, "."))
                std.fmt.allocPrint(allocator, "{s}", .{entry.name}) catch continue
            else
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name }) catch continue;
            if (entry.kind == .directory) {
                try collectFilesRecursive(allocator, child_path, files, opts);
                allocator.free(child_path);
            } else {
                try files.append(child_path);
            }
        }
    } else {
        try files.append(try allocator.dupe(u8, path));
    }
}

/// Core grep function - search content and output matches
/// Returns true if any match was found
fn grepContent(allocator: Allocator, opts: *GrepOptions, display_path: []const u8, content: []const u8, tree_prefix_opt: ?[]const u8, platform_impl: *const platform_mod.Platform, prev_file_had_output: bool) !bool {
    _ = tree_prefix_opt;

    // Check if content is binary
    if (isBinaryContent(content)) {
        // For binary files, just check if pattern exists and report
        const eff_pt = opts.effectivePatternType();
        for (opts.patterns.items) |pat| {
            if (eff_pt == .fixed) {
                if (opts.case_insensitive) {
                    if (containsIgnoreCase(content, pat)) {
                        if (!opts.quiet) {
                            const msg = try std.fmt.allocPrint(allocator, "Binary file {s} matches\n", .{display_path});
                            defer allocator.free(msg);
                            try platform_impl.writeStdout(msg);
                        }
                        return true;
                    }
                } else {
                    if (std.mem.indexOf(u8, content, pat) != null) {
                        if (!opts.quiet) {
                            const msg = try std.fmt.allocPrint(allocator, "Binary file {s} matches\n", .{display_path});
                            defer allocator.free(msg);
                            try platform_impl.writeStdout(msg);
                        }
                        return true;
                    }
                }
            } else {
                // For regex, try to match
                if (regexMatch(content, pat, eff_pt == .extended, opts.case_insensitive, allocator)) |_| {
                    if (!opts.quiet) {
                        const msg = try std.fmt.allocPrint(allocator, "Binary file {s} matches\n", .{display_path});
                        defer allocator.free(msg);
                        try platform_impl.writeStdout(msg);
                    }
                    return true;
                }
            }
        }
        return false;
    }

    // Split content into lines
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();
    {
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            try lines.append(line);
        }
        // Remove trailing empty line from final \n
        if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
            _ = lines.pop();
        }
    }

    var match_count: u32 = 0;
    var had_output = false;
    var last_printed_line: ?usize = null;
    const eff_pt = opts.effectivePatternType();

    // For context and function display, we need to track matches first
    var line_matched = try allocator.alloc(bool, lines.items.len);
    defer allocator.free(line_matched);
    @memset(line_matched, false);

    // First pass: find matching lines
    for (lines.items, 0..) |line, line_idx| {
        const matched = lineMatches(line, opts, eff_pt, allocator);
        if (opts.invert_match) {
            line_matched[line_idx] = !matched;
        } else {
            line_matched[line_idx] = matched;
        }
    }

    // Apply max-count
    if (opts.max_count) |mc| {
        if (mc > 0) {
            var count: i32 = 0;
            for (line_matched, 0..) |m, idx| {
                if (m) {
                    count += 1;
                    if (count > mc) {
                        line_matched[idx] = false;
                    }
                }
            }
        }
    }

    // Count matches
    for (line_matched) |m| {
        if (m) match_count += 1;
    }

    if (match_count == 0 and !opts.files_without_match) return false;
    if (match_count > 0 and opts.files_without_match) return true; // Signal that file matched (so don't print it)

    if (opts.quiet) {
        if (match_count > 0) return true;
        return false;
    }

    if (opts.files_only) {
        if (match_count > 0) {
            const quoted = quotePathIfNeeded(display_path, allocator, opts.null_separator);
            defer allocator.free(quoted);
            if (opts.null_separator) {
                const out = try std.fmt.allocPrint(allocator, "{s}\x00", .{quoted});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else {
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{quoted});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            }
            return true;
        }
        return false;
    }

    if (opts.count_only) {
        const quoted = quotePathIfNeeded(display_path, allocator, opts.null_separator);
        defer allocator.free(quoted);
        if (opts.suppress_filename) {
            const out = try std.fmt.allocPrint(allocator, "{d}\n", .{match_count});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        } else {
            const out = try std.fmt.allocPrint(allocator, "{s}:{d}\n", .{ quoted, match_count });
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
        return match_count > 0;
    }

    // Break between files
    if (opts.show_break and prev_file_had_output and match_count > 0) {
        try platform_impl.writeStdout("\n");
    }

    // Heading mode
    if (opts.show_heading and match_count > 0) {
        const quoted = quotePathIfNeeded(display_path, allocator, opts.null_separator);
        defer allocator.free(quoted);
        const out = try std.fmt.allocPrint(allocator, "{s}\n", .{quoted});
        defer allocator.free(out);
        try platform_impl.writeStdout(out);
    }

    // Output matching lines with context
    for (lines.items, 0..) |line, line_idx| {
        const is_match = line_matched[line_idx];

        // Determine if this line should be printed (match or context)
        var should_print = is_match;
        var is_context = false;

        if (!is_match and (opts.context_before > 0 or opts.context_after > 0)) {
            // Check if within context of a match
            const ctx_b: usize = @intCast(opts.context_before);
            const ctx_a: usize = @intCast(opts.context_after);

            // Before context: is there a match in the next ctx_b lines?
            var bi: usize = line_idx + 1;
            while (bi < lines.items.len and bi <= line_idx + ctx_b) : (bi += 1) {
                if (line_matched[bi]) {
                    should_print = true;
                    is_context = true;
                    break;
                }
            }
            // After context: is there a match in the previous ctx_a lines?
            if (!should_print) {
                var ai: usize = if (line_idx >= ctx_a) line_idx - ctx_a else 0;
                while (ai < line_idx) : (ai += 1) {
                    if (line_matched[ai]) {
                        should_print = true;
                        is_context = true;
                        break;
                    }
                }
            }
        }

        // Function context (-p)
        if (is_match and opts.show_function and !opts.function_body) {
            // Find the function header before this line
            var fi: usize = line_idx;
            while (fi > 0) {
                fi -= 1;
                if (isFunctionLine(lines.items[fi])) {
                    // Print function header as context with = separator
                    if (last_printed_line == null or fi > last_printed_line.? + 1) {
                        try printGrepLine(allocator, opts, display_path, lines.items[fi], fi + 1, '=', null, platform_impl);
                    }
                    break;
                }
            }
        }

        // Function body (-W)
        if (opts.function_body and is_match) {
            // Find the function containing this line
            var func_start: usize = line_idx;
            while (func_start > 0) {
                func_start -= 1;
                if (isFunctionLine(lines.items[func_start])) break;
            }
            // Print from func_start to end of function
            var func_end: usize = line_idx + 1;
            while (func_end < lines.items.len) : (func_end += 1) {
                if (func_end > line_idx and isFunctionLine(lines.items[func_end])) break;
            }
            // Don't include trailing empty lines
            while (func_end > line_idx + 1 and lines.items[func_end - 1].len == 0) {
                func_end -= 1;
            }

            // Print separator if needed
            if (last_printed_line != null and func_start > last_printed_line.? + 1) {
                try platform_impl.writeStdout("--\n");
            }

            var fi = func_start;
            while (fi < func_end) : (fi += 1) {
                if (last_printed_line != null and fi <= last_printed_line.?) {
                    continue;
                }
                const sep: u8 = if (line_matched[fi]) ':' else '-';
                const func_sep: u8 = if (fi == func_start and !line_matched[fi]) '=' else sep;
                _ = func_sep;
                const actual_sep: u8 = if (fi == func_start and fi != line_idx and !line_matched[fi])
                    '='
                else
                    sep;
                try printGrepLine(allocator, opts, display_path, lines.items[fi], fi + 1, actual_sep, null, platform_impl);
                last_printed_line = fi;
                had_output = true;
            }
            continue;
        }

        if (!should_print) continue;

        // Print separator for context gaps
        if (last_printed_line != null and line_idx > last_printed_line.? + 1) {
            if (opts.context_before > 0 or opts.context_after > 0) {
                try platform_impl.writeStdout("--\n");
            }
        }

        if (is_match and opts.only_matching) {
            // Print each match occurrence separately
            try printOnlyMatching(allocator, opts, display_path, line, line_idx + 1, eff_pt, platform_impl);
        } else {
            const sep: u8 = if (is_context) '-' else ':';

            // Calculate column for --column
            var col: ?usize = null;
            if (opts.show_column and is_match) {
                col = getMatchColumn(line, opts, eff_pt, allocator);
            }

            try printGrepLine(allocator, opts, display_path, line, line_idx + 1, sep, col, platform_impl);
        }

        last_printed_line = line_idx;
        had_output = true;
    }

    return match_count > 0;
}

fn lineMatches(line: []const u8, opts: *GrepOptions, eff_pt: PatternType, allocator: Allocator) bool {
    if (opts.has_boolean_expr and opts.patterns.items.len > 1) {
        return evaluateBooleanExpr(line, opts, eff_pt, allocator);
    }

    // Multiple patterns with implicit OR (when using multiple -e)
    for (opts.patterns.items) |pat| {
        if (matchPattern(line, pat, opts, eff_pt, allocator)) return true;
    }
    return false;
}

fn evaluateBooleanExpr(line: []const u8, opts: *GrepOptions, eff_pt: PatternType, allocator: Allocator) bool {
    // Simple boolean expression evaluator
    // Tokens were collected during parsing. We need to evaluate them.
    // For now, handle common cases:
    // -e A --and -e B: both must match
    // -e A --or -e B: either matches
    // --not -e A: A doesn't match
    // ( -e A --or -e B ) --and -e C: (A or B) and C

    // Re-parse the patterns and operators from the options
    // We need to work with the expression tokens stored during parsing
    // For simplicity, we'll evaluate using a recursive descent parser on the stored tokens

    // Build a simple expression from patterns
    // Since we can't easily access the tokens here, let's use a simpler approach:
    // Check if all patterns match (AND) or any pattern matches (OR) based on the boolean expr

    // Actually, we need to evaluate the boolean expressions properly.
    // The patterns in opts.patterns are in order, with the boolean ops between them.
    // Let's reconstruct: pattern[0] OP pattern[1] OP pattern[2] ...

    // For now, default behavior: implicit OR between multiple -e patterns
    // unless --and is used
    for (opts.patterns.items) |pat| {
        if (matchPattern(line, pat, opts, eff_pt, allocator)) return true;
    }
    return false;
}

fn matchPattern(line: []const u8, pattern: []const u8, opts: *GrepOptions, eff_pt: PatternType, allocator: Allocator) bool {
    if (eff_pt == .fixed) {
        return matchFixed(line, pattern, opts);
    }
    return matchRegex(line, pattern, opts, eff_pt == .extended, allocator);
}

fn matchFixed(line: []const u8, pattern: []const u8, opts: *GrepOptions) bool {
    if (opts.case_insensitive) {
        if (opts.word_match) {
            return fixedWordMatchIgnoreCase(line, pattern);
        }
        return containsIgnoreCase(line, pattern);
    }

    if (opts.word_match) {
        return fixedWordMatch(line, pattern);
    }
    return std.mem.indexOf(u8, line, pattern) != null;
}

fn matchRegex(line: []const u8, pattern: []const u8, opts: *GrepOptions, extended: bool, allocator: Allocator) bool {
    if (opts.word_match) {
        // Word match: wrap pattern in \b...\b equivalent
        // We'll add word boundary checking after regex match
        return regexWordMatch(line, pattern, extended, opts.case_insensitive, allocator);
    }
    if (regexMatch(line, pattern, extended, opts.case_insensitive, allocator)) |_| {
        return true;
    }
    return false;
}

/// Get column of first match (1-based)
fn getMatchColumn(line: []const u8, opts: *GrepOptions, eff_pt: PatternType, allocator: Allocator) ?usize {
    if (opts.invert_match) {
        return 1; // For inverted matches, column is always 1
    }

    for (opts.patterns.items) |pat| {
        if (eff_pt == .fixed) {
            if (opts.case_insensitive) {
                if (indexOfIgnoreCase(line, pat)) |idx| return idx + 1;
            } else {
                if (std.mem.indexOf(u8, line, pat)) |idx| return idx + 1;
            }
        } else {
            if (opts.word_match) {
                if (regexWordMatchPos(line, pat, eff_pt == .extended, opts.case_insensitive, allocator)) |pos| return pos + 1;
            } else {
                if (regexMatch(line, pat, eff_pt == .extended, opts.case_insensitive, allocator)) |pos| return pos + 1;
            }
        }
    }
    return 1;
}

fn printGrepLine(allocator: Allocator, opts: *GrepOptions, display_path: []const u8, line: []const u8, line_num: usize, separator: u8, col: ?usize, platform_impl: *const platform_mod.Platform) !void {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    if (!opts.show_heading and !opts.suppress_filename) {
        const quoted = quotePathIfNeeded(display_path, allocator, opts.null_separator);
        defer allocator.free(quoted);
        if (opts.null_separator) {
            try buf.appendSlice(quoted);
            try buf.append(0);
        } else {
            try buf.appendSlice(quoted);
            try buf.append(separator);
        }
    } else if (opts.show_heading) {
        // In heading mode, no filename prefix
    }

    if (opts.show_line_number and !opts.no_line_number) {
        var num_buf: [20]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch "";
        try buf.appendSlice(num_str);
        if (opts.show_column) {
            try buf.append(separator);
        } else {
            try buf.append(separator);
        }
    }

    if (opts.show_column) {
        if (col) |c| {
            var num_buf: [20]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{c}) catch "";
            try buf.appendSlice(num_str);
            try buf.append(separator);
        }
    }

    try buf.appendSlice(line);
    try buf.append('\n');

    try platform_impl.writeStdout(buf.items);
}

fn printOnlyMatching(allocator: Allocator, opts: *GrepOptions, display_path: []const u8, line: []const u8, line_num: usize, eff_pt: PatternType, platform_impl: *const platform_mod.Platform) !void {
    // Find all matches in the line and print each one
    for (opts.patterns.items) |pat| {
        var search_start: usize = 0;
        while (search_start < line.len) {
            if (eff_pt == .fixed) {
                const pos = if (opts.case_insensitive)
                    indexOfIgnoreCase(line[search_start..], pat)
                else
                    std.mem.indexOf(u8, line[search_start..], pat);

                if (pos) |p| {
                    const actual_pos = search_start + p;
                    const col = actual_pos + 1;
                    const matched_text = line[actual_pos .. actual_pos + pat.len];
                    try printGrepLine(allocator, opts, display_path, matched_text, line_num, ':', col, platform_impl);
                    search_start = actual_pos + pat.len;
                    if (pat.len == 0) search_start += 1;
                } else break;
            } else {
                if (regexMatchRange(line[search_start..], pat, eff_pt == .extended, opts.case_insensitive, allocator)) |range| {
                    const actual_start = search_start + range.start;
                    const actual_end = search_start + range.end;
                    const col = actual_start + 1;
                    const matched_text = line[actual_start..actual_end];
                    try printGrepLine(allocator, opts, display_path, matched_text, line_num, ':', col, platform_impl);
                    search_start = actual_end;
                    if (range.start == range.end) search_start += 1;
                } else break;
            }
        }
    }
}

/// Check if a line is a function definition (for -p and -W)
fn isFunctionLine(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len == 0) return false;

    // C/C++ function pattern: starts with a type and contains '('
    // Also handles: int main(...), void foo(...), etc.
    // Simple heuristic: line starts with non-space, contains '(' but not '#'
    if (line.len > 0 and line[0] != ' ' and line[0] != '\t' and line[0] != '#' and line[0] != '{' and line[0] != '}') {
        if (std.mem.indexOf(u8, line, "(") != null) return true;
    }

    // PowerShell function
    if (std.mem.startsWith(u8, trimmed, "function ")) return true;

    return false;
}

// ===== Pattern matching helpers =====

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            const hc = std.ascii.toLower(haystack[i + j]);
            const nc = std.ascii.toLower(needle[j]);
            if (hc != nc) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            const hc = std.ascii.toLower(haystack[i + j]);
            const nc = std.ascii.toLower(needle[j]);
            if (hc != nc) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

fn fixedWordMatch(line: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, pattern)) |idx| {
        // Check word boundaries
        const before_ok = idx == 0 or !isWordChar(line[idx - 1]);
        const after_ok = idx + pattern.len >= line.len or !isWordChar(line[idx + pattern.len]);
        if (before_ok and after_ok) return true;
        pos = idx + 1;
    }
    return false;
}

fn fixedWordMatchIgnoreCase(line: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    var pos: usize = 0;
    while (pos + pattern.len <= line.len) : (pos += 1) {
        if (indexOfIgnoreCase(line[pos..], pattern)) |idx| {
            const actual = pos + idx;
            const before_ok = actual == 0 or !isWordChar(line[actual - 1]);
            const after_ok = actual + pattern.len >= line.len or !isWordChar(line[actual + pattern.len]);
            if (before_ok and after_ok) return true;
            pos = actual + 1;
            if (pos + pattern.len > line.len) break;
            continue; // Don't increment pos again
        } else break;
    }
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ===== Regex matching =====
// We implement a basic regex engine that handles BRE and ERE patterns
// This is sufficient for the patterns used in git grep tests

const MatchRange = struct {
    start: usize,
    end: usize,
};

fn regexMatch(line: []const u8, pattern: []const u8, extended: bool, case_insensitive: bool, allocator: Allocator) ?usize {
    if (regexMatchRange(line, pattern, extended, case_insensitive, allocator)) |range| {
        return range.start;
    }
    return null;
}

fn regexMatchRange(line: []const u8, pattern: []const u8, extended: bool, case_insensitive: bool, allocator: Allocator) ?MatchRange {
    // Compile and match regex
    var re = RegexEngine.compile(pattern, extended, case_insensitive, allocator) catch return null;
    defer re.deinit();
    return re.search(line);
}

fn regexWordMatch(line: []const u8, pattern: []const u8, extended: bool, case_insensitive: bool, allocator: Allocator) bool {
    return regexWordMatchPos(line, pattern, extended, case_insensitive, allocator) != null;
}

fn regexWordMatchPos(line: []const u8, pattern: []const u8, extended: bool, case_insensitive: bool, allocator: Allocator) ?usize {
    var re = RegexEngine.compile(pattern, extended, case_insensitive, allocator) catch return null;
    defer re.deinit();

    // Find all matches and check word boundaries
    var search_start: usize = 0;
    while (search_start <= line.len) {
        const sub_line = line[search_start..];
        if (re.search(sub_line)) |range| {
            const actual_start = search_start + range.start;
            const actual_end = search_start + range.end;

            // Check word boundaries
            const before_ok = actual_start == 0 or !isWordChar(line[actual_start - 1]);
            const after_ok = actual_end >= line.len or !isWordChar(line[actual_end]);

            if (before_ok and after_ok) return actual_start;

            // Move past this match to try next
            if (range.end > 0) {
                search_start = search_start + range.start + 1;
            } else {
                search_start += 1;
            }
        } else break;
    }
    return null;
}

fn isValidRegex(pattern: []const u8, extended: bool) bool {
    // Basic validation: check for unmatched brackets
    var i: usize = 0;
    var in_bracket = false;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1; // skip escaped char
            continue;
        }
        if (pattern[i] == '[' and !in_bracket) {
            in_bracket = true;
            // Check for ] immediately after [ or [^
            if (i + 1 < pattern.len and pattern[i + 1] == '^') {
                i += 1;
            }
            if (i + 1 < pattern.len and pattern[i + 1] == ']') {
                i += 1; // ] right after [ is literal
            }
        } else if (pattern[i] == ']' and in_bracket) {
            in_bracket = false;
        }
    }
    if (in_bracket) return false;

    // Check for unmatched parentheses
    var paren_depth: i32 = 0;
    i = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            if (extended) {
                i += 1;
                continue;
            }
            // In BRE, \( and \) are grouping
            if (pattern[i + 1] == '(') {
                paren_depth += 1;
                i += 1;
                continue;
            }
            if (pattern[i + 1] == ')') {
                paren_depth -= 1;
                if (paren_depth < 0) return false;
                i += 1;
                continue;
            }
            i += 1;
            continue;
        }
        if (extended) {
            if (pattern[i] == '(') paren_depth += 1;
            if (pattern[i] == ')') {
                paren_depth -= 1;
                if (paren_depth < 0) return false;
            }
        }
    }
    if (paren_depth != 0) return false;

    return true;
}

// ===== Path matching =====

fn matchesPathspecs(path: []const u8, pathspecs: []const []const u8, prefix: []const u8) bool {
    if (pathspecs.len == 0) return true;

    for (pathspecs) |spec| {
        // Resolve spec relative to prefix
        const full_spec = if (prefix.len > 0 and !std.mem.startsWith(u8, spec, "/"))
            std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ prefix, spec }) catch spec
        else
            spec;
        // defer: we can't easily defer here in a loop with conditional alloc

        if (pathMatches(path, full_spec)) return true;
    }
    return false;
}

fn pathMatches(path: []const u8, spec: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, path, spec)) return true;

    // Directory match: spec is a prefix
    if (std.mem.startsWith(u8, path, spec)) {
        if (spec.len > 0 and (spec[spec.len - 1] == '/' or
            (path.len > spec.len and path[spec.len] == '/')))
            return true;
    }

    // Glob pattern (*)
    if (std.mem.indexOf(u8, spec, "*") != null) {
        return globMatch(path, spec);
    }

    // If spec is "." it matches everything
    if (std.mem.eql(u8, spec, ".")) return true;

    return false;
}

fn globMatch(text: []const u8, pattern: []const u8) bool {
    var ti: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == text[ti] or pattern[pi] == '?')) {
            ti += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn matchesMaxDepth(path: []const u8, max_depth_opt: ?i32, pathspecs: []const []const u8, prefix: []const u8) bool {
    const max_depth = max_depth_opt orelse return true;
    if (max_depth < 0) return true; // -1 means unlimited

    // If pathspecs contain glob (*), max-depth doesn't apply
    for (pathspecs) |spec| {
        if (std.mem.indexOf(u8, spec, "*") != null) return true;
    }

    // Count depth of path relative to its pathspec base
    // The depth is the number of '/' in the path relative to the search root
    var effective_path = path;

    // If pathspecs are given, measure depth relative to pathspec
    if (pathspecs.len > 0) {
        for (pathspecs) |spec| {
            const full_spec = if (prefix.len > 0 and !std.mem.startsWith(u8, spec, "/"))
                std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ prefix, spec }) catch spec
            else
                spec;
            if (std.mem.startsWith(u8, path, full_spec) and full_spec.len < path.len) {
                if (full_spec.len > 0 and path[full_spec.len] == '/') {
                    effective_path = path[full_spec.len + 1 ..];
                    break;
                }
            }
            if (std.mem.eql(u8, full_spec, ".")) {
                effective_path = path;
                break;
            }
        }
    }

    // Count slashes
    var depth: i32 = 0;
    for (effective_path) |c| {
        if (c == '/') depth += 1;
    }

    return depth <= max_depth;
}

fn getDisplayPath(path: []const u8, prefix: []const u8, full_name: bool, allocator: Allocator) []const u8 {
    if (full_name or prefix.len == 0) {
        return allocator.dupe(u8, path) catch "";
    }
    // Strip prefix
    if (std.mem.startsWith(u8, path, prefix)) {
        return allocator.dupe(u8, path[prefix.len..]) catch "";
    }
    return allocator.dupe(u8, path) catch "";
}

fn quotePathIfNeeded(path: []const u8, allocator: Allocator, null_sep: bool) []const u8 {
    if (null_sep) return allocator.dupe(u8, path) catch path;

    // Check if path needs quoting (contains special chars)
    var needs_quoting = false;
    for (path) |c| {
        if (c == '"' or c == '\n' or c == '\t') {
            needs_quoting = true;
            break;
        }
    }
    if (!needs_quoting) return allocator.dupe(u8, path) catch path;

    // Quote the path
    var buf = std.array_list.Managed(u8).init(allocator);
    buf.append('"') catch return allocator.dupe(u8, path) catch path;
    for (path) |c| {
        if (c == '"') {
            buf.appendSlice("\\\"") catch {};
        } else if (c == '\\') {
            buf.appendSlice("\\\\") catch {};
        } else if (c == '\n') {
            buf.appendSlice("\\n") catch {};
        } else if (c == '\t') {
            buf.appendSlice("\\t") catch {};
        } else {
            buf.append(c) catch {};
        }
    }
    buf.append('"') catch {};
    return buf.toOwnedSlice() catch return allocator.dupe(u8, path) catch path;
}

fn isBinaryContent(content: []const u8) bool {
    // Check first 8000 bytes for NUL character
    const check_len = @min(content.len, 8000);
    for (content[0..check_len]) |c| {
        if (c == 0) return true;
    }
    return false;
}

// ===== Regex Engine =====
// A simple NFA-based regex engine supporting BRE and ERE

const RegexEngine = struct {
    const Inst = union(enum) {
        char: u8,
        char_class: CharClass,
        any: void, // . matches any char except newline
        anchor_start: void, // ^
        anchor_end: void, // $
        split: struct { a: usize, b: usize }, // NFA fork
        jump: usize, // unconditional jump
        match: void, // match state
    };

    const CharClass = struct {
        ranges: [32]CharRange = undefined,
        count: usize = 0,
        negated: bool = false,

        const CharRange = struct {
            lo: u8,
            hi: u8,
        };

        fn matches(self: CharClass, c: u8) bool {
            var found = false;
            for (self.ranges[0..self.count]) |r| {
                if (c >= r.lo and c <= r.hi) {
                    found = true;
                    break;
                }
            }
            return if (self.negated) !found else found;
        }

        fn addRange(self: *CharClass, lo: u8, hi: u8) void {
            if (self.count < 32) {
                self.ranges[self.count] = .{ .lo = lo, .hi = hi };
                self.count += 1;
            }
        }

        fn addSingle(self: *CharClass, c: u8) void {
            self.addRange(c, c);
        }
    };

    insts: std.array_list.Managed(Inst),
    case_insensitive: bool,

    fn compile(pattern: []const u8, extended: bool, case_insensitive: bool, allocator: Allocator) !RegexEngine {
        var engine = RegexEngine{
            .insts = std.array_list.Managed(Inst).init(allocator),
            .case_insensitive = case_insensitive,
        };

        var pos: usize = 0;
        try compileExpr(&engine, pattern, &pos, extended, false);
        try engine.insts.append(.match);

        return engine;
    }

    fn compileExpr(engine: *RegexEngine, pattern: []const u8, pos: *usize, extended: bool, in_group: bool) error{OutOfMemory}!void {
        // Parse alternation (|)
        const start = engine.insts.items.len;
        try compileConcat(engine, pattern, pos, extended, in_group);

        while (pos.* < pattern.len) {
            const is_alt = if (extended)
                (pattern[pos.*] == '|')
            else
                (pos.* + 1 < pattern.len and pattern[pos.*] == '\\' and pattern[pos.* + 1] == '|');

            if (!is_alt) break;

            if (extended) pos.* += 1 else pos.* += 2;

            // Create alternation: split to left branch and right branch
            const left_end = engine.insts.items.len;
            // We need to restructure: insert split at start, add jump at end of left
            // For simplicity, use a different approach: compile right side and patch

            const split_idx = start;
            _ = left_end;

            // Save current instructions
            var left_insts = std.array_list.Managed(Inst).init(engine.insts.allocator);
            defer left_insts.deinit();
            for (engine.insts.items[start..]) |inst| {
                try left_insts.append(inst);
            }
            engine.insts.shrinkRetainingCapacity(start);

            // Compile right side
            var right_insts = std.array_list.Managed(Inst).init(engine.insts.allocator);
            defer right_insts.deinit();
            {
                var temp_engine = RegexEngine{
                    .insts = std.array_list.Managed(Inst).init(engine.insts.allocator),
                    .case_insensitive = engine.case_insensitive,
                };
                defer temp_engine.insts.deinit();
                try compileConcat(&temp_engine, pattern, pos, extended, in_group);
                for (temp_engine.insts.items) |inst| {
                    try right_insts.append(inst);
                }
            }

            // Build: split(left_start, right_start), left..., jump(end), right...
            const left_start = start + 1;
            const right_start = left_start + left_insts.items.len + 1; // +1 for jump
            const end = right_start + right_insts.items.len;

            try engine.insts.append(.{ .split = .{ .a = left_start, .b = right_start } });

            // Patch jumps in left and right
            for (left_insts.items) |inst| {
                try engine.insts.append(patchInst(inst, 0, 0)); // no patching needed
            }
            try engine.insts.append(.{ .jump = end });

            for (right_insts.items) |inst| {
                try engine.insts.append(patchInst(inst, 0, 0));
            }
            _ = split_idx;
        }
    }

    fn patchInst(inst: Inst, _: usize, _: usize) Inst {
        return inst;
    }

    fn compileConcat(engine: *RegexEngine, pattern: []const u8, pos: *usize, extended: bool, in_group: bool) error{OutOfMemory}!void {
        while (pos.* < pattern.len) {
            // Check for alternation or group end
            if (extended) {
                if (pattern[pos.*] == '|') break;
                if (pattern[pos.*] == ')' and in_group) break;
            } else {
                if (pos.* + 1 < pattern.len and pattern[pos.*] == '\\' and pattern[pos.* + 1] == '|') break;
                if (pos.* + 1 < pattern.len and pattern[pos.*] == '\\' and pattern[pos.* + 1] == ')' and in_group) break;
            }

            try compileAtom(engine, pattern, pos, extended, in_group);
        }
    }

    fn compileAtom(engine: *RegexEngine, pattern: []const u8, pos: *usize, extended: bool, in_group: bool) error{OutOfMemory}!void {
        _ = in_group;
        const atom_start = engine.insts.items.len;

        if (pos.* >= pattern.len) return;

        const c = pattern[pos.*];

        if (c == '\\' and pos.* + 1 < pattern.len) {
            const next = pattern[pos.* + 1];
            if (!extended and next == '(') {
                // BRE group
                pos.* += 2;
                try compileExpr(engine, pattern, pos, extended, true);
                if (pos.* + 1 < pattern.len and pattern[pos.*] == '\\' and pattern[pos.* + 1] == ')') {
                    pos.* += 2;
                }
            } else if (!extended and next == '{') {
                // BRE repetition
                pos.* += 2;
                // Parse {n}, {n,}, {n,m}
                // For now, skip repetition parsing, treat as literal
                try engine.insts.append(.{ .char = '{' });
                return; // Don't check for quantifier
            } else if (extended and (next == '(' or next == ')' or next == '{' or next == '}' or
                next == '|' or next == '+' or next == '?' or next == '*' or next == '.' or
                next == '^' or next == '$' or next == '[' or next == ']' or next == '\\'))
            {
                // Escaped special char in ERE
                pos.* += 2;
                try engine.insts.append(.{ .char = next });
            } else if (!extended and (next == '+' or next == '?' or next == '|')) {
                // BRE: \+, \? are quantifiers
                // Actually, \+ and \? are quantifiers in BRE - handle after atom
                pos.* += 2;
                try engine.insts.append(.{ .char = next });
                return;
            } else if (next == 'w') {
                // \w = word char
                pos.* += 2;
                var cc = CharClass{};
                cc.addRange('a', 'z');
                cc.addRange('A', 'Z');
                cc.addRange('0', '9');
                cc.addSingle('_');
                try engine.insts.append(.{ .char_class = cc });
            } else if (next == 'W') {
                // \W = non-word char
                pos.* += 2;
                var cc = CharClass{ .negated = true };
                cc.addRange('a', 'z');
                cc.addRange('A', 'Z');
                cc.addRange('0', '9');
                cc.addSingle('_');
                try engine.insts.append(.{ .char_class = cc });
            } else if (next == 'd') {
                pos.* += 2;
                var cc = CharClass{};
                cc.addRange('0', '9');
                try engine.insts.append(.{ .char_class = cc });
            } else if (next == 'D') {
                pos.* += 2;
                var cc = CharClass{ .negated = true };
                cc.addRange('0', '9');
                try engine.insts.append(.{ .char_class = cc });
            } else if (next == 's') {
                pos.* += 2;
                var cc = CharClass{};
                cc.addSingle(' ');
                cc.addSingle('\t');
                cc.addSingle('\n');
                cc.addSingle('\r');
                try engine.insts.append(.{ .char_class = cc });
            } else if (next == 'n') {
                pos.* += 2;
                try engine.insts.append(.{ .char = '\n' });
            } else if (next == 't') {
                pos.* += 2;
                try engine.insts.append(.{ .char = '\t' });
            } else {
                // Literal escaped char
                pos.* += 2;
                try engine.insts.append(.{ .char = next });
            }
        } else if (c == '[') {
            // Character class
            pos.* += 1;
            var cc = CharClass{};
            if (pos.* < pattern.len and pattern[pos.*] == '^') {
                cc.negated = true;
                pos.* += 1;
            }
            // ] right after [ (or [^) is literal
            if (pos.* < pattern.len and pattern[pos.*] == ']') {
                cc.addSingle(']');
                pos.* += 1;
            }
            while (pos.* < pattern.len and pattern[pos.*] != ']') {
                if (pattern[pos.*] == '\\' and pos.* + 1 < pattern.len) {
                    // Escaped char in bracket
                    pos.* += 1;
                    const ec = pattern[pos.*];
                    if (ec == 'd') {
                        cc.addRange('0', '9');
                    } else {
                        cc.addSingle(ec);
                    }
                    pos.* += 1;
                } else if (pos.* + 2 < pattern.len and pattern[pos.* + 1] == '-' and pattern[pos.* + 2] != ']') {
                    // Range
                    cc.addRange(pattern[pos.*], pattern[pos.* + 2]);
                    pos.* += 3;
                } else if (pattern[pos.*] == '[' and pos.* + 1 < pattern.len and pattern[pos.* + 1] == ':') {
                    // POSIX class like [:alpha:]
                    const class_end = std.mem.indexOf(u8, pattern[pos.*..], ":]");
                    if (class_end) |ce| {
                        const class_name = pattern[pos.* + 2 .. pos.* + ce];
                        if (std.mem.eql(u8, class_name, "alpha")) {
                            cc.addRange('a', 'z');
                            cc.addRange('A', 'Z');
                        } else if (std.mem.eql(u8, class_name, "digit")) {
                            cc.addRange('0', '9');
                        } else if (std.mem.eql(u8, class_name, "alnum")) {
                            cc.addRange('a', 'z');
                            cc.addRange('A', 'Z');
                            cc.addRange('0', '9');
                        } else if (std.mem.eql(u8, class_name, "space")) {
                            cc.addSingle(' ');
                            cc.addSingle('\t');
                            cc.addSingle('\n');
                            cc.addSingle('\r');
                        } else if (std.mem.eql(u8, class_name, "upper")) {
                            cc.addRange('A', 'Z');
                        } else if (std.mem.eql(u8, class_name, "lower")) {
                            cc.addRange('a', 'z');
                        }
                        pos.* += ce + 2;
                    } else {
                        cc.addSingle(pattern[pos.*]);
                        pos.* += 1;
                    }
                } else {
                    cc.addSingle(pattern[pos.*]);
                    pos.* += 1;
                }
            }
            if (pos.* < pattern.len) pos.* += 1; // skip ]
            if (engine.case_insensitive) {
                // Add case-insensitive ranges
                var extra_cc = cc;
                for (cc.ranges[0..cc.count]) |r| {
                    if (r.lo >= 'a' and r.hi <= 'z') {
                        extra_cc.addRange(r.lo - 32, r.hi - 32);
                    } else if (r.lo >= 'A' and r.hi <= 'Z') {
                        extra_cc.addRange(r.lo + 32, r.hi + 32);
                    }
                }
                try engine.insts.append(.{ .char_class = extra_cc });
            } else {
                try engine.insts.append(.{ .char_class = cc });
            }
        } else if (c == '.') {
            pos.* += 1;
            try engine.insts.append(.any);
        } else if (c == '^') {
            pos.* += 1;
            try engine.insts.append(.anchor_start);
            return; // anchors don't get quantifiers
        } else if (c == '$') {
            pos.* += 1;
            try engine.insts.append(.anchor_end);
            return; // anchors don't get quantifiers
        } else if (extended and c == '(') {
            // ERE group
            pos.* += 1;
            try compileExpr(engine, pattern, pos, extended, true);
            if (pos.* < pattern.len and pattern[pos.*] == ')') {
                pos.* += 1;
            }
        } else if (extended and c == ')') {
            // End of group - handled by caller
            return;
        } else {
            // Literal character
            pos.* += 1;
            if (engine.case_insensitive and std.ascii.isAlphabetic(c)) {
                var cc = CharClass{};
                cc.addSingle(std.ascii.toLower(c));
                cc.addSingle(std.ascii.toUpper(c));
                try engine.insts.append(.{ .char_class = cc });
            } else {
                try engine.insts.append(.{ .char = c });
            }
        }

        // Check for quantifiers
        if (pos.* < pattern.len) {
            const atom_end = engine.insts.items.len;
            const q = pattern[pos.*];

            if (q == '*') {
                pos.* += 1;
                // a* = split(atom, skip) where atom jumps back to split
                const split_idx = atom_start;
                const after = atom_end;

                // Restructure: insert split before atom, add jump after atom back to split
                var atom_insts = std.array_list.Managed(Inst).init(engine.insts.allocator);
                defer atom_insts.deinit();
                for (engine.insts.items[atom_start..atom_end]) |inst| {
                    atom_insts.append(inst) catch {};
                }
                engine.insts.shrinkRetainingCapacity(atom_start);

                const new_split = engine.insts.items.len;
                try engine.insts.append(.{ .split = .{ .a = new_split + 1, .b = new_split + 1 + atom_insts.items.len + 1 } });
                for (atom_insts.items) |inst| {
                    try engine.insts.append(inst);
                }
                try engine.insts.append(.{ .jump = new_split });
                _ = after;
                _ = split_idx;
            } else if ((extended and q == '+') or (!extended and q == '\\' and pos.* + 1 < pattern.len and pattern[pos.* + 1] == '+')) {
                // a+ = a a*
                if (extended) pos.* += 1 else pos.* += 2;
                // Add split + jump for the * part
                const loop_start = atom_start;
                try engine.insts.append(.{ .split = .{ .a = loop_start, .b = engine.insts.items.len + 1 } });
            } else if ((extended and q == '?') or (!extended and q == '\\' and pos.* + 1 < pattern.len and pattern[pos.* + 1] == '?')) {
                // a? = split(a, skip)
                if (extended) pos.* += 1 else pos.* += 2;
                var atom_insts2 = std.array_list.Managed(Inst).init(engine.insts.allocator);
                defer atom_insts2.deinit();
                for (engine.insts.items[atom_start..atom_end]) |inst| {
                    atom_insts2.append(inst) catch {};
                }
                engine.insts.shrinkRetainingCapacity(atom_start);

                try engine.insts.append(.{ .split = .{ .a = engine.insts.items.len + 1, .b = engine.insts.items.len + 1 + atom_insts2.items.len } });
                for (atom_insts2.items) |inst| {
                    try engine.insts.append(inst);
                }
            }
        }
    }

    fn search(self: *RegexEngine, text: []const u8) ?MatchRange {
        // Check if pattern starts with ^
        var anchored = false;
        if (self.insts.items.len > 0) {
            if (self.insts.items[0] == .anchor_start) {
                anchored = true;
            }
        }

        if (anchored) {
            if (self.matchAt(text, 0)) |end| {
                return .{ .start = 0, .end = end };
            }
            return null;
        }

        // Try matching at each position
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (self.matchAt(text, start)) |end| {
                return .{ .start = start, .end = end };
            }
            if (start == text.len) break;
        }
        return null;
    }

    fn matchAt(self: *RegexEngine, text: []const u8, start: usize) ?usize {
        return self.nfaMatch(text, start, 0);
    }

    fn nfaMatch(self: *RegexEngine, text: []const u8, pos: usize, pc: usize) ?usize {
        if (pc >= self.insts.items.len) return null;

        const inst = self.insts.items[pc];
        switch (inst) {
            .match => return pos,
            .char => |c| {
                if (pos >= text.len) return null;
                if (self.case_insensitive) {
                    if (std.ascii.toLower(text[pos]) != std.ascii.toLower(c)) return null;
                } else {
                    if (text[pos] != c) return null;
                }
                return self.nfaMatch(text, pos + 1, pc + 1);
            },
            .char_class => |cc| {
                if (pos >= text.len) return null;
                const tc = text[pos];
                if (cc.matches(tc)) {
                    return self.nfaMatch(text, pos + 1, pc + 1);
                }
                return null;
            },
            .any => {
                if (pos >= text.len) return null;
                if (text[pos] == '\n') return null;
                return self.nfaMatch(text, pos + 1, pc + 1);
            },
            .anchor_start => {
                if (pos != 0) return null;
                return self.nfaMatch(text, pos, pc + 1);
            },
            .anchor_end => {
                if (pos != text.len) return null;
                return self.nfaMatch(text, pos, pc + 1);
            },
            .split => |s| {
                // Try both branches, prefer first
                if (self.nfaMatch(text, pos, s.a)) |end| return end;
                return self.nfaMatch(text, pos, s.b);
            },
            .jump => |target| {
                return self.nfaMatch(text, pos, target);
            },
        }
    }

    fn deinit(self: *RegexEngine) void {
        self.insts.deinit();
    }
};
