/// XkbGetControls reply parser, extracts numGroups from the fixed reply header.
/// Wire layout: XCB reply prefix (8 bytes) + mouseKeysDfltBtn (1 byte) + numGroups (1 byte) at offset [9].
const std = @import("std");

pub fn parseGetControls(bytes: []const u8) !struct { num_groups: u8 } {
    if (bytes.len < 10) return error.ShortReply;
    return .{ .num_groups = bytes[9] };
}

test "parseGetControls synthetic: numGroups=2" {
    // Wire layout: XCB reply prefix (8 bytes) + mouseKeysDfltBtn (1 byte) + numGroups at [9].
    var bytes = [_]u8{0} ** 10;
    bytes[9] = 2; // numGroups
    const r = try parseGetControls(&bytes);
    try std.testing.expectEqual(@as(u8, 2), r.num_groups);
}

test "parseGetControls rejects short buffer" {
    const tiny = [_]u8{0} ** 9;
    try std.testing.expectError(error.ShortReply, parseGetControls(&tiny));
}
