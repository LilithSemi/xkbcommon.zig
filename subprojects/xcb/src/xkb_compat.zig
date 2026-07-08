/// XkbGetCompatMap reply parser.
const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

/// One raw SymInterpret record (16 bytes on the wire).
pub const CompatInterp = struct {
    /// Keysym to match; 0 = wildcard.
    sym: u32,
    /// Real modifier mask.
    mods: u8,
    /// Raw match byte: bits 0-3 = match op, bit 7 = LevelOneOnly.
    match: u8,
    /// Virtual mod bit index (0-15); 0xFF = none.
    virtual_mod: u8,
    /// SymInterpret flags byte.
    flags: u8,
    /// Raw 8-byte XkbAction body.
    action: [8]u8,
};

pub const GetCompatMapReply = struct {
    arena: std.heap.ArenaAllocator,
    interprets: []CompatInterp,

    pub fn deinit(self: *GetCompatMapReply) void {
        self.arena.deinit();
    }
};

/// Parse an XkbGetCompatMap reply buffer.
///
/// Reply header (32 bytes):
///   [0]  reply type   [1]  deviceID
///   [2..4] sequence   [4..8] length
///   [8]  groups (SETofGROUP bitmask)  [9] pad
///   [10..12] firstSI (u16)
///   [12..14] nSI (u16)
///   [14..16] nTotalSI (u16)
///   [16..32] pad
///
/// Variable data: nSI SymInterpret records (16 bytes each), then GroupCompat records.
pub fn parseGetCompatMap(alloc: std.mem.Allocator, bytes: []const u8) !GetCompatMapReply {
    if (bytes.len < 32) return error.ShortReply;

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    const n_si: usize = std.mem.readInt(u16, bytes[12..14], native_endian);

    var cursor: usize = 32;
    const interprets = try a.alloc(CompatInterp, n_si);
    for (interprets) |*ci| {
        if (cursor + 16 > bytes.len) return error.ShortReply;
        ci.sym = std.mem.readInt(u32, bytes[cursor..][0..4], native_endian);
        ci.mods = bytes[cursor + 4];
        ci.match = bytes[cursor + 5];
        ci.virtual_mod = bytes[cursor + 6];
        ci.flags = bytes[cursor + 7];
        ci.action = bytes[cursor + 8 ..][0..8].*;
        cursor += 16;
    }

    return GetCompatMapReply{ .arena = arena, .interprets = interprets };
}

test "parseGetCompatMap synthetic: 1 interpret with sym=0x61" {
    // Build a minimal GetCompatMap reply. Header is 32 bytes;
    // bytes[12..14]=nSI=1; variable data: 1 SymInterpret record (16 bytes).
    // SymInterpret wire: sym(u32) mods(u8) match(u8) virtual_mod(u8) flags(u8) action[8].
    var bytes = [_]u8{0} ** 48;
    std.mem.writeInt(u16, bytes[12..14], 1, native_endian); // nSI = 1
    std.mem.writeInt(u32, bytes[32..36], 0x61, native_endian); // sym = 'a' (0x61)
    // bytes[36..48] = 0 (mods, match, virtual_mod, flags, action)

    var r = try parseGetCompatMap(std.testing.allocator, &bytes);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.interprets.len);
    try std.testing.expectEqual(@as(u32, 0x61), r.interprets[0].sym);
}

test "parseGetCompatMap synthetic: 2 interprets, check both syms" {
    // nSI=2; two 16-byte records: sym=0x41 and sym=0xFE02.
    var bytes = [_]u8{0} ** 64;
    std.mem.writeInt(u16, bytes[12..14], 2, native_endian); // nSI = 2
    std.mem.writeInt(u32, bytes[32..36], 0x41, native_endian); // record 0 sym = 'A'
    std.mem.writeInt(u32, bytes[48..52], 0xFE02, native_endian); // record 1 sym = ISO_Level2_Latch

    var r = try parseGetCompatMap(std.testing.allocator, &bytes);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 2), r.interprets.len);
    try std.testing.expectEqual(@as(u32, 0x41), r.interprets[0].sym);
    try std.testing.expectEqual(@as(u32, 0xFE02), r.interprets[1].sym);
}

test "parseGetCompatMap: rejects short buffer" {
    const tiny = [_]u8{0} ** 31;
    try std.testing.expectError(error.ShortReply, parseGetCompatMap(std.testing.allocator, &tiny));
}
