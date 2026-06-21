const std = @import("std");
const PyObject = @import("object.zig").PyObject;
const PyTypeObject = @import("object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyStringObject = @import("primitives.zig").PyStringObject;

pub const PyExceptionObject = extern struct {
    base: PyObject,
    message: *PyObject, // PyStringObject
    
    pub fn create(type_ptr: *const PyTypeObject, message: *PyObject, mm: *PyMemoryManager) !*PyExceptionObject {
        const obj = try mm.alloc(PyExceptionObject);
        obj.* = .{
            .base = PyObject.init(type_ptr),
            .message = message,
        };
        message.incRef();
        return obj;
    }
};

pub const PyException_Type = PyTypeObject{
    .name = "Exception",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

fn exception_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyExceptionObject);
    obj.message.decRef(mm);
    mm.free(PyExceptionObject, obj);
}

fn exception_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyExceptionObject);
    var buf: [256]u8 = undefined;
    const repr_str = std.fmt.bufPrint(&buf, "Exception: {s}", .{obj.message.as(PyStringObject).value()}) catch "Exception";
    return try PyStringObject.create(repr_str, mm);
}

pub const PyAssertionError_Type = PyTypeObject{
    .name = "AssertionError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};
