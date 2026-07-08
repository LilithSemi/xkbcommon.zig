/// X11 connection-setup wire codec. encodeSetupRequest serialises the client
/// hello (byte order, version, auth). parseSetupReply decodes the server's
/// success or fail response into a Setup.
const std = @import("std");
const builtin = @import("builtin");

const native_endian = builtin.cpu.arch.endian();

/// Round n up to the next multiple of 4.
fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

/// The useful subset of the X11 connection-setup success reply.
pub const Setup = struct {
    protocol_major: u16,
    protocol_minor: u16,
    release_number: u32,
    resource_id_base: u32,
    resource_id_mask: u32,
    min_keycode: u8,
    max_keycode: u8,
    roots_len: u8,
    root: u32,
    root_visual: u32,
};

/// Write the X11 SetupRequest to w using the host's native byte order.
///
/// Wire layout (all multi-byte fields in native byte order):
///   u8  byte_order   0x6c = little, 0x42 = big
///   u8  pad          0
///   u16 protocol_major  11
///   u16 protocol_minor  0
///   u16 auth_name_len
///   u16 auth_data_len
///   u16 pad2         0
///   [auth_name_len]u8  auth_name, zero-padded to 4-byte boundary
///   [auth_data_len]u8  auth_data, zero-padded to 4-byte boundary
pub fn encodeSetupRequest(
    w: *std.Io.Writer,
    auth_name: []const u8,
    auth_data: []const u8,
) !void {
    if (auth_name.len > std.math.maxInt(u16) or auth_data.len > std.math.maxInt(u16)) {
        return error.AuthTooLong;
    }

    const byte_order: u8 = if (native_endian == .little) 0x6c else 0x42;
    const zeros = [3]u8{ 0, 0, 0 };

    var u16buf: [2]u8 = undefined;

    try w.writeAll(&[_]u8{ byte_order, 0 });

    std.mem.writeInt(u16, &u16buf, 11, native_endian);
    try w.writeAll(&u16buf);

    std.mem.writeInt(u16, &u16buf, 0, native_endian);
    try w.writeAll(&u16buf);

    std.mem.writeInt(u16, &u16buf, @intCast(auth_name.len), native_endian);
    try w.writeAll(&u16buf);

    std.mem.writeInt(u16, &u16buf, @intCast(auth_data.len), native_endian);
    try w.writeAll(&u16buf);

    std.mem.writeInt(u16, &u16buf, 0, native_endian);
    try w.writeAll(&u16buf);

    try w.writeAll(auth_name);
    const name_pad = pad4(auth_name.len) - auth_name.len;
    try w.writeAll(zeros[0..name_pad]);

    try w.writeAll(auth_data);
    const data_pad = pad4(auth_data.len) - auth_data.len;
    try w.writeAll(zeros[0..data_pad]);
}

/// Parse a server SetupReply from the raw bytes.
///
/// Returns error.SetupFailed on status 0, error.SetupAuthenticate on status 2.
/// Parses only the first SCREEN for root and root_visual.
/// Returns error.MalformedSetup on any short or structurally invalid buffer.
pub fn parseSetupReply(alloc: std.mem.Allocator, bytes: []const u8) !Setup {
    _ = alloc;

    if (bytes.len < 1) return error.MalformedSetup;

    switch (bytes[0]) {
        0 => return error.SetupFailed,
        2 => return error.SetupAuthenticate,
        1 => {
            // Fixed header occupies bytes 0-39 (40 bytes).
            if (bytes.len < 40) return error.MalformedSetup;

            const protocol_major = std.mem.readInt(u16, bytes[2..4], native_endian);
            const protocol_minor = std.mem.readInt(u16, bytes[4..6], native_endian);
            const release_number = std.mem.readInt(u32, bytes[8..12], native_endian);
            const resource_id_base = std.mem.readInt(u32, bytes[12..16], native_endian);
            const resource_id_mask = std.mem.readInt(u32, bytes[16..20], native_endian);
            const vendor_len = std.mem.readInt(u16, bytes[24..26], native_endian);
            const roots_len = bytes[28];
            const pixmap_formats_len = bytes[29];
            const min_keycode = bytes[34];
            const max_keycode = bytes[35];

            // Skip vendor string (padded to 4) and FORMAT records (8 bytes each).
            const vendor_skip = pad4(@as(usize, vendor_len));
            const formats_skip = @as(usize, pixmap_formats_len) * 8;
            const screen_offset = 40 + vendor_skip + formats_skip;

            if (roots_len == 0) return error.MalformedSetup;

            // First SCREEN layout (offsets from screen start):
            //   0  root: u32
            //   4  default_colormap: u32
            //   8  white_pixel: u32
            //  12  black_pixel: u32
            //  16  current_input_masks: u32
            //  20  width_px: u16
            //  22  height_px: u16
            //  24  width_mm: u16
            //  26  height_mm: u16
            //  28  min_installed_maps: u16
            //  30  max_installed_maps: u16
            //  32  root_visual: u32     <- last field we need
            //  36  ...
            if (bytes.len < screen_offset + 36) return error.MalformedSetup;

            const root = std.mem.readInt(u32, bytes[screen_offset..][0..4], native_endian);
            const root_visual = std.mem.readInt(u32, bytes[screen_offset + 32 ..][0..4], native_endian);

            return Setup{
                .protocol_major = protocol_major,
                .protocol_minor = protocol_minor,
                .release_number = release_number,
                .resource_id_base = resource_id_base,
                .resource_id_mask = resource_id_mask,
                .min_keycode = min_keycode,
                .max_keycode = max_keycode,
                .roots_len = roots_len,
                .root = root,
                .root_visual = root_visual,
            };
        },
        else => return error.MalformedSetup,
    }
}

test "encodeSetupRequest byte layout and padding" {
    const auth_name = "MIT-MAGIC-COOKIE-1"; // 18 bytes -> padded to 20
    const auth_data = [_]u8{0xde} ** 16; // 16 bytes -> no extra pad

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try encodeSetupRequest(&aw.writer, auth_name, &auth_data);
    const buf = aw.writer.buffered();

    // Fixed header: 12 bytes; auth_name padded: 20; auth_data padded: 16 -> total 48.
    try std.testing.expectEqual(@as(usize, 48), buf.len);
    // Total length must be a multiple of 4.
    try std.testing.expectEqual(@as(usize, 0), buf.len % 4);

    // byte_order sentinel.
    const expected_order: u8 = if (native_endian == .little) 0x6c else 0x42;
    try std.testing.expectEqual(expected_order, buf[0]);
    // pad byte is 0.
    try std.testing.expectEqual(@as(u8, 0), buf[1]);

    // protocol_major = 11 in native endian.
    const major = std.mem.readInt(u16, buf[2..4], native_endian);
    try std.testing.expectEqual(@as(u16, 11), major);

    // auth_name_len = 18.
    const name_len = std.mem.readInt(u16, buf[6..8], native_endian);
    try std.testing.expectEqual(@as(u16, 18), name_len);

    // auth_data_len = 16.
    const data_len = std.mem.readInt(u16, buf[8..10], native_endian);
    try std.testing.expectEqual(@as(u16, 16), data_len);

    // auth_name bytes start at offset 12.
    try std.testing.expectEqualSlices(u8, auth_name, buf[12..30]);
    // Padding bytes at 30-31 must be zero.
    try std.testing.expectEqual(@as(u8, 0), buf[30]);
    try std.testing.expectEqual(@as(u8, 0), buf[31]);

    // auth_data at offset 32 (12 + 20).
    try std.testing.expectEqualSlices(u8, &auth_data, buf[32..48]);
}

test "parseSetupReply success extracts fields" {
    // Build a minimal but structurally valid Success reply in native byte order.
    // Fixed header: 40 bytes, vendor: 0, pixmap_formats: 0, one SCREEN: 36+ bytes.
    var buf = std.mem.zeroes([80]u8);

    buf[0] = 1; // status = Success
    buf[1] = 0; // unused
    std.mem.writeInt(u16, buf[2..4], 11, native_endian); // protocol_major
    std.mem.writeInt(u16, buf[4..6], 0, native_endian); // protocol_minor
    std.mem.writeInt(u16, buf[6..8], 18, native_endian); // length (4-byte units)
    std.mem.writeInt(u32, buf[8..12], 12007000, native_endian); // release_number
    std.mem.writeInt(u32, buf[12..16], 0x04200000, native_endian); // resource_id_base
    std.mem.writeInt(u32, buf[16..20], 0x001fffff, native_endian); // resource_id_mask
    std.mem.writeInt(u32, buf[20..24], 256, native_endian); // motion_buffer_size
    std.mem.writeInt(u16, buf[24..26], 0, native_endian); // vendor_len = 0
    std.mem.writeInt(u16, buf[26..28], 65535, native_endian); // max_request_length
    buf[28] = 1; // roots_len = 1
    buf[29] = 0; // pixmap_formats_len = 0
    buf[30] = if (native_endian == .little) 0 else 1; // image_byte_order
    buf[31] = 0; // bitmap_format_bit_order
    buf[32] = 32; // bitmap_format_scanline_unit
    buf[33] = 32; // bitmap_format_scanline_pad
    buf[34] = 8; // min_keycode
    buf[35] = 255; // max_keycode
    // buf[36..40] = pad (already zero)

    // SCREEN at offset 40 (vendor_skip=0, formats_skip=0).
    std.mem.writeInt(u32, buf[40..44], 0x0000012a, native_endian); // root
    std.mem.writeInt(u32, buf[44..48], 0x00000025, native_endian); // default_colormap
    std.mem.writeInt(u32, buf[48..52], 0x00ffffff, native_endian); // white_pixel
    // black_pixel, current_input_masks: already zero
    std.mem.writeInt(u16, buf[60..62], 1920, native_endian); // width_px
    std.mem.writeInt(u16, buf[62..64], 1080, native_endian); // height_px
    std.mem.writeInt(u16, buf[64..66], 527, native_endian); // width_mm
    std.mem.writeInt(u16, buf[66..68], 296, native_endian); // height_mm
    std.mem.writeInt(u16, buf[68..70], 1, native_endian); // min_installed_maps
    std.mem.writeInt(u16, buf[70..72], 1, native_endian); // max_installed_maps
    std.mem.writeInt(u32, buf[72..76], 0x00000021, native_endian); // root_visual
    buf[78] = 24; // root_depth

    const setup = try parseSetupReply(std.testing.allocator, &buf);

    try std.testing.expectEqual(@as(u16, 11), setup.protocol_major);
    try std.testing.expectEqual(@as(u32, 0x04200000), setup.resource_id_base);
    try std.testing.expectEqual(@as(u32, 0x001fffff), setup.resource_id_mask);
    try std.testing.expectEqual(@as(u8, 8), setup.min_keycode);
    try std.testing.expectEqual(@as(u8, 255), setup.max_keycode);
    try std.testing.expectEqual(@as(u8, 1), setup.roots_len);
    try std.testing.expectEqual(@as(u32, 0x0000012a), setup.root);
    try std.testing.expectEqual(@as(u32, 0x00000021), setup.root_visual);
}

/// Encode an X11 request to w.
///
/// Wire layout:
///   u8  major_opcode
///   u8  minor_or_data
///   u16 length  (total request size in 4-byte units, including this 4-byte header)
///   [extra.len]u8  extra data
///   [pad]u8  zero-padding to next 4-byte boundary
pub fn encodeRequest(
    w: *std.Io.Writer,
    major: u8,
    minor_or_data: u8,
    extra: []const u8,
) !void {
    const total = 4 + pad4(extra.len);
    if (total / 4 > std.math.maxInt(u16)) return error.RequestTooLong;
    const length: u16 = @intCast(total / 4);

    var u16buf: [2]u8 = undefined;
    try w.writeAll(&[_]u8{ major, minor_or_data });
    std.mem.writeInt(u16, &u16buf, length, native_endian);
    try w.writeAll(&u16buf);
    try w.writeAll(extra);
    const pad_len = pad4(extra.len) - extra.len;
    const zeros = [3]u8{ 0, 0, 0 };
    try w.writeAll(zeros[0..pad_len]);
}

pub const ResponseType = enum { err, reply, event };

pub fn responseType(first: u8) ResponseType {
    return switch (first) {
        0 => .err,
        1 => .reply,
        else => .event,
    };
}

pub const ReplyHeader = struct { sequence: u16, length: u32 };

pub fn parseReplyHeader(bytes: []const u8) !ReplyHeader {
    if (bytes.len < 8) return error.ShortReply;
    const sequence = std.mem.readInt(u16, bytes[2..4], native_endian);
    const length = std.mem.readInt(u32, bytes[4..8], native_endian);
    return ReplyHeader{ .sequence = sequence, .length = length };
}

pub const XError = struct {
    code: u8,
    sequence: u16,
    bad_value: u32,
    minor_opcode: u16,
    major_opcode: u8,
};

pub fn parseError(bytes: []const u8) !XError {
    if (bytes.len < 32) return error.ShortError;
    return XError{
        .code = bytes[1],
        .sequence = std.mem.readInt(u16, bytes[2..4], native_endian),
        .bad_value = std.mem.readInt(u32, bytes[4..8], native_endian),
        .minor_opcode = std.mem.readInt(u16, bytes[8..10], native_endian),
        .major_opcode = bytes[10],
    };
}

pub fn eventCode(bytes: []const u8) u8 {
    return bytes[0] & 0x7f;
}

test "encodeRequest aligned extra" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const extra = [_]u8{0xAA} ** 8;
    try encodeRequest(&aw.writer, 98, 0, &extra);
    const buf = aw.writer.buffered();
    try std.testing.expectEqual(@as(usize, 12), buf.len);
    try std.testing.expectEqual(@as(usize, 0), buf.len % 4);
    try std.testing.expectEqual(@as(u8, 98), buf[0]);
    try std.testing.expectEqual(@as(u8, 0), buf[1]);
    const length = std.mem.readInt(u16, buf[2..4], native_endian);
    try std.testing.expectEqual(@as(u16, 3), length);
}

test "encodeRequest unaligned extra gets padded" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const extra = [_]u8{0xBB} ** 5;
    try encodeRequest(&aw.writer, 98, 0, &extra);
    const buf = aw.writer.buffered();
    // 5 bytes padded to 8, plus 4-byte header = 12.
    try std.testing.expectEqual(@as(usize, 12), buf.len);
    try std.testing.expectEqual(@as(usize, 0), buf.len % 4);
    const length = std.mem.readInt(u16, buf[2..4], native_endian);
    try std.testing.expectEqual(@as(u16, 3), length);
    // Pad bytes at positions 9, 10, 11 must be zero.
    try std.testing.expectEqual(@as(u8, 0), buf[9]);
    try std.testing.expectEqual(@as(u8, 0), buf[10]);
    try std.testing.expectEqual(@as(u8, 0), buf[11]);
}

test "parseReplyHeader canned bytes" {
    var buf = std.mem.zeroes([32]u8);
    buf[0] = 1; // reply marker
    std.mem.writeInt(u16, buf[2..4], 0x0042, native_endian);
    std.mem.writeInt(u32, buf[4..8], 2, native_endian);
    const hdr = try parseReplyHeader(&buf);
    try std.testing.expectEqual(@as(u16, 0x0042), hdr.sequence);
    try std.testing.expectEqual(@as(u32, 2), hdr.length);
}

test "parseReplyHeader short buffer" {
    const buf = [_]u8{1} ** 7;
    try std.testing.expectError(error.ShortReply, parseReplyHeader(&buf));
}

test "parseError canned bytes" {
    var buf = std.mem.zeroes([32]u8);
    buf[0] = 0; // error marker
    buf[1] = 3; // code = BadWindow
    std.mem.writeInt(u16, buf[2..4], 5, native_endian); // sequence
    std.mem.writeInt(u32, buf[4..8], 0xdeadbeef, native_endian); // bad_value
    std.mem.writeInt(u16, buf[8..10], 0, native_endian); // minor_opcode
    buf[10] = 98; // major_opcode
    const err = try parseError(&buf);
    try std.testing.expectEqual(@as(u8, 3), err.code);
    try std.testing.expectEqual(@as(u16, 5), err.sequence);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), err.bad_value);
    try std.testing.expectEqual(@as(u8, 98), err.major_opcode);
}

test "parseError short buffer" {
    const buf = [_]u8{0} ** 31;
    try std.testing.expectError(error.ShortError, parseError(&buf));
}

test "responseType classification" {
    try std.testing.expectEqual(ResponseType.err, responseType(0));
    try std.testing.expectEqual(ResponseType.reply, responseType(1));
    try std.testing.expectEqual(ResponseType.event, responseType(2));
    try std.testing.expectEqual(ResponseType.event, responseType(255));
}

test "eventCode masks high bit" {
    try std.testing.expectEqual(@as(u8, 0x02), eventCode(&[_]u8{0x82}));
    try std.testing.expectEqual(@as(u8, 0x15), eventCode(&[_]u8{0x95}));
    try std.testing.expectEqual(@as(u8, 0x00), eventCode(&[_]u8{0x80}));
}

test "parseSetupReply failed status" {
    var buf = std.mem.zeroes([16]u8);
    buf[0] = 0; // status = Failed
    buf[1] = 5; // reason_len = 5
    std.mem.writeInt(u16, buf[2..4], 11, native_endian); // protocol_major
    std.mem.writeInt(u16, buf[4..6], 0, native_endian); // protocol_minor
    std.mem.writeInt(u16, buf[6..8], 1, native_endian); // length (4-byte units)
    buf[8] = 'S';
    buf[9] = 'o';
    buf[10] = 'r';
    buf[11] = 'r';
    buf[12] = 'y';

    try std.testing.expectError(error.SetupFailed, parseSetupReply(std.testing.allocator, &buf));
}
