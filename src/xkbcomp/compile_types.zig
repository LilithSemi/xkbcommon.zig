/// compile_types.zig: compile a types section to []keymap.KeyType, injecting canonical built-in types.
const std = @import("std");
const keymap = @import("../keymap.zig");
const ast = @import("ast.zig");
const Context = @import("../context.zig").Context;
const Atom = @import("../context.zig").Atom;
const action_lib = @import("action.zig");
const include = @import("include.zig");
const mods_lib = @import("mods.zig");

const KeyType = keymap.KeyType;
const ModMask = keymap.ModMask;
const LevelIndex = keymap.LevelIndex;

/// Parse a level expression. "Level1"/1 maps to 0, "Level2"/2 maps to 1, etc.
fn parseLevelExpr(expr: *const ast.Expr) ?LevelIndex {
    switch (expr.*) {
        .ident => |name| {
            if (name.len >= 6) {
                var prefix_buf: [5]u8 = undefined;
                const prefix = std.ascii.lowerString(&prefix_buf, name[0..5]);
                if (std.mem.eql(u8, prefix, "level")) {
                    const n = std.fmt.parseInt(u32, name[5..], 10) catch return null;
                    if (n == 0) return null;
                    return n - 1;
                }
            }
            return null;
        },
        .integer => |v| {
            if (v <= 0) return null;
            return @as(LevelIndex, @intCast(v)) - 1;
        },
        else => return null,
    }
}

/// Compile a types Component to KeyType values. Appends missing canonical built-ins afterward.
pub fn compileTypes(
    arena: std.mem.Allocator,
    ctx: *Context,
    comp: *ast.Component,
    resolver: ?*include.Resolver,
    vmods: ?*const mods_lib.VirtualMods,
) ![]KeyType {
    var types: std.ArrayList(KeyType) = .empty;

    for (comp.decls) |decl| {
        switch (decl) {
            .key_type => |kt| {
                const name_atom = try ctx.intern(kt.name);

                var type_mods: ModMask = 0;
                var entries: std.ArrayList(KeyType.Entry) = .empty;
                // level->atom pairs packed into level_names after the body loop
                var lvl_names_tmp: std.ArrayList(struct { level: LevelIndex, atom: Atom }) = .empty;
                var max_level: LevelIndex = 0;

                for (kt.body) |vd| {
                    const name_expr = vd.name;
                    const value_expr = vd.value orelse continue;

                    switch (name_expr.*) {
                        .ident => |fname| {
                            if (std.ascii.eqlIgnoreCase(fname, "modifiers")) {
                                type_mods = action_lib.resolveModMask(value_expr, vmods);
                            }
                        },
                        .array_ref => |aref| {
                            const base_ident = switch (aref.base.*) {
                                .ident => |n| n,
                                else => continue,
                            };
                            const idx_expr = aref.index orelse continue;

                            if (std.ascii.eqlIgnoreCase(base_ident, "map")) {
                                const combo_mask = action_lib.resolveModMask(idx_expr, vmods);
                                const level = parseLevelExpr(value_expr) orelse continue;
                                if (level > max_level) max_level = level;
                                var found = false;
                                for (entries.items) |*e| {
                                    if (e.mods == combo_mask) {
                                        e.level = level;
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    try entries.append(arena, .{
                                        .mods = combo_mask,
                                        .level = level,
                                        .preserve = 0,
                                    });
                                }
                            } else if (std.ascii.eqlIgnoreCase(base_ident, "level_name")) {
                                const level = parseLevelExpr(idx_expr) orelse continue;
                                if (level > max_level) max_level = level;
                                const atom: Atom = switch (value_expr.*) {
                                    .string => |s| try ctx.intern(s),
                                    .ident => |s| try ctx.intern(s),
                                    else => continue,
                                };
                                var found = false;
                                for (lvl_names_tmp.items) |*ln| {
                                    if (ln.level == level) {
                                        ln.atom = atom;
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    try lvl_names_tmp.append(arena, .{ .level = level, .atom = atom });
                                }
                            } else if (std.ascii.eqlIgnoreCase(base_ident, "preserve")) {
                                const combo_mask = action_lib.resolveModMask(idx_expr, vmods);
                                const preserve_mask = action_lib.resolveModMask(value_expr, vmods);
                                // set preserve on the matching entry; skip if absent
                                for (entries.items) |*e| {
                                    if (e.mods == combo_mask) {
                                        e.preserve = preserve_mask;
                                        break;
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }

                const num_levels = max_level + 1;
                const level_names = try arena.alloc(Atom, num_levels);
                @memset(level_names, .none);
                for (lvl_names_tmp.items) |ln| {
                    if (ln.level < num_levels) {
                        level_names[ln.level] = ln.atom;
                    }
                }

                try types.append(arena, .{
                    .name = name_atom,
                    .mods = type_mods,
                    .num_levels = num_levels,
                    .entries = try entries.toOwnedSlice(arena),
                    .level_names = level_names,
                });
            },
            .include => |inc| {
                if (resolver) |res| {
                    const comps = res.resolveSpec(.types, inc.path) catch |e| {
                        ctx.log(.warning, "failed to resolve types include \"{s}\": {s}", .{ inc.path, @errorName(e) });
                        continue;
                    };
                    defer res.alloc.free(comps);

                    for (comps) |inc_comp| {
                        const inc_types = try compileTypes(arena, ctx, inc_comp, resolver, vmods);
                        // append types not already present by name (first wins)
                        for (inc_types) |it| {
                            var already_present = false;
                            for (types.items) |existing| {
                                if (existing.name == it.name) {
                                    already_present = true;
                                    break;
                                }
                            }
                            if (!already_present) {
                                try types.append(arena, it);
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    try injectBuiltins(arena, ctx, &types, vmods);

    return types.toOwnedSlice(arena);
}

fn typePresent(types: *const std.ArrayList(KeyType), ctx: *Context, name: []const u8) bool {
    for (types.items) |t| {
        if (std.mem.eql(u8, ctx.atomText(t.name), name)) return true;
    }
    return false;
}

fn injectBuiltins(arena: std.mem.Allocator, ctx: *Context, types: *std.ArrayList(KeyType), vmods: ?*const mods_lib.VirtualMods) !void {
    if (!typePresent(types, ctx, "ONE_LEVEL")) {
        const level_names = try arena.alloc(Atom, 1);
        level_names[0] = try ctx.intern("Any");
        try types.append(arena, .{
            .name = try ctx.intern("ONE_LEVEL"),
            .mods = 0,
            .num_levels = 1,
            .entries = &.{},
            .level_names = level_names,
        });
    }

    if (!typePresent(types, ctx, "TWO_LEVEL")) {
        const entries = try arena.alloc(KeyType.Entry, 1);
        entries[0] = .{ .mods = 0x1, .level = 1, .preserve = 0 };
        const level_names = try arena.alloc(Atom, 2);
        level_names[0] = try ctx.intern("Base");
        level_names[1] = try ctx.intern("Shift");
        try types.append(arena, .{
            .name = try ctx.intern("TWO_LEVEL"),
            .mods = 0x1,
            .num_levels = 2,
            .entries = entries,
            .level_names = level_names,
        });
    }

    // Lock has preserve=Lock so caps-lock release restores the base level.
    if (!typePresent(types, ctx, "ALPHABETIC")) {
        const entries = try arena.alloc(KeyType.Entry, 2);
        entries[0] = .{ .mods = 0x1, .level = 1, .preserve = 0 };
        entries[1] = .{ .mods = 0x2, .level = 1, .preserve = 0x2 };
        const level_names = try arena.alloc(Atom, 2);
        level_names[0] = try ctx.intern("Base");
        level_names[1] = try ctx.intern("Caps");
        try types.append(arena, .{
            .name = try ctx.intern("ALPHABETIC"),
            .mods = 0x3,
            .num_levels = 2,
            .entries = entries,
            .level_names = level_names,
        });
    }

    // NumLock is a vmod resolved later; only Shift is used as a real-mod entry here.
    if (!typePresent(types, ctx, "KEYPAD")) {
        const entries = try arena.alloc(KeyType.Entry, 1);
        entries[0] = .{ .mods = 0x1, .level = 1, .preserve = 0 };
        const level_names = try arena.alloc(Atom, 2);
        level_names[0] = try ctx.intern("Base");
        level_names[1] = try ctx.intern("Number");
        try types.append(arena, .{
            .name = try ctx.intern("KEYPAD"),
            .mods = 0x1,
            .num_levels = 2,
            .entries = entries,
            .level_names = level_names,
        });
    }

    // FOUR_LEVEL: use Shift + LevelThree vmod when LevelThree is declared,
    // otherwise fall back to Shift-only (approximation for keymaps without LevelThree).
    if (!typePresent(types, ctx, "FOUR_LEVEL")) {
        const lt_idx = if (vmods) |vm| vm.lookup("LevelThree") else null;
        const level_names = try arena.alloc(Atom, 4);
        level_names[0] = try ctx.intern("Base");
        level_names[1] = try ctx.intern("Shift");
        level_names[2] = try ctx.intern("AltGr");
        level_names[3] = try ctx.intern("Shift AltGr");
        if (lt_idx) |idx| {
            const lt_bit = mods_lib.modIndexMask(idx);
            const entries = try arena.alloc(KeyType.Entry, 3);
            entries[0] = .{ .mods = 0x1, .level = 1, .preserve = 0 };
            entries[1] = .{ .mods = lt_bit, .level = 2, .preserve = 0 };
            entries[2] = .{ .mods = 0x1 | lt_bit, .level = 3, .preserve = 0 };
            try types.append(arena, .{
                .name = try ctx.intern("FOUR_LEVEL"),
                .mods = 0x1 | lt_bit,
                .num_levels = 4,
                .entries = entries,
                .level_names = level_names,
            });
        } else {
            const entries = try arena.alloc(KeyType.Entry, 1);
            entries[0] = .{ .mods = 0x1, .level = 1, .preserve = 0 };
            try types.append(arena, .{
                .name = try ctx.intern("FOUR_LEVEL"),
                .mods = 0x1,
                .num_levels = 4,
                .entries = entries,
                .level_names = level_names,
            });
        }
    }
}

test "compileTypes: two-level type + canonical injection" {
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

    const src =
        \\xkb_types "t" {
        \\  type "TWO" {
        \\    modifiers=Shift;
        \\    map[Shift]=Level2;
        \\    level_name[Level1]="Base";
        \\    level_name[Level2]="Shift";
        \\  };
        \\};
    ;

    var lx = Lexer.init(std.testing.allocator, src);
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const xf = try p.parseFile();
    const comp = &xf.components[0];

    var km_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer km_arena.deinit();
    const arena = km_arena.allocator();

    const types = try compileTypes(arena, ctx, comp, null, null);

    // Find the "TWO" type.
    var two: ?KeyType = null;
    for (types) |t| {
        if (std.mem.eql(u8, ctx.atomText(t.name), "TWO")) {
            two = t;
            break;
        }
    }
    try std.testing.expect(two != null);
    const t = two.?;
    try std.testing.expectEqual(@as(ModMask, 0x1), t.mods);
    try std.testing.expectEqual(@as(LevelIndex, 2), t.num_levels);
    try std.testing.expectEqual(@as(usize, 1), t.entries.len);
    try std.testing.expectEqual(@as(ModMask, 0x1), t.entries[0].mods);
    try std.testing.expectEqual(@as(LevelIndex, 1), t.entries[0].level);
    try std.testing.expectEqual(@as(usize, 2), t.level_names.len);
    try std.testing.expectEqualStrings("Base", ctx.atomText(t.level_names[0]));
    try std.testing.expectEqualStrings("Shift", ctx.atomText(t.level_names[1]));

    // Canonical ONE_LEVEL must be present in the result.
    var has_one_level = false;
    for (types) |ct| {
        if (std.mem.eql(u8, ctx.atomText(ct.name), "ONE_LEVEL")) {
            has_one_level = true;
            break;
        }
    }
    try std.testing.expect(has_one_level);
}
