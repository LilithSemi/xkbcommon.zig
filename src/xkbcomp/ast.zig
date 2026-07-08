const std = @import("std");

pub const XkbFile = struct { components: []Component };

pub const Component = struct {
    kind: Kind,
    flags: Flags,
    name: ?[]const u8,
    decls: []Decl = &.{},
    children: []Component = &.{},

    pub const Kind = enum { keymap, keycodes, types, compat, symbols, geometry };
};

pub const Flags = struct {
    partial: bool = false,
    default: bool = false,
    hidden: bool = false,
    alphanumeric_keys: bool = false,
    modifier_keys: bool = false,
    keypad_keys: bool = false,
    function_keys: bool = false,
    alternate_group: bool = false,
};

pub const MergeMode = enum { default, augment, override, replace };

pub const Op = enum { add, sub, mul, div, negate, not, invert, unary_plus };

pub const Expr = union(enum) {
    ident: []const u8,
    field_ref: []const u8,
    string: []const u8,
    integer: i64,
    float: f64,
    keyname: []const u8,
    boolean: bool,
    unary: struct { op: Op, rhs: *Expr },
    binary: struct { op: Op, lhs: *Expr, rhs: *Expr },
    array_ref: struct { base: *Expr, index: ?*Expr },
    dot: struct { lhs: *Expr, field: []const u8 },
    action: struct { name: []const u8, args: []Expr },
    arg: struct { name: ?[]const u8, value: *Expr },
    assign: struct { lhs: *Expr, rhs: *Expr },
    list: []Expr,
};

pub const VarDef = struct { merge: MergeMode = .default, name: *Expr, value: ?*Expr };
pub const KeycodeDef = struct { name: []const u8, value: *Expr };
pub const KeyAlias = struct { alias: []const u8, real: []const u8 };
pub const VModDef = struct { names: [][]const u8, values: []?*Expr };
pub const KeyTypeDef = struct { merge: MergeMode = .default, name: []const u8, body: []VarDef };
pub const KeyDef = struct { merge: MergeMode = .default, name: []const u8, body: []Expr };
pub const InterpDef = struct { merge: MergeMode = .default, sym: []const u8, match: ?*Expr, body: []VarDef };
pub const IndicatorMapDef = struct { name: []const u8, body: []VarDef };
pub const IndicatorNameDef = struct { ndx: *Expr, name: *Expr, virtual: bool };
pub const ModMapDef = struct { modifier: []const u8, keys: []Expr };
pub const GroupCompatDef = struct { group: *Expr, value: *Expr };
pub const IncludeStmt = struct { merge: MergeMode = .default, path: []const u8 };

pub const DoodadKind = enum { solid, text, outline, logo, indicator };
pub const ShapeDef = struct { name: []const u8, outlines: []Expr };
pub const GeomSectionDef = struct { name: []const u8, body: []Decl };
pub const DoodadDef = struct { kind: DoodadKind, name: []const u8, body: []VarDef };
pub const RowDef = struct { body: []Decl };
pub const OutlineDef = struct { body: []Expr = &.{} };
pub const OverlayDef = struct { name: []const u8, body: []VarDef };
pub const KeysDef = struct { body: []Expr };

pub const Decl = union(enum) {
    var_def: VarDef,
    keycode: KeycodeDef,
    key_alias: KeyAlias,
    vmods: VModDef,
    key_type: KeyTypeDef,
    key: KeyDef,
    interp: InterpDef,
    indicator_map: IndicatorMapDef,
    indicator_name: IndicatorNameDef,
    mod_map: ModMapDef,
    group_compat: GroupCompatDef,
    include: IncludeStmt,
    shape: ShapeDef,
    geom_section: GeomSectionDef,
    doodad: DoodadDef,
    row: RowDef,
    outline: OutlineDef,
    overlay: OverlayDef,
    keys: KeysDef,
    text_doodad: void,
    solid_doodad: void,
};

test "ast: construct Decl and Expr values" {
    const d: Decl = .{ .include = .{ .path = "base" } };
    try std.testing.expectEqualStrings("base", d.include.path);

    const e: Expr = .{ .integer = 42 };
    try std.testing.expectEqual(@as(i64, 42), e.integer);

    const e2: Expr = .{ .boolean = true };
    try std.testing.expect(e2.boolean);
}
