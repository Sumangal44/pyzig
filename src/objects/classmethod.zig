const std = @import("std");
const object = @import("object.zig");
const PyObject = object.PyObject;
const PyTypeObject = object.PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;

pub const PyClassMethodObject = extern struct {
    base: PyObject,
    func: *PyObject,

    pub fn create(func: *PyObject, mm: *PyMemoryManager) !*PyObject {
        const obj = try mm.alloc(PyClassMethodObject);
        obj.* = .{
            .base = PyObject.init(&PyClassMethod_Type),
            .func = func,
        };
        func.incRef();
        return &obj.base;
    }
};

pub const PyClassMethod_Type = PyTypeObject{
    .name = "classmethod",
    .tp_dealloc = dealloc,
};

fn dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyClassMethodObject);
    obj.func.decRef(mm);
    mm.free(PyClassMethodObject, obj);
}
