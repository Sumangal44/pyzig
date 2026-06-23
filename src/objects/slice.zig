const std = @import("std");
const testing = std.testing;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyObject = @import("object.zig").PyObject;
const PyTypeObject = @import("object.zig").PyTypeObject;
const primitives = @import("primitives.zig");
const PyNone = primitives.PyNone;
const PyTrue = primitives.PyTrue;
const PyFalse = primitives.PyFalse;
const PyStringObject = primitives.PyStringObject;
const PyIntObject = primitives.PyIntObject;

pub const PySliceObject = extern struct {
    base: PyObject,
    start: ?*PyObject,
    stop: ?*PyObject,
    step: ?*PyObject,

    pub fn create(start: ?*PyObject, stop: ?*PyObject, step: ?*PyObject, mm: *PyMemoryManager) !*PySliceObject {
        const obj = try mm.alloc(PySliceObject);
        if (start) |s| s.incRef();
        if (stop) |s| s.incRef();
        if (step) |s| s.incRef();
        obj.* = .{
            .base = PyObject.init(&PySlice_Type),
            .start = start,
            .stop = stop,
            .step = step,
        };
        return obj;
    }

    pub fn computeIndices(self: *PySliceObject, length: i64) struct { start: i64, stop: i64, step: i64 } {
        const step = if (self.step) |s| blk: {
            if (std.mem.eql(u8, s.type_obj.name, "int")) {
                break :blk s.as(PyIntObject).value;
            }
            break :blk 1;
        } else 1;

        const start = if (self.start) |s| blk: {
            if (std.mem.eql(u8, s.type_obj.name, "int")) {
                var v = s.as(PyIntObject).value;
                if (v < 0) v += length;
                if (v < 0) v = 0;
                if (v > length) v = length;
                break :blk v;
            }
            break :blk if (step > 0) 0 else length - 1;
        } else if (step > 0) 0 else length - 1;

        const stop = if (self.stop) |s| blk: {
            if (std.mem.eql(u8, s.type_obj.name, "int")) {
                var v = s.as(PyIntObject).value;
                if (v < 0) v += length;
                if (v < 0) v = 0;
                if (v > length) v = length;
                break :blk v;
            }
            break :blk if (step > 0) length else -1;
        } else if (step > 0) length else -1;

        return .{ .start = start, .stop = stop, .step = step };
    }

    pub fn applyToSlice(self: *PySliceObject, length: i64) struct { indices: []i64, count: usize } {
        const info = self.computeIndices(length);
        const step = info.step;
        const start = info.start;
        const stop = info.stop;

        var count: usize = 0;
        if (step > 0) {
            if (start < stop) {
                count = @intCast((stop - start + step - 1) / step);
            }
        } else if (step < 0) {
            if (start > stop) {
                count = @intCast((start - stop - step - 1) / -step);
            }
        }

        return .{ .indices = undefined, .count = count };
    }
};

pub const PySlice_Type = PyTypeObject{
    .name = "slice",
    .tp_dealloc = slice_dealloc,
    .tp_repr = slice_repr,
    .tp_str = slice_repr,
};

fn slice_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PySliceObject);
    if (obj.start) |s| s.decRef(mm);
    if (obj.stop) |s| s.decRef(mm);
    if (obj.step) |s| s.decRef(mm);
    mm.free(PySliceObject, obj);
}

fn slice_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PySliceObject);
    _ = obj;
    return try PyStringObject.create("slice(...)", mm);
}
