/// ComposeTable trie of keysym sequences mapped to results.
/// Each Node holds a keysym (edge label), an arena-owned children slice, and an optional Result.
/// Children are built with a temp ArrayList then frozen to an arena slice after parsing.
const std = @import("std");
const Context = @import("../context.zig").Context;
const keysym_mod = @import("../keysym.zig");
pub const Keysym = keysym_mod.Keysym;
const parser = @import("parser.zig");
pub const Result = parser.Result;

pub const Format = enum { text_v1 };

// Build-time mutable node (lives in a temp arena, discarded after freeze)

const BuildNode = struct {
    keysym: Keysym,
    children: std.ArrayListUnmanaged(*BuildNode),
    result: ?Result,

    fn init(ks: Keysym) BuildNode {
        return .{ .keysym = ks, .children = .empty, .result = null };
    }
};

pub const ComposeTable = struct {
    arena: std.heap.ArenaAllocator,
    ctx: *Context,
    root: Node,

    pub const Node = struct {
        keysym: Keysym,
        children: []Node,
        result: ?Result,
    };

    /// Linear scan of children for a matching keysym.
    pub fn lookup(node: *const Node, ks: Keysym) ?*const Node {
        for (node.children) |*child| {
            if (child.keysym == ks) return child;
        }
        return null;
    }

    /// Parse `buf` as a Compose text file and build the trie.
    pub fn newFromBuffer(ctx: *Context, buf: []const u8, format: Format) !*ComposeTable {
        _ = format;
        return newFromBufImpl(ctx, buf, null, null);
    }

    /// Build a ComposeTable from buf, resolving includes relative to base_dir if given.
    /// locale is used for %L expansion; home is taken from ctx.getEnv("HOME") for %H.
    fn newFromBufImpl(ctx: *Context, buf: []const u8, base_dir: ?[]const u8, locale: ?[]const u8) !*ComposeTable {
        const self = try ctx.allocator.create(ComposeTable);
        errdefer ctx.allocator.destroy(self);

        self.* = .{
            .arena = std.heap.ArenaAllocator.init(ctx.allocator),
            .ctx = ctx,
            .root = .{ .keysym = .no_symbol, .children = &.{}, .result = null },
        };
        errdefer self.arena.deinit();

        const arena_alloc = self.arena.allocator();

        // Parse into a temporary arena so we can free parse allocations after
        // freezing results into the table arena.
        var scratch_arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const entries = if (base_dir != null)
            try parser.parseComposeWithIncludes(scratch, ctx.io, base_dir, ctx.getEnv("HOME"), parser.DFLT_SYSTEM_COMPOSE_DIR, locale, buf)
        else
            try parser.parseCompose(scratch, buf);
        // scratch_arena.deinit() frees entry memory; no manual freeEntries needed.

        // Build-time root in scratch memory.
        var build_root = BuildNode.init(.no_symbol);

        for (entries) |entry| {
            // Walk / create build nodes along the sequence.
            var cur: *BuildNode = &build_root;
            var conflict = false;
            for (entry.syms) |ks| {
                // Case (a): cur already has a result; extending past a terminal node
                // is a conflict.  Keep existing, skip this extension (X.Org policy).
                if (cur.result != null) {
                    ctx.log(.warning, "compose: conflicting sequence, keeping existing", .{});
                    conflict = true;
                    break;
                }
                var found: ?*BuildNode = null;
                for (cur.children.items) |child| {
                    if (child.keysym == ks) {
                        found = child;
                        break;
                    }
                }
                if (found) |c| {
                    cur = c;
                } else {
                    const new_node = try scratch.create(BuildNode);
                    new_node.* = BuildNode.init(ks);
                    try cur.children.append(scratch, new_node);
                    cur = new_node;
                }
            }
            if (conflict) continue;
            // Case (b): leaf already has children; a result here would make the
            // longer sequences permanently unreachable.  Keep existing (no result).
            if (cur.children.items.len > 0) {
                ctx.log(.warning, "compose: conflicting sequence, keeping existing", .{});
                continue;
            }
            // Case (c): duplicate sequence; first definition wins.
            if (cur.result != null) {
                ctx.log(.warning, "compose: conflicting sequence, keeping existing", .{});
                continue;
            }
            const duped_utf8 = try arena_alloc.dupe(u8, entry.result.utf8);
            cur.result = .{ .utf8 = duped_utf8, .keysym = entry.result.keysym };
        }

        // Freeze the build tree into arena-owned []Node slices.
        self.root = try freezeNode(&build_root, arena_alloc);

        return self;
    }

    /// Find a Compose file for `locale` and build the trie. Checks XCOMPOSEFILE,
    /// then $HOME/.XCompose, then compose/<locale>/Compose in include paths.
    /// Full locale resolution is not yet implemented.
    pub fn newFromLocale(ctx: *Context, locale: []const u8, format: Format) !*ComposeTable {
        _ = format; // only .text_v1 exists; format is carried for API symmetry with newFromBuffer
        const alloc = ctx.allocator;
        const io = ctx.io;

        // XCOMPOSEFILE overrides all
        if (ctx.getEnv("XCOMPOSEFILE")) |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
            defer alloc.free(bytes);
            const base_dir = std.fs.path.dirname(path);
            return newFromBufImpl(ctx, bytes, base_dir, locale);
        }

        // ~/.XCompose if HOME is set
        if (ctx.getEnv("HOME")) |home| {
            const xcompose_path = try std.fs.path.join(alloc, &.{ home, ".XCompose" });
            defer alloc.free(xcompose_path);
            if (std.Io.Dir.cwd().readFileAlloc(io, xcompose_path, alloc, .unlimited)) |bytes| {
                defer alloc.free(bytes);
                const base_dir = std.fs.path.dirname(xcompose_path);
                return newFromBufImpl(ctx, bytes, base_dir, locale);
            } else |_| {}
        }

        // compose/<locale>/Compose via context include paths.
        // Use the already-open file handle from ctx.open to avoid a second open.
        {
            const subpath = try std.fs.path.join(alloc, &.{ "compose", locale, "Compose" });
            defer alloc.free(subpath);
            if (ctx.open(subpath)) |of_| {
                var of = of_;
                defer of.close();
                var file_reader = of.file.reader(io, &.{});
                const bytes = file_reader.interface.allocRemaining(alloc, .unlimited) catch |err| switch (err) {
                    error.ReadFailed => return file_reader.err.?,
                    error.OutOfMemory, error.StreamTooLong => |e| return e,
                };
                defer alloc.free(bytes);
                const base_dir = std.fs.path.dirname(of.path);
                return newFromBufImpl(ctx, bytes, base_dir, locale);
            }
        }

        return error.ComposeFileNotFound;
    }

    pub fn destroy(self: *ComposeTable) void {
        const alloc = self.ctx.allocator;
        self.arena.deinit();
        alloc.destroy(self);
    }
};

// Freeze: recursively convert BuildNode tree -> arena-owned Node tree

fn freezeNode(bn: *const BuildNode, arena: std.mem.Allocator) !ComposeTable.Node {
    const children = try arena.alloc(ComposeTable.Node, bn.children.items.len);
    for (bn.children.items, 0..) |child, i| {
        children[i] = try freezeNode(child, arena);
    }
    return .{
        .keysym = bn.keysym,
        .children = children,
        .result = bn.result, // utf8 slice already duped into arena by caller
    };
}

test "ComposeTable trie build + lookup" {
    const ctx = try Context.create(std.testing.allocator, std.testing.io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const buf =
        \\<dead_acute> <a> : "á" aacute
        \\<Multi_key> <o> <c> : copyright
    ;
    const table = try ComposeTable.newFromBuffer(ctx, buf, .text_v1);
    defer table.destroy();

    const da = ComposeTable.lookup(&table.root, Keysym.fromName("dead_acute", .{}).?) orelse return error.NoNode;
    try std.testing.expect(da.result == null); // not a leaf yet
    const a = ComposeTable.lookup(da, Keysym.fromName("a", .{}).?) orelse return error.NoNode;
    try std.testing.expect(a.result != null);
    try std.testing.expectEqualStrings("\xc3\xa1", a.result.?.utf8); // UTF-8 for á
    try std.testing.expect(ComposeTable.lookup(&table.root, Keysym.fromName("Multi_key", .{}).?) != null);
}

test "ComposeTable three-key sequence" {
    const ctx = try Context.create(std.testing.allocator, std.testing.io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const buf =
        \\<Multi_key> <o> <c> : copyright
    ;
    const table = try ComposeTable.newFromBuffer(ctx, buf, .text_v1);
    defer table.destroy();

    const mk = ComposeTable.lookup(&table.root, Keysym.fromName("Multi_key", .{}).?) orelse return error.NoMK;
    try std.testing.expect(mk.result == null);
    const o = ComposeTable.lookup(mk, Keysym.fromName("o", .{}).?) orelse return error.NoO;
    try std.testing.expect(o.result == null);
    const c = ComposeTable.lookup(o, Keysym.fromName("c", .{}).?) orelse return error.NoC;
    try std.testing.expect(c.result != null);
    try std.testing.expectEqual(Keysym.fromName("copyright", .{}).?, c.result.?.keysym);
}

test "ComposeTable conflict: shorter sequence kept, extension rejected" {
    const ctx = try Context.create(std.testing.allocator, std.testing.io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    // Shorter sequence defined first, longer conflicts with it.
    const buf =
        \\<Multi_key> <a> : "x"
        \\<Multi_key> <a> <e> : "y"
    ;
    const table = try ComposeTable.newFromBuffer(ctx, buf, .text_v1);
    defer table.destroy();

    const mk = ComposeTable.lookup(&table.root, Keysym.fromName("Multi_key", .{}).?) orelse return error.NoMK;
    const a = ComposeTable.lookup(mk, Keysym.fromName("a", .{}).?) orelse return error.NoA;
    // Existing shorter sequence is kept.
    try std.testing.expect(a.result != null);
    try std.testing.expectEqualStrings("x", a.result.?.utf8);
    // Conflicting extension was rejected: no child for 'e'.
    try std.testing.expect(ComposeTable.lookup(a, Keysym.fromName("e", .{}).?) == null);
}

test "newFromLocale via XCOMPOSEFILE + full compose flow" {
    const ComposeState = @import("state.zig").ComposeState;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Compose file with literal UTF-8 characters (parser handles raw bytes directly)
    const compose_txt = "<dead_grave> <a> : \"\xc3\xa0\" agrave\n<Multi_key> <c> <o> : \"\xc2\xa9\" copyright\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "MyCompose", .data = compose_txt });
    var pathbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pathbuf);
    const real = pathbuf[0..n];
    const path = try std.fs.path.join(std.testing.allocator, &.{ real, "MyCompose" });
    defer std.testing.allocator.free(path);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XCOMPOSEFILE", path);
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, &env);
    defer ctx.destroy();
    const table = try ComposeTable.newFromLocale(ctx, "en_US.UTF-8", .text_v1);
    defer table.destroy();
    const st = try ComposeState.new(table);
    defer st.destroy();
    _ = st.feed(Keysym.fromName("dead_grave", .{}).?);
    _ = st.feed(Keysym.fromName("a", .{}).?);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\xc3\xa0", st.getUtf8(&buf).?); // UTF-8 for à
    // second sequence: auto-reset happens on first feed after .composed
    _ = st.feed(Keysym.fromName("Multi_key", .{}).?);
    _ = st.feed(Keysym.fromName("c", .{}).?);
    _ = st.feed(Keysym.fromName("o", .{}).?);
    try std.testing.expectEqualStrings("\xc2\xa9", st.getUtf8(&buf).?); // UTF-8 for ©
}
