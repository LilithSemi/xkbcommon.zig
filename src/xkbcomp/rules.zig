/// rules.zig: XKB rules file parser and resolver.
///
/// `parseRules` borrows all pattern-literal and rhs slices directly from the
/// caller-supplied `text` string.  The caller MUST ensure `text` outlives the
/// returned slice.  The outer slice and nested arrays are allocated with `alloc`.
const std = @import("std");
const Context = @import("../context.zig").Context;

pub const RuleNames = struct {
    rules: ?[]const u8 = null,
    model: ?[]const u8 = null,
    layout: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    options: ?[]const u8 = null,
};

pub const KcCGST = struct {
    keycodes: []u8,
    types: []u8,
    compat: []u8,
    symbols: []u8,
    geometry: []u8,
};

pub const Field = enum { model, layout, variant, option };

pub const Component = enum { keycodes, symbols, types, compat, geometry };

pub const Pattern = union(enum) {
    wildcard,
    literal: []const u8,
    /// $varname: matches if the field value is a member of the named variable set.
    group: []const u8,
};

pub const MappingLine = struct {
    patterns: []Pattern,
    rhs: []const u8,
};

pub const RuleGroup = struct {
    fields: []Field,
    component: Component,
    lines: []MappingLine,
    /// null = non-indexed group; N (1-based) = apply to layout/variant index N.
    layout_index: ?usize = null,
};

const VarGroupMap = std.StringHashMapUnmanaged([]const []const u8);

fn freeVarGroupMap(alloc: std.mem.Allocator, vg: *VarGroupMap) void {
    var it = vg.iterator();
    while (it.next()) |entry| alloc.free(entry.value_ptr.*);
    vg.deinit(alloc);
}

// Trim helpers (std.mem.trimLeft/trimRight are gone in 0.16)

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r')) : (i += 1) {}
    return s[i..];
}

fn trimRight(s: []const u8) []const u8 {
    var i: usize = s.len;
    while (i > 0 and (s[i - 1] == ' ' or s[i - 1] == '\t' or s[i - 1] == '\r')) : (i -= 1) {}
    return s[0..i];
}

fn trim(s: []const u8) []const u8 {
    return trimLeft(trimRight(s));
}

fn parseField(tok: []const u8) ?Field {
    if (std.mem.indexOfScalar(u8, tok, '[') != null) return null;
    if (std.mem.eql(u8, tok, "model")) return .model;
    if (std.mem.eql(u8, tok, "layout")) return .layout;
    if (std.mem.eql(u8, tok, "variant")) return .variant;
    if (std.mem.eql(u8, tok, "option")) return .option;
    return null;
}

/// Parse an optionally-indexed field token such as "layout[1]" or "layout".
/// Returns the base Field (null if unknown) and the 1-based index (null if non-indexed
/// or if the index label is "none"/"later", which means skip this group).
const IndexedField = struct { field: ?Field, index: ?usize };

fn parseFieldIndexed(tok: []const u8) IndexedField {
    const bracket = std.mem.indexOfScalar(u8, tok, '[') orelse
        return .{ .field = parseField(tok), .index = null };

    const base = tok[0..bracket];
    const rest = tok[bracket + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, ']') orelse
        return .{ .field = null, .index = null };
    const idx_str = rest[0..close];

    const field: Field = if (std.mem.eql(u8, base, "model"))
        .model
    else if (std.mem.eql(u8, base, "layout"))
        .layout
    else if (std.mem.eql(u8, base, "variant"))
        .variant
    else if (std.mem.eql(u8, base, "option"))
        .option
    else
        return .{ .field = null, .index = null };

    if (std.mem.eql(u8, idx_str, "none") or std.mem.eql(u8, idx_str, "later"))
        return .{ .field = field, .index = null }; // signals: skip group
    if (std.mem.eql(u8, idx_str, "first"))
        return .{ .field = field, .index = 1 };

    const n = std.fmt.parseInt(usize, idx_str, 10) catch
        return .{ .field = null, .index = null };
    if (n == 0) return .{ .field = null, .index = null };
    return .{ .field = field, .index = n };
}

fn parseComponent(tok: []const u8) ?Component {
    if (std.mem.eql(u8, tok, "keycodes")) return .keycodes;
    if (std.mem.eql(u8, tok, "symbols")) return .symbols;
    if (std.mem.eql(u8, tok, "types")) return .types;
    if (std.mem.eql(u8, tok, "compat")) return .compat;
    if (std.mem.eql(u8, tok, "geometry")) return .geometry;
    return null;
}

fn parseRulesInternal(
    alloc: std.mem.Allocator,
    text: []const u8,
    var_groups_out: *VarGroupMap,
) ![]RuleGroup {
    var groups: std.ArrayListUnmanaged(RuleGroup) = .empty;
    errdefer {
        for (groups.items) |*g| freeGroup(alloc, g);
        groups.deinit(alloc);
    }

    var cur_fields: std.ArrayListUnmanaged(Field) = .empty;
    var cur_component: ?Component = null;
    var cur_lines: std.ArrayListUnmanaged(MappingLine) = .empty;
    var cur_layout_index: ?usize = null;
    var skip_group: bool = false;

    errdefer {
        cur_fields.deinit(alloc);
        for (cur_lines.items) |*ln| alloc.free(ln.patterns);
        cur_lines.deinit(alloc);
    }

    var line_iter = std.mem.tokenizeScalar(u8, text, '\n');
    while (line_iter.next()) |raw_line| {
        const line = trim(raw_line);
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;

        if (std.mem.startsWith(u8, line, "!")) {
            if (cur_component != null) {
                const owned_fields = try cur_fields.toOwnedSlice(alloc);
                errdefer alloc.free(owned_fields);
                const owned_lines = try cur_lines.toOwnedSlice(alloc);
                errdefer {
                    for (owned_lines) |*ln| alloc.free(ln.patterns);
                    alloc.free(owned_lines);
                }
                try groups.append(alloc, RuleGroup{
                    .fields = owned_fields,
                    .component = cur_component.?,
                    .lines = owned_lines,
                    .layout_index = cur_layout_index,
                });
                cur_fields = .empty;
                cur_lines = .empty;
                cur_component = null;
                cur_layout_index = null;
            }
            skip_group = false;

            const body = trim(line[1..]);

            // Variable group: `! $name = v1 v2 ...`
            if (std.mem.startsWith(u8, body, "$")) {
                const eq_idx = std.mem.indexOfScalar(u8, body, '=') orelse continue;
                const name = trim(body[1..eq_idx]);
                if (name.len == 0) continue;
                const vals_str = trim(body[eq_idx + 1 ..]);
                var vals: std.ArrayListUnmanaged([]const u8) = .empty;
                errdefer vals.deinit(alloc);
                var vit = std.mem.tokenizeAny(u8, vals_str, " \t");
                while (vit.next()) |v| try vals.append(alloc, v);
                const owned_vals = try vals.toOwnedSlice(alloc);
                errdefer alloc.free(owned_vals);
                if (var_groups_out.fetchRemove(name)) |old| alloc.free(old.value);
                try var_groups_out.put(alloc, name, owned_vals);
                continue;
            }

            // Header line: `field [field...] = component`
            const eq_idx = std.mem.indexOfScalar(u8, body, '=') orelse continue;
            const lhs = trimRight(body[0..eq_idx]);
            const rhs_comp = trim(body[eq_idx + 1 ..]);

            const component = parseComponent(rhs_comp) orelse continue;

            // First pass: detect indexed fields and derive the group layout index.
            var group_index: ?usize = null;
            var bad = false;
            {
                var it = std.mem.tokenizeAny(u8, lhs, " \t");
                while (it.next()) |tok| {
                    if (std.mem.indexOfScalar(u8, tok, '[') == null) continue;
                    const pf = parseFieldIndexed(tok);
                    if (pf.field == null or pf.index == null) {
                        // Unknown field or skip-index (none/later) -> skip whole group.
                        bad = true;
                        break;
                    }
                    if (group_index == null) group_index = pf.index;
                }
            }
            if (bad) {
                skip_group = true;
                continue;
            }

            cur_component = component;
            cur_layout_index = group_index;

            var it2 = std.mem.tokenizeAny(u8, lhs, " \t");
            while (it2.next()) |tok| {
                const pf = parseFieldIndexed(tok);
                const f = pf.field orelse continue;
                if (std.mem.indexOfScalar(u8, tok, '[') != null and pf.index == null) continue;
                try cur_fields.append(alloc, f);
            }
        } else {
            // Mapping line.
            if (cur_component == null) continue;
            const n_fields = cur_fields.items.len;

            var tok_iter = std.mem.tokenizeAny(u8, line, " \t");
            var patterns: std.ArrayListUnmanaged(Pattern) = .empty;
            errdefer patterns.deinit(alloc);

            var count: usize = 0;
            var saw_eq = false;
            var rhs_start: usize = 0;

            while (tok_iter.next()) |tok| {
                if (count < n_fields) {
                    const pat: Pattern = if (std.mem.eql(u8, tok, "*"))
                        .wildcard
                    else if (std.mem.startsWith(u8, tok, "$"))
                        Pattern{ .group = tok[1..] }
                    else
                        Pattern{ .literal = tok };
                    try patterns.append(alloc, pat);
                    count += 1;
                } else if (!saw_eq) {
                    if (std.mem.eql(u8, tok, "=")) {
                        saw_eq = true;
                        rhs_start = tok_iter.index;
                    }
                } else {
                    break;
                }
            }

            if (!saw_eq) {
                patterns.deinit(alloc);
                continue;
            }

            const rhs = trim(line[rhs_start..]);
            const owned_pats = try patterns.toOwnedSlice(alloc);
            errdefer alloc.free(owned_pats);
            try cur_lines.append(alloc, MappingLine{
                .patterns = owned_pats,
                .rhs = rhs,
            });
        }
    }

    // Flush last group.
    if (cur_component != null) {
        const owned_fields = try cur_fields.toOwnedSlice(alloc);
        errdefer alloc.free(owned_fields);
        const owned_lines = try cur_lines.toOwnedSlice(alloc);
        errdefer {
            for (owned_lines) |*ln| alloc.free(ln.patterns);
            alloc.free(owned_lines);
        }
        try groups.append(alloc, RuleGroup{
            .fields = owned_fields,
            .component = cur_component.?,
            .lines = owned_lines,
            .layout_index = cur_layout_index,
        });
    } else {
        cur_fields.deinit(alloc);
        for (cur_lines.items) |*ln| alloc.free(ln.patterns);
        cur_lines.deinit(alloc);
    }

    return try groups.toOwnedSlice(alloc);
}

pub fn parseRules(alloc: std.mem.Allocator, text: []const u8) ![]RuleGroup {
    var vg: VarGroupMap = .empty;
    defer freeVarGroupMap(alloc, &vg);
    return parseRulesInternal(alloc, text, &vg);
}

fn freeGroup(alloc: std.mem.Allocator, g: *RuleGroup) void {
    alloc.free(g.fields);
    for (g.lines) |*ln| alloc.free(ln.patterns);
    alloc.free(g.lines);
}

pub fn freeRules(alloc: std.mem.Allocator, groups: []RuleGroup) void {
    for (groups) |*g| freeGroup(alloc, g);
    alloc.free(groups);
}

// expandInternal / expand

/// Expand `%`-escape sequences in `rhs`.
///
/// layouts/variants: split arrays for multi-layout mode (empty = single-layout).
/// effective_idx:    0-based index of the active layout for plain %l/%v
///                   (null -> use names.layout/names.variant directly).
///
/// Supported sequences:
///   %m  ->  model
///   %l  ->  layout[effective_idx] (or names.layout if no split)
///   %v  ->  variant[effective_idx] (or names.variant if no split)
///   %l[N]  ->  layouts[N-1]  (%l[1] = first layout)
///   %v[N]  ->  variants[N-1]
///   %(m) / %(l) / %(v)        ->  (<value>) or nothing if empty/null
///   %(l[N]) / %(v[N])         ->  (<value>) or nothing if empty/null
///   %+m / %+l / %+v           ->  +<value> or nothing if empty/null
///   %|m / %|l / %|v           ->  |<value> or nothing if empty/null
///   %%  ->  literal %
///   %x (unknown)  ->  literal %x (passthrough)
fn expandInternal(
    arena: std.mem.Allocator,
    rhs: []const u8,
    names: RuleNames,
    layouts: []const []const u8,
    variants: []const []const u8,
    effective_idx: ?usize,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < rhs.len) {
        if (rhs[i] != '%') {
            try out.append(arena, rhs[i]);
            i += 1;
            continue;
        }
        i += 1; // skip '%'
        if (i >= rhs.len) {
            try out.append(arena, '%');
            break;
        }

        switch (rhs[i]) {
            '%' => {
                try out.append(arena, '%');
                i += 1;
            },
            'm' => {
                if (names.model) |v| try out.appendSlice(arena, v);
                i += 1;
            },
            'l' => {
                // Check for %l[N] form.
                if (i + 1 < rhs.len and rhs[i + 1] == '[') {
                    if (parseIndexBracket(rhs, i + 2)) |res| {
                        const val = indexedOrFallback(layouts, res.n, if (res.n == 1) names.layout else null);
                        if (val) |v| try out.appendSlice(arena, v);
                        i = res.end;
                        continue;
                    }
                }
                // Plain %l.
                const val = effectiveSingle(layouts, effective_idx, names.layout);
                if (val) |v| try out.appendSlice(arena, v);
                i += 1;
            },
            'v' => {
                // Check for %v[N] form.
                if (i + 1 < rhs.len and rhs[i + 1] == '[') {
                    if (parseIndexBracket(rhs, i + 2)) |res| {
                        const val = indexedOrFallback(variants, res.n, if (res.n == 1) names.variant else null);
                        if (val) |v| try out.appendSlice(arena, v);
                        i = res.end;
                        continue;
                    }
                }
                // Plain %v.
                const val = effectiveSingle(variants, effective_idx, names.variant);
                if (val) |v| try out.appendSlice(arena, v);
                i += 1;
            },
            '(' => {
                i += 1; // skip '('
                // Try %(l[N]) and %(v[N]) forms first.
                if (i < rhs.len and (rhs[i] == 'l' or rhs[i] == 'v') and
                    i + 1 < rhs.len and rhs[i + 1] == '[')
                {
                    const is_v = rhs[i] == 'v';
                    if (parseIndexBracket(rhs, i + 2)) |res| {
                        if (res.end < rhs.len and rhs[res.end] == ')') {
                            const arr = if (is_v) variants else layouts;
                            const fb = if (res.n == 1) (if (is_v) names.variant else names.layout) else null;
                            const val = indexedOrFallback(arr, res.n, fb);
                            if (val) |v| if (v.len > 0) {
                                try out.append(arena, '(');
                                try out.appendSlice(arena, v);
                                try out.append(arena, ')');
                            };
                            i = res.end + 1; // skip ']' was in res.end, now skip ')'
                            continue;
                        }
                    }
                }
                // %(m) / %(l) / %(v) form: next char then ')'.
                if (i < rhs.len and i + 1 < rhs.len and rhs[i + 1] == ')') {
                    const fc = rhs[i];
                    i += 2; // skip fc and ')'
                    const val: ?[]const u8 = switch (fc) {
                        'm' => names.model,
                        'l' => effectiveSingle(layouts, effective_idx, names.layout),
                        'v' => effectiveSingle(variants, effective_idx, names.variant),
                        else => null,
                    };
                    if (val) |v| if (v.len > 0) {
                        try out.append(arena, '(');
                        try out.appendSlice(arena, v);
                        try out.append(arena, ')');
                    };
                } else {
                    // Unknown form: passthrough '('.
                    try out.append(arena, '(');
                }
            },
            '+' => {
                i += 1;
                if (i < rhs.len) {
                    const fc = rhs[i];
                    i += 1;
                    const val: ?[]const u8 = switch (fc) {
                        'm' => names.model,
                        'l' => effectiveSingle(layouts, effective_idx, names.layout),
                        'v' => effectiveSingle(variants, effective_idx, names.variant),
                        else => null,
                    };
                    if (val) |v| if (v.len > 0) {
                        try out.append(arena, '+');
                        try out.appendSlice(arena, v);
                    };
                } else {
                    try out.append(arena, '+');
                }
            },
            '|' => {
                i += 1;
                if (i < rhs.len) {
                    const fc = rhs[i];
                    i += 1;
                    const val: ?[]const u8 = switch (fc) {
                        'm' => names.model,
                        'l' => effectiveSingle(layouts, effective_idx, names.layout),
                        'v' => effectiveSingle(variants, effective_idx, names.variant),
                        else => null,
                    };
                    if (val) |v| if (v.len > 0) {
                        try out.append(arena, '|');
                        try out.appendSlice(arena, v);
                    };
                } else {
                    try out.append(arena, '|');
                }
            },
            else => {
                try out.append(arena, '%');
                try out.append(arena, rhs[i]);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(arena);
}

/// Parse `[N]` starting at position `pos` in `s`.  Returns the parsed index and
/// the position immediately after `]`, or null if malformed.
const BracketResult = struct { n: usize, end: usize };

fn parseIndexBracket(s: []const u8, pos: usize) ?BracketResult {
    const close = std.mem.indexOfScalarPos(u8, s, pos, ']') orelse return null;
    const n = std.fmt.parseInt(usize, s[pos..close], 10) catch return null;
    if (n == 0) return null;
    return .{ .n = n, .end = close + 1 };
}

/// Return `arr[n-1]` if it exists and is non-empty, else `fallback` if n==1.
fn indexedOrFallback(arr: []const []const u8, n: usize, fallback: ?[]const u8) ?[]const u8 {
    if (n > 0 and n - 1 < arr.len) {
        const v = arr[n - 1];
        return if (v.len > 0) v else null;
    }
    return fallback;
}

/// Return the effective single value for a field: arr[idx] if arr is non-empty,
/// else `fallback` (names.layout or names.variant).
fn effectiveSingle(arr: []const []const u8, idx: ?usize, fallback: ?[]const u8) ?[]const u8 {
    if (arr.len > 0) {
        const i = idx orelse 0;
        if (i < arr.len) return arr[i];
        return null;
    }
    return fallback;
}

/// Public single-layout expand (no multi-layout arrays).
pub fn expand(arena: std.mem.Allocator, rhs: []const u8, names: RuleNames) ![]u8 {
    return expandInternal(arena, rhs, names, &.{}, &.{}, null);
}

/// Returns true when every pattern matches the corresponding field value.
/// Wildcard matches anything including null.
/// Literal requires a non-null exact match.
/// Group requires the field value to be a member of the named variable set.
pub fn lineMatches(
    patterns: []Pattern,
    fieldvals: []const ?[]const u8,
    var_groups: ?*const VarGroupMap,
) bool {
    if (patterns.len != fieldvals.len) return false;
    for (patterns, fieldvals) |pat, fv| {
        switch (pat) {
            .wildcard => {},
            .literal => |lit| {
                if (fv == null or !std.mem.eql(u8, fv.?, lit)) return false;
            },
            .group => |name| {
                if (fv == null) return false;
                const vg = var_groups orelse return false;
                const members = vg.get(name) orelse return false;
                var found = false;
                for (members) |m| {
                    if (std.mem.eql(u8, fv.?, m)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            },
        }
    }
    return true;
}

fn appendPiece(acc: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, piece: []const u8) !void {
    if (piece.len == 0) return;
    if (acc.items.len == 0) {
        try acc.appendSlice(arena, piece);
    } else if (piece[0] == '+' or piece[0] == '|') {
        try acc.appendSlice(arena, piece);
    } else {
        try acc.append(arena, '+');
        try acc.appendSlice(arena, piece);
    }
}

fn effectiveFieldVal(
    names: RuleNames,
    f: Field,
    layouts: []const []const u8,
    variants: []const []const u8,
    layout_index: ?usize,
) ?[]const u8 {
    return switch (f) {
        .model => names.model,
        .option => null,
        .layout => blk: {
            if (layout_index) |li| {
                const idx = li - 1;
                break :blk if (idx < layouts.len) layouts[idx] else null;
            }
            // Non-indexed: use first layout.
            break :blk if (layouts.len > 0) layouts[0] else names.layout;
        },
        .variant => blk: {
            if (layout_index) |li| {
                const idx = li - 1;
                break :blk if (idx < variants.len) variants[idx] else null;
            }
            break :blk if (variants.len > 0) variants[0] else names.variant;
        },
    };
}

pub fn resolveRules(arena: std.mem.Allocator, ctx: *Context, names: RuleNames) !KcCGST {
    const eff_rules = names.rules orelse ctx.getEnv("XKB_DEFAULT_RULES") orelse "evdev";
    const eff_model = names.model orelse ctx.getEnv("XKB_DEFAULT_MODEL") orelse "pc105";
    const eff_layout = names.layout orelse ctx.getEnv("XKB_DEFAULT_LAYOUT") orelse "us";
    const eff_variant = names.variant orelse ctx.getEnv("XKB_DEFAULT_VARIANT");
    const eff_options = names.options orelse ctx.getEnv("XKB_DEFAULT_OPTIONS");

    const eff_names = RuleNames{
        .rules = eff_rules,
        .model = eff_model,
        .layout = eff_layout,
        .variant = eff_variant,
        .options = eff_options,
    };

    const subpath = try std.fmt.allocPrint(arena, "rules/{s}", .{eff_rules});

    const text = blk: {
        var of = ctx.open(subpath) orelse return error.RulesNotFound;
        defer of.close();
        break :blk try std.Io.Dir.cwd().readFileAlloc(ctx.io, of.path, arena, .unlimited);
    };

    var var_groups: VarGroupMap = .empty;
    // var_groups memory is arena-owned; freeVarGroupMap is a no-op on arena but keeps
    // the struct clean in case a real allocator is passed.
    defer freeVarGroupMap(arena, &var_groups);
    const groups = try parseRulesInternal(arena, text, &var_groups);

    var layouts_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var variants_list: std.ArrayListUnmanaged([]const u8) = .empty;
    if (eff_names.layout) |lay| {
        var it = std.mem.splitScalar(u8, lay, ',');
        while (it.next()) |l| try layouts_list.append(arena, trim(l));
    }
    if (eff_names.variant) |var_str| {
        var it = std.mem.splitScalar(u8, var_str, ',');
        while (it.next()) |v| try variants_list.append(arena, v);
    }
    const layouts = layouts_list.items;
    const variants = variants_list.items;

    var options_list: std.ArrayListUnmanaged([]const u8) = .empty;
    if (eff_names.options) |opts| {
        var it = std.mem.splitScalar(u8, opts, ',');
        while (it.next()) |opt| {
            const t = trim(opt);
            if (t.len > 0) try options_list.append(arena, t);
        }
    }
    const options = options_list.items;

    const kinds = [5]Component{ .keycodes, .types, .compat, .symbols, .geometry };
    var keycodes_acc: std.ArrayListUnmanaged(u8) = .empty;
    var types_acc: std.ArrayListUnmanaged(u8) = .empty;
    var compat_acc: std.ArrayListUnmanaged(u8) = .empty;
    var symbols_acc: std.ArrayListUnmanaged(u8) = .empty;
    var geometry_acc: std.ArrayListUnmanaged(u8) = .empty;
    const accs = [5]*std.ArrayListUnmanaged(u8){
        &keycodes_acc, &types_acc, &compat_acc, &symbols_acc, &geometry_acc,
    };

    for (kinds, 0..) |kind, ki| {
        for (groups) |g| {
            if (g.component != kind) continue;

            const has_option: bool = for (g.fields) |f| {
                if (f == .option) break true;
            } else false;

            if (has_option) {
                // Options: each option value is tried independently; all matches append.
                for (options) |opt_val| {
                    const fieldvals = try arena.alloc(?[]const u8, g.fields.len);
                    for (g.fields, 0..) |f, fi| {
                        fieldvals[fi] = if (f == .option)
                            opt_val
                        else
                            effectiveFieldVal(eff_names, f, layouts, variants, g.layout_index);
                    }
                    for (g.lines) |ln| {
                        if (lineMatches(ln.patterns, fieldvals, &var_groups)) {
                            const ei: ?usize = if (g.layout_index) |li| li - 1 else if (layouts.len > 0) @as(usize, 0) else null;
                            const piece = try expandInternal(arena, ln.rhs, eff_names, layouts, variants, ei);
                            try appendPiece(accs[ki], arena, piece);
                            break;
                        }
                    }
                }
            } else if (g.layout_index) |li| {
                // Indexed group: only fires when the requested layout index exists.
                const idx = li - 1;
                if (idx >= layouts.len) continue;
                const fieldvals = try arena.alloc(?[]const u8, g.fields.len);
                for (g.fields, 0..) |f, fi| {
                    fieldvals[fi] = effectiveFieldVal(eff_names, f, layouts, variants, g.layout_index);
                }
                for (g.lines) |ln| {
                    if (lineMatches(ln.patterns, fieldvals, &var_groups)) {
                        const piece = try expandInternal(arena, ln.rhs, eff_names, layouts, variants, idx);
                        try appendPiece(accs[ki], arena, piece);
                        break;
                    }
                }
            } else {
                // Non-indexed group: uses first layout (layouts[0]) for layout/variant.
                const ei: ?usize = if (layouts.len > 0) @as(usize, 0) else null;
                const fieldvals = try arena.alloc(?[]const u8, g.fields.len);
                for (g.fields, 0..) |f, fi| {
                    fieldvals[fi] = effectiveFieldVal(eff_names, f, layouts, variants, null);
                }
                for (g.lines) |ln| {
                    if (lineMatches(ln.patterns, fieldvals, &var_groups)) {
                        const piece = try expandInternal(arena, ln.rhs, eff_names, layouts, variants, ei);
                        try appendPiece(accs[ki], arena, piece);
                        break;
                    }
                }
            }
        }
    }

    return KcCGST{
        .keycodes = try keycodes_acc.toOwnedSlice(arena),
        .types = try types_acc.toOwnedSlice(arena),
        .compat = try compat_acc.toOwnedSlice(arena),
        .symbols = try symbols_acc.toOwnedSlice(arena),
        .geometry = try geometry_acc.toOwnedSlice(arena),
    };
}

test "resolveRules expands components" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "rules");
    const rules_txt =
        \\! model = keycodes
        \\  *      = evdev
        \\! layout = symbols
        \\  *      = pc+%l
        \\! layout variant = symbols
        \\  *      *   = pc+%l%(v)
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/testrules", .data = rules_txt });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // with variant: symbols must contain us(intl) and keycodes must be evdev
    const kccgst = try resolveRules(arena.allocator(), ctx, .{ .rules = "testrules", .layout = "us", .variant = "intl" });
    try std.testing.expectEqualStrings("evdev", kccgst.keycodes);
    try std.testing.expect(std.mem.indexOf(u8, kccgst.symbols, "us(intl)") != null);
    // empty variant -> no empty parens
    const k2 = try resolveRules(arena.allocator(), ctx, .{ .rules = "testrules", .layout = "us" });
    try std.testing.expect(std.mem.indexOf(u8, k2.symbols, "us") != null);
    try std.testing.expect(std.mem.indexOf(u8, k2.symbols, "()") == null);
}

test "parseRules: indexed group parsed with layout_index" {
    // Previously this test verified indexed groups were SKIPPED.
    // Now that indexed groups are supported, both groups must be parsed.
    const text =
        \\! layout = symbols
        \\  *      = pc+%l
        \\! layout[1] = symbols
        \\  *      = pc+%l[1]
    ;
    const groups = try parseRules(std.testing.allocator, text);
    defer freeRules(std.testing.allocator, groups);

    // Both groups must be present: non-indexed + indexed-1.
    try std.testing.expectEqual(@as(usize, 2), groups.len);

    try std.testing.expectEqual(Component.symbols, groups[0].component);
    try std.testing.expectEqual(@as(usize, 1), groups[0].fields.len);
    try std.testing.expectEqual(Field.layout, groups[0].fields[0]);
    try std.testing.expectEqual(@as(?usize, null), groups[0].layout_index);
    try std.testing.expectEqualStrings("pc+%l", groups[0].lines[0].rhs);

    try std.testing.expectEqual(Component.symbols, groups[1].component);
    try std.testing.expectEqual(@as(usize, 1), groups[1].fields.len);
    try std.testing.expectEqual(Field.layout, groups[1].fields[0]);
    try std.testing.expectEqual(@as(?usize, 1), groups[1].layout_index);
    try std.testing.expectEqualStrings("pc+%l[1]", groups[1].lines[0].rhs);
}

test "resolveRules: both indexed and non-indexed groups fire for single layout" {
    // For a rules file with both a plain `! layout` group and a `! layout[1]` group,
    // a single layout value fires BOTH (index 1 exists for a single-layout).
    // Updated from the old "indexed group not fired" test.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "rules");
    const rules_txt =
        \\! layout = symbols
        \\  *      = pc+%l
        \\! layout[1] = symbols
        \\  *      = pc+%l[1]
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/idxtest", .data = rules_txt });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const kccgst = try resolveRules(arena.allocator(), ctx, .{ .rules = "idxtest", .layout = "us" });
    // Both groups fire: non-indexed produces "pc+us", indexed[1] also produces "pc+us".
    // appendPiece joins with '+': "pc+us+pc+us".
    try std.testing.expect(std.mem.indexOf(u8, kccgst.symbols, "pc+us") != null);
    // No literal "[1]" in the output (the template was expanded).
    try std.testing.expect(std.mem.indexOf(u8, kccgst.symbols, "[1]") == null);
}

test "parseRules groups and lines" {
    const text =
        \\// comment
        \\! model = keycodes
        \\  pc98   = pc98
        \\  *      = evdev
        \\! layout variant = symbols
        \\  *      *   = pc+%l%(v)
    ;
    const groups = try parseRules(std.testing.allocator, text);
    defer freeRules(std.testing.allocator, groups);

    try std.testing.expectEqual(@as(usize, 2), groups.len);

    try std.testing.expectEqual(Component.keycodes, groups[0].component);
    try std.testing.expectEqual(@as(usize, 1), groups[0].fields.len);
    try std.testing.expectEqual(Field.model, groups[0].fields[0]);
    try std.testing.expectEqual(@as(usize, 2), groups[0].lines.len);
    try std.testing.expectEqualStrings("pc98", groups[0].lines[0].patterns[0].literal);
    try std.testing.expectEqualStrings("pc98", groups[0].lines[0].rhs);
    try std.testing.expect(groups[0].lines[1].patterns[0] == .wildcard);
    try std.testing.expectEqualStrings("evdev", groups[0].lines[1].rhs);

    try std.testing.expectEqual(Component.symbols, groups[1].component);
    try std.testing.expectEqual(@as(usize, 2), groups[1].fields.len);
    try std.testing.expectEqualStrings("pc+%l%(v)", groups[1].lines[0].rhs);
}

test "resolveRules: $variable group membership" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "rules");
    const rules_txt =
        \\! $pcmodels = pc101 pc105
        \\! model = keycodes
        \\  $pcmodels = special
        \\  *         = evdev
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/vartest", .data = rules_txt });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // pc105 is in $pcmodels -> picks "special"
    const k1 = try resolveRules(arena.allocator(), ctx, .{ .rules = "vartest", .model = "pc105" });
    try std.testing.expectEqualStrings("special", k1.keycodes);
    // pc99 is NOT in $pcmodels -> falls through to wildcard "evdev"
    const k2 = try resolveRules(arena.allocator(), ctx, .{ .rules = "vartest", .model = "pc99" });
    try std.testing.expectEqualStrings("evdev", k2.keycodes);
}

test "resolveRules: options matrix appends multiple matches" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "rules");
    const rules_txt =
        \\! option = symbols
        \\  grp:alt_shift_toggle = +group(alt_shift)
        \\  ctrl:nocaps          = +ctrl(nocaps)
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/opttest", .data = rules_txt });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const kccgst = try resolveRules(arena.allocator(), ctx, .{
        .rules = "opttest",
        .options = "grp:alt_shift_toggle,ctrl:nocaps",
    });
    try std.testing.expect(std.mem.indexOf(u8, kccgst.symbols, "+group(alt_shift)") != null);
    try std.testing.expect(std.mem.indexOf(u8, kccgst.symbols, "+ctrl(nocaps)") != null);
}

test "resolveRules: multi-layout indexed groups" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "rules");
    const rules_txt =
        \\! layout[1] = symbols
        \\  * = pc+%l[1]%(v[1])
        \\! layout[2] = symbols
        \\  * = +%l[2]%(v[2]):2
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/multitest", .data = rules_txt });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Two layouts "us,de": both indexed groups fire.
    const km = try resolveRules(arena.allocator(), ctx, .{
        .rules = "multitest",
        .layout = "us,de",
        .variant = ",",
    });
    try std.testing.expect(std.mem.indexOf(u8, km.symbols, "pc+us") != null);
    try std.testing.expect(std.mem.indexOf(u8, km.symbols, "+de") != null);
    try std.testing.expect(std.mem.indexOf(u8, km.symbols, ":2") != null);

    // Single layout "us": only layout[1] group fires, layout[2] is skipped.
    const k2 = try resolveRules(arena.allocator(), ctx, .{
        .rules = "multitest",
        .layout = "us",
    });
    try std.testing.expectEqualStrings("pc+us", k2.symbols);
}
