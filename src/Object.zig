const std = @import("std");
const Compilation = @import("Compilation.zig");
const Elf = @import("object/Elf.zig");

const Object = @This();

format: std.Target.ObjectFormat,
comp: *Compilation,

pub fn create(comp: *Compilation) !*Object {
    switch (comp.target.getObjectFormat()) {
        .elf => return Elf.create(comp),
        else => unreachable,
    }
}

pub fn deinit(obj: *Object) void {
    switch (obj.format) {
        .elf => @fieldParentPtr(Elf, "obj", obj).deinit(),
        else => unreachable,
    }
}

pub const Section = union(enum) {
    @"undefined",
    data,
    read_only_data,
    func,
    strings,
    custom: []const u8,
};

pub fn getSection(obj: *Object, section: Section) !*std.ArrayList(u8) {
    switch (obj.format) {
        .elf => return @fieldParentPtr(Elf, "obj", obj).getSection(section),
        else => unreachable,
    }
}

pub const SymbolType = enum {
    func,
    variable,
    external,
};

pub fn declareSymbol(
    obj: *Object,
    section: Section,
    name: ?[]const u8,
    linkage: std.builtin.GlobalLinkage,
    @"type": SymbolType,
    offset: u64,
    size: u64,
) ![]const u8 {
    switch (obj.format) {
        .elf => return @fieldParentPtr(Elf, "obj", obj).declareSymbol(section, name, linkage, @"type", offset, size),
        else => unreachable,
    }
}

pub fn addRelocation(obj: *Object, name: []const u8, section: Section, address: u64, addend: i64) !void {
    switch (obj.format) {
        .elf => return @fieldParentPtr(Elf, "obj", obj).addRelocation(name, section, address, addend),
        else => unreachable,
    }
}

pub fn finish(obj: *Object, file: std.fs.File) !void {
    switch (obj.format) {
        .elf => return @fieldParentPtr(Elf, "obj", obj).finish(file),
        else => unreachable,
    }
}
