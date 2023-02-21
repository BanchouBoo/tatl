const std = @import("std");

pub fn build(b: *std.Build) void {
    b.addModule(.{
        .name = "tatl",
        .source_file = std.Build.FileSource.relative("tatl.zig"),
        .dependencies = &[_]std.Build.ModuleDependency{},
    });
}
