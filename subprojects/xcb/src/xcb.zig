pub const display = @import("display.zig");
pub const proto = @import("proto.zig");
pub const xauth = @import("xauth.zig");
pub const conn = @import("conn.zig");
pub const ext = @import("ext.zig");
pub const xkb = @import("xkb.zig");
pub const xkb_map = @import("xkb_map.zig");
pub const xkb_controls = @import("xkb_controls.zig");
pub const xkb_names = @import("xkb_names.zig");
pub const xkb_compat = @import("xkb_compat.zig");

test {
    _ = display;
    _ = proto;
    _ = xauth;
    _ = conn;
    _ = ext;
    _ = xkb;
    _ = xkb_map;
    _ = xkb_controls;
    _ = xkb_names;
    _ = xkb_compat;
}
