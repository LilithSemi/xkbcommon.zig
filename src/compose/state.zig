/// ComposeState tracks a position in a ComposeTable trie as keysyms are fed.
/// Modifier keysyms are silently ignored. A non-match cancels the sequence.
/// A leaf node sets status to .composed and makes getUtf8/getOneSym valid.
const std = @import("std");
const table_mod = @import("table.zig");
pub const ComposeTable = table_mod.ComposeTable;
pub const Keysym = table_mod.Keysym;

pub const Status = enum { nothing, composing, composed, cancelled };
pub const FeedResult = enum { ignored, accepted };

// Stable XKB constants for modifier keys.
const modifier_values = [_]u32{
    0xffe1, // Shift_L
    0xffe2, // Shift_R
    0xffe3, // Control_L
    0xffe4, // Control_R
    0xffe5, // Caps_Lock
    0xffe6, // Shift_Lock
    0xffe7, // Meta_L
    0xffe8, // Meta_R
    0xffe9, // Alt_L
    0xffea, // Alt_R
    0xffeb, // Super_L
    0xffec, // Super_R
    0xffed, // Hyper_L
    0xffee, // Hyper_R
    0xff7e, // Mode_switch
    0xff7f, // Num_Lock
    0xfe03, // ISO_Level3_Shift
    0xfe11, // ISO_Level5_Shift
};

fn isModifier(ks: Keysym) bool {
    const val = @backingInt(ks);
    for (modifier_values) |m| {
        if (val == m) return true;
    }
    return false;
}

pub const ComposeState = struct {
    table: *ComposeTable,
    node: *const ComposeTable.Node,
    status: Status,

    pub fn new(table: *ComposeTable) !*ComposeState {
        const self = try table.ctx.allocator.create(ComposeState);
        self.* = .{
            .table = table,
            .node = &table.root,
            .status = .nothing,
        };
        return self;
    }

    pub fn destroy(self: *ComposeState) void {
        self.table.ctx.allocator.destroy(self);
    }

    pub fn reset(self: *ComposeState) void {
        self.node = &self.table.root;
        self.status = .nothing;
    }

    pub fn getStatus(self: *const ComposeState) Status {
        return self.status;
    }

    pub fn getOneSym(self: *const ComposeState) Keysym {
        if (self.status != .composed) return .no_symbol;
        return self.node.result.?.keysym;
    }

    pub fn getUtf8(self: *const ComposeState, buf: []u8) ?[]const u8 {
        if (self.status != .composed) return null;
        const result = self.node.result.?;
        if (result.utf8.len > 0) {
            if (buf.len < result.utf8.len) return null;
            @memcpy(buf[0..result.utf8.len], result.utf8);
            return buf[0..result.utf8.len];
        }
        if (result.keysym != .no_symbol) {
            return result.keysym.toUtf8(buf);
        }
        return null;
    }

    pub fn feed(self: *ComposeState, ks: Keysym) FeedResult {
        if (isModifier(ks)) return .ignored;
        if (self.status == .composed or self.status == .cancelled) {
            self.reset();
        }
        if (ComposeTable.lookup(self.node, ks)) |next| {
            self.node = next;
            self.status = if (next.result != null) .composed else .composing;
        } else {
            self.node = &self.table.root;
            self.status = .cancelled;
        }
        return .accepted;
    }
};

test "ComposeState feed sequence" {
    const Context = @import("../context.zig").Context;
    const ctx = try Context.create(std.testing.allocator, std.testing.io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const table = try ComposeTable.newFromBuffer(ctx, "<dead_acute> <a> : \"á\" aacute", .text_v1);
    defer table.destroy();
    const st = try ComposeState.new(table);
    defer st.destroy();

    // modifier is ignored with no state change
    try std.testing.expectEqual(FeedResult.ignored, st.feed(Keysym.fromName("Shift_L", .{}).?));
    try std.testing.expectEqual(Status.nothing, st.getStatus());

    // dead_acute advances into composing
    try std.testing.expectEqual(FeedResult.accepted, st.feed(Keysym.fromName("dead_acute", .{}).?));
    try std.testing.expectEqual(Status.composing, st.getStatus());

    // 'a' completes the sequence
    try std.testing.expectEqual(FeedResult.accepted, st.feed(Keysym.fromName("a", .{}).?));
    try std.testing.expectEqual(Status.composed, st.getStatus());

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\xc3\xa1", st.getUtf8(&buf).?); // UTF-8 for á
    try std.testing.expectEqual(Keysym.fromName("aacute", .{}).?, st.getOneSym());

    // a non-matching sequence after reset cancels
    st.reset();
    try std.testing.expectEqual(Status.nothing, st.getStatus());
    try std.testing.expectEqual(FeedResult.accepted, st.feed(Keysym.fromName("dead_acute", .{}).?));
    _ = st.feed(Keysym.fromName("z", .{}).?); // no <dead_acute> <z> rule
    try std.testing.expectEqual(Status.cancelled, st.getStatus());
}

test "ComposeState auto-reset on next feed after composed" {
    const Context = @import("../context.zig").Context;
    const ctx = try Context.create(std.testing.allocator, std.testing.io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const table = try ComposeTable.newFromBuffer(ctx, "<dead_acute> <a> : \"á\" aacute", .text_v1);
    defer table.destroy();
    const st = try ComposeState.new(table);
    defer st.destroy();

    _ = st.feed(Keysym.fromName("dead_acute", .{}).?);
    _ = st.feed(Keysym.fromName("a", .{}).?);
    try std.testing.expectEqual(Status.composed, st.getStatus());

    // feeding dead_acute again auto-resets and starts fresh composing
    try std.testing.expectEqual(FeedResult.accepted, st.feed(Keysym.fromName("dead_acute", .{}).?));
    try std.testing.expectEqual(Status.composing, st.getStatus());
}

test "ComposeState getOneSym and getUtf8 only when composed" {
    const Context = @import("../context.zig").Context;
    const ctx = try Context.create(std.testing.allocator, std.testing.io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const table = try ComposeTable.newFromBuffer(ctx, "<dead_acute> <a> : \"á\" aacute", .text_v1);
    defer table.destroy();
    const st = try ComposeState.new(table);
    defer st.destroy();

    try std.testing.expectEqual(Keysym.no_symbol, st.getOneSym());
    var buf: [16]u8 = undefined;
    try std.testing.expect(st.getUtf8(&buf) == null);
}
