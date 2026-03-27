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

fn charEqual(a: u8, b: u8, case_fold: bool) bool {
    if (case_fold) return toLower(a) == toLower(b);
    return a == b;
}

/// Match a character class like [abc], [a-z], [!abc], [^abc]
/// Returns the new pattern index past the ']', or null if invalid.
/// Sets matched to true if the character matches the class.
fn matchCharClass(pattern: []const u8, start: usize, test_char: u8, case_fold: bool) ?struct { end: usize, matched: bool } {
    var pi = start;
    if (pi >= pattern.len) return null;

    var negate = false;
    if (pi < pattern.len and (pattern[pi] == '!' or pattern[pi] == '^')) {
        negate = true;
        pi += 1;
    }

    if (pi >= pattern.len) return null;

    var matched = false;

    // First character after [ or [! or [^ can be ] and it's literal
    var first = true;
    while (pi < pattern.len) {
        const pc = pattern[pi];

        if (pc == ']' and !first) {
            return .{ .end = pi + 1, .matched = if (negate) !matched else matched };
        }

        first = false;

        if (pc == '\\' and pi + 1 < pattern.len) {
            pi += 1;
            if (charEqual(pattern[pi], test_char, case_fold)) matched = true;
            pi += 1;
            continue;
        }

        // Check for range: a-z
        if (pi + 2 < pattern.len and pattern[pi + 1] == '-' and pattern[pi + 2] != ']') {
            const range_start = if (case_fold) toLower(pc) else pc;
            const range_end = if (case_fold) toLower(pattern[pi + 2]) else pattern[pi + 2];
            const tc = if (case_fold) toLower(test_char) else test_char;

            if (range_start <= range_end) {
                if (tc >= range_start and tc <= range_end) matched = true;
            } else {
                // Reverse range (e.g. [z-a] or [Z-y])
                if (tc >= range_end and tc <= range_start) matched = true;
            }
            pi += 3;
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
                // Check for **
                if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                    // **
                    var p2 = pi + 2;

                    // Leading **/ or just **
                    if (pathname) {
                        // Check the form: we need ** to be bounded by / or start/end
                        const at_start = (pi == 0 or pattern[pi - 1] == '/');
                        const at_end = (p2 >= pattern.len);
                        const followed_by_slash = (p2 < pattern.len and pattern[p2] == '/');

                        if (at_start and (at_end or followed_by_slash)) {
                            // This is a proper ** that matches across path separators
                            if (at_end) {
                                // Pattern ends with **, matches everything
                                return WM_MATCH;
                            }

                            // Pattern is **/ followed by more pattern
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
                        }
                    }

                    // Not a proper ** in pathname mode, or not pathname mode
                    // Treat as * matching anything including /
                    // Skip all consecutive *
                    while (p2 < pattern.len and pattern[p2] == '*') p2 += 1;

                    if (p2 >= pattern.len) return WM_MATCH;

                    // Try matching remaining pattern at each position
                    while (ti <= text.len) {
                        const result = doWildmatch(pattern[p2..], text[ti..], flags);
                        if (result == WM_MATCH) return WM_MATCH;
                        if (result == WM_ABORT_ALL) return WM_ABORT_ALL;
                        if (ti >= text.len) break;
                        ti += 1;
                    }
                    return WM_ABORT_ALL;
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
                if (pi >= pattern.len) return WM_NOMATCH;
                if (ti >= text.len) return WM_NOMATCH;
                if (!charEqual(pattern[pi], text[ti], case_fold)) return WM_NOMATCH;
                pi += 1;
                ti += 1;
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

    // Exact match
    try testing.expectEqual(WM_MATCH, wildmatch("foo", "foo", 0));
    try testing.expect(wildmatch("foo", "bar", 0) != WM_MATCH);

    // ? matches single char
    try testing.expectEqual(WM_MATCH, wildmatch("???", "foo", 0));
    try testing.expect(wildmatch("??", "foo", 0) != WM_MATCH);

    // * matches anything except /
    try testing.expectEqual(WM_MATCH, wildmatch("*", "foo", 0));
    try testing.expectEqual(WM_MATCH, wildmatch("f*", "foo", 0));

    // * with WM_PATHNAME doesn't match /
    try testing.expect(wildmatch("*", "foo/bar", WM_PATHNAME) != WM_MATCH);
    try testing.expectEqual(WM_MATCH, wildmatch("*/*", "foo/bar", WM_PATHNAME));

    // ** matches across /
    try testing.expectEqual(WM_MATCH, wildmatch("**", "foo/bar", WM_PATHNAME));
    try testing.expectEqual(WM_MATCH, wildmatch("**/bar", "foo/bar", WM_PATHNAME));
    try testing.expectEqual(WM_MATCH, wildmatch("foo/**", "foo/bar", WM_PATHNAME));

    // Character classes
    try testing.expectEqual(WM_MATCH, wildmatch("[abc]", "a", 0));
    try testing.expect(wildmatch("[abc]", "d", 0) != WM_MATCH);
    try testing.expectEqual(WM_MATCH, wildmatch("[a-z]", "m", 0));
    try testing.expect(wildmatch("[a-z]", "M", 0) != WM_MATCH);

    // Negated classes
    try testing.expect(wildmatch("[!abc]", "a", 0) != WM_MATCH);
    try testing.expectEqual(WM_MATCH, wildmatch("[!abc]", "d", 0));

    // Case folding
    try testing.expectEqual(WM_MATCH, wildmatch("foo", "FOO", WM_CASEFOLD));

    // Backslash escaping
    try testing.expectEqual(WM_MATCH, wildmatch("\\*", "*", 0));
    try testing.expect(wildmatch("\\*", "foo", 0) != WM_MATCH);

    // Empty patterns
    try testing.expectEqual(WM_MATCH, wildmatch("", "", 0));
    try testing.expect(wildmatch("", "foo", 0) != WM_MATCH);
}
