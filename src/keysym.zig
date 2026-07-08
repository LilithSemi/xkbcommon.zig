const std = @import("std");
pub const tables = @import("keysym_tables");
pub const keys = tables.keys;
const unicode = @import("keysym/unicode.zig");
const names = @import("keysym/names.zig");

pub const NameOpts = names.NameOpts;
pub fn fromName(name: []const u8, opts: NameOpts) ?Keysym {
    return names.fromName(name, opts);
}
pub fn getName(ks: Keysym, buf: []u8) error{NoSpace}![]const u8 {
    return names.getName(ks, buf);
}

pub fn toLower(ks: Keysym) Keysym {
    return @import("keysym/case.zig").toLower(ks);
}

pub fn toUpper(ks: Keysym) Keysym {
    return @import("keysym/case.zig").toUpper(ks);
}

pub const Keysym = enum(u32) {
    no_symbol = 0,
    _,

    pub fn toUtf32(ks: Keysym) u21 {
        return unicode.toUtf32(ks);
    }

    pub fn fromUtf32(cp: u21) Keysym {
        return unicode.fromUtf32(cp);
    }

    pub fn toUtf8(ks: Keysym, buf: []u8) ?[]const u8 {
        return unicode.toUtf8(ks, buf);
    }

    pub fn getName(ks: Keysym, buf: []u8) error{NoSpace}![]const u8 {
        return names.getName(ks, buf);
    }

    pub fn toLower(ks: Keysym) Keysym {
        return @import("keysym/case.zig").toLower(ks);
    }

    pub fn toUpper(ks: Keysym) Keysym {
        return @import("keysym/case.zig").toUpper(ks);
    }

    pub fn fromName(name: []const u8, opts: NameOpts) ?Keysym {
        return names.fromName(name, opts);
    }
};
