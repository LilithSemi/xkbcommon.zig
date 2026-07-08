/// compile_link.zig: finalize per-section infos into a Keymap.
const std = @import("std");
const keymap = @import("../keymap.zig");
const Context = @import("../context.zig").Context;
const Atom = @import("../context.zig").Atom;
const Keysym = @import("../keysym.zig").Keysym;
const compile_keycodes = @import("compile_keycodes.zig");
const compile_compat = @import("compile_compat.zig");
const compile_symbols = @import("compile_symbols.zig");
const mods_lib = @import("mods.zig");

const real_mod_names = [_][]const u8{
    "Shift", "Lock", "Control", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5",
};
const real_mod_masks = [_]keymap.ModMask{ 0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80 };

/// Finalize section infos into km. Slices in types/compat/symbols must stay alive until km is destroyed.
pub fn link(
    km: *keymap.Keymap,
    keycodes: compile_keycodes.KeyNamesInfo,
    types: []keymap.KeyType,
    compat: compile_compat.CompatInfo,
    symbols: compile_symbols.SymbolsInfo,
    vmods: ?*const mods_lib.VirtualMods,
) !void {
    const arena = km.arena.allocator();

    // ModSet: 8 real mods plus any virtual mods from the vmod table.
    {
        const vmod_count: usize = if (vmods) |vm| vm.count() else 0;
        const mods = try arena.alloc(keymap.Mod, real_mod_names.len + vmod_count);
        for (real_mod_names, real_mod_masks, 0..) |name, mask, i| {
            mods[i] = .{
                .name = try km.ctx.intern(name),
                .type = .real,
                .mapping = mask,
            };
        }
        if (vmods) |vm| {
            for (vm.names.items, 0..) |vname, i| {
                const idx: keymap.ModIndex = @as(keymap.ModIndex, 8) + @as(keymap.ModIndex, @intCast(i));
                mods[real_mod_names.len + i] = .{
                    .name = try km.ctx.intern(vname),
                    .type = .virt,
                    .mapping = mods_lib.modIndexMask(idx),
                };
            }
        }
        km.mods = .{ .mods = mods };
    }

    km.types = types;

    km.sym_interprets = compat.interprets;
    km.leds = compat.leds;

    // Build keys[]. Level.syms are copied into km.arena so keys are self-contained after link() returns.
    {
        // Cast to usize before +1 to prevent u32 wrapping.
        const keys = try arena.alloc(keymap.Key, @as(usize, keycodes.max) + 1);
        for (keys) |*k| {
            k.* = keymap.Key{
                .name = .none,
                .keycode = 0,
                .repeats = false,
                .modmap = 0,
                .out_of_range_group_action = .wrap,
                .out_of_range_group_number = 0,
                .groups = &.{},
            };
        }

        for (keycodes.names, 0..) |name, kc| {
            if (name == .none) continue;
            if (kc >= keys.len) continue;

            keys[kc].name = name;
            keys[kc].keycode = @intCast(kc);

            if (findKeyInfo(symbols.keys, name)) |ki| {
                keys[kc].modmap = ki.modmap;
                keys[kc].repeats = ki.repeat orelse false;
                keys[kc].out_of_range_group_action = ki.out_of_range_action;

                const groups = try arena.alloc(keymap.Group, ki.groups.len);
                for (ki.groups, 0..) |gi, g_idx| {
                    const type_idx = resolveType(types, km.ctx, gi);
                    const levels = try arena.alloc(keymap.Level, gi.levels.len);
                    for (gi.levels, 0..) |li, l_idx| {
                        const syms = try arena.dupe(Keysym, li.syms);
                        levels[l_idx] = .{ .action = li.action, .syms = syms };
                    }
                    groups[g_idx] = .{
                        .explicit_type = gi.type_name != null,
                        .type_index = type_idx,
                        .levels = levels,
                    };
                }
                keys[kc].groups = groups;
            }
        }

        km.keys = keys;
    }

    // Compat pass: apply sym_interprets to levels with no explicit action and exactly one sym.
    for (km.keys) |*key| {
        if (key.name == .none) continue;
        for (key.groups) |*group| {
            for (group.levels, 0..) |*level, l_idx| {
                if (std.meta.activeTag(level.action) != .none) continue;
                if (level.syms.len != 1) continue;
                const sym = level.syms[0];
                if (findMatchingInterpret(km.sym_interprets, sym, key.modmap, l_idx)) |interp| {
                    level.action = interp.action;
                    // only propagate repeat when the key did not set it explicitly
                    if (interp.repeat) {
                        if (findKeyInfo(symbols.keys, key.name)) |ki| {
                            if (ki.repeat == null) key.repeats = true;
                        } else {
                            key.repeats = true;
                        }
                    }
                }
            }
        }
    }

    km.key_aliases = keycodes.aliases;
    km.group_names = symbols.group_names;
    km.min_key_code = keycodes.min;
    km.max_key_code = keycodes.max;
}

/// Look up a Key by atom name.
pub fn keyByName(km: *keymap.Keymap, name: Atom) ?*keymap.Key {
    for (km.keys) |*k| {
        if (k.name == name) return k;
    }
    return null;
}

fn findKeyInfo(keys: []compile_symbols.KeyInfo, name: Atom) ?compile_symbols.KeyInfo {
    for (keys) |ki| {
        if (ki.name == name) return ki;
    }
    return null;
}

fn resolveType(types: []keymap.KeyType, ctx: *Context, gi: compile_symbols.GroupInfo) u32 {
    if (gi.type_name) |name_atom| {
        const name_text = ctx.atomText(name_atom);
        for (types, 0..) |t, i| {
            if (std.ascii.eqlIgnoreCase(ctx.atomText(t.name), name_text)) {
                return @intCast(i);
            }
        }
    } else {
        // pick canonical type by level count so all levels stay reachable
        const canonical: []const u8 = switch (gi.levels.len) {
            0, 1 => "ONE_LEVEL",
            2 => "TWO_LEVEL",
            3, 4 => "FOUR_LEVEL",
            else => "ONE_LEVEL",
        };
        for (types, 0..) |t, i| {
            if (std.ascii.eqlIgnoreCase(ctx.atomText(t.name), canonical)) {
                return @intCast(i);
            }
        }
        // fallback: any type whose num_levels covers the group
        for (types, 0..) |t, i| {
            if (t.num_levels >= gi.levels.len) {
                return @intCast(i);
            }
        }
    }
    return 0;
}

/// Evaluate the mod predicate for an interpret. Compares interp.mods against the key's real-modifier map.
fn interpModPred(match: keymap.MatchOp, interp_mods: keymap.ModMask, key_modmap: keymap.ModMask) bool {
    return switch (match) {
        .none => false,
        .any_of_or_none => key_modmap == 0 or (key_modmap & interp_mods) != 0,
        .none_of => (key_modmap & interp_mods) == 0,
        .any_of => (key_modmap & interp_mods) != 0,
        .all_of => (key_modmap & interp_mods) == interp_mods,
        .exactly => key_modmap == interp_mods,
    };
}

/// Find the best-matching SymInterpret for a keysym at a given level index.
/// Rules:
///   - sym must match the level's keysym (or interp.sym == null for wildcard).
///   - The mod predicate must pass (interpModPred).
///   - An interpret with level_one_only=true is skipped for level_idx > 0.
///   - A specific-sym match beats a wildcard match; among equals the first wins.
fn findMatchingInterpret(
    interprets: []keymap.SymInterpret,
    sym: Keysym,
    modmap: keymap.ModMask,
    level_idx: usize,
) ?keymap.SymInterpret {
    var wildcard: ?keymap.SymInterpret = null;
    for (interprets) |interp| {
        if (interp.level_one_only and level_idx > 0) continue;
        const sym_ok = if (interp.sym) |isym| isym == sym else true;
        if (!sym_ok) continue;
        if (!interpModPred(interp.match, interp.mods, modmap)) continue;
        if (interp.sym != null) return interp;
        if (wildcard == null) wildcard = interp;
    }
    return wildcard;
}

test "compile_link: keys, groups, syms, mods, compat pass, keyByName" {
    const io = std.testing.io;
    const ctx = try Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const compile_types = @import("compile_types.zig");
    const keysym_lib = @import("../keysym.zig");

    // Arena for all section infos; must outlive km.
    var info_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer info_arena.deinit();
    const ia = info_arena.allocator();

    const kc_src =
        \\xkb_keycodes "k" {
        \\  minimum=8;
        \\  maximum=255;
        \\  <AE01>=10;
        \\  <CAPS>=66;
        \\};
    ;
    var lx_kc = Lexer.init(std.testing.allocator, kc_src);
    defer lx_kc.deinit();
    var p_kc = Parser.init(std.testing.allocator, &lx_kc);
    defer p_kc.deinit();
    const xf_kc = try p_kc.parseFile();
    const kc_info = try compile_keycodes.compileKeycodes(ia, ctx, &xf_kc.components[0], null);

    const ty_src = "xkb_types \"t\" { };";
    var lx_ty = Lexer.init(std.testing.allocator, ty_src);
    defer lx_ty.deinit();
    var p_ty = Parser.init(std.testing.allocator, &lx_ty);
    defer p_ty.deinit();
    const xf_ty = try p_ty.parseFile();
    const types = try compile_types.compileTypes(ia, ctx, &xf_ty.components[0], null, null);

    const compat_src =
        \\xkb_compat "c" {
        \\  interpret Caps_Lock { action=LockMods(modifiers=Lock); };
        \\};
    ;
    var lx_cp = Lexer.init(std.testing.allocator, compat_src);
    defer lx_cp.deinit();
    var p_cp = Parser.init(std.testing.allocator, &lx_cp);
    defer p_cp.deinit();
    const xf_cp = try p_cp.parseFile();
    const compat_info = try compile_compat.compileCompat(ia, ctx, &xf_cp.components[0], null, null);

    const sym_src =
        \\xkb_symbols "s" {
        \\  key <AE01> { [ 1, exclam ] };
        \\  key <CAPS> { [ Caps_Lock ] };
        \\};
    ;
    var lx_sy = Lexer.init(std.testing.allocator, sym_src);
    defer lx_sy.deinit();
    var p_sy = Parser.init(std.testing.allocator, &lx_sy);
    defer p_sy.deinit();
    const xf_sy = try p_sy.parseFile();
    const sym_info = try compile_symbols.compileSymbols(ia, ctx, &xf_sy.components[0], null, null);

    const km = try keymap.Keymap.create(ctx);
    defer km.destroy();
    try link(km, kc_info, types, compat_info, sym_info, null);

    const ae01_atom = try ctx.intern("AE01");

    // keys[10] name and first sym.
    try std.testing.expectEqual(ae01_atom, km.keys[10].name);
    try std.testing.expectEqual(@as(usize, 1), km.keys[10].groups.len);
    try std.testing.expectEqual(
        keysym_lib.fromName("1", .{}),
        km.keys[10].groups[0].levels[0].syms[0],
    );

    // ModSet: at least 8 real mods.
    try std.testing.expect(km.mods.mods.len >= 8);
    try std.testing.expectEqualStrings("Shift", ctx.atomText(km.mods.mods[0].name));
    try std.testing.expectEqual(keymap.ModType.real, km.mods.mods[0].type);
    try std.testing.expectEqual(@as(keymap.ModMask, 0x1), km.mods.mods[0].mapping);

    // keyByName lookup.
    const found = keyByName(km, ae01_atom);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(keymap.Keycode, 10), found.?.keycode);

    // min/max.
    try std.testing.expectEqual(@as(keymap.Keycode, 8), km.min_key_code);
    try std.testing.expectEqual(@as(keymap.Keycode, 255), km.max_key_code);

    // Compat pass: CAPS (kc=66) gets LockMods action from the Caps_Lock interpret.
    const caps_key = &km.keys[66];
    try std.testing.expectEqual(@as(usize, 1), caps_key.groups.len);
    try std.testing.expectEqual(@as(usize, 1), caps_key.groups[0].levels.len);
    const caps_action = caps_key.groups[0].levels[0].action;
    try std.testing.expectEqual(std.meta.Tag(keymap.Action).mods, std.meta.activeTag(caps_action));
    try std.testing.expect(caps_action.mods.kind == .lock);
}

test "compile_link fix3: 4-symbol group resolves to type with num_levels >= 4" {
    const io = std.testing.io;
    const ctx = try Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const compile_types = @import("compile_types.zig");

    var info_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer info_arena.deinit();
    const ia = info_arena.allocator();

    const kc_src = "xkb_keycodes \"k\" { minimum=8; maximum=255; <AD01>=38; };";
    var lx_kc = Lexer.init(std.testing.allocator, kc_src);
    defer lx_kc.deinit();
    var p_kc = Parser.init(std.testing.allocator, &lx_kc);
    defer p_kc.deinit();
    const xf_kc = try p_kc.parseFile();
    const kc_info = try compile_keycodes.compileKeycodes(ia, ctx, &xf_kc.components[0], null);

    const ty_src = "xkb_types \"t\" { };";
    var lx_ty = Lexer.init(std.testing.allocator, ty_src);
    defer lx_ty.deinit();
    var p_ty = Parser.init(std.testing.allocator, &lx_ty);
    defer p_ty.deinit();
    const xf_ty = try p_ty.parseFile();
    const types = try compile_types.compileTypes(ia, ctx, &xf_ty.components[0], null, null);

    const compat_src = "xkb_compat \"c\" { };";
    var lx_cp = Lexer.init(std.testing.allocator, compat_src);
    defer lx_cp.deinit();
    var p_cp = Parser.init(std.testing.allocator, &lx_cp);
    defer p_cp.deinit();
    const xf_cp = try p_cp.parseFile();
    const compat_info = try compile_compat.compileCompat(ia, ctx, &xf_cp.components[0], null, null);

    // Key with 4 symbols and no explicit type.
    const sym_src =
        \\xkb_symbols "s" {
        \\  key <AD01> { [ a, A, b, B ] };
        \\};
    ;
    var lx_sy = Lexer.init(std.testing.allocator, sym_src);
    defer lx_sy.deinit();
    var p_sy = Parser.init(std.testing.allocator, &lx_sy);
    defer p_sy.deinit();
    const xf_sy = try p_sy.parseFile();
    const sym_info = try compile_symbols.compileSymbols(ia, ctx, &xf_sy.components[0], null, null);

    const km = try keymap.Keymap.create(ctx);
    defer km.destroy();
    try link(km, kc_info, types, compat_info, sym_info, null);

    const key = &km.keys[38];
    try std.testing.expectEqual(@as(usize, 1), key.groups.len);
    try std.testing.expectEqual(@as(usize, 4), key.groups[0].levels.len);
    const type_idx = key.groups[0].type_index;
    try std.testing.expect(km.types[type_idx].num_levels >= 4);
}

test "compile_link fix5: explicit repeat=false not overridden by compat interp" {
    const io = std.testing.io;
    const ctx = try Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const compile_types = @import("compile_types.zig");
    const keysym_lib = @import("../keysym.zig");
    _ = keysym_lib;

    var info_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer info_arena.deinit();
    const ia = info_arena.allocator();

    const kc_src = "xkb_keycodes \"k\" { minimum=8; maximum=255; <CAPS>=66; };";
    var lx_kc = Lexer.init(std.testing.allocator, kc_src);
    defer lx_kc.deinit();
    var p_kc = Parser.init(std.testing.allocator, &lx_kc);
    defer p_kc.deinit();
    const xf_kc = try p_kc.parseFile();
    const kc_info = try compile_keycodes.compileKeycodes(ia, ctx, &xf_kc.components[0], null);

    const ty_src = "xkb_types \"t\" { };";
    var lx_ty = Lexer.init(std.testing.allocator, ty_src);
    defer lx_ty.deinit();
    var p_ty = Parser.init(std.testing.allocator, &lx_ty);
    defer p_ty.deinit();
    const xf_ty = try p_ty.parseFile();
    const types = try compile_types.compileTypes(ia, ctx, &xf_ty.components[0], null, null);

    // Interpret for Caps_Lock with repeat=true (the default).
    const compat_src =
        \\xkb_compat "c" {
        \\  interpret Caps_Lock { repeat=true; action=LockMods(modifiers=Lock); };
        \\};
    ;
    var lx_cp = Lexer.init(std.testing.allocator, compat_src);
    defer lx_cp.deinit();
    var p_cp = Parser.init(std.testing.allocator, &lx_cp);
    defer p_cp.deinit();
    const xf_cp = try p_cp.parseFile();
    const compat_info = try compile_compat.compileCompat(ia, ctx, &xf_cp.components[0], null, null);

    // Key explicitly sets repeat=no (evaluates to false in handleKeyAssign).
    // Key body items are comma-separated, not semicolon-separated.
    const sym_src =
        \\xkb_symbols "s" {
        \\  key <CAPS> { repeat=no, [ Caps_Lock ] };
        \\};
    ;
    var lx_sy = Lexer.init(std.testing.allocator, sym_src);
    defer lx_sy.deinit();
    var p_sy = Parser.init(std.testing.allocator, &lx_sy);
    defer p_sy.deinit();
    const xf_sy = try p_sy.parseFile();
    const sym_info = try compile_symbols.compileSymbols(ia, ctx, &xf_sy.components[0], null, null);

    const km = try keymap.Keymap.create(ctx);
    defer km.destroy();
    try link(km, kc_info, types, compat_info, sym_info, null);

    // repeat=false was explicit; the compat interp must not override it.
    try std.testing.expectEqual(false, km.keys[66].repeats);
}

test "compile_link: exactly predicate matches only the correct modmap" {
    // An interpret with Exactly(Shift) must match a key whose modmap is Shift (0x1),
    // and an interpret with Exactly(Control) must NOT match that same key.
    // We verify by placing Exactly(Control) first in the list so the predicate
    // rejection is the only reason it is skipped.
    const io = std.testing.io;
    const ctx = try Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const compile_types = @import("compile_types.zig");

    var info_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer info_arena.deinit();
    const ia = info_arena.allocator();

    // AD01 = keycode 38.
    const kc_src = "xkb_keycodes \"k\" { minimum=8; maximum=255; <AD01>=38; };";
    var lx_kc = Lexer.init(std.testing.allocator, kc_src);
    defer lx_kc.deinit();
    var p_kc = Parser.init(std.testing.allocator, &lx_kc);
    defer p_kc.deinit();
    const xf_kc = try p_kc.parseFile();
    const kc_info = try compile_keycodes.compileKeycodes(ia, ctx, &xf_kc.components[0], null);

    const ty_src = "xkb_types \"t\" { };";
    var lx_ty = Lexer.init(std.testing.allocator, ty_src);
    defer lx_ty.deinit();
    var p_ty = Parser.init(std.testing.allocator, &lx_ty);
    defer p_ty.deinit();
    const xf_ty = try p_ty.parseFile();
    const types = try compile_types.compileTypes(ia, ctx, &xf_ty.components[0], null, null);

    // Two interprets for 'a': Exactly(Control) is listed first but must not fire because AD01 has Shift in its modmap. Exactly(Shift) must win.
    const compat_src =
        \\xkb_compat "c" {
        \\  interpret a+Exactly(Control) { action=LockMods(modifiers=Lock); };
        \\  interpret a+Exactly(Shift)   { action=SetMods(modifiers=Shift); };
        \\};
    ;
    var lx_cp = Lexer.init(std.testing.allocator, compat_src);
    defer lx_cp.deinit();
    var p_cp = Parser.init(std.testing.allocator, &lx_cp);
    defer p_cp.deinit();
    const xf_cp = try p_cp.parseFile();
    const compat_info = try compile_compat.compileCompat(ia, ctx, &xf_cp.components[0], null, null);

    // AD01 maps to `a` and has Shift in its modifier_map -> modmap = 0x1.
    const sym_src =
        \\xkb_symbols "s" {
        \\  key <AD01> { [ a ] };
        \\  modifier_map Shift { <AD01> };
        \\};
    ;
    var lx_sy = Lexer.init(std.testing.allocator, sym_src);
    defer lx_sy.deinit();
    var p_sy = Parser.init(std.testing.allocator, &lx_sy);
    defer p_sy.deinit();
    const xf_sy = try p_sy.parseFile();
    const sym_info = try compile_symbols.compileSymbols(ia, ctx, &xf_sy.components[0], null, null);

    const km = try keymap.Keymap.create(ctx);
    defer km.destroy();
    try link(km, kc_info, types, compat_info, sym_info, null);

    // AD01 (kc=38) must have gotten SetMods(Shift), NOT LockMods from the Control interpret.
    const ad01 = &km.keys[38];
    try std.testing.expectEqual(@as(usize, 1), ad01.groups.len);
    try std.testing.expectEqual(@as(usize, 1), ad01.groups[0].levels.len);
    const action = ad01.groups[0].levels[0].action;
    try std.testing.expectEqual(std.meta.Tag(keymap.Action).mods, std.meta.activeTag(action));
    // Must be set (not lock) confirming Exactly(Shift) matched and Exactly(Control) did not.
    try std.testing.expect(action.mods.kind == .set);
}

test "compile_link: level_one_only skips higher levels" {
    // An interpret with level_one_only=true must only fire at level index 0.
    // A key with two levels and the same sym at each level should only get the
    // action on level 0; level 1 must remain .none.
    const io = std.testing.io;
    const ctx = try Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const compile_types = @import("compile_types.zig");

    var info_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer info_arena.deinit();
    const ia = info_arena.allocator();

    const kc_src = "xkb_keycodes \"k\" { minimum=8; maximum=255; <CAPS>=66; };";
    var lx_kc = Lexer.init(std.testing.allocator, kc_src);
    defer lx_kc.deinit();
    var p_kc = Parser.init(std.testing.allocator, &lx_kc);
    defer p_kc.deinit();
    const xf_kc = try p_kc.parseFile();
    const kc_info = try compile_keycodes.compileKeycodes(ia, ctx, &xf_kc.components[0], null);

    const ty_src = "xkb_types \"t\" { };";
    var lx_ty = Lexer.init(std.testing.allocator, ty_src);
    defer lx_ty.deinit();
    var p_ty = Parser.init(std.testing.allocator, &lx_ty);
    defer p_ty.deinit();
    const xf_ty = try p_ty.parseFile();
    const types = try compile_types.compileTypes(ia, ctx, &xf_ty.components[0], null, null);

    // Interpret with level_one_only=true: must only fire at level 0.
    const compat_src =
        \\xkb_compat "c" {
        \\  interpret Caps_Lock { level_one_only=true; action=LockMods(modifiers=Lock); };
        \\};
    ;
    var lx_cp = Lexer.init(std.testing.allocator, compat_src);
    defer lx_cp.deinit();
    var p_cp = Parser.init(std.testing.allocator, &lx_cp);
    defer p_cp.deinit();
    const xf_cp = try p_cp.parseFile();
    const compat_info = try compile_compat.compileCompat(ia, ctx, &xf_cp.components[0], null, null);

    // CAPS has two levels, both with Caps_Lock sym.
    const sym_src =
        \\xkb_symbols "s" {
        \\  key <CAPS> { [ Caps_Lock, Caps_Lock ] };
        \\};
    ;
    var lx_sy = Lexer.init(std.testing.allocator, sym_src);
    defer lx_sy.deinit();
    var p_sy = Parser.init(std.testing.allocator, &lx_sy);
    defer p_sy.deinit();
    const xf_sy = try p_sy.parseFile();
    const sym_info = try compile_symbols.compileSymbols(ia, ctx, &xf_sy.components[0], null, null);

    const km = try keymap.Keymap.create(ctx);
    defer km.destroy();
    try link(km, kc_info, types, compat_info, sym_info, null);

    const caps = &km.keys[66];
    try std.testing.expectEqual(@as(usize, 1), caps.groups.len);
    try std.testing.expectEqual(@as(usize, 2), caps.groups[0].levels.len);
    // Level 0: interpret applied -> LockMods.
    const lvl0_action = caps.groups[0].levels[0].action;
    try std.testing.expectEqual(std.meta.Tag(keymap.Action).mods, std.meta.activeTag(lvl0_action));
    try std.testing.expect(lvl0_action.mods.kind == .lock);
    // Level 1: interpret skipped due to level_one_only -> action remains .none.
    const lvl1_action = caps.groups[0].levels[1].action;
    try std.testing.expectEqual(std.meta.Tag(keymap.Action).none, std.meta.activeTag(lvl1_action));
}
