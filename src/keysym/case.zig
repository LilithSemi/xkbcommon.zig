const Keysym = @import("../keysym.zig").Keysym;

const Cased = struct { lower: u32, upper: u32 };

fn convert(v: u32) Cased {
    // Latin-1 uppercase A-Z
    if (v >= 0x41 and v <= 0x5a) return .{ .lower = v + 0x20, .upper = v };
    // Latin-1 lowercase a-z
    if (v >= 0x61 and v <= 0x7a) return .{ .lower = v, .upper = v - 0x20 };
    // Latin-1 extended uppercase (excludes 0xd7 multiply sign)
    if (v >= 0xc0 and v <= 0xd6) return .{ .lower = v + 0x20, .upper = v };
    if (v >= 0xd8 and v <= 0xde) return .{ .lower = v + 0x20, .upper = v };
    // Latin-1 extended lowercase (excludes 0xf7 division sign)
    if (v >= 0xe0 and v <= 0xf6) return .{ .lower = v, .upper = v - 0x20 };
    if (v >= 0xf8 and v <= 0xfe) return .{ .lower = v, .upper = v - 0x20 };

    // Latin-2/3/4 individual pairs (ported from XConvertCase)
    switch (v) {
        // Latin-2 block A: upper 0x1aX <-> lower 0x1bX (offset +0x10)
        0x1a1 => return .{ .lower = 0x1b1, .upper = v }, // Aogonek
        0x1a3 => return .{ .lower = 0x1b3, .upper = v }, // Lstroke
        0x1a5 => return .{ .lower = 0x1b5, .upper = v }, // Lcaron
        0x1a6 => return .{ .lower = 0x1b6, .upper = v }, // Sacute
        0x1a9 => return .{ .lower = 0x1b9, .upper = v }, // Scaron
        0x1aa => return .{ .lower = 0x1ba, .upper = v }, // Scedilla
        0x1ab => return .{ .lower = 0x1bb, .upper = v }, // Tcaron
        0x1ac => return .{ .lower = 0x1bc, .upper = v }, // Zacute
        0x1ae => return .{ .lower = 0x1be, .upper = v }, // Zcaron
        0x1af => return .{ .lower = 0x1bf, .upper = v }, // Zabovedot
        0x1b1 => return .{ .lower = v, .upper = 0x1a1 }, // aogonek
        0x1b3 => return .{ .lower = v, .upper = 0x1a3 }, // lstroke
        0x1b5 => return .{ .lower = v, .upper = 0x1a5 }, // lcaron
        0x1b6 => return .{ .lower = v, .upper = 0x1a6 }, // sacute
        0x1b9 => return .{ .lower = v, .upper = 0x1a9 }, // scaron
        0x1ba => return .{ .lower = v, .upper = 0x1aa }, // scedilla
        0x1bb => return .{ .lower = v, .upper = 0x1ab }, // tcaron
        0x1bc => return .{ .lower = v, .upper = 0x1ac }, // zacute
        0x1be => return .{ .lower = v, .upper = 0x1ae }, // zcaron
        0x1bf => return .{ .lower = v, .upper = 0x1af }, // zabovedot
        // Latin-2 block B: upper 0x1cX/0x1dX <-> lower 0x1eX/0x1fX (offset +0x20)
        0x1c0 => return .{ .lower = 0x1e0, .upper = v }, // Racute
        0x1c3 => return .{ .lower = 0x1e3, .upper = v }, // Abreve
        0x1c5 => return .{ .lower = 0x1e5, .upper = v }, // Lacute
        0x1c6 => return .{ .lower = 0x1e6, .upper = v }, // Cacute
        0x1c8 => return .{ .lower = 0x1e8, .upper = v }, // Ccaron
        0x1ca => return .{ .lower = 0x1ea, .upper = v }, // Eogonek
        0x1cc => return .{ .lower = 0x1ec, .upper = v }, // Ecaron
        0x1cf => return .{ .lower = 0x1ef, .upper = v }, // Dcaron
        0x1d0 => return .{ .lower = 0x1f0, .upper = v }, // Dstroke
        0x1d1 => return .{ .lower = 0x1f1, .upper = v }, // Nacute
        0x1d2 => return .{ .lower = 0x1f2, .upper = v }, // Ncaron
        0x1d5 => return .{ .lower = 0x1f5, .upper = v }, // Odoubleacute
        0x1d8 => return .{ .lower = 0x1f8, .upper = v }, // Rcaron
        0x1d9 => return .{ .lower = 0x1f9, .upper = v }, // Uring
        0x1db => return .{ .lower = 0x1fb, .upper = v }, // Udoubleacute
        0x1de => return .{ .lower = 0x1fe, .upper = v }, // Tcedilla
        0x1e0 => return .{ .lower = v, .upper = 0x1c0 }, // racute
        0x1e3 => return .{ .lower = v, .upper = 0x1c3 }, // abreve
        0x1e5 => return .{ .lower = v, .upper = 0x1c5 }, // lacute
        0x1e6 => return .{ .lower = v, .upper = 0x1c6 }, // cacute
        0x1e8 => return .{ .lower = v, .upper = 0x1c8 }, // ccaron
        0x1ea => return .{ .lower = v, .upper = 0x1ca }, // eogonek
        0x1ec => return .{ .lower = v, .upper = 0x1cc }, // ecaron
        0x1ef => return .{ .lower = v, .upper = 0x1cf }, // dcaron
        0x1f0 => return .{ .lower = v, .upper = 0x1d0 }, // dstroke
        0x1f1 => return .{ .lower = v, .upper = 0x1d1 }, // nacute
        0x1f2 => return .{ .lower = v, .upper = 0x1d2 }, // ncaron
        0x1f5 => return .{ .lower = v, .upper = 0x1d5 }, // odoubleacute
        0x1f8 => return .{ .lower = v, .upper = 0x1d8 }, // rcaron
        0x1f9 => return .{ .lower = v, .upper = 0x1d9 }, // uring
        0x1fb => return .{ .lower = v, .upper = 0x1db }, // udoubleacute
        0x1fe => return .{ .lower = v, .upper = 0x1de }, // tcedilla
        // Latin-3 block A: upper 0x2aX <-> lower 0x2bX (offset +0x10)
        0x2a1 => return .{ .lower = 0x2b1, .upper = v }, // Hstroke
        0x2a6 => return .{ .lower = 0x2b6, .upper = v }, // Hcircumflex
        0x2a9 => return .{ .lower = 0x2b9, .upper = v }, // Iabovedot -> idotless
        0x2ab => return .{ .lower = 0x2bb, .upper = v }, // Gbreve
        0x2ac => return .{ .lower = 0x2bc, .upper = v }, // Jcircumflex
        0x2b1 => return .{ .lower = v, .upper = 0x2a1 }, // hstroke
        0x2b6 => return .{ .lower = v, .upper = 0x2a6 }, // hcircumflex
        0x2b9 => return .{ .lower = v, .upper = 0x2a9 }, // idotless -> Iabovedot
        0x2bb => return .{ .lower = v, .upper = 0x2ab }, // gbreve
        0x2bc => return .{ .lower = v, .upper = 0x2ac }, // jcircumflex
        // Latin-3 block B: upper 0x2cX/0x2dX <-> lower 0x2eX/0x2fX (offset +0x20)
        0x2c5 => return .{ .lower = 0x2e5, .upper = v }, // Cabovedot
        0x2c6 => return .{ .lower = 0x2e6, .upper = v }, // Ccircumflex
        0x2d5 => return .{ .lower = 0x2f5, .upper = v }, // Gabovedot
        0x2d8 => return .{ .lower = 0x2f8, .upper = v }, // Gcircumflex
        0x2dd => return .{ .lower = 0x2fd, .upper = v }, // Ubreve
        0x2de => return .{ .lower = 0x2fe, .upper = v }, // Scircumflex
        0x2e5 => return .{ .lower = v, .upper = 0x2c5 }, // cabovedot
        0x2e6 => return .{ .lower = v, .upper = 0x2c6 }, // ccircumflex
        0x2f5 => return .{ .lower = v, .upper = 0x2d5 }, // gabovedot
        0x2f8 => return .{ .lower = v, .upper = 0x2d8 }, // gcircumflex
        0x2fd => return .{ .lower = v, .upper = 0x2dd }, // ubreve
        0x2fe => return .{ .lower = v, .upper = 0x2de }, // scircumflex
        // Latin-4 block A: upper 0x3aX <-> lower 0x3bX (offset +0x10)
        0x3a3 => return .{ .lower = 0x3b3, .upper = v }, // Rcedilla
        0x3a5 => return .{ .lower = 0x3b5, .upper = v }, // Itilde
        0x3a6 => return .{ .lower = 0x3b6, .upper = v }, // Lcedilla
        0x3aa => return .{ .lower = 0x3ba, .upper = v }, // Emacron
        0x3ab => return .{ .lower = 0x3bb, .upper = v }, // Gcedilla
        0x3ac => return .{ .lower = 0x3bc, .upper = v }, // Tslash
        0x3b3 => return .{ .lower = v, .upper = 0x3a3 }, // rcedilla
        0x3b5 => return .{ .lower = v, .upper = 0x3a5 }, // itilde
        0x3b6 => return .{ .lower = v, .upper = 0x3a6 }, // lcedilla
        0x3ba => return .{ .lower = v, .upper = 0x3aa }, // emacron
        0x3bb => return .{ .lower = v, .upper = 0x3ab }, // gcedilla
        0x3bc => return .{ .lower = v, .upper = 0x3ac }, // tslash
        // ENG is irregular: 0x3bd <-> 0x3bf (offset +0x02)
        0x3bd => return .{ .lower = 0x3bf, .upper = v }, // ENG
        0x3bf => return .{ .lower = v, .upper = 0x3bd }, // eng
        // Latin-4 block B: upper 0x3cX/0x3dX <-> lower 0x3eX/0x3fX (offset +0x20)
        0x3c0 => return .{ .lower = 0x3e0, .upper = v }, // Amacron
        0x3c7 => return .{ .lower = 0x3e7, .upper = v }, // Iogonek
        0x3cc => return .{ .lower = 0x3ec, .upper = v }, // Eabovedot
        0x3cf => return .{ .lower = 0x3ef, .upper = v }, // Imacron
        0x3d1 => return .{ .lower = 0x3f1, .upper = v }, // Ncedilla
        0x3d2 => return .{ .lower = 0x3f2, .upper = v }, // Omacron
        0x3d3 => return .{ .lower = 0x3f3, .upper = v }, // Kcedilla
        0x3d9 => return .{ .lower = 0x3f9, .upper = v }, // Uogonek
        0x3dd => return .{ .lower = 0x3fd, .upper = v }, // Utilde
        0x3de => return .{ .lower = 0x3fe, .upper = v }, // Umacron
        0x3e0 => return .{ .lower = v, .upper = 0x3c0 }, // amacron
        0x3e7 => return .{ .lower = v, .upper = 0x3c7 }, // iogonek
        0x3ec => return .{ .lower = v, .upper = 0x3cc }, // eabovedot
        0x3ef => return .{ .lower = v, .upper = 0x3cf }, // imacron
        0x3f1 => return .{ .lower = v, .upper = 0x3d1 }, // ncedilla
        0x3f2 => return .{ .lower = v, .upper = 0x3d2 }, // omacron
        0x3f3 => return .{ .lower = v, .upper = 0x3d3 }, // kcedilla
        0x3f9 => return .{ .lower = v, .upper = 0x3d9 }, // uogonek
        0x3fd => return .{ .lower = v, .upper = 0x3dd }, // utilde
        0x3fe => return .{ .lower = v, .upper = 0x3de }, // umacron
        else => {},
    }

    // Cyrillic (page 6): range-based rules from XConvertCase
    // Serbian/Macedonian lowercase 0x6a1..0x6af <-> uppercase 0x6b1..0x6bf (offset +0x10)
    if (v >= 0x6a1 and v <= 0x6af) return .{ .lower = v, .upper = v + 0x10 };
    if (v >= 0x6b1 and v <= 0x6bf) return .{ .lower = v - 0x10, .upper = v };
    // Standard Cyrillic lowercase 0x6c0..0x6df <-> uppercase 0x6e0..0x6ff (offset +0x20)
    if (v >= 0x6c0 and v <= 0x6df) return .{ .lower = v, .upper = v + 0x20 };
    if (v >= 0x6e0 and v <= 0x6ff) return .{ .lower = v - 0x20, .upper = v };

    // Greek (page 7): range-based rules from XConvertCase
    // Accented uppercase 0x7a1..0x7ab <-> accented lowercase 0x7b1..0x7bb (offset +0x10)
    if (v >= 0x7a1 and v <= 0x7ab) return .{ .lower = v + 0x10, .upper = v };
    // Exclude iotaaccentdieresis (0x7b6) and upsilonaccentdieresis (0x7ba), which have no uppercase pair.
    if (v >= 0x7b1 and v <= 0x7bb and v != 0x7b6 and v != 0x7ba)
        return .{ .lower = v, .upper = v - 0x10 };
    // Plain uppercase 0x7c1..0x7d9 <-> plain lowercase 0x7e1..0x7f9 (offset +0x20)
    if (v >= 0x7c1 and v <= 0x7d9) return .{ .lower = v + 0x20, .upper = v };
    // Exclude finalsmallsigma (0x7f3), which has no uppercase pair.
    if (v >= 0x7e1 and v <= 0x7f9 and v != 0x7f3) return .{ .lower = v, .upper = v - 0x20 };

    return .{ .lower = v, .upper = v };
}

pub fn toLower(ks: Keysym) Keysym {
    return @enumFromInt(convert(@intFromEnum(ks)).lower);
}

pub fn toUpper(ks: Keysym) Keysym {
    return @enumFromInt(convert(@intFromEnum(ks)).upper);
}

const std = @import("std");
const k = @import("../keysym.zig");

test "ascii case" {
    try std.testing.expectEqual(@as(u32, 0x0061), @intFromEnum(k.toLower(@enumFromInt(0x0041)))); // A->a
    try std.testing.expectEqual(@as(u32, 0x0041), @intFromEnum(k.toUpper(@enumFromInt(0x0061)))); // a->A
}

test "latin1 accented" {
    try std.testing.expectEqual(@as(u32, 0x00e9), @intFromEnum(k.toLower(@enumFromInt(0x00c9)))); // Eacute->eacute
    try std.testing.expectEqual(@as(u32, 0x00c9), @intFromEnum(k.toUpper(@enumFromInt(0x00e9))));
}

test "no case pair unchanged" {
    try std.testing.expectEqual(@as(u32, 0xff0d), @intFromEnum(k.toUpper(@enumFromInt(0xff0d)))); // Return
    try std.testing.expectEqual(@as(u32, 0x00d7), @intFromEnum(k.toLower(@enumFromInt(0x00d7)))); // multiply sign
}

test "latin2 case" {
    // Aogonek (0x1a1) <-> aogonek (0x1b1)
    try std.testing.expectEqual(@as(u32, 0x1b1), @intFromEnum(k.toLower(@enumFromInt(0x1a1))));
    try std.testing.expectEqual(@as(u32, 0x1a1), @intFromEnum(k.toUpper(@enumFromInt(0x1b1))));
    // breve (0x1a2) has no case pair
    try std.testing.expectEqual(@as(u32, 0x1a2), @intFromEnum(k.toLower(@enumFromInt(0x1a2))));
    try std.testing.expectEqual(@as(u32, 0x1a2), @intFromEnum(k.toUpper(@enumFromInt(0x1a2))));
    // Racute (0x1c0) <-> racute (0x1e0)
    try std.testing.expectEqual(@as(u32, 0x1e0), @intFromEnum(k.toLower(@enumFromInt(0x1c0))));
    try std.testing.expectEqual(@as(u32, 0x1c0), @intFromEnum(k.toUpper(@enumFromInt(0x1e0))));
}

test "cyrillic case" {
    // Cyrillic_A (0x6e1) <-> Cyrillic_a (0x6c1)
    try std.testing.expectEqual(@as(u32, 0x6c1), @intFromEnum(k.toLower(@enumFromInt(0x6e1))));
    try std.testing.expectEqual(@as(u32, 0x6e1), @intFromEnum(k.toUpper(@enumFromInt(0x6c1))));
    // Serbian_DJE (0x6b1) <-> Serbian_dje (0x6a1)
    try std.testing.expectEqual(@as(u32, 0x6a1), @intFromEnum(k.toLower(@enumFromInt(0x6b1))));
    try std.testing.expectEqual(@as(u32, 0x6b1), @intFromEnum(k.toUpper(@enumFromInt(0x6a1))));
    // numerosign (0x6b0) has no case pair
    try std.testing.expectEqual(@as(u32, 0x6b0), @intFromEnum(k.toLower(@enumFromInt(0x6b0))));
}

test "greek case" {
    // Greek_ALPHA (0x7c1) <-> Greek_alpha (0x7e1)
    try std.testing.expectEqual(@as(u32, 0x7e1), @intFromEnum(k.toLower(@enumFromInt(0x7c1))));
    try std.testing.expectEqual(@as(u32, 0x7c1), @intFromEnum(k.toUpper(@enumFromInt(0x7e1))));
    // Greek_ALPHAaccent (0x7a1) <-> Greek_alphaaccent (0x7b1)
    try std.testing.expectEqual(@as(u32, 0x7b1), @intFromEnum(k.toLower(@enumFromInt(0x7a1))));
    try std.testing.expectEqual(@as(u32, 0x7a1), @intFromEnum(k.toUpper(@enumFromInt(0x7b1))));
    // Greek_finalsmallsigma (0x7f3) has no uppercase pair
    try std.testing.expectEqual(@as(u32, 0x7f3), @intFromEnum(k.toUpper(@enumFromInt(0x7f3))));
    // Greek_iotaaccentdieresis (0x7b6) has no uppercase pair
    try std.testing.expectEqual(@as(u32, 0x7b6), @intFromEnum(k.toUpper(@enumFromInt(0x7b6))));
}
