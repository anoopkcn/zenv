//! zenv.json is JSONC: JSON plus `//` line and `/* */` block comments.
//! `strip` blanks the comments so std.json can parse the text, and the span
//! helpers locate values in it, so writers can edit the file as text and keep
//! the comments (re-serializing a parsed tree would drop them).
//!
//! Spans index the stripped text, which has the same byte offsets as the file.
//! The helpers assume valid JSON: parse the stripped text with std.json first.
//! std.json refuses duplicate keys and keeps members in file order, so member i
//! of `members` is entry i of the parsed `ObjectMap`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A copy of `text` with every comment replaced by spaces (newlines kept), so
/// byte offsets, lines and columns still match `text`. An unterminated block
/// comment is left in place for the JSON parser to report where it starts.
pub fn strip(a: Allocator, text: []const u8) ![]u8 {
    const out = try a.dupe(u8, text);
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == '"') {
            i = stringEnd(out, i);
        } else if (std.mem.startsWith(u8, out[i..], "//")) {
            const end = std.mem.findScalarPos(u8, out, i, '\n') orelse out.len;
            @memset(out[i..end], ' ');
            i = end;
        } else if (std.mem.startsWith(u8, out[i..], "/*")) {
            const end = (std.mem.findPos(u8, out, i + 2, "*/") orelse return out) + 2;
            for (out[i..end]) |*c| if (c.* != '\n') {
                c.* = ' ';
            };
            i = end;
        } else i += 1;
    }
    return out;
}

/// Bytes `start..end` of a stripped text.
pub const Span = struct { start: usize, end: usize };

/// An object member: its key (with the quotes) and its value.
pub const Member = struct { key: Span, value: Span };

/// Replace bytes `span` of the file with `text`.
pub const Edit = struct { span: Span, text: []const u8 };

/// The file's content with `edit` applied.
pub fn apply(a: Allocator, content: []const u8, edit: Edit) ![]u8 {
    return std.mem.concat(a, u8, &.{
        content[0..edit.span.start],
        edit.text,
        content[edit.span.end..],
    });
}

/// The top-level value.
pub fn root(s: []const u8) Span {
    const start = skipSpace(s, 0);
    return .{ .start = start, .end = valueEnd(s, start) };
}

/// The members of the object at `obj`, in file order.
pub fn members(a: Allocator, s: []const u8, obj: Span) ![]Member {
    var list: std.ArrayList(Member) = .empty;
    var i = skipSpace(s, obj.start + 1);
    while (s[i] != '}') {
        const key: Span = .{ .start = i, .end = stringEnd(s, i) };
        i = skipSpace(s, skipSpace(s, key.end) + 1); // past the ':'
        const value: Span = .{ .start = i, .end = valueEnd(s, i) };
        try list.append(a, .{ .key = key, .value = value });
        i = skipSpace(s, value.end);
        if (s[i] == ',') i = skipSpace(s, i + 1);
    }
    return list.toOwnedSlice(a);
}

/// The elements of the array at `arr`, in file order.
pub fn items(a: Allocator, s: []const u8, arr: Span) ![]Span {
    var list: std.ArrayList(Span) = .empty;
    var i = skipSpace(s, arr.start + 1);
    while (s[i] != ']') {
        const item: Span = .{ .start = i, .end = valueEnd(s, i) };
        try list.append(a, item);
        i = skipSpace(s, item.end);
        if (s[i] == ',') i = skipSpace(s, i + 1);
    }
    return list.toOwnedSlice(a);
}

/// The edit that adds `entry` (an element, or `"key": value` for an object) as
/// the last entry of the container at `span`. When the last entry ends its
/// line, the new one goes on a line of its own with the same indentation, after
/// any comment on that line; otherwise it follows on the same line.
pub fn append(a: Allocator, content: []const u8, s: []const u8, span: Span, entry: []const u8) !Edit {
    const last_end = if (s[span.start] == '{') blk: {
        const ms = try members(a, s, span);
        break :blk if (ms.len > 0) ms[ms.len - 1].value.end else null;
    } else blk: {
        const is = try items(a, s, span);
        break :blk if (is.len > 0) is[is.len - 1].end else null;
    };
    const end = last_end orelse
        return .{ .span = .{ .start = span.start + 1, .end = span.start + 1 }, .text = entry };

    const newline = lineEnd(content, end) orelse return .{
        .span = .{ .start = end, .end = end },
        .text = try std.mem.concat(a, u8, &.{ ", ", entry }),
    };
    return .{
        .span = .{ .start = end, .end = newline },
        .text = try std.mem.concat(a, u8, &.{
            ",",
            content[end..newline],
            "\n",
            indentOf(s, end),
            entry,
        }),
    };
}

/// The index of the newline in `content` that ends the line at `i`, when only
/// spaces and comments follow `i` on it; null when another token does. A block
/// comment that spans lines moves the end to the line where it closes.
fn lineEnd(content: []const u8, i: usize) ?usize {
    var j = i;
    while (j < content.len) {
        if (std.mem.startsWith(u8, content[j..], "//")) {
            return std.mem.findScalarPos(u8, content, j, '\n');
        } else if (std.mem.startsWith(u8, content[j..], "/*")) {
            j = (std.mem.findPos(u8, content, j + 2, "*/") orelse return null) + 2;
        } else switch (content[j]) {
            '\n' => return j,
            ' ', '\t', '\r' => j += 1,
            else => return null,
        }
    }
    return null;
}

/// The indentation before byte `i`, when only whitespace precedes it on its line.
pub fn ownLineIndent(s: []const u8, i: usize) ?[]const u8 {
    const indent = indentOf(s, i);
    const line = if (std.mem.findScalarLast(u8, s[0..i], '\n')) |n| n + 1 else 0;
    return if (line + indent.len == i) indent else null;
}

/// The leading whitespace of the line holding byte `i`.
fn indentOf(s: []const u8, i: usize) []const u8 {
    const line = if (std.mem.findScalarLast(u8, s[0..i], '\n')) |n| n + 1 else 0;
    var j = line;
    while (j < i and (s[j] == ' ' or s[j] == '\t')) j += 1;
    return s[line..j];
}

fn skipSpace(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and std.mem.findScalar(u8, " \t\r\n", s[j]) != null) j += 1;
    return j;
}

/// The index after the string starting at `start` (its opening quote).
fn stringEnd(s: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < s.len) : (i += 1) switch (s[i]) {
        '\\' => i += 1,
        '"' => return i + 1,
        else => {},
    };
    return s.len;
}

/// The index after the value starting at `start`.
fn valueEnd(s: []const u8, start: usize) usize {
    switch (s[start]) {
        '"' => return stringEnd(s, start),
        '{', '[' => {
            var depth: usize = 0;
            var i = start;
            while (i < s.len) {
                switch (s[i]) {
                    '"' => {
                        i = stringEnd(s, i);
                        continue;
                    },
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    },
                    else => {},
                }
                i += 1;
            }
            return s.len;
        },
        else => {
            var i = start;
            while (i < s.len and std.mem.findScalar(u8, " \t\r\n,]}", s[i]) == null) i += 1;
            return i;
        },
    }
}

const testing = std.testing;

test "strip blanks comments, keeps offsets, and leaves strings alone" {
    const a = testing.allocator;
    const text =
        \\{ // a "quoted" comment
        \\  "url": "http://x/*y*/", /* one
        \\  two */ "n": 1
        \\}
    ;
    const out = try strip(a, text);
    defer a.free(out);
    try testing.expectEqual(text.len, out.len);
    for (text, out) |t, o| if (t == '\n') try testing.expectEqual('\n', o);
    for ([_][]const u8{ "comment", "one", "two" }) |gone| {
        try testing.expect(std.mem.find(u8, out, gone) == null);
    }
    try testing.expectStringStartsWith(out, "{ ");
    try testing.expectStringEndsWith(out, "\"n\": 1\n}");
    var parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("http://x/*y*/", parsed.value.object.get("url").?.string);

    // An unterminated block comment stays for the parser to reject.
    const open = try strip(a, "{ /* x }");
    defer a.free(open);
    try testing.expectEqualStrings("{ /* x }", open);
}

test "members and items find spans in file order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try strip(a,
        \\{ "a": [1, "x\"]", {"b": []}], // c
        \\  "d": {} }
    );
    const ms = try members(a, s, root(s));
    try testing.expectEqual(2, ms.len);
    try testing.expectEqualStrings("\"a\"", s[ms[0].key.start..ms[0].key.end]);
    try testing.expectEqualStrings("{}", s[ms[1].value.start..ms[1].value.end]);
    const is = try items(a, s, ms[0].value);
    try testing.expectEqual(3, is.len);
    try testing.expectEqualStrings("\"x\\\"]\"", s[is[1].start..is[1].end]);
    try testing.expectEqualStrings("{\"b\": []}", s[is[2].start..is[2].end]);
    try testing.expectEqual(0, (try members(a, s, ms[1].value)).len);
}

test "append keeps the layout and the comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][3][]const u8{
        // Inline.
        .{ "[\"a\", \"b\"]", "\"c\"", "[\"a\", \"b\", \"c\"]" },
        // Empty.
        .{ "[]", "\"c\"", "[\"c\"]" },
        // One per line, a comment after the last.
        .{
            "{\n  \"a\": 1, // one\n  \"b\": 2 // two\n}",
            "\"c\": 3",
            "{\n  \"a\": 1, // one\n  \"b\": 2, // two\n  \"c\": 3\n}",
        },
        // A block comment running to the next line.
        .{
            "[\n    \"a\" /* x\n    y */\n]",
            "\"c\"",
            "[\n    \"a\", /* x\n    y */\n    \"c\"\n]",
        },
        // Last entry shares its line with the closing bracket.
        .{ "{\n  \"a\": 1 }", "\"c\": 3", "{\n  \"a\": 1, \"c\": 3 }" },
    };
    for (cases) |case| {
        const s = try strip(a, case[0]);
        const edit = try append(a, case[0], s, root(s), case[1]);
        const got = try apply(a, case[0], edit);
        try testing.expectEqualStrings(case[2], got);
        _ = try std.json.parseFromSliceLeaky(std.json.Value, a, try strip(a, got), .{});
    }
}
