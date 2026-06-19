const std = @import("std");
const PyObject = @import("object.zig").PyObject;
const PyTypeObject = @import("object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;

pub const PyCellObject = extern struct {
    base: PyObject,
    value: ?*PyObject,
    
    pub fn create(value: ?*PyObject, mm: *PyMemoryManager) !*PyCellObject {
        const obj = try mm.alloc(PyCellObject);
        obj.* = .{
            .base = PyObject.init(&PyCell_Type),
            .value = value,
        };
        if (value) |val| val.incRef();
        return obj;
    }
};

pub const PyCell_Type = PyTypeObject{
    .name = "cell",
    .tp_dealloc = cell_dealloc,
    .tp_repr = cell_repr,
    .tp_str = cell_repr,
};

fn cell_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyCellObject);
    if (obj.value) |val| val.decRef(mm);
    mm.free(PyCellObject, obj);
}

fn cell_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyCellObject);
    const primitives = @import("primitives.zig");
    const PyStringObject = primitives.PyStringObject;
    var buf: [128]u8 = undefined;
    const repr_str = if (obj.value) |val|
        std.fmt.bufPrint(&buf, "<cell at 0x{x}: {s} object>", .{@intFromPtr(obj), val.type_obj.name}) catch "<cell>"
    else
        "<cell: empty>";
    return try PyStringObject.create(repr_str, mm);
}
