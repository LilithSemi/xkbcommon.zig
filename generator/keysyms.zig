const std = @import("std");

// Build-time generator: parses X.Org's keysymdef.h and XF86keysym.h into
// keysym_tables.zig (the keys namespace and the name/value/unicode tables). The
// headers come from the xorgproto zon dependency and are read as text, so no C
// is compiled. Args: keysymdef.h, XF86keysym.h, output.

pub const Entry = struct { name: []const u8, value: u32, unicode: ?u21, reversible: bool };

// Parses keysymdef.h / XF86keysym.h #define lines into Entries. Holds a small
// buffer for the XF86-prefixed name: a returned Entry.name aliases that buffer
// until the next parseLine call, so parseInto dupes it before parsing on.
pub const Parser = struct {
    name_buf: [128]u8 = undefined,

    pub fn parseLine(self: *Parser, line: []const u8) ?Entry {
        const xk_prefix = "#define XK_";
        const xf86_prefix = "#define XF86XK_";

        var is_xf86 = false;
        var rest: []const u8 = undefined;

        if (std.mem.startsWith(u8, line, xf86_prefix)) {
            rest = line[xf86_prefix.len..];
            is_xf86 = true;
        } else if (std.mem.startsWith(u8, line, xk_prefix)) {
            rest = line[xk_prefix.len..];
        } else {
            return null;
        }

        const name_end = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
        const base_name = rest[0..name_end];
        rest = rest[name_end..];

        while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) {
            rest = rest[1..];
        }

        // value: 0x<hex> directly, or _EVDEVK(0x<hex>) which expands to 0x10081000 + inner
        const value: u32 = blk: {
            if (std.mem.startsWith(u8, rest, "0x")) {
                const val_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                const v = std.fmt.parseInt(u32, rest[2..val_end], 16) catch return null;
                rest = rest[val_end..];
                break :blk v;
            } else if (std.mem.startsWith(u8, rest, "_EVDEVK(0x")) {
                const inner_start = "_EVDEVK(0x".len;
                const inner_end = std.mem.indexOfScalar(u8, rest[inner_start..], ')') orelse return null;
                const inner_hex = rest[inner_start .. inner_start + inner_end];
                const inner = std.fmt.parseInt(u32, inner_hex, 16) catch return null;
                const val_end = inner_start + inner_end + 1;
                rest = rest[val_end..];
                break :blk 0x10081000 + inner;
            } else {
                return null;
            }
        };

        var unicode: ?u21 = null;
        var reversible = false;
        if (std.mem.indexOf(u8, rest, "U+")) |u_at| {
            // reversible unless the char before "U+" is '(' or '<'
            reversible = !(u_at > 0 and (rest[u_at - 1] == '(' or rest[u_at - 1] == '<'));
            const hex = rest[u_at + 2 ..];
            var hex_end: usize = 0;
            while (hex_end < hex.len and std.ascii.isHex(hex[hex_end])) : (hex_end += 1) {}
            unicode = std.fmt.parseInt(u21, hex[0..hex_end], 16) catch null;
        }

        const name: []const u8 = if (is_xf86)
            std.fmt.bufPrint(&self.name_buf, "XF86{s}", .{base_name}) catch return null
        else
            base_name;

        return .{ .name = name, .value = value, .unicode = unicode, .reversible = reversible };
    }

    pub fn parseInto(self: *Parser, alloc: std.mem.Allocator, list: *std.ArrayList(Entry), text: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, text, '\n');
        while (it.next()) |raw| {
            var line = raw;
            while (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            if (self.parseLine(line)) |e| {
                var entry = e;
                // XF86 names alias name_buf; dupe before the next parseLine call
                if (std.mem.startsWith(u8, line, "#define XF86XK_")) {
                    entry.name = try alloc.dupe(u8, e.name);
                }
                try list.append(alloc, entry);
            }
        }
    }
};

fn validBareIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return std.zig.Token.getKeyword(name) == null;
}

fn lessByName(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessByValue(_: void, a: Entry, b: Entry) bool {
    return a.value < b.value;
}

pub fn emit(alloc: std.mem.Allocator, w: anytype, entries: []const Entry) !void {
    try w.writeAll("// Generated at build time by generator/keysyms.zig from xorgproto headers. Do not edit.\n\n");

    try w.writeAll("pub const keys = struct {\n");
    for (entries) |e| {
        if (validBareIdent(e.name))
            try w.print("    pub const {s}: u32 = 0x{x};\n", .{ e.name, e.value })
        else
            try w.print("    pub const @\"{s}\": u32 = 0x{x};\n", .{ e.name, e.value });
    }
    try w.writeAll("};\n\n");

    const by_name = try alloc.dupe(Entry, entries);
    defer alloc.free(by_name);
    std.mem.sort(Entry, by_name, {}, lessByName);
    try w.writeAll("pub const NameEntry = struct { name: []const u8, value: u32 };\n");
    try w.writeAll("pub const names_by_name = [_]NameEntry{\n");
    for (by_name) |e| try w.print("    .{{ .name = \"{s}\", .value = 0x{x} }},\n", .{ e.name, e.value });
    try w.writeAll("};\n\n");

    // names_by_value keeps the first occurrence per value, which is keysymdef order
    const by_value = try alloc.dupe(Entry, entries);
    defer alloc.free(by_value);
    std.mem.sort(Entry, by_value, {}, lessByValue);
    try w.writeAll("pub const names_by_value = [_]NameEntry{\n");
    var seen: ?u32 = null;
    for (by_value) |e| {
        if (seen != null and seen.? == e.value) continue;
        seen = e.value;
        try w.print("    .{{ .name = \"{s}\", .value = 0x{x} }},\n", .{ e.name, e.value });
    }
    try w.writeAll("};\n\n");

    // one entry per keysym value, deduped, first-listed name wins
    try w.writeAll("pub const UnicodeEntry = struct { keysym: u32, unicode: u21 };\n");
    try w.writeAll("pub const keysym_to_unicode = [_]UnicodeEntry{\n");
    var seen_ku: ?u32 = null;
    for (by_value) |e| {
        if (seen_ku != null and seen_ku.? == e.value) continue;
        seen_ku = e.value;
        if (e.unicode) |u|
            try w.print("    .{{ .keysym = 0x{x}, .unicode = 0x{x} }},\n", .{ e.value, u });
    }
    try w.writeAll("};\n\n");

    const by_uni = try alloc.dupe(Entry, entries);
    defer alloc.free(by_uni);
    std.mem.sort(Entry, by_uni, {}, struct {
        fn f(_: void, a: Entry, b: Entry) bool {
            return (a.unicode orelse 0) < (b.unicode orelse 0);
        }
    }.f);
    try w.writeAll("pub const unicode_to_keysym = [_]UnicodeEntry{\n");
    for (by_uni) |e| {
        if (e.reversible) {
            if (e.unicode) |u|
                try w.print("    .{{ .keysym = 0x{x}, .unicode = 0x{x} }},\n", .{ e.value, u });
        }
    }
    try w.writeAll("};\n");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = init.minimal.args.iterate();
    _ = args_it.skip(); // program name
    const keysymdef_path = args_it.next() orelse return error.MissingArgs;
    const xf86_path = args_it.next() orelse return error.MissingArgs;
    const output = args_it.next() orelse return error.MissingArgs;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.Io.Dir.cwd();
    const keysymdef_text = try cwd.readFileAlloc(io, keysymdef_path, arena, .unlimited);
    const xf86_text = try cwd.readFileAlloc(io, xf86_path, arena, .unlimited);

    var parser: Parser = .{};
    var entries = std.ArrayList(Entry).empty;
    try parser.parseInto(arena, &entries, keysymdef_text);
    try parser.parseInto(arena, &entries, xf86_text);

    var out = try cwd.createFile(io, output, .{});
    defer out.close(io);
    var buf: [65536]u8 = undefined;
    var bw = out.writer(io, &buf);
    try emit(gpa, &bw.interface, entries.items);
    try bw.flush();
}

test "parseLine plain latin" {
    var p: Parser = .{};
    const e = p.parseLine("#define XK_A                             0x0041  /* U+0041 LATIN CAPITAL LETTER A */").?;
    try std.testing.expectEqualStrings("A", e.name);
    try std.testing.expectEqual(@as(u32, 0x0041), e.value);
    try std.testing.expectEqual(@as(?u21, 0x0041), e.unicode);
    try std.testing.expect(e.reversible);
}

test "parseLine non-reversible parenthesized" {
    var p: Parser = .{};
    const e = p.parseLine("#define XK_topleftradical                0x08a2  /*(U+250C BOX DRAWINGS LIGHT DOWN AND RIGHT)*/").?;
    try std.testing.expectEqual(@as(u32, 0x08a2), e.value);
    try std.testing.expectEqual(@as(?u21, 0x250C), e.unicode);
    try std.testing.expect(!e.reversible);
}

test "parseLine no unicode" {
    var p: Parser = .{};
    const e = p.parseLine("#define XK_Menu                          0xff67").?;
    try std.testing.expectEqual(@as(u32, 0xff67), e.value);
    try std.testing.expectEqual(@as(?u21, null), e.unicode);
}

test "parseLine ignores guard macros and non-defines" {
    var p: Parser = .{};
    try std.testing.expect(p.parseLine("#define XK_MISCELLANY") == null);
    try std.testing.expect(p.parseLine("#ifdef XK_LATIN1") == null);
    try std.testing.expect(p.parseLine("") == null);
}

test "parseLine angle-bracket form is non-reversible" {
    var p: Parser = .{};
    const e = p.parseLine("#define XK_KP_Space                      0xff80  /*<U+0020 SPACE>*/").?;
    try std.testing.expectEqual(@as(?u21, 0x0020), e.unicode);
    try std.testing.expectEqual(@as(u32, 0xff80), e.value);
    try std.testing.expect(!e.reversible);
}

test "parseLine XF86 direct hex" {
    var p: Parser = .{};
    const e = p.parseLine("#define XF86XK_AudioPlay             0x1008ff14  /* Start playing of audio >   */").?;
    try std.testing.expectEqualStrings("XF86AudioPlay", e.name);
    try std.testing.expectEqual(@as(u32, 0x1008ff14), e.value);
    try std.testing.expectEqual(@as(?u21, null), e.unicode);
    try std.testing.expect(!e.reversible);
}

test "parseLine XF86 EVDEVK form" {
    var p: Parser = .{};
    const e = p.parseLine("#define XF86XK_MediaPlayPause           _EVDEVK(0x0a4)  /*         KEY_PLAYPAUSE */").?;
    try std.testing.expectEqualStrings("XF86MediaPlayPause", e.name);
    try std.testing.expectEqual(@as(u32, 0x10081000 + 0x0a4), e.value);
}

test "parseInto accumulates both prefixes with duped xf86 names" {
    const text =
        \\#define XK_A                             0x0041  /* U+0041 LATIN CAPITAL LETTER A */
        \\#define XF86XK_AudioPlay                 0x1008ff14
        \\#define XF86XK_AudioStop                 0x1008ff15
    ;
    var parser: Parser = .{};
    var list = std.ArrayList(Entry).empty;
    defer list.deinit(std.testing.allocator);
    try parser.parseInto(std.testing.allocator, &list, text);
    defer for (list.items) |e| if (std.mem.startsWith(u8, e.name, "XF86")) std.testing.allocator.free(e.name);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("XF86AudioPlay", list.items[1].name);
    try std.testing.expectEqualStrings("XF86AudioStop", list.items[2].name);
}

test "emit produces keys namespace and sorted tables" {
    const fixture = [_]Entry{
        .{ .name = "A", .value = 0x41, .unicode = 0x41, .reversible = true },
        .{ .name = "1", .value = 0x31, .unicode = 0x31, .reversible = true },
        .{ .name = "Return", .value = 0xff0d, .unicode = 0x0d, .reversible = true },
    };
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try emit(std.testing.allocator, &aw.writer, &fixture);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const A: u32 = 0x41;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const @\"1\": u32 = 0x31;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "keysym_to_unicode") != null);
}

test "keysym_to_unicode deduplicates aliased values" {
    const fixture = [_]Entry{
        .{ .name = "A", .value = 0x41, .unicode = 0x41, .reversible = true },
        .{ .name = "AAlias", .value = 0x41, .unicode = 0x41, .reversible = false },
        .{ .name = "B", .value = 0x42, .unicode = 0x42, .reversible = true },
    };
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try emit(std.testing.allocator, &aw.writer, &fixture);
    const out = aw.writer.buffered();
    const section_start = std.mem.indexOf(u8, out, "keysym_to_unicode") orelse
        return error.MissingSection;
    const section_end = std.mem.indexOf(u8, out[section_start..], "unicode_to_keysym") orelse
        return error.MissingSection;
    const section = out[section_start .. section_start + section_end];
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, section[pos..], ".keysym = 0x41,")) |found| {
        count += 1;
        pos += found + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
