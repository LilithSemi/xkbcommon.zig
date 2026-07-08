const std = @import("std");
const xml = @import("xml");
const Context = @import("context.zig").Context;

pub const Popularity = enum { standard, exotic };

pub const ConfigItem = struct {
    name: []const u8,
    short_description: []const u8,
    description: []const u8,
    languages: [][]const u8,
    countries: [][]const u8 = &.{},
    popularity: Popularity = .standard,
};

pub const Model = struct {
    item: ConfigItem,
    vendor: []const u8,
};

pub const Variant = struct {
    item: ConfigItem,
};

pub const Layout = struct {
    item: ConfigItem,
    variants: []Variant,
};

pub const Option = struct {
    item: ConfigItem,
};

pub const OptionGroup = struct {
    item: ConfigItem,
    allow_multiple: bool,
    options: []Option,
};

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    ctx: *Context,
    models: []Model,
    layouts: []Layout,
    option_groups: []OptionGroup,

    pub fn newFromBuffer(ctx: *Context, xml_bytes: []const u8) !*Registry {
        const self = try ctx.allocator.create(Registry);
        errdefer ctx.allocator.destroy(self);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(ctx.allocator),
            .ctx = ctx,
            .models = &.{},
            .layouts = &.{},
            .option_groups = &.{},
        };
        errdefer self.arena.deinit();
        try parseXml(self, xml_bytes);
        return self;
    }

    pub fn newFromNames(ctx: *Context, rules: ?[]const u8) !*Registry {
        const name = rules orelse "evdev";
        const subpath = try std.fmt.allocPrint(ctx.allocator, "rules/{s}.xml", .{name});
        defer ctx.allocator.free(subpath);
        var of = ctx.open(subpath) orelse return error.RegistryFileNotFound;
        defer of.close();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(ctx.io, of.path, ctx.allocator, .unlimited);
        defer ctx.allocator.free(bytes);
        const self = try newFromBuffer(ctx, bytes);
        // Also try extras.xml (e.g. evdev.extras.xml); silently skip if absent.
        const extras_subpath = try std.fmt.allocPrint(ctx.allocator, "rules/{s}.extras.xml", .{name});
        defer ctx.allocator.free(extras_subpath);
        if (ctx.open(extras_subpath)) |extras_of_| {
            var extras_of = extras_of_;
            defer extras_of.close();
            if (std.Io.Dir.cwd().readFileAlloc(ctx.io, extras_of.path, ctx.allocator, .unlimited)) |extra_bytes| {
                defer ctx.allocator.free(extra_bytes);
                self.mergeFromBuffer(extra_bytes) catch {};
            } else |_| {}
        }
        return self;
    }

    /// Parse extra_xml and APPEND its entries to this registry.
    fn mergeFromBuffer(self: *Registry, extra_xml: []const u8) !void {
        const arena = self.arena.allocator();
        const old_models = self.models;
        const old_layouts = self.layouts;
        const old_groups = self.option_groups;
        // Parse extras into self (overwrites self.models/layouts/option_groups with extras-only content).
        try parseXml(self, extra_xml);
        const new_models = try arena.alloc(Model, old_models.len + self.models.len);
        @memcpy(new_models[0..old_models.len], old_models);
        @memcpy(new_models[old_models.len..], self.models);
        self.models = new_models;
        const new_layouts = try arena.alloc(Layout, old_layouts.len + self.layouts.len);
        @memcpy(new_layouts[0..old_layouts.len], old_layouts);
        @memcpy(new_layouts[old_layouts.len..], self.layouts);
        self.layouts = new_layouts;
        const new_groups = try arena.alloc(OptionGroup, old_groups.len + self.option_groups.len);
        @memcpy(new_groups[0..old_groups.len], old_groups);
        @memcpy(new_groups[old_groups.len..], self.option_groups);
        self.option_groups = new_groups;
    }

    pub fn destroy(self: *Registry) void {
        const alloc = self.ctx.allocator;
        self.arena.deinit();
        alloc.destroy(self);
    }
};

fn dupeStr(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    return arena.dupe(u8, s);
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn parseXml(reg: *Registry, xml_bytes: []const u8) !void {
    const arena = reg.arena.allocator();
    const scratch_alloc = reg.ctx.allocator;

    var sr = xml.Reader.Static.init(scratch_alloc, xml_bytes, .{ .namespace_aware = false });
    defer sr.deinit();
    const r = &sr.interface;

    const Section = enum { none, models, layouts, options };
    var section: Section = .none;

    var in_model = false;
    var in_layout = false;
    var in_variant_list = false;
    var in_variant = false;
    var in_group = false;
    var in_option = false;
    var in_config_item = false;
    var in_lang_list = false;
    var in_country_list = false;

    // Which text field is being collected
    const TextField = enum { none, name, short_desc, desc, lang, vendor, country };
    var text_field: TextField = .none;

    // Scratch text accumulation buffer (freed at end)
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(scratch_alloc);

    // Current configItem fields being built
    var cur_name: []const u8 = "";
    var cur_short_desc: []const u8 = "";
    var cur_desc: []const u8 = "";
    var cur_langs: std.ArrayList([]const u8) = .empty;
    var cur_countries: std.ArrayList([]const u8) = .empty;
    var cur_vendor: []const u8 = "";
    var cur_allow_multiple = false;
    var cur_popularity: Popularity = .standard;

    // Saved configItems: outer = model/layout/group; inner = variant/option
    var outer_ci: ConfigItem = .{ .name = "", .short_description = "", .description = "", .languages = &.{} };
    var inner_ci: ConfigItem = .{ .name = "", .short_description = "", .description = "", .languages = &.{} };
    // Layout's saved item (outer_ci can be overwritten before layout closes)
    var layout_ci: ConfigItem = .{ .name = "", .short_description = "", .description = "", .languages = &.{} };

    var cur_variants: std.ArrayList(Variant) = .empty;
    var cur_options: std.ArrayList(Option) = .empty;

    // Top-level accumulators (arena-backed, frozen to slices at end)
    var models: std.ArrayList(Model) = .empty;
    var layouts: std.ArrayList(Layout) = .empty;
    var option_groups: std.ArrayList(OptionGroup) = .empty;

    while (true) {
        const node = try r.read();
        switch (node) {
            .eof => break,

            .element_start => {
                const name = r.elementName();

                if (std.mem.eql(u8, name, "modelList")) {
                    section = .models;
                } else if (std.mem.eql(u8, name, "layoutList")) {
                    section = .layouts;
                } else if (std.mem.eql(u8, name, "optionList")) {
                    section = .options;
                } else if (std.mem.eql(u8, name, "model") and section == .models) {
                    in_model = true;
                    cur_vendor = "";
                } else if (std.mem.eql(u8, name, "layout") and section == .layouts) {
                    in_layout = true;
                    layout_ci = .{ .name = "", .short_description = "", .description = "", .languages = &.{} };
                    cur_variants = .empty;
                } else if (std.mem.eql(u8, name, "variantList") and in_layout) {
                    in_variant_list = true;
                } else if (std.mem.eql(u8, name, "variant") and in_variant_list) {
                    in_variant = true;
                } else if (std.mem.eql(u8, name, "group") and section == .options) {
                    in_group = true;
                    cur_allow_multiple = false;
                    cur_options = .empty;
                    // Read allowMultipleSelection attribute
                    const count = r.attributeCount();
                    var ai: usize = 0;
                    while (ai < count) : (ai += 1) {
                        if (std.mem.eql(u8, r.attributeName(ai), "allowMultipleSelection")) {
                            const val = r.attributeValueRaw(ai);
                            cur_allow_multiple = std.ascii.eqlIgnoreCase(val, "true") or
                                std.ascii.eqlIgnoreCase(val, "yes");
                            break;
                        }
                    }
                } else if (std.mem.eql(u8, name, "option") and in_group) {
                    in_option = true;
                } else if (std.mem.eql(u8, name, "configItem")) {
                    in_config_item = true;
                    cur_name = "";
                    cur_short_desc = "";
                    cur_desc = "";
                    cur_langs = .empty;
                    cur_countries = .empty;
                    cur_popularity = .standard;
                    // Parse optional popularity="exotic" attribute
                    const attr_count = r.attributeCount();
                    var ai: usize = 0;
                    while (ai < attr_count) : (ai += 1) {
                        if (std.mem.eql(u8, r.attributeName(ai), "popularity")) {
                            if (std.mem.eql(u8, r.attributeValueRaw(ai), "exotic"))
                                cur_popularity = .exotic;
                            break;
                        }
                    }
                } else if (in_config_item) {
                    if (std.mem.eql(u8, name, "name")) {
                        text_buf.clearRetainingCapacity();
                        text_field = .name;
                    } else if (std.mem.eql(u8, name, "shortDescription")) {
                        text_buf.clearRetainingCapacity();
                        text_field = .short_desc;
                    } else if (std.mem.eql(u8, name, "description")) {
                        text_buf.clearRetainingCapacity();
                        text_field = .desc;
                    } else if (std.mem.eql(u8, name, "languageList")) {
                        in_lang_list = true;
                    } else if (std.mem.eql(u8, name, "iso639Id") and in_lang_list) {
                        text_buf.clearRetainingCapacity();
                        text_field = .lang;
                    } else if (std.mem.eql(u8, name, "countryList")) {
                        in_country_list = true;
                    } else if (std.mem.eql(u8, name, "iso3166Id") and in_country_list) {
                        text_buf.clearRetainingCapacity();
                        text_field = .country;
                    }
                } else if (std.mem.eql(u8, name, "vendor") and in_model and !in_config_item) {
                    text_buf.clearRetainingCapacity();
                    text_field = .vendor;
                }
            },

            .text => {
                if (text_field != .none) {
                    try text_buf.appendSlice(scratch_alloc, r.textRaw());
                }
            },

            .entity_reference => {
                if (text_field != .none) {
                    const ent = r.entityReferenceName();
                    if (xml.predefined_entities.get(ent)) |expanded| {
                        try text_buf.appendSlice(scratch_alloc, expanded);
                    }
                }
            },

            .character_reference => {
                if (text_field != .none) {
                    var cbuf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(r.characterReferenceChar(), &cbuf) catch 0;
                    try text_buf.appendSlice(scratch_alloc, cbuf[0..n]);
                }
            },

            .element_end => {
                const name = r.elementName();

                if (std.mem.eql(u8, name, "name") and text_field == .name) {
                    cur_name = try dupeStr(arena, trimmed(text_buf.items));
                    text_buf.clearRetainingCapacity();
                    text_field = .none;
                } else if (std.mem.eql(u8, name, "shortDescription") and text_field == .short_desc) {
                    cur_short_desc = try dupeStr(arena, trimmed(text_buf.items));
                    text_buf.clearRetainingCapacity();
                    text_field = .none;
                } else if (std.mem.eql(u8, name, "description") and text_field == .desc) {
                    cur_desc = try dupeStr(arena, trimmed(text_buf.items));
                    text_buf.clearRetainingCapacity();
                    text_field = .none;
                } else if (std.mem.eql(u8, name, "iso639Id") and text_field == .lang) {
                    const lang = try dupeStr(arena, trimmed(text_buf.items));
                    text_buf.clearRetainingCapacity();
                    text_field = .none;
                    try cur_langs.append(arena, lang);
                } else if (std.mem.eql(u8, name, "iso3166Id") and text_field == .country) {
                    const country = try dupeStr(arena, trimmed(text_buf.items));
                    text_buf.clearRetainingCapacity();
                    text_field = .none;
                    try cur_countries.append(arena, country);
                } else if (std.mem.eql(u8, name, "vendor") and text_field == .vendor) {
                    cur_vendor = try dupeStr(arena, trimmed(text_buf.items));
                    text_buf.clearRetainingCapacity();
                    text_field = .none;
                } else if (std.mem.eql(u8, name, "languageList")) {
                    in_lang_list = false;
                } else if (std.mem.eql(u8, name, "countryList")) {
                    in_country_list = false;
                } else if (std.mem.eql(u8, name, "configItem")) {
                    const ci: ConfigItem = .{
                        .name = cur_name,
                        .short_description = cur_short_desc,
                        .description = cur_desc,
                        .languages = cur_langs.items,
                        .countries = cur_countries.items,
                        .popularity = cur_popularity,
                    };
                    if (in_variant or in_option) {
                        inner_ci = ci;
                    } else if (in_layout and !in_variant_list) {
                        layout_ci = ci;
                    } else {
                        outer_ci = ci;
                    }
                    in_config_item = false;
                    cur_name = "";
                    cur_short_desc = "";
                    cur_desc = "";
                    cur_langs = .empty;
                    cur_countries = .empty;
                } else if (std.mem.eql(u8, name, "variant")) {
                    try cur_variants.append(arena, .{ .item = inner_ci });
                    in_variant = false;
                } else if (std.mem.eql(u8, name, "variantList")) {
                    in_variant_list = false;
                } else if (std.mem.eql(u8, name, "layout")) {
                    try layouts.append(arena, .{
                        .item = layout_ci,
                        .variants = cur_variants.items,
                    });
                    cur_variants = .empty;
                    in_layout = false;
                } else if (std.mem.eql(u8, name, "model")) {
                    try models.append(arena, .{
                        .item = outer_ci,
                        .vendor = cur_vendor,
                    });
                    cur_vendor = "";
                    in_model = false;
                } else if (std.mem.eql(u8, name, "option")) {
                    try cur_options.append(arena, .{ .item = inner_ci });
                    in_option = false;
                } else if (std.mem.eql(u8, name, "group")) {
                    try option_groups.append(arena, .{
                        .item = outer_ci,
                        .allow_multiple = cur_allow_multiple,
                        .options = cur_options.items,
                    });
                    cur_options = .empty;
                    in_group = false;
                } else if (std.mem.eql(u8, name, "modelList") or
                    std.mem.eql(u8, name, "layoutList") or
                    std.mem.eql(u8, name, "optionList"))
                {
                    section = .none;
                }
            },

            else => {},
        }
    }

    reg.models = models.items;
    reg.layouts = layouts.items;
    reg.option_groups = option_groups.items;
}

test "Registry.newFromBuffer: entity references decoded in description" {
    const xml_bytes =
        \\<xkbConfigRegistry>
        \\ <layoutList>
        \\  <layout><configItem><name>ba</name><description>Bosnian (A &amp; B)</description></configItem></layout>
        \\ </layoutList>
        \\</xkbConfigRegistry>
    ;
    const io = std.testing.io;
    const ctx = try @import("context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();
    const reg = try Registry.newFromBuffer(ctx, xml_bytes);
    defer reg.destroy();
    try std.testing.expectEqual(@as(usize, 1), reg.layouts.len);
    try std.testing.expectEqualStrings("ba", reg.layouts[0].item.name);
    try std.testing.expectEqualStrings("Bosnian (A & B)", reg.layouts[0].item.description);
}

test "Registry.newFromNames: reads file from include path and decodes entities" {
    const io = std.testing.io;
    const xml_data =
        \\<xkbConfigRegistry>
        \\ <modelList><model><configItem><name>pc105</name><description>Generic 105-key (A &amp; B)</description></configItem><vendor>Generic</vendor></model></modelList>
        \\ <layoutList>
        \\  <layout><configItem><name>us</name><shortDescription>en</shortDescription><description>English (US)</description>
        \\   <languageList><iso639Id>eng</iso639Id></languageList></configItem>
        \\   <variantList><variant><configItem><name>dvorak</name><description>English (Dvorak)</description></configItem></variant></variantList>
        \\  </layout>
        \\  <layout><configItem><name>de</name><description>German</description></configItem></layout>
        \\ </layoutList>
        \\ <optionList><group allowMultipleSelection="true"><configItem><name>grp</name><description>Switching</description></configItem>
        \\   <option><configItem><name>grp:alt_shift_toggle</name><description>Alt+Shift</description></configItem></option></group></optionList>
        \\</xkbConfigRegistry>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "rules");
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/evdev.xml", .data = xml_data });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];
    const ctx = try @import("context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();
    try ctx.includePathAppend(real);

    const reg = try Registry.newFromNames(ctx, "evdev");
    defer reg.destroy();

    try std.testing.expectEqual(@as(usize, 1), reg.models.len);
    try std.testing.expectEqualStrings("pc105", reg.models[0].item.name);
    try std.testing.expectEqualStrings("Generic 105-key (A & B)", reg.models[0].item.description);
    try std.testing.expectEqualStrings("Generic", reg.models[0].vendor);

    try std.testing.expectEqual(@as(usize, 2), reg.layouts.len);
    try std.testing.expectEqualStrings("us", reg.layouts[0].item.name);
    try std.testing.expectEqualStrings("English (US)", reg.layouts[0].item.description);
    try std.testing.expectEqual(@as(usize, 1), reg.layouts[0].variants.len);
    try std.testing.expectEqualStrings("dvorak", reg.layouts[0].variants[0].item.name);
    try std.testing.expectEqualStrings("de", reg.layouts[1].item.name);

    try std.testing.expectEqual(@as(usize, 1), reg.option_groups.len);
    try std.testing.expectEqualStrings("grp", reg.option_groups[0].item.name);
    try std.testing.expectEqual(true, reg.option_groups[0].allow_multiple);
    try std.testing.expectEqual(@as(usize, 1), reg.option_groups[0].options.len);
    try std.testing.expectEqualStrings("grp:alt_shift_toggle", reg.option_groups[0].options[0].item.name);
}

test "Registry.newFromBuffer: numeric character references decoded in description" {
    const xml_bytes =
        \\<xkbConfigRegistry>
        \\ <layoutList>
        \\  <layout><configItem><name>test</name><description>Don&#39;t</description></configItem></layout>
        \\  <layout><configItem><name>test2</name><description>Won&#x27;t</description></configItem></layout>
        \\ </layoutList>
        \\</xkbConfigRegistry>
    ;
    const io = std.testing.io;
    const ctx = try @import("context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();
    const reg = try Registry.newFromBuffer(ctx, xml_bytes);
    defer reg.destroy();
    try std.testing.expectEqual(@as(usize, 2), reg.layouts.len);
    try std.testing.expectEqualStrings("Don't", reg.layouts[0].item.description);
    try std.testing.expectEqualStrings("Won't", reg.layouts[1].item.description);
}

test "Registry.newFromBuffer: popularity attribute parsed" {
    const xml_bytes =
        \\<xkbConfigRegistry>
        \\ <layoutList>
        \\  <layout><configItem popularity="exotic"><name>xyz</name><description>Exotic layout</description></configItem></layout>
        \\  <layout><configItem><name>us</name><description>Standard</description></configItem></layout>
        \\ </layoutList>
        \\</xkbConfigRegistry>
    ;
    const io = std.testing.io;
    const ctx = try @import("context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();
    const reg = try Registry.newFromBuffer(ctx, xml_bytes);
    defer reg.destroy();
    try std.testing.expectEqual(@as(usize, 2), reg.layouts.len);
    try std.testing.expectEqual(Popularity.exotic, reg.layouts[0].item.popularity);
    try std.testing.expectEqual(Popularity.standard, reg.layouts[1].item.popularity);
}

test "Registry.newFromNames: error when file not found" {
    const io = std.testing.io;
    const ctx = try @import("context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();
    try std.testing.expectError(error.RegistryFileNotFound, Registry.newFromNames(ctx, "nonexistent"));
}

test "Registry.newFromBuffer: parses small xkbConfigRegistry" {
    const xml_bytes =
        \\<xkbConfigRegistry>
        \\ <modelList><model><configItem><name>pc105</name><description>Generic 105-key</description></configItem><vendor>Generic</vendor></model></modelList>
        \\ <layoutList>
        \\  <layout><configItem><name>us</name><shortDescription>en</shortDescription><description>English (US)</description>
        \\   <languageList><iso639Id>eng</iso639Id></languageList></configItem>
        \\   <variantList><variant><configItem><name>dvorak</name><description>English (Dvorak)</description></configItem></variant></variantList>
        \\  </layout>
        \\  <layout><configItem><name>de</name><description>German</description></configItem></layout>
        \\ </layoutList>
        \\ <optionList><group allowMultipleSelection="true"><configItem><name>grp</name><description>Switching</description></configItem>
        \\   <option><configItem><name>grp:alt_shift_toggle</name><description>Alt+Shift</description></configItem></option></group></optionList>
        \\</xkbConfigRegistry>
    ;

    const io = std.testing.io;
    const ctx = try @import("context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const reg = try Registry.newFromBuffer(ctx, xml_bytes);
    defer reg.destroy();

    try std.testing.expectEqual(@as(usize, 1), reg.models.len);
    try std.testing.expectEqualStrings("pc105", reg.models[0].item.name);
    try std.testing.expectEqualStrings("Generic", reg.models[0].vendor);

    try std.testing.expectEqual(@as(usize, 2), reg.layouts.len);
    try std.testing.expectEqualStrings("us", reg.layouts[0].item.name);
    try std.testing.expectEqualStrings("English (US)", reg.layouts[0].item.description);
    try std.testing.expectEqualStrings("en", reg.layouts[0].item.short_description);
    try std.testing.expectEqual(@as(usize, 1), reg.layouts[0].item.languages.len);
    try std.testing.expectEqualStrings("eng", reg.layouts[0].item.languages[0]);
    try std.testing.expectEqual(@as(usize, 1), reg.layouts[0].variants.len);
    try std.testing.expectEqualStrings("dvorak", reg.layouts[0].variants[0].item.name);
    try std.testing.expectEqualStrings("de", reg.layouts[1].item.name);
    try std.testing.expectEqual(@as(usize, 0), reg.layouts[1].variants.len);

    try std.testing.expectEqual(@as(usize, 1), reg.option_groups.len);
    try std.testing.expectEqualStrings("grp", reg.option_groups[0].item.name);
    try std.testing.expectEqual(true, reg.option_groups[0].allow_multiple);
    try std.testing.expectEqual(@as(usize, 1), reg.option_groups[0].options.len);
    try std.testing.expectEqualStrings("grp:alt_shift_toggle", reg.option_groups[0].options[0].item.name);
}

test "Registry.newFromBuffer: iso3166 country list parsed" {
    const xml_bytes =
        \\<xkbConfigRegistry>
        \\ <layoutList>
        \\  <layout><configItem><name>us</name><description>English (US)</description>
        \\   <countryList><iso3166Id>US</iso3166Id><iso3166Id>GB</iso3166Id></countryList>
        \\   <languageList><iso639Id>eng</iso639Id></languageList></configItem></layout>
        \\  <layout><configItem><name>de</name><description>German</description></configItem></layout>
        \\ </layoutList>
        \\</xkbConfigRegistry>
    ;
    const io = std.testing.io;
    const ctx = try @import("context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();
    const reg = try Registry.newFromBuffer(ctx, xml_bytes);
    defer reg.destroy();
    try std.testing.expectEqual(@as(usize, 2), reg.layouts.len);
    try std.testing.expectEqual(@as(usize, 2), reg.layouts[0].item.countries.len);
    try std.testing.expectEqualStrings("US", reg.layouts[0].item.countries[0]);
    try std.testing.expectEqualStrings("GB", reg.layouts[0].item.countries[1]);
    try std.testing.expectEqual(@as(usize, 1), reg.layouts[0].item.languages.len);
    try std.testing.expectEqualStrings("eng", reg.layouts[0].item.languages[0]);
    // Layout without countryList gets empty countries slice.
    try std.testing.expectEqual(@as(usize, 0), reg.layouts[1].item.countries.len);
}

test "Registry.newFromNames: extras.xml merged" {
    const io = std.testing.io;
    const main_xml =
        \\<xkbConfigRegistry>
        \\ <layoutList>
        \\  <layout><configItem><name>us</name><description>English (US)</description></configItem></layout>
        \\ </layoutList>
        \\</xkbConfigRegistry>
    ;
    const extras_xml =
        \\<xkbConfigRegistry>
        \\ <layoutList>
        \\  <layout><configItem><name>exotic</name><description>Exotic layout</description></configItem></layout>
        \\ </layoutList>
        \\</xkbConfigRegistry>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "rules");
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/mytest.xml", .data = main_xml });
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/mytest.extras.xml", .data = extras_xml });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];
    const ctx = try @import("context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();
    try ctx.includePathAppend(real);
    const reg = try Registry.newFromNames(ctx, "mytest");
    defer reg.destroy();
    // Both main and extras layouts must be present.
    try std.testing.expectEqual(@as(usize, 2), reg.layouts.len);
    try std.testing.expectEqualStrings("us", reg.layouts[0].item.name);
    try std.testing.expectEqualStrings("exotic", reg.layouts[1].item.name);
}
