/// X11 Connection: transport connect + setup handshake.
///
/// connect() opens a unix socket (local) or TCP socket (remote), sends the X11
/// SetupRequest, reads the SetupReply, and returns a ready-to-use Connection.
const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const proto = @import("proto.zig");
const display_mod = @import("display.zig");
const xauth = @import("xauth.zig");

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    setup: proto.Setup,
    sequence: u16,

    /// Open a connection to the X server described by display_str (e.g. ":0").
    /// Passes auth token in the setup request (empty auth if null).
    /// Requires a live X server.
    pub fn connect(
        alloc: std.mem.Allocator,
        io: std.Io,
        display_str: ?[]const u8,
        auth: ?xauth.Auth,
    ) !*Connection {
        const ds = display_str orelse return error.NoDisplay;
        const disp = try display_mod.parseDisplay(ds);

        // Open transport: unix socket for local, TCP for remote.
        const is_local = disp.host.len == 0 or std.mem.eql(u8, disp.host, "unix");
        const stream: std.Io.net.Stream = if (is_local) blk: {
            var path_buf: [108]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{}", .{disp.display}) catch
                return error.DisplayPathTooLong;
            const ua = try std.Io.net.UnixAddress.init(path);
            break :blk try ua.connect(io);
        } else blk: {
            // TCP: numeric IP only, no hostname resolution.
            const port = std.math.cast(u16, 6000 + @as(u32, disp.display)) orelse return error.InvalidDisplay;
            const addr = std.Io.net.IpAddress.parse(disp.host, port) catch
                return error.HostnameResolutionUnsupported;
            break :blk try addr.connect(io, .{ .mode = .stream });
        };
        errdefer stream.close(io);

        const auth_name: []const u8 = if (auth) |a| a.name else "";
        const auth_data: []const u8 = if (auth) |a| a.data else "";

        var write_buf: [256]u8 = undefined;
        var sw = stream.writer(io, &write_buf);
        try proto.encodeSetupRequest(&sw.interface, auth_name, auth_data);
        try sw.interface.flush();

        // First 8 bytes are the fixed header; bytes 6-7 hold additional-length in 4-byte units.
        var read_buf: [4096]u8 = undefined;
        var sr = stream.reader(io, &read_buf);

        var reply_writer = std.Io.Writer.Allocating.init(alloc);
        defer reply_writer.deinit();

        try (&sr.interface).streamExact(&reply_writer.writer, 8);
        const hdr = reply_writer.writer.buffered();
        const additional_u32s = std.mem.readInt(u16, hdr[6..8], native_endian);

        if (additional_u32s > 1_000_000) {
            return error.SetupReplyTooLarge;
        }

        const additional_bytes: usize = @as(usize, additional_u32s) * 4;

        try (&sr.interface).streamExact(&reply_writer.writer, additional_bytes);
        const full_reply = reply_writer.writer.buffered();

        const setup = try proto.parseSetupReply(alloc, full_reply);

        const conn = try alloc.create(Connection);
        conn.* = .{
            .allocator = alloc,
            .io = io,
            .stream = stream,
            .setup = setup,
            .sequence = 0,
        };
        return conn;
    }

    /// Close the socket and free the Connection allocation.
    pub fn disconnect(self: *Connection) void {
        self.stream.close(self.io);
        self.allocator.destroy(self);
    }

    /// Encode and send a request; return the sequence number the server will assign.
    pub fn sendRequest(self: *Connection, major: u8, minor_or_data: u8, extra: []const u8) !u16 {
        var write_buf: [256]u8 = undefined;
        var sw = self.stream.writer(self.io, &write_buf);
        try proto.encodeRequest(&sw.interface, major, minor_or_data, extra);
        try sw.interface.flush();
        self.sequence +%= 1;
        return self.sequence;
    }

    /// Read a reply matched by sequence number, using the socket reader.
    pub fn readReply(self: *Connection, want_seq: u16, out_err: *proto.XError) !Reply {
        var read_buf: [4096]u8 = undefined;
        var sr = self.stream.reader(self.io, &read_buf);
        return readReplyFrom(&sr.interface, self.allocator, want_seq, out_err);
    }
};

/// An owned reply buffer returned by readReplyFrom / readReply.
pub const Reply = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Reply) void {
        self.allocator.free(self.bytes);
    }
};

/// Dispatch loop over an arbitrary reader.
///
/// Reads 32-byte packets and dispatches:
///   event  -> skip and continue.
///   error  -> if sequence matches want_seq, fill out_err and return error.XProtocolError;
///             otherwise skip and continue.
///   reply  -> if sequence matches want_seq, allocate (32 + length*4) bytes, copy the
///             header packet, read the extra bytes, and return Reply; otherwise
///             discard the extra bytes and continue.
///
/// Returns error.ConnectionClosed on any read failure or premature end of stream.
pub fn readReplyFrom(
    r: *std.Io.Reader,
    alloc: std.mem.Allocator,
    want_seq: u16,
    out_err: *proto.XError,
) !Reply {
    while (true) {
        var pkt: [32]u8 = undefined;
        r.readSliceAll(&pkt) catch return error.ConnectionClosed;

        switch (proto.responseType(pkt[0])) {
            .event => {},

            .err => {
                const xerr = try proto.parseError(&pkt);
                if (xerr.sequence == want_seq) {
                    out_err.* = xerr;
                    return error.XProtocolError;
                }
            },

            .reply => {
                const hdr = try proto.parseReplyHeader(&pkt);
                const extra_len: usize = @as(usize, hdr.length) * 4;

                if (hdr.sequence == want_seq) {
                    const total = 32 + extra_len;
                    const bytes = try alloc.alloc(u8, total);
                    errdefer alloc.free(bytes);
                    @memcpy(bytes[0..32], &pkt);
                    if (extra_len > 0) {
                        r.readSliceAll(bytes[32..]) catch return error.ConnectionClosed;
                    }
                    return Reply{ .bytes = bytes, .allocator = alloc };
                } else {
                    if (extra_len > 0) {
                        r.discardAll(extra_len) catch return error.ConnectionClosed;
                    }
                }
            },
        }
    }
}

test "readReplyFrom skips event and returns matching reply" {
    var buf: [68]u8 = std.mem.zeroes([68]u8);

    // 32-byte event packet: pkt[0] = 2
    buf[0] = 2;

    // 32-byte reply header for seq=1 with length=1 (4 extra bytes beyond 32)
    buf[32] = 1;
    std.mem.writeInt(u16, buf[34..36], 1, native_endian); // sequence = 1
    std.mem.writeInt(u32, buf[36..40], 1, native_endian); // length = 1

    // 4 extra bytes at buf[64..68] (already zeros)

    var r = std.Io.Reader.fixed(&buf);
    var xe: proto.XError = undefined;
    var reply = try readReplyFrom(&r, std.testing.allocator, 1, &xe);
    defer reply.deinit();

    try std.testing.expectEqual(@as(usize, 36), reply.bytes.len);
    try std.testing.expectEqual(@as(u8, 1), reply.bytes[0]);
    const seq = std.mem.readInt(u16, reply.bytes[2..4], native_endian);
    try std.testing.expectEqual(@as(u16, 1), seq);
}

test "readReplyFrom returns XProtocolError on matching X error" {
    var buf: [32]u8 = std.mem.zeroes([32]u8);

    buf[0] = 0; // error marker
    buf[1] = 3; // error code
    std.mem.writeInt(u16, buf[2..4], 1, native_endian); // sequence = 1
    std.mem.writeInt(u32, buf[4..8], 0, native_endian); // bad_value
    std.mem.writeInt(u16, buf[8..10], 0, native_endian); // minor_opcode
    buf[10] = 98; // major_opcode

    var r = std.Io.Reader.fixed(&buf);
    var xe: proto.XError = undefined;
    try std.testing.expectError(error.XProtocolError, readReplyFrom(&r, std.testing.allocator, 1, &xe));
    try std.testing.expectEqual(@as(u8, 3), xe.code);
    try std.testing.expectEqual(@as(u8, 98), xe.major_opcode);
}

test "readReplyFrom skips wrong-sequence reply consuming extra bytes" {
    // Reply for seq=2 with length=1 (4 extra bytes), then reply for seq=1 with length=0.
    var buf: [68]u8 = std.mem.zeroes([68]u8);

    // First packet: reply for seq=2, length=1
    buf[0] = 1;
    std.mem.writeInt(u16, buf[2..4], 2, native_endian); // sequence = 2
    std.mem.writeInt(u32, buf[4..8], 1, native_endian); // length = 1

    // 4 extra bytes at buf[32..36] (zeros)

    // Second packet: reply for seq=1, length=0
    buf[36] = 1;
    std.mem.writeInt(u16, buf[38..40], 1, native_endian); // sequence = 1
    std.mem.writeInt(u32, buf[40..44], 0, native_endian); // length = 0

    var r = std.Io.Reader.fixed(&buf);
    var xe: proto.XError = undefined;
    var reply = try readReplyFrom(&r, std.testing.allocator, 1, &xe);
    defer reply.deinit();

    try std.testing.expectEqual(@as(usize, 32), reply.bytes.len);
    const seq = std.mem.readInt(u16, reply.bytes[2..4], native_endian);
    try std.testing.expectEqual(@as(u16, 1), seq);
}
