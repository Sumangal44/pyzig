const std = @import("std");
const PyObject = @import("object.zig").PyObject;
const PyTypeObject = @import("object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyDictObject = @import("collections.zig").PyDictObject;
const PyStringObject = @import("primitives.zig").PyStringObject;

pub const PyClassObject = extern struct {
    base: PyObject,
    name: *PyObject, // string
    base_class: ?*PyObject, // PyClassObject
    dict: *PyObject, // PyDictObject containing methods and class attributes
    
    pub fn create(name: *PyObject, base_class: ?*PyObject, dict: *PyObject, mm: *PyMemoryManager) !*PyClassObject {
        const obj = try mm.alloc(PyClassObject);
        obj.* = .{
            .base = PyObject.init(&PyClass_Type),
            .name = name,
            .base_class = base_class,
            .dict = dict,
        };
        name.incRef();
        if (base_class) |bc| bc.incRef();
        dict.incRef();
        return obj;
    }
};

pub const PyInstanceObject = extern struct {
    base: PyObject,
    class_obj: *PyClassObject,
    dict: *PyObject, // PyDictObject for instance attributes
    
    pub fn create(class_obj: *PyClassObject, mm: *PyMemoryManager) !*PyInstanceObject {
        const dict = try PyDictObject.create(mm);
        const obj = try mm.alloc(PyInstanceObject);
        obj.* = .{
            .base = PyObject.init(&PyInstance_Type),
            .class_obj = class_obj,
            .dict = &dict.base,
        };
        class_obj.base.incRef();
        return obj;
    }
};

pub const PyMethodObject = extern struct {
    base: PyObject,
    self_obj: *PyObject, // instance
    func: *PyObject, // PyFunctionObject
    
    pub fn create(self_obj: *PyObject, func: *PyObject, mm: *PyMemoryManager) !*PyMethodObject {
        const obj = try mm.alloc(PyMethodObject);
        obj.* = .{
            .base = PyObject.init(&PyMethod_Type),
            .self_obj = self_obj,
            .func = func,
        };
        self_obj.incRef();
        func.incRef();
        return obj;
    }
};

pub const PyClass_Type = PyTypeObject{
    .name = "type",
    .tp_dealloc = class_dealloc,
    .tp_repr = class_repr,
    .tp_str = class_repr,
};

pub const PyInstance_Type = PyTypeObject{
    .name = "object",
    .tp_dealloc = instance_dealloc,
    .tp_repr = instance_repr,
    .tp_str = instance_repr,
};

pub const PyMethod_Type = PyTypeObject{
    .name = "method",
    .tp_dealloc = method_dealloc,
    .tp_repr = method_repr,
    .tp_str = method_repr,
};

fn class_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyClassObject);
    obj.name.decRef(mm);
    if (obj.base_class) |bc| bc.decRef(mm);
    obj.dict.decRef(mm);
    mm.free(PyClassObject, obj);
}

fn instance_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyInstanceObject);
    obj.class_obj.base.decRef(mm);
    obj.dict.decRef(mm);
    mm.free(PyInstanceObject, obj);
}

fn method_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyMethodObject);
    obj.self_obj.decRef(mm);
    obj.func.decRef(mm);
    mm.free(PyMethodObject, obj);
}

fn class_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyClassObject);
    var buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "<class '{s}'>", .{obj.name.as(PyStringObject).value()}) catch "<class>";
    return try PyStringObject.create(name, mm);
}

fn instance_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyInstanceObject);
    var buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "<{s} object at 0x{x}>", .{obj.class_obj.name.as(PyStringObject).value(), @intFromPtr(obj)}) catch "<object>";
    return try PyStringObject.create(name, mm);
}

fn method_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyMethodObject);
    var buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "<bound method of <{s} object>>", .{obj.self_obj.type_obj.name}) catch "<bound method>";
    return try PyStringObject.create(name, mm);
}
