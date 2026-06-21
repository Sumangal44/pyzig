const std = @import("std");
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyObject = @import("object.zig").PyObject;
const PyTypeObject = @import("object.zig").PyTypeObject;
const primitives = @import("primitives.zig");
const PyNone = primitives.PyNone;
const PyTrue = primitives.PyTrue;
const PyFalse = primitives.PyFalse;
const PyIntObject = primitives.PyIntObject;
const PyInt_Type = primitives.PyInt_Type;
const PyStringObject = primitives.PyStringObject;

/// Lazy range object — stores start/stop/step without materializing values.
pub const PyRangeObject = extern struct {
    base: PyObject,
    start: i64,
    stop: i64,
    step: i64,

    pub fn create(start: i64, stop: i64, step: i64, mm: *PyMemoryManager) !*PyRangeObject {
        const obj = try mm.alloc(PyRangeObject);
        obj.* = .{
            .base = PyObject.init(&PyRange_Type),
            .start = start,
            .stop = stop,
            .step = step,
        };
        return obj;
    }

    /// Number of elements in the range (0 if empty).
    pub fn len(self: *const PyRangeObject) usize {
        if (self.step > 0) {
            if (self.start >= self.stop) return 0;
            return @intCast(@divFloor(self.stop - self.start + self.step - 1, self.step));
        } else if (self.step < 0) {
            if (self.start <= self.stop) return 0;
            return @intCast(@divFloor(self.start - self.stop - self.step - 1, -self.step));
        }
        return 0;
    }

    /// Get the i-th element (zero-based).
    pub fn get(self: *const PyRangeObject, index: usize) i64 {
        return self.start + @as(i64, @intCast(index)) * self.step;
    }
};

pub const PyRange_Type = PyTypeObject{
    .name = "range",
    .tp_dealloc = range_dealloc,
    .tp_repr = range_repr,
    .tp_str = range_repr,
    .tp_bool = range_bool,
};

fn range_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyRangeObject);
    mm.free(PyRangeObject, obj);
}

fn range_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyRangeObject);
    if (obj.step == 1) {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "range({d}, {d})", .{ obj.start, obj.stop }) catch return error.ValueError;
        return try PyStringObject.create(s, mm);
    }
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "range({d}, {d}, {d})", .{ obj.start, obj.stop, obj.step }) catch return error.ValueError;
    return try PyStringObject.create(s, mm);
}

fn range_bool(self: *PyObject) bool {
    return self.as(PyRangeObject).len() > 0;
}
