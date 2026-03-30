const std = @import("std");

/// Built-in diff driver definition
pub const DiffDriver = struct {
    name: []const u8,
    /// Match function - returns true if line is a funcname line
    match_fn: *const fn ([]const u8) bool,
};

/// Builtin diff drivers
pub const builtin_drivers = [_]DiffDriver{
    .{ .name = "ada", .match_fn = matchAda },
    .{ .name = "bash", .match_fn = matchBash },
    .{ .name = "bibtex", .match_fn = matchBibtex },
    .{ .name = "cpp", .match_fn = matchCpp },
    .{ .name = "csharp", .match_fn = matchCsharp },
    .{ .name = "css", .match_fn = matchCss },
    .{ .name = "dts", .match_fn = matchDts },
    .{ .name = "elixir", .match_fn = matchElixir },
    .{ .name = "fortran", .match_fn = matchFortran },
    .{ .name = "fountain", .match_fn = matchFountain },
    .{ .name = "golang", .match_fn = matchGolang },
    .{ .name = "html", .match_fn = matchHtml },
    .{ .name = "java", .match_fn = matchJava },
    .{ .name = "kotlin", .match_fn = matchKotlin },
    .{ .name = "markdown", .match_fn = matchMarkdown },
    .{ .name = "matlab", .match_fn = matchMatlab },
    .{ .name = "objc", .match_fn = matchObjc },
    .{ .name = "pascal", .match_fn = matchPascal },
    .{ .name = "perl", .match_fn = matchPerl },
    .{ .name = "php", .match_fn = matchPhp },
    .{ .name = "python", .match_fn = matchPython },
    .{ .name = "ruby", .match_fn = matchRuby },
    .{ .name = "rust", .match_fn = matchRust },
    .{ .name = "scheme", .match_fn = matchScheme },
    .{ .name = "tex", .match_fn = matchTex },
};

/// Look up a builtin diff driver by name
pub fn findDriverByName(name: []const u8) ?*const DiffDriver {
    for (&builtin_drivers) |*d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

/// Default funcname pattern: line starts with alpha, $, or _
pub fn matchDefault(line: []const u8) bool {
    if (line.len == 0) return false;
    const c = line[0];
    return std.ascii.isAlphabetic(c) or c == '$' or c == '_';
}

// Helper functions
fn skipWhitespace(line: []const u8) []const u8 {
    return std.mem.trimLeft(u8, line, " \t");
}

fn startsWithWord(line: []const u8, word: []const u8) bool {
    if (line.len < word.len) return false;
    if (!std.mem.eql(u8, line[0..word.len], word)) return false;
    if (line.len == word.len) return true;
    const next = line[word.len];
    return next == ' ' or next == '\t' or next == '(' or next == '{' or next == '<' or next == ':' or next == ';';
}

fn startsWithWordCI(line: []const u8, word: []const u8) bool {
    if (line.len < word.len) return false;
    for (0..word.len) |i| {
        if (std.ascii.toLower(line[i]) != std.ascii.toLower(word[i])) return false;
    }
    if (line.len == word.len) return true;
    const next = line[word.len];
    return next == ' ' or next == '\t' or next == '(' or next == '{' or next == '<' or next == ':' or next == ';';
}

fn containsWord(line: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (i + word.len <= line.len) {
        if (std.mem.eql(u8, line[i .. i + word.len], word)) {
            // Check word boundary
            const before_ok = (i == 0) or !std.ascii.isAlphanumeric(line[i - 1]);
            const after_ok = (i + word.len == line.len) or !std.ascii.isAlphanumeric(line[i + word.len]);
            if (before_ok and after_ok) return true;
        }
        i += 1;
    }
    return false;
}

fn endsWithChar(line: []const u8, chars: []const u8) bool {
    const trimmed = std.mem.trimRight(u8, line, " \t");
    if (trimmed.len == 0) return false;
    for (chars) |c| {
        if (trimmed[trimmed.len - 1] == c) return true;
    }
    return false;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ============================================================
// Language-specific matchers
// ============================================================

fn matchAda(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    // Negative: "is new", "renames", "is separate"
    if (containsWord(trimmed, "is new") or containsWord(trimmed, "renames") or containsWord(trimmed, "is separate")) return false;
    // Positive: procedure, function, package, protected, task
    if (startsWithWordCI(trimmed, "procedure") or startsWithWordCI(trimmed, "function")) return true;
    if (startsWithWordCI(trimmed, "package") or startsWithWordCI(trimmed, "protected") or startsWithWordCI(trimmed, "task")) return true;
    return false;
}

fn matchBash(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    if (trimmed.len == 0) return false;

    // "function name ..." style
    if (std.mem.startsWith(u8, trimmed, "function")) {
        const rest = skipWhitespace(trimmed[8..]);
        if (rest.len > 0 and (std.ascii.isAlphabetic(rest[0]) or rest[0] == '_')) {
            // Must end with {, (, ((, or [[
            const tline = std.mem.trimRight(u8, line, " \t");
            if (tline.len > 0) {
                const last = tline[tline.len - 1];
                if (last == '{' or last == '(' or last == '[') return true;
            }
            return false;
        }
        return false;
    }

    // "name()" or "name ()" style - identifier followed by ()
    var i: usize = 0;
    if (std.ascii.isAlphabetic(trimmed[0]) or trimmed[0] == '_') {
        i = 1;
        while (i < trimmed.len and isIdent(trimmed[i])) i += 1;
        // Skip whitespace
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
        // Check for ()
        if (i < trimmed.len and trimmed[i] == '(') {
            // Must end with {, (, ((, [[
            const tline = std.mem.trimRight(u8, line, " \t");
            if (tline.len > 0) {
                const last = tline[tline.len - 1];
                if (last == '{' or last == '(' or last == '[') return true;
                // Also check for # (comment at end)
                if (std.mem.indexOf(u8, tline, "#")) |_| {
                    // Has comment, check before comment
                    var ci: usize = 0;
                    while (ci < tline.len) {
                        if (tline[ci] == '#') break;
                        ci += 1;
                    }
                    const before_comment = std.mem.trimRight(u8, tline[0..ci], " \t");
                    if (before_comment.len > 0) {
                        const lc = before_comment[before_comment.len - 1];
                        if (lc == '{' or lc == '(' or lc == '[') return true;
                    }
                }
            }
            return false;
        }
    }

    return false;
}

fn matchBibtex(line: []const u8) bool {
    return line.len > 0 and line[0] == '@' and std.ascii.isAlphabetic(if (line.len > 1) line[1] else 0);
}

fn matchCpp(line: []const u8) bool {
    // Negative: labels like "public:", "private:" etc (word followed by : and nothing or comment)
    const trimmed = skipWhitespace(line);
    if (trimmed.len > 0 and std.ascii.isAlphabetic(trimmed[0]) or (trimmed.len > 0 and trimmed[0] == '_')) {
        // Check if it's a label: identifier followed by : and then end/whitespace/comment
        var i: usize = 0;
        while (i < trimmed.len and isIdent(trimmed[i])) i += 1;
        if (i < trimmed.len and trimmed[i] == ':') {
            const after = std.mem.trimLeft(u8, trimmed[i + 1 ..], " \t");
            if (after.len == 0 or std.mem.startsWith(u8, after, "//") or std.mem.startsWith(u8, after, "/*")) {
                return false;
            }
        }
    }

    // Positive: lines starting with optional :: then alpha
    if (line.len > 0) {
        if (std.mem.startsWith(u8, line, "::")) {
            const rest = skipWhitespace(line[2..]);
            if (rest.len > 0 and (std.ascii.isAlphabetic(rest[0]) or rest[0] == '_')) return true;
        }
        if (std.ascii.isAlphabetic(line[0]) or line[0] == '_') return true;
    }
    return false;
}

fn matchCsharp(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    // Negative: control flow keywords
    const neg_keywords = [_][]const u8{ "do", "while", "for", "if", "else", "instanceof", "new", "return", "switch", "case", "throw", "catch", "using" };
    for (neg_keywords) |kw| {
        if (startsWithWord(trimmed, kw)) return false;
    }
    // Positive: class/enum/interface/struct/record/namespace declarations
    if (containsWord(trimmed, "class") or containsWord(trimmed, "enum") or containsWord(trimmed, "interface") or containsWord(trimmed, "struct") or containsWord(trimmed, "record")) return true;
    if (startsWithWord(trimmed, "namespace")) return true;
    // Method signatures (contain parentheses, not ending with ;)
    if (std.mem.indexOf(u8, trimmed, "(") != null and !endsWithChar(trimmed, ";")) return true;
    return false;
}

fn matchCss(line: []const u8) bool {
    // Negative: lines ending with : or ; (after trimming whitespace)
    const trimmed = std.mem.trimRight(u8, line, " \t");
    if (trimmed.len > 0 and (trimmed[trimmed.len - 1] == ':' or trimmed[trimmed.len - 1] == ';')) return false;

    // Positive: lines starting with :, [, @, ., # or _/a-z/0-9
    if (line.len == 0) return false;
    const c = line[0];
    if (c == ':' or c == '[' or c == '@' or c == '.' or c == '#') return true;
    if (c == '_' or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z')) return true;
    return false;
}

fn matchDts(line: []const u8) bool {
    const trimmed_r = std.mem.trimRight(u8, line, " \t");
    // Negative: lines ending with ; or =
    if (trimmed_r.len > 0 and (trimmed_r[trimmed_r.len - 1] == ';' or trimmed_r[trimmed_r.len - 1] == '=')) return false;

    const trimmed = skipWhitespace(line);
    if (trimmed.len == 0) return false;
    // Lines starting with / { (root node)
    if (trimmed[0] == '/') return true;
    // Lines starting with & (reference)
    if (trimmed[0] == '&') return true;
    // Lines starting with alpha or _
    if (std.ascii.isAlphabetic(trimmed[0]) or trimmed[0] == '_') return true;
    return false;
}

fn matchElixir(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    const keywords = [_][]const u8{ "defmacro", "defmodule", "defimpl", "defprotocol", "defp", "def", "test" };
    for (keywords) |kw| {
        if (startsWithWord(trimmed, kw)) return true;
    }
    return false;
}

fn matchFortran(line: []const u8) bool {
    // Negative: comment lines (C or * in column 1, or ! after whitespace)
    if (line.len > 0 and (line[0] == 'C' or line[0] == 'c' or line[0] == '*')) return false;
    const trimmed = skipWhitespace(line);
    if (trimmed.len > 0 and trimmed[0] == '!') return false;

    // Negative: "MODULE PROCEDURE"
    if (containsCI(trimmed, "module") and containsCI(trimmed, "procedure")) return false;

    // Positive: PROGRAM, MODULE, BLOCK DATA, SUBROUTINE, FUNCTION, END PROGRAM, etc.
    const fkeywords = [_][]const u8{ "program", "module", "subroutine", "function", "block" };
    for (fkeywords) |kw| {
        if (startsWithWordCI(trimmed, kw)) return true;
    }
    // Also match after type declarations like "integer function"
    if (containsCI(trimmed, "subroutine") or containsCI(trimmed, "function")) return true;
    if (startsWithWordCI(trimmed, "end")) return true;
    return false;
}

fn containsCI(line: []const u8, word: []const u8) bool {
    if (line.len < word.len) return false;
    var i: usize = 0;
    while (i + word.len <= line.len) {
        var match = true;
        for (0..word.len) |j| {
            if (std.ascii.toLower(line[i + j]) != std.ascii.toLower(word[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
        i += 1;
    }
    return false;
}

fn matchFountain(line: []const u8) bool {
    if (line.len == 0) return false;
    // Scene headings: .xxx or INT/EXT/EST/I/E
    if (line[0] == '.' and line.len > 1 and line[1] != '.') return true;
    const upper = std.ascii.toLower(line[0]);
    _ = upper;
    if (startsWithWordCI(line, "int") or startsWithWordCI(line, "ext") or startsWithWordCI(line, "est")) return true;
    if (std.mem.startsWith(u8, line, "I/E") or std.mem.startsWith(u8, line, "i/e")) return true;
    return false;
}

fn matchGolang(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    if (std.mem.startsWith(u8, trimmed, "func")) {
        if (trimmed.len == 4 or trimmed[4] == ' ' or trimmed[4] == '\t') return true;
    }
    if (std.mem.startsWith(u8, trimmed, "type")) {
        if (trimmed.len > 4 and (trimmed[4] == ' ' or trimmed[4] == '\t')) {
            if (containsWord(trimmed, "struct") or containsWord(trimmed, "interface")) return true;
        }
    }
    return false;
}

fn matchHtml(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    // <h1> through <h6>
    if (trimmed.len >= 3 and trimmed[0] == '<' and (trimmed[1] == 'h' or trimmed[1] == 'H')) {
        if (trimmed[2] >= '1' and trimmed[2] <= '6') return true;
    }
    return false;
}

fn matchJava(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    // Negative: control flow keywords
    const neg_keywords = [_][]const u8{ "catch", "do", "for", "if", "instanceof", "new", "return", "switch", "throw", "while" };
    for (neg_keywords) |kw| {
        if (startsWithWord(trimmed, kw)) return false;
    }
    // Positive: class/enum/interface/record declarations
    if (containsWord(trimmed, "class") or containsWord(trimmed, "enum") or containsWord(trimmed, "interface") or containsWord(trimmed, "record")) return true;
    // Method signatures: has ( but doesn't end with ;
    if (std.mem.indexOf(u8, trimmed, "(") != null) {
        const tr = std.mem.trimRight(u8, trimmed, " \t");
        if (tr.len > 0 and tr[tr.len - 1] != ';') return true;
    }
    return false;
}

fn matchKotlin(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    if (containsWord(trimmed, "fun") or containsWord(trimmed, "class") or containsWord(trimmed, "interface")) return true;
    return false;
}

fn matchMarkdown(line: []const u8) bool {
    // Up to 3 leading spaces, then 1-6 # followed by space/tab
    var spaces: usize = 0;
    while (spaces < line.len and spaces < 3 and line[spaces] == ' ') spaces += 1;
    if (spaces + 1 >= line.len) return false;
    if (line[spaces] != '#') return false;
    var hashes: usize = 0;
    var i = spaces;
    while (i < line.len and line[i] == '#') {
        hashes += 1;
        i += 1;
    }
    if (hashes < 1 or hashes > 6) return false;
    if (i < line.len and (line[i] == ' ' or line[i] == '\t')) return true;
    return false;
}

fn matchMatlab(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    // classdef or function
    if (startsWithWord(trimmed, "classdef") or startsWithWord(trimmed, "function")) return true;
    // Octave sections: %%, %%%, ##
    if (std.mem.startsWith(u8, trimmed, "%%") or std.mem.startsWith(u8, trimmed, "##")) {
        // Must be followed by space
        const prefix_len: usize = if (trimmed.len >= 3 and trimmed[2] == '%') 3 else 2;
        if (prefix_len <= trimmed.len and (prefix_len == trimmed.len or trimmed[prefix_len] == ' ' or trimmed[prefix_len] == '\t')) return true;
    }
    return false;
}

fn matchObjc(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    // Negative: control flow
    const neg_keywords = [_][]const u8{ "do", "for", "if", "else", "return", "switch", "while" };
    for (neg_keywords) |kw| {
        if (startsWithWord(trimmed, kw)) return false;
    }
    // Objective-C methods: +/- (type) name
    if (trimmed.len > 0 and (trimmed[0] == '-' or trimmed[0] == '+')) {
        const rest = skipWhitespace(trimmed[1..]);
        if (rest.len > 0 and rest[0] == '(') return true;
    }
    // @implementation, @interface, @protocol
    if (trimmed.len > 0 and trimmed[0] == '@') {
        if (startsWithWord(trimmed[1..], "implementation") or startsWithWord(trimmed[1..], "interface") or startsWithWord(trimmed[1..], "protocol")) return true;
    }
    // C-style functions
    if (std.mem.indexOf(u8, trimmed, "(") != null and !endsWithChar(trimmed, ";")) {
        if (trimmed.len > 0 and (std.ascii.isAlphabetic(trimmed[0]) or trimmed[0] == '_')) return true;
    }
    return false;
}

fn matchPascal(line: []const u8) bool {
    if (containsWord(line, "procedure") or containsWord(line, "function")) return true;
    if (startsWithWord(line, "constructor") or startsWithWord(line, "destructor")) return true;
    if (startsWithWord(line, "interface") or startsWithWord(line, "implementation")) return true;
    if (startsWithWord(line, "initialization") or startsWithWord(line, "finalization")) return true;
    if (containsWord(line, "class") or containsWord(line, "record")) return true;
    return false;
}

fn matchPerl(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "package ")) return true;
    if (std.mem.startsWith(u8, line, "sub ")) return true;
    if (std.mem.startsWith(u8, line, "=head")) return true;
    const keywords = [_][]const u8{ "BEGIN", "END", "INIT", "CHECK", "UNITCHECK", "AUTOLOAD", "DESTROY" };
    for (keywords) |kw| {
        if (startsWithWord(line, kw)) return true;
    }
    return false;
}

fn matchPhp(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    if (containsWord(trimmed, "function")) return true;
    if (startsWithWord(trimmed, "class") or startsWithWord(trimmed, "enum") or startsWithWord(trimmed, "interface") or startsWithWord(trimmed, "trait")) return true;
    // With modifiers
    const modifiers = [_][]const u8{ "final", "abstract", "public", "protected", "private", "static" };
    for (modifiers) |mod| {
        if (startsWithWord(trimmed, mod)) {
            if (containsWord(trimmed, "class") or containsWord(trimmed, "function") or containsWord(trimmed, "enum") or containsWord(trimmed, "interface") or containsWord(trimmed, "trait")) return true;
        }
    }
    return false;
}

fn matchPython(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    if (startsWithWord(trimmed, "class") or startsWithWord(trimmed, "def")) return true;
    if (std.mem.startsWith(u8, trimmed, "async")) {
        const rest = skipWhitespace(trimmed[5..]);
        if (startsWithWord(rest, "def")) return true;
    }
    return false;
}

fn matchRuby(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    return startsWithWord(trimmed, "class") or startsWithWord(trimmed, "module") or startsWithWord(trimmed, "def");
}

fn matchRust(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    // Keywords that indicate a funcname line
    const keywords = [_][]const u8{ "fn", "struct", "enum", "union", "mod", "trait", "impl", "macro_rules!" };

    // Direct match
    for (keywords) |kw| {
        if (startsWithRustKeyword(trimmed, kw)) return true;
    }

    // After pub/pub(...) or const/unsafe/async/extern
    var rest = trimmed;
    // Skip pub/pub(...)
    if (std.mem.startsWith(u8, rest, "pub")) {
        rest = rest[3..];
        if (rest.len > 0 and rest[0] == '(') {
            // Skip pub(crate), pub(self), etc.
            if (std.mem.indexOf(u8, rest, ")")) |close| {
                rest = rest[close + 1 ..];
            }
        }
        rest = skipWhitespace(rest);
    }
    // Skip async/const/unsafe/extern
    const qualifiers = [_][]const u8{ "async", "const", "unsafe", "extern" };
    for (qualifiers) |q| {
        if (std.mem.startsWith(u8, rest, q) and rest.len > q.len and (rest[q.len] == ' ' or rest[q.len] == '\t')) {
            rest = skipWhitespace(rest[q.len..]);
            // extern may be followed by "C" or "Rust"
            if (std.mem.eql(u8, q, "extern") and rest.len > 0 and rest[0] == '"') {
                if (std.mem.indexOf(u8, rest[1..], "\"")) |close| {
                    rest = skipWhitespace(rest[close + 2 ..]);
                }
            }
        }
    }
    for (keywords) |kw| {
        if (startsWithRustKeyword(rest, kw)) return true;
    }
    return false;
}

fn startsWithRustKeyword(line: []const u8, keyword: []const u8) bool {
    if (line.len < keyword.len) return false;
    if (!std.mem.eql(u8, line[0..keyword.len], keyword)) return false;
    if (line.len == keyword.len) return true;
    const next = line[keyword.len];
    return next == ' ' or next == '\t' or next == '<' or next == '(' or next == '{' or next == ':';
}

fn matchScheme(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    if (trimmed.len == 0 or trimmed[0] != '(') return false;
    const rest = trimmed[1..];
    // define, defstruct, defsyntax, defclass, defmethod, defrules, defrecord, defproto, defalias, def
    if (std.mem.startsWith(u8, rest, "define") or std.mem.startsWith(u8, rest, "def")) return true;
    // library, module, struct, class
    if (std.mem.startsWith(u8, rest, "library") or std.mem.startsWith(u8, rest, "module")) return true;
    if (std.mem.startsWith(u8, rest, "struct") or std.mem.startsWith(u8, rest, "class")) return true;
    return false;
}

fn matchTex(line: []const u8) bool {
    // \section, \subsection, \subsubsection, \chapter, \part
    if (line.len == 0 or line[0] != '\\') return false;
    const rest = line[1..];
    if (std.mem.startsWith(u8, rest, "section") or
        std.mem.startsWith(u8, rest, "subsection") or
        std.mem.startsWith(u8, rest, "subsubsection") or
        std.mem.startsWith(u8, rest, "chapter") or
        std.mem.startsWith(u8, rest, "part"))
    {
        return true;
    }
    return false;
}
