/// Compose file parser. Parses a buffer into Entry values.
/// Include lines with literal paths are resolved recursively via parseComposeWithIncludes.
/// %H/%L/%S substitutions are supported when home_dir/locale are threaded in.
const std = @import("std");
const keysym_mod = @import("../keysym.zig");
pub const Keysym = keysym_mod.Keysym;

pub const Result = struct { utf8: []const u8, keysym: Keysym };
pub const Entry = struct { syms: []Keysym, result: Result };

pub fn freeEntries(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| {
        alloc.free(entry.syms);
        alloc.free(entry.result.utf8);
    }
    alloc.free(entries);
}

// Trim helpers (std.mem.trimLeft/trimRight removed in 0.16)

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r')) : (i += 1) {}
    return s[i..];
}

fn trimRight(s: []const u8) []const u8 {
    var i: usize = s.len;
    while (i > 0 and (s[i - 1] == ' ' or s[i - 1] == '\t' or s[i - 1] == '\r')) : (i -= 1) {}
    return s[0..i];
}

fn trim(s: []const u8) []const u8 {
    return trimLeft(trimRight(s));
}

/// Decode a quoted Compose string body. Handles \" \\ \n \t and octal \NNN escapes.
fn decodeString(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\') {
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= s.len) break;
        switch (s[i]) {
            '"' => {
                try out.append(alloc, '"');
                i += 1;
            },
            '\\' => {
                try out.append(alloc, '\\');
                i += 1;
            },
            'n' => {
                try out.append(alloc, '\n');
                i += 1;
            },
            't' => {
                try out.append(alloc, '\t');
                i += 1;
            },
            '0'...'7' => {
                var end = i;
                while (end < s.len and end - i < 3 and s[end] >= '0' and s[end] <= '7') : (end += 1) {}
                const val = std.fmt.parseInt(u8, s[i..end], 8) catch 0;
                try out.append(alloc, val);
                i = end;
            },
            else => {
                try out.append(alloc, s[i]);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Default system compose directory (where locale-specific Compose files live).
pub const DFLT_SYSTEM_COMPOSE_DIR: []const u8 = "/usr/share/X11/locale";

const MAX_INCLUDE_DEPTH: u32 = 32;

const IncludeContext = struct {
    io: std.Io,
    /// Directory used to resolve relative paths in include directives.
    /// Null means only absolute paths work.
    base_dir: ?[]const u8,
    /// $HOME value from the environment, for %H expansion.
    home_dir: ?[]const u8,
    /// System compose directory, for %S and %L expansion.
    system_compose_dir: []const u8,
    /// Locale name (e.g. "en_US.UTF-8"), for %L expansion.
    locale: ?[]const u8,
};

fn parseComposeImpl(
    alloc: std.mem.Allocator,
    text: []const u8,
    inc: ?IncludeContext,
    depth: u32,
    entries: *std.ArrayListUnmanaged(Entry),
) !void {
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |raw_line| {
        const line = trim(raw_line);

        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // include directive
        if (std.mem.startsWith(u8, line, "include")) {
            const after_kw = line["include".len..];
            if (after_kw.len > 0 and (after_kw[0] == ' ' or after_kw[0] == '\t' or after_kw[0] == '"')) {
                if (inc) |ictx| resolve_include: {
                    if (depth >= MAX_INCLUDE_DEPTH) break :resolve_include;
                    const rest = trimLeft(after_kw);
                    if (rest.len == 0 or rest[0] != '"') break :resolve_include;
                    const q_end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse break :resolve_include;
                    const raw_path = rest[1 .. 1 + q_end];
                    // Expand %H/%S/%L substitutions; skip unknown %X sequences.
                    const abs_path = blk: {
                        if (std.mem.eql(u8, raw_path, "%H")) {
                            const home = ictx.home_dir orelse break :resolve_include;
                            break :blk std.fs.path.join(alloc, &.{ home, ".XCompose" }) catch break :resolve_include;
                        } else if (std.mem.eql(u8, raw_path, "%S")) {
                            break :blk alloc.dupe(u8, ictx.system_compose_dir) catch break :resolve_include;
                        } else if (std.mem.eql(u8, raw_path, "%L")) {
                            const loc = ictx.locale orelse break :resolve_include;
                            break :blk std.fs.path.join(alloc, &.{ ictx.system_compose_dir, loc, "Compose" }) catch break :resolve_include;
                        } else if (std.mem.indexOfScalar(u8, raw_path, '%') != null) {
                            // Unknown %X substitution; silently skip per X.Org policy.
                            break :resolve_include;
                        } else if (std.fs.path.isAbsolute(raw_path)) {
                            break :blk alloc.dupe(u8, raw_path) catch break :resolve_include;
                        } else if (ictx.base_dir) |bd| {
                            break :blk std.fs.path.join(alloc, &.{ bd, raw_path }) catch break :resolve_include;
                        } else {
                            break :resolve_include;
                        }
                    };
                    defer alloc.free(abs_path);
                    // Read included file; silently skip if missing or unreadable
                    const inc_bytes = std.Io.Dir.cwd().readFileAlloc(ictx.io, abs_path, alloc, .unlimited) catch break :resolve_include;
                    defer alloc.free(inc_bytes);
                    // Recurse; silently skip on any error (X.Org policy)
                    const inc_base: ?[]const u8 = std.fs.path.dirname(abs_path);
                    parseComposeImpl(alloc, inc_bytes, .{
                        .io = ictx.io,
                        .base_dir = inc_base,
                        .home_dir = ictx.home_dir,
                        .system_compose_dir = ictx.system_compose_dir,
                        .locale = ictx.locale,
                    }, depth + 1, entries) catch {};
                }
            }
            continue;
        }

        if (line[0] != '<') continue;

        const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;

        var syms: std.ArrayListUnmanaged(Keysym) = .empty;
        errdefer syms.deinit(alloc);
        var lhs = trimRight(line[0..colon_idx]);
        var lhs_ok = true;
        while (lhs.len > 0) {
            lhs = trimLeft(lhs);
            if (lhs.len == 0) break;
            if (lhs[0] != '<') {
                lhs_ok = false;
                break;
            }
            const close = std.mem.indexOfScalar(u8, lhs, '>') orelse {
                lhs_ok = false;
                break;
            };
            const name = lhs[1..close];
            const ks = keysym_mod.fromName(name, .{}) orelse {
                lhs_ok = false;
                break;
            };
            try syms.append(alloc, ks);
            lhs = lhs[close + 1 ..];
        }

        if (!lhs_ok or syms.items.len == 0) {
            syms.deinit(alloc);
            continue;
        }

        var rhs = trimLeft(line[colon_idx + 1 ..]);

        var result_utf8_opt: ?[]u8 = null;
        errdefer if (result_utf8_opt) |s| alloc.free(s);
        var result_keysym: Keysym = .no_symbol;

        if (rhs.len > 0 and rhs[0] == '"') {
            var str_end: usize = 1;
            while (str_end < rhs.len) {
                if (rhs[str_end] == '\\') {
                    str_end += 2;
                } else if (rhs[str_end] == '"') {
                    break;
                } else {
                    str_end += 1;
                }
            }
            if (str_end < rhs.len and rhs[str_end] == '"') {
                result_utf8_opt = try decodeString(alloc, rhs[1..str_end]);
                rhs = trimLeft(rhs[str_end + 1 ..]);
            }
        }

        // Strip trailing comment before keysym token
        if (std.mem.indexOfScalar(u8, rhs, '#')) |hi| {
            rhs = trimRight(rhs[0..hi]);
        } else {
            rhs = trimRight(rhs);
        }

        if (rhs.len > 0) {
            var tok_end: usize = 0;
            while (tok_end < rhs.len and rhs[tok_end] != ' ' and rhs[tok_end] != '\t') : (tok_end += 1) {}
            const tok = rhs[0..tok_end];
            if (keysym_mod.fromName(tok, .{})) |ks| {
                result_keysym = ks;
            }
        }

        // At least one of string or keysym must be present
        if (result_utf8_opt == null and result_keysym == .no_symbol) {
            syms.deinit(alloc);
            continue;
        }

        const utf8_str = result_utf8_opt orelse try alloc.dupe(u8, "");

        try entries.append(alloc, .{
            .syms = try syms.toOwnedSlice(alloc),
            .result = .{ .utf8 = utf8_str, .keysym = result_keysym },
        });
    }
}

/// Parse a Compose text buffer without include resolution. Include lines are silently skipped.
pub fn parseCompose(alloc: std.mem.Allocator, text: []const u8) ![]Entry {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (entries.items) |e| {
            alloc.free(e.syms);
            alloc.free(e.result.utf8);
        }
        entries.deinit(alloc);
    }
    try parseComposeImpl(alloc, text, null, 0, &entries);
    return entries.toOwnedSlice(alloc);
}

/// Parse a Compose text buffer with recursive include resolution.
/// Pass null for base_dir to allow only absolute include paths.
/// home_dir and locale enable %H/%S/%L substitution; pass null to skip those paths.
/// system_compose_dir is used for %S and %L (defaults to DFLT_SYSTEM_COMPOSE_DIR).
/// Missing includes are silently skipped.
pub fn parseComposeWithIncludes(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_dir: ?[]const u8,
    home_dir: ?[]const u8,
    system_compose_dir: []const u8,
    locale: ?[]const u8,
    text: []const u8,
) ![]Entry {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (entries.items) |e| {
            alloc.free(e.syms);
            alloc.free(e.result.utf8);
        }
        entries.deinit(alloc);
    }
    try parseComposeImpl(alloc, text, .{
        .io = io,
        .base_dir = base_dir,
        .home_dir = home_dir,
        .system_compose_dir = system_compose_dir,
        .locale = locale,
    }, 0, &entries);
    return entries.toOwnedSlice(alloc);
}

test "parseCompose entries" {
    const text =
        \\# comment
        \\<dead_acute> <a> : "á" aacute
        \\<Multi_key> <o> <c> : copyright
    ;
    const entries = try parseCompose(std.testing.allocator, text);
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 2), entries[0].syms.len);
    try std.testing.expectEqual(Keysym.fromName("dead_acute", .{}).?, entries[0].syms[0]);
    try std.testing.expectEqual(Keysym.fromName("a", .{}).?, entries[0].syms[1]);
    try std.testing.expectEqualStrings("á", entries[0].result.utf8);
    try std.testing.expectEqual(Keysym.fromName("aacute", .{}).?, entries[0].result.keysym);
    try std.testing.expectEqual(@as(usize, 3), entries[1].syms.len);
    try std.testing.expectEqual(Keysym.fromName("copyright", .{}).?, entries[1].result.keysym);
    try std.testing.expectEqualStrings("", entries[1].result.utf8);
}

test "parseCompose skips bad keysym" {
    const text =
        \\<dead_acute> <not_a_real_keysym_xyz> : "x"
        \\<dead_acute> <a> : "á"
    ;
    const entries = try parseCompose(std.testing.allocator, text);
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("á", entries[0].result.utf8);
}

test "parseCompose skips no result" {
    const text =
        \\<dead_acute> <a> :
    ;
    const entries = try parseCompose(std.testing.allocator, text);
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseCompose string escapes" {
    const text =
        \\<dead_acute> <a> : "\\" backslash
    ;
    const entries = try parseCompose(std.testing.allocator, text);
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("\\", entries[0].result.utf8);
}

test "parseComposeWithIncludes resolves absolute include path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Write the included compose file
    const inc_text = "<dead_grave> <e> : \"\xc3\xa8\" egrave\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "inc.compose", .data = inc_text });
    var pathbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pathbuf);
    const base = pathbuf[0..n];
    const inc_abs = try std.fs.path.join(std.testing.allocator, &.{ base, "inc.compose" });
    defer std.testing.allocator.free(inc_abs);
    // Main buffer with an include directive using the absolute path
    const main_text = try std.fmt.allocPrint(
        std.testing.allocator,
        "include \"{s}\"\n<dead_acute> <a> : \"\xc3\xa1\" aacute\n",
        .{inc_abs},
    );
    defer std.testing.allocator.free(main_text);
    const entries = try parseComposeWithIncludes(std.testing.allocator, io, null, null, DFLT_SYSTEM_COMPOSE_DIR, null, main_text);
    defer freeEntries(std.testing.allocator, entries);
    // Included entry first, then main buffer entry
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("\xc3\xa8", entries[0].result.utf8); // egrave from include
    try std.testing.expectEqualStrings("\xc3\xa1", entries[1].result.utf8); // aacute from main
}

test "parseComposeWithIncludes resolves relative include path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const inc_text = "<dead_tilde> <n> : \"\xc3\xb1\" ntilde\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "rel.compose", .data = inc_text });
    var pathbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pathbuf);
    const base = pathbuf[0..n];
    // Main buffer uses a relative path; we pass base as base_dir
    const main_text = "include \"rel.compose\"\n<dead_acute> <a> : \"\xc3\xa1\" aacute\n";
    const entries = try parseComposeWithIncludes(std.testing.allocator, io, base, null, DFLT_SYSTEM_COMPOSE_DIR, null, main_text);
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("\xc3\xb1", entries[0].result.utf8); // ntilde from include
    try std.testing.expectEqualStrings("\xc3\xa1", entries[1].result.utf8); // aacute from main
}

test "parseComposeWithIncludes skips percent H without home_dir" {
    const io = std.testing.io;
    // When home_dir is null, %H cannot be expanded so the include is silently skipped.
    const text =
        \\include "%H"
        \\<dead_acute> <a> : "á" aacute
    ;
    const entries = try parseComposeWithIncludes(std.testing.allocator, io, null, null, DFLT_SYSTEM_COMPOSE_DIR, null, text);
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("á", entries[0].result.utf8);
}

test "parseComposeWithIncludes resolves %H include path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Write a .XCompose file in the tmp dir (simulates $HOME/.XCompose)
    const home_xcompose = "<dead_grave> <e> : \"\xc3\xa8\" egrave\n";
    try tmp.dir.writeFile(io, .{ .sub_path = ".XCompose", .data = home_xcompose });
    var pathbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pathbuf);
    const home = pathbuf[0..n];
    // Main buffer with include "%H"
    const main_text = "include \"%H\"\n<dead_acute> <a> : \"\xc3\xa1\" aacute\n";
    const entries = try parseComposeWithIncludes(std.testing.allocator, io, null, home, DFLT_SYSTEM_COMPOSE_DIR, null, main_text);
    defer freeEntries(std.testing.allocator, entries);
    // %H resolves to home/.XCompose; its entry appears first
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("\xc3\xa8", entries[0].result.utf8); // egrave from %H
    try std.testing.expectEqualStrings("\xc3\xa1", entries[1].result.utf8); // aacute from main
}
