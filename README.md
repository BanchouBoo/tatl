# Tatl
Library for deserializing Aseprite files for usage in game development, image editors, etc.

Made for Aseprite v1.2.x, there is no guarantee this library will work with files made in other versions of Aseprite.

You can view the Aseprite file spec [here](https://github.com/aseprite/aseprite/blob/master/docs/ase-file-specs.md).

## Example
```zig
const std = @import("std");
const tatl = @import("tatl.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var file = try std.fs.openFileAbsolute("/path/to/file.ase", .{});
    const aseprite_import = try tatl.import(allocator, file.reader());
    // do stuff with import data
    aseprite_import.free(allocator);
}
```

## Plans
* Add file serialization, current roadblock for this is the lack of zlib compression in the Zig standard library (https://github.com/ziglang/zig/issues/213)
* Update to support the new and changed data for Aseprite v1.3
