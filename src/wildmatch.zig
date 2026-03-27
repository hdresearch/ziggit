const std = @import("std");

/// Wildmatch flags
pub const WM_CASEFOLD: u32 = 1;
pub const WM_PATHNAME: u32 = 2;

/// Result codes matching git's wildmatch
pub const WM_MATCH: i32 = 0;
pub const WM_NOMATCH: i32 = 1;
pub const WM_ABORT_ALL: i32 = -1;
pub const WM_ABORT_TO_STARSTAR: i32 = -2;

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn toUpper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

fn charEqual(a: u8, b: u8, case_fold: bool) bool {
    if (case_fold) return toLower(a) == toLower(b);
    return a == b;
}

/// Check if name is a valid POSIX character class name.
fn isValidPosixClass(name: []const u8) bool {
    const valid_classes = [_][]const u8{
        "alpha", "digit", "upper", "lower", "xdigit", "space",
        "blank", "alnum", "print", "graph", "cntrl", "punct",
    };
    for (valid_classes) |vc| {
        if (std.mem.eql(u8, name, vc)) return true;
    }
    return false;
}

/// Check if character matches a POSIX character class name.
/// Returns null for invalid/unknown class names.
fn matchPosixClass(name: []const u8, c: u8, case_fold: bool) ?bool {
    if (std.mem.eql(u8, name, "alpha")) {
        if (case_fold) return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    } else if (std.mem.eql(u8, name, "digit")) {
        return c >= '0' and c <= '9';
    } else if (std.mem.eql(u8, name, "upper")) {
        if (case_fold) return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
        return c >= 'A' and c <= 'Z';
    } else if (std.mem.eql(u8, name, "lower")) {
        if (case_fold) return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
        return c >= 'a' and c <= 'z';
    } else if (std.mem.eql(u8, name, "xdigit")) {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    } else if (std.mem.eql(u8, name, "space")) {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12; // \v \f
    } else if (std.mem.eql(u8, name, "blank")) {
        return c == ' ' or c == '\t';
    } else if (std.mem.eql(u8, name, "alnum")) {
        if (case_fold) return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
    } else if (std.mem.eql(u8, name, "print")) {
        return c >= 0x20 and c <= 0x7e;
    } else if (std.mem.eql(u8, name, "graph")) {
        return c > 0x20 and c <= 0x7e;
    } else if (std.mem.eql(u8, name, "cntrl")) {
        return c < 0x20 or c == 0x7f;
    } else if (std.mem.eql(u8, name, "punct")) {
        return (c >= 0x21 and c <= 0x2f) or (c >= 0x3a and c <= 0x40) or
            (c >= 0x5b and c <= 0x60) or (c >= 0x7b and c <= 0x7e);
    }
    // Unknown/invalid POSIX class
    return null;
}

/// Match a character class like [abc], [a-z], [!abc], [^abc], [[:alpha:]]
/// pattern starts AFTER the opening '['.
/// Returns the index past the closing ']', or null if invalid bracket expression.
fn matchCharClass(pattern: []const u8, start: usize, test_char: u8, case_fold: bool) ?struct { end: usize, matched: bool } {
    var pi = start;
    if (pi >= pattern.len) return null;

    var negate = false;
    if (pattern[pi] == '!' or pattern[pi] == '^') {
        negate = true;
        pi += 1;
    }

    if (pi >= pattern.len) return null;

    var matched = false;

    // First character can be ']' and it's treated as literal
    var first = true;
    while (pi < pattern.len) {
        const pc = pattern[pi];

        if (pc == ']' and !first) {
            return .{ .end = pi + 1, .matched = if (negate) !matched else matched };
        }

        first = false;

        // Check for POSIX character class [:name:]
        if (pc == '[' and pi + 1 < pattern.len and pattern[pi + 1] == ':') {
            // Find closing :]
            const class_start = pi + 2;
            var class_end: ?usize = null;
            var ci = class_start;
            while (ci + 1 < pattern.len) {
                if (pattern[ci] == ':' and pattern[ci + 1] == ']') {
                    class_end = ci;
                    break;
                }
                ci += 1;
            }
            if (class_end) |ce| {
                const class_name = pattern[class_start..ce];
                if (class_name.len == 0) {
                    // [[::]...] - empty class name, invalid bracket expression
                    return null;
                }
                if (matchPosixClass(class_name, test_char, case_fold)) |m| {
                    if (m) matched = true;
                } else {
                    // Invalid/unknown POSIX class name - entire bracket expression fails
                    return null;
                }
                pi = ce + 2; // skip past :]
                continue;
            }
            // No closing :] found, treat [ as literal
            if (charEqual(pc, test_char, case_fold)) matched = true;
            pi += 1;
            continue;
        }

        // Backslash escaping inside bracket expression
        if (pc == '\\') {
            if (pi + 1 < pattern.len) {
                pi += 1;
                const escaped = pattern[pi];
                // Check for range: \x-y
                if (pi + 2 < pattern.len and pattern[pi + 1] == '-' and pattern[pi + 2] != ']') {
                    var range_end_char: u8 = undefined;
                    var skip: usize = 3;
                    if (pattern[pi + 2] == '\\' and pi + 3 < pattern.len) {
                        range_end_char = pattern[pi + 3];
                        skip = 4;
                    } else {
                        range_end_char = pattern[pi + 2];
                    }
                    const rs = if (case_fold) toLower(escaped) else escaped;
                    const re = if (case_fold) toLower(range_end_char) else range_end_char;
                    const tc = if (case_fold) toLower(test_char) else test_char;
                    if (rs <= re) {
                        if (tc >= rs and tc <= re) matched = true;
                    } else {
                        if (tc >= re and tc <= rs) matched = true;
                    }
                    pi += skip;
                    continue;
                }
                if (charEqual(escaped, test_char, case_fold)) matched = true;
                pi += 1;
                continue;
            }
            // Backslash at end - treat as literal
            if (charEqual(pc, test_char, case_fold)) matched = true;
            pi += 1;
            continue;
        }

        // Check for range: a-z (but not if - is at end before ])
        if (pi + 2 < pattern.len and pattern[pi + 1] == '-' and pattern[pi + 2] != ']') {
            var range_end_char: u8 = undefined;
            var skip: usize = 3;
            if (pattern[pi + 2] == '\\' and pi + 3 < pattern.len) {
                range_end_char = pattern[pi + 3];
                skip = 4;
            } else {
                range_end_char = pattern[pi + 2];
            }
            const range_start = if (case_fold) toLower(pc) else pc;
            const range_end = if (case_fold) toLower(range_end_char) else range_end_char;
            const tc = if (case_fold) toLower(test_char) else test_char;

            if (range_start <= range_end) {
                if (tc >= range_start and tc <= range_end) matched = true;
            } else {
                // Reverse range (e.g. [z-a] or [Z-y])
                if (tc >= range_end and tc <= range_start) matched = true;
            }
            pi += skip;
            continue;
        }

        if (charEqual(pc, test_char, case_fold)) matched = true;
        pi += 1;
    }

    // No closing ']' found - invalid class
    return null;
}

/// Core wildmatch implementation
fn doWildmatch(pattern: []const u8, text: []const u8, flags: u32) i32 {
    const pathname = (flags & WM_PATHNAME) != 0;
    const case_fold = (flags & WM_CASEFOLD) != 0;

    var pi: usize = 0;
    var ti: usize = 0;

    while (pi < pattern.len) {
        const p = pattern[pi];

        switch (p) {
            '?' => {
                if (ti >= text.len) return WM_NOMATCH;
                if (pathname and text[ti] == '/') return WM_NOMATCH;
                ti += 1;
                pi += 1;
            },
            '*' => {
                // Check for ** (two or more stars)
                if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                    // Count consecutive stars
                    var p2 = pi + 2;
                    while (p2 < pattern.len and pattern[p2] == '*') p2 += 1;

                    if (pathname) {
                        // In pathname mode, ** only special if bounded properly
                        const at_start = (pi == 0 or pattern[pi - 1] == '/');
                        const at_end = (p2 >= pattern.len);
                        const followed_by_slash = (p2 < pattern.len and pattern[p2] == '/');

                        if (at_start and (at_end or followed_by_slash)) {
                            // Proper ** globstar
                            if (at_end) {
                                return WM_MATCH;
                            }

                            // Pattern is **/ followed by more
                            const rest_pattern = pattern[p2 + 1 ..];

                            // Try matching rest at current position and after each /
                            var search_ti = ti;
                            while (true) {
                                const result = doWildmatch(rest_pattern, text[search_ti..], flags);
                                if (result == WM_MATCH) return WM_MATCH;
                                if (result == WM_ABORT_ALL) return WM_ABORT_ALL;
                                if (search_ti >= text.len) return WM_NOMATCH;
                                search_ti += 1;
                            }
                        } else {
                            // ** not properly bounded in pathname mode
                            // Treat as two single stars = same as one *
                            // (does NOT cross directory boundaries)
                            pi = p2;
                            // Fall through to single star logic below
                            if (pi >= pattern.len) {
                                if (std.mem.indexOfScalar(u8, text[ti..], '/') != null) return WM_NOMATCH;
                                return WM_MATCH;
                            }
                            while (ti <= text.len) {
                                const result = doWildmatch(pattern[pi..], text[ti..], flags);
                                if (result == WM_MATCH) return WM_MATCH;
                                if (result == WM_ABORT_ALL) return WM_ABORT_ALL;
                                if (ti >= text.len) break;
                                if (text[ti] == '/') return WM_NOMATCH;
                                ti += 1;
                            }
                            return WM_ABORT_ALL;
                        }
                    } else {
                        // Not pathname mode: ** matches anything including /
                        // Skip all consecutive *
                        if (p2 >= pattern.len) return WM_MATCH;

                        while (ti <= text.len) {
                            const result = doWildmatch(pattern[p2..], text[ti..], flags);
                            if (result == WM_MATCH) return WM_MATCH;
                            if (result == WM_ABORT_ALL) return WM_ABORT_ALL;
                            if (ti >= text.len) break;
                            ti += 1;
                        }
                        return WM_ABORT_ALL;
                    }
                }

                // Single *
                pi += 1;

                // Trailing * matches everything (except / in pathname mode)
                if (pi >= pattern.len) {
                    if (pathname) {
                        if (std.mem.indexOfScalar(u8, text[ti..], '/') != null) return WM_NOMATCH;
                    }
                    return WM_MATCH;
                }

                // Try matching remaining pattern at each position
                while (ti <= text.len) {
                    const result = doWildmatch(pattern[pi..], text[ti..], flags);
                    if (result == WM_MATCH) return WM_MATCH;
                    if (result == WM_ABORT_ALL) return WM_ABORT_ALL;
                    if (ti >= text.len) break;
                    if (pathname and text[ti] == '/') return WM_NOMATCH;
                    ti += 1;
                }
                return WM_ABORT_ALL;
            },
            '[' => {
                if (ti >= text.len) return WM_NOMATCH;
                if (pathname and text[ti] == '/') return WM_NOMATCH;
                if (matchCharClass(pattern, pi + 1, text[ti], case_fold)) |result| {
                    if (!result.matched) return WM_NOMATCH;
                    pi = result.end;
                    ti += 1;
                } else {
                    // Invalid character class - treat '[' as literal
                    if (!charEqual(p, text[ti], case_fold)) return WM_NOMATCH;
                    pi += 1;
                    ti += 1;
                }
            },
            '\\' => {
                pi += 1;
                if (pi >= pattern.len) {
                    // Trailing backslash with nothing to escape - pattern is invalid, no match
                    return WM_ABORT_ALL;
                } else {
                    if (ti >= text.len) return WM_NOMATCH;
                    if (!charEqual(pattern[pi], text[ti], case_fold)) return WM_NOMATCH;
                    pi += 1;
                    ti += 1;
                }
            },
            else => {
                if (ti >= text.len) return WM_NOMATCH;
                if (!charEqual(p, text[ti], case_fold)) return WM_NOMATCH;
                pi += 1;
                ti += 1;
            },
        }
    }

    if (ti < text.len) return WM_NOMATCH;
    return WM_MATCH;
}

/// Public wildmatch function matching git's interface.
/// Returns 0 (WM_MATCH) on match, non-zero on no match.
pub fn wildmatch(pattern: []const u8, text: []const u8, flags: u32) i32 {
    return doWildmatch(pattern, text, flags);
}

test "basic wildmatch" {
    const testing = std.testing;

    try testing.expectEqual(WM_MATCH, wildmatch("foo", "foo", 0));
    try testing.expect(wildmatch("foo", "bar", 0) != WM_MATCH);
    try testing.expectEqual(WM_MATCH, wildmatch("???", "foo", 0));
    try testing.expect(wildmatch("??", "foo", 0) != WM_MATCH);
    try testing.expectEqual(WM_MATCH, wildmatch("*", "foo", 0));
    try testing.expect(wildmatch("*", "foo/bar", WM_PATHNAME) != WM_MATCH);
    try testing.expectEqual(WM_MATCH, wildmatch("**", "foo/bar", WM_PATHNAME));
    try testing.expectEqual(WM_MATCH, wildmatch("", "", 0));

    // POSIX classes
    try testing.expectEqual(WM_MATCH, wildmatch("[[:alpha:]]", "a", 0));
    try testing.expectEqual(WM_MATCH, wildmatch("[[:upper:]]", "A", 0));
    try testing.expectEqual(WM_MATCH, wildmatch("[[:digit:]]", "5", 0));

    // Trailing backslash
    try testing.expectEqual(WM_MATCH, wildmatch("\\", "\\", 0));

    // foo**bar should not match foo/baz/bar in pathname mode
    try testing.expect(wildmatch("foo**bar", "foo/baz/bar", WM_PATHNAME) != WM_MATCH);
}
