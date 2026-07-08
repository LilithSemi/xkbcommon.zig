/// compile_geometry.zig: compile a geometry section AST to keymap.Geometry IR.
const std = @import("std");
const keymap = @import("../keymap.zig");
const ast = @import("ast.zig");
const Context = @import("../context.zig").Context;
const Atom = @import("../context.zig").Atom;
const expr_eval = @import("expr_eval.zig");

pub const Geometry = keymap.Geometry;

/// Parse a [x, y] pair expression into a Point.
fn parsePoint(e: *const ast.Expr, ctx: *Context) ?Geometry.Point {
    switch (e.*) {
        .list => |items| {
            if (items.len < 2) return null;
            const xv = expr_eval.eval(&items[0], ctx) catch return null;
            const yv = expr_eval.eval(&items[1], ctx) catch return null;
            const x = switch (xv) {
                .int => |v| @as(i32, @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)))),
                else => return null,
            };
            const y = switch (yv) {
                .int => |v| @as(i32, @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)))),
                else => return null,
            };
            return .{ .x = x, .y = y };
        },
        else => return null,
    }
}

/// Compile a ShapeDef into a Geometry.Shape.
fn compileShape(
    arena: std.mem.Allocator,
    ctx: *Context,
    def: ast.ShapeDef,
) !?Geometry.Shape {
    const name = try ctx.intern(def.name);

    var outlines_list: std.ArrayListUnmanaged(Geometry.Outline) = .empty;

    for (def.outlines) |*outline_expr| {
        switch (outline_expr.*) {
            .list => |point_exprs| {
                var pts: std.ArrayListUnmanaged(Geometry.Point) = .empty;
                for (point_exprs) |*pe| {
                    if (parsePoint(pe, ctx)) |pt| {
                        try pts.append(arena, pt);
                    }
                }
                try outlines_list.append(arena, .{ .points = try pts.toOwnedSlice(arena) });
            },
            .assign => {
                // shape-level vardef (e.g. cornerRadius); not used in the IR.
            },
            else => {},
        }
    }

    return .{
        .name = name,
        .outlines = try outlines_list.toOwnedSlice(arena),
    };
}

/// Compile a KeysDef (list of key item exprs) into GeomKey entries.
fn compileKeysDef(
    arena: std.mem.Allocator,
    ctx: *Context,
    def: ast.KeysDef,
) ![]Geometry.GeomKey {
    var keys: std.ArrayListUnmanaged(Geometry.GeomKey) = .empty;
    for (def.body) |*item| {
        // Each item is expected to be a .list of assignments like { name=<AE01> }.
        switch (item.*) {
            .list => |assigns| {
                var key_name: Atom = .none;
                for (assigns) |*a| {
                    switch (a.*) {
                        .assign => |asn| {
                            const lname = switch (asn.lhs.*) {
                                .ident => |s| s,
                                else => continue,
                            };
                            if (std.ascii.eqlIgnoreCase(lname, "name")) {
                                switch (asn.rhs.*) {
                                    .keyname => |s| {
                                        key_name = try ctx.intern(s);
                                    },
                                    .ident => |s| {
                                        key_name = try ctx.intern(s);
                                    },
                                    .string => |s| {
                                        key_name = try ctx.intern(s);
                                    },
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }
                try keys.append(arena, .{ .name = key_name });
            },
            else => {},
        }
    }
    return keys.toOwnedSlice(arena);
}

/// Compile a RowDef into a Geometry.Row.
fn compileRow(
    arena: std.mem.Allocator,
    ctx: *Context,
    def: ast.RowDef,
) !Geometry.Row {
    var all_keys: std.ArrayListUnmanaged(Geometry.GeomKey) = .empty;
    for (def.body) |*decl| {
        switch (decl.*) {
            .keys => |kd| {
                const ks = try compileKeysDef(arena, ctx, kd);
                try all_keys.appendSlice(arena, ks);
            },
            else => {},
        }
    }
    return .{ .keys = try all_keys.toOwnedSlice(arena) };
}

/// Compile a GeomSectionDef into a Geometry.GeomSection.
fn compileSection(
    arena: std.mem.Allocator,
    ctx: *Context,
    def: ast.GeomSectionDef,
) !Geometry.GeomSection {
    const name = try ctx.intern(def.name);
    var rows: std.ArrayListUnmanaged(Geometry.Row) = .empty;
    for (def.body) |*decl| {
        switch (decl.*) {
            .row => |rd| {
                const row = try compileRow(arena, ctx, rd);
                try rows.append(arena, row);
            },
            else => {},
        }
    }
    return .{ .name = name, .rows = try rows.toOwnedSlice(arena) };
}

/// Compile a DoodadDef into a Geometry.Doodad.
fn compileDoodad(
    arena: std.mem.Allocator,
    ctx: *Context,
    def: ast.DoodadDef,
) !Geometry.Doodad {
    _ = arena;
    const name = try ctx.intern(def.name);
    const kind: Geometry.Doodad.Kind = switch (def.kind) {
        .solid => .solid,
        .text => .text,
        .outline => .outline,
        .logo => .logo,
        .indicator => .indicator,
    };
    return .{ .kind = kind, .name = name };
}

/// Compile a geometry Component into a Geometry IR.
pub fn compileGeometry(
    arena: std.mem.Allocator,
    ctx: *Context,
    comp: *ast.Component,
) !?Geometry {
    if (comp.decls.len == 0) return null;

    const geom_name: Atom = if (comp.name) |n| try ctx.intern(n) else .none;

    var width: i32 = 0;
    var height: i32 = 0;
    var shapes: std.ArrayListUnmanaged(Geometry.Shape) = .empty;
    var sections: std.ArrayListUnmanaged(Geometry.GeomSection) = .empty;
    var doodads: std.ArrayListUnmanaged(Geometry.Doodad) = .empty;

    for (comp.decls) |*decl| {
        switch (decl.*) {
            .var_def => |vd| {
                // Top-level vardef: look for width= and height=
                const fname = switch (vd.name.*) {
                    .ident => |s| s,
                    else => continue,
                };
                const val_expr = vd.value orelse continue;
                const val = expr_eval.eval(val_expr, ctx) catch continue;
                const ival = switch (val) {
                    .int => |v| @as(i32, @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)))),
                    else => continue,
                };
                if (std.ascii.eqlIgnoreCase(fname, "width")) {
                    width = ival;
                } else if (std.ascii.eqlIgnoreCase(fname, "height")) {
                    height = ival;
                }
            },
            .shape => |sd| {
                if (try compileShape(arena, ctx, sd)) |s| {
                    try shapes.append(arena, s);
                }
            },
            .geom_section => |gsd| {
                const sec = try compileSection(arena, ctx, gsd);
                try sections.append(arena, sec);
            },
            .doodad => |dd| {
                const d = try compileDoodad(arena, ctx, dd);
                try doodads.append(arena, d);
            },
            else => {},
        }
    }

    return Geometry{
        .name = geom_name,
        .width_mm = width,
        .height_mm = height,
        .shapes = try shapes.toOwnedSlice(arena),
        .sections = try sections.toOwnedSlice(arena),
        .doodads = try doodads.toOwnedSlice(arena),
    };
}

test "compileGeometry: basic shape and section" {
    const io = std.testing.io;
    const ctx = try Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;

    const src =
        \\xkb_geometry "g" {
        \\  width=470; height=460;
        \\  shape "KEYCAP" { { [16,16], [2,2] } };
        \\  section "main" { row { keys { { name=<AE01> } }; }; };
        \\  solid "GreyStuff" { };
        \\};
    ;

    var lx = Lexer.init(std.testing.allocator, src);
    defer lx.deinit();
    var p = Parser.init(std.testing.allocator, &lx);
    defer p.deinit();
    const xf = try p.parseFile();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var geom_comp: ?*ast.Component = null;
    for (xf.components) |*comp| {
        if (comp.kind == .geometry) {
            geom_comp = comp;
            break;
        }
    }
    const gc = geom_comp orelse return error.NoGeomComp;

    const geom = (try compileGeometry(arena.allocator(), ctx, gc)) orelse return error.NullGeom;

    try std.testing.expectEqualStrings("g", ctx.atomText(geom.name));
    try std.testing.expectEqual(@as(i32, 470), geom.width_mm);
    try std.testing.expectEqual(@as(i32, 460), geom.height_mm);
    try std.testing.expectEqual(@as(usize, 1), geom.shapes.len);
    try std.testing.expectEqualStrings("KEYCAP", ctx.atomText(geom.shapes[0].name));
    try std.testing.expectEqual(@as(usize, 1), geom.shapes[0].outlines.len);
    try std.testing.expectEqual(@as(usize, 2), geom.shapes[0].outlines[0].points.len);
    try std.testing.expectEqual(@as(usize, 1), geom.sections.len);
    try std.testing.expectEqualStrings("main", ctx.atomText(geom.sections[0].name));
    try std.testing.expectEqual(@as(usize, 1), geom.sections[0].rows.len);
    try std.testing.expectEqual(@as(usize, 1), geom.sections[0].rows[0].keys.len);
    try std.testing.expectEqualStrings("AE01", ctx.atomText(geom.sections[0].rows[0].keys[0].name));
    try std.testing.expectEqual(@as(usize, 1), geom.doodads.len);
    try std.testing.expectEqualStrings("GreyStuff", ctx.atomText(geom.doodads[0].name));
    try std.testing.expect(geom.doodads[0].kind == .solid);
}
