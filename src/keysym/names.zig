const std = @import("std");
const k = @import("../keysym.zig");
const Keysym = k.Keysym;
const tables = @import("keysym_tables");

pub const NameOpts = struct { case_insensitive: bool = false };

/// Returns true only when every byte in s is a valid hex digit (no underscores, no signs).
fn isStrictHex(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn fromName(name: []const u8, opts: NameOpts) ?Keysym {
    var lo: usize = 0;
    var hi: usize = tables.names_by_name.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cmp = std.mem.order(u8, tables.names_by_name[mid].name, name);
        switch (cmp) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return @fromBackingInt(@intCast(tables.names_by_name[mid].value)),
        }
    }
    // U<hex> form (>= 4 hex digits after U, so len >= 5).
    // Reject if hex part contains non-hex chars (e.g. underscores or sign chars).
    if (name.len >= 5 and name[0] == 'U') {
        const hex = name[1..];
        if (isStrictHex(hex)) {
            if (std.fmt.parseInt(u21, hex, 16)) |cp| {
                if ((cp >= 0x20 and cp <= 0x7e) or (cp >= 0xa0 and cp <= 0xff))
                    return @fromBackingInt(@intCast(@as(u32, cp)));
                if (cp >= 0x100 and cp <= 0x10ffff)
                    return @fromBackingInt(@intCast(@as(u32, cp) + 0x01000000));
            } else |_| {}
        }
    }
    // 0x<hex> form. Reject if hex part contains non-hex chars.
    if (name.len > 2 and name[0] == '0' and name[1] == 'x') {
        const hex = name[2..];
        if (isStrictHex(hex)) {
            if (std.fmt.parseInt(u32, hex, 16)) |v| return @fromBackingInt(@intCast(v)) else |_| {}
        }
    }
    // case-insensitive linear fallback
    if (opts.case_insensitive) {
        for (tables.names_by_name) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, name)) return @fromBackingInt(@intCast(e.value));
        }
    }
    return null;
}

pub fn getName(ks: Keysym, buf: []u8) error{NoSpace}![]const u8 {
    const v: u32 = @backingInt(ks);
    var lo: usize = 0;
    var hi: usize = tables.names_by_value.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mv = tables.names_by_value[mid].value;
        if (mv < v) {
            lo = mid + 1;
        } else if (mv > v) {
            hi = mid;
        } else {
            const nm = tables.names_by_value[mid].name;
            if (buf.len < nm.len) return error.NoSpace;
            @memcpy(buf[0..nm.len], nm);
            return buf[0..nm.len];
        }
    }
    // unicode keysym range -> U<HEX>
    if (v >= 0x01000100 and v <= 0x0110ffff) {
        return std.fmt.bufPrint(buf, "U{X:0>4}", .{v - 0x01000000}) catch error.NoSpace;
    }
    return std.fmt.bufPrint(buf, "0x{x:0>8}", .{v}) catch error.NoSpace;
}

test "fromName exact" {
    try std.testing.expectEqual(@as(u32, 0xff0d), @backingInt(k.fromName("Return", .{}).?));
    try std.testing.expectEqual(@as(u32, 0x0041), @backingInt(k.fromName("A", .{}).?));
}
test "fromName unknown" {
    try std.testing.expect(k.fromName("NotAKeysym", .{}) == null);
}
test "fromName unicode and hex forms" {
    try std.testing.expectEqual(@as(u32, 0x0041), @backingInt(k.fromName("U0041", .{}).?));
    try std.testing.expectEqual(@as(u32, 0x01002603), @backingInt(k.fromName("U2603", .{}).?));
    try std.testing.expectEqual(@as(u32, 0xff0d), @backingInt(k.fromName("0xff0d", .{}).?));
}
test "fromName rejects underscore separators" {
    // upstream rejects _ digit separators that Zig parseInt would otherwise accept
    try std.testing.expect(k.fromName("U00_41", .{}) == null);
    try std.testing.expect(k.fromName("0xff_0d", .{}) == null);
    // valid forms still work
    try std.testing.expectEqual(@as(u32, 0x0041), @backingInt(k.fromName("U0041", .{}).?));
    try std.testing.expectEqual(@as(u32, 0xff0d), @backingInt(k.fromName("0xff0d", .{}).?));
}
test "fromName case insensitive" {
    try std.testing.expectEqual(@as(u32, 0xff0d), @backingInt(k.fromName("return", .{ .case_insensitive = true }).?));
    try std.testing.expect(k.fromName("return", .{}) == null);
}
test "getName roundtrip" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Return", try k.getName(@fromBackingInt(@intCast(0xff0d)), &buf));
}
test "getName unicode keysym" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("U2603", try k.getName(@fromBackingInt(@intCast(0x01002603)), &buf));
}
test "getName no space" {
    var buf: [2]u8 = undefined;
    try std.testing.expectError(error.NoSpace, k.getName(@fromBackingInt(@intCast(0xff0d)), &buf));
}
test "fromName XF86AudioPlay" {
    const ks = k.fromName("XF86AudioPlay", .{}).?;
    try std.testing.expectEqual(@as(u32, 0x1008ff14), @backingInt(ks));
}
test "getName XF86AudioPlay" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("XF86AudioPlay", try k.getName(@fromBackingInt(@intCast(0x1008ff14)), &buf));
}
