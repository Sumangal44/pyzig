const std = @import("std");
const PyObject = @import("object.zig").PyObject;
const PyTypeObject = @import("object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyStringObject = @import("primitives.zig").PyStringObject;

pub const PyPropertyObject = extern struct {
    base: PyObject,
    fget: ?*PyObject,
    fset: ?*PyObject,
    fdel: ?*PyObject,
    doc: ?*PyObject,

    pub fn create(fget: ?*PyObject, fset: ?*PyObject, fdel: ?*PyObject, doc: ?*PyObject, mm: *PyMemoryManager) !*PyPropertyObject {
        const obj = try mm.alloc(PyPropertyObject);
        obj.* = .{
            .base = PyObject.init(&PyProperty_Type),
            .fget = fget,
            .fset = fset,
            .fdel = fdel,
            .doc = doc,
        };
        if (fget) |f| f.incRef();
        if (fset) |f| f.incRef();
        if (fdel) |f| f.incRef();
        if (doc) |d| d.incRef();
        return obj;
    }
};

pub const PyProperty_Type = PyTypeObject{
    .name = "property",
    .tp_dealloc = property_dealloc,
    .tp_repr = property_repr,
    .tp_str = property_repr,
};

fn property_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyPropertyObject);
    if (obj.fget) |f| f.decRef(mm);
    if (obj.fset) |f| f.decRef(mm);
    if (obj.fdel) |f| f.decRef(mm);
    if (obj.doc) |d| d.decRef(mm);
    mm.free(PyPropertyObject, obj);
}

fn property_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyPropertyObject);
    _ = obj;
    var buf: [256]u8 = undefined;
    const repr_str = std.fmt.bufPrint(&buf, "<property object at 0x{x}>", .{@intFromPtr(self)}) catch "<property>";
    return try PyStringObject.create(repr_str, mm);
}
