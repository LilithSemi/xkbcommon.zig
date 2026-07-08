const std = @import("std");
const ast = @import("ast.zig");
const keymap = @import("../keymap.zig");
const mods_lib = @import("mods.zig");
const Context = @import("../context.zig").Context;

const Action = keymap.Action;
const ModMask = keymap.ModMask;

/// Resolve a mod-mask expression to a bitmask. Handles idents, "all"/"none", binary +, and vmods.
pub fn resolveModMask(expr: *const ast.Expr, vmods: ?*const mods_lib.VirtualMods) ModMask {
    switch (expr.*) {
        .ident => |name| {
            if (std.ascii.eqlIgnoreCase(name, "all")) return 0xff;
            if (std.ascii.eqlIgnoreCase(name, "none")) return 0;
            if (mods_lib.realModMask(name)) |m| return m;
            if (vmods) |vm| {
                if (vm.lookup(name)) |idx| return mods_lib.modIndexMask(idx);
            }
            return 0;
        },
        .integer => |v| {
            if (v < 0 or v > std.math.maxInt(ModMask)) return 0;
            return @intCast(v);
        },
        .binary => |b| {
            if (b.op == .add) {
                return resolveModMask(b.lhs, vmods) | resolveModMask(b.rhs, vmods);
            }
            return 0;
        },
        .unary => |u| {
            if (u.op == .unary_plus) return resolveModMask(u.rhs, vmods);
            return 0;
        },
        else => return 0,
    }
}

/// Compile an AST action-call expression. Unknown names map to .private; bad args are silently defaulted.
pub fn compileAction(
    alloc: std.mem.Allocator,
    ctx: *Context,
    expr: *const ast.Expr,
    vmods: ?*const mods_lib.VirtualMods,
) !Action {
    _ = alloc;
    _ = ctx;

    const act = switch (expr.*) {
        .action => |a| a,
        else => return .none,
    };

    const name = act.name;

    if (std.ascii.eqlIgnoreCase(name, "NoAction")) {
        return .none;
    }

    if (std.ascii.eqlIgnoreCase(name, "Terminate") or
        std.ascii.eqlIgnoreCase(name, "TerminateServer"))
    {
        return .terminate;
    }

    {
        const ModsKind = @TypeOf(@as(Action.ModsAction, undefined).kind);
        const kind: ?ModsKind = blk: {
            if (std.ascii.eqlIgnoreCase(name, "SetMods")) break :blk .set;
            if (std.ascii.eqlIgnoreCase(name, "LatchMods")) break :blk .latch;
            if (std.ascii.eqlIgnoreCase(name, "LockMods")) break :blk .lock;
            break :blk null;
        };

        if (kind) |k| {
            var mod_mask: ModMask = 0;
            var flags: keymap.ModsFlags = .{};
            var mods_by_name = false;

            for (act.args) |arg_expr| {
                switch (arg_expr) {
                    .arg => |arg| {
                        if (arg.name) |arg_name| {
                            if (std.ascii.eqlIgnoreCase(arg_name, "mods") or
                                std.ascii.eqlIgnoreCase(arg_name, "modifiers"))
                            {
                                mod_mask = resolveModMask(arg.value, vmods);
                                mods_by_name = true;
                            } else if (std.ascii.eqlIgnoreCase(arg_name, "useModMapMods") or
                                std.ascii.eqlIgnoreCase(arg_name, "usemodmapmods"))
                            {
                                flags.use_mod_map_mods = switch (arg.value.*) {
                                    .boolean => |v| v,
                                    else => true,
                                };
                            } else if (std.ascii.eqlIgnoreCase(arg_name, "clearLocks")) {
                                flags.clear_locks = switch (arg.value.*) {
                                    .boolean => |v| v,
                                    else => true,
                                };
                            } else if (std.ascii.eqlIgnoreCase(arg_name, "latchToLock")) {
                                flags.latch_to_lock = switch (arg.value.*) {
                                    .boolean => |v| v,
                                    else => true,
                                };
                            }
                        } else {
                            // bare positional flag ident
                            switch (arg.value.*) {
                                .ident => |ident_name| {
                                    if (std.ascii.eqlIgnoreCase(ident_name, "clearLocks")) {
                                        flags.clear_locks = true;
                                    } else if (std.ascii.eqlIgnoreCase(ident_name, "latchToLock")) {
                                        flags.latch_to_lock = true;
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }

            return .{ .mods = .{
                .kind = k,
                .mods = mod_mask,
                .mods_by_name = mods_by_name,
                .flags = flags,
            } };
        }
    }

    {
        const GroupKind = @TypeOf(@as(Action.GroupAction, undefined).kind);
        const kind: ?GroupKind = blk: {
            if (std.ascii.eqlIgnoreCase(name, "SetGroup")) break :blk .set;
            if (std.ascii.eqlIgnoreCase(name, "LatchGroup")) break :blk .latch;
            if (std.ascii.eqlIgnoreCase(name, "LockGroup")) break :blk .lock;
            break :blk null;
        };

        if (kind) |k| {
            var group: i32 = 0;
            var absolute = false;
            var flags: keymap.GroupFlags = .{};

            for (act.args) |arg_expr| {
                switch (arg_expr) {
                    .arg => |arg| {
                        if (arg.name) |arg_name| {
                            if (std.ascii.eqlIgnoreCase(arg_name, "group")) {
                                switch (arg.value.*) {
                                    .integer => |v| {
                                        // clamp to i32 range; large group values have no XKB meaning
                                        group = std.math.cast(i32, v) orelse std.math.maxInt(i32);
                                        absolute = true;
                                        flags.absolute = true;
                                    },
                                    .unary => |u| {
                                        switch (u.rhs.*) {
                                            .integer => |v| {
                                                const clamped = std.math.cast(i32, v) orelse std.math.maxInt(i32);
                                                group = if (u.op == .negate) -clamped else clamped;
                                                absolute = false;
                                                flags.absolute = false;
                                            },
                                            else => {},
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                    },
                    else => {},
                }
            }

            return .{ .group = .{
                .kind = k,
                .group = group,
                .absolute = absolute,
                .flags = flags,
            } };
        }
    }

    if (std.ascii.eqlIgnoreCase(name, "MovePtr") or
        std.ascii.eqlIgnoreCase(name, "MovePointer"))
    {
        return .{ .ptr = .{ .x = 0, .y = 0, .accelerate = true } };
    }

    if (std.ascii.eqlIgnoreCase(name, "PtrBtn") or
        std.ascii.eqlIgnoreCase(name, "PointerButton") or
        std.ascii.eqlIgnoreCase(name, "LockPtrBtn"))
    {
        return .{ .ptr_button = .{ .button = 1, .count = 1 } };
    }

    if (std.ascii.eqlIgnoreCase(name, "SetPtrDflt")) {
        return .{ .ptr_default = .{ .affect = 0, .value = 0 } };
    }

    if (std.ascii.eqlIgnoreCase(name, "SwitchScreen")) {
        return .{ .switch_screen = .{ .screen = 0, .same_server = true } };
    }

    if (std.ascii.eqlIgnoreCase(name, "SetControls")) {
        return .{ .controls = .{ .kind = .set, .ctrls = 0 } };
    }

    if (std.ascii.eqlIgnoreCase(name, "LockControls")) {
        return .{ .controls = .{ .kind = .lock, .ctrls = 0 } };
    }

    // unknown action name: store as .private
    return .{ .private = .{
        .kind = if (name.len > 0) name[0] else 0,
        .data = std.mem.zeroes([7]u8),
    } };
}

test "action: SetMods(modifiers=Shift) -> .mods set 0x1" {
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

    var lx = Lexer.init(std.testing.allocator, "SetMods(modifiers=Shift)");
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const e = try p.parseExpr();

    const result = try compileAction(std.testing.allocator, ctx, e, null);
    try std.testing.expectEqual(std.meta.activeTag(result), .mods);
    try std.testing.expectEqual(result.mods.kind, .set);
    try std.testing.expectEqual(result.mods.mods, @as(ModMask, 0x1));
}

test "action: LockMods(modifiers=Lock) -> .mods lock 0x2" {
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

    var lx = Lexer.init(std.testing.allocator, "LockMods(modifiers=Lock)");
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const e = try p.parseExpr();

    const result = try compileAction(std.testing.allocator, ctx, e, null);
    try std.testing.expectEqual(std.meta.activeTag(result), .mods);
    try std.testing.expectEqual(result.mods.kind, .lock);
    try std.testing.expectEqual(result.mods.mods, @as(ModMask, 0x2));
}

test "action: SetMods(mods=Mod1+Mod2) -> .mods set 0x18" {
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

    var lx = Lexer.init(std.testing.allocator, "SetMods(mods=Mod1+Mod2)");
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const e = try p.parseExpr();

    const result = try compileAction(std.testing.allocator, ctx, e, null);
    try std.testing.expectEqual(std.meta.activeTag(result), .mods);
    try std.testing.expectEqual(result.mods.kind, .set);
    try std.testing.expectEqual(result.mods.mods, @as(ModMask, 0x18));
}

test "action: SetGroup(group=2) -> .group set 2 absolute" {
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

    var lx = Lexer.init(std.testing.allocator, "SetGroup(group=2)");
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const e = try p.parseExpr();

    const result = try compileAction(std.testing.allocator, ctx, e, null);
    try std.testing.expectEqual(std.meta.activeTag(result), .group);
    try std.testing.expectEqual(result.group.kind, .set);
    try std.testing.expectEqual(result.group.group, @as(i32, 2));
    try std.testing.expect(result.group.absolute);
}

test "action: SetGroup(group=+1) -> .group set 1 relative" {
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

    var lx = Lexer.init(std.testing.allocator, "SetGroup(group=+1)");
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const e = try p.parseExpr();

    const result = try compileAction(std.testing.allocator, ctx, e, null);
    try std.testing.expectEqual(std.meta.activeTag(result), .group);
    try std.testing.expectEqual(result.group.group, @as(i32, 1));
    try std.testing.expect(!result.group.absolute);
}

test "action: NoAction() -> .none" {
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

    var lx = Lexer.init(std.testing.allocator, "NoAction()");
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const e = try p.parseExpr();

    const result = try compileAction(std.testing.allocator, ctx, e, null);
    try std.testing.expectEqual(std.meta.activeTag(result), .none);
}

test "action: FooBar() -> .private" {
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

    var lx = Lexer.init(std.testing.allocator, "FooBar()");
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const e = try p.parseExpr();

    const result = try compileAction(std.testing.allocator, ctx, e, null);
    try std.testing.expectEqual(std.meta.activeTag(result), .private);
}

test "action fix4: SetGroup(group=99999999999) does not panic" {
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

    var lx = Lexer.init(std.testing.allocator, "SetGroup(group=99999999999)");
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const e = try p.parseExpr();

    // Must not panic; group is clamped to i32 range.
    const result = try compileAction(std.testing.allocator, ctx, e, null);
    try std.testing.expectEqual(std.meta.activeTag(result), .group);
    try std.testing.expectEqual(result.group.kind, .set);
    try std.testing.expect(result.group.absolute);
}
