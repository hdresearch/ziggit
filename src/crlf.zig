/// CRLF/EOL line ending conversion module.
/// Handles line ending conversion based on .gitattributes and core.autocrlf/core.eol config.
const std = @import("std");
const check_attr = @import("cmd_check_attr.zig");
const helpers = @import("git_helpers.zig");
const platform_mod = @import("platform/platform.zig");

pub const EolAction = enum {
    none, // No conversion
    lf_to_crlf, // LF → CRLF (checkout)
    crlf_to_lf, // CRLF → LF (add/commit)
};

pub const TextAttr = enum {
    unspecified, // No text attribute set
    text, // text
    text_auto, // text=auto
    no_text, // -text / binary
};

pub const EolAttr = enum {
    unspecified,
    lf,
    crlf,
};

/// Determine text/eol attributes for a file path from .gitattributes rules.
pub fn getFileAttrs(path: []const u8, attr_rules: []const check_attr.AttrRule) struct { text: TextAttr, eol: EolAttr } {
    var text_attr: TextAttr = .unspecified;
    var eol_attr: EolAttr = .unspecified;

    // Last matching rule wins
    for (attr_rules) |rule| {
        if (check_attr.attrPatternMatches(rule.pattern, path)) {
            for (rule.attrs.items) |attr| {
                if (std.mem.eql(u8, attr.name, "text")) {
                    if (std.mem.eql(u8, attr.value, "set")) {
                        text_attr = .text;
                    } else if (std.mem.eql(u8, attr.value, "unset")) {
                        text_attr = .no_text;
                    } else if (std.mem.eql(u8, attr.value, "auto")) {
                        text_attr = .text_auto;
                    }
                } else if (std.mem.eql(u8, attr.name, "eol")) {
                    if (std.mem.eql(u8, attr.value, "lf")) {
                        eol_attr = .lf;
                    } else if (std.mem.eql(u8, attr.value, "crlf")) {
                        eol_attr = .crlf;
                    }
                } else if (std.mem.eql(u8, attr.name, "binary")) {
                    if (std.mem.eql(u8, attr.value, "set")) {
                        text_attr = .no_text;
                    }
                }
            }
        }
    }

    // Setting eol implies text
    if (eol_attr != .unspecified and text_attr == .unspecified) {
        text_attr = .text;
    }

    return .{ .text = text_attr, .eol = eol_attr };
}

/// Determine the checkout conversion action for a file.
pub fn getCheckoutAction(text_attr: TextAttr, eol_attr: EolAttr, autocrlf: ?[]const u8, eol_config: ?[]const u8, content: []const u8) EolAction {
    switch (text_attr) {
        .no_text => return .none,
        .text_auto => {
            // Auto-detect: only convert if content looks like text (no NUL bytes)
            // AND the content has been normalized (all LF, no CRLF)
            if (!isTextContent(content)) return .none;
            if (!isNormalizedLf(content)) return .none;
            return getCheckoutEolAction(eol_attr, autocrlf, eol_config);
        },
        .text => {
            return getCheckoutEolAction(eol_attr, autocrlf, eol_config);
        },
        .unspecified => {
            // No text attribute - check core.autocrlf
            if (autocrlf) |ac| {
                if (std.mem.eql(u8, ac, "true")) {
                    // autocrlf=true: auto-detect + convert to CRLF on checkout
                    if (!isTextContent(content)) return .none;
                    if (!isNormalizedLf(content)) return .none;
                    return .lf_to_crlf;
                }
            }
            return .none;
        },
    }
}

/// Determine the commit (add) conversion action for a file.
pub fn getCommitAction(text_attr: TextAttr, _: EolAttr, autocrlf: ?[]const u8, content: []const u8) EolAction {
    switch (text_attr) {
        .no_text => return .none,
        .text_auto => {
            if (!isTextContent(content)) return .none;
            return .crlf_to_lf;
        },
        .text => {
            return .crlf_to_lf;
        },
        .unspecified => {
            if (autocrlf) |ac| {
                if (std.mem.eql(u8, ac, "true") or std.mem.eql(u8, ac, "input")) {
                    if (!isTextContent(content)) return .none;
                    return .crlf_to_lf;
                }
            }
            return .none;
        },
    }
}

fn getCheckoutEolAction(eol_attr: EolAttr, autocrlf: ?[]const u8, eol_config: ?[]const u8) EolAction {
    // Explicit eol attribute takes highest priority
    switch (eol_attr) {
        .crlf => return .lf_to_crlf,
        .lf => return .none, // LF → LF = no conversion needed (content is stored as LF)
        .unspecified => {},
    }

    // core.autocrlf=true overrides core.eol, input prevents CRLF on checkout
    if (autocrlf) |ac| {
        if (std.mem.eql(u8, ac, "true")) return .lf_to_crlf;
        if (std.mem.eql(u8, ac, "input")) return .none; // input means never CRLF on checkout
    }

    // Check core.eol config (only when autocrlf is not true/input)
    if (eol_config) |ec| {
        if (std.mem.eql(u8, ec, "crlf")) return .lf_to_crlf;
        if (std.mem.eql(u8, ec, "lf")) return .none;
        // "native" - on Linux, native is LF so no conversion
    }

    // Default: no conversion (native LF on Linux)
    return .none;
}

/// Check if content has been normalized to LF-only line endings.
/// Returns false if content contains any CRLF or lone CR sequences.
pub fn isNormalizedLf(content: []const u8) bool {
    for (content, 0..) |c, i| {
        if (c == '\r') {
            // Any CR makes it non-normalized
            _ = i;
            return false;
        }
    }
    return true;
}

/// Check if content is text (no NUL bytes in first 8000 bytes).
pub fn isTextContent(content: []const u8) bool {
    const check_len = @min(content.len, 8000);
    for (content[0..check_len]) |c| {
        if (c == 0) return false;
    }
    return true;
}

/// Convert LF to CRLF in content. Returns new allocated buffer.
pub fn convertLfToCrlf(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    // Count LFs that need conversion (LFs not preceded by CR)
    var extra: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n' and (i == 0 or content[i - 1] != '\r')) {
            extra += 1;
        }
    }
    if (extra == 0) return allocator.dupe(u8, content);

    var result = try allocator.alloc(u8, content.len + extra);
    var j: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n' and (i == 0 or content[i - 1] != '\r')) {
            result[j] = '\r';
            j += 1;
        }
        result[j] = c;
        j += 1;
    }
    return result;
}

/// Convert CRLF to LF in content. Returns new allocated buffer.
pub fn convertCrlfToLf(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var remove: usize = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') {
            remove += 1;
        }
    }
    if (remove == 0) return allocator.dupe(u8, content);

    var result = try allocator.alloc(u8, content.len - remove);
    var j: usize = 0;
    i = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') {
            continue; // skip CR
        }
        result[j] = content[i];
        j += 1;
    }
    return result;
}

/// Apply checkout conversion to blob content.
pub fn applyCheckoutConversion(allocator: std.mem.Allocator, content: []const u8, path: []const u8, attr_rules: []const check_attr.AttrRule, autocrlf: ?[]const u8, eol_config: ?[]const u8) ![]u8 {
    const attrs = getFileAttrs(path, attr_rules);
    const action = getCheckoutAction(attrs.text, attrs.eol, autocrlf, eol_config, content);
    return switch (action) {
        .lf_to_crlf => convertLfToCrlf(allocator, content),
        .crlf_to_lf => convertCrlfToLf(allocator, content),
        .none => allocator.dupe(u8, content),
    };
}

/// Apply commit conversion to worktree content.
pub fn applyCommitConversion(allocator: std.mem.Allocator, content: []const u8, path: []const u8, attr_rules: []const check_attr.AttrRule, autocrlf: ?[]const u8) ![]u8 {
    const attrs = getFileAttrs(path, attr_rules);
    const action = getCommitAction(attrs.text, attrs.eol, autocrlf, content);
    return switch (action) {
        .crlf_to_lf => convertCrlfToLf(allocator, content),
        .lf_to_crlf => convertLfToCrlf(allocator, content),
        .none => allocator.dupe(u8, content),
    };
}

/// Load .gitattributes rules for a repository.
pub fn loadAttrRules(allocator: std.mem.Allocator, repo_root: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform) !std.ArrayList(check_attr.AttrRule) {
    var rules = std.ArrayList(check_attr.AttrRule).init(allocator);
    check_attr.loadAttrFile(allocator, repo_root, "", platform_impl, &rules) catch {};
    // Load info/attributes
    const info_attr_path = try std.fmt.allocPrint(allocator, "{s}/info/attributes", .{git_path});
    defer allocator.free(info_attr_path);
    if (platform_impl.fs.readFile(allocator, info_attr_path)) |content| {
        defer allocator.free(content);
        check_attr.parseAttrContent(allocator, content, "", &rules) catch {};
    } else |_| {}
    return rules;
}
