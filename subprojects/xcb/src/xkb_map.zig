/// XkbGetMap reply parser. Parses fixed header, KeyTypes, KeySyms, and ModifierMap.
/// KeyActions, KeyBehaviors, ExplicitComponents, and VirtualModMap are skipped.
const std = @import("std");
const builtin = @import("builtin");

const native_endian = builtin.cpu.arch.endian();

pub const KTMapEntry = struct {
    active: bool,
    mods_mask: u8,
    level: u8,
    mods_mods: u8,
    mods_vmods: u16,
};

pub const ModDef = struct {
    mask: u8,
    real_mods: u8,
    vmods: u16,
};

pub const KeyType = struct {
    mods_mask: u8,
    mods_mods: u8,
    mods_vmods: u16,
    num_levels: u8,
    entries: []KTMapEntry,
    preserve: []ModDef,
};

/// Per-key symbol map: kt_index[g] is the key type for group g.
/// syms is a flat array of n_syms u32 keysyms.
/// Layout: group g, level l -> syms[g * width + l].
/// group_info & 0x0f = number of groups.
pub const KeySymMap = struct {
    kt_index: [4]u8,
    group_info: u8,
    width: u8,
    syms: []u32,
};

/// One entry from the ModifierMap section.
pub const ModMapEntry = struct {
    keycode: u8,
    mods: u8,
};

/// All counts extracted from the XkbGetMap reply fixed header.
///
/// Wire layout (offsets from reply byte 0):
///   [0]  response_type u8    [1]  deviceID u8
///   [2..4]  sequence u16     [4..8]  length u32
///   [8..10] pad0 u16         [10] minKeyCode u8    [11] maxKeyCode u8
///   [12..14] present u16
///   [14] firstType  [15] nTypes  [16] totalTypes
///   [17] firstKeySym  [18..20] totalSyms u16  [20] nKeySyms
///   [21] firstKeyAction  [22..24] totalActions u16  [24] nKeyActions
///   [25] firstKeyBehavior  [26] nKeyBehaviors  [27] totalKeyBehaviors
///   [28] firstKeyExplicit  [29] nKeyExplicit  [30] totalKeyExplicit
///   [31] firstModMapKey  [32] nModMapKeys  [33] totalModMapKeys
///   [34] firstVModMapKey  [35] nVModMapKeys  [36] totalVModMapKeys
///   [37] pad1  [38..40] virtualMods u16
///   variable data starts at offset 40
pub const MapHeader = struct {
    min_key_code: u8,
    max_key_code: u8,
    present: u16,
    first_type: u8,
    n_types: u8,
    total_types: u8,
    first_key_sym: u8,
    total_syms: u16,
    n_key_syms: u8,
    first_key_action: u8,
    total_actions: u16,
    n_key_actions: u8,
    first_key_behavior: u8,
    n_key_behaviors: u8,
    total_key_behaviors: u8,
    first_key_explicit: u8,
    n_key_explicit: u8,
    total_key_explicit: u8,
    first_mod_map_key: u8,
    n_mod_map_keys: u8,
    total_mod_map_keys: u8,
    first_vmod_map_key: u8,
    n_vmod_map_keys: u8,
    total_vmod_map_keys: u8,
    virtual_mods: u16,
};

pub const GetMapReply = struct {
    arena: std.heap.ArenaAllocator,
    header: MapHeader,
    types: []KeyType,
    /// Byte offset into the reply buffer where the KeySyms section begins.
    syms_offset: usize,
    /// KeySymMap records indexed by (keycode - header.first_key_sym).
    syms: []KeySymMap,
    /// ModifierMap entries (totalModMapKeys records).
    modmap: []ModMapEntry,

    pub fn deinit(self: *GetMapReply) void {
        self.arena.deinit();
    }
};

// present bitmask constants

pub const PRESENT_KEY_TYPES: u16 = 0x0001;
pub const PRESENT_KEY_SYMS: u16 = 0x0002;
pub const PRESENT_MODIFIER_MAP: u16 = 0x0004;
pub const PRESENT_EXPLICIT_COMPONENTS: u16 = 0x0008;
pub const PRESENT_KEY_ACTIONS: u16 = 0x0010;
pub const PRESENT_KEY_BEHAVIORS: u16 = 0x0020;
pub const PRESENT_VIRTUAL_MODS: u16 = 0x0040;
pub const PRESENT_VIRTUAL_MOD_MAP: u16 = 0x0080;

/// Number of groups for a KeySymMap (group_info low 4 bits).
pub fn groupCount(m: *const KeySymMap) u8 {
    return m.group_info & 0x0f;
}

/// Round n up to the next multiple of 4.
inline fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn popcount16(v: u16) u32 {
    return @popCount(v);
}

/// Return the keysym for (keycode, group, level), or null if out of range.
pub fn symForKey(r: *const GetMapReply, keycode: u8, group: u8, level: u8) ?u32 {
    if (keycode < r.header.first_key_sym) return null;
    const idx = @as(usize, keycode) - @as(usize, r.header.first_key_sym);
    if (idx >= r.syms.len) return null;
    const m = &r.syms[idx];
    const ngroups = groupCount(m);
    if (group >= ngroups) return null;
    if (level >= m.width) return null;
    const offset = @as(usize, group) * @as(usize, m.width) + @as(usize, level);
    if (offset >= m.syms.len) return null;
    return m.syms[offset];
}

/// Parse a raw XkbGetMap reply buffer into a GetMapReply.
/// Parses the fixed header (40 bytes), KeyTypes, KeySyms, KeyActions (skip),
/// KeyBehaviors (skip), VirtualMods, ExplicitComponents (skip), ModifierMap,
/// and VirtualModMap (skip).
/// All slice memory is owned by the returned arena; call deinit() to free.
/// Returns error.ShortReply or error.MalformedMap on invalid input.
pub fn parseGetMap(alloc: std.mem.Allocator, bytes: []const u8) !GetMapReply {
    if (bytes.len < 40) return error.ShortReply;

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Parse fixed header fields.
    const header = MapHeader{
        .min_key_code = bytes[10],
        .max_key_code = bytes[11],
        .present = std.mem.readInt(u16, bytes[12..14], native_endian),
        .first_type = bytes[14],
        .n_types = bytes[15],
        .total_types = bytes[16],
        .first_key_sym = bytes[17],
        .total_syms = std.mem.readInt(u16, bytes[18..20], native_endian),
        .n_key_syms = bytes[20],
        .first_key_action = bytes[21],
        .total_actions = std.mem.readInt(u16, bytes[22..24], native_endian),
        .n_key_actions = bytes[24],
        .first_key_behavior = bytes[25],
        .n_key_behaviors = bytes[26],
        .total_key_behaviors = bytes[27],
        .first_key_explicit = bytes[28],
        .n_key_explicit = bytes[29],
        .total_key_explicit = bytes[30],
        .first_mod_map_key = bytes[31],
        .n_mod_map_keys = bytes[32],
        .total_mod_map_keys = bytes[33],
        .first_vmod_map_key = bytes[34],
        .n_vmod_map_keys = bytes[35],
        .total_vmod_map_keys = bytes[36],
        // bytes[37] is pad1
        .virtual_mods = std.mem.readInt(u16, bytes[38..40], native_endian),
    };

    var cursor: usize = 40;

    // Each KeyType wire record:
    //   mods_mask u8, mods_mods u8, mods_vmods u16,
    //   numLevels u8, nMapEntries u8, hasPreserve u8, pad u8   (8 bytes)
    // Followed by nMapEntries KTMapEntry records (8 bytes each):
    //   active u8, mods_mask u8, level u8, mods_mods u8, mods_vmods u16, pad u16
    // Then if hasPreserve: nMapEntries ModDef records (4 bytes each):
    //   mask u8, realMods u8, vmods u16
    const n_types: usize = if (header.present & PRESENT_KEY_TYPES != 0) header.n_types else 0;
    const types = try a.alloc(KeyType, n_types);

    for (types) |*kt| {
        if (cursor + 8 > bytes.len) return error.ShortReply;
        kt.mods_mask = bytes[cursor];
        kt.mods_mods = bytes[cursor + 1];
        kt.mods_vmods = std.mem.readInt(u16, bytes[cursor + 2 ..][0..2], native_endian);
        kt.num_levels = bytes[cursor + 4];
        const n_entries: usize = bytes[cursor + 5];
        const has_preserve = bytes[cursor + 6] != 0;
        // bytes[cursor + 7] = pad0, skip
        cursor += 8;

        kt.entries = try a.alloc(KTMapEntry, n_entries);
        for (kt.entries) |*e| {
            if (cursor + 8 > bytes.len) return error.ShortReply;
            e.active = bytes[cursor] != 0;
            e.mods_mask = bytes[cursor + 1];
            e.level = bytes[cursor + 2];
            e.mods_mods = bytes[cursor + 3];
            e.mods_vmods = std.mem.readInt(u16, bytes[cursor + 4 ..][0..2], native_endian);
            // bytes[cursor + 6..7] = pad u16, skip
            cursor += 8;
        }

        // Preserve ModDef records (only when hasPreserve is set).
        const preserve_count: usize = if (has_preserve) n_entries else 0;
        kt.preserve = try a.alloc(ModDef, preserve_count);
        for (kt.preserve) |*md| {
            if (cursor + 4 > bytes.len) return error.ShortReply;
            md.mask = bytes[cursor];
            md.real_mods = bytes[cursor + 1];
            md.vmods = std.mem.readInt(u16, bytes[cursor + 2 ..][0..2], native_endian);
            cursor += 4;
        }
    }

    const syms_offset = cursor;

    // n_key_syms KeySymMap records.  Each record:
    //   kt_index [4]u8, group_info u8, width u8, n_syms u16  (8 bytes)
    //   then n_syms u32 keysyms.
    // Records are inherently 4-byte-aligned (8 + n_syms*4).
    const n_key_syms: usize = if (header.present & PRESENT_KEY_SYMS != 0) header.n_key_syms else 0;
    const syms = try a.alloc(KeySymMap, n_key_syms);

    for (syms) |*ksm| {
        if (cursor + 8 > bytes.len) return error.ShortReply;
        ksm.kt_index = bytes[cursor..][0..4].*;
        ksm.group_info = bytes[cursor + 4];
        ksm.width = bytes[cursor + 5];
        const n_syms_rec = std.mem.readInt(u16, bytes[cursor + 6 ..][0..2], native_endian);
        cursor += 8;

        ksm.syms = try a.alloc(u32, n_syms_rec);
        for (ksm.syms) |*sym| {
            if (cursor + 4 > bytes.len) return error.ShortReply;
            sym.* = std.mem.readInt(u32, bytes[cursor..][0..4], native_endian);
            cursor += 4;
        }
    }

    // First: n_key_actions u8 per-key count bytes, padded to multiple of 4.
    // Then:  total_actions * 8 bytes of action records.
    if (header.present & PRESENT_KEY_ACTIONS != 0) {
        const count_bytes = pad4(@as(usize, header.n_key_actions));
        const action_bytes = @as(usize, header.total_actions) * 8;
        const skip = count_bytes + action_bytes;
        if (cursor + skip > bytes.len) return error.ShortReply;
        cursor += skip;
    }

    // total_key_behaviors SetBehavior records (4 bytes each), padded to 4.
    if (header.present & PRESENT_KEY_BEHAVIORS != 0) {
        const skip = pad4(@as(usize, header.total_key_behaviors) * 4);
        if (cursor + skip > bytes.len) return error.ShortReply;
        cursor += skip;
    }

    // popcount(virtual_mods) u8 bytes, padded to multiple of 4.
    if (header.present & PRESENT_VIRTUAL_MODS != 0) {
        const n_vmods = popcount16(header.virtual_mods);
        const skip = pad4(@as(usize, n_vmods));
        if (cursor + skip > bytes.len) return error.ShortReply;
        cursor += skip;
    }

    // total_key_explicit records (2 bytes each: keycode u8, explicit u8), padded to 4.
    if (header.present & PRESENT_EXPLICIT_COMPONENTS != 0) {
        const skip = pad4(@as(usize, header.total_key_explicit) * 2);
        if (cursor + skip > bytes.len) return error.ShortReply;
        cursor += skip;
    }

    // total_mod_map_keys records (2 bytes each: keycode u8, mods u8), padded to 4.
    const n_modmap: usize = if (header.present & PRESENT_MODIFIER_MAP != 0) header.total_mod_map_keys else 0;
    const modmap = try a.alloc(ModMapEntry, n_modmap);
    if (header.present & PRESENT_MODIFIER_MAP != 0) {
        for (modmap) |*e| {
            if (cursor + 2 > bytes.len) return error.ShortReply;
            e.keycode = bytes[cursor];
            e.mods = bytes[cursor + 1];
            cursor += 2;
        }
        // Pad to multiple of 4.
        const unpadded = n_modmap * 2;
        const padded = pad4(unpadded);
        cursor += padded - unpadded;
    }

    // total_vmod_map_keys records (4 bytes each: keycode u8, pad u8, vmods u16).
    if (header.present & PRESENT_VIRTUAL_MOD_MAP != 0) {
        const skip = @as(usize, header.total_vmod_map_keys) * 4;
        if (cursor + skip > bytes.len) return error.ShortReply;
        cursor += skip;
    }

    return GetMapReply{
        .arena = arena,
        .header = header,
        .types = types,
        .syms_offset = syms_offset,
        .syms = syms,
        .modmap = modmap,
    };
}

test "parseGetMap synthetic: 1 type / kc8=a,A / 1 modmap entry" {
    // Build a minimal GetMapReply in memory. Wire layout matches the spec in
    // the MapHeader doc comment. present=0x0007 (KeyTypes|KeySyms|ModifierMap).
    var bytes = [_]u8{0} ** 68;
    // Fixed header (40 bytes)
    bytes[10] = 8; // minKeyCode
    bytes[11] = 9; // maxKeyCode
    std.mem.writeInt(u16, bytes[12..14], 0x0007, native_endian); // present
    // bytes[14] firstType = 0
    bytes[15] = 1; // nTypes
    bytes[16] = 1; // totalTypes
    bytes[17] = 8; // firstKeySym
    std.mem.writeInt(u16, bytes[18..20], 2, native_endian); // totalSyms
    bytes[20] = 1; // nKeySyms
    // bytes[21..33] = 0 (no actions/behaviors/explicit)
    bytes[33] = 1; // totalModMapKeys
    // bytes[34..40] = 0 (no vmod map, virtualMods=0)

    // KeyType at offset 40: mods_mask=Shift, num_levels=2, 0 entries, no preserve
    bytes[40] = 0x01; // mods_mask
    bytes[41] = 0x01; // mods_mods
    std.mem.writeInt(u16, bytes[42..44], 0, native_endian); // mods_vmods
    bytes[44] = 2; // numLevels
    // bytes[45]=0 nMapEntries, bytes[46]=0 hasPreserve, bytes[47]=0 pad

    // KeySymMap at offset 48: kt_index all 0, group_info=1, width=2, n_syms=2
    // bytes[48..52] = 0 (kt_index)
    bytes[52] = 1; // group_info: 1 group
    bytes[53] = 2; // width
    std.mem.writeInt(u16, bytes[54..56], 2, native_endian); // n_syms
    std.mem.writeInt(u32, bytes[56..60], 0x61, native_endian); // sym[0] = 'a'
    std.mem.writeInt(u32, bytes[60..64], 0x41, native_endian); // sym[1] = 'A'

    // ModifierMap at offset 64: 1 entry (keycode=8, mods=0), padded to 4
    bytes[64] = 8; // keycode
    bytes[65] = 0; // mods
    // bytes[66..68] = 0 (padding)

    var r = try parseGetMap(std.testing.allocator, &bytes);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.types.len);
    try std.testing.expectEqual(@as(?u32, 0x61), symForKey(&r, 8, 0, 0));
    try std.testing.expectEqual(@as(?u32, 0x41), symForKey(&r, 8, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), r.modmap.len);
    try std.testing.expectEqual(@as(u8, 8), r.modmap[0].keycode);
}

test "parseGetMap rejects short buffer" {
    const tiny = [_]u8{0} ** 39;
    try std.testing.expectError(error.ShortReply, parseGetMap(std.testing.allocator, &tiny));
}

test "symForKey out-of-range returns null" {
    // A 40-byte all-zeros buffer (no KeyTypes/KeySyms/ModifierMap present)
    // just exercises symForKey boundary checks.
    const empty = [_]u8{0} ** 40;
    var r = try parseGetMap(std.testing.allocator, &empty);
    defer r.deinit();
    try std.testing.expectEqual(@as(?u32, null), symForKey(&r, 8, 0, 0));
}
