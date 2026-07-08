const std = @import("std");
const ModMask = @import("../keymap.zig").ModMask;
const ModIndex = @import("../keymap.zig").ModIndex;

const RealModEntry = struct {
    name: []const u8,
    mask: ModMask,
};

const real_mod_table = [_]RealModEntry{
    .{ .name = "shift", .mask = 0x01 },
    .{ .name = "lock", .mask = 0x02 },
    .{ .name = "control", .mask = 0x04 },
    .{ .name = "mod1", .mask = 0x08 },
    .{ .name = "mod2", .mask = 0x10 },
    .{ .name = "mod3", .mask = 0x20 },
    .{ .name = "mod4", .mask = 0x40 },
    .{ .name = "mod5", .mask = 0x80 },
};

pub fn realModMask(name: []const u8) ?ModMask {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf[0..name.len], name);
    for (real_mod_table) |entry| {
        if (std.mem.eql(u8, lower, entry.name)) return entry.mask;
    }
    return null;
}

pub fn realModIndex(name: []const u8) ?ModIndex {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf[0..name.len], name);
    for (real_mod_table, 0..) |entry, i| {
        if (std.mem.eql(u8, lower, entry.name)) return @as(ModIndex, @intCast(i));
    }
    return null;
}

pub fn modIndexMask(index: ModIndex) ModMask {
    if (index >= 32) return 0;
    return @as(ModMask, 1) << @intCast(index);
}

pub const VirtualMods = struct {
    alloc: std.mem.Allocator,
    names: std.ArrayList([]u8),

    pub fn init(alloc: std.mem.Allocator) VirtualMods {
        return .{
            .alloc = alloc,
            .names = .empty,
        };
    }

    pub fn deinit(self: *VirtualMods) void {
        for (self.names.items) |n| self.alloc.free(n);
        self.names.deinit(self.alloc);
    }

    pub fn intern(self: *VirtualMods, name: []const u8) !ModIndex {
        for (self.names.items, 0..) |n, i| {
            if (std.ascii.eqlIgnoreCase(n, name)) return @as(ModIndex, 8) + @as(ModIndex, @intCast(i));
        }
        const dup = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(dup);
        try self.names.append(self.alloc, dup);
        return @as(ModIndex, 8) + @as(ModIndex, @intCast(self.names.items.len - 1));
    }

    pub fn count(self: *const VirtualMods) usize {
        return self.names.items.len;
    }

    /// Return 8+i for a previously-interned vmod name (case-insensitive), or null.
    pub fn lookup(self: *const VirtualMods, name: []const u8) ?ModIndex {
        for (self.names.items, 0..) |n, i| {
            if (std.ascii.eqlIgnoreCase(n, name)) return @as(ModIndex, 8) + @as(ModIndex, @intCast(i));
        }
        return null;
    }

    pub fn mask(index: ModIndex) ModMask {
        return modIndexMask(index);
    }
};

test "mods: realModMask case insensitive" {
    try std.testing.expectEqual(@as(ModMask, 0x4), realModMask("control").?);
    try std.testing.expectEqual(@as(ModMask, 0x4), realModMask("Control").?);
    try std.testing.expectEqual(@as(ModMask, 0x1), realModMask("SHIFT").?);
    try std.testing.expectEqual(@as(ModMask, 0x2), realModMask("Lock").?);
    try std.testing.expect(realModMask("bogus") == null);
}

test "mods: VirtualMods builder dedup" {
    var vm = VirtualMods.init(std.testing.allocator);
    defer vm.deinit();

    const idx1 = try vm.intern("NumLock");
    try std.testing.expect(idx1 >= 8);

    const idx2 = try vm.intern("NumLock");
    try std.testing.expectEqual(idx1, idx2);

    const idx3 = try vm.intern("LevelThree");
    try std.testing.expect(idx3 != idx1);
    try std.testing.expect(idx3 >= 8);
    try std.testing.expectEqual(@as(usize, 2), vm.count());
}
