const std = @import("std");

pub const Loc = struct { line: u32, col: u32 };

pub const TokenType = enum {
    eof,
    err,
    // punctuation
    obrace,
    cbrace,
    oparen,
    cparen,
    obracket,
    cbracket,
    dot,
    comma,
    semi,
    equals,
    plus,
    minus,
    star,
    slash,
    bang,
    invert,
    // literals/identifiers
    ident,
    string,
    keyname,
    integer,
    float,
    // keywords
    kw_keymap,
    kw_keycodes,
    kw_types,
    kw_compat,
    kw_symbols,
    kw_geometry,
    kw_key,
    kw_keys,
    kw_row,
    kw_section,
    kw_overlay,
    kw_outline,
    kw_solid,
    kw_text,
    kw_shape,
    kw_logo,
    kw_indicator,
    kw_alias,
    kw_group,
    kw_modifier_map,
    kw_virtual_modifiers,
    kw_type,
    kw_interpret,
    kw_include,
    kw_partial,
    kw_default,
    kw_hidden,
    kw_virtual,
    kw_alphanumeric_keys,
    kw_modifier_keys,
    kw_keypad_keys,
    kw_function_keys,
    kw_alternate,
    kw_alternate_group,
    kw_augment,
    kw_replace,
    kw_override,
    kw_action,
    kw_layout,
    kw_semantics,
};

pub const Token = struct {
    type: TokenType,
    loc: Loc,
    text: []const u8 = "",
    int_val: i64 = 0,
    float_val: f64 = 0,
};

const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "xkb_keymap", .kw_keymap },
    .{ "xkb_keycodes", .kw_keycodes },
    .{ "xkb_types", .kw_types },
    .{ "xkb_compatibility", .kw_compat },
    .{ "xkb_compat", .kw_compat },
    .{ "xkb_compat_map", .kw_compat },
    .{ "xkb_compatibility_map", .kw_compat },
    .{ "xkb_symbols", .kw_symbols },
    .{ "xkb_geometry", .kw_geometry },
    .{ "xkb_layout", .kw_layout },
    .{ "xkb_semantics", .kw_semantics },
    .{ "key", .kw_key },
    .{ "keys", .kw_keys },
    .{ "row", .kw_row },
    .{ "section", .kw_section },
    .{ "overlay", .kw_overlay },
    .{ "outline", .kw_outline },
    .{ "solid", .kw_solid },
    .{ "text", .kw_text },
    .{ "shape", .kw_shape },
    .{ "logo", .kw_logo },
    .{ "indicator", .kw_indicator },
    .{ "alias", .kw_alias },
    .{ "group", .kw_group },
    .{ "modifier_map", .kw_modifier_map },
    .{ "mod_map", .kw_modifier_map },
    .{ "modmap", .kw_modifier_map },
    .{ "virtual_modifiers", .kw_virtual_modifiers },
    .{ "type", .kw_type },
    .{ "interpret", .kw_interpret },
    .{ "include", .kw_include },
    .{ "partial", .kw_partial },
    .{ "default", .kw_default },
    .{ "hidden", .kw_hidden },
    .{ "virtual", .kw_virtual },
    .{ "alphanumeric_keys", .kw_alphanumeric_keys },
    .{ "modifier_keys", .kw_modifier_keys },
    .{ "keypad_keys", .kw_keypad_keys },
    .{ "function_keys", .kw_function_keys },
    .{ "alternate", .kw_alternate },
    .{ "alternate_group", .kw_alternate_group },
    .{ "augment", .kw_augment },
    .{ "replace", .kw_replace },
    .{ "override", .kw_override },
    .{ "action", .kw_action },
});

pub const Lexer = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    owned: std.ArrayList([]u8),

    pub fn init(alloc: std.mem.Allocator, src: []const u8) Lexer {
        return .{
            .alloc = alloc,
            .src = src,
            .owned = .empty,
        };
    }

    pub fn deinit(self: *Lexer) void {
        for (self.owned.items) |s| self.alloc.free(s);
        self.owned.deinit(self.alloc);
    }

    fn advance(self: *Lexer) void {
        if (self.pos >= self.src.len) return;
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
    }

    fn peek(self: *const Lexer) ?u8 {
        if (self.pos < self.src.len) return self.src[self.pos];
        return null;
    }

    fn skipWhitespace(self: *Lexer) void {
        outer: while (true) {
            while (self.peek()) |c| {
                switch (c) {
                    ' ', '\t', '\r', '\n' => self.advance(),
                    else => break,
                }
            }
            const c = self.peek() orelse break;
            if (c == '#') {
                while (self.peek()) |nc| {
                    if (nc == '\n') break;
                    self.advance();
                }
                continue :outer;
            }
            if (c == '/' and self.pos + 1 < self.src.len) {
                const c2 = self.src[self.pos + 1];
                if (c2 == '/') {
                    self.advance();
                    self.advance();
                    while (self.peek()) |nc| {
                        if (nc == '\n') break;
                        self.advance();
                    }
                    continue :outer;
                }
                if (c2 == '*') {
                    self.advance();
                    self.advance();
                    while (self.pos < self.src.len) {
                        if (self.src[self.pos] == '*' and
                            self.pos + 1 < self.src.len and
                            self.src[self.pos + 1] == '/')
                        {
                            self.advance();
                            self.advance();
                            break;
                        }
                        self.advance();
                    }
                    continue :outer;
                }
            }
            break;
        }
    }

    fn scanString(self: *Lexer, loc: Loc) !Token {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.alloc);
        while (self.peek()) |c| {
            // stop at newline without consuming it
            if (c == '\n') break;
            if (c == '"') {
                self.advance();
                break;
            }
            if (c == '\\') {
                self.advance();
                if (self.peek()) |esc| {
                    self.advance();
                    switch (esc) {
                        'n' => try buf.append(self.alloc, '\n'),
                        't' => try buf.append(self.alloc, '\t'),
                        'r' => try buf.append(self.alloc, '\r'),
                        '\\' => try buf.append(self.alloc, '\\'),
                        '"' => try buf.append(self.alloc, '"'),
                        'b' => try buf.append(self.alloc, 8),
                        'f' => try buf.append(self.alloc, 12),
                        'v' => try buf.append(self.alloc, 11),
                        '0'...'7' => {
                            var oct: [3]u8 = undefined;
                            oct[0] = esc;
                            var len: usize = 1;
                            while (len < 3) {
                                if (self.peek()) |oc| {
                                    if (oc >= '0' and oc <= '7') {
                                        oct[len] = oc;
                                        len += 1;
                                        self.advance();
                                    } else break;
                                } else break;
                            }
                            const val = std.fmt.parseInt(u8, oct[0..len], 8) catch 0;
                            try buf.append(self.alloc, val);
                        },
                        else => try buf.append(self.alloc, esc),
                    }
                }
            } else {
                self.advance();
                try buf.append(self.alloc, c);
            }
        }
        const slice = try buf.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(slice);
        try self.owned.append(self.alloc, slice);
        return .{ .type = .string, .loc = loc, .text = slice };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.pos >= self.src.len) {
            return .{ .type = .eof, .loc = .{ .line = self.line, .col = self.col } };
        }

        const loc = Loc{ .line = self.line, .col = self.col };
        const c = self.src[self.pos];
        self.advance();

        const tt: TokenType = switch (c) {
            '{' => .obrace,
            '}' => .cbrace,
            '(' => .oparen,
            ')' => .cparen,
            '[' => .obracket,
            ']' => .cbracket,
            '.' => .dot,
            ',' => .comma,
            ';' => .semi,
            '=' => .equals,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '!' => .bang,
            '~' => .invert,
            '0'...'9' => {
                const start = self.pos - 1;
                if (c == '0' and self.pos < self.src.len and
                    (self.src[self.pos] == 'x' or self.src[self.pos] == 'X'))
                {
                    self.advance(); // consume 'x'
                    const hex_start = self.pos;
                    while (self.peek()) |nc| {
                        if (std.ascii.isHex(nc)) self.advance() else break;
                    }
                    // no hex digits after 0x yields .err
                    if (hex_start == self.pos) return .{ .type = .err, .loc = loc };
                    const val = std.fmt.parseInt(i64, self.src[hex_start..self.pos], 16) catch
                        return .{ .type = .err, .loc = loc };
                    return .{ .type = .integer, .loc = loc, .int_val = val };
                }
                while (self.peek()) |nc| {
                    if (std.ascii.isDigit(nc)) self.advance() else break;
                }
                if (self.pos < self.src.len and self.src[self.pos] == '.' and
                    self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))
                {
                    self.advance(); // consume '.'
                    while (self.peek()) |nc| {
                        if (std.ascii.isDigit(nc)) self.advance() else break;
                    }
                    const val = std.fmt.parseFloat(f64, self.src[start..self.pos]) catch 0.0;
                    return .{ .type = .float, .loc = loc, .float_val = val };
                }
                // decimal overflow yields .err
                const val = std.fmt.parseInt(i64, self.src[start..self.pos], 10) catch
                    return .{ .type = .err, .loc = loc };
                return .{ .type = .integer, .loc = loc, .int_val = val };
            },
            'A'...'Z', 'a'...'z', '_' => {
                const start = self.pos - 1;
                while (self.peek()) |nc| {
                    switch (nc) {
                        'A'...'Z', 'a'...'z', '0'...'9', '_' => self.advance(),
                        else => break,
                    }
                }
                const text = self.src[start..self.pos];
                var buf: [64]u8 = undefined;
                if (text.len <= buf.len) {
                    for (text, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
                    if (keywords.get(buf[0..text.len])) |kw| {
                        return .{ .type = kw, .loc = loc, .text = text };
                    }
                }
                return .{ .type = .ident, .loc = loc, .text = text };
            },
            '"' => return self.scanString(loc) catch .{ .type = .eof, .loc = loc },
            '<' => {
                const start = self.pos;
                // stop at any non-graphic char (<=space) or '>'
                while (self.peek()) |nc| {
                    if (nc == '>' or nc <= ' ') break;
                    self.advance();
                }
                const text = self.src[start..self.pos];
                if (self.peek() == '>') self.advance();
                return .{ .type = .keyname, .loc = loc, .text = text };
            },
            // unrecognized char returns .err
            else => return .{ .type = .err, .loc = loc },
        };

        return .{ .type = tt, .loc = loc };
    }
};

test "identifiers and keywords case-insensitive" {
    var lx = Lexer.init(std.testing.allocator, "key KEY Key xkb_symbols myVar_1 mod_map");
    defer lx.deinit();
    try std.testing.expectEqual(TokenType.kw_key, lx.next().type);
    try std.testing.expectEqual(TokenType.kw_key, lx.next().type);
    try std.testing.expectEqual(TokenType.kw_key, lx.next().type);
    try std.testing.expectEqual(TokenType.kw_symbols, lx.next().type);
    const id = lx.next();
    try std.testing.expectEqual(TokenType.ident, id.type);
    try std.testing.expectEqualStrings("myVar_1", id.text);
    try std.testing.expectEqual(TokenType.kw_modifier_map, lx.next().type);
}

test "string with escapes" {
    var lx = Lexer.init(std.testing.allocator, "\"ab\\ncd\" \"x\\\"y\"");
    defer lx.deinit();
    const s = lx.next();
    try std.testing.expectEqual(TokenType.string, s.type);
    try std.testing.expectEqualStrings("ab\ncd", s.text);
    const s2 = lx.next();
    try std.testing.expectEqualStrings("x\"y", s2.text);
}

test "numbers" {
    var lx = Lexer.init(std.testing.allocator, "10 0x1f 3.14 0");
    defer lx.deinit();
    const a = lx.next();
    try std.testing.expectEqual(TokenType.integer, a.type);
    try std.testing.expectEqual(@as(i64, 10), a.int_val);
    const b = lx.next();
    try std.testing.expectEqual(TokenType.integer, b.type);
    try std.testing.expectEqual(@as(i64, 0x1f), b.int_val);
    const c = lx.next();
    try std.testing.expectEqual(TokenType.float, c.type);
    try std.testing.expect(@abs(c.float_val - 3.14) < 0.001);
    const d = lx.next();
    try std.testing.expectEqual(@as(i64, 0), d.int_val);
}

test "number boundaries: trailing dot and field access not float" {
    // "1." -> integer 1, then dot token
    var lx1 = Lexer.init(std.testing.allocator, "1.");
    defer lx1.deinit();
    const t1 = lx1.next();
    try std.testing.expectEqual(TokenType.integer, t1.type);
    try std.testing.expectEqual(@as(i64, 1), t1.int_val);
    try std.testing.expectEqual(TokenType.dot, lx1.next().type);

    // "foo.bar" -> ident dot ident
    var lx2 = Lexer.init(std.testing.allocator, "foo.bar");
    defer lx2.deinit();
    const id1 = lx2.next();
    try std.testing.expectEqual(TokenType.ident, id1.type);
    try std.testing.expectEqualStrings("foo", id1.text);
    try std.testing.expectEqual(TokenType.dot, lx2.next().type);
    const id2 = lx2.next();
    try std.testing.expectEqual(TokenType.ident, id2.type);
    try std.testing.expectEqualStrings("bar", id2.text);
}

test "punctuation and eof with locations" {
    var lx = Lexer.init(std.testing.allocator, "{ }\n;=");
    defer lx.deinit();
    const t0 = lx.next();
    try std.testing.expectEqual(TokenType.obrace, t0.type);
    try std.testing.expectEqual(@as(u32, 1), t0.loc.line);
    try std.testing.expectEqual(@as(u32, 1), t0.loc.col);
    try std.testing.expectEqual(TokenType.cbrace, lx.next().type);
    const semi = lx.next();
    try std.testing.expectEqual(TokenType.semi, semi.type);
    try std.testing.expectEqual(@as(u32, 2), semi.loc.line);
    try std.testing.expectEqual(TokenType.equals, lx.next().type);
    try std.testing.expectEqual(TokenType.eof, lx.next().type);
    try std.testing.expectEqual(TokenType.eof, lx.next().type);
}

test "key names" {
    var lx = Lexer.init(std.testing.allocator, "<AE01> <TLDE> key <LatQ>");
    defer lx.deinit();
    const a = lx.next();
    try std.testing.expectEqual(TokenType.keyname, a.type);
    try std.testing.expectEqualStrings("AE01", a.text);
    try std.testing.expectEqualStrings("TLDE", lx.next().text);
    try std.testing.expectEqual(TokenType.kw_key, lx.next().type);
    try std.testing.expectEqualStrings("LatQ", lx.next().text);
}

test "key name empty and unterminated" {
    var lx = Lexer.init(std.testing.allocator, "<> <oops");
    defer lx.deinit();
    const empty = lx.next();
    try std.testing.expectEqual(TokenType.keyname, empty.type);
    try std.testing.expectEqualStrings("", empty.text);
    const unt = lx.next();
    try std.testing.expectEqual(TokenType.keyname, unt.type);
    try std.testing.expectEqualStrings("oops", unt.text);
}

test "comments skipped" {
    var lx = Lexer.init(std.testing.allocator, "key // line comment\n <AE01> /* block\n comment */ = # hash\n 5");
    defer lx.deinit();
    try std.testing.expectEqual(TokenType.kw_key, lx.next().type);
    const kn = lx.next();
    try std.testing.expectEqual(TokenType.keyname, kn.type);
    try std.testing.expectEqual(@as(u32, 2), kn.loc.line);
    try std.testing.expectEqual(TokenType.equals, lx.next().type);
    const five = lx.next();
    try std.testing.expectEqual(@as(i64, 5), five.int_val);
    try std.testing.expectEqual(@as(u32, 4), five.loc.line);
}

test "tokenize a symbols snippet" {
    const src =
        \\xkb_symbols "basic" {
        \\    key <AE01> { [ 1, exclam ] };
        \\};
    ;
    var lx = Lexer.init(std.testing.allocator, src);
    defer lx.deinit();
    const expect = [_]TokenType{
        .kw_symbols, .string,   .obrace,
        .kw_key,     .keyname,  .obrace,
        .obracket,   .integer,  .comma,
        .ident,      .cbracket, .cbrace,
        .semi,       .cbrace,   .semi,
        .eof,
    };
    for (expect) |et| try std.testing.expectEqual(et, lx.next().type);
}

test "tokenize keycodes + lone slash" {
    var lx = Lexer.init(std.testing.allocator, "xkb_keycodes \"k\" { <TLDE> = 49; }; a / b // c");
    defer lx.deinit();
    const expect = [_]TokenType{ .kw_keycodes, .string, .obrace, .keyname, .equals, .integer, .semi, .cbrace, .semi, .ident, .slash, .ident, .eof };
    for (expect) |et| try std.testing.expectEqual(et, lx.next().type);
}

test "fix1: unknown chars yield .err tokens, no stack overflow" {
    // 5000 '@' chars must each lex as .err without recursing (stack safe)
    const src: [5000]u8 = @splat('@');
    var lx = Lexer.init(std.testing.allocator, &src);
    defer lx.deinit();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const t = lx.next();
        try std.testing.expectEqual(TokenType.err, t.type);
    }
    try std.testing.expectEqual(TokenType.eof, lx.next().type);
}

test "fix2: unterminated string stops at newline, rest lexes normally" {
    // Opening quote, content, then newline (no closing quote on that line)
    const src = "\"unterminated\n key <AE01>";
    var lx = Lexer.init(std.testing.allocator, src);
    defer lx.deinit();
    const s = lx.next();
    try std.testing.expectEqual(TokenType.string, s.type);
    try std.testing.expectEqualStrings("unterminated", s.text);
    // newline is left unconsumed; whitespace skip eats it; next real tokens follow
    try std.testing.expectEqual(TokenType.kw_key, lx.next().type);
    const kn = lx.next();
    try std.testing.expectEqual(TokenType.keyname, kn.type);
    try std.testing.expectEqualStrings("AE01", kn.text);
}

test "fix3: keyword table additions and doodad is ident" {
    var lx = Lexer.init(std.testing.allocator, "action modmap xkb_layout doodad");
    defer lx.deinit();
    try std.testing.expectEqual(TokenType.kw_action, lx.next().type);
    try std.testing.expectEqual(TokenType.kw_modifier_map, lx.next().type);
    try std.testing.expectEqual(TokenType.kw_layout, lx.next().type);
    const dd = lx.next();
    try std.testing.expectEqual(TokenType.ident, dd.type);
    try std.testing.expectEqualStrings("doodad", dd.text);
}

test "fix4: keyname stops at non-graphic char (space)" {
    // <AE 01> should yield keyname "AE", space halts it before >
    var lx = Lexer.init(std.testing.allocator, "<AE 01>");
    defer lx.deinit();
    const kn = lx.next();
    try std.testing.expectEqual(TokenType.keyname, kn.type);
    try std.testing.expectEqualStrings("AE", kn.text);
}

test "fix5: malformed hex yields .err, valid large keysym stays .integer" {
    // "0x" with no hex digits -> .err
    var lx1 = Lexer.init(std.testing.allocator, "0x");
    defer lx1.deinit();
    try std.testing.expectEqual(TokenType.err, lx1.next().type);
    try std.testing.expectEqual(TokenType.eof, lx1.next().type);

    // valid large keysym like 0x1008FF12 (fits i64) -> .integer
    var lx2 = Lexer.init(std.testing.allocator, "0x1008FF12");
    defer lx2.deinit();
    const t = lx2.next();
    try std.testing.expectEqual(TokenType.integer, t.type);
    try std.testing.expectEqual(@as(i64, 0x1008FF12), t.int_val);
}

test "keyword tokens carry source text" {
    var lx = Lexer.init(std.testing.allocator, "key type action group indicator");
    defer lx.deinit();
    const k = lx.next();
    try std.testing.expectEqual(TokenType.kw_key, k.type);
    try std.testing.expectEqualStrings("key", k.text);
    const ty = lx.next();
    try std.testing.expectEqual(TokenType.kw_type, ty.type);
    try std.testing.expectEqualStrings("type", ty.text);
    const ac = lx.next();
    try std.testing.expectEqual(TokenType.kw_action, ac.type);
    try std.testing.expectEqualStrings("action", ac.text);
    const gr = lx.next();
    try std.testing.expectEqual(TokenType.kw_group, gr.type);
    try std.testing.expectEqualStrings("group", gr.text);
    const ind = lx.next();
    try std.testing.expectEqual(TokenType.kw_indicator, ind.type);
    try std.testing.expectEqualStrings("indicator", ind.text);
}
