/// XKB extension setup: XkbUseExtension negotiation.
const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const conn_mod = @import("conn.zig");
const proto = @import("proto.zig");
const ext = @import("ext.zig");

pub const Connection = conn_mod.Connection;

pub const XKB_EXTENSION_NAME = "XKEYBOARD";

/// Build the 4 extra bytes for a XkbUseExtension request.
/// Wire layout: wantedMajor:u16, wantedMinor:u16 (native endian).
pub fn encodeUseExtensionExtra(wanted_major: u16, wanted_minor: u16) [4]u8 {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], wanted_major, native_endian);
    std.mem.writeInt(u16, buf[2..4], wanted_minor, native_endian);
    return buf;
}

pub const UseExtensionReply = struct {
    supported: bool,
    server_major: u16,
    server_minor: u16,
};

/// Parse a XkbUseExtension reply from raw reply bytes.
/// bytes must be at least 12; returns error.ShortReply otherwise.
/// Wire offsets: [1]=supported:u8, [8..10]=serverMajor:u16, [10..12]=serverMinor:u16.
pub fn parseUseExtensionReply(bytes: []const u8) !UseExtensionReply {
    if (bytes.len < 12) return error.ShortReply;
    return UseExtensionReply{
        .supported = bytes[1] != 0,
        .server_major = std.mem.readInt(u16, bytes[8..10], native_endian),
        .server_minor = std.mem.readInt(u16, bytes[10..12], native_endian),
    };
}

pub const XkbSetup = struct {
    major_opcode: u8,
    server_major: u16,
    server_minor: u16,
};

/// Send XkbUseExtension to a live X server and return the parsed setup.
/// Integration-only; not unit-tested.
pub fn setupXkb(c: *Connection) !XkbSetup {
    const qe = try ext.queryExtension(c, XKB_EXTENSION_NAME);
    if (!qe.present) return error.XkbNotSupported;
    const extra = encodeUseExtensionExtra(1, 0);
    const seq = try c.sendRequest(qe.major_opcode, 0, &extra);
    var xe: proto.XError = undefined;
    var reply = try c.readReply(seq, &xe);
    defer reply.deinit();
    const ue = try parseUseExtensionReply(reply.bytes);
    if (!ue.supported) return error.XkbVersionUnsupported;
    return XkbSetup{
        .major_opcode = qe.major_opcode,
        .server_major = ue.server_major,
        .server_minor = ue.server_minor,
    };
}

test "encodeUseExtensionExtra layout" {
    const buf = encodeUseExtensionExtra(1, 0);

    const wanted_major = std.mem.readInt(u16, buf[0..2], native_endian);
    try std.testing.expectEqual(@as(u16, 1), wanted_major);

    const wanted_minor = std.mem.readInt(u16, buf[2..4], native_endian);
    try std.testing.expectEqual(@as(u16, 0), wanted_minor);
}

test "parseUseExtensionReply supported fields" {
    var buf = std.mem.zeroes([32]u8);
    buf[1] = 1; // supported = true
    std.mem.writeInt(u16, buf[8..10], 1, native_endian); // serverMajor = 1
    std.mem.writeInt(u16, buf[10..12], 0, native_endian); // serverMinor = 0

    const reply = try parseUseExtensionReply(&buf);
    try std.testing.expect(reply.supported);
    try std.testing.expectEqual(@as(u16, 1), reply.server_major);
    try std.testing.expectEqual(@as(u16, 0), reply.server_minor);
}

test "parseUseExtensionReply supported false when byte is 0" {
    var buf = std.mem.zeroes([32]u8);
    buf[1] = 0; // supported = false

    const reply = try parseUseExtensionReply(&buf);
    try std.testing.expect(!reply.supported);
}

test "parseUseExtensionReply short buffer" {
    const buf = [_]u8{0} ** 11;
    try std.testing.expectError(error.ShortReply, parseUseExtensionReply(&buf));
}
