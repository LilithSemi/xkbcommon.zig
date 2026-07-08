/// serialize.zig: helpers and serializers for the XKB text format.
const std = @import("std");
const keymap = @import("../keymap.zig");
const Keysym = @import("../keysym.zig").Keysym;
const ModMask = keymap.ModMask;
const Context = @import("../context.zig").Context;
const Atom = @import("../context.zig").Atom;

/// Write the names of all bits set in `mask`, joined by `+`.
/// Names are taken from km.mods.mods[i].name via atomText.
/// If mask == 0, writes "none".
/// Bits beyond km.mods.mods.len are silently ignored.
pub fn modMaskName(km: *const keymap.Keymap, mask: ModMask, w: *std.Io.Writer) !void {
    if (mask == 0) {
        try w.writeAll("none");
        return;
    }
    var first = true;
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        if (i >= km.mods.mods.len) break;
        if ((mask >> @as(u5, @intCast(i))) & 1 == 0) continue;
        if (!first) try w.writeAll("+");
        first = false;
        try w.writeAll(km.ctx.atomText(km.mods.mods[i].name));
    }
}

/// Write the canonical name of a keysym (falls back to "NoSymbol" on NoSpace).
pub fn keysymName(sym: Keysym, w: *std.Io.Writer) !void {
    var buf: [64]u8 = undefined;
    const n = sym.getName(&buf) catch "NoSymbol";
    try w.writeAll(n);
}

/// Write `s` surrounded by double-quotes, escaping `\` -> `\\` and `"` -> `\"`.
pub fn writeQuotedString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            else => try w.writeAll((&c)[0..1]),
        }
    }
    try w.writeAll("\"");
}

/// Emit the xkb_keycodes block for `km`.
pub fn serializeKeycodes(km: *const keymap.Keymap, w: *std.Io.Writer) !void {
    try w.writeAll("\txkb_keycodes \"(unnamed)\" {\n");
    try w.print("\t\tminimum = {};\n", .{km.min_key_code});
    try w.print("\t\tmaximum = {};\n", .{km.max_key_code});

    var kc: u32 = km.min_key_code;
    while (kc <= km.max_key_code) : (kc += 1) {
        if (kc >= km.keys.len) break;
        const key = &km.keys[kc];
        if (key.name == .none) continue;
        const name = km.ctx.atomText(key.name);
        try w.print("\t\t<{s}> = {};\n", .{ name, kc });
    }

    for (km.leds, 0..) |led, idx| {
        if (led.name == .none) continue;
        const led_name = km.ctx.atomText(led.name);
        try w.print("\t\tindicator {} = ", .{idx + 1});
        try writeQuotedString(w, led_name);
        try w.writeAll(";\n");
    }

    for (km.key_aliases) |alias| {
        const a_name = km.ctx.atomText(alias.alias);
        const r_name = km.ctx.atomText(alias.real);
        try w.print("\t\talias <{s}> = <{s}>;\n", .{ a_name, r_name });
    }

    try w.writeAll("\t};\n");
}

/// Emit the xkb_types block for `km`.
pub fn serializeTypes(km: *const keymap.Keymap, w: *std.Io.Writer) !void {
    try w.writeAll("\txkb_types \"(unnamed)\" {\n");

    var has_virt = false;
    for (km.mods.mods) |mod| {
        if (mod.type == .virt) {
            has_virt = true;
            break;
        }
    }
    if (has_virt) {
        try w.writeAll("\t\tvirtual_modifiers ");
        var first = true;
        for (km.mods.mods) |mod| {
            if (mod.type != .virt) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll(km.ctx.atomText(mod.name));
        }
        try w.writeAll(";\n");
    }

    for (km.types) |*t| {
        try w.writeAll("\t\ttype ");
        try writeQuotedString(w, km.ctx.atomText(t.name));
        try w.writeAll(" {\n");

        try w.writeAll("\t\t\tmodifiers= ");
        try modMaskName(km, t.mods, w);
        try w.writeAll(";\n");

        for (t.entries) |entry| {
            try w.writeAll("\t\t\tmap[");
            try modMaskName(km, entry.mods, w);
            try w.print("]= Level{};\n", .{entry.level + 1});
        }

        // Guard: level_names slice may be shorter than num_levels or empty.
        for (t.level_names, 0..) |lname, i| {
            if (lname == .none) continue;
            try w.print("\t\t\tlevel_name[Level{}]= ", .{i + 1});
            try writeQuotedString(w, km.ctx.atomText(lname));
            try w.writeAll(";\n");
        }

        for (t.entries) |entry| {
            if (entry.preserve == 0) continue;
            try w.writeAll("\t\t\tpreserve[");
            try modMaskName(km, entry.mods, w);
            try w.writeAll("]= ");
            try modMaskName(km, entry.preserve, w);
            try w.writeAll(";\n");
        }

        try w.writeAll("\t\t};\n");
    }

    try w.writeAll("\t};\n");
}

/// Return the XKB text name for a MatchOp.
pub fn matchOpName(m: keymap.MatchOp) []const u8 {
    return switch (m) {
        .any_of_or_none => "AnyOfOrNone",
        .any_of => "AnyOf",
        .none_of => "NoneOf",
        .all_of => "AllOf",
        .exactly => "Exactly",
        .none => "AnyOfOrNone",
    };
}

/// Write the text representation of `a` (e.g. `LockMods(modifiers=Lock)`).
pub fn actionToString(km: *const keymap.Keymap, a: keymap.Action, w: *std.Io.Writer) !void {
    switch (a) {
        .none => try w.writeAll("NoAction()"),
        .mods => |ma| {
            const prefix: []const u8 = switch (ma.kind) {
                .set => "SetMods",
                .latch => "LatchMods",
                .lock => "LockMods",
            };
            try w.writeAll(prefix);
            try w.writeAll("(modifiers=");
            try modMaskName(km, ma.mods, w);
            if (ma.flags.clear_locks) try w.writeAll(",clearLocks");
            if (ma.flags.latch_to_lock) try w.writeAll(",latchToLock");
            try w.writeAll(")");
        },
        .group => |ga| {
            const prefix: []const u8 = switch (ga.kind) {
                .set => "SetGroup",
                .latch => "LatchGroup",
                .lock => "LockGroup",
            };
            try w.writeAll(prefix);
            try w.writeAll("(group=");
            if (ga.absolute) {
                try w.print("{}", .{ga.group});
            } else if (ga.group >= 0) {
                try w.print("+{}", .{ga.group});
            } else {
                try w.print("{}", .{ga.group});
            }
            try w.writeAll(")");
        },
        else => try w.writeAll("NoAction()"),
    }
}

/// Emit the xkb_compatibility block for `km`.
pub fn serializeCompat(km: *const keymap.Keymap, w: *std.Io.Writer) !void {
    try w.writeAll("\txkb_compatibility \"(unnamed)\" {\n");

    var has_virt = false;
    for (km.mods.mods) |mod| {
        if (mod.type == .virt) {
            has_virt = true;
            break;
        }
    }
    if (has_virt) {
        try w.writeAll("\t\tvirtual_modifiers ");
        var first = true;
        for (km.mods.mods) |mod| {
            if (mod.type != .virt) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll(km.ctx.atomText(mod.name));
        }
        try w.writeAll(";\n");
    }

    for (km.sym_interprets) |interp| {
        try w.writeAll("\t\tinterpret ");
        if (interp.sym) |sym| {
            try keysymName(sym, w);
        } else {
            try w.writeAll("Any");
        }
        try w.writeAll("+");
        try w.writeAll(matchOpName(interp.match));
        try w.writeAll("(");
        try modMaskName(km, interp.mods, w);
        try w.writeAll(") {\n");
        try w.writeAll("\t\t\taction= ");
        try actionToString(km, interp.action, w);
        try w.writeAll(";\n");
        if (interp.virtual_mod != keymap.mod_index_invalid and
            interp.virtual_mod < km.mods.mods.len)
        {
            const vmod_name = km.ctx.atomText(km.mods.mods[interp.virtual_mod].name);
            try w.print("\t\t\tvirtualModifier={s};\n", .{vmod_name});
        }
        if (!interp.repeat) {
            try w.writeAll("\t\t\trepeat=false;\n");
        }
        if (interp.level_one_only) {
            try w.writeAll("\t\t\tuseModMapMods=level1;\n");
        }
        try w.writeAll("\t\t};\n");
    }

    for (km.leds) |led| {
        if (led.name == .none) continue;
        const led_name = km.ctx.atomText(led.name);
        try w.writeAll("\t\tindicator ");
        try writeQuotedString(w, led_name);
        try w.writeAll(" {\n");
        if (led.which_mods.modifiers or led.which_mods.groups) {
            try w.writeAll("\t\t\twhichModState= effective;\n");
        }
        try w.writeAll("\t\t\tmodifiers= ");
        try modMaskName(km, led.mods, w);
        try w.writeAll(";\n");
        if (led.which_groups.modifiers or led.which_groups.groups) {
            try w.writeAll("\t\t\twhichGroupState= effective;\n");
        }
        if (led.groups != 0) {
            try w.print("\t\t\tgroups= {};\n", .{led.groups});
        }
        try w.writeAll("\t\t};\n");
    }

    try w.writeAll("\t};\n");
}

/// Emit the xkb_symbols block for `km`.
pub fn serializeSymbols(km: *const keymap.Keymap, w: *std.Io.Writer) !void {
    try w.writeAll("\txkb_symbols \"(unnamed)\" {\n");

    for (km.group_names, 0..) |gname, gi| {
        if (gname == .none) continue;
        try w.print("\t\tname[Group{}]=", .{gi + 1});
        try writeQuotedString(w, km.ctx.atomText(gname));
        try w.writeAll(";\n");
    }

    var kc: u32 = km.min_key_code;
    while (kc <= km.max_key_code) : (kc += 1) {
        if (kc >= km.keys.len) break;
        const key = &km.keys[kc];
        if (key.name == .none) continue;
        if (key.groups.len == 0) continue;

        const kname = km.ctx.atomText(key.name);
        try w.print("\t\tkey <{s}> {{ ", .{kname});

        var need_comma = false;

        if (need_comma) try w.writeAll(", ");
        try w.writeAll(if (key.repeats) "repeat= Yes" else "repeat= No");
        need_comma = true;

        for (key.groups, 0..) |*grp, gi| {
            if (!grp.explicit_type or grp.type_index >= km.types.len) continue;
            if (need_comma) try w.writeAll(", ");
            need_comma = true;
            const tname = km.ctx.atomText(km.types[grp.type_index].name);
            try w.print("type[Group{}]=", .{gi + 1});
            try writeQuotedString(w, tname);
        }

        // compile_symbols silently ignores these bare idents on re-parse
        switch (key.out_of_range_group_action) {
            .wrap => {}, // default, omit
            .clamp => {
                if (need_comma) try w.writeAll(", ");
                need_comma = true;
                try w.writeAll("groupsClamp");
            },
            .redirect => {
                if (need_comma) try w.writeAll(", ");
                need_comma = true;
                try w.writeAll("groupsRedirect");
            },
        }

        for (key.groups) |*grp| {
            if (need_comma) try w.writeAll(", ");
            need_comma = true;
            try w.writeAll("[ ");
            for (grp.levels, 0..) |*lvl, li| {
                if (li > 0) try w.writeAll(", ");
                if (lvl.syms.len > 1) {
                    // multi-sym level: compile_symbols re-parses only the first sym on round-trip
                    try w.writeAll("{ ");
                    for (lvl.syms, 0..) |sym, si| {
                        if (si > 0) try w.writeAll(", ");
                        try keysymName(sym, w);
                    }
                    try w.writeAll(" }");
                } else if (lvl.syms.len == 1) {
                    try keysymName(lvl.syms[0], w);
                } else {
                    try w.writeAll("NoSymbol");
                }
            }
            try w.writeAll(" ]");
        }

        for (key.groups, 0..) |*grp, gi| {
            var has_action = false;
            for (grp.levels) |*lvl| {
                if (std.meta.activeTag(lvl.action) != .none) {
                    has_action = true;
                    break;
                }
            }
            if (!has_action) continue;
            if (need_comma) try w.writeAll(", ");
            need_comma = true;
            try w.print("actions[Group{}]=[ ", .{gi + 1});
            for (grp.levels, 0..) |*lvl, li| {
                if (li > 0) try w.writeAll(", ");
                try actionToString(km, lvl.action, w);
            }
            try w.writeAll(" ]");
        }

        try w.writeAll(" };\n");
    }

    // real mods are indices 0-7
    var m: u32 = 0;
    while (m < 8) : (m += 1) {
        if (m >= km.mods.mods.len) break;
        const mod = &km.mods.mods[m];
        if (mod.type != .real) continue;

        const mask: ModMask = @as(ModMask, 1) << @as(u5, @intCast(m));

        var has_any = false;
        {
            var k: u32 = km.min_key_code;
            while (k <= km.max_key_code) : (k += 1) {
                if (k >= km.keys.len) break;
                if (km.keys[k].name == .none) continue;
                if ((km.keys[k].modmap & mask) != 0) {
                    has_any = true;
                    break;
                }
            }
        }
        if (!has_any) continue;

        const mname = km.ctx.atomText(mod.name);
        try w.print("\t\tmodifier_map {s} {{ ", .{mname});

        var first_key = true;
        var k: u32 = km.min_key_code;
        while (k <= km.max_key_code) : (k += 1) {
            if (k >= km.keys.len) break;
            const key2 = &km.keys[k];
            if (key2.name == .none) continue;
            if ((key2.modmap & mask) == 0) continue;
            if (!first_key) try w.writeAll(", ");
            first_key = false;
            try w.print("<{s}>", .{km.ctx.atomText(key2.name)});
        }

        try w.writeAll(" };\n");
    }

    try w.writeAll("\t};\n");
}

/// Emit the xkb_geometry block for `km` when geometry is present.
pub fn serializeGeometry(km: *const keymap.Keymap, w: *std.Io.Writer) !void {
    const geom = km.geometry orelse return;

    try w.writeAll("\txkb_geometry ");
    try writeQuotedString(w, km.ctx.atomText(geom.name));
    try w.writeAll(" {\n");

    try w.print("\t\twidth={};\n", .{geom.width_mm});
    try w.print("\t\theight={};\n", .{geom.height_mm});

    for (geom.shapes) |shape| {
        try w.writeAll("\t\tshape ");
        try writeQuotedString(w, km.ctx.atomText(shape.name));
        try w.writeAll(" {");
        for (shape.outlines) |outline| {
            try w.writeAll(" {");
            for (outline.points, 0..) |pt, i| {
                if (i > 0) try w.writeAll(",");
                try w.print(" [{},{}]", .{ pt.x, pt.y });
            }
            try w.writeAll(" }");
        }
        try w.writeAll(" };\n");
    }

    for (geom.sections) |section| {
        try w.writeAll("\t\tsection ");
        try writeQuotedString(w, km.ctx.atomText(section.name));
        try w.writeAll(" {\n");
        for (section.rows) |row| {
            try w.writeAll("\t\t\trow {\n");
            try w.writeAll("\t\t\t\tkeys {");
            for (row.keys) |key| {
                try w.writeAll(" { name=<");
                try w.writeAll(km.ctx.atomText(key.name));
                try w.writeAll("> }");
            }
            try w.writeAll(" };\n");
            try w.writeAll("\t\t\t};\n");
        }
        try w.writeAll("\t\t};\n");
    }

    for (geom.doodads) |doodad| {
        const kind_name: []const u8 = switch (doodad.kind) {
            .solid => "solid",
            .text => "text",
            .outline => "outline",
            .logo => "logo",
            .indicator => "indicator",
        };
        try w.writeAll("\t\t");
        try w.writeAll(kind_name);
        try w.writeAll(" ");
        try writeQuotedString(w, km.ctx.atomText(doodad.name));
        try w.writeAll(" { };\n");
    }

    try w.writeAll("\t};\n");
}

test "modMaskName: none, single bit, two bits" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    // Use a real compiled keymap so mods.mods is populated.
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { minimum=8; maximum=255; <AE01>=10; };
        \\  xkb_types "t" { type "TWO_LEVEL" { modifiers=Shift; map[Shift]=Level2; }; };
        \\  xkb_compat "c" { };
        \\  xkb_symbols "s" { key <AE01> { [ 1, exclam ] }; };
        \\};
    ;
    const km = try keymap.Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try modMaskName(km, 0, &aw.writer);
        try std.testing.expectEqualStrings("none", aw.writer.buffered());
    }
    {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try modMaskName(km, 0x1, &aw.writer);
        try std.testing.expectEqualStrings("Shift", aw.writer.buffered());
    }
    {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try modMaskName(km, 0x3, &aw.writer);
        try std.testing.expectEqualStrings("Shift+Lock", aw.writer.buffered());
    }
}

test "serializeKeycodes: output contains expected tokens" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" {
        \\    minimum=8; maximum=255;
        \\    <AE01>=10;
        \\    <TLDE>=49;
        \\    indicator 1 = "Caps Lock";
        \\    alias <CAPS>=<CAPL>;
        \\  };
        \\  xkb_types "t" { type "TWO_LEVEL" { modifiers=Shift; map[Shift]=Level2; }; };
        \\  xkb_compat "c" {
        \\    indicator "Caps Lock" { modifiers=Lock; };
        \\  };
        \\  xkb_symbols "s" {
        \\    key <AE01> { [ 1, exclam ] };
        \\    key <TLDE> { [ grave, asciitilde ] };
        \\  };
        \\};
    ;
    const km = try keymap.Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try serializeKeycodes(km, &aw.writer);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "xkb_keycodes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "minimum =") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "maximum =") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<AE01> = 10;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "alias <CAPS> = <CAPL>;") != null);
    // LED indicator line: indicator 1 = "Caps Lock";
    try std.testing.expect(std.mem.indexOf(u8, out, "indicator") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Caps Lock") != null);
}

test "serializeTypes: output contains expected tokens" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" {
        \\    minimum=8; maximum=255;
        \\    <AE01>=10; <LFSH>=50;
        \\  };
        \\  xkb_types "t" {
        \\    type "ONE_LEVEL" { modifiers=none; map[none]=Level1; level_name[Level1]="Any"; };
        \\    type "TWO_LEVEL" { modifiers=Shift; map[Shift]=Level2; level_name[Level1]="Base"; level_name[Level2]="Shift"; };
        \\  };
        \\  xkb_compat "c" { };
        \\  xkb_symbols "s" {
        \\    key <AE01> { [ 1, exclam ] };
        \\    key <LFSH> { [ Shift_L ] };
        \\    modifier_map Shift { <LFSH> };
        \\  };
        \\};
    ;
    const km = try keymap.Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try serializeTypes(km, &aw.writer);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "xkb_types") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "type \"TWO_LEVEL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "modifiers= Shift") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "map[Shift]= Level2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "level_name[Level1]= \"Base\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "type \"ONE_LEVEL\"") != null);
}

test "serializeCompat: output contains expected tokens" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" {
        \\    minimum=8; maximum=255;
        \\    <CAPS>=66;
        \\    indicator 1 = "Caps Lock";
        \\  };
        \\  xkb_types "t" {
        \\    type "ONE_LEVEL" { modifiers=none; map[none]=Level1; };
        \\  };
        \\  xkb_compat "c" {
        \\    interpret Caps_Lock+AnyOfOrNone(none) {
        \\      action=LockMods(modifiers=Lock);
        \\    };
        \\    indicator "Caps Lock" { modifiers=Lock; };
        \\  };
        \\  xkb_symbols "s" {
        \\    key <CAPS> { [ Caps_Lock ] };
        \\  };
        \\};
    ;
    const km = try keymap.Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try serializeCompat(km, &aw.writer);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "xkb_compatibility") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "interpret Caps_Lock") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "LockMods(modifiers=Lock)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "indicator \"Caps Lock\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "modifiers= Lock") != null);
}

test "actionToString: SetGroup non-absolute" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { minimum=8; maximum=255; <AE01>=10; };
        \\  xkb_types "t" { type "TWO_LEVEL" { modifiers=Shift; map[Shift]=Level2; }; };
        \\  xkb_compat "c" { };
        \\  xkb_symbols "s" { key <AE01> { [ 1, exclam ] }; };
        \\};
    ;
    const km = try keymap.Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    const action = keymap.Action{
        .group = .{
            .kind = .set,
            .group = 1,
            .absolute = false,
            .flags = .{},
        },
    };

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try actionToString(km, action, &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "SetGroup(group=+1)") != null);
}

test "serialize round-trip: repeat, explicit actions, per-group types" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    // AE01 (kc=10): explicit repeat=no
    // AE02 (kc=11): explicit action at group 0 level 0
    // AE03 (kc=12): 2 groups with distinct types
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" {
        \\    minimum=8; maximum=255;
        \\    <AE01>=10; <AE02>=11; <AE03>=12;
        \\  };
        \\  xkb_types "t" {
        \\    type "ONE_LEVEL" { modifiers=none; map[none]=Level1; };
        \\    type "TWO_LEVEL" { modifiers=Shift; map[Shift]=Level2; };
        \\  };
        \\  xkb_compat "c" {};
        \\  xkb_symbols "s" {
        \\    key <AE01> { repeat=no, [ 1, exclam ] };
        \\    key <AE02> { symbols[Group1]=[ a, A ], actions[Group1]=[ SetMods(modifiers=Control), NoAction() ] };
        \\    key <AE03> { type[Group1]="ONE_LEVEL", type[Group2]="TWO_LEVEL", [ q ], [ w, W ] };
        \\  };
        \\};
    ;

    const km = try keymap.Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    // Baseline: verify first compile state.
    try std.testing.expectEqual(false, km.keys[10].repeats);
    try std.testing.expectEqual(
        std.meta.Tag(keymap.Action).mods,
        std.meta.activeTag(km.keys[11].groups[0].levels[0].action),
    );
    try std.testing.expectEqual(true, km.keys[12].groups[0].explicit_type);
    try std.testing.expectEqual(true, km.keys[12].groups[1].explicit_type);
    try std.testing.expect(km.keys[12].groups[0].type_index != km.keys[12].groups[1].type_index);

    // Serialize -> re-compile.
    const text = try km.getAsString(.text_v1);
    defer std.testing.allocator.free(text);

    const km2 = try keymap.Keymap.newFromString(ctx, text, .text_v1);
    defer km2.destroy();

    // repeat=No survived: keys[10].repeats must still be false.
    try std.testing.expectEqual(false, km2.keys[10].repeats);

    // Explicit action survived: AE02 group 0 level 0 must be .mods{kind=.set}.
    const act = km2.keys[11].groups[0].levels[0].action;
    try std.testing.expectEqual(
        std.meta.Tag(keymap.Action).mods,
        std.meta.activeTag(act),
    );
    try std.testing.expect(act.mods.kind == .set);

    // Per-group types survived: both groups explicit with different type indices.
    try std.testing.expectEqual(true, km2.keys[12].groups[0].explicit_type);
    try std.testing.expectEqual(true, km2.keys[12].groups[1].explicit_type);
    try std.testing.expect(km2.keys[12].groups[0].type_index != km2.keys[12].groups[1].type_index);
}

test "multi-sym level round-trip: [{a, b}, c] survives serialize and recompile" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { minimum=8; maximum=255; <AE01>=10; };
        \\  xkb_types "t" { type "TWO_LEVEL" { modifiers=Shift; map[Shift]=Level2; }; };
        \\  xkb_compat "c" {};
        \\  xkb_symbols "s" { key <AE01> { [ {a, b}, c ] }; };
        \\};
    ;
    const km = try keymap.Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    // First compile: level 0 must have 2 syms (a, b).
    try std.testing.expectEqual(@as(usize, 2), km.keys[10].groups[0].levels[0].syms.len);
    try std.testing.expectEqual(
        @import("../keysym.zig").fromName("a", .{}),
        km.keys[10].groups[0].levels[0].syms[0],
    );
    try std.testing.expectEqual(
        @import("../keysym.zig").fromName("b", .{}),
        km.keys[10].groups[0].levels[0].syms[1],
    );

    // Serialize -> the serialized text must contain "{ a, b }" for the multi-sym level.
    const text = try km.getAsString(.text_v1);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "{ a, b }") != null or
        std.mem.indexOf(u8, text, "{ a,b }") != null or
        std.mem.indexOf(u8, text, "{a, b}") != null);

    // Re-compile from the serialized text: level 0 must still have 2 syms.
    const km2 = try keymap.Keymap.newFromString(ctx, text, .text_v1);
    defer km2.destroy();
    try std.testing.expectEqual(@as(usize, 2), km2.keys[10].groups[0].levels[0].syms.len);
}

test "groupsClamp: key body keyword parses and compiles without error" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { minimum=8; maximum=255; <AE01>=10; };
        \\  xkb_types "t" { type "ONE_LEVEL" { modifiers=none; map[none]=Level1; }; };
        \\  xkb_compat "c" {};
        \\  xkb_symbols "s" { key <AE01> { groupsClamp, [a] }; };
        \\};
    ;
    const km = try keymap.Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    // Key must have compiled successfully with its sym intact.
    try std.testing.expectEqual(@as(usize, 1), km.keys[10].groups.len);
    try std.testing.expectEqual(@as(usize, 1), km.keys[10].groups[0].levels.len);
    try std.testing.expectEqual(
        @import("../keysym.zig").fromName("a", .{}),
        km.keys[10].groups[0].levels[0].syms[0],
    );
}

test "serialize round-trip: interpret virtualModifier survives recompile" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    // Keymap with a virtual mod LevelThree and an interpret that uses it.
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { minimum=8; maximum=255; <AE01>=10; };
        \\  xkb_types "t" {
        \\    virtual_modifiers LevelThree;
        \\    type "ONE_LEVEL" { modifiers=none; map[none]=Level1; };
        \\  };
        \\  xkb_compat "c" {
        \\    virtual_modifiers LevelThree;
        \\    interpret a+AnyOfOrNone(none) {
        \\      virtualModifier=LevelThree;
        \\      action=SetMods(modifiers=Shift);
        \\    };
        \\  };
        \\  xkb_symbols "s" {
        \\    key <AE01> { [ a ] };
        \\  };
        \\};
    ;
    const km = try keymap.Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    // Baseline: the interpret must have virtual_mod resolved (not invalid).
    try std.testing.expect(km.sym_interprets.len > 0);
    try std.testing.expect(km.sym_interprets[0].virtual_mod != keymap.mod_index_invalid);

    // Serialize and check the output contains virtualModifier=LevelThree.
    const text = try km.getAsString(.text_v1);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "virtualModifier=LevelThree") != null);

    // Re-compile from serialized text: virtual_mod must still be non-invalid.
    const km2 = try keymap.Keymap.newFromString(ctx, text, .text_v1);
    defer km2.destroy();
    try std.testing.expect(km2.sym_interprets.len > 0);
    try std.testing.expect(km2.sym_interprets[0].virtual_mod != keymap.mod_index_invalid);
}

test "serializeSymbols: output contains expected tokens" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" {
        \\    minimum=8; maximum=255;
        \\    <AE01>=10; <LFSH>=50;
        \\  };
        \\  xkb_types "t" {
        \\    type "ONE_LEVEL" { modifiers=none; map[none]=Level1; level_name[Level1]="Any"; };
        \\    type "TWO_LEVEL" { modifiers=Shift; map[Shift]=Level2; level_name[Level1]="Base"; level_name[Level2]="Shift"; };
        \\  };
        \\  xkb_compat "c" { };
        \\  xkb_symbols "s" {
        \\    key <AE01> { type="TWO_LEVEL", [ 1, exclam ] };
        \\    key <LFSH> { [ Shift_L ] };
        \\    modifier_map Shift { <LFSH> };
        \\  };
        \\};
    ;
    const km = try keymap.Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try serializeSymbols(km, &aw.writer);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "xkb_symbols") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "key <AE01> {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " 1,") != null or std.mem.indexOf(u8, out, " 1 ]") != null or std.mem.indexOf(u8, out, "[ 1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exclam") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "modifier_map Shift") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<LFSH>") != null);
}
