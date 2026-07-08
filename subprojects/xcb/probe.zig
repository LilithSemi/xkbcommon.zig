/// Live X server validation probe.
///
/// Connects to a real Xvfb server, runs XkbUseExtension, then sends
/// raw XKB requests and saves each reply to testdata/*.bin as fixture files.
/// Usage: zig build run-probe -- :99
const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const xcb = @import("xcb");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = init.minimal.args.iterate();
    _ = args_it.skip();
    const display_str: []const u8 = args_it.next() orelse ":99";

    const stdout_file = std.Io.File.stdout();
    var out_buf: [65536]u8 = undefined;
    var bw = stdout_file.writer(io, &out_buf);
    const w = &bw.interface;

    try w.print("probe: connecting to {s}\n", .{display_str});
    try bw.flush();

    // Xvfb launched with -ac; pass empty auth.
    const conn = xcb.conn.Connection.connect(gpa, io, display_str, null) catch |err| {
        try w.print("FAIL connect: {}\n", .{err});
        try bw.flush();
        return err;
    };
    defer conn.disconnect();

    const setup = conn.setup;
    try w.print("connect OK\n", .{});
    try w.print("  resource_id_base  0x{x:0>8}\n", .{setup.resource_id_base});
    try w.print("  resource_id_mask  0x{x:0>8}\n", .{setup.resource_id_mask});
    try w.print("  root window       0x{x:0>8}\n", .{setup.root});
    try w.print("  root_visual       0x{x:0>8}\n", .{setup.root_visual});
    try w.print("  min_keycode       {d}\n", .{setup.min_keycode});
    try w.print("  max_keycode       {d}\n", .{setup.max_keycode});
    try bw.flush();

    const xkb_setup = xcb.xkb.setupXkb(conn) catch |err| {
        try w.print("FAIL setupXkb: {}\n", .{err});
        try bw.flush();
        return err;
    };
    try w.print("setupXkb OK\n", .{});
    try w.print("  XKB major_opcode  {d}\n", .{xkb_setup.major_opcode});
    try w.print("  server version    {d}.{d}\n", .{ xkb_setup.server_major, xkb_setup.server_minor });
    try bw.flush();

    const min_kc = setup.min_keycode;
    const max_kc = setup.max_keycode;
    const n_kc: u8 = max_kc -% min_kc +% 1;
    const opcode = xkb_setup.major_opcode;

    // XkbGetMap (minor 8)
    // Wire layout extra (24 bytes):
    //   deviceSpec:u16, full:u16, partial:u16,
    //   firstType:u8, nTypes:u8, firstKeySym:u8, nKeySyms:u8,
    //   firstKeyAction:u8, nKeyActions:u8, firstKeyBehavior:u8, nKeyBehaviors:u8,
    //   virtualMods:u16, firstKeyExplicit:u8, nKeyExplicit:u8,
    //   firstModMapKey:u8, nModMapKeys:u8, firstVModMapKey:u8, nVModMapKeys:u8,
    //   pad:u16
    {
        var extra: [24]u8 = std.mem.zeroes([24]u8);
        std.mem.writeInt(u16, extra[0..2], 0x0100, native_endian); // deviceSpec = XkbUseCoreKbd
        std.mem.writeInt(u16, extra[2..4], 0x00ff, native_endian); // full: all 8 map sections
        std.mem.writeInt(u16, extra[4..6], 0x0000, native_endian); // partial: none
        extra[6] = 0; // firstType
        extra[7] = 0; // nTypes (0 = use all when full.KeyTypes set)
        extra[8] = min_kc; // firstKeySym
        extra[9] = n_kc; // nKeySyms
        extra[10] = min_kc; // firstKeyAction
        extra[11] = n_kc; // nKeyActions
        extra[12] = min_kc; // firstKeyBehavior
        extra[13] = n_kc; // nKeyBehaviors
        std.mem.writeInt(u16, extra[14..16], 0xffff, native_endian); // virtualMods: all
        extra[16] = min_kc; // firstKeyExplicit
        extra[17] = n_kc; // nKeyExplicit
        extra[18] = min_kc; // firstModMapKey
        extra[19] = n_kc; // nModMapKeys
        extra[20] = min_kc; // firstVModMapKey
        extra[21] = n_kc; // nVModMapKeys
        // extra[22..24] = pad2 (zeroed)

        try w.print("sending XkbGetMap (minor=8)\n", .{});
        try bw.flush();

        const seq = conn.sendRequest(opcode, 8, &extra) catch |err| {
            try w.print("FAIL XkbGetMap sendRequest: {}\n", .{err});
            try bw.flush();
            return err;
        };

        var xe: xcb.proto.XError = undefined;
        var reply = conn.readReply(seq, &xe) catch |err| {
            if (err == error.XProtocolError) {
                try w.print("FAIL XkbGetMap X error: code={d} major={d} minor={d} bad_value=0x{x}\n", .{
                    xe.code, xe.major_opcode, xe.minor_opcode, xe.bad_value,
                });
            } else {
                try w.print("FAIL XkbGetMap readReply: {}\n", .{err});
            }
            try bw.flush();
            return err;
        };
        defer reply.deinit();

        try w.print("XkbGetMap reply: {d} bytes\n", .{reply.bytes.len});
        try writeFixture(io, "testdata/getmap.bin", reply.bytes, w, &bw);
        try bw.flush();
    }

    // XkbGetNames (minor 17)
    // xcb-proto XkbGetNames request extra (8 bytes):
    //   deviceSpec:u16, pad:u16, which:u32
    {
        var extra: [8]u8 = std.mem.zeroes([8]u8);
        std.mem.writeInt(u16, extra[0..2], 0x0100, native_endian); // deviceSpec
        std.mem.writeInt(u16, extra[2..4], 0, native_endian); // pad
        // which: SETofXKBNAMEDETAIL valid bits 0-13 = 0x3FFF
        // (Keycodes|Geometry|Symbols|PhysSymbols|Types|Compat|KeyTypeNames|
        //  KTLevelNames|IndicatorNames|KeyNames|KeyAliases|VirtualModNames|
        //  GroupNames|RGNames)
        std.mem.writeInt(u32, extra[4..8], 0x3FFF, native_endian); // which: all defined

        try w.print("sending XkbGetNames (minor=17)\n", .{});
        try bw.flush();

        const seq = conn.sendRequest(opcode, 17, &extra) catch |err| {
            try w.print("FAIL XkbGetNames sendRequest: {}\n", .{err});
            try bw.flush();
            return err;
        };

        var xe: xcb.proto.XError = undefined;
        var reply = conn.readReply(seq, &xe) catch |err| {
            if (err == error.XProtocolError) {
                try w.print("FAIL XkbGetNames X error: code={d} major={d} minor={d} bad_value=0x{x}\n", .{
                    xe.code, xe.major_opcode, xe.minor_opcode, xe.bad_value,
                });
            } else {
                try w.print("FAIL XkbGetNames readReply: {}\n", .{err});
            }
            try bw.flush();
            return err;
        };
        defer reply.deinit();

        try w.print("XkbGetNames reply: {d} bytes\n", .{reply.bytes.len});
        try writeFixture(io, "testdata/getnames.bin", reply.bytes, w, &bw);
        try bw.flush();
    }

    // XkbGetState (minor 4)
    // xcb-proto XkbGetState request extra (4 bytes):
    //   deviceSpec:u16, pad:u16
    {
        var extra: [4]u8 = std.mem.zeroes([4]u8);
        std.mem.writeInt(u16, extra[0..2], 0x0100, native_endian); // deviceSpec
        std.mem.writeInt(u16, extra[2..4], 0, native_endian); // pad

        try w.print("sending XkbGetState (minor=4)\n", .{});
        try bw.flush();

        const seq = conn.sendRequest(opcode, 4, &extra) catch |err| {
            try w.print("FAIL XkbGetState sendRequest: {}\n", .{err});
            try bw.flush();
            return err;
        };

        var xe: xcb.proto.XError = undefined;
        var reply = conn.readReply(seq, &xe) catch |err| {
            if (err == error.XProtocolError) {
                try w.print("FAIL XkbGetState X error: code={d} major={d} minor={d} bad_value=0x{x}\n", .{
                    xe.code, xe.major_opcode, xe.minor_opcode, xe.bad_value,
                });
            } else {
                try w.print("FAIL XkbGetState readReply: {}\n", .{err});
            }
            try bw.flush();
            return err;
        };
        defer reply.deinit();

        try w.print("XkbGetState reply: {d} bytes\n", .{reply.bytes.len});
        try writeFixture(io, "testdata/getstate.bin", reply.bytes, w, &bw);
        try bw.flush();
    }

    // XkbGetControls (minor 6, NOT 5 which is LatchLockState)
    // XKBproto.h: X_kbGetControls = 6
    // Request extra (4 bytes):
    //   deviceSpec:u16, pad:u16
    {
        var extra: [4]u8 = std.mem.zeroes([4]u8);
        std.mem.writeInt(u16, extra[0..2], 0x0100, native_endian); // deviceSpec
        std.mem.writeInt(u16, extra[2..4], 0, native_endian); // pad

        try w.print("sending XkbGetControls (minor=6)\n", .{});
        try bw.flush();

        const seq = conn.sendRequest(opcode, 6, &extra) catch |err| {
            try w.print("FAIL XkbGetControls sendRequest: {}\n", .{err});
            try bw.flush();
            return err;
        };

        var xe: xcb.proto.XError = undefined;
        var reply = conn.readReply(seq, &xe) catch |err| {
            if (err == error.XProtocolError) {
                try w.print("FAIL XkbGetControls X error: code={d} major={d} minor={d} bad_value=0x{x}\n", .{
                    xe.code, xe.major_opcode, xe.minor_opcode, xe.bad_value,
                });
            } else {
                try w.print("FAIL XkbGetControls readReply: {}\n", .{err});
            }
            try bw.flush();
            return err;
        };
        defer reply.deinit();

        try w.print("XkbGetControls reply: {d} bytes\n", .{reply.bytes.len});
        try writeFixture(io, "testdata/getcontrols.bin", reply.bytes, w, &bw);
        try bw.flush();
    }

    // XkbGetCompatMap (minor 10, NOT 9 which is SetMap)
    // XKBproto.h: X_kbGetCompatMap = 10
    // Request extra (8 bytes):
    //   deviceSpec:u16, groups:u8, getAllSI:u8, firstSI:u16, nSI:u16
    {
        var extra: [8]u8 = std.mem.zeroes([8]u8);
        std.mem.writeInt(u16, extra[0..2], 0x0100, native_endian); // deviceSpec
        extra[2] = 0xFF; // groups: all 8 groups
        extra[3] = 1; // getAllSI: true
        std.mem.writeInt(u16, extra[4..6], 0, native_endian); // firstSI
        std.mem.writeInt(u16, extra[6..8], 0, native_endian); // nSI

        try w.print("sending XkbGetCompatMap (minor=10)\n", .{});
        try bw.flush();

        const seq = conn.sendRequest(opcode, 10, &extra) catch |err| {
            try w.print("FAIL XkbGetCompatMap sendRequest: {}\n", .{err});
            try bw.flush();
            return err;
        };

        var xe: xcb.proto.XError = undefined;
        var reply = conn.readReply(seq, &xe) catch |err| {
            if (err == error.XProtocolError) {
                try w.print("FAIL XkbGetCompatMap X error: code={d} major={d} minor={d} bad_value=0x{x}\n", .{
                    xe.code, xe.major_opcode, xe.minor_opcode, xe.bad_value,
                });
            } else {
                try w.print("FAIL XkbGetCompatMap readReply: {}\n", .{err});
            }
            try bw.flush();
            return err;
        };
        defer reply.deinit();

        try w.print("XkbGetCompatMap reply: {d} bytes\n", .{reply.bytes.len});
        try writeFixture(io, "testdata/getcompatmap.bin", reply.bytes, w, &bw);
        try bw.flush();
    }

    // XkbGetIndicatorMap (minor 13, NOT 22 which is ListComponents)
    // XKBproto.h: X_kbGetIndicatorMap = 13
    // Request extra (8 bytes):
    //   deviceSpec:u16, pad:u16, which:u32
    {
        var extra: [8]u8 = std.mem.zeroes([8]u8);
        std.mem.writeInt(u16, extra[0..2], 0x0100, native_endian); // deviceSpec
        std.mem.writeInt(u16, extra[2..4], 0, native_endian); // pad
        std.mem.writeInt(u32, extra[4..8], 0xFFFFFFFF, native_endian); // which: all

        try w.print("sending XkbGetIndicatorMap (minor=13)\n", .{});
        try bw.flush();

        const seq = conn.sendRequest(opcode, 13, &extra) catch |err| {
            try w.print("FAIL XkbGetIndicatorMap sendRequest: {}\n", .{err});
            try bw.flush();
            return err;
        };

        var xe: xcb.proto.XError = undefined;
        var reply = conn.readReply(seq, &xe) catch |err| {
            if (err == error.XProtocolError) {
                try w.print("FAIL XkbGetIndicatorMap X error: code={d} major={d} minor={d} bad_value=0x{x}\n", .{
                    xe.code, xe.major_opcode, xe.minor_opcode, xe.bad_value,
                });
            } else {
                try w.print("FAIL XkbGetIndicatorMap readReply: {}\n", .{err});
            }
            try bw.flush();
            return err;
        };
        defer reply.deinit();

        try w.print("XkbGetIndicatorMap reply: {d} bytes\n", .{reply.bytes.len});
        try writeFixture(io, "testdata/getindicatormap.bin", reply.bytes, w, &bw);
        try bw.flush();
    }

    try w.print("probe complete -- all fixtures written to testdata/\n", .{});
    try bw.flush();
}

/// Write bytes to a fixture file and print its size.
fn writeFixture(
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
    w: *std.Io.Writer,
    bw: anytype,
) !void {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    var file_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &file_buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
    try w.print("  wrote {s} ({d} bytes)\n", .{ path, bytes.len });
    _ = bw;
}
