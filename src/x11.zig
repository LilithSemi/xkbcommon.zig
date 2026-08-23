//! Keymap retrieval from a live X server over the XKEYBOARD extension.
//!
//! Wire structures come from x11.zig's generated xcbproto bindings (`xproto`
//! and `xkbproto`): those decode the packets. What lives here is the reading of
//! XKB's irregular, presence-driven reply payloads into an xkbcommon Keymap,
//! plus the bounds validation those payloads need before anything walks them.

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();
const x11 = @import("x11");
const xproto = @import("xproto");
const xkbproto = @import("xkbproto");
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
const ModsFlags = keymap_mod.ModsFlags;
const SymInterpret = keymap_mod.SymInterpret;
const MatchOp = keymap_mod.MatchOp;
const Action = keymap_mod.Action;

/// XkbUseCoreKbd: the core keyboard device spec.
pub const CORE_KEYBOARD: u16 = 0x0100;

/// Faults raised by reading an X reply. Every one of them means the server (or
/// something impersonating it) sent bytes that do not describe a usable reply.
pub const DecodeError = error{
    /// The buffer ends before a section the reply header says is present.
    ShortReply,
    /// A length or offset in the reply cannot be represented, or the header
    /// contradicts itself (max_key_code below min_key_code, for instance).
    MalformedReply,
};

pub const ParseError = DecodeError || std.mem.Allocator.Error;

/// Every XkbGetMap reply starts with 40 fixed bytes; sections follow.
const map_header_len: usize = 40;
/// KeyType: 8 header bytes, then nMapEntries KTMapEntry, then the preserve list.
const key_type_header_len: usize = 8;
const kt_map_entry_len: usize = 8;
const mod_def_len: usize = 4;
/// KeySymMap: 8 header bytes, then nSyms 32-bit keysyms.
const key_sym_map_len: usize = 8;
const keysym_len: usize = 4;
/// XkbAction and its per-key record widths.
const action_len: usize = 8;
const set_behavior_len: usize = 4;
const set_explicit_len: usize = 2;
const key_mod_map_len: usize = 2;
const key_vmod_map_len: usize = 4;
/// Both XkbGetNames and XkbGetCompatMap put their variable data after 32 bytes.
const reply_header_len: usize = 32;
/// XkbGetControls carries numGroups at byte 9.
const controls_num_groups_offset: usize = 9;

/// Ask XkbGetNames for every name section the protocol defines (bits 0 to 13).
const names_which_all: u32 = (@as(u32, @intFromEnum(xkbproto.NameDetail.RGNames)) << 1) - 1;
/// Ask XkbGetMap for every map component (bits 0 to 7).
const map_full_all: u16 = (@as(u16, @intFromEnum(xkbproto.MapPart.VirtualModMap)) << 1) - 1;

// The bindings declare the SymInterpret match bits as enum(u32), but the wire
// field is one byte, so narrow them once here instead of at every use.
const si_op_mask: u8 = @intFromEnum(xkbproto.SymInterpMatch.OpMask);
const si_level_one_only: u8 = @intFromEnum(xkbproto.SymInterpMatch.LevelOneOnly);
/// XkbSI_AutoRepeat, from X11/extensions/XKB.h.
const si_auto_repeat: u8 = 1 << 0;

fn addChecked(a: usize, b: usize) DecodeError!usize {
    return std.math.add(usize, a, b) catch error.MalformedReply;
}

fn mulChecked(a: usize, b: usize) DecodeError!usize {
    return std.math.mul(usize, a, b) catch error.MalformedReply;
}

/// Round a section offset up to the 4-byte boundary XKB pads every section to.
fn align4(n: usize) DecodeError!usize {
    return (try addChecked(n, 3)) & ~@as(usize, 3);
}

// ---------------------------------------------------------------------------
// XkbGetMap
// ---------------------------------------------------------------------------

/// Walk every section an XkbGetMap reply header claims, in wire order, and
/// confirm the buffer actually holds them.
///
/// This has to run before `decodeGetMapReply`. The KeyType and KeySymMap
/// sections are variable-length, so the generated decoder walks them with a
/// cursor it does not re-check against the buffer: a header claiming more
/// records than the buffer holds makes it slice past the end. A reply is bytes
/// off a socket, so that has to be a returned error rather than a panic.
///
/// The traversal below mirrors the generated decoder step for step, including
/// its section order and its padding, so passing here means the decode is safe.
fn validateGetMap(bytes: []const u8) DecodeError!void {
    if (bytes.len < map_header_len) return error.ShortReply;

    const present = std.mem.readInt(u16, bytes[12..14], native_endian);
    const n_types: usize = bytes[15];
    const total_actions: usize = std.mem.readInt(u16, bytes[22..24], native_endian);
    const n_key_actions: usize = bytes[24];
    const n_key_syms: usize = bytes[20];
    const total_key_behaviors: usize = bytes[27];
    const total_key_explicit: usize = bytes[30];
    const total_mod_map_keys: usize = bytes[33];
    const total_vmod_map_keys: usize = bytes[36];
    const virtual_mods = std.mem.readInt(u16, bytes[38..40], native_endian);

    var off: usize = map_header_len;

    if (present & @intFromEnum(xkbproto.MapPart.KeyTypes) != 0) {
        for (0..n_types) |_| {
            if (try addChecked(off, key_type_header_len) > bytes.len) return error.ShortReply;
            const n_entries: usize = bytes[off + 5];
            const has_preserve = bytes[off + 6] != 0;
            off = try addChecked(off, key_type_header_len);
            off = try addChecked(off, try mulChecked(n_entries, kt_map_entry_len));
            if (has_preserve) off = try addChecked(off, try mulChecked(n_entries, mod_def_len));
            if (off > bytes.len) return error.ShortReply;
        }
    }

    if (present & @intFromEnum(xkbproto.MapPart.KeySyms) != 0) {
        for (0..n_key_syms) |_| {
            if (try addChecked(off, key_sym_map_len) > bytes.len) return error.ShortReply;
            const n_syms: usize = std.mem.readInt(u16, bytes[off + 6 ..][0..2], native_endian);
            off = try addChecked(off, key_sym_map_len);
            off = try addChecked(off, try mulChecked(n_syms, keysym_len));
            if (off > bytes.len) return error.ShortReply;
        }
    }

    // Key actions are a count byte per key, padded to 4, then the action bodies.
    if (present & @intFromEnum(xkbproto.MapPart.KeyActions) != 0) {
        off = try align4(try addChecked(off, n_key_actions));
        off = try addChecked(off, try mulChecked(total_actions, action_len));
        if (off > bytes.len) return error.ShortReply;
    }

    if (present & @intFromEnum(xkbproto.MapPart.KeyBehaviors) != 0) {
        off = try addChecked(off, try mulChecked(total_key_behaviors, set_behavior_len));
        if (off > bytes.len) return error.ShortReply;
    }

    // One byte per virtual modifier that the virtualMods mask names.
    if (present & @intFromEnum(xkbproto.MapPart.VirtualMods) != 0) {
        off = try align4(try addChecked(off, @popCount(virtual_mods)));
        if (off > bytes.len) return error.ShortReply;
    }

    if (present & @intFromEnum(xkbproto.MapPart.ExplicitComponents) != 0) {
        off = try align4(try addChecked(off, try mulChecked(total_key_explicit, set_explicit_len)));
        if (off > bytes.len) return error.ShortReply;
    }

    if (present & @intFromEnum(xkbproto.MapPart.ModifierMap) != 0) {
        off = try align4(try addChecked(off, try mulChecked(total_mod_map_keys, key_mod_map_len)));
        if (off > bytes.len) return error.ShortReply;
    }

    if (present & @intFromEnum(xkbproto.MapPart.VirtualModMap) != 0) {
        off = try addChecked(off, try mulChecked(total_vmod_map_keys, key_vmod_map_len));
        if (off > bytes.len) return error.ShortReply;
    }
}

/// A validated XkbGetMap reply with its variable-length sections flattened into
/// indexable slices.
///
/// The generated decoder hands back forward-only iterators over the KeyType and
/// KeySymMap sections, but building a keymap needs random access by keycode, so
/// they are walked once into arena-owned slices here instead of being re-walked
/// per lookup.
///
/// The slices borrow the reply buffer passed to `parseGetMap`. That buffer must
/// outlive the view.
pub const MapView = struct {
    arena: std.heap.ArenaAllocator,
    reply: xkbproto.GetMapReply,
    types: []const xkbproto.KeyType,
    /// KeySymMap records, indexed by (keycode - reply.firstKeySym).
    syms: []const xkbproto.KeySymMap,
    modmap: []const xkbproto.KeyModMap,

    pub fn deinit(self: *MapView) void {
        self.arena.deinit();
    }

    /// The keysym for (keycode, group, level), or null when any of them is out
    /// of range for this map.
    pub fn symForKey(self: *const MapView, keycode: u8, group: u8, level: u8) ?u32 {
        if (keycode < self.reply.firstKeySym) return null;
        const idx: usize = @as(usize, keycode) - @as(usize, self.reply.firstKeySym);
        if (idx >= self.syms.len) return null;

        const m = self.syms[idx];
        if (group >= groupCount(m)) return null;
        if (level >= m.width) return null;

        const row = std.math.mul(usize, group, m.width) catch return null;
        const offset = std.math.add(usize, row, level) catch return null;
        if (offset >= m.syms.len) return null;
        return m.syms[offset];
    }
};

/// Number of groups a KeySymMap defines (the low nibble of groupInfo).
pub fn groupCount(m: xkbproto.KeySymMap) u8 {
    return m.groupInfo & 0x0f;
}

/// Validate and decode an XkbGetMap reply.
///
/// `bytes` is borrowed by the returned view and must outlive it. Call `deinit`
/// on the view to release the flattened section slices.
pub fn parseGetMap(gpa: std.mem.Allocator, bytes: []const u8) ParseError!MapView {
    try validateGetMap(bytes);

    const reply = xkbproto.decodeGetMapReply(bytes);

    // A map whose last keycode precedes its first describes no keys at all and
    // would make the keycode loop in keymapFromGetMap run backwards. The old
    // parser passed such a header straight through.
    if (reply.maxKeyCode < reply.minKeyCode) return error.MalformedReply;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var types: []xkbproto.KeyType = &.{};
    if (reply.values.types_rtrn) |iter_const| {
        var iter = iter_const;
        types = try a.alloc(xkbproto.KeyType, iter.len());
        var i: usize = 0;
        while (iter.next()) |kt| : (i += 1) types[i] = kt;
    }

    var syms: []xkbproto.KeySymMap = &.{};
    if (reply.values.syms_rtrn) |iter_const| {
        var iter = iter_const;
        syms = try a.alloc(xkbproto.KeySymMap, iter.len());
        var i: usize = 0;
        while (iter.next()) |ksm| : (i += 1) syms[i] = ksm;
    }

    var modmap: []xkbproto.KeyModMap = &.{};
    if (reply.values.modmap_rtrn) |list| {
        modmap = try a.alloc(xkbproto.KeyModMap, list.len());
        for (modmap, 0..) |*e, i| e.* = list.at(i);
    }

    return .{
        .arena = arena,
        .reply = reply,
        .types = types,
        .syms = syms,
        .modmap = modmap,
    };
}

// ---------------------------------------------------------------------------
// XkbGetNames
// ---------------------------------------------------------------------------

/// A decoded XkbGetNames reply. Every slice it hands out borrows the reply
/// buffer passed to `parseGetNames`, which must outlive the view.
pub const NamesView = struct {
    reply: xkbproto.GetNamesReply,

    /// One atom per key type.
    pub fn typeNames(self: *const NamesView) []align(1) const xproto.ATOM {
        return self.reply.values.typeNames orelse &.{};
    }

    /// One atom per named indicator.
    pub fn indicatorNames(self: *const NamesView) []align(1) const xproto.ATOM {
        return self.reply.values.indicatorNames orelse &.{};
    }

    /// One atom per named virtual modifier.
    pub fn virtualModNames(self: *const NamesView) []align(1) const xproto.ATOM {
        return self.reply.values.virtualModNames orelse &.{};
    }

    /// One atom per named group.
    pub fn groupNames(self: *const NamesView) []align(1) const xproto.ATOM {
        return self.reply.values.groups orelse &.{};
    }

    /// The name of a key, or null when the keycode is out of range or unnamed.
    pub fn keyName(self: *const NamesView, keycode: u8) ?[]const u8 {
        const names = self.reply.values.keyNames orelse return null;
        if (keycode < self.reply.firstKey) return null;
        const idx: usize = @as(usize, keycode) - @as(usize, self.reply.firstKey);
        if (idx >= names.len()) return null;

        const raw = names.at(idx).name;
        // KEYNAME is a fixed 4-byte field padded with NULs, so the name ends at
        // the first NUL. The old parser only trimmed trailing NULs, which let an
        // embedded NUL through into the interned atom.
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        if (end == 0) return null;
        return raw[0..end];
    }
};

/// Decode an XkbGetNames reply. `bytes` is borrowed by the returned view.
pub fn parseGetNames(bytes: []const u8) DecodeError!NamesView {
    if (bytes.len < reply_header_len) return error.ShortReply;
    // Every list in this reply is bounded against the buffer by the generated
    // decoder, so a truncated section decodes as empty rather than overrunning.
    return .{ .reply = xkbproto.decodeGetNamesReply(bytes) };
}

// ---------------------------------------------------------------------------
// XkbGetControls and XkbGetCompatMap
// ---------------------------------------------------------------------------

/// The one XkbGetControls field a keymap needs: how many groups the device has.
pub const ControlsView = struct {
    num_groups: u8,
};

pub fn parseGetControls(bytes: []const u8) DecodeError!ControlsView {
    if (bytes.len <= controls_num_groups_offset) return error.ShortReply;
    return .{ .num_groups = xkbproto.decodeGetControlsReply(bytes).numGroups };
}

/// A decoded XkbGetCompatMap reply. `interprets` borrows the reply buffer.
pub const CompatView = struct {
    reply: xkbproto.GetCompatMapReply,

    pub fn interprets(self: *const CompatView) xkbproto.ListView(xkbproto.SymInterpret) {
        return self.reply.si_rtrn;
    }
};

/// Decode an XkbGetCompatMap reply. `bytes` is borrowed by the returned view.
pub fn parseGetCompatMap(bytes: []const u8) DecodeError!CompatView {
    if (bytes.len < reply_header_len) return error.ShortReply;
    return .{ .reply = xkbproto.decodeGetCompatMapReply(bytes) };
}

// ---------------------------------------------------------------------------
// XKB extension setup
// ---------------------------------------------------------------------------

pub const XkbSetup = struct {
    major_opcode: u8,
    server_major: u16,
    server_minor: u16,
};

/// Negotiate the XKEYBOARD extension. A server refuses every other XKB request
/// until XkbUseExtension has agreed on a version, so this runs first.
pub fn setupXkb(client: *x11.Client) !XkbSetup {
    const info = try client.queryExtension(xkbproto.extension_xname);
    if (!info.present) return error.XkbNotSupported;

    const c = try xkbproto.use_extension(client, 1, 0);
    var xe: x11.wire.XError = undefined;
    var reply = try client.awaitReply(xkbproto.UseExtensionReply, c, &xe);
    defer reply.deinit();

    const use = xkbproto.decodeUseExtensionReply(reply.bytes);
    if (!use.supported) return error.XkbVersionUnsupported;
    return .{
        .major_opcode = info.major_opcode,
        .server_major = use.serverMajor,
        .server_minor = use.serverMinor,
    };
}

// ---------------------------------------------------------------------------
// Compat interpretation
// ---------------------------------------------------------------------------

/// Map an XKB wire match op to a MatchOp.
///
/// Ops above Exactly are not defined by the protocol. They resolve to `.none`,
/// which never matches, so a server sending one loses that single interpret
/// instead of the whole keymap.
fn wireMatchOp(raw: u8) MatchOp {
    return switch (raw) {
        0 => .none_of,
        1 => .any_of_or_none,
        2 => .any_of,
        3 => .all_of,
        4 => .exactly,
        else => .none,
    };
}

/// Read an 8-byte XkbAction body into an Action.
///
/// SetMods (1), LatchMods (2), LockMods (3) and Terminate (0x0C) are modelled;
/// everything else is kept verbatim as `.private` so no data is lost.
fn decodeXkbAction(wire: xkbproto.SIAction) Action {
    // A complete SymInterpret always carries all 7 data bytes. A short one only
    // arrives on a malformed reply, and has no action worth reading.
    if (wire.data.len < 7) return .none;

    // Rebuild the wire body so the field offsets come from the generated
    // SASetMods layout rather than from hand-counted indices.
    var raw: [action_len]u8 = undefined;
    raw[0] = wire.type;
    @memcpy(raw[1..action_len], wire.data[0..7]);
    const set_mods = xkbproto.SASetMods.decodeElement(&raw, native_endian);

    const mods_action: Action.ModsAction = .{
        .kind = .set,
        .mods = @as(u32, set_mods.realMods),
        .mods_by_name = false,
        .flags = @as(ModsFlags, @bitCast(set_mods.flags)),
    };

    return switch (wire.type) {
        0 => .none,
        1 => .{ .mods = mods_action },
        2 => .{ .mods = blk: {
            var a = mods_action;
            a.kind = .latch;
            break :blk a;
        } },
        3 => .{ .mods = blk: {
            var a = mods_action;
            a.kind = .lock;
            break :blk a;
        } },
        0x0C => .terminate,
        else => .{ .private = .{ .kind = wire.type, .data = wire.data[0..7].* } },
    };
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

/// Apply sym_interprets to every key level that carries no explicit action.
/// Same semantics as compile_link's compat pass.
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
                    // The X11 path has no explicit per-key repeat setting to
                    // defer to, so a repeating interpret always wins. The old
                    // code left every key non-repeating.
                    if (interp.repeat) key.repeats = true;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Keymap construction
// ---------------------------------------------------------------------------

/// Build a Keymap from a live X server using XkbGetMap, XkbGetNames,
/// XkbGetControls and XkbGetCompatMap. All requests go out before any reply is
/// read; the connection buffers replies by sequence, so the order they arrive
/// in does not matter. `device_spec` is normally `CORE_KEYBOARD`.
pub fn keymapNewFromDevice(ctx: *Context, client: *x11.Client, device_spec: u16) !*Keymap {
    _ = try setupXkb(client);

    const min_kc = client.conn.setup.min_keycode;
    const max_kc = client.conn.setup.max_keycode;
    const n_kc: u8 = max_kc -% min_kc +% 1;

    // `full` already names every component, so the partial ranges only bound
    // the per-keycode sections. firstType/nTypes stay zero for the same reason.
    const map_cookie = try xkbproto.get_map(
        client,
        device_spec,
        map_full_all,
        0,
        0,
        0,
        min_kc,
        n_kc,
        min_kc,
        n_kc,
        min_kc,
        n_kc,
        0xffff,
        min_kc,
        n_kc,
        min_kc,
        n_kc,
        min_kc,
        n_kc,
    );
    const names_cookie = try xkbproto.get_names(client, device_spec, names_which_all);
    const ctrl_cookie = try xkbproto.get_controls(client, device_spec);
    const compat_cookie = try xkbproto.get_compat_map(client, device_spec, 0xff, true, 0, 0);

    var xe: x11.wire.XError = undefined;

    var map_reply = try client.awaitReply(xkbproto.GetMapReply, map_cookie, &xe);
    defer map_reply.deinit();
    var map = try parseGetMap(ctx.allocator, map_reply.bytes);
    defer map.deinit();

    var names_reply = try client.awaitReply(xkbproto.GetNamesReply, names_cookie, &xe);
    defer names_reply.deinit();
    const names = try parseGetNames(names_reply.bytes);

    var ctrl_reply = try client.awaitReply(xkbproto.GetControlsReply, ctrl_cookie, &xe);
    defer ctrl_reply.deinit();
    const controls = try parseGetControls(ctrl_reply.bytes);

    var compat_reply = try client.awaitReply(xkbproto.GetCompatMapReply, compat_cookie, &xe);
    defer compat_reply.deinit();
    const compat = try parseGetCompatMap(compat_reply.bytes);

    // Names arrive as atom ids, so every distinct non-zero id needs one
    // GetAtomName round trip. Collect first, ask once per id.
    var uniq: std.AutoHashMapUnmanaged(xproto.ATOM, void) = .empty;
    defer uniq.deinit(ctx.allocator);

    for ([_][]align(1) const xproto.ATOM{
        names.typeNames(),
        names.indicatorNames(),
        names.virtualModNames(),
        names.groupNames(),
    }) |list| {
        for (list) |atom| {
            if (atom != 0) try uniq.put(ctx.allocator, atom, {});
        }
    }

    const AtomCookie = struct { atom: xproto.ATOM, cookie: x11.cookie.Cookie(xproto.GetAtomNameReply) };
    var atom_cookies: std.ArrayList(AtomCookie) = .empty;
    defer atom_cookies.deinit(ctx.allocator);
    try atom_cookies.ensureTotalCapacity(ctx.allocator, uniq.count());

    var kit = uniq.keyIterator();
    while (kit.next()) |atom| {
        atom_cookies.appendAssumeCapacity(.{
            .atom = atom.*,
            .cookie = try xproto.get_atom_name(client, atom.*),
        });
    }

    var resolved: std.AutoHashMapUnmanaged(xproto.ATOM, Atom) = .empty;
    defer resolved.deinit(ctx.allocator);
    try resolved.ensureTotalCapacity(ctx.allocator, uniq.count());

    for (atom_cookies.items) |ac| {
        var atom_reply = try client.awaitReply(xproto.GetAtomNameReply, ac.cookie, &xe);
        defer atom_reply.deinit();
        const name = xproto.decodeGetAtomNameReply(atom_reply.bytes).name;
        // An empty name is what the decoder yields for a truncated reply, and
        // interning it would name a type or led after nothing.
        if (name.len == 0) continue;
        resolved.putAssumeCapacity(ac.atom, try ctx.intern(name));
    }

    const km = try keymapFromGetMap(ctx, &map, controls.num_groups, &names);
    errdefer km.destroy();

    const arena = km.arena.allocator();

    const type_names = names.typeNames();
    for (km.types, 0..) |*kt, i| {
        if (i >= type_names.len) break;
        if (resolved.get(type_names[i])) |name| kt.name = name;
    }

    const indicator_names = names.indicatorNames();
    if (indicator_names.len > 0) {
        const leds = try arena.alloc(Led, indicator_names.len);
        for (leds, indicator_names) |*led, atom_id| {
            led.* = .{
                .name = resolved.get(atom_id) orelse .none,
                .mods = 0,
                .groups = 0,
                .ctrls = 0,
                .which_mods = .{},
                .which_groups = .{},
            };
        }
        km.leds = leds;
    }

    const group_atoms = names.groupNames();
    if (group_atoms.len > 0) {
        const gnames = try arena.alloc(Atom, group_atoms.len);
        for (gnames, group_atoms) |*gn, atom_id| {
            gn.* = resolved.get(atom_id) orelse .none;
        }
        km.group_names = gnames;
    }

    const wire_interprets = compat.interprets();
    if (wire_interprets.len() > 0) {
        const interprets = try arena.alloc(SymInterpret, wire_interprets.len());
        for (interprets, 0..) |*si, i| {
            const ci = wire_interprets.at(i);
            si.* = .{
                // Keysym is a non-exhaustive enum, so any wire value is a valid
                // tag; 0 is XKB's wildcard rather than a symbol.
                .sym = if (ci.sym == 0) null else @enumFromInt(ci.sym),
                .match = wireMatchOp(ci.match & si_op_mask),
                .mods = @as(u32, ci.mods),
                .virtual_mod = keymap_mod.mod_index_invalid,
                .action = decodeXkbAction(ci.action),
                .level_one_only = (ci.match & si_level_one_only) != 0,
                // The old code read bit 1, which is XkbSI_LockingKey, so it
                // reported repeat for the wrong interprets.
                .repeat = (ci.flags & si_auto_repeat) != 0,
            };
        }
        km.sym_interprets = interprets;
        applyCompatPass(km);
    }

    return km;
}

/// Build a Keymap from a validated XkbGetMap reply.
///
/// `num_groups` is the group count to fall back on when a key's group_info says
/// zero. `names` supplies real key names when present; otherwise keys get
/// synthetic `K<keycode>` names.
pub fn keymapFromGetMap(
    ctx: *Context,
    map: *const MapView,
    num_groups: u8,
    names: ?*const NamesView,
) !*Keymap {
    const km = try Keymap.create(ctx);
    errdefer km.destroy();

    const arena = km.arena.allocator();

    // The 8 real modifiers, in wire bit order.
    const mod_names = [8][]const u8{ "Shift", "Lock", "Control", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5" };
    const mods = try arena.alloc(Mod, mod_names.len);
    for (mods, 0..) |*m, i| {
        m.* = .{
            .name = try ctx.intern(mod_names[i]),
            .type = .real,
            .mapping = @as(u32, 1) << @intCast(i),
        };
    }
    km.mods = .{ .mods = mods };

    const types = try arena.alloc(KeyType, map.types.len);
    for (types, map.types, 0..) |*kt, xtype, i| {
        var name_buf: [32]u8 = undefined;
        const name_atom = try ctx.intern(try std.fmt.bufPrint(&name_buf, "type{d}", .{i}));

        const entries = try arena.alloc(KeyType.Entry, xtype.map.len());
        for (entries, 0..) |*e, j| {
            const wire_entry = xtype.map.at(j);
            e.* = .{
                .level = wire_entry.level,
                .mods = wire_entry.mods_mods,
                .preserve = 0,
            };
        }

        kt.* = .{
            .name = name_atom,
            .mods = xtype.mods_mask,
            .num_levels = xtype.numLevels,
            .entries = entries,
            .level_names = &.{},
        };
    }
    km.types = types;

    const min_kc: usize = map.reply.minKeyCode;
    const max_kc: usize = map.reply.maxKeyCode;
    const first_key_sym: usize = map.reply.firstKeySym;

    const keys = try arena.alloc(Key, max_kc + 1);
    for (keys, 0..) |*key, kc| {
        key.* = .{
            .name = try keyNameAtom(ctx, names, kc),
            .keycode = @intCast(kc),
            .repeats = false,
            .modmap = 0,
            .out_of_range_group_action = .wrap,
            .out_of_range_group_number = 0,
            .groups = &.{},
        };
    }

    for (map.modmap) |entry| {
        if (entry.keycode <= max_kc) keys[entry.keycode].modmap = entry.mods;
    }

    // parseGetMap rejects max below min, so this range is never inverted.
    for (min_kc..max_kc + 1) |kc| {
        if (kc < first_key_sym) continue;
        const idx = kc - first_key_sym;
        if (idx >= map.syms.len) continue;

        const ksm = map.syms[idx];
        const wire_groups = groupCount(ksm);
        const n_groups: usize = if (wire_groups == 0) @as(usize, num_groups) else wire_groups;
        if (n_groups == 0) continue;

        const groups = try arena.alloc(Group, n_groups);
        for (groups, 0..) |*g, grp_i| {
            // XKB stores at most 4 group type indices; anything past that
            // reuses the last one.
            const kt_slot = @min(grp_i, 3);
            const kt_raw: usize = if (kt_slot < ksm.kt_index.len) ksm.kt_index[kt_slot] else 0;
            const type_idx = if (types.len == 0) 0 else @min(kt_raw, types.len - 1);
            const num_levels: usize = if (types.len == 0) 1 else types[type_idx].num_levels;

            const levels = try arena.alloc(Level, num_levels);
            for (levels, 0..) |*lvl, lvl_i| {
                const sym_slice = try arena.alloc(Keysym, 1);
                const sym_val = map.symForKey(@intCast(kc), @intCast(grp_i), @intCast(lvl_i)) orelse 0;
                // Keysym is non-exhaustive: every 32-bit wire value is a tag.
                sym_slice[0] = @enumFromInt(sym_val);
                lvl.* = .{ .syms = sym_slice, .action = .none };
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

/// The interned name for a keycode: the server's name when it has one, else a
/// synthetic `K<keycode>`.
fn keyNameAtom(ctx: *Context, names: ?*const NamesView, kc: usize) !Atom {
    if (kc <= std.math.maxInt(u8)) {
        if (names) |n| {
            if (n.keyName(@intCast(kc))) |name| return ctx.intern(name);
        }
    }
    var buf: [8]u8 = undefined;
    return ctx.intern(try std.fmt.bufPrint(&buf, "K{d}", .{kc}));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    // keymapNewFromDevice and setupXkb need a live server, so no test calls
    // them and Zig would never analyse them. Referencing every declaration
    // forces the test build to type-check them anyway.
    std.testing.refAllDecls(@This());
}

/// Write the fixed 40-byte XkbGetMap header of the one-key test map into `bytes`.
/// kc8 carries 'a'/'A' through a single 2-level Shift key type.
fn writeOneKeyMapHeader(bytes: []u8) void {
    bytes[10] = 8; // minKeyCode
    bytes[11] = 9; // maxKeyCode
    std.mem.writeInt(u16, bytes[12..14], 0x0007, native_endian); // KeyTypes|KeySyms|ModifierMap
    bytes[15] = 1; // nTypes
    bytes[16] = 1; // totalTypes
    bytes[17] = 8; // firstKeySym
    std.mem.writeInt(u16, bytes[18..20], 2, native_endian); // totalSyms
    bytes[20] = 1; // nKeySyms
    bytes[33] = 1; // totalModMapKeys
}

/// The full one-key XkbGetMap reply: header, one KeyType with one map entry,
/// one KeySymMap for kc8, and one ModifierMap entry.
fn oneKeyMapReply() [76]u8 {
    var bytes = [_]u8{0} ** 76;
    writeOneKeyMapHeader(&bytes);

    // KeyType at 40.
    bytes[40] = 0x01; // mods_mask = Shift
    bytes[41] = 0x01; // mods_mods
    bytes[44] = 2; // numLevels
    bytes[45] = 1; // nMapEntries
    bytes[46] = 0; // hasPreserve

    // KTMapEntry at 48: Shift selects level 1.
    bytes[48] = 1; // active
    bytes[49] = 0x01; // mods_mask
    bytes[50] = 1; // level
    bytes[51] = 0x01; // mods_mods

    // KeySymMap at 56: kt_index all zero, 1 group, width 2.
    bytes[60] = 1; // groupInfo
    bytes[61] = 2; // width
    std.mem.writeInt(u16, bytes[62..64], 2, native_endian); // nSyms
    std.mem.writeInt(u32, bytes[64..68], 0x61, native_endian); // 'a'
    std.mem.writeInt(u32, bytes[68..72], 0x41, native_endian); // 'A'

    // ModMapEntry at 72, padded to 4.
    bytes[72] = 8; // keycode
    return bytes;
}

test "parseGetMap on the one-key reply yields kc8 level 0 'a' and level 1 'A'" {
    const bytes = oneKeyMapReply();
    var map = try parseGetMap(std.testing.allocator, &bytes);
    defer map.deinit();

    try std.testing.expectEqual(@as(usize, 1), map.types.len);
    try std.testing.expectEqual(@as(u8, 2), map.types[0].numLevels);
    try std.testing.expectEqual(@as(?u32, 0x61), map.symForKey(8, 0, 0));
    try std.testing.expectEqual(@as(?u32, 0x41), map.symForKey(8, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), map.modmap.len);
    try std.testing.expectEqual(@as(u8, 8), map.modmap[0].keycode);
}

test "symForKey returns null for a group and a level past the KeySymMap" {
    const bytes = oneKeyMapReply();
    var map = try parseGetMap(std.testing.allocator, &bytes);
    defer map.deinit();

    try std.testing.expectEqual(@as(?u32, null), map.symForKey(8, 1, 0)); // only 1 group
    try std.testing.expectEqual(@as(?u32, null), map.symForKey(8, 0, 2)); // width is 2
    try std.testing.expectEqual(@as(?u32, null), map.symForKey(7, 0, 0)); // below firstKeySym
    try std.testing.expectEqual(@as(?u32, null), map.symForKey(9, 0, 0)); // past the sym list
}

test "parseGetMap rejects a reply shorter than the 40-byte header" {
    const tiny = [_]u8{0} ** 39;
    try std.testing.expectError(error.ShortReply, parseGetMap(std.testing.allocator, &tiny));
}

test "parseGetMap rejects a KeyType section that runs past the reply" {
    // nTypes claims 4 types but only the first KeyType header is in the buffer.
    var bytes = [_]u8{0} ** 48;
    std.mem.writeInt(u16, bytes[12..14], 0x0001, native_endian); // KeyTypes
    bytes[15] = 4; // nTypes
    try std.testing.expectError(error.ShortReply, parseGetMap(std.testing.allocator, &bytes));
}

test "parseGetMap rejects a KeyType whose map entries run past the reply" {
    // One KeyType claiming 200 map entries in a buffer that holds none of them.
    var bytes = [_]u8{0} ** 48;
    std.mem.writeInt(u16, bytes[12..14], 0x0001, native_endian); // KeyTypes
    bytes[15] = 1; // nTypes
    bytes[45] = 200; // nMapEntries
    try std.testing.expectError(error.ShortReply, parseGetMap(std.testing.allocator, &bytes));
}

test "parseGetMap rejects a KeySymMap whose keysyms run past the reply" {
    // One KeySymMap claiming 1000 keysyms with no room for them.
    var bytes = [_]u8{0} ** 48;
    std.mem.writeInt(u16, bytes[12..14], 0x0002, native_endian); // KeySyms
    bytes[20] = 1; // nKeySyms
    std.mem.writeInt(u16, bytes[46..48], 1000, native_endian); // nSyms of record 0
    try std.testing.expectError(error.ShortReply, parseGetMap(std.testing.allocator, &bytes));
}

test "parseGetMap rejects a modifier map that runs past the reply" {
    var bytes = [_]u8{0} ** 40;
    std.mem.writeInt(u16, bytes[12..14], 0x0004, native_endian); // ModifierMap
    bytes[33] = 8; // totalModMapKeys, needs 16 bytes that are not there
    try std.testing.expectError(error.ShortReply, parseGetMap(std.testing.allocator, &bytes));
}

test "parseGetMap rejects max_key_code below min_key_code" {
    var bytes = [_]u8{0} ** 40;
    bytes[10] = 40; // minKeyCode
    bytes[11] = 20; // maxKeyCode
    try std.testing.expectError(error.MalformedReply, parseGetMap(std.testing.allocator, &bytes));
}

test "parseGetNames reads AC01 for keycode 8 and null for an unnamed key" {
    // which = KeyNames only; firstKey 8, nKeys 2. kc8 is "AC01", kc9 all zeros.
    var bytes = [_]u8{0} ** 40;
    std.mem.writeInt(u32, bytes[8..12], @intFromEnum(xkbproto.NameDetail.KeyNames), native_endian);
    bytes[18] = 8; // firstKey
    bytes[19] = 2; // nKeys
    @memcpy(bytes[32..36], "AC01");

    const names = try parseGetNames(&bytes);
    try std.testing.expectEqualStrings("AC01", names.keyName(8).?);
    try std.testing.expectEqual(@as(?[]const u8, null), names.keyName(9));
    try std.testing.expectEqual(@as(?[]const u8, null), names.keyName(7));
    try std.testing.expectEqual(@as(?[]const u8, null), names.keyName(10));
}

test "keyName stops at the first NUL rather than only trimming trailing NULs" {
    var bytes = [_]u8{0} ** 36;
    std.mem.writeInt(u32, bytes[8..12], @intFromEnum(xkbproto.NameDetail.KeyNames), native_endian);
    bytes[18] = 8; // firstKey
    bytes[19] = 1; // nKeys
    // "ES\0C": the trailing byte is non-zero, so a trailing-NUL trim would
    // return all four bytes including the embedded NUL.
    @memcpy(bytes[32..36], "ES\x00C");

    const names = try parseGetNames(&bytes);
    try std.testing.expectEqualStrings("ES", names.keyName(8).?);
}

test "parseGetNames rejects a reply shorter than the 32-byte header" {
    const tiny = [_]u8{0} ** 31;
    try std.testing.expectError(error.ShortReply, parseGetNames(&tiny));
}

test "parseGetControls reads numGroups 2" {
    var bytes = [_]u8{0} ** 32;
    bytes[9] = 2;
    try std.testing.expectEqual(@as(u8, 2), (try parseGetControls(&bytes)).num_groups);
}

test "parseGetControls rejects a reply that stops before the numGroups byte" {
    const tiny = [_]u8{0} ** 9;
    try std.testing.expectError(error.ShortReply, parseGetControls(&tiny));
}

test "parseGetCompatMap reads two interprets with syms 0x41 and 0xFE02" {
    var bytes = [_]u8{0} ** 64;
    // The generated decoder bounds its lists by the reply length field, so a
    // synthetic reply has to set it: (64 - 32) / 4 = 8 words.
    std.mem.writeInt(u32, bytes[4..8], 8, native_endian);
    std.mem.writeInt(u16, bytes[12..14], 2, native_endian); // nSIRtrn
    std.mem.writeInt(u32, bytes[32..36], 0x41, native_endian);
    std.mem.writeInt(u32, bytes[48..52], 0xFE02, native_endian);

    const compat = try parseGetCompatMap(&bytes);
    const list = compat.interprets();
    try std.testing.expectEqual(@as(usize, 2), list.len());
    try std.testing.expectEqual(@as(u32, 0x41), list.at(0).sym);
    try std.testing.expectEqual(@as(u32, 0xFE02), list.at(1).sym);
}

test "parseGetCompatMap rejects a reply shorter than the 32-byte header" {
    const tiny = [_]u8{0} ** 31;
    try std.testing.expectError(error.ShortReply, parseGetCompatMap(&tiny));
}

test "wireMatchOp maps the five defined ops and sends unknown ops to none" {
    try std.testing.expectEqual(MatchOp.none_of, wireMatchOp(0));
    try std.testing.expectEqual(MatchOp.any_of_or_none, wireMatchOp(1));
    try std.testing.expectEqual(MatchOp.any_of, wireMatchOp(2));
    try std.testing.expectEqual(MatchOp.all_of, wireMatchOp(3));
    try std.testing.expectEqual(MatchOp.exactly, wireMatchOp(4));
    try std.testing.expectEqual(MatchOp.none, wireMatchOp(5));
    try std.testing.expectEqual(MatchOp.none, wireMatchOp(0x7f));
}

test "decodeXkbAction reads LockMods realMods 0x04 and keeps unknown types private" {
    // SIAction.data holds the 7 bytes after the type byte, so for SASetMods
    // that is flags, mask, realMods, vmodsHigh, vmodsLow, and two pad bytes.
    const lock_body = [_]u8{ 0x02, 0xff, 0x04, 0, 0, 0, 0 };
    const lock = decodeXkbAction(.{ .type = 3, .data = &lock_body });
    try std.testing.expectEqual(Action.ModsAction{
        .kind = .lock,
        .mods = 0x04,
        .mods_by_name = false,
        .flags = .{ .clear_locks = true },
    }, lock.mods);

    const terminate = decodeXkbAction(.{ .type = 0x0c, .data = &lock_body });
    try std.testing.expectEqual(Action.terminate, terminate);

    const unknown_body = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
    const unknown = decodeXkbAction(.{ .type = 0x5a, .data = &unknown_body });
    try std.testing.expectEqual(@as(u8, 0x5a), unknown.private.kind);
    try std.testing.expectEqualSlices(u8, &unknown_body, &unknown.private.data);
}

test "decodeXkbAction returns none for an action body cut short" {
    const short_body = [_]u8{ 1, 2, 3 };
    try std.testing.expectEqual(Action.none, decodeXkbAction(.{ .type = 1, .data = &short_body }));
}

test "interpModMatch: exactly needs equality, none_of needs disjoint mods" {
    try std.testing.expect(interpModMatch(.exactly, 0x05, 0x05));
    try std.testing.expect(!interpModMatch(.exactly, 0x05, 0x01));
    try std.testing.expect(interpModMatch(.none_of, 0x02, 0x05));
    try std.testing.expect(!interpModMatch(.none_of, 0x04, 0x05));
    try std.testing.expect(interpModMatch(.all_of, 0x05, 0x07));
    try std.testing.expect(!interpModMatch(.all_of, 0x05, 0x01));
    try std.testing.expect(interpModMatch(.any_of_or_none, 0x02, 0x00));
    try std.testing.expect(!interpModMatch(.none, 0x00, 0x00));
}

test "x11 hermetic: one-key getmap bytes drive a State that reports 'a' then 'A'" {
    const State = @import("state.zig").State;
    const ctx = try Context.create(std.testing.allocator, std.testing.io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();

    const bytes = oneKeyMapReply();
    var map = try parseGetMap(std.testing.allocator, &bytes);
    defer map.deinit();

    const km = try keymapFromGetMap(ctx, &map, 1, null);
    defer km.destroy();

    const st = try State.create(km);
    defer st.destroy();

    try std.testing.expectEqual(Keysym.fromName("a", .{}).?, st.keyGetOneSym(8));
    _ = st.updateMask(0x1, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(Keysym.fromName("A", .{}).?, st.keyGetOneSym(8));
}

test "keymapFromGetMap names kc8 from GetNames instead of the synthetic K8" {
    const ctx = try Context.create(std.testing.allocator, std.testing.io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();

    const bytes = oneKeyMapReply();
    var map = try parseGetMap(std.testing.allocator, &bytes);
    defer map.deinit();

    var name_bytes = [_]u8{0} ** 36;
    std.mem.writeInt(u32, name_bytes[8..12], @intFromEnum(xkbproto.NameDetail.KeyNames), native_endian);
    name_bytes[18] = 8; // firstKey
    name_bytes[19] = 1; // nKeys
    @memcpy(name_bytes[32..36], "AC01");
    const names = try parseGetNames(&name_bytes);

    const km = try keymapFromGetMap(ctx, &map, 1, &names);
    defer km.destroy();

    try std.testing.expectEqualStrings("AC01", ctx.atomText(km.keys[8].name));
    try std.testing.expectEqualStrings("K9", ctx.atomText(km.keys[9].name));
}
