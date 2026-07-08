const std = @import("std");
const keymap_mod = @import("keymap.zig");
const Keymap = keymap_mod.Keymap;
const ModMask = keymap_mod.ModMask;
const Keysym = @import("keysym.zig").Keysym;
const mods_lib = @import("xkbcomp/mods.zig");

/// Returns level index for a key type given active mods (entry.mods == mods & type.mods). Returns 0 if no match.
pub fn getLevel(t: *const keymap_mod.KeyType, mods: ModMask) keymap_mod.LevelIndex {
    const active = mods & t.mods;
    for (t.entries) |e| {
        if (e.mods == active) return e.level;
    }
    return 0;
}

pub const Component = packed struct(u32) {
    mods_depressed: bool = false,
    mods_latched: bool = false,
    mods_locked: bool = false,
    mods_effective: bool = false,
    group_depressed: bool = false,
    group_latched: bool = false,
    group_locked: bool = false,
    group_effective: bool = false,
    leds: bool = false,
    _pad: u23 = 0,
};

pub const StateComponent = enum { depressed, latched, locked, effective };

pub const Direction = enum { up, down };

pub const State = struct {
    keymap: *Keymap,
    mod_base: ModMask = 0,
    mod_latched: ModMask = 0,
    mod_locked: ModMask = 0,
    mod_effective: ModMask = 0,
    grp_base: i32 = 0,
    grp_latched: i32 = 0,
    grp_locked: i32 = 0,
    grp_effective: i32 = 0,
    leds: u32 = 0,
    allocator: std.mem.Allocator,
    held: std.AutoHashMapUnmanaged(keymap_mod.Keycode, ModMask) = .empty,
    held_group: std.AutoHashMapUnmanaged(keymap_mod.Keycode, i32) = .empty,

    pub fn create(km: *Keymap) !*State {
        const alloc = km.ctx.allocator;
        const self = try alloc.create(State);
        self.* = .{
            .keymap = km,
            .allocator = alloc,
        };
        return self;
    }

    pub fn destroy(self: *State) void {
        self.held.deinit(self.allocator);
        self.held_group.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn updateMask(
        self: *State,
        base_mods: ModMask,
        latched_mods: ModMask,
        locked_mods: ModMask,
        base_grp: i32,
        latched_grp: i32,
        locked_grp: i32,
    ) Component {
        const old_base = self.mod_base;
        const old_latched = self.mod_latched;
        const old_locked = self.mod_locked;
        const old_effective = self.mod_effective;
        const old_grp_base = self.grp_base;
        const old_grp_latched = self.grp_latched;
        const old_grp_locked = self.grp_locked;
        const old_grp_effective = self.grp_effective;

        self.mod_base = base_mods;
        self.mod_latched = latched_mods;
        self.mod_locked = locked_mods;
        self.mod_effective = base_mods | latched_mods | locked_mods;
        self.grp_base = base_grp;
        self.grp_latched = latched_grp;
        self.grp_locked = locked_grp;
        self.grp_effective = base_grp + latched_grp + locked_grp;

        const new_leds = self.computeLeds();
        const leds_changed = new_leds != self.leds;
        if (leds_changed) self.leds = new_leds;

        return .{
            .mods_depressed = self.mod_base != old_base,
            .mods_latched = self.mod_latched != old_latched,
            .mods_locked = self.mod_locked != old_locked,
            .mods_effective = self.mod_effective != old_effective,
            .group_depressed = self.grp_base != old_grp_base,
            .group_latched = self.grp_latched != old_grp_latched,
            .group_locked = self.grp_locked != old_grp_locked,
            .group_effective = self.grp_effective != old_grp_effective,
            .leds = leds_changed,
        };
    }

    pub fn serializeMods(self: *const State, which: StateComponent) ModMask {
        return switch (which) {
            .depressed => self.mod_base,
            .latched => self.mod_latched,
            .locked => self.mod_locked,
            .effective => self.mod_effective,
        };
    }

    pub fn serializeLayout(self: *const State, which: StateComponent) i32 {
        return switch (which) {
            .depressed => self.grp_base,
            .latched => self.grp_latched,
            .locked => self.grp_locked,
            .effective => self.grp_effective,
        };
    }

    /// Resolves the layout index for a keycode, applying the out-of-range action if grp_effective is outside the key's group count.
    pub fn keyGetLayout(self: *const State, kc: keymap_mod.Keycode) i32 {
        if (kc >= self.keymap.keys.len) return 0;
        const key = &self.keymap.keys[kc];
        if (key.groups.len == 0) return 0;
        const n: i32 = @intCast(key.groups.len);
        const eff = self.grp_effective;
        if (eff >= 0 and eff < n) return eff;
        return switch (key.out_of_range_group_action) {
            .wrap => @mod(eff, n),
            .clamp => if (eff < 0) 0 else n - 1,
            .redirect => blk: {
                const max: u32 = @intCast(n - 1);
                const clamped = @min(key.out_of_range_group_number, max);
                break :blk @as(i32, @intCast(clamped));
            },
        };
    }

    /// Returns level index for a keycode within a layout, using mod_effective.
    pub fn keyGetLevel(self: *const State, kc: keymap_mod.Keycode, layout: i32) keymap_mod.LevelIndex {
        if (kc >= self.keymap.keys.len) return 0;
        const key = &self.keymap.keys[kc];
        if (layout < 0 or layout >= @as(i32, @intCast(key.groups.len))) return 0;
        const g = &key.groups[@intCast(layout)];
        if (g.levels.len == 0) return 0;
        if (g.type_index >= self.keymap.types.len) return 0;
        const t = &self.keymap.types[g.type_index];
        const lvl = getLevel(t, self.mod_effective);
        return if (lvl >= g.levels.len) @intCast(g.levels.len - 1) else lvl;
    }

    /// Returns the keysym slice for the current state at the given keycode.
    pub fn keyGetSyms(self: *const State, kc: keymap_mod.Keycode) []const Keysym {
        if (kc >= self.keymap.keys.len) return &.{};
        const key = &self.keymap.keys[kc];
        if (key.groups.len == 0) return &.{};
        const layout = self.keyGetLayout(kc);
        const level = self.keyGetLevel(kc, layout);
        const g = &key.groups[@intCast(layout)];
        if (g.levels.len == 0) return &.{};
        return g.levels[level].syms;
    }

    /// Returns the first keysym for the current state, or no_symbol.
    pub fn keyGetOneSym(self: *const State, kc: keymap_mod.Keycode) Keysym {
        const syms = self.keyGetSyms(kc);
        return if (syms.len >= 1) syms[0] else Keysym.no_symbol;
    }

    pub fn keyGetUtf32(self: *const State, kc: keymap_mod.Keycode) u21 {
        return self.keyGetOneSym(kc).toUtf32();
    }

    /// Encodes the one-sym as UTF-8 into buf. Returns the written slice,
    /// or null if there is no mapping or buf is too small.
    pub fn keyGetUtf8(self: *const State, kc: keymap_mod.Keycode, buf: []u8) ?[]const u8 {
        return self.keyGetOneSym(kc).toUtf8(buf);
    }

    /// Process a key press or release event, updating modifier and group state.
    /// Returns a Component bitmask indicating which state fields changed.
    pub fn updateKey(self: *State, kc: keymap_mod.Keycode, dir: Direction) !Component {
        const old_base = self.mod_base;
        const old_latched = self.mod_latched;
        const old_locked = self.mod_locked;
        const old_effective = self.mod_effective;
        const old_grp_base = self.grp_base;
        const old_grp_latched = self.grp_latched;
        const old_grp_locked = self.grp_locked;
        const old_grp_effective = self.grp_effective;

        const action: keymap_mod.Action = blk: {
            if (kc >= self.keymap.keys.len) break :blk .none;
            const key = &self.keymap.keys[kc];
            if (key.groups.len == 0) break :blk .none;
            const layout_idx = self.keyGetLayout(kc);
            if (layout_idx < 0) break :blk .none;
            const li: usize = @intCast(layout_idx);
            if (li >= key.groups.len) break :blk .none;
            const g = &key.groups[li];
            if (g.levels.len == 0) break :blk .none;
            break :blk g.levels[0].action;
        };

        switch (dir) {
            .down => {
                switch (action) {
                    .mods => |ma| switch (ma.kind) {
                        .set => {
                            const contribution = ma.mods;
                            self.mod_base |= contribution;
                            try self.held.put(self.allocator, kc, contribution);
                        },
                        .latch => {
                            self.mod_latched |= ma.mods;
                        },
                        .lock => {
                            self.mod_locked ^= ma.mods;
                        },
                    },
                    .group => |ga| switch (ga.kind) {
                        .set => {
                            if (!self.held_group.contains(kc)) {
                                const prev = self.grp_base;
                                if (ga.absolute) {
                                    self.grp_base = ga.group;
                                } else {
                                    self.grp_base += ga.group;
                                }
                                const delta = self.grp_base - prev;
                                try self.held_group.put(self.allocator, kc, delta);
                            }
                        },
                        .latch => {
                            self.grp_latched += ga.group;
                        },
                        .lock => {
                            if (ga.absolute) {
                                self.grp_locked = ga.group;
                            } else {
                                self.grp_locked += ga.group;
                            }
                        },
                    },
                    .none => {
                        if (kc < self.keymap.keys.len) {
                            const contribution = self.keymap.keys[kc].modmap;
                            self.mod_base |= contribution;
                            if (contribution != 0) {
                                try self.held.put(self.allocator, kc, contribution);
                            }
                        }
                    },
                    else => {},
                }
            },
            .up => {
                _ = self.held.remove(kc);
                var new_base: ModMask = 0;
                var it = self.held.iterator();
                while (it.next()) |entry| {
                    new_base |= entry.value_ptr.*;
                }
                self.mod_base = new_base;

                if (self.held_group.fetchRemove(kc)) |kv| {
                    self.grp_base -= kv.value;
                }
            },
        }

        self.mod_effective = self.mod_base | self.mod_latched | self.mod_locked;
        self.grp_effective = self.grp_base + self.grp_latched + self.grp_locked;

        const new_leds = self.computeLeds();
        const leds_changed = new_leds != self.leds;
        if (leds_changed) self.leds = new_leds;

        return .{
            .mods_depressed = self.mod_base != old_base,
            .mods_latched = self.mod_latched != old_latched,
            .mods_locked = self.mod_locked != old_locked,
            .mods_effective = self.mod_effective != old_effective,
            .group_depressed = self.grp_base != old_grp_base,
            .group_latched = self.grp_latched != old_grp_latched,
            .group_locked = self.grp_locked != old_grp_locked,
            .group_effective = self.grp_effective != old_grp_effective,
            .leds = leds_changed,
        };
    }

    /// Returns true if the modifier at index `idx` is active in the given component.
    pub fn modIndexIsActive(self: *const State, idx: u32, which: StateComponent) bool {
        if (idx >= 32) return false;
        const mask: ModMask = @as(ModMask, 1) << @intCast(idx);
        const component = switch (which) {
            .depressed => self.mod_base,
            .latched => self.mod_latched,
            .locked => self.mod_locked,
            .effective => self.mod_effective,
        };
        return (component & mask) != 0;
    }

    /// Returns true if the named modifier is active. Checks real mods first, then keymap.mods.
    pub fn modNameIsActive(self: *const State, name: []const u8, which: StateComponent) bool {
        const mask: ModMask = blk: {
            if (mods_lib.realModMask(name)) |m| break :blk m;
            for (self.keymap.mods.mods, 0..) |mod, i| {
                const atom_name = self.keymap.ctx.atomText(mod.name);
                if (std.ascii.eqlIgnoreCase(atom_name, name)) {
                    break :blk @as(ModMask, 1) << @intCast(i);
                }
            }
            return false;
        };
        const component = switch (which) {
            .depressed => self.mod_base,
            .latched => self.mod_latched,
            .locked => self.mod_locked,
            .effective => self.mod_effective,
        };
        return (component & mask) != 0;
    }

    /// Returns true if the given layout index equals the selected group component.
    pub fn layoutIndexIsActive(self: *const State, layout: i32, which: StateComponent) bool {
        const grp = switch (which) {
            .depressed => self.grp_base,
            .latched => self.grp_latched,
            .locked => self.grp_locked,
            .effective => self.grp_effective,
        };
        return grp == layout;
    }

    /// Returns true if the LED at index `idx` is active (all its mods are in mod_effective).
    pub fn ledIndexIsActive(self: *const State, idx: u32) bool {
        if (idx >= self.keymap.leds.len) return false;
        const led = &self.keymap.leds[idx];
        if (led.mods == 0) return false;
        return (led.mods & self.mod_effective) == led.mods;
    }

    pub fn ledNameIsActive(self: *const State, name: []const u8) bool {
        for (self.keymap.leds, 0..) |led, i| {
            const atom_name = self.keymap.ctx.atomText(led.name);
            if (std.ascii.eqlIgnoreCase(atom_name, name)) {
                return self.ledIndexIsActive(@intCast(i));
            }
        }
        return false;
    }

    /// Recomputes the LED bitmask. Bit i is set when all of led[i].mods are in mod_effective.
    fn computeLeds(self: *const State) u32 {
        var mask: u32 = 0;
        for (self.keymap.leds, 0..) |led, i| {
            if (led.mods != 0 and (led.mods & self.mod_effective) == led.mods) {
                mask |= @as(u32, 1) << @intCast(i);
            }
        }
        return mask;
    }

    /// Returns the set of modifiers consumed by the key's type when picking its level.
    /// Consumed = type.mods minus the preserve mask of the matched entry (XKB consume mode).
    pub fn keyGetConsumedMods(self: *const State, kc: keymap_mod.Keycode) ModMask {
        if (kc >= self.keymap.keys.len) return 0;
        const key = &self.keymap.keys[kc];
        if (key.groups.len == 0) return 0;
        const layout = self.keyGetLayout(kc);
        if (layout < 0 or layout >= @as(i32, @intCast(key.groups.len))) return 0;
        const g = &key.groups[@intCast(layout)];
        if (g.type_index >= self.keymap.types.len) return 0;
        const t = &self.keymap.types[g.type_index];
        const active = self.mod_effective & t.mods;
        var preserve: ModMask = 0;
        for (t.entries) |e| {
            if (e.mods == active) {
                preserve = e.preserve;
                break;
            }
        }
        return t.mods & ~preserve;
    }

    /// Returns true if the modifier at index `idx` is consumed by the key's type.
    pub fn modIndexIsConsumed(self: *const State, kc: keymap_mod.Keycode, idx: u32) bool {
        if (idx >= 32) return false;
        return (self.keyGetConsumedMods(kc) & (@as(ModMask, 1) << @intCast(idx))) != 0;
    }
};

test "state updateMask + serialize" {
    const Ctx = @import("context.zig").Context;
    const io = std.testing.io;
    const ctx = try Ctx.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const src = "xkb_keymap { xkb_keycodes \"k\" { <AE01>=10; }; xkb_types \"t\" {}; xkb_compat \"c\" {}; xkb_symbols \"s\" { key <AE01> { [1] }; }; };";
    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();
    const st = try State.create(km);
    defer st.destroy();
    const changed = st.updateMask(0x1, 0, 0, 0, 0, 0);
    try std.testing.expect(changed.mods_effective);
    try std.testing.expectEqual(@as(ModMask, 0x1), st.serializeMods(.effective));
    _ = st.updateMask(0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(ModMask, 0), st.serializeMods(.effective));
}

test "state getLevel + keyGetLayout/Level/Syms/Utf8" {
    const Ctx = @import("context.zig").Context;
    const keysym_lib = @import("keysym.zig");
    const io = std.testing.io;
    const ctx = try Ctx.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { <AE01>=10; };
        \\  xkb_types "t" { type "TWO" { modifiers=Shift; map[Shift]=Level2; }; };
        \\  xkb_compat "c" {};
        \\  xkb_symbols "s" { key <AE01> { type="TWO", [ 1, exclam ] }; };
        \\};
    ;

    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    var two_idx: usize = 0;
    for (km.types, 0..) |t, i| {
        if (std.mem.eql(u8, ctx.atomText(t.name), "TWO")) {
            two_idx = i;
            break;
        }
    }

    // getLevel: no mods -> level 0; Shift (bit 0) -> level 1.
    try std.testing.expectEqual(@as(keymap_mod.LevelIndex, 0), getLevel(&km.types[two_idx], 0x0));
    try std.testing.expectEqual(@as(keymap_mod.LevelIndex, 1), getLevel(&km.types[two_idx], 0x1));

    const st = try State.create(km);
    defer st.destroy();

    // Default state (mod_effective=0): AE01 -> keysym '1'.
    try std.testing.expectEqual(keysym_lib.fromName("1", .{}).?, st.keyGetOneSym(10));
    try std.testing.expectEqual(@as(u21, '1'), st.keyGetUtf32(10));

    // With Shift active: level 1 -> keysym exclam.
    _ = st.updateMask(0x1, 0, 0, 0, 0, 0);
    const layout = st.keyGetLayout(10);
    try std.testing.expectEqual(@as(keymap_mod.LevelIndex, 1), st.keyGetLevel(10, layout));
    try std.testing.expectEqual(keysym_lib.fromName("exclam", .{}).?, st.keyGetOneSym(10));
    try std.testing.expectEqual(@as(u21, '!'), st.keyGetUtf32(10));

    var buf: [8]u8 = undefined;
    const utf8 = st.keyGetUtf8(10, &buf);
    try std.testing.expect(utf8 != null);
    try std.testing.expectEqualStrings("!", utf8.?);
}

const test_km_src =
    \\xkb_keymap {
    \\  xkb_keycodes "k" { minimum=8; maximum=255; <AE01>=10; <LFSH>=50; <RTSH>=62; <CAPS>=66; };
    \\  xkb_types "t" { type "TWO" { modifiers=Shift; map[Shift]=Level2; }; };
    \\  xkb_compat "c" { interpret Caps_Lock { action=LockMods(modifiers=Lock); }; };
    \\  xkb_symbols "s" {
    \\    key <AE01> { type="TWO", [ 1, exclam ] };
    \\    key <LFSH> { [ Shift_L ] };
    \\    key <RTSH> { [ Shift_R ] };
    \\    key <CAPS> { [ Caps_Lock ] };
    \\    modifier_map Shift { <LFSH>, <RTSH> };
    \\  };
    \\};
;

test "updateKey: shift via modmap changes level" {
    const Ctx = @import("context.zig").Context;
    const keysym_lib = @import("keysym.zig");
    const io = std.testing.io;
    const ctx = try Ctx.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const km = try Keymap.newFromString(ctx, test_km_src, .text_v1);
    defer km.destroy();
    const st = try State.create(km);
    defer st.destroy();

    // No mods: AE01 gives keysym '1'.
    try std.testing.expectEqual(keysym_lib.fromName("1", .{}).?, st.keyGetOneSym(10));

    // Press LFSH: modmap Shift contributes to mod_base.
    _ = try st.updateKey(50, .down);
    try std.testing.expect(st.mod_effective & 0x1 != 0);
    try std.testing.expectEqual(keysym_lib.fromName("exclam", .{}).?, st.keyGetOneSym(10));

    // Release LFSH: mod_base cleared, sym back to '1'.
    _ = try st.updateKey(50, .up);
    try std.testing.expectEqual(@as(ModMask, 0), st.mod_effective);
    try std.testing.expectEqual(keysym_lib.fromName("1", .{}).?, st.keyGetOneSym(10));
}

test "updateKey: capslock toggles mod_locked" {
    const Ctx = @import("context.zig").Context;
    const io = std.testing.io;
    const ctx = try Ctx.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const km = try Keymap.newFromString(ctx, test_km_src, .text_v1);
    defer km.destroy();
    const st = try State.create(km);
    defer st.destroy();

    // First press+release: Lock bit toggles on and stays after release.
    _ = try st.updateKey(66, .down);
    _ = try st.updateKey(66, .up);
    try std.testing.expect(st.mod_locked != 0);
    try std.testing.expect(st.mod_effective != 0);

    // Second press+release: Lock bit toggles off.
    _ = try st.updateKey(66, .down);
    _ = try st.updateKey(66, .up);
    try std.testing.expectEqual(@as(ModMask, 0), st.mod_locked);
    try std.testing.expectEqual(@as(ModMask, 0), st.mod_effective);
}

const test_km_src_with_led =
    \\xkb_keymap {
    \\  xkb_keycodes "k" { minimum=8; maximum=255; <AE01>=10; <LFSH>=50; <RTSH>=62; <CAPS>=66; };
    \\  xkb_types "t" { type "TWO" { modifiers=Shift; map[Shift]=Level2; }; };
    \\  xkb_compat "c" {
    \\    interpret Caps_Lock { action=LockMods(modifiers=Lock); };
    \\    indicator "Caps Lock" { modifiers=Lock; };
    \\  };
    \\  xkb_symbols "s" {
    \\    key <AE01> { type="TWO", [ 1, exclam ] };
    \\    key <LFSH> { [ Shift_L ] };
    \\    key <RTSH> { [ Shift_R ] };
    \\    key <CAPS> { [ Caps_Lock ] };
    \\    modifier_map Shift { <LFSH>, <RTSH> };
    \\  };
    \\};
;

test "queries: modNameIsActive, modIndexIsActive, layoutIndexIsActive" {
    const Ctx = @import("context.zig").Context;
    const io = std.testing.io;
    const ctx = try Ctx.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const km = try Keymap.newFromString(ctx, test_km_src, .text_v1);
    defer km.destroy();
    const st = try State.create(km);
    defer st.destroy();

    // Layout 0 is active before any key events.
    try std.testing.expect(st.layoutIndexIsActive(0, .effective));
    try std.testing.expect(!st.layoutIndexIsActive(1, .effective));

    // Hold Shift (LFSH = kc 50): Shift mod becomes active.
    _ = try st.updateKey(50, .down);
    try std.testing.expect(st.modNameIsActive("Shift", .effective));
    try std.testing.expect(!st.modNameIsActive("Control", .effective));
    try std.testing.expect(st.modIndexIsActive(0, .effective)); // index 0 = Shift mask 0x1
    try std.testing.expect(!st.modIndexIsActive(2, .effective)); // index 2 = Control mask 0x4

    // modNameIsActive on depressed component.
    try std.testing.expect(st.modNameIsActive("Shift", .depressed));
    try std.testing.expect(!st.modNameIsActive("Shift", .locked));

    _ = try st.updateKey(50, .up);
    try std.testing.expect(!st.modNameIsActive("Shift", .effective));
}

test "queries: ledNameIsActive + ledIndexIsActive for Caps Lock" {
    const Ctx = @import("context.zig").Context;
    const io = std.testing.io;
    const ctx = try Ctx.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const km = try Keymap.newFromString(ctx, test_km_src_with_led, .text_v1);
    defer km.destroy();
    const st = try State.create(km);
    defer st.destroy();

    // Before locking: LED is off.
    try std.testing.expect(!st.ledNameIsActive("Caps Lock"));

    // Press+release CAPS: Lock mod toggles on.
    _ = try st.updateKey(66, .down);
    _ = try st.updateKey(66, .up);
    try std.testing.expect(st.modNameIsActive("Lock", .locked));
    try std.testing.expect(st.modNameIsActive("Lock", .effective));
    try std.testing.expect(st.ledNameIsActive("Caps Lock"));

    try std.testing.expect(st.ledIndexIsActive(0));

    // Out-of-bounds LED index returns false.
    try std.testing.expect(!st.ledIndexIsActive(999));

    // Press+release CAPS again: Lock toggles off, LED off.
    _ = try st.updateKey(66, .down);
    _ = try st.updateKey(66, .up);
    try std.testing.expect(!st.ledNameIsActive("Caps Lock"));
    try std.testing.expect(!st.modNameIsActive("Lock", .effective));
}

test "consumed mods: keyGetConsumedMods + modIndexIsConsumed" {
    const Ctx = @import("context.zig").Context;
    const io = std.testing.io;
    const ctx = try Ctx.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" { <AE01>=10; };
        \\  xkb_types "t" { type "TWO_LEVEL" { modifiers=Shift; map[Shift]=Level2; }; };
        \\  xkb_compat "c" {};
        \\  xkb_symbols "s" { key <AE01> { type="TWO_LEVEL", [ 1, exclam ] }; };
        \\};
    ;
    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();
    const st = try State.create(km);
    defer st.destroy();

    // Activate Shift (bit 0 = mask 0x1).
    _ = st.updateMask(0x1, 0, 0, 0, 0, 0);

    // Shift (0x1) must be consumed; Control (0x4) must not be.
    const consumed = st.keyGetConsumedMods(10);
    try std.testing.expect(consumed & 0x1 != 0);
    try std.testing.expect(consumed & 0x4 == 0);

    // modIndexIsConsumed: index 0 = Shift, index 2 = Control.
    try std.testing.expect(st.modIndexIsConsumed(10, 0));
    try std.testing.expect(!st.modIndexIsConsumed(10, 2));

    // Out-of-bounds keycode returns 0 / false.
    try std.testing.expectEqual(@as(ModMask, 0), st.keyGetConsumedMods(9999));
    try std.testing.expect(!st.modIndexIsConsumed(9999, 0));
}

test "integration: full key session Shift+CapsLock+ALPHABETIC+Wayland mask" {
    const Ctx = @import("context.zig").Context;
    const keysym_lib = @import("keysym.zig");
    const io = std.testing.io;
    const ctx = try Ctx.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();

    const src =
        \\xkb_keymap {
        \\  xkb_keycodes "k" {
        \\    minimum=8; maximum=255;
        \\    <AE01>=10; <LFSH>=50; <CAPS>=66; <AC01>=38;
        \\  };
        \\  xkb_types "t" {};
        \\  xkb_compat "c" {
        \\    interpret Caps_Lock { action=LockMods(modifiers=Lock); };
        \\  };
        \\  xkb_symbols "s" {
        \\    key <AC01> { type="ALPHABETIC", [ a, A ] };
        \\    key <AE01> { type="TWO_LEVEL", [ 1, exclam ] };
        \\    key <LFSH> { [ Shift_L ] };
        \\    key <CAPS> { [ Caps_Lock ] };
        \\    modifier_map Shift { <LFSH> };
        \\  };
        \\};
    ;

    const km = try Keymap.newFromString(ctx, src, .text_v1);
    defer km.destroy();

    const st = try State.create(km);
    defer st.destroy();

    var buf: [8]u8 = undefined;

    // no mods: AC01 -> 'a'
    try std.testing.expectEqual(keysym_lib.fromName("a", .{}).?, st.keyGetOneSym(38));
    try std.testing.expectEqualStrings("a", st.keyGetUtf8(38, &buf).?);

    // hold Shift (LFSH=50): AC01 -> 'A'
    _ = try st.updateKey(50, .down);
    try std.testing.expect(st.mod_effective & 0x1 != 0);
    try std.testing.expectEqual(keysym_lib.fromName("A", .{}).?, st.keyGetOneSym(38));
    try std.testing.expectEqualStrings("A", st.keyGetUtf8(38, &buf).?);

    // Release Shift: AC01 back to 'a'
    _ = try st.updateKey(50, .up);
    try std.testing.expectEqual(@as(ModMask, 0), st.mod_effective);
    try std.testing.expectEqual(keysym_lib.fromName("a", .{}).?, st.keyGetOneSym(38));

    // press+release CapsLock: Lock mod locked
    _ = try st.updateKey(66, .down);
    _ = try st.updateKey(66, .up);
    try std.testing.expect(st.modNameIsActive("Lock", .locked));

    // AC01 with ALPHABETIC: Lock (0x2) in type mods (0x3) -> entry[1] -> level 1 -> 'A'
    try std.testing.expectEqual(keysym_lib.fromName("A", .{}).?, st.keyGetOneSym(38));
    try std.testing.expectEqualStrings("A", st.keyGetUtf8(38, &buf).?);

    // AE01 with TWO_LEVEL: Lock not in type mods (0x1 only) -> level 0 -> '1'
    try std.testing.expectEqual(keysym_lib.fromName("1", .{}).?, st.keyGetOneSym(10));

    // Press+release CapsLock again: unlocked
    _ = try st.updateKey(66, .down);
    _ = try st.updateKey(66, .up);
    try std.testing.expectEqual(@as(ModMask, 0), st.mod_effective);
    try std.testing.expectEqual(keysym_lib.fromName("a", .{}).?, st.keyGetOneSym(38));

    // Wayland client path: external Shift via updateMask
    _ = st.updateMask(0x1, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(keysym_lib.fromName("exclam", .{}).?, st.keyGetOneSym(10));
    try std.testing.expectEqual(@as(ModMask, 0x1), st.serializeMods(.effective));
}

test "updateKey: two shift keys ref-count via held map" {
    const Ctx = @import("context.zig").Context;
    const io = std.testing.io;
    const ctx = try Ctx.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const km = try Keymap.newFromString(ctx, test_km_src, .text_v1);
    defer km.destroy();
    const st = try State.create(km);
    defer st.destroy();

    // Press both Shift keys.
    _ = try st.updateKey(50, .down); // LFSH
    _ = try st.updateKey(62, .down); // RTSH
    try std.testing.expect(st.mod_effective & 0x1 != 0);

    // Release LFSH: RTSH still holds Shift.
    _ = try st.updateKey(50, .up);
    try std.testing.expect(st.mod_effective & 0x1 != 0);

    // Release RTSH: Shift clears.
    _ = try st.updateKey(62, .up);
    try std.testing.expectEqual(@as(ModMask, 0), st.mod_effective);
}

test "updateKey: Component.leds set on Caps Lock LED change" {
    const Ctx = @import("context.zig").Context;
    const io = std.testing.io;
    const ctx = try Ctx.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const km = try Keymap.newFromString(ctx, test_km_src_with_led, .text_v1);
    defer km.destroy();
    const st = try State.create(km);
    defer st.destroy();

    // LED starts off, st.leds == 0.
    try std.testing.expectEqual(@as(u32, 0), st.leds);
    try std.testing.expect(!st.ledIndexIsActive(0));

    // Press CAPS: LockMods toggles mod_locked on, LED activates.
    const c1 = try st.updateKey(66, .down);
    try std.testing.expect(c1.leds);
    try std.testing.expect(st.ledIndexIsActive(0));

    // Release CAPS: mod_locked stays set, LED unchanged.
    const c2 = try st.updateKey(66, .up);
    try std.testing.expect(!c2.leds);

    // Non-LED key (LFSH = kc 50): Shift does not affect Caps Lock LED.
    const c3 = try st.updateKey(50, .down);
    try std.testing.expect(!c3.leds);
    _ = try st.updateKey(50, .up);
}
