/// compile_keycodes.zig: compile a keycodes section to KeyNamesInfo.
const std = @import("std");
const keymap = @import("../keymap.zig");
const ast = @import("ast.zig");
const Context = @import("../context.zig").Context;
const Atom = @import("../context.zig").Atom;
const include = @import("include.zig");
const expr_eval = @import("expr_eval.zig");

const Keycode = keymap.Keycode;
const KeyAlias = keymap.KeyAlias;

const KcPair = struct { kc: Keycode, atom: Atom };
const LedPair = struct { ndx: u32, atom: Atom };

pub const KeyNamesInfo = struct {
    min: Keycode,
    max: Keycode,
    // names[kc] == .none if absent; length = max+1.
    names: []Atom,
    aliases: []KeyAlias,
    // led_names[0] unused; indexed 1-based by indicator index.
    led_names: []Atom,
};

/// Compile a keycodes Component into a KeyNamesInfo. Output slices are arena-allocated.
pub fn compileKeycodes(
    arena: std.mem.Allocator,
    ctx: *Context,
    comp: *ast.Component,
    resolver: ?*include.Resolver,
) !KeyNamesInfo {
    var min_bound: ?Keycode = null;
    var max_bound: ?Keycode = null;

    var kc_pairs: std.ArrayList(KcPair) = .empty;
    var aliases: std.ArrayList(KeyAlias) = .empty;
    var led_pairs: std.ArrayList(LedPair) = .empty;

    try walkComp(arena, ctx, comp, resolver, &min_bound, &max_bound, &kc_pairs, &aliases, &led_pairs);

    var eff_max: Keycode = max_bound orelse 0;
    for (kc_pairs.items) |p| {
        if (p.kc > eff_max) eff_max = p.kc;
    }

    // Keycodes above 65535 would cause gigabyte allocations.
    const keycode_sanity_cap: Keycode = 65535;
    if (eff_max > keycode_sanity_cap) return error.KeycodeOutOfRange;

    var eff_min_opt: ?Keycode = min_bound;
    for (kc_pairs.items) |p| {
        if (eff_min_opt) |m| {
            if (p.kc < m) eff_min_opt = p.kc;
        } else {
            eff_min_opt = p.kc;
        }
    }
    const eff_min: Keycode = eff_min_opt orelse 0;

    // Cast to usize before +1 to prevent u32 wrapping.
    const names = try arena.alloc(Atom, @as(usize, eff_max) + 1);
    @memset(names, .none);
    for (kc_pairs.items) |p| {
        names[p.kc] = p.atom; // last-write wins
    }

    var max_led: u32 = 0;
    for (led_pairs.items) |p| {
        if (p.ndx > max_led) max_led = p.ndx;
    }
    const led_names = try arena.alloc(Atom, max_led + 1);
    @memset(led_names, .none);
    for (led_pairs.items) |p| {
        led_names[p.ndx] = p.atom;
    }

    return .{
        .min = eff_min,
        .max = eff_max,
        .names = names,
        .aliases = try aliases.toOwnedSlice(arena),
        .led_names = led_names,
    };
}

fn walkComp(
    arena: std.mem.Allocator,
    ctx: *Context,
    comp: *ast.Component,
    resolver: ?*include.Resolver,
    min_bound: *?Keycode,
    max_bound: *?Keycode,
    kc_pairs: *std.ArrayList(KcPair),
    aliases: *std.ArrayList(KeyAlias),
    led_pairs: *std.ArrayList(LedPair),
) !void {
    for (comp.decls) |decl| {
        switch (decl) {
            .keycode => |kd| {
                const atom = try ctx.intern(kd.name);
                const val = expr_eval.eval(kd.value, ctx) catch continue;
                switch (val) {
                    .int => |v| {
                        if (v < 0 or v > std.math.maxInt(Keycode)) continue;
                        const kc: Keycode = @intCast(v);
                        try kc_pairs.append(arena, .{ .kc = kc, .atom = atom });
                    },
                    else => continue,
                }
            },
            .key_alias => |ka| {
                const alias_atom = try ctx.intern(ka.alias);
                const real_atom = try ctx.intern(ka.real);
                try aliases.append(arena, .{ .alias = alias_atom, .real = real_atom });
            },
            .indicator_name => |ind| {
                const ndx_val = expr_eval.eval(ind.ndx, ctx) catch continue;
                switch (ndx_val) {
                    .int => |v| {
                        if (v <= 0 or v > std.math.maxInt(u32)) continue;
                        const ndx: u32 = @intCast(v);
                        const name_val = expr_eval.eval(ind.name, ctx) catch continue;
                        switch (name_val) {
                            .string => |s| {
                                const name_atom = try ctx.intern(s);
                                try led_pairs.append(arena, .{ .ndx = ndx, .atom = name_atom });
                            },
                            else => continue,
                        }
                    },
                    else => continue,
                }
            },
            .var_def => |vd| {
                switch (vd.name.*) {
                    .ident => |name_str| {
                        const value_expr = vd.value orelse continue;
                        const val = expr_eval.eval(value_expr, ctx) catch continue;
                        switch (val) {
                            .int => |iv| {
                                if (iv < 0 or iv > std.math.maxInt(Keycode)) continue;
                                const v: Keycode = @intCast(iv);
                                if (std.ascii.eqlIgnoreCase(name_str, "minimum")) {
                                    min_bound.* = v;
                                } else if (std.ascii.eqlIgnoreCase(name_str, "maximum")) {
                                    max_bound.* = v;
                                }
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            .include => |inc| {
                if (resolver) |res| {
                    const sub_comps = res.resolveSpec(.keycodes, inc.path) catch |e| {
                        ctx.log(.warning, "failed to resolve keycodes include \"{s}\": {s}", .{ inc.path, @errorName(e) });
                        continue;
                    };
                    defer res.alloc.free(sub_comps);
                    for (sub_comps) |sub_comp| {
                        try walkComp(arena, ctx, sub_comp, res, min_bound, max_bound, kc_pairs, aliases, led_pairs);
                    }
                }
            },
            else => {},
        }
    }
}

test "compileKeycodes: basic keycodes section" {
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
        \\xkb_keycodes "k" {
        \\  minimum=8;
        \\  maximum=255;
        \\  <AE01>=10;
        \\  <TLDE>=49;
        \\  alias <CAPS>=<CAPL>;
        \\  indicator 1="Caps Lock";
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

    const info = try compileKeycodes(arena, ctx, comp, null);

    try std.testing.expect(info.min <= 10);
    try std.testing.expect(info.max >= 49);
    try std.testing.expectEqualStrings("AE01", ctx.atomText(info.names[10]));
    try std.testing.expectEqualStrings("TLDE", ctx.atomText(info.names[49]));
    try std.testing.expectEqual(@as(usize, 1), info.aliases.len);
    try std.testing.expectEqualStrings("CAPS", ctx.atomText(info.aliases[0].alias));
    try std.testing.expectEqualStrings("CAPL", ctx.atomText(info.aliases[0].real));
    try std.testing.expectEqualStrings("Caps Lock", ctx.atomText(info.led_names[1]));
}

test "compileKeycodes: keycode 4294967295 returns KeycodeOutOfRange" {
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
        \\xkb_keycodes "huge" {
        \\  <X> = 4294967295;
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

    const result = compileKeycodes(km_arena.allocator(), ctx, comp, null);
    try std.testing.expectError(error.KeycodeOutOfRange, result);
}
