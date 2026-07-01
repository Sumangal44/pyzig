const std = @import("std");
const object = @import("object.zig");
const PyObject = object.PyObject;
const PyTypeObject = object.PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;

pub const PyStaticMethodObject = extern struct {
    base: PyObject,
    func: *PyObject,

    pub fn create(func: *PyObject, mm: *PyMemoryManager) !*PyObject {
        const obj = try mm.alloc(PyStaticMethodObject);
        obj.* = .{
            .base = PyObject.init(&PyStaticMethod_Type),
            .func = func,
        };
        func.incRef();
        return &obj.base;
    }
};

pub const PyStaticMethod_Type = PyTypeObject{
    .name = "staticmethod",
    .tp_dealloc = dealloc,
};

fn dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyStaticMethodObject);
    obj.func.decRef(mm);
    mm.free(PyStaticMethodObject, obj);
}
