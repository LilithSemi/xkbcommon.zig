const std = @import("std");

pub const DFLT_XKB_CONFIG_ROOT = "/usr/share/X11/xkb";
pub const DFLT_XKB_CONFIG_EXTRA_PATH = "/etc/xkb";

pub const Atom = enum(u32) { none = 0, _ };

pub const LogLevel = enum(u8) {
    critical = 10,
    err = 20,
    warning = 30,
    info = 40,
    debug = 50,
};

pub fn parseLogLevel(s: []const u8) ?LogLevel {
    if (std.ascii.eqlIgnoreCase(s, "critical")) return .critical;
    if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(s, "warning")) return .warning;
    if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
    const n = std.fmt.parseInt(u8, s, 10) catch return null;
    return switch (n) {
        10 => .critical,
        20 => .err,
        30 => .warning,
        40 => .info,
        50 => .debug,
        else => null,
    };
}

pub const DefaultEnv = struct {
    home: ?[]const u8,
    xdg_config_home: ?[]const u8,
    extra_path: ?[]const u8,
    config_root: ?[]const u8,
};

pub fn appendDefaultPaths(ctx: *Context, env: DefaultEnv) !void {
    const alloc = ctx.allocator;

    // xdg_config_home/xkb or home/.config/xkb
    if (env.xdg_config_home) |xdg| {
        if (xdg.len > 0) {
            const p = try std.fs.path.join(alloc, &.{ xdg, "xkb" });
            defer alloc.free(p);
            try ctx.includePathAppend(p);
        }
    } else if (env.home) |home| {
        if (home.len > 0) {
            const p = try std.fs.path.join(alloc, &.{ home, ".config", "xkb" });
            defer alloc.free(p);
            try ctx.includePathAppend(p);
        }
    }

    // home/.xkb
    if (env.home) |home| {
        if (home.len > 0) {
            const p = try std.fs.path.join(alloc, &.{ home, ".xkb" });
            defer alloc.free(p);
            try ctx.includePathAppend(p);
        }
    }

    // extra_path if non-empty, otherwise the compiled-in default
    const extra = blk: {
        if (env.extra_path) |e| if (e.len > 0) break :blk e;
        break :blk DFLT_XKB_CONFIG_EXTRA_PATH;
    };
    try ctx.includePathAppend(extra);

    // config_root if non-empty, otherwise the compiled-in default
    const root = blk: {
        if (env.config_root) |r| if (r.len > 0) break :blk r;
        break :blk DFLT_XKB_CONFIG_ROOT;
    };
    try ctx.includePathAppend(root);
}

pub const Flags = struct {
    no_default_includes: bool = false,
    no_environment_names: bool = false,
};

// OpenedFile holds the resolved path so callers can resolve relative includes.
pub const OpenedFile = struct {
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []u8,

    pub fn close(self: *OpenedFile) void {
        self.allocator.free(self.path);
        self.file.close(self.io);
        self.* = undefined;
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    include_paths: std.ArrayList([]u8),
    log_level: LogLevel,
    log_verbosity: i32,
    // log_fn receives the context pointer so sinks can reach context state.
    log_fn: ?*const fn (ctx: *Context, level: LogLevel, msg: []const u8) void,
    env_enabled: bool,
    env: ?*const std.process.Environ.Map,
    atom_map: std.StringHashMap(Atom),
    atom_list: std.ArrayList([]const u8),

    pub fn create(alloc: std.mem.Allocator, io: std.Io, flags: Flags, env: ?*const std.process.Environ.Map) !*Context {
        const self = try alloc.create(Context);
        errdefer alloc.destroy(self);
        self.* = .{
            .allocator = alloc,
            .io = io,
            .include_paths = .empty,
            .log_level = .err,
            .log_verbosity = 0,
            .log_fn = null,
            .env_enabled = !flags.no_environment_names,
            .env = env,
            .atom_map = std.StringHashMap(Atom).init(alloc),
            .atom_list = .empty,
        };
        errdefer {
            self.includePathClear();
            self.include_paths.deinit(alloc);
            self.atom_map.deinit();
            self.atom_list.deinit(alloc);
        }
        if (!flags.no_default_includes) {
            try self.includePathAppendDefault();
        }
        if (self.env_enabled) {
            if (self.getEnv("XKB_LOG_LEVEL")) |val| {
                if (parseLogLevel(val)) |level| self.log_level = level;
            }
            if (self.getEnv("XKB_LOG_VERBOSITY")) |val| {
                if (std.fmt.parseInt(i32, val, 10)) |v| {
                    self.log_verbosity = v;
                } else |_| {}
            }
        }
        return self;
    }

    pub fn getEnv(self: *const Context, name: []const u8) ?[]const u8 {
        if (!self.env_enabled) return null;
        const m = self.env orelse return null;
        return m.get(name);
    }

    pub fn includePathAppendDefault(self: *Context) !void {
        const env: DefaultEnv = .{
            .home = self.getEnv("HOME"),
            .xdg_config_home = self.getEnv("XDG_CONFIG_HOME"),
            .extra_path = self.getEnv("XKB_CONFIG_EXTRA_PATH"),
            .config_root = self.getEnv("XKB_CONFIG_ROOT"),
        };
        try appendDefaultPaths(self, env);
    }

    pub fn destroy(self: *Context) void {
        self.includePathClear();
        self.include_paths.deinit(self.allocator);
        for (self.atom_list.items) |s| {
            self.allocator.free(s);
        }
        self.atom_list.deinit(self.allocator);
        self.atom_map.deinit();
        self.allocator.destroy(self);
    }

    pub fn setLogFn(self: *Context, f: *const fn (ctx: *Context, level: LogLevel, msg: []const u8) void) void {
        self.log_fn = f;
    }

    pub fn setLogLevel(self: *Context, level: LogLevel) void {
        self.log_level = level;
    }

    pub fn setLogVerbosity(self: *Context, verbosity: i32) void {
        self.log_verbosity = verbosity;
    }

    pub fn log(self: *Context, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) > @intFromEnum(self.log_level)) return;
        var buf: [1024]u8 = undefined;
        // drop cleanly on overflow rather than returning garbage bytes
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        if (self.log_fn) |f| {
            // pass self so the sink can reach context state
            f(self, level, msg);
        } else {
            std.Io.File.writeStreamingAll(std.Io.File.stderr(), self.io, msg) catch {};
            std.Io.File.writeStreamingAll(std.Io.File.stderr(), self.io, "\n") catch {};
        }
    }

    pub fn intern(self: *Context, name: []const u8) !Atom {
        if (self.atom_map.get(name)) |a| return a;
        const dup = try self.allocator.dupe(u8, name);
        // free dup on any subsequent error
        errdefer self.allocator.free(dup);
        try self.atom_list.append(self.allocator, dup);
        // roll back append if put fails so list and map stay in sync
        errdefer _ = self.atom_list.pop();
        const id: Atom = @enumFromInt(self.atom_list.items.len);
        try self.atom_map.put(dup, id);
        return id;
    }

    pub fn atomText(self: *const Context, atom: Atom) []const u8 {
        if (atom == .none) return "";
        return self.atom_list.items[@intFromEnum(atom) - 1];
    }

    pub fn includePathAppend(self: *Context, path: []const u8) !void {
        const dup = try self.allocator.dupe(u8, path);
        try self.include_paths.append(self.allocator, dup);
    }

    pub fn includePathPrepend(self: *Context, path: []const u8) !void {
        const dup = try self.allocator.dupe(u8, path);
        try self.include_paths.insert(self.allocator, 0, dup);
    }

    pub fn includePathClear(self: *Context) void {
        for (self.include_paths.items) |p| {
            self.allocator.free(p);
        }
        self.include_paths.clearRetainingCapacity();
    }

    pub fn numIncludePaths(self: *const Context) usize {
        return self.include_paths.items.len;
    }

    pub fn includePath(self: *const Context, idx: usize) ?[]const u8 {
        if (idx >= self.include_paths.items.len) return null;
        return self.include_paths.items[idx];
    }

    pub fn open(self: *Context, subpath: []const u8) ?OpenedFile {
        const io = self.io;
        for (self.include_paths.items) |inc_path| {
            // cwd().openFile handles both absolute and relative include dirs. On success, OpenedFile owns full_path.
            const full_path = std.fs.path.join(self.allocator, &.{ inc_path, subpath }) catch continue;
            const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch {
                self.allocator.free(full_path);
                continue;
            };
            return OpenedFile{
                .file = file,
                .io = io,
                .allocator = self.allocator,
                .path = full_path,
            };
        }
        return null;
    }
};

test "create/destroy empty" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try std.testing.expectEqual(@as(usize, 0), ctx.numIncludePaths());
}

test "append and prepend order" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend("/a");
    try ctx.includePathAppend("/b");
    try ctx.includePathPrepend("/z");
    try std.testing.expectEqual(@as(usize, 3), ctx.numIncludePaths());
    try std.testing.expectEqualStrings("/z", ctx.includePath(0).?);
    try std.testing.expectEqualStrings("/a", ctx.includePath(1).?);
    try std.testing.expectEqualStrings("/b", ctx.includePath(2).?);
    try std.testing.expect(ctx.includePath(3) == null);
}

test "clear frees paths" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend("/a");
    ctx.includePathClear();
    try std.testing.expectEqual(@as(usize, 0), ctx.numIncludePaths());
}

test "atom intern dedups and round-trips" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const a = try ctx.intern("Return");
    const b = try ctx.intern("Return");
    const c = try ctx.intern("space");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
    try std.testing.expectEqualStrings("Return", ctx.atomText(a));
    try std.testing.expectEqualStrings("space", ctx.atomText(c));
    try std.testing.expectEqual(Atom.none, @as(Atom, @enumFromInt(0)));
    try std.testing.expectEqualStrings("", ctx.atomText(.none));
}

test "parseLogLevel names and numbers" {
    try std.testing.expectEqual(LogLevel.warning, parseLogLevel("warning").?);
    try std.testing.expectEqual(LogLevel.err, parseLogLevel("ERROR").?);
    try std.testing.expectEqual(LogLevel.debug, parseLogLevel("50").?);
    try std.testing.expect(parseLogLevel("nonsense") == null);
}

test "appendDefaultPaths order with injected env" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try appendDefaultPaths(ctx, .{ .home = "/home/u", .xdg_config_home = null, .extra_path = null, .config_root = "/data/xkb" });
    try std.testing.expectEqual(@as(usize, 4), ctx.numIncludePaths());
    try std.testing.expectEqualStrings("/home/u/.config/xkb", ctx.includePath(0).?);
    try std.testing.expectEqualStrings("/home/u/.xkb", ctx.includePath(1).?);
    try std.testing.expectEqualStrings("/etc/xkb", ctx.includePath(2).?);
    try std.testing.expectEqualStrings("/data/xkb", ctx.includePath(3).?);
}

test "appendDefaultPaths uses xdg over home config" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try appendDefaultPaths(ctx, .{ .home = "/home/u", .xdg_config_home = "/xdg", .extra_path = "/opt/xkb", .config_root = "/data/xkb" });
    try std.testing.expectEqualStrings("/xdg/xkb", ctx.includePath(0).?);
    try std.testing.expectEqualStrings("/opt/xkb", ctx.includePath(2).?);
}

test "create reads defaults from injected env map" {
    const io = std.testing.io;
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("HOME", "/home/tester");
    const ctx = try Context.create(std.testing.allocator, io, .{}, &map);
    defer ctx.destroy();
    try std.testing.expectEqualStrings("/home/tester/.config/xkb", ctx.includePath(0).?);
}

var test_captured: [256]u8 = undefined;
var test_len: usize = 0;
fn captureLog(ctx: *Context, level: LogLevel, msg: []const u8) void {
    _ = ctx;
    _ = level;
    @memcpy(test_captured[0..msg.len], msg);
    test_len = msg.len;
}

test "log respects level and calls fn" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    ctx.setLogFn(captureLog);
    ctx.setLogLevel(.warning);
    test_len = 0;
    ctx.log(.debug, "should be filtered {d}", .{1});
    try std.testing.expectEqual(@as(usize, 0), test_len);
    ctx.log(.err, "boom {d}", .{42});
    try std.testing.expectEqualStrings("boom 42", test_captured[0..test_len]);
}

test "log overflow drops message cleanly" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    ctx.setLogFn(captureLog);
    ctx.setLogLevel(.debug);
    test_len = 99; // sentinel: captureLog must overwrite this
    // Feed a 2048-byte string to exceed the 1024-byte bufPrint buffer
    const long_arr = [_]u8{'x'} ** 2048;
    ctx.log(.debug, "{s}", .{long_arr[0..]});
    // bufPrint overflows -> catch returns buf[0..0]; captureLog sees msg.len == 0
    try std.testing.expectEqual(@as(usize, 0), test_len);
}

test "open finds file in include path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "rules");
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/evdev", .data = "hello" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);
    var found = ctx.open("rules/evdev") orelse return error.NotFound;
    // path is owned and ends with the subpath we searched for
    try std.testing.expect(std.mem.endsWith(u8, found.path, "rules/evdev"));
    found.close();
    try std.testing.expect(ctx.open("rules/missing") == null);
}

// regression test: a relative include path must return null, not panic
test "open with relative include path does not panic" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend("relative/nonexistent/path");
    try std.testing.expect(ctx.open("anything") == null);
}

// empty extra_path and config_root fall back to compiled-in defaults
test "appendDefaultPaths empty env falls back to compile defaults" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try appendDefaultPaths(ctx, .{ .home = null, .xdg_config_home = null, .extra_path = "", .config_root = "" });
    try std.testing.expectEqual(@as(usize, 2), ctx.numIncludePaths());
    try std.testing.expectEqualStrings(DFLT_XKB_CONFIG_EXTRA_PATH, ctx.includePath(0).?);
    try std.testing.expectEqualStrings(DFLT_XKB_CONFIG_ROOT, ctx.includePath(1).?);
}

// with no_environment_names, env vars in the map must be ignored
test "getEnv gating suppresses XKB_LOG_LEVEL when no_environment_names" {
    const io = std.testing.io;
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("XKB_LOG_LEVEL", "debug");
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true, .no_environment_names = true }, &map);
    defer ctx.destroy();
    // XKB_LOG_LEVEL=debug in the map should be ignored; log_level stays at default .err.
    try std.testing.expectEqual(LogLevel.err, ctx.log_level);
}
