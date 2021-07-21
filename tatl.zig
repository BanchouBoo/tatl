const std = @import("std");
const zlib = std.compress.zlib;

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const File = std.fs.File;
const Reader = File.Reader;

pub const AsepriteImportError = error{
    InvalidFile,
    InvalidFrameHeader,
};

pub const ChunkType = enum(u16) {
    OldPaletteA = 0x0004,
    OldPaletteB = 0x0011,
    Layer = 0x2004,
    Cel = 0x2005,
    CelExtra = 0x2006,
    ColorProfile = 0x2007,
    Mask = 0x2016,
    Path = 0x2017,
    Tags = 0x2018,
    Palette = 0x2019,
    UserData = 0x2020,
    Slices = 0x2022,
    Tileset = 0x2023,
    _,
};

pub const ColorDepth = enum(u16) {
    indexed = 8,
    grayscale = 16,
    rgba = 32,
};

pub const PaletteFlags = packed struct {
    has_name: bool,

    padding: u15 = 0,
};

pub const RGBA = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn deserializeOld(reader: Reader) !RGBA {
        return RGBA{
            .r = try reader.readIntLittle(u8),
            .g = try reader.readIntLittle(u8),
            .b = try reader.readIntLittle(u8),
            .a = 255,
        };
    }

    pub fn deserializeNew(reader: Reader) !RGBA {
        return RGBA{
            .r = try reader.readIntLittle(u8),
            .g = try reader.readIntLittle(u8),
            .b = try reader.readIntLittle(u8),
            .a = try reader.readIntLittle(u8),
        };
    }

    pub fn format(self: RGBA, comptime fmt: []const u8, options: std.fmt.FormatOptions, stream: anytype) !void {
        _ = fmt;
        _ = options;
        try stream.print("RGBA({d:>3}, {d:>3}, {d:>3}, {d:>3})", .{ self.r, self.g, self.b, self.a });
    }
};

pub const Palette = struct {
    colors: []RGBA,
    /// index for transparent color in indexed sprites
    transparent_index: u8,
    names: [][]const u8,

    pub fn deserializeOld(prev_pal: Palette, reader: Reader) !Palette {
        var pal = prev_pal;

        const packets = try reader.readIntLittle(u16);
        var skip: usize = 0;

        var i: u16 = 0;
        while (i < packets) : (i += 1) {
            skip += try reader.readIntLittle(u8);
            const size: u16 = val: {
                const s = try reader.readIntLittle(u8);
                break :val if (s == 0) @as(u16, 256) else s;
            };

            for (pal.colors[skip .. skip + size]) |*entry, j| {
                entry.* = try RGBA.deserializeOld(reader);
                pal.names[skip + j] = "";
            }
        }

        return pal;
    }

    pub fn deserializeNew(prev_pal: Palette, allocator: *Allocator, reader: Reader) !Palette {
        var pal = prev_pal;

        const size = try reader.readIntLittle(u32);
        if (pal.colors.len != size) {
            pal.colors = try allocator.realloc(pal.colors, size);
            pal.names = try allocator.realloc(pal.names, size);
        }
        const from = try reader.readIntLittle(u32);
        const to = try reader.readIntLittle(u32);

        try reader.skipBytes(8, .{});

        for (pal.colors[from .. to + 1]) |*entry, i| {
            const flags = try reader.readStruct(PaletteFlags);
            entry.* = try RGBA.deserializeNew(reader);
            if (flags.has_name)
                pal.names[from + i] = try readSlice(u8, u16, allocator, reader)
            else
                pal.names[from + i] = "";
        }

        return pal;
    }
};

pub const LayerFlags = packed struct {
    visible: bool,
    editable: bool,
    lock_movement: bool,
    background: bool,
    prefer_linked_cels: bool,
    collapsed: bool,
    reference: bool,

    padding: u9 = 0,
};

pub const LayerType = enum(u16) {
    normal,
    group,
    tilemap,
};

pub const LayerBlendMode = enum(u16) {
    normal,
    multiply,
    screen,
    overlay,
    darken,
    lighten,
    color_dodge,
    color_burn,
    hard_light,
    soft_light,
    difference,
    exclusion,
    hue,
    saturation,
    color,
    luminosity,
    addition,
    subtract,
    divide,
};

pub const Layer = struct {
    flags: LayerFlags,
    type: LayerType,
    child_level: u16,
    blend_mode: LayerBlendMode,
    opacity: u8,
    name: []const u8,
    user_data: UserData,

    pub fn deserialize(allocator: *Allocator, reader: Reader) !Layer {
        var result: Layer = undefined;
        result.flags = try reader.readStruct(LayerFlags);
        result.type = try reader.readEnum(LayerType, .Little);
        result.child_level = try reader.readIntLittle(u16);
        try reader.skipBytes(4, .{});
        result.blend_mode = try reader.readEnum(LayerBlendMode, .Little);
        result.opacity = try reader.readIntLittle(u8);
        try reader.skipBytes(3, .{});
        result.name = try readSlice(u8, u16, allocator, reader);
        result.user_data = UserData{ .text = "", .color = [4]u8{ 0, 0, 0, 0 } };
        return result;
    }
};

pub const ImageCel = struct {
    width: u16,
    height: u16,
    pixels: []u8,

    pub fn deserialize(
        color_depth: ColorDepth,
        compressed: bool,
        allocator: *Allocator,
        reader: Reader,
    ) !ImageCel {
        var result: ImageCel = undefined;
        result.width = try reader.readIntLittle(u16);
        result.height = try reader.readIntLittle(u16);

        const size = @intCast(usize, result.width) *
            @intCast(usize, result.height) *
            @intCast(usize, @enumToInt(color_depth) / 8);
        result.pixels = try allocator.alloc(u8, size);
        errdefer allocator.free(result.pixels);

        if (compressed) {
            var zlib_stream = try zlib.zlibStream(allocator, reader);
            defer zlib_stream.deinit();
            _ = try zlib_stream.reader().readAll(result.pixels);
        } else {
            try reader.readNoEof(result.pixels);
        }

        return result;
    }
};

pub const LinkedCel = struct {
    frame: u16,

    pub fn deserialize(reader: Reader) !LinkedCel {
        return LinkedCel{ .frame = try reader.readIntLittle(u16) };
    }
};

pub const CelType = enum(u16) {
    raw_image,
    linked,
    compressed_image,
    compressed_tilemap,
};

pub const CelData = union(CelType) {
    raw_image: ImageCel,
    linked: LinkedCel,
    compressed_image: ImageCel,
    compressed_tilemap: void,
};

pub const Cel = struct {
    layer: u16,
    x: i16,
    y: i16,
    opacity: u8,
    data: CelData,
    extra: CelExtra,
    user_data: UserData,

    pub fn deserialize(color_depth: ColorDepth, allocator: *Allocator, reader: Reader) !Cel {
        var result: Cel = undefined;
        result.layer = try reader.readIntLittle(u16);
        result.x = try reader.readIntLittle(i16);
        result.y = try reader.readIntLittle(i16);
        result.opacity = try reader.readIntLittle(u8);

        const cel_type = try reader.readEnum(CelType, .Little);
        try reader.skipBytes(7, .{});
        result.data = switch (cel_type) {
            .raw_image => CelData{
                .raw_image = try ImageCel.deserialize(color_depth, false, allocator, reader),
            },
            .linked => CelData{
                .linked = try LinkedCel.deserialize(reader),
            },
            .compressed_image => CelData{
                .compressed_image = try ImageCel.deserialize(color_depth, true, allocator, reader),
            },
            .compressed_tilemap => CelData{
                .compressed_tilemap = void{},
            },
        };

        result.extra = CelExtra{ .x = 0, .y = 0, .width = 0, .height = 0 };
        result.user_data = UserData{ .text = "", .color = [4]u8{ 0, 0, 0, 0 } };

        return result;
    }
};

pub const CelExtraFlags = packed struct {
    precise_bounds: bool,

    padding: u31 = 0,
};

/// This contains values stored in fixed point numbers stored in u32's, do not try to use these values directly
pub const CelExtra = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn isEmpty(self: CelExtra) bool {
        return @bitCast(u128, self) == 0;
    }

    pub fn deserialize(reader: Reader) !CelExtra {
        const flags = try reader.readStruct(CelExtraFlags);
        if (flags.precise_bounds) {
            return CelExtra{
                .x = try reader.readIntLittle(u32),
                .y = try reader.readIntLittle(u32),
                .width = try reader.readIntLittle(u32),
                .height = try reader.readIntLittle(u32),
            };
        } else {
            return CelExtra{
                .x = 0,
                .y = 0,
                .width = 0,
                .height = 0,
            };
        }
    }
};

pub const ColorProfileType = enum(u16) {
    none,
    srgb,
    icc,
};

pub const ColorProfileFlags = packed struct {
    special_fixed_gamma: bool,

    padding: u15 = 0,
};

pub const ColorProfile = struct {
    type: ColorProfileType,
    flags: ColorProfileFlags,
    /// this is a fixed point value stored in a u32, do not try to use it directly
    gamma: u32,
    icc_data: []const u8,

    pub fn deserialize(allocator: *Allocator, reader: Reader) !ColorProfile {
        var result: ColorProfile = undefined;
        result.type = try reader.readEnum(ColorProfileType, .Little);
        result.flags = try reader.readStruct(ColorProfileFlags);
        result.gamma = try reader.readIntLittle(u32);
        try reader.skipBytes(8, .{});
        // zig fmt: off
        result.icc_data = if (result.type == .icc)
                              try readSlice(u8, u32, allocator, reader)
                          else
                              &[0]u8{};
        // zig fmt: on
        return result;
    }
};

pub const AnimationDirection = enum(u8) {
    forward,
    reverse,
    pingpong,
};

pub const Tag = struct {
    from: u16,
    to: u16,
    direction: AnimationDirection,
    color: [3]u8,
    name: []const u8,

    pub fn deserialize(allocator: *Allocator, reader: Reader) !Tag {
        var result: Tag = undefined;
        result.from = try reader.readIntLittle(u16);
        result.to = try reader.readIntLittle(u16);
        result.direction = try reader.readEnum(AnimationDirection, .Little);
        try reader.skipBytes(8, .{});
        result.color = try reader.readBytesNoEof(3);
        try reader.skipBytes(1, .{});
        result.name = try readSlice(u8, u16, allocator, reader);
        return result;
    }

    pub fn deserializeAll(allocator: *Allocator, reader: Reader) ![]Tag {
        const len = try reader.readIntLittle(u16);
        try reader.skipBytes(8, .{});
        const result = try allocator.alloc(Tag, len);
        errdefer allocator.free(result);
        for (result) |*tag| {
            tag.* = try Tag.deserialize(allocator, reader);
        }
        return result;
    }
};

pub const UserDataFlags = packed struct {
    has_text: bool,
    has_color: bool,

    padding: u14 = 0,
};

pub const UserData = struct {
    text: []const u8,
    color: [4]u8,

    pub const empty = UserData{ .text = "", .color = [4]u8{ 0, 0, 0, 0 } };

    pub fn isEmpty(user_data: UserData) bool {
        return user_data.text.len == 0 and @bitCast(u32, user_data.color) == 0;
    }

    pub fn deserialize(allocator: *Allocator, reader: Reader) !UserData {
        var result: UserData = undefined;
        const flags = try reader.readStruct(UserDataFlags);
        // zig fmt: off
        result.text = if (flags.has_text)
                          try readSlice(u8, u16, allocator, reader)
                      else
                          "";
        result.color = if (flags.has_color)
                           try reader.readBytesNoEof(4)
                       else
                           [4]u8{ 0, 0, 0, 0 };
        // zig fmt: on
        return result;
    }
};

const UserDataChunks = union(enum) {
    Layer: *Layer,
    Cel: *Cel,
    Slice: *Slice,

    pub fn new(pointer: anytype) UserDataChunks {
        const name = @typeName(@typeInfo(@TypeOf(pointer)).Pointer.child);
        return @unionInit(UserDataChunks, name, pointer);
    }

    pub fn setUserData(self: UserDataChunks, user_data: UserData) void {
        switch (self) {
            .Layer => |p| p.*.user_data = user_data,
            .Cel => |p| p.*.user_data = user_data,
            .Slice => |p| p.*.user_data = user_data,
        }
    }
};

pub const SliceFlags = packed struct {
    nine_patch: bool,
    has_pivot: bool,

    padding: u30 = 0,
};

pub const SliceKey = struct {
    frame: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    center: struct {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
    },
    pivot: struct {
        x: i32,
        y: i32,
    },

    pub fn deserialize(flags: SliceFlags, reader: Reader) !SliceKey {
        var result: SliceKey = undefined;
        result.frame = try reader.readIntLittle(u32);
        result.x = try reader.readIntLittle(i32);
        result.y = try reader.readIntLittle(i32);
        result.width = try reader.readIntLittle(u32);
        result.height = try reader.readIntLittle(u32);
        result.center = if (flags.nine_patch) .{
            .x = try reader.readIntLittle(i32),
            .y = try reader.readIntLittle(i32),
            .width = try reader.readIntLittle(u32),
            .height = try reader.readIntLittle(u32),
        } else .{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
        };
        result.pivot = if (flags.has_pivot) .{
            .x = try reader.readIntLittle(i32),
            .y = try reader.readIntLittle(i32),
        } else .{
            .x = 0,
            .y = 0,
        };
        return result;
    }
};

pub const Slice = struct {
    flags: SliceFlags,
    name: []const u8,
    keys: []SliceKey,
    user_data: UserData,

    pub fn deserialize(allocator: *Allocator, reader: Reader) !Slice {
        var result: Slice = undefined;
        const key_len = try reader.readIntLittle(u32);
        result.flags = try reader.readStruct(SliceFlags);
        try reader.skipBytes(4, .{});
        result.name = try readSlice(u8, u16, allocator, reader);
        errdefer allocator.free(result.name);
        result.keys = try allocator.alloc(SliceKey, key_len);
        errdefer allocator.free(result.keys);
        for (result.keys) |*key| {
            key.* = try SliceKey.deserialize(result.flags, reader);
        }
        result.user_data = UserData{ .text = "", .color = [4]u8{ 0, 0, 0, 0 } };
        return result;
    }
};

pub const Frame = struct {
    /// frame duration in miliseconds
    duration: u16,
    /// images contained within the frame
    cels: []Cel,

    pub const magic: u16 = 0xF1FA;
};

pub const FileHeaderFlags = packed struct {
    layer_with_opacity: bool,

    padding: u31 = 0,
};

pub const AsepriteImport = struct {
    width: u16,
    height: u16,
    color_depth: ColorDepth,
    flags: FileHeaderFlags,
    pixel_width: u8,
    pixel_height: u8,
    grid_x: i16,
    grid_y: i16,
    /// zero if no grid
    grid_width: u16,
    /// zero if no grid
    grid_height: u16,
    palette: Palette,
    color_profile: ColorProfile,
    layers: []Layer,
    slices: []Slice,
    tags: []Tag,
    frames: []Frame,

    pub const magic: u16 = 0xA5E0;

    pub fn deserialize(allocator: *Allocator, reader: Reader) !AsepriteImport {
        var result: AsepriteImport = undefined;
        try reader.skipBytes(4, .{});
        if (magic != try reader.readIntLittle(u16)) {
            return error.InvalidFile;
        }
        const frame_count = try reader.readIntLittle(u16);
        result.width = try reader.readIntLittle(u16);
        result.height = try reader.readIntLittle(u16);
        result.color_depth = try reader.readEnum(ColorDepth, .Little);
        result.flags = try reader.readStruct(FileHeaderFlags);
        try reader.skipBytes(10, .{});
        const transparent_index = try reader.readIntLittle(u8);
        try reader.skipBytes(3, .{});
        var color_count = try reader.readIntLittle(u16);
        result.pixel_width = try reader.readIntLittle(u8);
        result.pixel_height = try reader.readIntLittle(u8);
        result.grid_x = try reader.readIntLittle(i16);
        result.grid_y = try reader.readIntLittle(i16);
        result.grid_width = try reader.readIntLittle(u16);
        result.grid_height = try reader.readIntLittle(u16);

        if (color_count == 0)
            color_count = 256;

        if (result.pixel_width == 0 or result.pixel_height == 0) {
            result.pixel_width = 1;
            result.pixel_height = 1;
        }

        try reader.skipBytes(84, .{});

        result.palette = Palette{
            .colors = try allocator.alloc(RGBA, color_count),
            .transparent_index = transparent_index,
            .names = try allocator.alloc([]const u8, color_count),
        };
        errdefer {
            allocator.free(result.palette.colors);
            allocator.free(result.palette.names);
        }
        result.frames = try allocator.alloc(Frame, frame_count);
        errdefer allocator.free(result.frames);

        var layers = try ArrayListUnmanaged(Layer).initCapacity(allocator, 1);
        errdefer layers.deinit(allocator);
        var slices = try ArrayListUnmanaged(Slice).initCapacity(allocator, 0);
        errdefer slices.deinit(allocator);
        var using_new_palette = false;
        var last_with_user_data: ?UserDataChunks = null;

        for (result.frames) |*frame| {
            var cels = try ArrayListUnmanaged(Cel).initCapacity(allocator, 0);
            errdefer cels.deinit(allocator);
            var last_cel: ?*Cel = null;

            try reader.skipBytes(4, .{});
            if (Frame.magic != try reader.readIntLittle(u16)) {
                return error.InvalidFrameHeader;
            }
            const old_chunks = try reader.readIntLittle(u16);
            frame.duration = try reader.readIntLittle(u16);
            try reader.skipBytes(2, .{});
            const new_chunks = try reader.readIntLittle(u32);
            const chunks = if (old_chunks == 0xFFFF and old_chunks < new_chunks)
                new_chunks
            else
                old_chunks;

            var i: u32 = 0;
            while (i < chunks) : (i += 1) {
                const chunk_start = try reader.context.getPos();
                const chunk_size = try reader.readIntLittle(u32);
                const chunk_end = chunk_start + chunk_size;

                const chunk_type = try reader.readEnum(ChunkType, .Little);
                switch (chunk_type) {
                    .OldPaletteA, .OldPaletteB => {
                        if (!using_new_palette)
                            result.palette = try Palette.deserializeOld(result.palette, reader);
                    },
                    .Layer => {
                        try layers.append(allocator, try Layer.deserialize(allocator, reader));
                        last_with_user_data = UserDataChunks.new(&layers.items[layers.items.len - 1]);
                    },
                    .Cel => {
                        try cels.append(
                            allocator,
                            try Cel.deserialize(
                                result.color_depth,
                                allocator,
                                reader,
                            ),
                        );
                        last_cel = &cels.items[cels.items.len - 1];
                        last_with_user_data = UserDataChunks.new(last_cel.?);
                    },
                    .CelExtra => {
                        const extra = try CelExtra.deserialize(reader);
                        if (last_cel) |c| {
                            c.extra = extra;
                            last_cel = null;
                        } else {
                            std.log.err("{s}\n", .{"Found extra cel chunk without cel to attach it to!"});
                        }
                    },
                    .ColorProfile => {
                        result.color_profile = try ColorProfile.deserialize(allocator, reader);
                    },
                    .Tags => {
                        result.tags = try Tag.deserializeAll(allocator, reader);
                    },
                    .Palette => {
                        using_new_palette = true;
                        result.palette = try Palette.deserializeNew(
                            result.palette,
                            allocator,
                            reader,
                        );
                    },
                    .UserData => {
                        const user_data = try UserData.deserialize(allocator, reader);
                        if (last_with_user_data) |chunk| {
                            chunk.setUserData(user_data);
                            last_with_user_data = null;
                        } else {
                            std.log.err("{s}\n", .{"Found user data chunk without chunk to attach it to!"});
                        }
                    },
                    .Slices => {
                        try slices.append(allocator, try Slice.deserialize(allocator, reader));
                        last_with_user_data = UserDataChunks.new(&slices.items[slices.items.len - 1]);
                    },
                    else => std.log.err("{s}: {x}\n", .{ "Unsupported chunk type", chunk_type }),
                }
                try reader.context.seekTo(chunk_end);
            }

            frame.cels = cels.toOwnedSlice(allocator);
            errdefer allocator.free(frame.cels);
        }
        result.layers = layers.toOwnedSlice(allocator);
        result.slices = slices.toOwnedSlice(allocator);
        return result;
    }

    pub fn free(self: AsepriteImport, allocator: *Allocator) void {
        allocator.free(self.palette.colors);
        for (self.palette.names) |name| {
            if (name.len > 0)
                allocator.free(name);
        }
        allocator.free(self.palette.names);
        allocator.free(self.color_profile.icc_data);

        for (self.layers) |layer| {
            allocator.free(layer.name);
            allocator.free(layer.user_data.text);
        }
        allocator.free(self.layers);

        for (self.slices) |slice| {
            allocator.free(slice.name);
            allocator.free(slice.keys);
            allocator.free(slice.user_data.text);
        }
        allocator.free(self.slices);

        for (self.tags) |tag| {
            allocator.free(tag.name);
        }
        allocator.free(self.tags);

        for (self.frames) |frame| {
            for (frame.cels) |cel| {
                allocator.free(cel.user_data.text);
                switch (cel.data) {
                    .raw_image => |raw| allocator.free(raw.pixels),
                    .compressed_image => |compressed| allocator.free(compressed.pixels),
                    else => {},
                }
            }
            allocator.free(frame.cels);
        }
        allocator.free(self.frames);
    }
};

fn readSlice(comptime SliceT: type, comptime LenT: type, allocator: *Allocator, reader: Reader) ![]SliceT {
    const len = (try reader.readIntLittle(LenT)) * @sizeOf(SliceT);
    var bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    try reader.readNoEof(bytes);
    return std.mem.bytesAsSlice(SliceT, bytes);
}

pub fn import(allocator: *Allocator, reader: Reader) !AsepriteImport {
    return AsepriteImport.deserialize(allocator, reader);
}
