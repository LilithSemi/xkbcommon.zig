const std = @import("std");
const Keysym = @import("../keysym.zig").Keysym;
const tables = @import("keysym_tables");

pub fn toUtf32(ks: Keysym) u21 {
    const v: u32 = @backingInt(ks);
    if ((v >= 0x20 and v <= 0x7e) or (v >= 0xa0 and v <= 0xff)) return @intCast(v);
    if (v >= 0x01000100 and v <= 0x0110ffff) return @intCast(v - 0x01000000);
    return legacyToUtf32(v);
}

pub fn toUtf8(ks: Keysym, buf: []u8) ?[]const u8 {
    const cp = toUtf32(ks);
    if (cp == 0) return null;
    const len = std.unicode.utf8CodepointSequenceLength(cp) catch return null;
    if (buf.len < len) return null;
    _ = std.unicode.utf8Encode(cp, buf) catch return null;
    return buf[0..len];
}

pub fn fromUtf32(cp: u21) Keysym {
    if (legacyFromUtf32(cp)) |ks| return ks;
    if ((cp >= 0x20 and cp <= 0x7e) or (cp >= 0xa0 and cp <= 0xff)) return @fromBackingInt(@intCast(@as(u32, cp)));
    if (cp >= 0x100 and cp <= 0x10ffff) return @fromBackingInt(@intCast(@as(u32, cp) + 0x01000000));
    return .no_symbol;
}

fn legacyToUtf32(v: u32) u21 {
    const items = tables.keysym_to_unicode;
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].keysym < v) lo = mid + 1 else if (items[mid].keysym > v) hi = mid else return items[mid].unicode;
    }
    return 0;
}

fn legacyFromUtf32(cp: u21) ?Keysym {
    const items = tables.unicode_to_keysym;
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].unicode < cp) lo = mid + 1 else if (items[mid].unicode > cp) hi = mid else return @fromBackingInt(@intCast(items[mid].keysym));
    }
    return null;
}

test "ascii and latin1 direct" {
    try std.testing.expectEqual(@as(u21, 'A'), toUtf32(@fromBackingInt(@intCast(0x0041))));
    try std.testing.expectEqual(@as(u21, 0x00e9), toUtf32(@fromBackingInt(@intCast(0x00e9))));
}

test "unicode-range keysym" {
    try std.testing.expectEqual(@as(u21, 0x0104), toUtf32(@fromBackingInt(@intCast(0x01000104))));
}

test "fromUtf32 ascii and high" {
    try std.testing.expectEqual(@as(u32, 0x0041), @backingInt(fromUtf32('A')));
    try std.testing.expectEqual(@as(u32, 0x0101F600), @backingInt(fromUtf32(0x1F600)));
}

test "legacy keysym to unicode" {
    // XK_Aogonek 0x01a1 -> U+0104
    try std.testing.expectEqual(@as(u21, 0x0104), toUtf32(@fromBackingInt(@intCast(0x01a1))));
}

test "legacy unicode to keysym reversible" {
    try std.testing.expectEqual(@as(u32, 0x01a1), @backingInt(fromUtf32(0x0104)));
}

test "non-reversible unicode does not map back to legacy" {
    // U+2022 BULLET has a keysym (0xb7 via non-reversible enfilledbox), but no reversible mapping;
    // fromUtf32 should fall through to the unicode-range path
    try std.testing.expectEqual(@as(u32, 0x01002022), @backingInt(fromUtf32(0x2022)));
}

test "toUtf8 ascii" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("A", toUtf8(@fromBackingInt(@intCast(0x0041)), &buf).?);
}
test "toUtf8 multibyte" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\u{0104}", toUtf8(@fromBackingInt(@intCast(0x01a1)), &buf).?);
}
test "toUtf8 no mapping returns null" {
    var buf: [8]u8 = undefined;
    try std.testing.expect(toUtf8(@fromBackingInt(@intCast(0xff67)), &buf) == null);
}
test "toUtf8 too small returns null" {
    var buf: [1]u8 = undefined;
    try std.testing.expect(toUtf8(@fromBackingInt(@intCast(0x01a1)), &buf) == null);
}

test "fromUtf32 canonical keysym for shared codepoints" {
    // space: canonical is XK_space 0x0020, not KP_Space 0xff80
    try std.testing.expectEqual(@as(u32, 0x0020), @backingInt(fromUtf32(0x20)));
    // digit 5: canonical is XK_5 0x0035, not KP_5 0xffb5
    try std.testing.expectEqual(@as(u32, 0x0035), @backingInt(fromUtf32('5')));
    // carriage return: canonical is XK_Return 0xff0d, not KP_Enter 0xff8d
    try std.testing.expectEqual(@as(u32, 0xff0d), @backingInt(fromUtf32(0x000d)));
}
