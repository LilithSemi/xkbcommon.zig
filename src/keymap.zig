const std = @import("std");
const Context = @import("context.zig").Context;
const Atom = @import("context.zig").Atom;
const Keysym = @import("keysym.zig").Keysym;
const ast = @import("xkbcomp/ast.zig");
const include_lib = @import("xkbcomp/include.zig");
const Lexer = @import("xkbcomp/lexer.zig").Lexer;
const Parser = @import("xkbcomp/parser.zig").Parser;
const compile_keycodes = @import("xkbcomp/compile_keycodes.zig");
const compile_types = @import("xkbcomp/compile_types.zig");
const compile_compat = @import("xkbcomp/compile_compat.zig");
const compile_symbols = @import("xkbcomp/compile_symbols.zig");
const compile_link = @import("xkbcomp/compile_link.zig");
const compile_geometry = @import("xkbcomp/compile_geometry.zig");
pub const rules = @import("xkbcomp/rules.zig");
const serialize = @import("xkbcomp/serialize.zig");
const mods_lib = @import("xkbcomp/mods.zig");

pub const ModMask = u32;
pub const ModIndex = u32;
pub const mod_index_invalid: ModIndex = 0xffffffff;
pub const LevelIndex = u32;
pub const LayoutIndex = u32;
pub const LayoutMask = u32;
pub const Keycode = u32;

pub const ModType = enum(u8) { real = 1, virt = 2 };

pub const Mod = struct {
    name: Atom,
    type: ModType,
    mapping: ModMask,
};

pub const ModSet = struct {
    mods: []Mod,
};

pub const KeyType = struct {
    name: Atom,
    mods: ModMask,
    num_levels: LevelIndex,
    entries: []Entry,
    level_names: []Atom,

    pub const Entry = struct {
        level: LevelIndex,
        mods: ModMask,
        preserve: ModMask,
    };
};

pub const ModsFlags = packed struct(u8) {
    use_mod_map_mods: bool = false,
    clear_locks: bool = false,
    latch_to_lock: bool = false,
    _pad: u5 = 0,
};

pub const GroupFlags = packed struct(u8) {
    absolute: bool = false,
    _pad: u7 = 0,
};

pub const Action = union(enum) {
    none,
    mods: ModsAction,
    group: GroupAction,
    ptr: PtrAction,
    ptr_button: PtrButtonAction,
    ptr_default: PtrDefaultAction,
    terminate,
    switch_screen: SwitchScreenAction,
    controls: ControlsAction,
    private: PrivateAction,

    pub const ModsAction = struct {
        kind: enum { set, latch, lock },
        mods: ModMask,
        mods_by_name: bool,
        flags: ModsFlags,
    };

    pub const GroupAction = struct {
        kind: enum { set, latch, lock },
        group: i32,
        absolute: bool,
        flags: GroupFlags,
    };

    pub const PtrAction = struct {
        x: i16,
        y: i16,
        accelerate: bool,
    };

    pub const PtrButtonAction = struct {
        button: u8,
        count: u8,
    };

    pub const PtrDefaultAction = struct {
        affect: u8,
        value: i8,
    };

    pub const SwitchScreenAction = struct {
        screen: i8,
        same_server: bool,
    };

    pub const ControlsAction = struct {
        kind: enum { set, lock },
        ctrls: u32,
    };

    pub const PrivateAction = struct {
        kind: u8,
        data: [7]u8,
    };
};

pub const Level = struct {
    action: Action,
    syms: []Keysym,
};

pub const Group = struct {
    explicit_type: bool,
    type_index: u32,
    levels: []Level,
};

pub const RangeExceed = enum { wrap, clamp, redirect };

pub const Key = struct {
    name: Atom,
    keycode: Keycode,
    repeats: bool,
    modmap: ModMask,
    out_of_range_group_action: RangeExceed,
    out_of_range_group_number: LayoutIndex,
    groups: []Group,
};

pub const LedWhich = packed struct(u8) {
    modifiers: bool = false,
    groups: bool = false,
    _pad: u6 = 0,
};

pub const Led = struct {
    name: Atom,
    mods: ModMask,
    groups: LayoutMask,
    ctrls: u32,
    which_mods: LedWhich,
    which_groups: LedWhich,
};

pub const MatchOp = enum { none, any_of_or_none, none_of, any_of, all_of, exactly };

pub const SymInterpret = struct {
    sym: ?Keysym,
    match: MatchOp,
    mods: ModMask,
    virtual_mod: ModIndex,
    action: Action,
    level_one_only: bool,
    repeat: bool,
};

pub const KeyAlias = struct {
    alias: Atom,
    real: Atom,
};

pub const Format = enum { text_v1 };

pub const Geometry = struct {
    name: Atom,
    width_mm: i32 = 0,
    height_mm: i32 = 0,
    shapes: []Shape,
    sections: []GeomSection,
    doodads: []Doodad,

    pub const Point = struct { x: i32, y: i32 };
    pub const Outline = struct { points: []Point };
    pub const Shape = struct { name: Atom, outlines: []Outline };
    pub const GeomSection = struct { name: Atom, rows: []Row };
    pub const Row = struct { keys: []GeomKey };
    pub const GeomKey = struct { name: Atom };
    pub const Doodad = struct {
        kind: Kind,
        name: Atom,
        pub const Kind = enum { outline, solid, text, logo, indicator };
    };
};

pub const Keymap = struct {
    arena: std.heap.ArenaAllocator,
    ctx: *Context,
    format: Format,
    mods: ModSet,
    types: []KeyType,
    sym_interprets: []SymInterpret,
    leds: []Led,
    min_key_code: Keycode,
    max_key_code: Keycode,
    keys: []Key,
    key_aliases: []KeyAlias,
    group_names: []Atom,
    geometry: ?Geometry = null,

    pub fn create(ctx: *Context) !*Keymap {
        const alloc = ctx.allocator;
        const self = try alloc.create(Keymap);
        self.* = Keymap{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .ctx = ctx,
            .format = .text_v1,
            .mods = .{ .mods = &.{} },
            .types = &.{},
            .sym_interprets = &.{},
            .leds = &.{},
            .min_key_code = 0,
            .max_key_code = 0,
            .keys = &.{},
            .key_aliases = &.{},
            .group_names = &.{},
            .geometry = null,
        };
        return self;
    }

    /// Find the first component of a kind, searching keymap-wrapper children too.
    fn findSection(xf: *ast.XkbFile, kind: ast.Component.Kind) ?*ast.Component {
        for (xf.components) |*comp| {
            if (comp.kind == kind) return comp;
            if (comp.kind == .keymap) {
                for (comp.children) |*child| {
                    if (child.kind == kind) return child;
                }
            }
        }
        return null;
    }

    /// Recursively collect all virtual_modifiers declarations from comp and any included files.
    /// Used in the vmod pre-pass before compilation so the VmodTable is populated for all sections.
    fn collectVmods(
        kind: ast.Component.Kind,
        comp: *ast.Component,
        vmods: *mods_lib.VirtualMods,
        resolver: *include_lib.Resolver,
    ) !void {
        for (comp.decls) |decl| {
            switch (decl) {
                .vmods => |vd| {
                    for (vd.names) |name| {
                        _ = try vmods.intern(name);
                    }
                },
                .include => |inc| {
                    const parsed = include_lib.parseIncludeSpec(resolver.alloc, inc.path) catch continue;
                    defer resolver.alloc.free(parsed);
                    for (parsed) |ic| {
                        const child = resolver.resolve(kind, ic.file, ic.map) catch continue;
                        defer resolver.leave();
                        try collectVmods(kind, child, vmods, resolver);
                    }
                },
                else => {},
            }
        }
    }

    /// Parse and compile a complete XKB keymap from a string. All data goes into the Keymap's arena.
    pub fn newFromString(ctx: *Context, str: []const u8, format: Format) !*Keymap {
        const alloc = ctx.allocator;

        var lx = Lexer.init(alloc, str);
        defer lx.deinit();
        var p = Parser.init(alloc, &lx);
        defer p.deinit();
        const xf = try p.parseFile();

        const kc_comp = findSection(xf, .keycodes) orelse return error.MissingKeycodes;
        const ty_comp = findSection(xf, .types) orelse return error.MissingTypes;
        const cp_comp = findSection(xf, .compat) orelse return error.MissingCompat;
        const sy_comp = findSection(xf, .symbols) orelse return error.MissingSymbols;

        const km = try Keymap.create(ctx);
        errdefer km.destroy();
        km.format = format;

        const arena = km.arena.allocator();

        var resolver = include_lib.Resolver.init(alloc, ctx);
        defer resolver.deinit();

        // Pre-pass: collect all virtual_modifiers declarations from all sections (including includes).
        var vmods = mods_lib.VirtualMods.init(alloc);
        defer vmods.deinit();
        try collectVmods(.types, ty_comp, &vmods, &resolver);
        try collectVmods(.compat, cp_comp, &vmods, &resolver);
        try collectVmods(.symbols, sy_comp, &vmods, &resolver);

        const kc_info = try compile_keycodes.compileKeycodes(arena, ctx, kc_comp, &resolver);
        const types = try compile_types.compileTypes(arena, ctx, ty_comp, &resolver, &vmods);
        const compat_info = try compile_compat.compileCompat(arena, ctx, cp_comp, &resolver, &vmods);
        const sym_info = try compile_symbols.compileSymbols(arena, ctx, sy_comp, &resolver, &vmods);

        try compile_link.link(km, kc_info, types, compat_info, sym_info, &vmods);

        if (findSection(xf, .geometry)) |geom_comp| {
            km.geometry = try compile_geometry.compileGeometry(arena, ctx, geom_comp);
        }

        return km;
    }

    /// Build a Keymap from RMLVO names by resolving rules and compiling
    /// the five component include-specs produced by resolveRules.
    pub fn newFromNames(ctx: *Context, names: rules.RuleNames, format: Format) !*Keymap {
        var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const kccgst = try rules.resolveRules(sa, ctx, names);

        const km = try Keymap.create(ctx);
        errdefer km.destroy();
        km.format = format;

        const km_arena = km.arena.allocator();

        var resolver = include_lib.Resolver.init(sa, ctx);
        defer resolver.deinit();

        // Pre-pass: collect vmods from each section's included files before compiling.
        var vmods = mods_lib.VirtualMods.init(sa);
        defer vmods.deinit();
        if (kccgst.types.len > 0) {
            const inc_decl = ast.Decl{ .include = .{ .merge = .default, .path = kccgst.types } };
            var decls = [1]ast.Decl{inc_decl};
            var comp = ast.Component{ .kind = .types, .flags = .{}, .name = null, .decls = &decls, .children = &.{} };
            try collectVmods(.types, &comp, &vmods, &resolver);
        }
        if (kccgst.compat.len > 0) {
            const inc_decl = ast.Decl{ .include = .{ .merge = .default, .path = kccgst.compat } };
            var decls = [1]ast.Decl{inc_decl};
            var comp = ast.Component{ .kind = .compat, .flags = .{}, .name = null, .decls = &decls, .children = &.{} };
            try collectVmods(.compat, &comp, &vmods, &resolver);
        }
        if (kccgst.symbols.len > 0) {
            const inc_decl = ast.Decl{ .include = .{ .merge = .default, .path = kccgst.symbols } };
            var decls = [1]ast.Decl{inc_decl};
            var comp = ast.Component{ .kind = .symbols, .flags = .{}, .name = null, .decls = &decls, .children = &.{} };
            try collectVmods(.symbols, &comp, &vmods, &resolver);
        }

        // For each component, synthesize a Component with a single include decl
        // whose path is the kccgst spec string. The compile phase resolves/merges
        // the included files via the resolver (same pattern as newFromString).

        const kc_info = blk: {
            const inc_decl = ast.Decl{ .include = .{ .merge = .default, .path = kccgst.keycodes } };
            var decls = [1]ast.Decl{inc_decl};
            var comp = ast.Component{ .kind = .keycodes, .flags = .{}, .name = null, .decls = if (kccgst.keycodes.len > 0) &decls else &.{}, .children = &.{} };
            break :blk try compile_keycodes.compileKeycodes(km_arena, ctx, &comp, &resolver);
        };

        const types_info = blk: {
            const inc_decl = ast.Decl{ .include = .{ .merge = .default, .path = kccgst.types } };
            var decls = [1]ast.Decl{inc_decl};
            var comp = ast.Component{ .kind = .types, .flags = .{}, .name = null, .decls = if (kccgst.types.len > 0) &decls else &.{}, .children = &.{} };
            break :blk try compile_types.compileTypes(km_arena, ctx, &comp, &resolver, &vmods);
        };

        const compat_info = blk: {
            const inc_decl = ast.Decl{ .include = .{ .merge = .default, .path = kccgst.compat } };
            var decls = [1]ast.Decl{inc_decl};
            var comp = ast.Component{ .kind = .compat, .flags = .{}, .name = null, .decls = if (kccgst.compat.len > 0) &decls else &.{}, .children = &.{} };
            break :blk try compile_compat.compileCompat(km_arena, ctx, &comp, &resolver, &vmods);
        };

        const sym_info = blk: {
            const inc_decl = ast.Decl{ .include = .{ .merge = .default, .path = kccgst.symbols } };
            var decls = [1]ast.Decl{inc_decl};
            var comp = ast.Component{ .kind = .symbols, .flags = .{}, .name = null, .decls = if (kccgst.symbols.len > 0) &decls else &.{}, .children = &.{} };
            break :blk try compile_symbols.compileSymbols(km_arena, ctx, &comp, &resolver, &vmods);
        };

        try compile_link.link(km, kc_info, types_info, compat_info, sym_info, &vmods);

        return km;
    }

    /// Serialize the keymap to XKB text format.  Caller owns the returned
    /// slice and must free it with ctx.allocator.
    pub fn getAsString(self: *const Keymap, format: Format) ![]u8 {
        _ = format; // only text_v1 supported
        const alloc = self.ctx.allocator;
        var aw = std.Io.Writer.Allocating.init(alloc);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("xkb_keymap {\n");
        try serialize.serializeKeycodes(self, w);
        try serialize.serializeTypes(self, w);
        try serialize.serializeCompat(self, w);
        try serialize.serializeSymbols(self, w);
        if (self.geometry != null) {
            try serialize.serializeGeometry(self, w);
        }
        try w.writeAll("};\n");
        return alloc.dupe(u8, aw.writer.buffered());
    }

    pub fn destroy(self: *Keymap) void {
        const alloc = self.ctx.allocator;
        self.arena.deinit();
        alloc.destroy(self);
    }
};

test "keymap: create and destroy frees cleanly" {
    const io = std.testing.io;
    const ctx = try @import("context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();
    const km = try Keymap.create(ctx);
    km.destroy();
}

test "newFromString compiles a mini keymap end to end" {
    const keysym_lib = @import("keysym.zig");
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { minimum=8; maximum=255; <AE01> = 10; <LFSH> = 50; <CAPS> = 66; };
        \\  xkb_types "t" { type "TWO" { modifiers=Shift; map[Shift]=Level2; }; };
        \\  xkb_compat "c" { interpret Caps_Lock { action=LockMods(modifiers=Lock); }; };
        \\  xkb_symbols "s" {
        \\    key <AE01> { [ 1, exclam ] };
        \\    key <LFSH> { [ Shift_L ] };
        \\    key <CAPS> { [ Caps_Lock ] };
        \\    modifier_map Shift { <LFSH> };
        \\  };
        \\};
    ;
    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    try std.testing.expect(km.max_key_code >= 66);
    try std.testing.expectEqualStrings("AE01", ctx.atomText(km.keys[10].name));
    try std.testing.expectEqual(
        keysym_lib.fromName("1", .{}).?,
        km.keys[10].groups[0].levels[0].syms[0],
    );
    try std.testing.expect(km.mods.mods.len >= 8);
    // Caps key got its compat LockMods action via the interpret pass.
    try std.testing.expectEqual(
        std.meta.Tag(Action).mods,
        std.meta.activeTag(km.keys[66].groups[0].levels[0].action),
    );
    // LFSH contributes to Shift via modmap.
    try std.testing.expect((km.keys[50].modmap & 0x1) != 0);
}

test "newFromNames compiles a keymap via rules resolution" {
    const keysym_lib = @import("keysym.zig");
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "rules");
    try tmp.dir.createDirPath(io, "keycodes");
    try tmp.dir.createDirPath(io, "symbols");
    try tmp.dir.createDirPath(io, "types");
    try tmp.dir.createDirPath(io, "compat");

    const rules_txt =
        \\! model = keycodes
        \\  * = evdev
        \\! layout = symbols
        \\  * = pc+%l
        \\! model = types
        \\  * = complete
        \\! model = compat
        \\  * = complete
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/evdev", .data = rules_txt });
    try tmp.dir.writeFile(io, .{
        .sub_path = "keycodes/evdev",
        .data = "default xkb_keycodes \"evdev\" { <AE01> = 10; <AC01> = 38; };",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols/pc",
        .data = "default xkb_symbols \"pc\" { key <AE01> { [ 1, exclam ] }; };",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols/us",
        .data = "default xkb_symbols \"basic\" { key <AC01> { [ a, A ] }; };",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "types/complete",
        .data = "default xkb_types \"complete\" { type \"TWO_LEVEL\" { modifiers=Shift; map[Shift]=Level2; }; };",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "compat/complete",
        .data = "default xkb_compat \"complete\" {};",
    });

    var pathbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pathbuf);
    const real = pathbuf[0..n];

    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);

    const km = try Keymap.newFromNames(ctx, .{ .rules = "evdev", .layout = "us" }, .text_v1);
    defer km.destroy();

    // AE01 = 10 from keycodes/evdev, symbol '1' from symbols/pc
    try std.testing.expect(km.max_key_code >= 38);
    try std.testing.expectEqualStrings("AE01", ctx.atomText(km.keys[10].name));
    try std.testing.expectEqual(
        keysym_lib.fromName("1", .{}).?,
        km.keys[10].groups[0].levels[0].syms[0],
    );

    // AC01 = 38 from keycodes/evdev, symbol 'a' from symbols/us
    try std.testing.expectEqualStrings("AC01", ctx.atomText(km.keys[38].name));
    try std.testing.expectEqual(
        keysym_lib.fromName("a", .{}).?,
        km.keys[38].groups[0].levels[0].syms[0],
    );
}

test "newFromNames multi-layout: us,de gives two groups on AD01" {
    const keysym_lib = @import("keysym.zig");
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "rules");
    try tmp.dir.createDirPath(io, "keycodes");
    try tmp.dir.createDirPath(io, "symbols");
    try tmp.dir.createDirPath(io, "types");
    try tmp.dir.createDirPath(io, "compat");

    // Rules with indexed layout groups so de:2 suffix gets emitted for layout[2].
    const rules_txt =
        \\! model = keycodes
        \\  * = evdev
        \\! layout = symbols
        \\  * = pc+%l
        \\! layout[1] = symbols
        \\  * = pc+%l[1]
        \\! layout[2] = symbols
        \\  * = +%l[2]:2
        \\! model = types
        \\  * = complete
        \\! model = compat
        \\  * = complete
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/evdev", .data = rules_txt });
    try tmp.dir.writeFile(io, .{
        .sub_path = "keycodes/evdev",
        .data = "default xkb_keycodes \"e\" { <AD01>=24; };",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols/pc",
        .data = "default xkb_symbols \"pc\" {};",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols/us",
        .data = "default xkb_symbols \"basic\" { key <AD01> { [ q ] }; };",
    });
    // German: y is where q sits in qwerty.
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols/de",
        .data = "default xkb_symbols \"basic\" { key <AD01> { [ y ] }; };",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "types/complete",
        .data = "default xkb_types \"c\" { type \"ONE_LEVEL\" { modifiers=none; }; };",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "compat/complete",
        .data = "default xkb_compat \"c\" {};",
    });

    var pathbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pathbuf);
    const real = pathbuf[0..n];

    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);

    const km2 = try Keymap.newFromNames(ctx, .{ .rules = "evdev", .layout = "us,de" }, .text_v1);
    defer km2.destroy();

    // AD01 = keycode 24.
    try std.testing.expect(km2.max_key_code >= 24);
    const ad01_2 = km2.keys[24];
    try std.testing.expectEqualStrings("AD01", ctx.atomText(ad01_2.name));
    // Must have 2 groups.
    try std.testing.expectEqual(@as(usize, 2), ad01_2.groups.len);
    // Group 0 (us): q.
    try std.testing.expectEqual(
        keysym_lib.fromName("q", .{}).?,
        ad01_2.groups[0].levels[0].syms[0],
    );
    // Group 1 (de via :2): y.
    try std.testing.expectEqual(
        keysym_lib.fromName("y", .{}).?,
        ad01_2.groups[1].levels[0].syms[0],
    );

    const km1 = try Keymap.newFromNames(ctx, .{ .rules = "evdev", .layout = "us" }, .text_v1);
    defer km1.destroy();

    const ad01_1 = km1.keys[24];
    try std.testing.expectEqualStrings("AD01", ctx.atomText(ad01_1.name));
    // Must have exactly 1 group.
    try std.testing.expectEqual(@as(usize, 1), ad01_1.groups.len);
    try std.testing.expectEqual(
        keysym_lib.fromName("q", .{}).?,
        ad01_1.groups[0].levels[0].syms[0],
    );
}

test "virtual modifiers: LevelThree reaches level 3 of a 4-level key" {
    const State = @import("state.zig").State;
    const keysym_lib = @import("keysym.zig");
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { <AD01>=24; <RALT>=108; };
        \\  xkb_types "t" {
        \\    virtual_modifiers LevelThree;
        \\    type "FOUR" { modifiers=Shift+LevelThree; map[Shift]=Level2; map[LevelThree]=Level3; map[Shift+LevelThree]=Level4; };
        \\  };
        \\  xkb_compat "c" {
        \\    virtual_modifiers LevelThree;
        \\    interpret ISO_Level3_Shift { virtualModifier=LevelThree; action=SetMods(modifiers=LevelThree); };
        \\  };
        \\  xkb_symbols "s" {
        \\    virtual_modifiers LevelThree;
        \\    key <AD01> { type="FOUR", [ q, Q, eacute, Eacute ] };
        \\    key <RALT> { [ ISO_Level3_Shift ] };
        \\  };
        \\};
    ;
    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();
    const st = try State.create(km);
    defer st.destroy();
    // Base state: AD01 -> 'q'
    try std.testing.expectEqual(keysym_lib.fromName("q", .{}).?, st.keyGetOneSym(24));
    // Press RALT -> interpret fires SetMods(LevelThree) -> vmod bit set in mod_base
    _ = try st.updateKey(108, .down);
    // AD01 type "FOUR" has map[LevelThree]=Level3 -> should give 'eacute'
    try std.testing.expectEqual(keysym_lib.fromName("eacute", .{}).?, st.keyGetOneSym(24));
}

test "virtual modifiers through includes: vmod in included file reaches level 3" {
    const State = @import("state.zig").State;
    const keysym_lib = @import("keysym.zig");
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "symbols");
    // The vmod declaration lives only inside the included file, not in the top-level keymap string.
    try tmp.dir.writeFile(io, .{
        .sub_path = "symbols/inc_vmod",
        .data = "default xkb_symbols \"v\" { virtual_modifiers LevelThree; key <RALT> { [ ISO_Level3_Shift ] }; };",
    });

    var pathbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pathbuf);
    const real = pathbuf[0..n];

    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);

    // There is no "virtual_modifiers LevelThree;" in xkb_types or xkb_compat here.
    // The pre-pass must find it by resolving the include in xkb_symbols.
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { <AD01>=24; <RALT>=108; };
        \\  xkb_types "t" {
        \\    type "FOUR" { modifiers=Shift+LevelThree; map[Shift]=Level2; map[LevelThree]=Level3; map[Shift+LevelThree]=Level4; };
        \\  };
        \\  xkb_compat "c" {
        \\    interpret ISO_Level3_Shift { virtualModifier=LevelThree; action=SetMods(modifiers=LevelThree); };
        \\  };
        \\  xkb_symbols "s" {
        \\    include "inc_vmod";
        \\    key <AD01> { type="FOUR", [ q, Q, eacute, Eacute ] };
        \\  };
        \\};
    ;
    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    // LevelThree must appear in the mod table (as a virt entry).
    var found_lt = false;
    for (km.mods.mods) |m| {
        if (m.type == .virt and std.mem.eql(u8, ctx.atomText(m.name), "LevelThree")) {
            found_lt = true;
            break;
        }
    }
    try std.testing.expect(found_lt);

    const st = try State.create(km);
    defer st.destroy();
    // Base state: AD01 -> 'q'
    try std.testing.expectEqual(keysym_lib.fromName("q", .{}).?, st.keyGetOneSym(24));
    // Press RALT -> interpret fires SetMods(LevelThree) -> vmod bit set
    _ = try st.updateKey(108, .down);
    // FOUR type has map[LevelThree]=Level3 -> should give 'eacute'
    try std.testing.expectEqual(keysym_lib.fromName("eacute", .{}).?, st.keyGetOneSym(24));
}

test "vmodmap binding: virtualMods= in key body sets vmod bit in modmap (no interpret)" {
    const State = @import("state.zig").State;
    const keysym_lib = @import("keysym.zig");
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    // RALT uses virtualMods=LevelThree in its key body, no interpret binding it.
    // AD01 uses a custom FOUR_VK type that maps LevelThree to Level3.
    // Pressing RALT must set LevelThree bit in mod_base via vmodmap, reaching level 3 on AD01.
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { <AD01>=24; <RALT>=108; };
        \\  xkb_types "t" {
        \\    virtual_modifiers LevelThree;
        \\    type "FOUR_VK" { modifiers=Shift+LevelThree; map[Shift]=Level2; map[LevelThree]=Level3; map[Shift+LevelThree]=Level4; };
        \\  };
        \\  xkb_compat "c" { virtual_modifiers LevelThree; };
        \\  xkb_symbols "s" {
        \\    virtual_modifiers LevelThree;
        \\    key <AD01> { type="FOUR_VK", [ q, Q, eacute, Eacute ] };
        \\    key <RALT> { virtualMods=LevelThree, [ ISO_Level3_Shift ] };
        \\  };
        \\};
    ;
    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();
    // Find LevelThree vmod bit in the keymap mod table.
    var lt_bit: ModMask = 0;
    for (km.mods.mods) |m| {
        if (m.type == .virt and std.mem.eql(u8, ctx.atomText(m.name), "LevelThree")) {
            lt_bit = m.mapping;
            break;
        }
    }
    try std.testing.expect(lt_bit != 0);
    // RALT modmap must contain the LevelThree vmod bit (set via virtualMods=, no interpret).
    try std.testing.expect((km.keys[108].modmap & lt_bit) != 0);
    // State: pressing RALT routes AD01 to level 3.
    const st = try State.create(km);
    defer st.destroy();
    try std.testing.expectEqual(keysym_lib.fromName("q", .{}).?, st.keyGetOneSym(24));
    _ = try st.updateKey(108, .down);
    try std.testing.expectEqual(keysym_lib.fromName("eacute", .{}).?, st.keyGetOneSym(24));
}

test "FOUR_LEVEL builtin uses LevelThree vmod when declared" {
    const State = @import("state.zig").State;
    const keysym_lib = @import("keysym.zig");
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    // AD01 has 4 syms, no explicit type -> auto-resolved to builtin FOUR_LEVEL.
    // When LevelThree vmod is declared and RALT has virtualMods=LevelThree,
    // pressing RALT must reach level 3 via the builtin FOUR_LEVEL entries.
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { <AD01>=24; <RALT>=108; };
        \\  xkb_types "t" { virtual_modifiers LevelThree; };
        \\  xkb_compat "c" { virtual_modifiers LevelThree; };
        \\  xkb_symbols "s" {
        \\    virtual_modifiers LevelThree;
        \\    key <AD01> { [ q, Q, eacute, Eacute ] };
        \\    key <RALT> { virtualMods=LevelThree, [ ISO_Level3_Shift ] };
        \\  };
        \\};
    ;
    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();
    // The builtin FOUR_LEVEL must have LevelThree in its mods.
    var four_level_has_lt = false;
    var lt_bit: ModMask = 0;
    for (km.mods.mods) |m| {
        if (m.type == .virt and std.mem.eql(u8, ctx.atomText(m.name), "LevelThree")) {
            lt_bit = m.mapping;
            break;
        }
    }
    try std.testing.expect(lt_bit != 0);
    for (km.types) |t| {
        if (std.mem.eql(u8, ctx.atomText(t.name), "FOUR_LEVEL")) {
            if ((t.mods & lt_bit) != 0) four_level_has_lt = true;
            break;
        }
    }
    try std.testing.expect(four_level_has_lt);
    // Pressing RALT (vmodmap binding) must reach level 3 on AD01.
    const st = try State.create(km);
    defer st.destroy();
    try std.testing.expectEqual(keysym_lib.fromName("q", .{}).?, st.keyGetOneSym(24));
    _ = try st.updateKey(108, .down);
    try std.testing.expectEqual(keysym_lib.fromName("eacute", .{}).?, st.keyGetOneSym(24));
}

test "getAsString round-trips through the compiler" {
    const keysym_lib = @import("keysym.zig");
    const State = @import("state.zig").State;
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { minimum=8; maximum=255; <AE01> = 10; <LFSH> = 50; };
        \\  xkb_types "t" { type "TWO_LEVEL" { modifiers=Shift; map[Shift]=Level2; }; };
        \\  xkb_compat "c" {};
        \\  xkb_symbols "s" { key <AE01> { type="TWO_LEVEL", [ 1, exclam ] }; key <LFSH> { [ Shift_L ] }; modifier_map Shift { <LFSH> }; };
        \\};
    ;
    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();
    const text = try km.getAsString(.text_v1);
    defer std.testing.allocator.free(text);
    const km2 = try Keymap.newFromString(ctx, text, .text_v1);
    defer km2.destroy();
    // Assert equivalence: <AE01>=10 present with '1' at level0; Shift modmap on <LFSH>=50.
    try std.testing.expectEqualStrings("AE01", ctx.atomText(km2.keys[10].name));
    try std.testing.expectEqual(keysym_lib.fromName("1", .{}).?, km2.keys[10].groups[0].levels[0].syms[0]);
    try std.testing.expect((km2.keys[50].modmap & 0x1) != 0);
    // level 1 via a State with Shift:
    const st = try State.create(km2);
    defer st.destroy();
    _ = st.updateMask(0x1, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(keysym_lib.fromName("exclam", .{}).?, st.keyGetOneSym(10));
}

test "geometry: compiles, serializes, and round-trips" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { <AE01>=10; };
        \\  xkb_types "t" {};
        \\  xkb_compat "c" {};
        \\  xkb_symbols "s" { key <AE01> { [1] }; };
        \\  xkb_geometry "g" {
        \\    width=470; height=460;
        \\    shape "KEYCAP" { { [16,16], [2,2] } };
        \\    section "main" { row { keys { { name=<AE01> } }; }; };
        \\    solid "GreyStuff" { };
        \\  };
        \\};
    ;

    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    // Geometry must be compiled.
    try std.testing.expect(km.geometry != null);
    const geom = km.geometry.?;
    try std.testing.expectEqualStrings("g", ctx.atomText(geom.name));
    try std.testing.expectEqual(@as(i32, 470), geom.width_mm);
    try std.testing.expectEqual(@as(i32, 460), geom.height_mm);
    try std.testing.expectEqual(@as(usize, 1), geom.shapes.len);
    try std.testing.expectEqualStrings("KEYCAP", ctx.atomText(geom.shapes[0].name));
    try std.testing.expectEqual(@as(usize, 1), geom.shapes[0].outlines.len);
    try std.testing.expectEqual(@as(usize, 2), geom.shapes[0].outlines[0].points.len);
    try std.testing.expectEqual(@as(usize, 1), geom.sections.len);
    try std.testing.expectEqualStrings("main", ctx.atomText(geom.sections[0].name));
    try std.testing.expectEqual(@as(usize, 1), geom.sections[0].rows.len);
    try std.testing.expectEqual(@as(usize, 1), geom.sections[0].rows[0].keys.len);
    try std.testing.expectEqualStrings("AE01", ctx.atomText(geom.sections[0].rows[0].keys[0].name));
    try std.testing.expectEqual(@as(usize, 1), geom.doodads.len);
    try std.testing.expectEqualStrings("GreyStuff", ctx.atomText(geom.doodads[0].name));
    try std.testing.expect(geom.doodads[0].kind == .solid);

    // Serialize: output must contain geometry markers.
    const text = try km.getAsString(.text_v1);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "xkb_geometry") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "shape \"KEYCAP\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "section \"main\"") != null);

    // Round-trip: parse the serialized form and geometry must survive.
    const km2 = try Keymap.newFromString(ctx, text, .text_v1);
    defer km2.destroy();
    try std.testing.expect(km2.geometry != null);
    try std.testing.expectEqual(@as(usize, 1), km2.geometry.?.shapes.len);
    try std.testing.expectEqualStrings("KEYCAP", ctx.atomText(km2.geometry.?.shapes[0].name));
    try std.testing.expectEqual(@as(usize, 1), km2.geometry.?.sections.len);
    try std.testing.expectEqualStrings("main", ctx.atomText(km2.geometry.?.sections[0].name));
}

test "geometry: keymap without geometry has null geometry field" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { <AE01>=10; };
        \\  xkb_types "t" {};
        \\  xkb_compat "c" {};
        \\  xkb_symbols "s" { key <AE01> { [1] }; };
        \\};
    ;
    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();
    try std.testing.expect(km.geometry == null);

    // Serialized output must NOT contain xkb_geometry.
    const text = try km.getAsString(.text_v1);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "xkb_geometry") == null);
}

test "LED round-trip: whichModState=locked compiles, serializes, and re-compiles" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { minimum=8; maximum=255; <CAPS>=66; };
        \\  xkb_types "t" { type "ONE_LEVEL" { modifiers=none; }; };
        \\  xkb_compat "c" {
        \\    indicator "Caps Lock" { whichModState=locked; modifiers=Lock; };
        \\  };
        \\  xkb_symbols "s" { key <CAPS> { [ Caps_Lock ] }; };
        \\};
    ;

    // First compile.
    const km1 = try Keymap.newFromString(ctx, src, .text_v1);
    defer km1.destroy();

    // Verify which_mods is populated and mods==Lock.
    var found = false;
    for (km1.leds) |led| {
        if (led.name == .none) continue;
        if (std.mem.eql(u8, ctx.atomText(led.name), "Caps Lock")) {
            try std.testing.expect(led.which_mods.modifiers or led.which_mods.groups);
            try std.testing.expectEqual(@as(ModMask, 0x2), led.mods); // Lock
            found = true;
        }
    }
    try std.testing.expect(found);

    // Serialize.
    const text = try km1.getAsString(.text_v1);
    defer std.testing.allocator.free(text);

    // Serialized text must contain whichModState and modifiers.
    try std.testing.expect(std.mem.indexOf(u8, text, "whichModState") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "modifiers") != null);

    // Second compile from the serialized text.
    const km2 = try Keymap.newFromString(ctx, text, .text_v1);
    defer km2.destroy();

    // Verify which_mods survives the round-trip.
    var found2 = false;
    for (km2.leds) |led| {
        if (led.name == .none) continue;
        if (std.mem.eql(u8, ctx.atomText(led.name), "Caps Lock")) {
            try std.testing.expect(led.which_mods.modifiers or led.which_mods.groups);
            try std.testing.expectEqual(@as(ModMask, 0x2), led.mods);
            found2 = true;
        }
    }
    try std.testing.expect(found2);
}
