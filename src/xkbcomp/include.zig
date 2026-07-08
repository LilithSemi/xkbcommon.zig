/// include.zig: XKB include-spec parser and file resolver.
/// Slices in parseIncludeSpec point into the caller's spec string; the caller must keep it alive.
/// resolveFile heap-allocates Lexer and Parser so the Parser's *Lexer stays valid; call rf.deinit() when done.
const std = @import("std");
const ast = @import("ast.zig");
const Context = @import("../context.zig").Context;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

pub const IncMerge = enum { default, augment, override, replace };

pub const IncludeComponent = struct {
    merge: IncMerge,
    file: []const u8,
    map: ?[]const u8,
    /// 1-based group target (null = default, i.e. group 1 / index 0).
    explicit_group: ?u8 = null,
};

/// Parse an XKB include spec into components. "+" gives .override, "|" gives .augment.
/// Each component is "file" or "file(map)". Returned slices point into spec; spec must outlive the result.
pub fn parseIncludeSpec(alloc: std.mem.Allocator, spec: []const u8) ![]IncludeComponent {
    var list: std.ArrayListUnmanaged(IncludeComponent) = .empty;
    errdefer list.deinit(alloc);

    var rest = spec;
    var next_merge: IncMerge = .default;

    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '|')) {
        next_merge = if (rest[0] == '+') .override else .augment;
        rest = rest[1..];
    }

    while (rest.len > 0) {
        // Find the next + or | that is outside parentheses.
        var i: usize = 0;
        var depth: usize = 0;
        var op_pos: ?usize = null;
        var op_char: u8 = 0;

        while (i < rest.len) : (i += 1) {
            switch (rest[i]) {
                '(' => depth += 1,
                ')' => if (depth > 0) {
                    depth -= 1;
                },
                '+', '|' => if (depth == 0) {
                    op_pos = i;
                    op_char = rest[i];
                    break;
                },
                else => {},
            }
        }

        const piece = if (op_pos) |p| rest[0..p] else rest;
        rest = if (op_pos) |p| rest[p + 1 ..] else "";

        const merge = next_merge;
        next_merge = if (op_char == '+') .override else .augment;

        // Extract the optional :N group suffix that may appear after any (map) part.
        // Examples: "de:2", "de(basic):2", "de(basic)" (no suffix).
        const paren_end_in_piece: usize = if (std.mem.indexOfScalar(u8, piece, '(')) |po|
            (std.mem.indexOfScalarPos(u8, piece, po, ')') orelse (piece.len -| 1)) + 1
        else
            0;
        const colon_in_suffix = std.mem.indexOfScalarPos(u8, piece, paren_end_in_piece, ':');
        const piece_core = if (colon_in_suffix) |cp| piece[0..cp] else piece;
        const explicit_group: ?u8 = if (colon_in_suffix) |cp| grp: {
            const n_str = std.mem.trim(u8, piece[cp + 1 ..], " \t");
            const n = std.fmt.parseInt(u8, n_str, 10) catch break :grp null;
            if (n == 0) break :grp null;
            break :grp n;
        } else null;

        const file_str, const map_str = if (std.mem.indexOfScalar(u8, piece_core, '(')) |paren_open| blk: {
            const paren_close = std.mem.indexOfScalarPos(u8, piece_core, paren_open, ')') orelse piece_core.len;
            const raw_map = std.mem.trim(u8, piece_core[paren_open + 1 .. paren_close], " \t");
            break :blk .{
                std.mem.trim(u8, piece_core[0..paren_open], " \t"),
                @as(?[]const u8, if (raw_map.len == 0) null else raw_map),
            };
        } else .{
            std.mem.trim(u8, piece_core, " \t"),
            @as(?[]const u8, null),
        };

        try list.append(alloc, .{ .merge = merge, .file = file_str, .map = map_str, .explicit_group = explicit_group });
    }

    return list.toOwnedSlice(alloc);
}

/// Map a component kind to its XKB subdirectory name.
pub fn kindDir(kind: ast.Component.Kind) []const u8 {
    return switch (kind) {
        .keycodes => "keycodes",
        .types => "types",
        .compat => "compat",
        .symbols => "symbols",
        .geometry => "geometry",
        .keymap => "keymap",
    };
}

/// Owns a parsed XkbFile and its Lexer/Parser; call deinit() when done.
pub const ResolvedFile = struct {
    alloc: std.mem.Allocator,
    src: []u8,
    lx: *Lexer,
    p: *Parser,
    xf: *ast.XkbFile,

    pub fn deinit(self: *ResolvedFile) void {
        self.p.deinit();
        self.alloc.destroy(self.p);
        self.lx.deinit();
        self.alloc.destroy(self.lx);
        self.alloc.free(self.src);
    }
};

/// Open and parse "kindDir/file" via context include paths. Returns error.FileNotFound if missing.
pub fn resolveFile(
    alloc: std.mem.Allocator,
    ctx: *Context,
    kind: ast.Component.Kind,
    file: []const u8,
) !ResolvedFile {
    const subpath = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ kindDir(kind), file });
    defer alloc.free(subpath);

    const src = blk: {
        var of = ctx.open(subpath) orelse return error.FileNotFound;
        defer of.close();
        break :blk try std.Io.Dir.cwd().readFileAlloc(ctx.io, of.path, alloc, .unlimited);
    };
    errdefer alloc.free(src);

    const lx = try alloc.create(Lexer);
    errdefer alloc.destroy(lx);
    lx.* = Lexer.init(alloc, src);
    errdefer lx.deinit();

    const p = try alloc.create(Parser);
    errdefer alloc.destroy(p);
    p.* = Parser.init(alloc, lx);
    errdefer p.deinit();

    const xf = try p.parseFile();

    return .{ .alloc = alloc, .src = src, .lx = lx, .p = p, .xf = xf };
}

fn searchComponents(
    components: []ast.Component,
    kind: ast.Component.Kind,
    map: ?[]const u8,
) ?*ast.Component {
    var first_of_kind: ?*ast.Component = null;
    for (components) |*comp| {
        if (comp.kind == .keymap and comp.children.len > 0) {
            if (searchComponents(comp.children, kind, map)) |found| return found;
        }
        if (comp.kind != kind) continue;
        if (map) |m| {
            if (comp.name) |n| {
                if (std.ascii.eqlIgnoreCase(n, m)) return comp;
            }
        } else {
            if (comp.flags.default) return comp;
            if (first_of_kind == null) first_of_kind = comp;
        }
    }
    return if (map == null) first_of_kind else null;
}

/// Pick the component from a parsed file matching (kind, map). Null map picks the default-flagged or first.
pub fn selectMap(
    xf: *ast.XkbFile,
    kind: ast.Component.Kind,
    map: ?[]const u8,
) ?*ast.Component {
    return searchComponents(xf.components, kind, map);
}

/// Owns all ResolvedFiles produced during an include chain and guards against cycles and deep nesting.
pub const Resolver = struct {
    alloc: std.mem.Allocator,
    ctx: *Context,
    /// Owns every ResolvedFile produced; freed in deinit.
    files: std.ArrayList(ResolvedFile),
    /// Active include chain for cycle detection (a stack).
    stack: std.ArrayList(Key),
    depth: usize = 0,

    pub const Key = struct {
        kind: ast.Component.Kind,
        file: []const u8,
        map: ?[]const u8,
    };

    pub fn init(alloc: std.mem.Allocator, ctx: *Context) Resolver {
        return .{
            .alloc = alloc,
            .ctx = ctx,
            .files = .empty,
            .stack = .empty,
            .depth = 0,
        };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.files.items) |*rf| rf.deinit();
        self.files.deinit(self.alloc);
        self.stack.deinit(self.alloc);
    }

    /// Resolve one (kind, file, map) tuple. Errors: IncludeTooDeep, IncludeCycle, NoMap.
    pub fn resolve(
        self: *Resolver,
        kind: ast.Component.Kind,
        file: []const u8,
        map: ?[]const u8,
    ) !*ast.Component {
        if (self.depth >= 32) return error.IncludeTooDeep;

        for (self.stack.items) |k| {
            if (k.kind != kind) continue;
            if (!std.mem.eql(u8, k.file, file)) continue;
            const maps_match = blk: {
                if (k.map) |km| {
                    if (map) |m| break :blk std.mem.eql(u8, km, m);
                    break :blk false;
                } else {
                    break :blk map == null;
                }
            };
            if (maps_match) return error.IncludeCycle;
        }

        try self.stack.append(self.alloc, .{ .kind = kind, .file = file, .map = map });
        self.depth += 1;
        errdefer {
            _ = self.stack.pop();
            self.depth -= 1;
        }

        var rf = try resolveFile(self.alloc, self.ctx, kind, file);

        const comp = selectMap(rf.xf, kind, map) orelse {
            rf.deinit();
            return error.NoMap;
        };

        self.files.append(self.alloc, rf) catch |err| {
            rf.deinit();
            return err;
        };

        return comp;
    }

    /// Pop the active stack entry after walking a resolved component's nested includes.
    pub fn leave(self: *Resolver) void {
        std.debug.assert(self.stack.items.len > 0);
        _ = self.stack.pop();
        self.depth -= 1;
    }

    /// Resolve a full include-spec string. Returns caller-owned component pointers; components live until deinit.
    pub fn resolveSpec(
        self: *Resolver,
        kind: ast.Component.Kind,
        spec: []const u8,
    ) ![]*ast.Component {
        const parsed = try parseIncludeSpec(self.alloc, spec);
        defer self.alloc.free(parsed);

        var result: std.ArrayList(*ast.Component) = .empty;
        errdefer result.deinit(self.alloc);

        for (parsed) |ic| {
            const comp = try self.resolve(kind, ic.file, ic.map);
            defer self.leave();
            try result.append(self.alloc, comp);
        }

        return result.toOwnedSlice(self.alloc);
    }

    /// Component pointer paired with its group target (from a :N suffix in the spec).
    pub const ResolvedSpec = struct {
        comp: *ast.Component,
        /// 1-based group index (null = default, i.e. group 1 / index 0).
        explicit_group: ?u8,
    };

    /// Like resolveSpec but also returns the explicit_group from each IncludeComponent.
    /// Use this when the caller needs to apply per-group placement (symbols multi-layout).
    pub fn resolveSpecFull(
        self: *Resolver,
        kind: ast.Component.Kind,
        spec: []const u8,
    ) ![]ResolvedSpec {
        const parsed = try parseIncludeSpec(self.alloc, spec);
        defer self.alloc.free(parsed);

        var result: std.ArrayListUnmanaged(ResolvedSpec) = .empty;
        errdefer result.deinit(self.alloc);

        for (parsed) |ic| {
            const comp = try self.resolve(kind, ic.file, ic.map);
            defer self.leave();
            try result.append(self.alloc, .{ .comp = comp, .explicit_group = ic.explicit_group });
        }

        return result.toOwnedSlice(self.alloc);
    }
};

test "parseIncludeSpec single with map" {
    const r = try parseIncludeSpec(std.testing.allocator, "us(basic)");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("us", r[0].file);
    try std.testing.expectEqualStrings("basic", r[0].map.?);
    try std.testing.expectEqual(IncMerge.default, r[0].merge);
}

test "parseIncludeSpec chain with operators" {
    const r = try parseIncludeSpec(std.testing.allocator, "evdev+aliases(qwerty)|extra");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqualStrings("evdev", r[0].file);
    try std.testing.expect(r[0].map == null);
    try std.testing.expectEqualStrings("aliases", r[1].file);
    try std.testing.expectEqualStrings("qwerty", r[1].map.?);
    try std.testing.expectEqual(IncMerge.override, r[1].merge);
    try std.testing.expectEqualStrings("extra", r[2].file);
    try std.testing.expectEqual(IncMerge.augment, r[2].merge);
}

test "parseIncludeSpec whitespace tolerance" {
    const r = try parseIncludeSpec(std.testing.allocator, " us ( basic ) ");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("us", r[0].file);
    try std.testing.expectEqualStrings("basic", r[0].map.?);
    try std.testing.expectEqual(IncMerge.default, r[0].merge);
}

test "parseIncludeSpec no map" {
    const r = try parseIncludeSpec(std.testing.allocator, "evdev");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("evdev", r[0].file);
    try std.testing.expect(r[0].map == null);
    try std.testing.expectEqual(IncMerge.default, r[0].merge);
}

test "parseIncludeSpec leading operator" {
    const r = try parseIncludeSpec(std.testing.allocator, "|us");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("us", r[0].file);
    try std.testing.expectEqual(IncMerge.augment, r[0].merge);
}

test "parseIncludeSpec empty parens treated as null map" {
    const r = try parseIncludeSpec(std.testing.allocator, "us()");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("us", r[0].file);
    try std.testing.expect(r[0].map == null);
}

test "resolveFile + selectMap" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "keycodes");
    try tmp.dir.writeFile(io, .{
        .sub_path = "keycodes/mine",
        .data = "default xkb_keycodes \"basic\" { <AE01> = 10; };",
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];

    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);

    var rf = try resolveFile(std.testing.allocator, ctx, .keycodes, "mine");
    defer rf.deinit();

    const comp = selectMap(rf.xf, .keycodes, "basic") orelse return error.NoMap;
    try std.testing.expectEqual(ast.Component.Kind.keycodes, comp.kind);
    try std.testing.expectEqual(@as(usize, 1), comp.decls.len);

    // null map returns the default-flagged component
    try std.testing.expect(selectMap(rf.xf, .keycodes, null) != null);
}

test "kindDir coverage" {
    try std.testing.expectEqualStrings("keycodes", kindDir(.keycodes));
    try std.testing.expectEqualStrings("types", kindDir(.types));
    try std.testing.expectEqualStrings("compat", kindDir(.compat));
    try std.testing.expectEqualStrings("symbols", kindDir(.symbols));
    try std.testing.expectEqualStrings("geometry", kindDir(.geometry));
    try std.testing.expectEqualStrings("keymap", kindDir(.keymap));
}

test "Resolver integration" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "symbols");
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols/main",
        .data = "xkb_symbols \"m\" { include \"extra\"; };",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols/extra",
        .data = "default xkb_symbols \"e\" { key <AE01> { [ a ] }; };",
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];

    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);

    var r = Resolver.init(std.testing.allocator, ctx);
    defer r.deinit();

    const comps = try r.resolveSpec(.symbols, "main");
    defer std.testing.allocator.free(comps);
    try std.testing.expectEqual(@as(usize, 1), comps.len);

    const main_comp = comps[0];
    try std.testing.expectEqual(@as(usize, 1), main_comp.decls.len);
    try std.testing.expectEqualStrings("extra", main_comp.decls[0].include.path);

    const extra_comp = try r.resolve(.symbols, "extra", null);
    defer r.leave();
    try std.testing.expectEqual(@as(usize, 1), extra_comp.decls.len);
    try std.testing.expectEqualStrings("AE01", extra_comp.decls[0].key.name);
}

test "Resolver cycle detection" {
    // Write a -> b -> a pair and simulate the recursive 3d driver pattern.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "symbols");
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols/a",
        .data = "xkb_symbols \"a\" { include \"b\"; };",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols/b",
        .data = "xkb_symbols \"b\" { include \"a\"; };",
    });
    var pathbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pn = try tmp.dir.realPath(io, &pathbuf);
    const real = pathbuf[0..pn];

    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);

    var r = Resolver.init(std.testing.allocator, ctx);
    defer r.deinit();

    // Simulate: 3d resolves "a" (parent stays on stack while walking children)
    _ = try r.resolve(.symbols, "a", null);
    defer r.leave();
    // 3d walks a's include decl -> resolves "b" (b stays on stack)
    _ = try r.resolve(.symbols, "b", null);
    defer r.leave();
    // 3d walks b's include decl -> tries to resolve "a" again: cycle detected
    try std.testing.expectError(error.IncludeCycle, r.resolve(.symbols, "a", null));
}

test "Resolver depth guard" {
    // Exercise the non-preseeded path: loop resolve 32 times (no leave),
    // verify the 33rd call hits IncludeTooDeep, then balance the stack.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "symbols");

    // Create 32 uniquely-named files so the cycle check never fires.
    for (0..32) |i| {
        var fname: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&fname, "symbols/d{d}", .{i});
        try tmp.dir.writeFile(io, .{
            .sub_path = s,
            .data = "default xkb_symbols \"x\" { };",
        });
    }
    var pathbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pn = try tmp.dir.realPath(io, &pathbuf);
    const real = pathbuf[0..pn];

    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);

    var r = Resolver.init(std.testing.allocator, ctx);
    defer r.deinit();

    // Each allocation lives until deinit; Keys on the stack hold these slices.
    var names: [32][]u8 = undefined;
    for (0..32) |i| {
        names[i] = try std.fmt.allocPrint(std.testing.allocator, "d{d}", .{i});
    }
    defer for (names) |nm| std.testing.allocator.free(nm);

    for (0..32) |i| {
        _ = try r.resolve(.symbols, names[i], null);
    }
    // depth == 32 now; 33rd call must fail regardless of whether d32 exists
    try std.testing.expectError(error.IncludeTooDeep, r.resolve(.symbols, "d32", null));

    // Balance the stack so deinit sees a consistent state
    while (r.stack.items.len > 0) r.leave();
}

test "parseIncludeSpec explicit group suffix :N" {
    const r = try parseIncludeSpec(std.testing.allocator, "de:2");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("de", r[0].file);
    try std.testing.expect(r[0].map == null);
    try std.testing.expectEqual(@as(?u8, 2), r[0].explicit_group);
}

test "parseIncludeSpec group suffix with map" {
    const r = try parseIncludeSpec(std.testing.allocator, "de(basic):2");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("de", r[0].file);
    try std.testing.expectEqualStrings("basic", r[0].map.?);
    try std.testing.expectEqual(@as(?u8, 2), r[0].explicit_group);
}

test "parseIncludeSpec chain with group suffix on last component" {
    const r = try parseIncludeSpec(std.testing.allocator, "pc+us+de:2");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqualStrings("pc", r[0].file);
    try std.testing.expect(r[0].explicit_group == null);
    try std.testing.expectEqualStrings("us", r[1].file);
    try std.testing.expect(r[1].explicit_group == null);
    try std.testing.expectEqualStrings("de", r[2].file);
    try std.testing.expectEqual(@as(?u8, 2), r[2].explicit_group);
}

test "selectMap name mismatch returns null" {
    // Uses an in-memory parse to avoid filesystem.
    var lx = Lexer.init(std.testing.allocator, "xkb_keycodes \"foo\" { };");
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const xf = try p.parseFile();
    try std.testing.expect(selectMap(xf, .keycodes, "bar") == null);
    // map=null and no default flag: returns first of kind
    try std.testing.expect(selectMap(xf, .keycodes, null) != null);
}
