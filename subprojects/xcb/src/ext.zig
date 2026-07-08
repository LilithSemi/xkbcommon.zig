/// X11 extension discovery: QueryExtension (opcode 98).
const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const conn_mod = @import("conn.zig");
const proto = @import("proto.zig");

fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

/// Wire layout: name_len:u16, pad:u16(0), name bytes zero-padded to 4-byte boundary.
pub fn encodeQueryExtensionExtra(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    if (name.len > std.math.maxInt(u16)) return error.NameTooLong;

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(alloc);

    var u16buf: [2]u8 = undefined;

    std.mem.writeInt(u16, &u16buf, @intCast(name.len), native_endian);
    try list.appendSlice(alloc, &u16buf);

    std.mem.writeInt(u16, &u16buf, 0, native_endian);
    try list.appendSlice(alloc, &u16buf);

    try list.appendSlice(alloc, name);

    const name_pad = pad4(name.len) - name.len;
    const zeros = [3]u8{ 0, 0, 0 };
    try list.appendSlice(alloc, zeros[0..name_pad]);

    return list.toOwnedSlice(alloc);
}

pub const QueryExtensionReply = struct {
    present: bool,
    major_opcode: u8,
    first_event: u8,
    first_error: u8,
};

/// Parse QueryExtension reply; returns error.ShortReply if bytes is under 12.
pub fn parseQueryExtensionReply(bytes: []const u8) !QueryExtensionReply {
    if (bytes.len < 12) return error.ShortReply;
    return QueryExtensionReply{
        .present = bytes[8] != 0,
        .major_opcode = bytes[9],
        .first_event = bytes[10],
        .first_error = bytes[11],
    };
}

/// Send QueryExtension and return the parsed reply. Integration-only.
pub fn queryExtension(c: *conn_mod.Connection, name: []const u8) !QueryExtensionReply {
    const extra = try encodeQueryExtensionExtra(c.allocator, name);
    defer c.allocator.free(extra);
    const seq = try c.sendRequest(98, 0, extra);
    var xe: proto.XError = undefined;
    var reply = try c.readReply(seq, &xe);
    defer reply.deinit();
    return parseQueryExtensionReply(reply.bytes);
}

/// Send GetAtomName (opcode 17) and return a caller-owned name string. Integration-only.
pub fn getAtomName(c: *conn_mod.Connection, atom_id: u32) ![]u8 {
    var extra: [4]u8 = undefined;
    std.mem.writeInt(u32, &extra, atom_id, native_endian);
    const seq = try c.sendRequest(17, 0, &extra);
    var xe: proto.XError = undefined;
    var reply = try c.readReply(seq, &xe);
    defer reply.deinit();
    // Reply layout: [8..10] nameLength u16, [10..32] pad, [32..] name bytes
    if (reply.bytes.len < 32) return error.ShortReply;
    const name_len = std.mem.readInt(u16, reply.bytes[8..10], native_endian);
    if (reply.bytes.len < 32 + @as(usize, name_len)) return error.ShortReply;
    return c.allocator.dupe(u8, reply.bytes[32 .. 32 + @as(usize, name_len)]);
}

test "encodeQueryExtensionExtra XKEYBOARD layout" {
    const result = try encodeQueryExtensionExtra(std.testing.allocator, "XKEYBOARD");
    defer std.testing.allocator.free(result);

    // name_len field = 9 (native endian u16 at offset 0)
    const name_len = std.mem.readInt(u16, result[0..2], native_endian);
    try std.testing.expectEqual(@as(u16, 9), name_len);

    // pad field = 0
    const pad = std.mem.readInt(u16, result[2..4], native_endian);
    try std.testing.expectEqual(@as(u16, 0), pad);

    // total: 4 (name_len + pad) + padTo4(9)=12 = 16
    try std.testing.expectEqual(@as(usize, 16), result.len);

    // name bytes at offset 4
    try std.testing.expectEqualSlices(u8, "XKEYBOARD", result[4..13]);

    // trailing pad bytes must be zero
    try std.testing.expectEqual(@as(u8, 0), result[13]);
    try std.testing.expectEqual(@as(u8, 0), result[14]);
    try std.testing.expectEqual(@as(u8, 0), result[15]);
}

test "parseQueryExtensionReply present fields" {
    var buf = std.mem.zeroes([32]u8);
    buf[8] = 1;
    buf[9] = 135;
    buf[10] = 101;
    buf[11] = 137;

    const reply = try parseQueryExtensionReply(&buf);
    try std.testing.expect(reply.present);
    try std.testing.expectEqual(@as(u8, 135), reply.major_opcode);
    try std.testing.expectEqual(@as(u8, 101), reply.first_event);
    try std.testing.expectEqual(@as(u8, 137), reply.first_error);
}

test "parseQueryExtensionReply present false when byte is 0" {
    var buf = std.mem.zeroes([32]u8);
    buf[8] = 0;

    const reply = try parseQueryExtensionReply(&buf);
    try std.testing.expect(!reply.present);
}

test "parseQueryExtensionReply short buffer" {
    const buf = [_]u8{0} ** 11;
    try std.testing.expectError(error.ShortReply, parseQueryExtensionReply(&buf));
}
