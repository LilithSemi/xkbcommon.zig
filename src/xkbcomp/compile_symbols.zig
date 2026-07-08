/// compile_symbols.zig: compile a symbols section to SymbolsInfo.
const std = @import("std");
const keymap = @import("../keymap.zig");
const ast = @import("ast.zig");
const Context = @import("../context.zig").Context;
const Atom = @import("../context.zig").Atom;
const include = @import("include.zig");
const action_lib = @import("action.zig");
const keysym_lib = @import("../keysym.zig");
const mods_lib = @import("mods.zig");

const ModMask = keymap.ModMask;
const Keysym = keysym_lib.Keysym;

/// XKB allows at most 4 simultaneous keyboard groups.
const XKB_MAX_GROUPS: usize = 4;

pub const LevelInfo = struct {
    syms: []Keysym,
    action: keymap.Action,
};

pub const GroupInfo = struct {
    type_name: ?Atom,
    levels: []LevelInfo,
};

pub const KeyInfo = struct {
    name: Atom,
    groups: []GroupInfo,
    modmap: ModMask,
    repeat: ?bool,
    out_of_range_action: keymap.RangeExceed = .wrap,
};

pub const SymbolsInfo = struct {
    keys: []KeyInfo,
    group_names: []Atom,
};

/// Resolve a keysym from an AST expression.
/// Integers are first tried as decimal keysym names (so "1" -> 0x31), then
/// as raw keysym values.
fn resolveKeysym(expr: *const ast.Expr) Keysym {
    switch (expr.*) {
        .ident => |name| {
            if (std.ascii.eqlIgnoreCase(name, "NoSymbol") or
                std.ascii.eqlIgnoreCase(name, "VoidSymbol"))
            {
                return .no_symbol;
            }
            return keysym_lib.fromName(name, .{}) orelse .no_symbol;
        },
        .keyname => |name| {
            return keysym_lib.fromName(name, .{}) orelse .no_symbol;
        },
        .integer => |v| {
            if (v < 0) return .no_symbol;
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return .no_symbol;
            return keysym_lib.fromName(s, .{}) orelse @enumFromInt(@as(u32, @intCast(v)));
        },
        else => return .no_symbol,
    }
}

/// Parse a group index from an index expression.
/// "Group1"/"group1"/1 -> 0; "Group2"/2 -> 1; etc.
fn parseGroupIndex(expr: *const ast.Expr) ?usize {
    switch (expr.*) {
        .ident => |name| {
            var buf: [32]u8 = undefined;
            if (name.len > buf.len) return null;
            const lower = std.ascii.lowerString(buf[0..name.len], name);
            if (std.mem.startsWith(u8, lower, "group")) {
                const num_str = lower["group".len..];
                if (num_str.len == 0) return 0;
                const n = std.fmt.parseInt(usize, num_str, 10) catch return null;
                if (n == 0) return null;
                const idx = n - 1;
                if (idx >= XKB_MAX_GROUPS) return null; // out of range: reject
                return idx;
            }
            const n = std.fmt.parseInt(usize, lower, 10) catch return null;
            if (n == 0) return null;
            const idx = n - 1;
            if (idx >= XKB_MAX_GROUPS) return null; // out of range: reject
            return idx;
        },
        .integer => |v| {
            if (v <= 0) return null;
            const idx = @as(usize, @intCast(v)) - 1;
            if (idx >= XKB_MAX_GROUPS) return null; // out of range: reject
            return idx;
        },
        else => return null,
    }
}

// per-group mutable builder; syms and actions merged at finalize
const GroupBuild = struct {
    type_name: ?Atom = null,
    level_syms: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Keysym)) = .empty,
    actions: std.ArrayListUnmanaged(keymap.Action) = .empty,
};

fn ensureGroup(arena: std.mem.Allocator, groups_build: *std.ArrayListUnmanaged(GroupBuild), gi: usize) !void {
    while (groups_build.items.len <= gi) {
        try groups_build.append(arena, .{});
    }
}

fn handleKeyAssign(
    arena: std.mem.Allocator,
    ctx: *Context,
    lhs: *const ast.Expr,
    rhs: *const ast.Expr,
    groups_build: *std.ArrayListUnmanaged(GroupBuild),
    repeat: *?bool,
    vmods: ?*const mods_lib.VirtualMods,
    vmodmap_out: *ModMask,
) !void {
    switch (lhs.*) {
        .ident => |name| {
            if (std.ascii.eqlIgnoreCase(name, "type")) {
                const type_str = switch (rhs.*) {
                    .string => |s| s,
                    .ident => |s| s,
                    else => return,
                };
                const type_atom = try ctx.intern(type_str);
                // type applies to all groups; ensure at least one exists
                if (groups_build.items.len == 0) {
                    try groups_build.append(arena, .{});
                }
                for (groups_build.items) |*gb| {
                    gb.type_name = type_atom;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "repeat")) {
                repeat.* = switch (rhs.*) {
                    .boolean => |v| v,
                    .ident => |v| std.ascii.eqlIgnoreCase(v, "true") or
                        std.ascii.eqlIgnoreCase(v, "yes"),
                    .integer => |v| v != 0,
                    else => true,
                };
            } else if (std.ascii.eqlIgnoreCase(name, "virtualMods") or
                std.ascii.eqlIgnoreCase(name, "vmods"))
            {
                // Bind vmod bits to this key's modmap so pressing the key sets those vmods.
                vmodmap_out.* |= action_lib.resolveModMask(rhs, vmods);
            }
        },
        .array_ref => |ar| {
            const base_name = switch (ar.base.*) {
                .ident => |n| n,
                else => return,
            };
            const gi: usize = if (ar.index) |idx_expr|
                parseGroupIndex(idx_expr) orelse 0
            else
                0;

            // guard in case a bare numeric index slips past parseGroupIndex
            if (gi >= XKB_MAX_GROUPS) return;

            try ensureGroup(arena, groups_build, gi);

            if (std.ascii.eqlIgnoreCase(base_name, "symbols")) {
                const gb = &groups_build.items[gi];
                switch (rhs.*) {
                    .list => |items| {
                        for (items) |*sym_expr| {
                            var level_s: std.ArrayListUnmanaged(Keysym) = .empty;
                            switch (sym_expr.*) {
                                .list => |sub| {
                                    for (sub) |*se| try level_s.append(arena, resolveKeysym(se));
                                },
                                else => try level_s.append(arena, resolveKeysym(sym_expr)),
                            }
                            try gb.level_syms.append(arena, level_s);
                        }
                    },
                    else => {},
                }
            } else if (std.ascii.eqlIgnoreCase(base_name, "actions")) {
                const gb = &groups_build.items[gi];
                switch (rhs.*) {
                    .list => |items| {
                        for (items) |*act_expr| {
                            const act = try action_lib.compileAction(arena, ctx, act_expr, null);
                            try gb.actions.append(arena, act);
                        }
                    },
                    else => {},
                }
            } else if (std.ascii.eqlIgnoreCase(base_name, "type")) {
                const type_str = switch (rhs.*) {
                    .string => |s| s,
                    .ident => |s| s,
                    else => return,
                };
                const type_atom = try ctx.intern(type_str);
                groups_build.items[gi].type_name = type_atom;
            }
        },
        else => {},
    }
}

/// Compile a symbols Component into a SymbolsInfo. Output slices are arena-allocated.
pub fn compileSymbols(
    arena: std.mem.Allocator,
    ctx: *Context,
    comp: *ast.Component,
    resolver: ?*include.Resolver,
    vmods: ?*const mods_lib.VirtualMods,
) !SymbolsInfo {
    var keys_list: std.ArrayListUnmanaged(KeyInfo) = .empty;
    var keys_map: std.AutoHashMapUnmanaged(Atom, usize) = .empty;
    var modmap_acc: std.AutoHashMapUnmanaged(Atom, ModMask) = .empty;
    var group_names: std.ArrayListUnmanaged(Atom) = .empty;

    for (comp.decls) |decl| {
        switch (decl) {
            .key => |kd| {
                const name_atom = try ctx.intern(kd.name);

                var groups_build: std.ArrayListUnmanaged(GroupBuild) = .empty;
                var bare_group_idx: usize = 0;
                var repeat: ?bool = null;
                var out_of_range_action: keymap.RangeExceed = .wrap;
                var key_vmodmap: ModMask = 0;

                for (kd.body) |*expr| {
                    switch (expr.*) {
                        .list => |items| {
                            const gi = bare_group_idx;
                            bare_group_idx += 1;
                            if (gi >= XKB_MAX_GROUPS) continue; // ignore excess groups
                            try ensureGroup(arena, &groups_build, gi);
                            const gb = &groups_build.items[gi];
                            for (items) |*sym_expr| {
                                var level_s: std.ArrayListUnmanaged(Keysym) = .empty;
                                switch (sym_expr.*) {
                                    .list => |sub| {
                                        for (sub) |*se| try level_s.append(arena, resolveKeysym(se));
                                    },
                                    else => try level_s.append(arena, resolveKeysym(sym_expr)),
                                }
                                try gb.level_syms.append(arena, level_s);
                            }
                        },
                        .assign => |asgn| {
                            try handleKeyAssign(arena, ctx, asgn.lhs, asgn.rhs, &groups_build, &repeat, vmods, &key_vmodmap);
                        },
                        .ident => |name| {
                            // bare out-of-range action keywords
                            var buf: [32]u8 = undefined;
                            if (name.len <= buf.len) {
                                const lower = std.ascii.lowerString(buf[0..name.len], name);
                                if (std.mem.eql(u8, lower, "groupswrap")) {
                                    out_of_range_action = .wrap;
                                } else if (std.mem.eql(u8, lower, "groupsclamp")) {
                                    out_of_range_action = .clamp;
                                } else if (std.mem.eql(u8, lower, "groupsredirect")) {
                                    out_of_range_action = .redirect;
                                }
                            }
                        },
                        else => {},
                    }
                }

                const groups = try arena.alloc(GroupInfo, groups_build.items.len);
                for (groups_build.items, 0..) |*gb, gi| {
                    const num_levels = @max(gb.level_syms.items.len, gb.actions.items.len);
                    const levels = try arena.alloc(LevelInfo, num_levels);
                    for (0..num_levels) |li| {
                        const syms: []Keysym = if (li < gb.level_syms.items.len) blk: {
                            const ls = &gb.level_syms.items[li];
                            if (ls.items.len == 0) {
                                const s = try arena.alloc(Keysym, 1);
                                s[0] = .no_symbol;
                                break :blk s;
                            }
                            break :blk try arena.dupe(Keysym, ls.items);
                        } else blk: {
                            const s = try arena.alloc(Keysym, 1);
                            s[0] = .no_symbol;
                            break :blk s;
                        };
                        const act: keymap.Action = if (li < gb.actions.items.len)
                            gb.actions.items[li]
                        else
                            .none;
                        levels[li] = .{ .syms = syms, .action = act };
                    }
                    groups[gi] = .{ .type_name = gb.type_name, .levels = levels };
                }

                const ki = KeyInfo{
                    .name = name_atom,
                    .groups = groups,
                    .modmap = key_vmodmap,
                    .repeat = repeat,
                    .out_of_range_action = out_of_range_action,
                };

                if (!keys_map.contains(name_atom)) {
                    const idx = keys_list.items.len;
                    try keys_list.append(arena, ki);
                    try keys_map.put(arena, name_atom, idx);
                }
            },

            .mod_map => |mm| {
                const mod_ident: ast.Expr = .{ .ident = mm.modifier };
                const mod_mask = action_lib.resolveModMask(&mod_ident, null);

                for (mm.keys) |*key_expr| {
                    const key_atom: Atom = switch (key_expr.*) {
                        .keyname => |kname| try ctx.intern(kname),
                        .ident => |iname| try ctx.intern(iname),
                        else => continue,
                    };
                    const existing = modmap_acc.get(key_atom) orelse 0;
                    try modmap_acc.put(arena, key_atom, existing | mod_mask);
                }
            },

            .vmods => {
                // Virtual mod names registered here; vmod finalization is compile_link's job.
            },

            .include => |inc| {
                if (resolver) |res| {
                    const resolved = res.resolveSpecFull(.symbols, inc.path) catch |e| {
                        ctx.log(.warning, "failed to resolve symbols include \"{s}\": {s}", .{ inc.path, @errorName(e) });
                        continue;
                    };
                    defer res.alloc.free(resolved);

                    for (resolved) |rc| {
                        // explicit_group is 1-based; convert to 0-based offset.
                        const group_offset: usize = if (rc.explicit_group) |eg| eg - 1 else 0;
                        const sub = try compileSymbols(arena, ctx, rc.comp, resolver, vmods);

                        for (sub.keys) |ki| {
                            if (group_offset == 0) {
                                // Default: add only if not already present (augment semantics).
                                if (!keys_map.contains(ki.name)) {
                                    const idx = keys_list.items.len;
                                    try keys_list.append(arena, ki);
                                    try keys_map.put(arena, ki.name, idx);
                                }
                            } else {
                                // Explicit group target: place ki's groups starting at group_offset.
                                if (keys_map.get(ki.name)) |existing_idx| {
                                    // Key exists: extend groups array to fit offset + ki's groups.
                                    const existing = &keys_list.items[existing_idx];
                                    const needed = group_offset + ki.groups.len;
                                    if (needed > existing.groups.len) {
                                        const new_groups = try arena.alloc(GroupInfo, needed);
                                        @memcpy(new_groups[0..existing.groups.len], existing.groups);
                                        // Fill any gap between old end and group_offset.
                                        if (group_offset > existing.groups.len) {
                                            for (new_groups[existing.groups.len..group_offset]) |*g| {
                                                g.* = .{ .type_name = null, .levels = &.{} };
                                            }
                                        }
                                        for (ki.groups, 0..) |g, i| {
                                            new_groups[group_offset + i] = g;
                                        }
                                        existing.groups = new_groups;
                                    } else {
                                        // Enough room: write into existing slots (don't clobber non-empty).
                                        for (ki.groups, 0..) |g, i| {
                                            const ti = group_offset + i;
                                            if (existing.groups[ti].levels.len == 0) {
                                                existing.groups[ti] = g;
                                            }
                                        }
                                    }
                                } else {
                                    // Key not present: add with groups padded to offset.
                                    const needed = group_offset + ki.groups.len;
                                    const new_groups = try arena.alloc(GroupInfo, needed);
                                    for (new_groups[0..group_offset]) |*g| {
                                        g.* = .{ .type_name = null, .levels = &.{} };
                                    }
                                    for (ki.groups, 0..) |g, i| {
                                        new_groups[group_offset + i] = g;
                                    }
                                    const new_ki = KeyInfo{
                                        .name = ki.name,
                                        .groups = new_groups,
                                        .modmap = ki.modmap,
                                        .repeat = ki.repeat,
                                        .out_of_range_action = ki.out_of_range_action,
                                    };
                                    const idx = keys_list.items.len;
                                    try keys_list.append(arena, new_ki);
                                    try keys_map.put(arena, ki.name, idx);
                                }
                            }
                        }

                        // Merge group names, offset-aware; first non-none wins per slot.
                        for (sub.group_names, 0..) |gn, gi| {
                            const target_gi = group_offset + gi;
                            while (group_names.items.len <= target_gi) {
                                try group_names.append(arena, .none);
                            }
                            if (group_names.items[target_gi] == .none) {
                                group_names.items[target_gi] = gn;
                            }
                        }
                    }
                }
            },

            else => {},
        }
    }

    var mm_iter = modmap_acc.iterator();
    while (mm_iter.next()) |entry| {
        const key_atom = entry.key_ptr.*;
        const mod_mask = entry.value_ptr.*;

        if (keys_map.get(key_atom)) |idx| {
            keys_list.items[idx].modmap |= mod_mask;
        } else {
            // key only in modmap, no key decl. Create a stub.
            const ki = KeyInfo{
                .name = key_atom,
                .groups = &.{},
                .modmap = mod_mask,
                .repeat = null,
            };
            const idx = keys_list.items.len;
            try keys_list.append(arena, ki);
            try keys_map.put(arena, key_atom, idx);
        }
    }

    return .{
        .keys = try keys_list.toOwnedSlice(arena),
        .group_names = try group_names.toOwnedSlice(arena),
    };
}

test "compileSymbols: basic keys, groups, modmap" {
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
        \\xkb_symbols "s" {
        \\  key <AE01> { [ 1, exclam ] };
        \\  key <LFSH> { [ Shift_L ] };
        \\  modifier_map Shift { <LFSH> };
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

    const info = try compileSymbols(arena, ctx, comp, null, null);

    // Two keys total.
    try std.testing.expectEqual(@as(usize, 2), info.keys.len);

    // Find AE01 and LFSH by atom text.
    var ae01: ?KeyInfo = null;
    var lfsh: ?KeyInfo = null;
    for (info.keys) |ki| {
        const text = ctx.atomText(ki.name);
        if (std.mem.eql(u8, text, "AE01")) ae01 = ki;
        if (std.mem.eql(u8, text, "LFSH")) lfsh = ki;
    }

    try std.testing.expect(ae01 != null);
    try std.testing.expect(lfsh != null);

    // AE01: 1 group, 2 levels.
    const ae = ae01.?;
    try std.testing.expectEqual(@as(usize, 1), ae.groups.len);
    try std.testing.expectEqual(@as(usize, 2), ae.groups[0].levels.len);
    try std.testing.expectEqual(
        keysym_lib.fromName("1", .{}),
        ae.groups[0].levels[0].syms[0],
    );
    try std.testing.expectEqual(
        keysym_lib.fromName("exclam", .{}),
        ae.groups[0].levels[1].syms[0],
    );

    // LFSH: modmap has Shift bit (0x1).
    try std.testing.expectEqual(@as(ModMask, 0x1), lfsh.?.modmap);
}

test "compileSymbols: explicit symbols[Group1] assign" {
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
        \\xkb_symbols "s" {
        \\  key <AD01> { symbols[Group1] = [ a, A ], actions[Group1] = [ NoAction() ] };
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

    const info = try compileSymbols(km_arena.allocator(), ctx, comp, null, null);

    try std.testing.expectEqual(@as(usize, 1), info.keys.len);
    const ki = info.keys[0];
    try std.testing.expectEqualStrings("AD01", ctx.atomText(ki.name));
    try std.testing.expectEqual(@as(usize, 1), ki.groups.len);
    try std.testing.expectEqual(@as(usize, 2), ki.groups[0].levels.len);
    try std.testing.expectEqual(
        keysym_lib.fromName("a", .{}),
        ki.groups[0].levels[0].syms[0],
    );
    try std.testing.expectEqual(keymap.Action.none, ki.groups[0].levels[0].action);
}

test "compileSymbols: multi-group key" {
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
        \\xkb_symbols "s" {
        \\  key <AD01> { [q, Q], [a, A] };
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

    const info = try compileSymbols(km_arena.allocator(), ctx, comp, null, null);

    try std.testing.expectEqual(@as(usize, 1), info.keys.len);
    const ki = info.keys[0];
    try std.testing.expectEqual(@as(usize, 2), ki.groups.len);
    try std.testing.expectEqual(
        keysym_lib.fromName("q", .{}),
        ki.groups[0].levels[0].syms[0],
    );
    try std.testing.expectEqual(
        keysym_lib.fromName("a", .{}),
        ki.groups[1].levels[0].syms[0],
    );
}

test "compileSymbols: multi-keysym level [{a, b}, c]" {
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
        \\xkb_symbols "s" {
        \\  key <AE01> { [ {a, b}, c ] };
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

    const info = try compileSymbols(km_arena.allocator(), ctx, comp, null, null);

    try std.testing.expectEqual(@as(usize, 1), info.keys.len);
    const ki = info.keys[0];
    try std.testing.expectEqualStrings("AE01", ctx.atomText(ki.name));
    try std.testing.expectEqual(@as(usize, 1), ki.groups.len);
    try std.testing.expectEqual(@as(usize, 2), ki.groups[0].levels.len);

    // Level 0: multi-keysym {a, b} -> 2 syms
    try std.testing.expectEqual(@as(usize, 2), ki.groups[0].levels[0].syms.len);
    try std.testing.expectEqual(keysym_lib.fromName("a", .{}), ki.groups[0].levels[0].syms[0]);
    try std.testing.expectEqual(keysym_lib.fromName("b", .{}), ki.groups[0].levels[0].syms[1]);

    // Level 1: single sym c
    try std.testing.expectEqual(@as(usize, 1), ki.groups[0].levels[1].syms.len);
    try std.testing.expectEqual(keysym_lib.fromName("c", .{}), ki.groups[0].levels[1].syms[0]);
}

test "compileSymbols: groupsClamp bare keyword records clamp action" {
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
        \\xkb_symbols "s" {
        \\  key <AE01> { groupsClamp, [a] };
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

    const info = try compileSymbols(km_arena.allocator(), ctx, comp, null, null);

    try std.testing.expectEqual(@as(usize, 1), info.keys.len);
    try std.testing.expectEqual(keymap.RangeExceed.clamp, info.keys[0].out_of_range_action);
    // Key still has 1 group with 1 level containing 'a'
    try std.testing.expectEqual(@as(usize, 1), info.keys[0].groups.len);
    try std.testing.expectEqual(keysym_lib.fromName("a", .{}), info.keys[0].groups[0].levels[0].syms[0]);
}

test "compileSymbols fix2: symbols[Group99] does not OOM or hang" {
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
        \\xkb_symbols "s" {
        \\  key <AD01> { symbols[Group99] = [ a ] };
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

    // Must complete quickly (no OOM / hang). Out-of-range group is silently
    // ignored; the key ends up with either 0 groups or group 0 depending on
    // defaulting behaviour.
    const info = try compileSymbols(km_arena.allocator(), ctx, comp, null, null);
    try std.testing.expectEqual(@as(usize, 1), info.keys.len);
    // groups must be within the allowed range
    try std.testing.expect(info.keys[0].groups.len <= XKB_MAX_GROUPS);
}
