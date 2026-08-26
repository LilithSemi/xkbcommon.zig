const std = @import("std");
const lx = @import("lexer.zig");
const ast = @import("ast.zig");

pub const Lexer = lx.Lexer;
pub const Token = lx.Token;
pub const TokenType = lx.TokenType;
pub const Loc = lx.Loc;
pub const Expr = ast.Expr;
pub const Op = ast.Op;
pub const XkbFile = ast.XkbFile;
pub const Component = ast.Component;
pub const Flags = ast.Flags;
pub const Decl = ast.Decl;

pub const ParseError = error{ParseError};

pub const Parser = struct {
    arena: std.heap.ArenaAllocator,
    lexer: *Lexer,
    tok: Token,
    ahead: ?Token = null,
    err_msg: ?[]const u8 = null,
    err_loc: Loc = .{ .line = 0, .col = 0 },
    depth: usize = 0,

    pub fn init(alloc: std.mem.Allocator, lexer: *Lexer) Parser {
        const arena = std.heap.ArenaAllocator.init(alloc);
        return .{
            .arena = arena,
            .lexer = lexer,
            .tok = lexer.next(),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    fn a(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn advance(self: *Parser) void {
        if (self.ahead) |next| {
            self.tok = next;
            self.ahead = null;
        } else {
            self.tok = self.lexer.next();
        }
    }

    fn peek(self: *Parser) Token {
        if (self.ahead == null) {
            self.ahead = self.lexer.next();
        }
        return self.ahead.?;
    }

    fn accept(self: *Parser, t: TokenType) ?Token {
        if (self.tok.type == t) {
            const old = self.tok;
            self.advance();
            return old;
        }
        return null;
    }

    fn expect(self: *Parser, t: TokenType) ParseError!Token {
        if (self.tok.type == t) {
            const old = self.tok;
            self.advance();
            return old;
        }
        return self.fail("expected {s}, got {s}", .{ @tagName(t), @tagName(self.tok.type) });
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) ParseError {
        self.err_msg = std.fmt.allocPrint(self.a(), fmt, args) catch null;
        self.err_loc = self.tok.loc;
        return error.ParseError;
    }

    pub fn parseExpr(self: *Parser) error{ ParseError, OutOfMemory }!*Expr {
        self.depth += 1;
        defer self.depth -= 1;
        // 256 levels is far beyond any real XKB expression; catches runaway input before stack overflow.
        if (self.depth > 256) return self.fail("expression nesting too deep", .{});
        return self.parseAddSub();
    }

    fn parseAddSub(self: *Parser) error{ ParseError, OutOfMemory }!*Expr {
        var lhs = try self.parseMulDiv();
        while (true) {
            const op: Op = switch (self.tok.type) {
                .plus => .add,
                .minus => .sub,
                else => break,
            };
            self.advance();
            const rhs = try self.parseMulDiv();
            const p = try self.a().create(Expr);
            p.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } };
            lhs = p;
        }
        return lhs;
    }

    fn parseMulDiv(self: *Parser) error{ ParseError, OutOfMemory }!*Expr {
        var lhs = try self.parseUnary();
        while (true) {
            const op: Op = switch (self.tok.type) {
                .star => .mul,
                .slash => .div,
                else => break,
            };
            self.advance();
            const rhs = try self.parseUnary();
            const p = try self.a().create(Expr);
            p.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } };
            lhs = p;
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) error{ ParseError, OutOfMemory }!*Expr {
        switch (self.tok.type) {
            .minus => {
                self.advance();
                const rhs = try self.parseUnary();
                const p = try self.a().create(Expr);
                p.* = .{ .unary = .{ .op = .negate, .rhs = rhs } };
                return p;
            },
            .bang => {
                self.advance();
                const rhs = try self.parseUnary();
                const p = try self.a().create(Expr);
                p.* = .{ .unary = .{ .op = .not, .rhs = rhs } };
                return p;
            },
            .invert => {
                self.advance();
                const rhs = try self.parseUnary();
                const p = try self.a().create(Expr);
                p.* = .{ .unary = .{ .op = .invert, .rhs = rhs } };
                return p;
            },
            .plus => {
                self.advance();
                const rhs = try self.parseUnary();
                const p = try self.a().create(Expr);
                p.* = .{ .unary = .{ .op = .unary_plus, .rhs = rhs } };
                return p;
            },
            else => return self.parsePostfix(),
        }
    }

    fn parsePostfix(self: *Parser) error{ ParseError, OutOfMemory }!*Expr {
        var base = try self.parsePrimary();
        while (true) {
            if (self.tok.type == .obracket) {
                self.advance();
                const index: ?*Expr = if (self.tok.type == .cbracket) null else try self.parseExpr();
                _ = try self.expect(.cbracket);
                const p = try self.a().create(Expr);
                p.* = .{ .array_ref = .{ .base = base, .index = index } };
                base = p;
            } else if (self.tok.type == .dot) {
                self.advance();
                const field_tok = try self.expect(.ident);
                const p = try self.a().create(Expr);
                p.* = .{ .dot = .{ .lhs = base, .field = field_tok.text } };
                base = p;
            } else {
                break;
            }
        }
        return base;
    }

    /// Parse one element in a [...] sym list. Braces open a multi-sym sub-list.
    fn parseBracketElement(self: *Parser) error{ ParseError, OutOfMemory }!*Expr {
        if (self.tok.type == .obrace) {
            self.advance();
            var syms: std.ArrayList(Expr) = .empty;
            while (self.tok.type != .cbrace and self.tok.type != .eof) {
                const sym = try self.parseExpr();
                try syms.append(self.a(), sym.*);
                _ = self.accept(.comma);
            }
            _ = try self.expect(.cbrace);
            const p = try self.a().create(Expr);
            p.* = .{ .list = try syms.toOwnedSlice(self.a()) };
            return p;
        }
        return self.parseExpr();
    }

    fn parsePrimary(self: *Parser) error{ ParseError, OutOfMemory }!*Expr {
        switch (self.tok.type) {
            .integer => {
                const val = self.tok.int_val;
                self.advance();
                const p = try self.a().create(Expr);
                p.* = .{ .integer = val };
                return p;
            },
            .float => {
                const val = self.tok.float_val;
                self.advance();
                const p = try self.a().create(Expr);
                p.* = .{ .float = val };
                return p;
            },
            .string => {
                const text = self.tok.text;
                self.advance();
                const p = try self.a().create(Expr);
                p.* = .{ .string = text };
                return p;
            },
            .keyname => {
                const text = self.tok.text;
                self.advance();
                const p = try self.a().create(Expr);
                p.* = .{ .keyname = text };
                return p;
            },
            .oparen => {
                self.advance();
                const e = try self.parseExpr();
                _ = try self.expect(.cparen);
                return e;
            },
            .obracket => {
                self.advance();
                var items: std.ArrayList(Expr) = .empty;
                if (self.tok.type != .cbracket) {
                    const first = try self.parseBracketElement();
                    try items.append(self.a(), first.*);
                    while (self.accept(.comma) != null) {
                        if (self.tok.type == .cbracket) break;
                        const item = try self.parseBracketElement();
                        try items.append(self.a(), item.*);
                    }
                }
                _ = try self.expect(.cbracket);
                const p = try self.a().create(Expr);
                p.* = .{ .list = try items.toOwnedSlice(self.a()) };
                return p;
            },
            .ident => {
                const text = self.tok.text;
                self.advance();
                var buf: [8]u8 = undefined;
                if (text.len <= buf.len) {
                    for (text, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
                    const lower = buf[0..text.len];
                    if (std.mem.eql(u8, lower, "true") or std.mem.eql(u8, lower, "yes") or std.mem.eql(u8, lower, "on")) {
                        const p = try self.a().create(Expr);
                        p.* = .{ .boolean = true };
                        return p;
                    }
                    if (std.mem.eql(u8, lower, "false") or std.mem.eql(u8, lower, "no") or std.mem.eql(u8, lower, "off")) {
                        const p = try self.a().create(Expr);
                        p.* = .{ .boolean = false };
                        return p;
                    }
                }
                // Action call: ident immediately followed by '('
                if (self.tok.type == .oparen) {
                    self.advance();
                    var args: std.ArrayList(Expr) = .empty;
                    if (self.tok.type != .cparen) {
                        const first_arg = try self.parseArg();
                        try args.append(self.a(), first_arg.*);
                        while (self.accept(.comma) != null) {
                            if (self.tok.type == .cparen) break;
                            const arg = try self.parseArg();
                            try args.append(self.a(), arg.*);
                        }
                    }
                    _ = try self.expect(.cparen);
                    const p = try self.a().create(Expr);
                    p.* = .{ .action = .{ .name = text, .args = try args.toOwnedSlice(self.a()) } };
                    return p;
                }
                const p = try self.a().create(Expr);
                p.* = .{ .ident = text };
                return p;
            },
            else => {
                if (self.keywordAsText()) |name| {
                    self.advance();
                    const p = try self.a().create(Expr);
                    p.* = .{ .ident = name };
                    return p;
                }
                return self.fail("unexpected token {s} in expression", .{@tagName(self.tok.type)});
            },
        }
    }

    fn keywordAsText(self: *Parser) ?[]const u8 {
        return switch (self.tok.type) {
            .kw_key, .kw_interpret, .kw_type, .kw_action, .kw_group, .kw_indicator, .kw_section, .kw_row, .kw_overlay, .kw_outline, .kw_solid, .kw_text, .kw_shape, .kw_logo, .kw_keys, .kw_virtual, .kw_default, .kw_partial, .kw_hidden => self.tok.text,
            else => null,
        };
    }

    pub fn parseFile(self: *Parser) error{ ParseError, OutOfMemory }!*XkbFile {
        var components: std.ArrayList(ast.Component) = .empty;
        while (self.tok.type != .eof) {
            const comp = try self.parseComponent();
            try components.append(self.a(), comp);
        }
        const f = try self.a().create(ast.XkbFile);
        f.* = .{ .components = try components.toOwnedSlice(self.a()) };
        return f;
    }

    fn parseComponent(self: *Parser) error{ ParseError, OutOfMemory }!ast.Component {
        var flags: ast.Flags = .{};
        while (true) {
            switch (self.tok.type) {
                .kw_partial => {
                    flags.partial = true;
                    self.advance();
                },
                .kw_default => {
                    flags.default = true;
                    self.advance();
                },
                .kw_hidden => {
                    flags.hidden = true;
                    self.advance();
                },
                .kw_alphanumeric_keys => {
                    flags.alphanumeric_keys = true;
                    self.advance();
                },
                .kw_modifier_keys => {
                    flags.modifier_keys = true;
                    self.advance();
                },
                .kw_keypad_keys => {
                    flags.keypad_keys = true;
                    self.advance();
                },
                .kw_function_keys => {
                    flags.function_keys = true;
                    self.advance();
                },
                .kw_alternate_group => {
                    flags.alternate_group = true;
                    self.advance();
                },
                else => break,
            }
        }

        const kind: ast.Component.Kind = switch (self.tok.type) {
            .kw_keymap => .keymap,
            .kw_keycodes => .keycodes,
            .kw_types => .types,
            .kw_compat => .compat,
            .kw_symbols => .symbols,
            .kw_geometry => .geometry,
            else => return self.fail("expected section keyword, got {s}", .{@tagName(self.tok.type)}),
        };
        self.advance();

        const name: ?[]const u8 = if (self.tok.type == .string) blk: {
            const t = self.tok.text;
            self.advance();
            break :blk t;
        } else null;

        _ = try self.expect(.obrace);

        var children: std.ArrayList(ast.Component) = .empty;
        var decls: std.ArrayList(ast.Decl) = .empty;

        if (kind == .keymap) {
            while (self.tok.type != .cbrace) {
                if (self.tok.type == .eof) return self.fail("unexpected EOF in keymap body", .{});
                const child = try self.parseComponent();
                try children.append(self.a(), child);
            }
        } else {
            while (self.tok.type != .cbrace) {
                if (self.tok.type == .eof) return self.fail("unexpected EOF in section body", .{});
                const d = try self.parseDecl();
                try decls.append(self.a(), d);
            }
        }

        _ = try self.expect(.cbrace);
        _ = try self.expect(.semi);

        return .{
            .kind = kind,
            .flags = flags,
            .name = name,
            .decls = try decls.toOwnedSlice(self.a()),
            .children = try children.toOwnedSlice(self.a()),
        };
    }

    fn parseDeclStub(self: *Parser) error{ ParseError, OutOfMemory }!ast.Decl {
        return self.fail("unexpected token {s} cannot start a declaration", .{@tagName(self.tok.type)});
    }

    pub fn parseDecl(self: *Parser) error{ ParseError, OutOfMemory }!ast.Decl {
        var merge: ast.MergeMode = .default;
        switch (self.tok.type) {
            .kw_augment => {
                merge = .augment;
                self.advance();
            },
            .kw_override, .kw_alternate => {
                merge = .override;
                self.advance();
            },
            .kw_replace => {
                merge = .replace;
                self.advance();
            },
            else => {},
        }

        // A dot straight after the section keyword is the DEFAULT form:
        // `interpret.repeat = False;` sets the default for the interpret
        // declarations that follow, instead of opening a block. Every section
        // keyword takes it, and no block form has a dot in that position, so one
        // check here covers them all. xkbcomp emits these in the compat section
        // of an ordinary keymap, which is what made a real compositor keymap
        // fail to parse while the hand-written test maps passed.
        if (self.tok.type != .ident and self.peek().type == .dot) {
            const lhs = try self.parseExpr();
            const value: ?*ast.Expr = if (self.accept(.equals) != null) try self.parseExpr() else null;
            _ = try self.expect(.semi);
            return .{ .var_def = .{ .merge = merge, .name = lhs, .value = value } };
        }

        switch (self.tok.type) {
            .kw_include => {
                self.advance();
                const path_tok = try self.expect(.string);
                _ = try self.expect(.semi);
                return .{ .include = .{ .merge = merge, .path = path_tok.text } };
            },
            .keyname => {
                const kn_tok = self.tok;
                self.advance();
                _ = try self.expect(.equals);
                const value = try self.parseExpr();
                _ = try self.expect(.semi);
                return .{ .keycode = .{ .name = kn_tok.text, .value = value } };
            },
            .kw_alias => {
                self.advance();
                const alias_tok = try self.expect(.keyname);
                _ = try self.expect(.equals);
                const real_tok = try self.expect(.keyname);
                _ = try self.expect(.semi);
                return .{ .key_alias = .{ .alias = alias_tok.text, .real = real_tok.text } };
            },
            .kw_interpret => {
                self.advance();
                // The keysym is a name, or a number for the ones libxkbcommon has
                // no name for. The lexer reports `0xff7f` as an integer, which is
                // correct, so a number is spelled back out as the `0x<hex>` text
                // that `keysym.fromName` already reads. That keeps the AST one
                // shape and leaves the consumer unchanged.
                const sym_text = if (self.tok.type == .integer) blk: {
                    const v = self.tok.int_val;
                    self.advance();
                    break :blk try std.fmt.allocPrint(self.a(), "0x{x}", .{@as(u32, @truncate(@as(u64, @bitCast(v))))});
                } else (try self.expect(.ident)).text;
                const match: ?*ast.Expr = if (self.accept(.plus) != null) try self.parseExpr() else null;
                _ = try self.expect(.obrace);
                var body: std.ArrayList(ast.VarDef) = .empty;
                while (self.tok.type != .cbrace and self.tok.type != .eof) {
                    const vd = try self.parseVarDef();
                    try body.append(self.a(), vd);
                }
                _ = try self.expect(.cbrace);
                _ = try self.expect(.semi);
                return .{ .interp = .{ .merge = merge, .sym = sym_text, .match = match, .body = try body.toOwnedSlice(self.a()) } };
            },
            .kw_indicator => {
                self.advance();
                const ndx = try self.parseExpr();
                if (self.accept(.equals) != null) {
                    const name_expr = try self.parseExpr();
                    _ = try self.expect(.semi);
                    return .{ .indicator_name = .{ .ndx = ndx, .name = name_expr, .virtual = false } };
                }
                // indicator "name" { ... }; indicator_map form
                switch (ndx.*) {
                    .string => |map_name| {
                        if (self.tok.type == .obrace) {
                            self.advance();
                            var body: std.ArrayList(ast.VarDef) = .empty;
                            while (self.tok.type != .cbrace and self.tok.type != .eof) {
                                const vd = try self.parseVarDef();
                                try body.append(self.a(), vd);
                            }
                            _ = try self.expect(.cbrace);
                            _ = try self.expect(.semi);
                            return .{ .indicator_map = .{ .name = map_name, .body = try body.toOwnedSlice(self.a()) } };
                        }
                    },
                    else => {},
                }
                return self.parseDeclStub();
            },
            .kw_group => {
                self.advance();
                const group_expr = try self.parseExpr();
                _ = try self.expect(.equals);
                const value_expr = try self.parseExpr();
                _ = try self.expect(.semi);
                return .{ .group_compat = .{ .group = group_expr, .value = value_expr } };
            },
            .kw_virtual => {
                if (self.peek().type == .kw_indicator) {
                    self.advance();
                    self.advance();
                    const ndx = try self.parseExpr();
                    _ = try self.expect(.equals);
                    const name_expr = try self.parseExpr();
                    _ = try self.expect(.semi);
                    return .{ .indicator_name = .{ .ndx = ndx, .name = name_expr, .virtual = true } };
                }
                return self.parseDeclStub();
            },
            .kw_key => {
                if (self.peek().type == .keyname) {
                    self.advance();
                    const name_tok = try self.expect(.keyname);
                    _ = try self.expect(.obrace);
                    var body: std.ArrayList(ast.Expr) = .empty;
                    while (self.tok.type != .cbrace and self.tok.type != .eof) {
                        const lhs = try self.parseExpr();
                        if (self.accept(.equals) != null) {
                            const rhs = try self.parseExpr();
                            const assign_p = try self.a().create(ast.Expr);
                            assign_p.* = .{ .assign = .{ .lhs = lhs, .rhs = rhs } };
                            try body.append(self.a(), assign_p.*);
                        } else {
                            try body.append(self.a(), lhs.*);
                        }
                        _ = self.accept(.comma);
                    }
                    _ = try self.expect(.cbrace);
                    _ = try self.expect(.semi);
                    return .{ .key = .{ .merge = merge, .name = name_tok.text, .body = try body.toOwnedSlice(self.a()) } };
                }
                if (self.peek().type == .dot) {
                    const lhs = try self.parseExpr();
                    const value: ?*ast.Expr = if (self.accept(.equals) != null) try self.parseExpr() else null;
                    _ = try self.expect(.semi);
                    return .{ .var_def = .{ .merge = merge, .name = lhs, .value = value } };
                }
                return self.parseDeclStub();
            },
            .kw_modifier_map => {
                self.advance();
                const mod_tok = try self.expect(.ident);
                _ = try self.expect(.obrace);
                var keys: std.ArrayList(ast.Expr) = .empty;
                while (self.tok.type != .cbrace and self.tok.type != .eof) {
                    const key_expr = try self.parseExpr();
                    try keys.append(self.a(), key_expr.*);
                    _ = self.accept(.comma);
                }
                _ = try self.expect(.cbrace);
                _ = try self.expect(.semi);
                return .{ .mod_map = .{ .modifier = mod_tok.text, .keys = try keys.toOwnedSlice(self.a()) } };
            },
            .kw_virtual_modifiers => {
                self.advance();
                var names: std.ArrayList([]const u8) = .empty;
                var values: std.ArrayList(?*ast.Expr) = .empty;
                const first_tok = try self.expect(.ident);
                try names.append(self.a(), first_tok.text);
                if (self.accept(.equals) != null) {
                    const val = try self.parseExpr();
                    try values.append(self.a(), val);
                } else {
                    try values.append(self.a(), null);
                }
                while (self.accept(.comma) != null) {
                    const name_tok = try self.expect(.ident);
                    try names.append(self.a(), name_tok.text);
                    if (self.accept(.equals) != null) {
                        const val = try self.parseExpr();
                        try values.append(self.a(), val);
                    } else {
                        try values.append(self.a(), null);
                    }
                }
                _ = try self.expect(.semi);
                return .{ .vmods = .{ .names = try names.toOwnedSlice(self.a()), .values = try values.toOwnedSlice(self.a()) } };
            },
            .ident => {
                const lhs = try self.parseExpr();
                if (self.accept(.equals) != null) {
                    const value = try self.parseExpr();
                    _ = try self.expect(.semi);
                    return .{ .var_def = .{ .merge = merge, .name = lhs, .value = value } };
                } else if (self.tok.type == .obrace) {
                    self.advance();
                    var items: std.ArrayList(ast.Expr) = .empty;
                    while (self.tok.type != .cbrace and self.tok.type != .eof) {
                        const inner = try self.parseDecl();
                        switch (inner) {
                            .var_def => |vd| {
                                if (vd.value) |val| {
                                    const assign_p = try self.a().create(ast.Expr);
                                    assign_p.* = .{ .assign = .{ .lhs = vd.name, .rhs = val } };
                                    try items.append(self.a(), assign_p.*);
                                } else {
                                    try items.append(self.a(), vd.name.*);
                                }
                            },
                            else => {},
                        }
                    }
                    _ = try self.expect(.cbrace);
                    _ = try self.expect(.semi);
                    const list_p = try self.a().create(ast.Expr);
                    list_p.* = .{ .list = try items.toOwnedSlice(self.a()) };
                    return .{ .var_def = .{ .merge = merge, .name = lhs, .value = list_p } };
                } else {
                    _ = try self.expect(.semi);
                    return .{ .var_def = .{ .merge = merge, .name = lhs, .value = null } };
                }
            },
            .kw_type => {
                self.advance();
                const name_tok = try self.expect(.string);
                _ = try self.expect(.obrace);
                var body: std.ArrayList(ast.VarDef) = .empty;
                while (self.tok.type != .cbrace and self.tok.type != .eof) {
                    const vd = try self.parseVarDef();
                    try body.append(self.a(), vd);
                }
                _ = try self.expect(.cbrace);
                _ = try self.expect(.semi);
                return .{ .key_type = .{ .merge = merge, .name = name_tok.text, .body = try body.toOwnedSlice(self.a()) } };
            },
            .kw_shape => {
                self.advance();
                const name_tok = try self.expect(.string);
                _ = try self.expect(.obrace);
                var outlines: std.ArrayList(ast.Expr) = .empty;
                while (self.tok.type != .cbrace and self.tok.type != .eof) {
                    if (self.tok.type == .obrace) {
                        self.advance();
                        var items: std.ArrayList(ast.Expr) = .empty;
                        while (self.tok.type != .cbrace and self.tok.type != .eof) {
                            const item = try self.parseExpr();
                            try items.append(self.a(), item.*);
                            _ = self.accept(.comma);
                        }
                        _ = try self.expect(.cbrace);
                        const outline = try self.a().create(ast.Expr);
                        outline.* = .{ .list = try items.toOwnedSlice(self.a()) };
                        try outlines.append(self.a(), outline.*);
                    } else {
                        const lhs = try self.parseExpr();
                        if (self.accept(.equals) != null) {
                            const rhs = try self.parseExpr();
                            const assign_p = try self.a().create(ast.Expr);
                            assign_p.* = .{ .assign = .{ .lhs = lhs, .rhs = rhs } };
                            try outlines.append(self.a(), assign_p.*);
                        } else {
                            try outlines.append(self.a(), lhs.*);
                        }
                    }
                    _ = self.accept(.comma);
                }
                _ = try self.expect(.cbrace);
                _ = try self.expect(.semi);
                return .{ .shape = .{ .name = name_tok.text, .outlines = try outlines.toOwnedSlice(self.a()) } };
            },
            .kw_section => {
                self.advance();
                const name_tok = try self.expect(.string);
                _ = try self.expect(.obrace);
                var body: std.ArrayList(ast.Decl) = .empty;
                while (self.tok.type != .cbrace and self.tok.type != .eof) {
                    const d = try self.parseDecl();
                    try body.append(self.a(), d);
                }
                _ = try self.expect(.cbrace);
                _ = try self.expect(.semi);
                return .{ .geom_section = .{ .name = name_tok.text, .body = try body.toOwnedSlice(self.a()) } };
            },
            .kw_row => {
                self.advance();
                _ = try self.expect(.obrace);
                var body: std.ArrayList(ast.Decl) = .empty;
                while (self.tok.type != .cbrace and self.tok.type != .eof) {
                    const d = try self.parseDecl();
                    try body.append(self.a(), d);
                }
                _ = try self.expect(.cbrace);
                _ = try self.expect(.semi);
                return .{ .row = .{ .body = try body.toOwnedSlice(self.a()) } };
            },
            .kw_overlay => {
                self.advance();
                const name_tok = try self.expect(.string);
                _ = try self.expect(.obrace);
                var body: std.ArrayList(ast.VarDef) = .empty;
                while (self.tok.type != .cbrace and self.tok.type != .eof) {
                    const vd = try self.parseVarDef();
                    try body.append(self.a(), vd);
                }
                _ = try self.expect(.cbrace);
                _ = try self.expect(.semi);
                return .{ .overlay = .{ .name = name_tok.text, .body = try body.toOwnedSlice(self.a()) } };
            },
            .kw_keys => {
                self.advance();
                _ = try self.expect(.obrace);
                var body: std.ArrayList(ast.Expr) = .empty;
                while (self.tok.type != .cbrace and self.tok.type != .eof) {
                    if (self.tok.type == .obrace) {
                        self.advance();
                        var inner: std.ArrayList(ast.Expr) = .empty;
                        while (self.tok.type != .cbrace and self.tok.type != .eof) {
                            const lhs = try self.parseExpr();
                            if (self.accept(.equals) != null) {
                                const rhs = try self.parseExpr();
                                const assign_p = try self.a().create(ast.Expr);
                                assign_p.* = .{ .assign = .{ .lhs = lhs, .rhs = rhs } };
                                try inner.append(self.a(), assign_p.*);
                            } else {
                                try inner.append(self.a(), lhs.*);
                            }
                            _ = self.accept(.comma);
                        }
                        _ = try self.expect(.cbrace);
                        const list_p = try self.a().create(ast.Expr);
                        list_p.* = .{ .list = try inner.toOwnedSlice(self.a()) };
                        try body.append(self.a(), list_p.*);
                    } else {
                        const e = try self.parseExpr();
                        try body.append(self.a(), e.*);
                    }
                    _ = self.accept(.comma);
                }
                _ = try self.expect(.cbrace);
                _ = try self.expect(.semi);
                return .{ .keys = .{ .body = try body.toOwnedSlice(self.a()) } };
            },
            .kw_solid, .kw_text, .kw_outline, .kw_logo => {
                const kind: ast.DoodadKind = switch (self.tok.type) {
                    .kw_solid => .solid,
                    .kw_text => .text,
                    .kw_outline => .outline,
                    .kw_logo => .logo,
                    else => unreachable,
                };
                self.advance();
                const name_tok = try self.expect(.string);
                _ = try self.expect(.obrace);
                var body: std.ArrayList(ast.VarDef) = .empty;
                while (self.tok.type != .cbrace and self.tok.type != .eof) {
                    const vd = try self.parseVarDef();
                    try body.append(self.a(), vd);
                }
                _ = try self.expect(.cbrace);
                _ = try self.expect(.semi);
                return .{ .doodad = .{ .kind = kind, .name = name_tok.text, .body = try body.toOwnedSlice(self.a()) } };
            },
            else => return self.fail("unexpected token {s} cannot start a declaration", .{@tagName(self.tok.type)}),
        }
    }

    fn parseVarDef(self: *Parser) error{ ParseError, OutOfMemory }!ast.VarDef {
        const lhs = try self.parseExpr();
        const value: ?*ast.Expr = if (self.accept(.equals) != null) try self.parseExpr() else null;
        _ = try self.expect(.semi);
        return .{ .merge = .default, .name = lhs, .value = value };
    }

    fn parseArg(self: *Parser) error{ ParseError, OutOfMemory }!*Expr {
        // !ident is a negated boolean flag arg
        if (self.tok.type == .bang) {
            self.advance();
            const name_tok = try self.expect(.ident);
            const val = try self.a().create(Expr);
            val.* = .{ .boolean = false };
            const p = try self.a().create(Expr);
            p.* = .{ .arg = .{ .name = name_tok.text, .value = val } };
            return p;
        }
        // ident[index] = expr is an indexed named arg, which `Private` uses to
        // fill its payload one byte at a time: `Private(type=0x86,data[0]=0x50)`.
        // The index is parsed and dropped, because the only consumer of a
        // private action zeroes its data and keeps the name (see action.zig).
        // Refusing the syntax outright made every real keymap fail to parse.
        if (self.tok.type == .ident and self.peek().type == .obracket) {
            const name_text = self.tok.text;
            self.advance();
            _ = try self.expect(.obracket);
            _ = try self.parseExpr();
            _ = try self.expect(.cbracket);
            _ = try self.expect(.equals);
            const val = try self.parseExpr();
            const p = try self.a().create(Expr);
            p.* = .{ .arg = .{ .name = name_text, .value = val } };
            return p;
        }
        // ident = expr is a named arg
        if (self.tok.type == .ident) {
            const name_text = self.tok.text;
            const ahead_tok = self.peek();
            if (ahead_tok.type == .equals) {
                self.advance(); // consume ident (tok becomes '=')
                self.advance(); // consume '=' (tok becomes next)
                const val = try self.parseExpr();
                const p = try self.a().create(Expr);
                p.* = .{ .arg = .{ .name = name_text, .value = val } };
                return p;
            }
        }
        // keyword in named-arg position, e.g. group=2
        if (self.keywordAsText()) |kw_name| {
            const ahead_tok = self.peek();
            if (ahead_tok.type == .equals) {
                self.advance(); // consume keyword token
                self.advance(); // consume '='
                const val = try self.parseExpr();
                const p = try self.a().create(Expr);
                p.* = .{ .arg = .{ .name = kw_name, .value = val } };
                return p;
            }
        }
        // bare positional arg
        const val = try self.parseExpr();
        const p = try self.a().create(Expr);
        p.* = .{ .arg = .{ .name = null, .value = val } };
        return p;
    }
};

test "parser skeleton: accept/expect/advance/deinit" {
    var lexer = Lexer.init(std.testing.allocator, "= ;");
    defer lexer.deinit();

    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    try std.testing.expectEqual(TokenType.equals, p.tok.type);

    const eq_tok = p.accept(.equals);
    try std.testing.expect(eq_tok != null);
    try std.testing.expectEqual(TokenType.semi, p.tok.type);

    const result = p.expect(.integer);
    try std.testing.expectError(error.ParseError, result);
}

test "parser peek does not consume" {
    var lexer = Lexer.init(std.testing.allocator, "= ;");
    defer lexer.deinit();

    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    try std.testing.expectEqual(TokenType.equals, p.tok.type);
    const ahead = p.peek();
    try std.testing.expectEqual(TokenType.semi, ahead.type);
    try std.testing.expectEqual(TokenType.equals, p.tok.type);
}

test "parseExpr: binary precedence 1 + 2 * 3" {
    var lexer = Lexer.init(std.testing.allocator, "1 + 2 * 3");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const e = try p.parseExpr();
    try std.testing.expectEqual(Op.add, e.binary.op);
    try std.testing.expectEqual(@as(i64, 1), e.binary.lhs.integer);
    try std.testing.expectEqual(Op.mul, e.binary.rhs.binary.op);
    try std.testing.expectEqual(@as(i64, 2), e.binary.rhs.binary.lhs.integer);
    try std.testing.expectEqual(@as(i64, 3), e.binary.rhs.binary.rhs.integer);
}

test "parseExpr: unary negate" {
    var lexer = Lexer.init(std.testing.allocator, "- 5");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const e = try p.parseExpr();
    try std.testing.expectEqual(Op.negate, e.unary.op);
    try std.testing.expectEqual(@as(i64, 5), e.unary.rhs.integer);
}

test "parseExpr: bare ident" {
    var lexer = Lexer.init(std.testing.allocator, "Shift");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const e = try p.parseExpr();
    try std.testing.expectEqualStrings("Shift", e.ident);
}

test "parseExpr: keyname" {
    var lexer = Lexer.init(std.testing.allocator, "<AE01>");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const e = try p.parseExpr();
    try std.testing.expectEqualStrings("AE01", e.keyname);
}

test "parseExpr: action call SetMods with named and positional args" {
    var lexer = Lexer.init(std.testing.allocator, "SetMods(mods=Shift,clearLocks)");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const e = try p.parseExpr();
    try std.testing.expectEqualStrings("SetMods", e.action.name);
    try std.testing.expectEqual(@as(usize, 2), e.action.args.len);
    // first arg: named mods=Shift
    const a0 = e.action.args[0].arg;
    try std.testing.expectEqualStrings("mods", a0.name.?);
    try std.testing.expectEqualStrings("Shift", a0.value.ident);
    // second arg: positional clearLocks
    const a1 = e.action.args[1].arg;
    try std.testing.expect(a1.name == null);
    try std.testing.expectEqualStrings("clearLocks", a1.value.ident);
}

test "parseExpr: list of 3 idents" {
    var lexer = Lexer.init(std.testing.allocator, "[ a, b, c ]");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const e = try p.parseExpr();
    try std.testing.expectEqual(@as(usize, 3), e.list.len);
    try std.testing.expectEqualStrings("a", e.list[0].ident);
    try std.testing.expectEqualStrings("b", e.list[1].ident);
    try std.testing.expectEqualStrings("c", e.list[2].ident);
}

test "parseExpr: array_ref foo[Group1]" {
    var lexer = Lexer.init(std.testing.allocator, "foo[Group1]");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const e = try p.parseExpr();
    try std.testing.expectEqualStrings("foo", e.array_ref.base.ident);
    try std.testing.expectEqualStrings("Group1", e.array_ref.index.?.ident);
}

test "parseExpr: dot a.b" {
    var lexer = Lexer.init(std.testing.allocator, "a.b");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const e = try p.parseExpr();
    try std.testing.expectEqualStrings("a", e.dot.lhs.ident);
    try std.testing.expectEqualStrings("b", e.dot.field);
}

test "parseFile: single symbols component" {
    var lexer = Lexer.init(std.testing.allocator, "xkb_symbols \"basic\" { };");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const f = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), f.components.len);
    const comp = f.components[0];
    try std.testing.expectEqual(ast.Component.Kind.symbols, comp.kind);
    try std.testing.expectEqualStrings("basic", comp.name.?);
    try std.testing.expectEqual(@as(usize, 0), comp.decls.len);
}

test "parseFile: partial default flags" {
    var lexer = Lexer.init(std.testing.allocator, "partial default xkb_symbols \"x\" { };");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const f = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), f.components.len);
    const comp = f.components[0];
    try std.testing.expect(comp.flags.partial);
    try std.testing.expect(comp.flags.default);
    try std.testing.expect(!comp.flags.hidden);
}

test "parseFile: keymap wrapper with children" {
    var lexer = Lexer.init(std.testing.allocator, "xkb_keymap { xkb_keycodes \"k\" {}; xkb_symbols \"s\" {}; };");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const f = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), f.components.len);
    const km = f.components[0];
    try std.testing.expectEqual(ast.Component.Kind.keymap, km.kind);
    try std.testing.expectEqual(@as(usize, 2), km.children.len);
    try std.testing.expectEqual(ast.Component.Kind.keycodes, km.children[0].kind);
    try std.testing.expectEqual(ast.Component.Kind.symbols, km.children[1].kind);
}

test "parseDecl: include stmt path and default merge" {
    const src = "xkb_symbols \"t\" { include \"us(basic)\"; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), f.components[0].decls.len);
    const d = f.components[0].decls[0];
    try std.testing.expectEqualStrings("us(basic)", d.include.path);
    try std.testing.expectEqual(ast.MergeMode.default, d.include.merge);
}

test "parseDecl: var_def key.repeat = true" {
    const src = "xkb_symbols \"t\" { key.repeat = true; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), f.components[0].decls.len);
    const vd = f.components[0].decls[0].var_def;
    try std.testing.expectEqual(ast.MergeMode.default, vd.merge);
    try std.testing.expectEqualStrings("key", vd.name.dot.lhs.ident);
    try std.testing.expectEqualStrings("repeat", vd.name.dot.field);
    try std.testing.expect(vd.value.?.boolean == true);
}

test "parseDecl: merge prefix augment on var_def" {
    const src = "xkb_symbols \"t\" { augment foo = 1; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), f.components[0].decls.len);
    const vd = f.components[0].decls[0].var_def;
    try std.testing.expectEqual(ast.MergeMode.augment, vd.merge);
    try std.testing.expectEqualStrings("foo", vd.name.ident);
    try std.testing.expectEqual(@as(i64, 1), vd.value.?.integer);
}

test "parseDecl: keycodes section keycode defs alias and indicator" {
    const src = "xkb_keycodes \"k\" { <TLDE> = 49; <AE01> = 10; alias <CAPS> = <CAPL>; indicator 1 = \"Caps Lock\"; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 4), decls.len);

    const d0 = decls[0].keycode;
    try std.testing.expectEqualStrings("TLDE", d0.name);
    try std.testing.expectEqual(@as(i64, 49), d0.value.integer);

    const d1 = decls[1].keycode;
    try std.testing.expectEqualStrings("AE01", d1.name);
    try std.testing.expectEqual(@as(i64, 10), d1.value.integer);

    const d2 = decls[2].key_alias;
    try std.testing.expectEqualStrings("CAPS", d2.alias);
    try std.testing.expectEqualStrings("CAPL", d2.real);

    const d3 = decls[3].indicator_name;
    try std.testing.expectEqual(@as(i64, 1), d3.ndx.integer);
    try std.testing.expectEqualStrings("Caps Lock", d3.name.string);
    try std.testing.expect(!d3.virtual);
}

test "parseDecl: key_type TWO with body vardefs" {
    const src = "xkb_types \"t\" { type \"TWO\" { modifiers = Shift; map[Shift] = Level2; level_name[Level1] = \"Base\"; }; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    const kt = decls[0].key_type;
    try std.testing.expectEqualStrings("TWO", kt.name);
    try std.testing.expectEqual(@as(usize, 3), kt.body.len);
    // body[0] modifiers is a plain ident
    try std.testing.expectEqualStrings("modifiers", kt.body[0].name.ident);
    // body[1] map[Shift] is an array_ref: base ident "map", index ident "Shift"
    const b1 = kt.body[1].name;
    try std.testing.expectEqualStrings("map", b1.array_ref.base.ident);
    try std.testing.expectEqualStrings("Shift", b1.array_ref.index.?.ident);
}

test "parseDecl: virtual indicator name" {
    const src = "xkb_keycodes \"k\" { virtual indicator 2 = \"x\"; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);

    const d = decls[0].indicator_name;
    try std.testing.expectEqual(@as(i64, 2), d.ndx.integer);
    try std.testing.expectEqualStrings("x", d.name.string);
    try std.testing.expect(d.virtual);
}

test "parseDecl: compat section interp indicator_map group_compat" {
    const src =
        \\xkb_compat "c" {
        \\  interpret Num_Lock+AnyOf(all) { action = LockMods(modifiers=NumLock); };
        \\  indicator "Caps Lock" { modifiers = Lock; };
        \\  group 2 = AltGr;
        \\};
    ;
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 3), decls.len);

    const interp = decls[0].interp;
    try std.testing.expectEqualStrings("Num_Lock", interp.sym);
    try std.testing.expect(interp.match != null);
    try std.testing.expect(interp.body.len >= 1);

    const imap = decls[1].indicator_map;
    try std.testing.expectEqualStrings("Caps Lock", imap.name);
    try std.testing.expect(imap.body.len >= 1);

    const gc = decls[2].group_compat;
    try std.testing.expectEqual(@as(i64, 2), gc.group.integer);
    try std.testing.expectEqualStrings("AltGr", gc.value.ident);
}

test "parseDecl: KeyDef bare list body" {
    const src = "xkb_symbols \"s\" { key <AE01> { [ 1, exclam ] }; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    const kd = decls[0].key;
    try std.testing.expectEqualStrings("AE01", kd.name);
    try std.testing.expectEqual(@as(usize, 1), kd.body.len);
    try std.testing.expectEqual(@as(usize, 2), kd.body[0].list.len);
}

test "parseDecl: KeyDef mixed arg and list body" {
    const src = "xkb_symbols \"s\" { key <AD01> { type=\"FOUR\", [q,Q], [a,A] }; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    const kd = decls[0].key;
    try std.testing.expectEqualStrings("AD01", kd.name);
    try std.testing.expectEqual(@as(usize, 3), kd.body.len);
    // body[0] is .assign with lhs ident "type" and rhs string "FOUR"
    try std.testing.expectEqualStrings("type", kd.body[0].assign.lhs.ident);
    try std.testing.expectEqualStrings("FOUR", kd.body[0].assign.rhs.string);
    // body[1] and body[2] are lists
    try std.testing.expectEqual(@as(usize, 2), kd.body[1].list.len);
    try std.testing.expectEqual(@as(usize, 2), kd.body[2].list.len);
}

test "parseDecl: ModMapDef" {
    const src = "xkb_symbols \"s\" { modifier_map Shift { <LFSH>, <RTSH> }; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    const mm = decls[0].mod_map;
    try std.testing.expectEqualStrings("Shift", mm.modifier);
    try std.testing.expectEqual(@as(usize, 2), mm.keys.len);
    try std.testing.expectEqualStrings("LFSH", mm.keys[0].keyname);
    try std.testing.expectEqualStrings("RTSH", mm.keys[1].keyname);
}

test "parseDecl: VModDef no values" {
    const src = "xkb_symbols \"s\" { virtual_modifiers NumLock, LevelThree; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    const vm = decls[0].vmods;
    try std.testing.expectEqual(@as(usize, 2), vm.names.len);
    try std.testing.expectEqualStrings("NumLock", vm.names[0]);
    try std.testing.expectEqualStrings("LevelThree", vm.names[1]);
    try std.testing.expect(vm.values[0] == null);
    try std.testing.expect(vm.values[1] == null);
}

test "parseDecl: KeyDef array_ref assign group index preserved" {
    const src = "xkb_symbols \"s\" { key <AD01> { symbols[Group1] = [ a, A ], actions[Group1] = [ NoAction() ] }; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    const kd = decls[0].key;
    try std.testing.expectEqualStrings("AD01", kd.name);
    try std.testing.expectEqual(@as(usize, 2), kd.body.len);
    // body[0]: symbols[Group1] = [a, A] -> assign, lhs is array_ref preserving group index
    const b0 = kd.body[0].assign;
    try std.testing.expectEqualStrings("symbols", b0.lhs.array_ref.base.ident);
    try std.testing.expectEqualStrings("Group1", b0.lhs.array_ref.index.?.ident);
    try std.testing.expectEqual(@as(usize, 2), b0.rhs.list.len);
    // body[1]: actions[Group1] = [NoAction()] -> assign, index not dropped
    const b1 = kd.body[1].assign;
    try std.testing.expectEqualStrings("actions", b1.lhs.array_ref.base.ident);
    try std.testing.expectEqualStrings("Group1", b1.lhs.array_ref.index.?.ident);
    try std.testing.expectEqual(@as(usize, 1), b1.rhs.list.len);
}

test "integration: full mini keymap" {
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { <AE01> = 10; <LFSH> = 50; alias <CAPS> = <CAPL>; };
        \\  xkb_types "t" { type "ONE" { modifiers = None; }; };
        \\  xkb_compat "c" { interpret Any+AnyOf(all) { action = SetMods(modifiers=Shift); }; };
        \\  xkb_symbols "s" {
        \\    key <AE01> { [ 1, exclam ] };
        \\    key <LFSH> { [ Shift_L ] };
        \\    modifier_map Shift { <LFSH> };
        \\  };
        \\};
    ;
    var lx2 = Lexer.init(std.testing.allocator, src);
    defer lx2.deinit();
    var p = Parser.init(std.testing.allocator, &lx2);
    defer p.deinit();
    const file = try p.parseFile();

    // one top-level component: the xkb_keymap wrapper
    try std.testing.expectEqual(@as(usize, 1), file.components.len);
    const km = file.components[0];
    try std.testing.expectEqual(ast.Component.Kind.keymap, km.kind);

    // keymap has 4 children (keycodes, types, compat, symbols)
    try std.testing.expectEqual(@as(usize, 4), km.children.len);

    // child 0: xkb_keycodes with 3 decls (2 keycode defs + 1 alias)
    const kc = km.children[0];
    try std.testing.expectEqual(ast.Component.Kind.keycodes, kc.kind);
    try std.testing.expectEqualStrings("k", kc.name.?);
    try std.testing.expectEqual(@as(usize, 3), kc.decls.len);
    try std.testing.expect(kc.decls[0] == .keycode);
    try std.testing.expectEqualStrings("AE01", kc.decls[0].keycode.name);
    try std.testing.expectEqual(@as(i64, 10), kc.decls[0].keycode.value.integer);
    try std.testing.expect(kc.decls[1] == .keycode);
    try std.testing.expectEqualStrings("LFSH", kc.decls[1].keycode.name);
    try std.testing.expectEqual(@as(i64, 50), kc.decls[1].keycode.value.integer);
    try std.testing.expect(kc.decls[2] == .key_alias);
    try std.testing.expectEqualStrings("CAPS", kc.decls[2].key_alias.alias);
    try std.testing.expectEqualStrings("CAPL", kc.decls[2].key_alias.real);

    // child 1: xkb_types with 1 key_type decl
    const ty = km.children[1];
    try std.testing.expectEqual(ast.Component.Kind.types, ty.kind);
    try std.testing.expectEqual(@as(usize, 1), ty.decls.len);
    try std.testing.expect(ty.decls[0] == .key_type);
    try std.testing.expectEqualStrings("ONE", ty.decls[0].key_type.name);
    try std.testing.expectEqual(@as(usize, 1), ty.decls[0].key_type.body.len);

    // child 2: xkb_compat with 1 interp decl
    const co = km.children[2];
    try std.testing.expectEqual(ast.Component.Kind.compat, co.kind);
    try std.testing.expectEqual(@as(usize, 1), co.decls.len);
    try std.testing.expect(co.decls[0] == .interp);
    try std.testing.expectEqualStrings("Any", co.decls[0].interp.sym);
    try std.testing.expect(co.decls[0].interp.match != null);
    try std.testing.expectEqual(@as(usize, 1), co.decls[0].interp.body.len);

    // child 3: xkb_symbols with 3 decls (2 key + 1 mod_map)
    const sy = km.children[3];
    try std.testing.expectEqual(ast.Component.Kind.symbols, sy.kind);
    try std.testing.expectEqual(@as(usize, 3), sy.decls.len);
    try std.testing.expect(sy.decls[0] == .key);
    try std.testing.expectEqualStrings("AE01", sy.decls[0].key.name);
    try std.testing.expect(sy.decls[1] == .key);
    try std.testing.expectEqualStrings("LFSH", sy.decls[1].key.name);
    try std.testing.expect(sy.decls[2] == .mod_map);
    try std.testing.expectEqualStrings("Shift", sy.decls[2].mod_map.modifier);
    try std.testing.expectEqual(@as(usize, 1), sy.decls[2].mod_map.keys.len);
    try std.testing.expectEqualStrings("LFSH", sy.decls[2].mod_map.keys[0].keyname);
}

test "parseDecl: geometry section decls shape section doodad" {
    const src =
        \\xkb_geometry "g" {
        \\  width = 470;
        \\  shape "KEYCAP" { { [16,16] } };
        \\  section "main" { row { keys { { name=<AE01> } }; }; };
        \\  solid "GreyStuff" { top=1; left=1; };
        \\};
    ;
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 4), decls.len);

    // decl[0]: width = 470 -> var_def
    try std.testing.expect(decls[0] == .var_def);
    try std.testing.expectEqualStrings("width", decls[0].var_def.name.ident);
    try std.testing.expectEqual(@as(i64, 470), decls[0].var_def.value.?.integer);

    // decl[1]: shape "KEYCAP" { { [16,16] } } -> shape
    try std.testing.expect(decls[1] == .shape);
    try std.testing.expectEqualStrings("KEYCAP", decls[1].shape.name);
    try std.testing.expectEqual(@as(usize, 1), decls[1].shape.outlines.len);

    // decl[2]: section "main" { row { ... }; } -> geom_section containing a row
    try std.testing.expect(decls[2] == .geom_section);
    try std.testing.expectEqualStrings("main", decls[2].geom_section.name);
    try std.testing.expect(decls[2].geom_section.body.len >= 1);
    try std.testing.expect(decls[2].geom_section.body[0] == .row);

    // decl[3]: solid "GreyStuff" { top=1; left=1; } -> doodad kind=solid
    try std.testing.expect(decls[3] == .doodad);
    try std.testing.expectEqualStrings("GreyStuff", decls[3].doodad.name);
    try std.testing.expect(decls[3].doodad.kind == .solid);
    try std.testing.expectEqual(@as(usize, 2), decls[3].doodad.body.len);
}

test "parseDecl: keys def inside row captures key item (fix 1)" {
    const src =
        \\xkb_geometry "g" {
        \\  section "s" {
        \\    row {
        \\      keys { { name=<AE01> } };
        \\    };
        \\  };
        \\};
    ;
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const section_body = f.components[0].decls[0].geom_section.body;
    const row_body = section_body[0].row.body;
    try std.testing.expectEqual(@as(usize, 1), row_body.len);
    const keys_def = row_body[0].keys;
    try std.testing.expectEqual(@as(usize, 1), keys_def.body.len);
    const group = keys_def.body[0].list;
    try std.testing.expectEqual(@as(usize, 1), group.len);
    try std.testing.expectEqualStrings("name", group[0].assign.lhs.ident);
    try std.testing.expectEqualStrings("AE01", group[0].assign.rhs.keyname);
}

test "parseDecl: shape commas between outline groups (fix 2a)" {
    const src = "xkb_geometry \"g\" { shape \"K\" { { [0,0] }, { [1,1] } }; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const shape = f.components[0].decls[0].shape;
    try std.testing.expectEqual(@as(usize, 2), shape.outlines.len);
    try std.testing.expectEqual(@as(usize, 1), shape.outlines[0].list.len);
    try std.testing.expectEqual(@as(i64, 0), shape.outlines[0].list[0].list[0].integer);
    try std.testing.expectEqual(@as(usize, 1), shape.outlines[1].list.len);
    try std.testing.expectEqual(@as(i64, 1), shape.outlines[1].list[0].list[0].integer);
}

test "parseDecl: shape vardef then outline group (fix 2b)" {
    const src = "xkb_geometry \"g\" { shape \"K\" { cornerRadius = 1, { [0,0] } }; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const shape = f.components[0].decls[0].shape;
    try std.testing.expectEqual(@as(usize, 2), shape.outlines.len);
    try std.testing.expectEqualStrings("cornerRadius", shape.outlines[0].assign.lhs.ident);
    try std.testing.expectEqual(@as(i64, 1), shape.outlines[0].assign.rhs.integer);
    try std.testing.expectEqual(@as(usize, 1), shape.outlines[1].list.len);
}

test "parseDecl: generic ident block preserves field values (fix 3)" {
    const src = "xkb_geometry \"g\" { foo { bar = 5; }; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decl = f.components[0].decls[0];
    try std.testing.expect(decl == .var_def);
    try std.testing.expectEqualStrings("foo", decl.var_def.name.ident);
    const list = decl.var_def.value.?.list;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("bar", list[0].assign.lhs.ident);
    try std.testing.expectEqual(@as(i64, 5), list[0].assign.rhs.integer);
}

test "parseDecl: unknown leading token returns ParseError (fix 4)" {
    const src = "xkb_symbols \"s\" { ) };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const result = p.parseFile();
    try std.testing.expectError(error.ParseError, result);
}

test "parseExpr: list with nested brace group [{a, b}, c]" {
    var lexer = Lexer.init(std.testing.allocator, "[ {a, b}, c ]");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const e = try p.parseExpr();
    try std.testing.expectEqual(@as(usize, 2), e.list.len);
    // First element is a nested list representing the multi-sym group {a, b}
    try std.testing.expectEqual(@as(usize, 2), e.list[0].list.len);
    try std.testing.expectEqualStrings("a", e.list[0].list[0].ident);
    try std.testing.expectEqualStrings("b", e.list[0].list[1].ident);
    // Second element is a plain ident c
    try std.testing.expectEqualStrings("c", e.list[1].ident);
}

test "parseDecl: KeyDef with groupsClamp bare ident in body" {
    const src = "xkb_symbols \"s\" { key <AE01> { groupsClamp, [a] }; };";
    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const f = try p.parseFile();
    const decls = f.components[0].decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    const kd = decls[0].key;
    try std.testing.expectEqualStrings("AE01", kd.name);
    // body: two items, the bare ident and the sym list
    try std.testing.expectEqual(@as(usize, 2), kd.body.len);
    try std.testing.expectEqualStrings("groupsClamp", kd.body[0].ident);
    try std.testing.expectEqual(@as(usize, 1), kd.body[1].list.len);
}

test "parseExpr: recursion depth guard returns ParseError (fix 5)" {
    const nest = 5000;
    const src_len = nest * 2 + 1;
    const src = try std.testing.allocator.alloc(u8, src_len);
    defer std.testing.allocator.free(src);
    for (0..nest) |i| src[i] = '(';
    src[nest] = '1';
    for (0..nest) |i| src[nest + 1 + i] = ')';

    var lexer = Lexer.init(std.testing.allocator, src);
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();
    const result = p.parseExpr();
    try std.testing.expectError(error.ParseError, result);
}

test "a section keyword followed by a dot is a default, not a block" {
    // `interpret.repeat = False;` sets the default for the interpret
    // declarations after it. xkbcomp emits this in the compat section of an
    // ordinary keymap, so refusing it made every real compositor keymap fail to
    // parse while the hand-written test maps passed.
    var lexer = Lexer.init(std.testing.allocator, "interpret.repeat= False;");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const decl = try p.parseDecl();
    try std.testing.expectEqualStrings("interpret", decl.var_def.name.dot.lhs.ident);
    try std.testing.expectEqualStrings("repeat", decl.var_def.name.dot.field);
}

test "the same keyword still opens a block when no dot follows it" {
    // The two forms share a keyword, so the check that tells them apart must not
    // swallow the block form.
    var lexer = Lexer.init(std.testing.allocator, "interpret Foo+AnyOf(all) { repeat= True; };");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const decl = try p.parseDecl();
    try std.testing.expectEqualStrings("Foo", decl.interp.sym);
    try std.testing.expectEqual(@as(usize, 1), decl.interp.body.len);
}

test "an action argument can be indexed" {
    // `Private(type=0x86,data[0]=0x50)` is how a private action fills its
    // payload a byte at a time, and real keymaps carry a dozen of them for the
    // XF86 log keys.
    var lexer = Lexer.init(std.testing.allocator, "action= Private(type=0x86,data[0]=0x50,data[1]=0x72);");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const vd = try p.parseVarDef();
    try std.testing.expectEqualStrings("action", vd.name.ident);
    try std.testing.expectEqual(@as(usize, 3), vd.value.?.action.args.len);
}

test "an interpret can name its keysym as a number" {
    // libxkbcommon emits `interpret 0xff7f+AnyOf(all)` for keysyms it has no
    // name for; 1.13.2 emits 53 of them in an ordinary keymap. The lexer is
    // right to call that an integer, so the parser has to accept one here.
    // Demanding an identifier rejected the whole keymap on the first occurrence.
    var lexer = Lexer.init(std.testing.allocator, "interpret 0xff7f+AnyOf(all) { repeat= True; };");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const decl = try p.parseDecl();
    // Kept as the text a keysym lookup understands: `keysym.fromName` already
    // reads the `0x<hex>` form, so the consumer needs no separate numeric path.
    try std.testing.expectEqualStrings("0xff7f", decl.interp.sym);
}

test "a named keysym in an interpret still works" {
    var lexer = Lexer.init(std.testing.allocator, "interpret Caps_Lock+AnyOf(all) { repeat= True; };");
    defer lexer.deinit();
    var p = Parser.init(std.testing.allocator, &lexer);
    defer p.deinit();

    const decl = try p.parseDecl();
    try std.testing.expectEqualStrings("Caps_Lock", decl.interp.sym);
}
