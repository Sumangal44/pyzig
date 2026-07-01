const std = @import("std");
const PyObject = @import("object.zig").PyObject;
const PyTypeObject = @import("object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyStringObject = @import("primitives.zig").PyStringObject;
const PyListObject = @import("collections.zig").PyListObject;
const PyNone = @import("primitives.zig").PyNone;

pub const PyFileObject = struct {
    base: PyObject,
    file: std.Io.File,
    io: std.Io,
    is_closed: bool,
    mode: [8]u8,
    mode_len: usize,
    pos: u64,

    pub fn create(file: std.Io.File, io: std.Io, mode: []const u8, pos: u64, mm: *PyMemoryManager) !*PyFileObject {
        const obj = try mm.alloc(PyFileObject);
        obj.* = .{
            .base = PyObject.init(&PyFile_Type),
            .file = file,
            .io = io,
            .is_closed = false,
            .mode = undefined,
            .mode_len = mode.len,
            .pos = pos,
        };
        @memcpy(obj.mode[0..mode.len], mode);
        return obj;
    }
};

pub const PyFile_Type = PyTypeObject{
    .name = "file",
    .tp_dealloc = file_dealloc,
    .tp_repr = file_repr,
    .tp_str = file_repr,
};

fn file_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyFileObject);
    if (!obj.is_closed) {
        obj.file.close(obj.io);
    }
    mm.free(PyFileObject, obj);
}

fn file_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyFileObject);
    var buf: [256]u8 = undefined;
    const repr_str = try std.fmt.bufPrint(&buf, "<_io.TextIOWrapper name='file' mode='{s}' encoding='UTF-8'>", .{obj.mode[0..obj.mode_len]});
    return try PyStringObject.create(repr_str, mm);
}

pub fn fileReadMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != &PyFile_Type) return error.TypeError;
    const obj = self_obj.as(PyFileObject);
    if (obj.is_closed) return error.ValueError;

    const len = try obj.file.length(obj.io);
    if (obj.pos >= len) {
        return try PyStringObject.create("", vm.mm);
    }
    const read_len = len - obj.pos;
    const content = try vm.allocator.alloc(u8, read_len);
    defer vm.allocator.free(content);

    _ = try obj.file.readPositionalAll(obj.io, content, obj.pos);
    obj.pos += read_len;

    return try PyStringObject.create(content, vm.mm);
}

pub fn fileWriteMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const str_arg = args[1];
    if (self_obj.type_obj != &PyFile_Type) return error.TypeError;
    if (str_arg.type_obj != &@import("primitives.zig").PyString_Type) return error.TypeError;
    const obj = self_obj.as(PyFileObject);
    if (obj.is_closed) return error.ValueError;

    const data = str_arg.as(PyStringObject).value();
    try obj.file.writePositionalAll(obj.io, data, obj.pos);
    obj.pos += data.len;

    return try @import("primitives.zig").PyIntObject.create(@as(i64, @intCast(data.len)), vm.mm);
}

pub fn fileCloseMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != &PyFile_Type) return error.TypeError;
    const obj = self_obj.as(PyFileObject);
    if (!obj.is_closed) {
        obj.file.close(obj.io);
        obj.is_closed = true;
    }
    PyNone.incRef();
    return PyNone;
}

pub fn fileReadlinesMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != &PyFile_Type) return error.TypeError;
    const obj = self_obj.as(PyFileObject);
    if (obj.is_closed) return error.ValueError;

    const list = try PyListObject.create(0, vm.mm);
    errdefer list.base.decRef(vm.mm);

    const len = try obj.file.length(obj.io);
    if (obj.pos >= len) {
        return &list.base;
    }
    const read_len = len - obj.pos;
    const content = try vm.allocator.alloc(u8, read_len);
    defer vm.allocator.free(content);

    _ = try obj.file.readPositionalAll(obj.io, content, obj.pos);
    obj.pos += read_len;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const has_newline = it.index != null;
        const line_str = if (has_newline) blk: {
            const line_nl = try vm.allocator.alloc(u8, line.len + 1);
            defer vm.allocator.free(line_nl);
            @memcpy(line_nl[0..line.len], line);
            line_nl[line.len] = '\n';
            break :blk try PyStringObject.create(line_nl, vm.mm);
        } else blk: {
            if (line.len == 0) break :blk null;
            break :blk try PyStringObject.create(line, vm.mm);
        };
        if (line_str) |s| {
            defer s.decRef(vm.mm);
            try list.append(s, vm.mm);
        }
    }
    return &list.base;
}

pub fn fileWritelinesMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const list_arg = args[1];
    if (self_obj.type_obj != &PyFile_Type) return error.TypeError;
    if (list_arg.type_obj != &@import("collections.zig").PyList_Type) return error.TypeError;
    const obj = self_obj.as(PyFileObject);
    if (obj.is_closed) return error.ValueError;

    const list = list_arg.as(PyListObject);
    if (list.size > 0) {
        for (0..list.size) |i| {
            const item = list.items.?[i];
            if (item.type_obj != &@import("primitives.zig").PyString_Type) return error.TypeError;
            const data = item.as(PyStringObject).value();
            try obj.file.writePositionalAll(obj.io, data, obj.pos);
            obj.pos += data.len;
        }
    }

    PyNone.incRef();
    return PyNone;
}

pub fn fileEnterMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != &PyFile_Type) return error.TypeError;
    self_obj.incRef();
    return self_obj;
}

pub fn fileExitMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 4) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != &PyFile_Type) return error.TypeError;
    const obj = self_obj.as(PyFileObject);
    if (!obj.is_closed) {
        obj.file.close(obj.io);
        obj.is_closed = true;
    }
    const PyFalse = @import("primitives.zig").PyFalse;
    PyFalse.incRef();
    return PyFalse;
}
