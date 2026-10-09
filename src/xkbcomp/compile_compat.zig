/// compile_compat.zig: compile a compat section to CompatInfo.
const std = @import("std");
const keymap = @import("../keymap.zig");
const ast = @import("ast.zig");
const Context = @import("../context.zig").Context;
const action_lib = @import("action.zig");
const include = @import("include.zig");
const keysym_lib = @import("../keysym.zig");

const mods_lib = @import("mods.zig");
const ModMask = keymap.ModMask;
const ModIndex = keymap.ModIndex;
const mod_index_invalid = keymap.mod_index_invalid;
const SymInterpret = keymap.SymInterpret;
const Led = keymap.Led;
const MatchOp = keymap.MatchOp;

pub const CompatInfo = struct {
    interprets: []SymInterpret,
    leds: []Led,
    /// [0] unused; [1]..[4] for groups 1-4 (1-based indexing).
    group_compat: [5]?ModMask,
};

/// Extract a mod mask from the first argument of a match-op call.
/// e.g. AnyOf(all), NoneOf(Shift+Lock).
fn matchOpArgMods(args: []const ast.Expr, vmods: ?*const mods_lib.VirtualMods) ModMask {
    if (args.len == 0) return 0xff;
    const first = &args[0];
    const val: *const ast.Expr = switch (first.*) {
        .arg => |a| a.value,
        else => first,
    };
    return action_lib.resolveModMask(val, vmods);
}

/// Parse the optional match expression (the `+<expr>` predicate in an interp decl).
fn parseMatchExpr(expr: ?*const ast.Expr, vmods: ?*const mods_lib.VirtualMods) struct { op: MatchOp, mods: ModMask } {
    const e = expr orelse return .{ .op = .any_of_or_none, .mods = 0xff };
    switch (e.*) {
        .ident => |name| {
            if (std.ascii.eqlIgnoreCase(name, "any") or
                std.ascii.eqlIgnoreCase(name, "all"))
            {
                return .{ .op = .any_of_or_none, .mods = 0xff };
            }
            // bare mod name: match exactly
            return .{ .op = .exactly, .mods = action_lib.resolveModMask(e, vmods) };
        },
        .action => |act| {
            const mods = matchOpArgMods(act.args, vmods);
            if (std.ascii.eqlIgnoreCase(act.name, "AnyOfOrNone")) {
                return .{ .op = .any_of_or_none, .mods = mods };
            } else if (std.ascii.eqlIgnoreCase(act.name, "AnyOf")) {
                return .{ .op = .any_of, .mods = mods };
            } else if (std.ascii.eqlIgnoreCase(act.name, "NoneOf")) {
                return .{ .op = .none_of, .mods = mods };
            } else if (std.ascii.eqlIgnoreCase(act.name, "AllOf")) {
                return .{ .op = .all_of, .mods = mods };
            } else if (std.ascii.eqlIgnoreCase(act.name, "Exactly")) {
                return .{ .op = .exactly, .mods = mods };
            }
            return .{ .op = .exactly, .mods = mods };
        },
        .binary => return .{ .op = .exactly, .mods = action_lib.resolveModMask(e, vmods) },
        else => return .{ .op = .any_of_or_none, .mods = 0xff },
    }
}

/// Map an XKB state-component name to a LedWhich value.
/// Any recognised state sets the .modifiers bit; effective/any also sets .groups.
fn parseLedWhich(expr: *const ast.Expr) keymap.LedWhich {
    const name: []const u8 = switch (expr.*) {
        .ident => |n| n,
        else => return .{},
    };
    if (std.ascii.eqlIgnoreCase(name, "none")) return .{};
    if (std.ascii.eqlIgnoreCase(name, "effective") or
        std.ascii.eqlIgnoreCase(name, "any"))
    {
        return .{ .modifiers = true, .groups = true };
    }
    if (std.ascii.eqlIgnoreCase(name, "base") or
        std.ascii.eqlIgnoreCase(name, "depressed") or
        std.ascii.eqlIgnoreCase(name, "latched") or
        std.ascii.eqlIgnoreCase(name, "locked"))
    {
        return .{ .modifiers = true };
    }
    return .{};
}

fn parseLayoutMask(expr: *const ast.Expr) keymap.LayoutMask {
    return switch (expr.*) {
        .integer => |v| if (v >= 0 and v <= 0xffffffff) @intCast(v) else 0,
        else => 0,
    };
}

fn parseBool(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .boolean => |v| v,
        .ident => |name| std.ascii.eqlIgnoreCase(name, "true") or
            std.ascii.eqlIgnoreCase(name, "yes"),
        .integer => |v| v != 0,
        else => true,
    };
}

fn declFieldName(name_expr: *const ast.Expr) ?[]const u8 {
    return switch (name_expr.*) {
        .ident => |n| n,
        .field_ref => |n| n,
        else => null,
    };
}

pub fn compileCompat(
    arena: std.mem.Allocator,
    ctx: *Context,
    comp: *ast.Component,
    resolver: ?*include.Resolver,
    vmods: ?*const mods_lib.VirtualMods,
) !CompatInfo {
    var interprets: std.ArrayListUnmanaged(SymInterpret) = .empty;
    var leds: std.ArrayListUnmanaged(Led) = .empty;
    var group_compat: [5]?ModMask = @splat(null);

    for (comp.decls) |decl| {
        switch (decl) {
            .interp => |id| {
                const sym = if (std.ascii.eqlIgnoreCase(id.sym, "any"))
                    null
                else
                    keysym_lib.fromName(id.sym, .{});

                const match_res = parseMatchExpr(id.match, vmods);

                var action: keymap.Action = .none;
                var virtual_mod: ModIndex = mod_index_invalid;
                var repeat: bool = true;
                var level_one_only: bool = false;

                for (id.body) |vd| {
                    const value_expr = vd.value orelse continue;
                    const fname = declFieldName(vd.name) orelse continue;

                    if (std.ascii.eqlIgnoreCase(fname, "action")) {
                        action = try action_lib.compileAction(arena, ctx, value_expr, vmods);
                    } else if (std.ascii.eqlIgnoreCase(fname, "virtualModifier") or
                        std.ascii.eqlIgnoreCase(fname, "virtualmod"))
                    {
                        const vmod_name: []const u8 = switch (value_expr.*) {
                            .ident => |n| n,
                            else => continue,
                        };
                        if (vmods) |vm| {
                            if (vm.lookup(vmod_name)) |idx| {
                                virtual_mod = idx;
                            }
                        }
                    } else if (std.ascii.eqlIgnoreCase(fname, "repeat")) {
                        repeat = parseBool(value_expr);
                    } else if (std.ascii.eqlIgnoreCase(fname, "level_one_only") or
                        std.ascii.eqlIgnoreCase(fname, "leveloneonly"))
                    {
                        level_one_only = parseBool(value_expr);
                    } else if (std.ascii.eqlIgnoreCase(fname, "useModMapMods")) {
                        // accepted here to avoid unknown-field warnings; does not set level_one_only
                        _ = parseBool(value_expr);
                    }
                }

                try interprets.append(arena, .{
                    .sym = sym,
                    .match = match_res.op,
                    .mods = match_res.mods,
                    .virtual_mod = virtual_mod,
                    .action = action,
                    .level_one_only = level_one_only,
                    .repeat = repeat,
                });
            },

            .indicator_map => |im| {
                const name_atom = try ctx.intern(im.name);
                var mods: ModMask = 0;
                var groups: keymap.LayoutMask = 0;
                var ctrls: u32 = 0;
                var which_mods: keymap.LedWhich = .{};
                var which_groups: keymap.LedWhich = .{};

                for (im.body) |vd| {
                    const value_expr = vd.value orelse continue;
                    const fname = declFieldName(vd.name) orelse continue;
                    if (std.ascii.eqlIgnoreCase(fname, "modifiers") or
                        std.ascii.eqlIgnoreCase(fname, "mods"))
                    {
                        mods = action_lib.resolveModMask(value_expr, vmods);
                    } else if (std.ascii.eqlIgnoreCase(fname, "whichModState")) {
                        which_mods = parseLedWhich(value_expr);
                    } else if (std.ascii.eqlIgnoreCase(fname, "whichGroupState")) {
                        which_groups = parseLedWhich(value_expr);
                    } else if (std.ascii.eqlIgnoreCase(fname, "groups")) {
                        groups = parseLayoutMask(value_expr);
                    } else if (std.ascii.eqlIgnoreCase(fname, "controls") or
                        std.ascii.eqlIgnoreCase(fname, "ctrls"))
                    {
                        ctrls = parseLayoutMask(value_expr);
                    }
                }

                try leds.append(arena, .{
                    .name = name_atom,
                    .mods = mods,
                    .groups = groups,
                    .ctrls = ctrls,
                    .which_mods = which_mods,
                    .which_groups = which_groups,
                });
            },

            .group_compat => |gc| {
                const n: i64 = switch (gc.group.*) {
                    .integer => |v| v,
                    else => continue,
                };
                if (n >= 1 and n <= 4) {
                    group_compat[@intCast(n)] = action_lib.resolveModMask(gc.value, vmods);
                }
            },

            .include => |inc| {
                if (resolver) |res| {
                    const comps = res.resolveSpec(.compat, inc.path) catch |e| {
                        ctx.log(.warning, "failed to resolve compat include \"{s}\": {s}", .{ inc.path, @errorName(e) });
                        continue;
                    };
                    defer res.alloc.free(comps);

                    for (comps) |inc_comp| {
                        const sub = try compileCompat(arena, ctx, inc_comp, resolver, vmods);
                        try interprets.appendSlice(arena, sub.interprets);
                        try leds.appendSlice(arena, sub.leds);
                        for (1..5) |i| {
                            if (group_compat[i] == null) {
                                group_compat[i] = sub.group_compat[i];
                            }
                        }
                    }
                }
            },

            else => {},
        }
    }

    return .{
        .interprets = try interprets.toOwnedSlice(arena),
        .leds = try leds.toOwnedSlice(arena),
        .group_compat = group_compat,
    };
}

test "compileCompat: basic interprets + indicator + group_compat" {
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
        \\xkb_compat "c" {
        \\  interpret Caps_Lock { action=LockMods(modifiers=Lock); };
        \\  interpret Num_Lock+AnyOf(all) { action=LockMods(modifiers=Mod2); };
        \\  indicator "Caps Lock" { modifiers=Lock; };
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

    const info = try compileCompat(arena, ctx, comp, null, null);

    // Two interprets
    try std.testing.expectEqual(@as(usize, 2), info.interprets.len);

    // First: Caps_Lock, no match (defaults to any_of_or_none / 0xff), LockMods(Lock)
    const interp0 = info.interprets[0];
    try std.testing.expectEqual(keysym_lib.fromName("Caps_Lock", .{}), interp0.sym);
    try std.testing.expectEqual(MatchOp.any_of_or_none, interp0.match);
    try std.testing.expectEqual(@as(ModMask, 0xff), interp0.mods);
    try std.testing.expectEqual(std.meta.activeTag(interp0.action), .mods);
    try std.testing.expectEqual(interp0.action.mods.kind, .lock);
    try std.testing.expectEqual(interp0.action.mods.mods, @as(ModMask, 0x2));

    // Second: Num_Lock+AnyOf(all) -> .any_of, 0xff, LockMods(Mod2)
    const interp1 = info.interprets[1];
    try std.testing.expectEqual(keysym_lib.fromName("Num_Lock", .{}), interp1.sym);
    try std.testing.expectEqual(MatchOp.any_of, interp1.match);
    try std.testing.expectEqual(@as(ModMask, 0xff), interp1.mods);
    try std.testing.expectEqual(std.meta.activeTag(interp1.action), .mods);
    try std.testing.expectEqual(interp1.action.mods.kind, .lock);
    try std.testing.expectEqual(interp1.action.mods.mods, @as(ModMask, 0x10)); // Mod2

    // One LED
    try std.testing.expectEqual(@as(usize, 1), info.leds.len);
    try std.testing.expectEqualStrings("Caps Lock", ctx.atomText(info.leds[0].name));
    try std.testing.expectEqual(@as(ModMask, 0x2), info.leds[0].mods); // Lock
}

test "compileCompat: group_compat decl" {
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
        \\xkb_compat "c" {
        \\  group 2 = Shift;
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

    const info = try compileCompat(km_arena.allocator(), ctx, comp, null, null);
    try std.testing.expect(info.group_compat[2] != null);
    try std.testing.expectEqual(@as(ModMask, 0x1), info.group_compat[2].?); // Shift
}

test "compileCompat: Any sym -> null" {
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
        \\xkb_compat "c" {
        \\  interpret Any+AnyOfOrNone(all) { action=NoAction(); };
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

    const info = try compileCompat(km_arena.allocator(), ctx, comp, null, null);
    try std.testing.expectEqual(@as(usize, 1), info.interprets.len);
    try std.testing.expect(info.interprets[0].sym == null);
    try std.testing.expectEqual(MatchOp.any_of_or_none, info.interprets[0].match);
    try std.testing.expectEqual(@as(ModMask, 0xff), info.interprets[0].mods);
}

test "compileCompat fix6: useModMapMods does not set level_one_only" {
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
        \\xkb_compat "c" {
        \\  interpret Shift_L {
        \\    useModMapMods = true;
        \\    action = SetMods(modifiers=Shift);
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

    const info = try compileCompat(km_arena.allocator(), ctx, comp, null, null);
    try std.testing.expectEqual(@as(usize, 1), info.interprets.len);
    // useModMapMods must NOT have set level_one_only.
    try std.testing.expectEqual(false, info.interprets[0].level_one_only);
}

test "compileCompat: indicator which_mods/which_groups/groups populated" {
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
        \\xkb_compat "c" {
        \\  indicator "Caps Lock" {
        \\    whichModState=locked;
        \\    modifiers=Lock;
        \\  };
        \\  indicator "Num Lock" {
        \\    whichModState=effective;
        \\    whichGroupState=effective;
        \\    modifiers=Mod2;
        \\    groups=1;
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

    const info = try compileCompat(km_arena.allocator(), ctx, comp, null, null);
    try std.testing.expectEqual(@as(usize, 2), info.leds.len);

    const caps = info.leds[0];
    try std.testing.expectEqualStrings("Caps Lock", ctx.atomText(caps.name));
    try std.testing.expectEqual(@as(keymap.ModMask, 0x2), caps.mods); // Lock
    try std.testing.expect(caps.which_mods.modifiers); // locked state sets .modifiers
    try std.testing.expect(!caps.which_mods.groups); // locked does NOT set .groups
    try std.testing.expect(!caps.which_groups.modifiers);

    const num = info.leds[1];
    try std.testing.expectEqualStrings("Num Lock", ctx.atomText(num.name));
    try std.testing.expect(num.which_mods.modifiers);
    try std.testing.expect(num.which_mods.groups); // effective sets both bits
    try std.testing.expect(num.which_groups.modifiers);
    try std.testing.expect(num.which_groups.groups);
    try std.testing.expectEqual(@as(keymap.LayoutMask, 1), num.groups);
}
