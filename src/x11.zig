const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();
const xcb = @import("xcb");
const Context = @import("context.zig").Context;
const Atom = @import("context.zig").Atom;
const Keysym = @import("keysym.zig").Keysym;
const keymap_mod = @import("keymap.zig");
const Keymap = keymap_mod.Keymap;
const Mod = keymap_mod.Mod;
const KeyType = keymap_mod.KeyType;
const Key = keymap_mod.Key;
const Group = keymap_mod.Group;
const Level = keymap_mod.Level;
const Led = keymap_mod.Led;
const SymInterpret = keymap_mod.SymInterpret;
const MatchOp = keymap_mod.MatchOp;
const Action = keymap_mod.Action;

/// XkbUseCoreKbd: the core keyboard device spec.
pub const CORE_KEYBOARD: u16 = 0x0100;

/// Map XKB wire match-op nibble to MatchOp enum.
fn wireMatchOp(raw: u4) MatchOp {
    return switch (raw) {
        0 => .none_of,
        1 => .any_of_or_none,
        2 => .any_of,
        3 => .all_of,
        4 => .exactly,
        else => .none,
    };
}

/// Decode an 8-byte raw XkbAction body into an Action.
/// Decodes SetMods (1), LatchMods (2), LockMods (3), Terminate (0x0C).
/// Everything else becomes .private.
fn decodeXkbAction(raw: [8]u8) Action {
    return switch (raw[0]) {
        0 => .none,
        1 => .{ .mods = .{ .kind = .set, .mods = @as(u32, raw[3]), .mods_by_name = false, .flags = @bitCast(raw[1]) } },
        2 => .{ .mods = .{ .kind = .latch, .mods = @as(u32, raw[3]), .mods_by_name = false, .flags = @bitCast(raw[1]) } },
        3 => .{ .mods = .{ .kind = .lock, .mods = @as(u32, raw[3]), .mods_by_name = false, .flags = @bitCast(raw[1]) } },
        0x0C => .terminate,
        else => .{ .private = .{ .kind = raw[0], .data = raw[1..8].* } },
    };
}

/// Apply sym_interprets to all key levels that have no explicit action.
/// Same semantics as compile_link.findMatchingInterpret.
fn applyCompatPass(km: *Keymap) void {
    for (km.keys) |*key| {
        if (key.keycode == 0) continue;
        for (key.groups) |*group| {
            for (group.levels, 0..) |*level, l_idx| {
                if (std.meta.activeTag(level.action) != .none) continue;
                if (level.syms.len != 1) continue;
                const sym = level.syms[0];
                if (findBestInterp(km.sym_interprets, sym, key.modmap, l_idx)) |interp| {
                    level.action = interp.action;
                }
            }
        }
    }
}

fn interpModMatch(match: MatchOp, interp_mods: keymap_mod.ModMask, key_modmap: keymap_mod.ModMask) bool {
    return switch (match) {
        .none => false,
        .any_of_or_none => key_modmap == 0 or (key_modmap & interp_mods) != 0,
        .none_of => (key_modmap & interp_mods) == 0,
        .any_of => (key_modmap & interp_mods) != 0,
        .all_of => (key_modmap & interp_mods) == interp_mods,
        .exactly => key_modmap == interp_mods,
    };
}

fn findBestInterp(
    interprets: []const SymInterpret,
    sym: Keysym,
    modmap: keymap_mod.ModMask,
    level_idx: usize,
) ?SymInterpret {
    var wildcard: ?SymInterpret = null;
    for (interprets) |interp| {
        if (interp.level_one_only and level_idx > 0) continue;
        const sym_ok = if (interp.sym) |isym| isym == sym else true;
        if (!sym_ok) continue;
        if (!interpModMatch(interp.match, interp.mods, modmap)) continue;
        if (interp.sym != null) return interp;
        if (wildcard == null) wildcard = interp;
    }
    return wildcard;
}

/// Build a Keymap from a live X server using XkbGetMap, XkbGetNames, XkbGetControls,
/// and XkbGetCompatMap. All requests are pipelined before reading replies.
/// device_spec is typically CORE_KEYBOARD (0x0100).
pub fn keymapNewFromDevice(ctx: *Context, conn: *xcb.conn.Connection, device_spec: u16) !*Keymap {
    const xkb_setup = try xcb.xkb.setupXkb(conn);

    const min_kc = conn.setup.min_keycode;
    const max_kc = conn.setup.max_keycode;
    const n_kc: u8 = max_kc -% min_kc +% 1;

    var map_extra: [24]u8 = std.mem.zeroes([24]u8);
    std.mem.writeInt(u16, map_extra[0..2], device_spec, native_endian);
    std.mem.writeInt(u16, map_extra[2..4], 0x00ff, native_endian);
    std.mem.writeInt(u16, map_extra[4..6], 0x0000, native_endian);
    map_extra[6] = 0;
    map_extra[7] = 0;
    map_extra[8] = min_kc;
    map_extra[9] = n_kc;
    map_extra[10] = min_kc;
    map_extra[11] = n_kc;
    map_extra[12] = min_kc;
    map_extra[13] = n_kc;
    std.mem.writeInt(u16, map_extra[14..16], 0xffff, native_endian);
    map_extra[16] = min_kc;
    map_extra[17] = n_kc;
    map_extra[18] = min_kc;
    map_extra[19] = n_kc;
    map_extra[20] = min_kc;
    map_extra[21] = n_kc;
    const seq_map = try conn.sendRequest(xkb_setup.major_opcode, 8, &map_extra);

    var names_extra: [8]u8 = std.mem.zeroes([8]u8);
    std.mem.writeInt(u16, names_extra[0..2], device_spec, native_endian);
    std.mem.writeInt(u32, names_extra[4..8], 0x3FFF, native_endian);
    const seq_names = try conn.sendRequest(xkb_setup.major_opcode, 17, &names_extra);

    var ctrl_extra: [4]u8 = std.mem.zeroes([4]u8);
    std.mem.writeInt(u16, ctrl_extra[0..2], device_spec, native_endian);
    const seq_ctrl = try conn.sendRequest(xkb_setup.major_opcode, 6, &ctrl_extra);

    var compat_extra: [8]u8 = std.mem.zeroes([8]u8);
    std.mem.writeInt(u16, compat_extra[0..2], device_spec, native_endian);
    compat_extra[2] = 0xFF; // groups: all
    compat_extra[3] = 1; // getAllSI: true
    const seq_compat = try conn.sendRequest(xkb_setup.major_opcode, 10, &compat_extra);

    // Read all four replies using a single shared stream reader.
    var xe: xcb.proto.XError = undefined;
    var read_buf: [4096]u8 = undefined;
    var sr = conn.stream.reader(conn.io, &read_buf);

    var reply_map = try xcb.conn.readReplyFrom(&sr.interface, ctx.allocator, seq_map, &xe);
    defer reply_map.deinit();
    var map = try xcb.xkb_map.parseGetMap(ctx.allocator, reply_map.bytes);
    defer map.deinit();

    var reply_names = try xcb.conn.readReplyFrom(&sr.interface, ctx.allocator, seq_names, &xe);
    defer reply_names.deinit();
    var names_reply = try xcb.xkb_names.parseGetNames(ctx.allocator, reply_names.bytes);
    defer names_reply.deinit();

    var reply_ctrl = try xcb.conn.readReplyFrom(&sr.interface, ctx.allocator, seq_ctrl, &xe);
    defer reply_ctrl.deinit();
    const controls = try xcb.xkb_controls.parseGetControls(reply_ctrl.bytes);

    var reply_compat = try xcb.conn.readReplyFrom(&sr.interface, ctx.allocator, seq_compat, &xe);
    defer reply_compat.deinit();
    var compat_reply = try xcb.xkb_compat.parseGetCompatMap(ctx.allocator, reply_compat.bytes);
    defer compat_reply.deinit();

    // Collect unique non-zero atom IDs across all name arrays.
    var uniq = std.AutoHashMap(u32, void).init(ctx.allocator);
    defer uniq.deinit();

    for (names_reply.type_names) |a| if (a != 0) try uniq.put(a, {});
    for (names_reply.indicator_names) |a| if (a != 0) try uniq.put(a, {});
    for (names_reply.virtual_mod_names) |a| if (a != 0) try uniq.put(a, {});
    for (names_reply.group_names) |a| if (a != 0) try uniq.put(a, {});

    // Pipeline GetAtomName requests (core opcode 17, extra = atom:u32).
    const AtomSeq = struct { atom: u32, seq: u16 };
    var atom_seqs: std.ArrayList(AtomSeq) = .empty;
    defer atom_seqs.deinit(ctx.allocator);

    var kit = uniq.keyIterator();
    while (kit.next()) |atom_ptr| {
        var atom_extra: [4]u8 = undefined;
        std.mem.writeInt(u32, &atom_extra, atom_ptr.*, native_endian);
        const seq = try conn.sendRequest(17, 0, &atom_extra);
        try atom_seqs.append(ctx.allocator, .{ .atom = atom_ptr.*, .seq = seq });
    }

    // Read all GetAtomName replies (same shared sr reader).
    // Reply layout: [8..10] nameLength u16, [32..] name bytes.
    var resolved = std.AutoHashMap(u32, []u8).init(ctx.allocator);
    defer {
        var vit = resolved.valueIterator();
        while (vit.next()) |v| ctx.allocator.free(v.*);
        resolved.deinit();
    }

    for (atom_seqs.items) |as| {
        var atom_reply = try xcb.conn.readReplyFrom(&sr.interface, ctx.allocator, as.seq, &xe);
        defer atom_reply.deinit();
        if (atom_reply.bytes.len < 32) continue;
        const name_len = std.mem.readInt(u16, atom_reply.bytes[8..10], native_endian);
        const end: usize = 32 + @as(usize, name_len);
        if (atom_reply.bytes.len < end or name_len == 0) continue;
        const name = try ctx.allocator.dupe(u8, atom_reply.bytes[32..end]);
        errdefer ctx.allocator.free(name);
        try resolved.put(as.atom, name);
    }

    const km = try keymapFromGetMap(ctx, &map, controls.num_groups, &names_reply);
    errdefer km.destroy();

    const arena = km.arena.allocator();

    for (km.types, 0..) |*kt, i| {
        if (i >= names_reply.type_names.len) break;
        const atom_id = names_reply.type_names[i];
        if (atom_id != 0) {
            if (resolved.get(atom_id)) |name| {
                kt.name = try ctx.intern(name);
            }
        }
    }

    if (names_reply.indicator_names.len > 0) {
        const leds = try arena.alloc(Led, names_reply.indicator_names.len);
        for (leds, names_reply.indicator_names) |*led, atom_id| {
            const led_name: Atom = if (atom_id != 0) blk: {
                if (resolved.get(atom_id)) |name| break :blk try ctx.intern(name);
                break :blk .none;
            } else .none;
            led.* = .{
                .name = led_name,
                .mods = 0,
                .groups = 0,
                .ctrls = 0,
                .which_mods = .{},
                .which_groups = .{},
            };
        }
        km.leds = leds;
    }

    if (names_reply.group_names.len > 0) {
        const gnames = try arena.alloc(Atom, names_reply.group_names.len);
        for (gnames, names_reply.group_names) |*gn, atom_id| {
            gn.* = if (atom_id != 0) blk: {
                if (resolved.get(atom_id)) |name| break :blk try ctx.intern(name);
                break :blk .none;
            } else .none;
        }
        km.group_names = gnames;
    }

    if (compat_reply.interprets.len > 0) {
        const interprets = try arena.alloc(SymInterpret, compat_reply.interprets.len);
        for (compat_reply.interprets, interprets) |ci, *si| {
            si.* = .{
                .sym = if (ci.sym == 0) null else @enumFromInt(ci.sym),
                .match = wireMatchOp(@truncate(ci.match & 0x0F)),
                .mods = @as(u32, ci.mods),
                .virtual_mod = keymap_mod.mod_index_invalid,
                .action = decodeXkbAction(ci.action),
                .level_one_only = (ci.match & 0x80) != 0,
                .repeat = (ci.flags & 0x02) != 0,
            };
        }
        km.sym_interprets = interprets;
        applyCompatPass(km);
    }

    return km;
}

/// Build a xkbcommon.Keymap from a parsed XkbGetMap reply.
/// num_groups is used as the group count fallback when a key's group_info is 0.
/// names, if provided, supplies real key names from XkbGetNames; otherwise synthetic names are used.
pub fn keymapFromGetMap(ctx: *Context, map: *const xcb.xkb_map.GetMapReply, num_groups: u8, names: ?*const xcb.xkb_names.GetNamesReply) !*Keymap {
    const km = try Keymap.create(ctx);
    errdefer km.destroy();

    const arena = km.arena.allocator();

    // mods: 8 real mods, Shift..Mod5 in bit order 0..7
    const mod_names = [8][]const u8{ "Shift", "Lock", "Control", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5" };
    const mods = try arena.alloc(Mod, 8);
    for (mods, 0..) |*m, i| {
        m.* = .{
            .name = try ctx.intern(mod_names[i]),
            .type = .real,
            .mapping = @as(u32, 1) << @intCast(i),
        };
    }
    km.mods = .{ .mods = mods };

    const types = try arena.alloc(KeyType, map.types.len);
    for (types, 0..) |*kt, i| {
        const xtype = &map.types[i];

        var name_buf: [32]u8 = undefined;
        const name_str = try std.fmt.bufPrint(&name_buf, "type{}", .{i});
        const name_atom = try ctx.intern(name_str);

        const entries = try arena.alloc(KeyType.Entry, xtype.entries.len);
        for (entries, 0..) |*e, j| {
            const xe = &xtype.entries[j];
            e.* = .{
                .level = xe.level,
                .mods = xe.mods_mods,
                .preserve = 0,
            };
        }

        kt.* = .{
            .name = name_atom,
            .mods = xtype.mods_mask,
            .num_levels = xtype.num_levels,
            .entries = entries,
            .level_names = &.{},
        };
    }
    km.types = types;

    const max_kc: usize = map.header.max_key_code;
    const min_kc: usize = map.header.min_key_code;
    const first_key_sym: usize = map.header.first_key_sym;

    const keys = try arena.alloc(Key, max_kc + 1);
    for (keys, 0..) |*key, kc| {
        key.* = .{
            .name = blk: {
                if (names) |n| {
                    if (xcb.xkb_names.keyName(n, @intCast(kc))) |name| {
                        break :blk try ctx.intern(name);
                    }
                }
                var buf: [8]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "K{d}", .{kc});
                break :blk try ctx.intern(s);
            },
            .keycode = @intCast(kc),
            .repeats = false,
            .modmap = 0,
            .out_of_range_group_action = .wrap,
            .out_of_range_group_number = 0,
            .groups = &.{},
        };
    }

    for (map.modmap) |entry| {
        const kc: usize = entry.keycode;
        if (kc <= max_kc) {
            keys[kc].modmap = entry.mods;
        }
    }

    for (min_kc..max_kc + 1) |kc| {
        if (kc < first_key_sym) continue;
        const idx = kc - first_key_sym;
        if (idx >= map.syms.len) continue;

        const sm = &map.syms[idx];
        const ng_raw = xcb.xkb_map.groupCount(sm);
        const ng: usize = if (ng_raw == 0) @as(usize, num_groups) else ng_raw;
        if (ng == 0) continue;

        const groups = try arena.alloc(Group, ng);
        for (groups, 0..) |*g, grp_i| {
            const kt_raw: usize = sm.kt_index[if (grp_i < 4) grp_i else 3];
            const type_idx = @min(kt_raw, if (types.len > 0) types.len - 1 else 0);
            const num_levels: usize = if (types.len > 0) types[type_idx].num_levels else 1;

            const levels = try arena.alloc(Level, num_levels);
            for (levels, 0..) |*lvl, lvl_i| {
                const sym_val = xcb.xkb_map.symForKey(
                    map,
                    @intCast(kc),
                    @intCast(grp_i),
                    @intCast(lvl_i),
                ) orelse 0;
                const sym_slice = try arena.alloc(Keysym, 1);
                sym_slice[0] = @enumFromInt(sym_val);
                lvl.* = .{
                    .syms = sym_slice,
                    .action = .none,
                };
            }

            g.* = .{
                .explicit_type = true,
                .type_index = @intCast(type_idx),
                .levels = levels,
            };
        }

        keys[kc].groups = groups;
    }

    km.keys = keys;
    km.min_key_code = @intCast(min_kc);
    km.max_key_code = @intCast(max_kc);
    km.leds = &.{};
    km.sym_interprets = &.{};
    km.key_aliases = &.{};
    km.group_names = &.{};

    return km;
}

test "x11 hermetic: synthetic getmap bytes -> Keymap -> State, kc8='a'/'A'" {
    // Build a minimal GetMapReply with:
    //   present=0x0007 (KeyTypes|KeySyms|ModifierMap), minKc=8, maxKc=9
    //   1 KeyType: mods_mask=Shift(0x1), numLevels=2, 1 map entry (Shift->level1)
    //   1 KeySymMap for kc8: group_info=1, width=2, syms=[0x61 'a', 0x41 'A']
    //   1 ModMapEntry: kc=8, mods=0
    //
    // The KT map entry is needed so State.getLevel can compute level 1 when Shift
    // is active (it checks entry.mods == active_mods; entry.mods comes from the
    // wire mods_mods field at KTMapEntry offset +3).
    const State = @import("state.zig").State;
    const ctx = try Context.create(std.testing.allocator, std.testing.io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();

    // Layout (offsets):
    //  [0..40]  fixed header
    //  [40..48] KeyType header (8 bytes)
    //  [48..56] KT map entry (8 bytes: active, mods_mask, level, mods_mods, vmods u16, pad u16)
    //  [56..64] KeySymMap header (8 bytes: kt_index[4], group_info, width, n_syms u16)
    //  [64..72] 2 keysyms (u32 each)
    //  [72..76] 1 ModMapEntry (2 bytes) + 2 bytes pad
    var bytes = [_]u8{0} ** 76;

    // Fixed header (40 bytes)
    bytes[10] = 8; // minKeyCode
    bytes[11] = 9; // maxKeyCode
    std.mem.writeInt(u16, bytes[12..14], 0x0007, native_endian); // present
    bytes[15] = 1; // nTypes
    bytes[16] = 1; // totalTypes
    bytes[17] = 8; // firstKeySym
    std.mem.writeInt(u16, bytes[18..20], 2, native_endian); // totalSyms
    bytes[20] = 1; // nKeySyms
    bytes[33] = 1; // totalModMapKeys

    // KeyType header at offset 40
    bytes[40] = 0x01; // mods_mask = Shift bit
    bytes[41] = 0x01; // mods_mods
    std.mem.writeInt(u16, bytes[42..44], 0, native_endian); // mods_vmods
    bytes[44] = 2; // numLevels
    bytes[45] = 1; // nMapEntries = 1
    bytes[46] = 0; // hasPreserve = 0

    // KT map entry at offset 48 (8 bytes)
    bytes[48] = 1; // active
    bytes[49] = 0x01; // mods_mask = Shift
    bytes[50] = 1; // level = 1 (becomes entry.level)
    bytes[51] = 0x01; // mods_mods = Shift (becomes entry.mods in KeyType.Entry)
    std.mem.writeInt(u16, bytes[52..54], 0, native_endian); // mods_vmods
    std.mem.writeInt(u16, bytes[54..56], 0, native_endian); // pad

    // KeySymMap at offset 56
    // bytes[56..60] = kt_index = {0,0,0,0} (already 0)
    bytes[60] = 1; // group_info: 1 group
    bytes[61] = 2; // width
    std.mem.writeInt(u16, bytes[62..64], 2, native_endian); // n_syms
    std.mem.writeInt(u32, bytes[64..68], 0x61, native_endian); // sym[0] = 'a'
    std.mem.writeInt(u32, bytes[68..72], 0x41, native_endian); // sym[1] = 'A'

    // ModifierMap at offset 72 (1 entry = 2 bytes, padded to 4)
    bytes[72] = 8; // keycode
    bytes[73] = 0; // mods
    // bytes[74..76] = 0 (padding)

    var map = try xcb.xkb_map.parseGetMap(std.testing.allocator, &bytes);
    defer map.deinit();

    const km = try keymapFromGetMap(ctx, &map, 1, null);
    defer km.destroy();

    const st = try State.create(km);
    defer st.destroy();

    try std.testing.expectEqual(Keysym.fromName("a", .{}).?, st.keyGetOneSym(8));
    _ = st.updateMask(0x1, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(Keysym.fromName("A", .{}).?, st.keyGetOneSym(8));
}
