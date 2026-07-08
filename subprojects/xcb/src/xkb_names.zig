/// XkbGetNames reply parser.
const std = @import("std");
const builtin = @import("builtin");

const native_endian = builtin.cpu.arch.endian();

pub const GetNamesReply = struct {
    arena: std.heap.ArenaAllocator,
    /// First keycode for which a name is stored (= firstKey from wire header byte 18).
    min_key_code: u8,
    /// Raw 4-byte key names, indexed by (keycode - min_key_code).
    key_names: [][4]u8,
    /// X atom IDs for each key type (one per nTypes, section 7).
    type_names: []u32,
    /// Per-type level count (nTypes CARD8 bytes from section 8 header).
    kt_level_counts: []u8,
    /// X atom IDs for KT level names (nKTLevels total, section 8 body).
    kt_level_names: []u32,
    /// X atom IDs for named indicators (popcount(indicators) entries, section 9).
    indicator_names: []u32,
    /// X atom IDs for named virtual mods (popcount(virtualMods) entries, section 10).
    virtual_mod_names: []u32,
    /// X atom IDs for named groups (popcount(groupNames) entries, section 11).
    group_names: []u32,

    pub fn deinit(self: *GetNamesReply) void {
        self.arena.deinit();
    }
};

// which-bitmask constants (wire order is NOT bit-ascending)

const WHICH_KEYCODES: u32 = 1 << 0;
const WHICH_GEOMETRY: u32 = 1 << 1;
const WHICH_SYMBOLS: u32 = 1 << 2;
const WHICH_PHYS_SYMBOLS: u32 = 1 << 3;
const WHICH_TYPES: u32 = 1 << 4;
const WHICH_COMPAT: u32 = 1 << 5;
const WHICH_KEY_TYPE_NAMES: u32 = 1 << 6;
const WHICH_KT_LEVEL_NAMES: u32 = 1 << 7;
const WHICH_INDICATOR_NAMES: u32 = 1 << 8;
const WHICH_KEY_NAMES: u32 = 1 << 9;
const WHICH_KEY_ALIASES: u32 = 1 << 10;
const WHICH_VIRTUAL_MOD_NAMES: u32 = 1 << 11;
const WHICH_GROUP_NAMES: u32 = 1 << 12;

inline fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

/// Reads n u32 LE values from bytes at cursor and advances cursor by n*4.
fn readU32Slice(a: std.mem.Allocator, bytes: []const u8, cursor: *usize, n: usize) ![]u32 {
    if (cursor.* + n * 4 > bytes.len) return error.ShortReply;
    const out = try a.alloc(u32, n);
    for (out, 0..) |*v, i| {
        v.* = std.mem.readInt(u32, bytes[cursor.* + i * 4 ..][0..4], native_endian);
    }
    cursor.* += n * 4;
    return out;
}

/// Parse an XkbGetNames reply. Returns error.ShortReply on truncated input.
pub fn parseGetNames(alloc: std.mem.Allocator, bytes: []const u8) !GetNamesReply {
    if (bytes.len < 32) return error.ShortReply;

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    // [8..12]  which         u32 LE
    // [12]     minKeyCode    u8
    // [14]     nTypes        u8
    // [15]     groupNames    u8  (bitmask of groups with names)
    // [16..18] virtualMods   u16 LE
    // [18]     firstKey      u8
    // [19]     nKeys         u8
    // [20..24] indicators    u32 LE
    // [25]     nKeyAliases   u8
    // [26..28] nKTLevels     u16 LE

    const which = std.mem.readInt(u32, bytes[8..12], native_endian);
    const n_types: usize = bytes[14];
    const group_names_mask: u8 = bytes[15];
    const virtual_mods = std.mem.readInt(u16, bytes[16..18], native_endian);
    const first_key: u8 = bytes[18];
    const n_keys: usize = bytes[19];
    const indicators = std.mem.readInt(u32, bytes[20..24], native_endian);
    const n_key_aliases: usize = bytes[25];
    const n_kt_levels: usize = std.mem.readInt(u16, bytes[26..28], native_endian);

    // Variable data starts at byte 32.
    var cursor: usize = 32;

    // Wire section order:
    //
    //  1. Keycodes     (bit 0) : 1 ATOM (4 bytes)
    //  2. Geometry     (bit 1) : 1 ATOM
    //  3. Symbols      (bit 2) : 1 ATOM
    //  4. PhysSymbols  (bit 3) : 1 ATOM
    //  5. Types        (bit 4) : 1 ATOM
    //  6. Compat       (bit 5) : 1 ATOM
    //  7. KeyTypeNames (bit 6) : nTypes ATOMs
    //  8. KTLevelNames (bit 7) : nTypes CARD8 (padded to 4) + nKTLevels ATOMs
    //  9. IndicatorNames (bit 8): popcount(indicators) ATOMs
    // 10. VirtualModNames (bit 11): popcount(virtualMods) ATOMs
    // 11. GroupNames   (bit 12): popcount(groupNames) ATOMs
    // 12. KeyNames     (bit 9) : nKeys KEYNAME records (4 bytes each)
    // 13. KeyAliases   (bit 10): nKeyAliases * 8 bytes

    // Sections 1-6: single ATOMs.
    if (which & WHICH_KEYCODES != 0) cursor += 4;
    if (which & WHICH_GEOMETRY != 0) cursor += 4;
    if (which & WHICH_SYMBOLS != 0) cursor += 4;
    if (which & WHICH_PHYS_SYMBOLS != 0) cursor += 4;
    if (which & WHICH_TYPES != 0) cursor += 4;
    if (which & WHICH_COMPAT != 0) cursor += 4;

    // Section 7: KeyTypeNames = nTypes ATOMs.
    var type_names: []u32 = &.{};
    if (which & WHICH_KEY_TYPE_NAMES != 0) {
        type_names = try readU32Slice(a, bytes, &cursor, n_types);
    }

    // Section 8: KTLevelNames = nTypes CARD8 bytes (padded to 4) + nKTLevels ATOMs.
    var kt_level_counts: []u8 = &.{};
    var kt_level_names: []u32 = &.{};
    if (which & WHICH_KT_LEVEL_NAMES != 0) {
        if (cursor + n_types > bytes.len) return error.ShortReply;
        kt_level_counts = try a.alloc(u8, n_types);
        @memcpy(kt_level_counts, bytes[cursor .. cursor + n_types]);
        cursor += pad4(n_types);
        kt_level_names = try readU32Slice(a, bytes, &cursor, n_kt_levels);
    }

    // Section 9: IndicatorNames = popcount(indicators) ATOMs.
    var indicator_names: []u32 = &.{};
    if (which & WHICH_INDICATOR_NAMES != 0) {
        const n = @as(usize, @popCount(indicators));
        indicator_names = try readU32Slice(a, bytes, &cursor, n);
    }

    // Section 10: VirtualModNames = popcount(virtualMods) ATOMs.
    var virtual_mod_names: []u32 = &.{};
    if (which & WHICH_VIRTUAL_MOD_NAMES != 0) {
        const n = @as(usize, @popCount(virtual_mods));
        virtual_mod_names = try readU32Slice(a, bytes, &cursor, n);
    }

    // Section 11: GroupNames = popcount(groupNames) ATOMs.
    var group_names_out: []u32 = &.{};
    if (which & WHICH_GROUP_NAMES != 0) {
        const n = @as(usize, @popCount(group_names_mask));
        group_names_out = try readU32Slice(a, bytes, &cursor, n);
    }

    // Section 12: KeyNames = nKeys KEYNAME records (4 raw ASCII bytes each, NOT ATOMs).
    const key_names = try a.alloc([4]u8, n_keys);
    if (which & WHICH_KEY_NAMES != 0) {
        if (cursor + n_keys * 4 > bytes.len) return error.ShortReply;
        for (key_names, 0..) |*kn, i| {
            kn.* = bytes[cursor + i * 4 ..][0..4].*;
        }
        cursor += n_keys * 4;
    } else {
        for (key_names) |*kn| kn.* = [4]u8{ 0, 0, 0, 0 };
    }

    // Section 13: KeyAliases = nKeyAliases * 8 bytes (not parsed, just skip).
    _ = n_key_aliases;

    return GetNamesReply{
        .arena = arena,
        .min_key_code = first_key,
        .key_names = key_names,
        .type_names = type_names,
        .kt_level_counts = kt_level_counts,
        .kt_level_names = kt_level_names,
        .indicator_names = indicator_names,
        .virtual_mod_names = virtual_mod_names,
        .group_names = group_names_out,
    };
}

/// Return the trimmed key name string, or null if keycode is out of range or the name is all zeros.
pub fn keyName(r: *const GetNamesReply, keycode: u8) ?[]const u8 {
    if (keycode < r.min_key_code) return null;
    const idx = @as(usize, keycode) - @as(usize, r.min_key_code);
    if (idx >= r.key_names.len) return null;
    const raw = &r.key_names[idx];
    var len: usize = 4;
    while (len > 0 and raw[len - 1] == 0) len -= 1;
    if (len == 0) return null;
    return raw[0..len];
}

test "parseGetNames synthetic: WHICH_KEY_NAMES only, keycode 8 = AC01" {
    // Build a minimal GetNames reply with only KEY_NAMES set.
    // Fixed header is 32 bytes; variable data starts at 32.
    // Wire layout: [8..12]=which, [14]=nTypes, [15]=groupNames, [16..18]=virtualMods,
    // [18]=firstKey, [19]=nKeys, [20..24]=indicators, [25]=nKeyAliases, [26..28]=nKTLevels.
    var bytes = [_]u8{0} ** 36;
    std.mem.writeInt(u32, bytes[8..12], WHICH_KEY_NAMES, native_endian); // which
    // bytes[14]=0 nTypes, bytes[15]=0 groupNames
    std.mem.writeInt(u16, bytes[16..18], 0, native_endian); // virtualMods
    bytes[18] = 8; // firstKey (becomes min_key_code)
    bytes[19] = 1; // nKeys
    // bytes[20..24]=0 indicators, bytes[25]=0 nKeyAliases
    std.mem.writeInt(u16, bytes[26..28], 0, native_endian); // nKTLevels
    // Section 12 (KeyNames) at offset 32: 1 record of 4 bytes = "AC01"
    bytes[32] = 'A';
    bytes[33] = 'C';
    bytes[34] = '0';
    bytes[35] = '1';

    var r = try parseGetNames(std.testing.allocator, &bytes);
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 8), r.min_key_code);
    try std.testing.expectEqual(@as(usize, 1), r.key_names.len);
    const name = keyName(&r, 8);
    try std.testing.expectEqualStrings("AC01", name.?);
}

test "parseGetNames synthetic: 2 key names, second is ESC" {
    // Two KEYNAME records starting at firstKey=8: kc8="  \x00\x00" (empty), kc9="ESC\x00".
    var bytes = [_]u8{0} ** 40;
    std.mem.writeInt(u32, bytes[8..12], WHICH_KEY_NAMES, native_endian);
    bytes[18] = 8; // firstKey
    bytes[19] = 2; // nKeys
    // bytes[32..36] = kc8 name: all zeros (null name)
    // bytes[36..40] = kc9 name: "ESC\x00"
    bytes[36] = 'E';
    bytes[37] = 'S';
    bytes[38] = 'C';
    bytes[39] = 0;

    var r = try parseGetNames(std.testing.allocator, &bytes);
    defer r.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), keyName(&r, 8)); // zeros -> null
    const name9 = keyName(&r, 9);
    try std.testing.expectEqualStrings("ESC", name9.?);
}

test "parseGetNames rejects short buffer" {
    const tiny = [_]u8{0} ** 31;
    try std.testing.expectError(error.ShortReply, parseGetNames(std.testing.allocator, &tiny));
}
