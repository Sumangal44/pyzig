const std = @import("std");
const PyObject = @import("object.zig").PyObject;
const PyTypeObject = @import("object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyCodeObjectWrapper = @import("../bytecode/bytecode.zig").PyCodeObjectWrapper;

pub const PyFunctionObject = struct {
    base: PyObject,
    code: *PyObject, // points to PyCodeObjectWrapper
    globals: *std.StringHashMap(*PyObject),
    closure: std.StringHashMap(*PyObject), // map from name (string) to PyCellObject
    
    pub fn create(code: *PyObject, globals: *std.StringHashMap(*PyObject), mm: *PyMemoryManager) !*PyFunctionObject {
        const obj = try mm.alloc(PyFunctionObject);
        obj.* = .{
            .base = PyObject.init(&PyFunction_Type),
            .code = code,
            .globals = globals,
            .closure = std.StringHashMap(*PyObject).init(mm.allocator),
        };
        code.incRef();
        return obj;
    }
};

pub const PyFunction_Type = PyTypeObject{
    .name = "function",
    .tp_dealloc = function_dealloc,
    .tp_repr = function_repr,
    .tp_str = function_repr,
};

fn function_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyFunctionObject);
    obj.code.decRef(mm);
    var it = obj.closure.iterator();
    while (it.next()) |entry| {
        mm.allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.decRef(mm);
    }
    obj.closure.deinit();
    mm.free(PyFunctionObject, obj);
}

fn function_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyFunctionObject);
    const primitives = @import("primitives.zig");
    const PyStringObject = primitives.PyStringObject;
    var buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "<function at 0x{x}>", .{@intFromPtr(obj)}) catch "<function>";
    return try PyStringObject.create(name, mm);
}

pub const PyBuiltinFunctionObject = struct {
    base: PyObject,
    name: []const u8,
    func: *const fn (args: []*PyObject, vm: *anyopaque) anyerror!*PyObject,
    
    pub fn create(name: []const u8, func: *const fn (args: []*PyObject, vm: *anyopaque) anyerror!*PyObject, mm: *PyMemoryManager) !*PyBuiltinFunctionObject {
        const obj = try mm.alloc(PyBuiltinFunctionObject);
        obj.* = .{
            .base = PyObject.init(&PyBuiltinFunction_Type),
            .name = name,
            .func = func,
        };
        return obj;
    }
};

pub const PyBuiltinFunction_Type = PyTypeObject{
    .name = "builtin_function",
    .tp_dealloc = builtin_func_dealloc,
    .tp_repr = builtin_func_repr,
    .tp_str = builtin_func_repr,
};

fn builtin_func_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyBuiltinFunctionObject);
    mm.free(PyBuiltinFunctionObject, obj);
}

fn builtin_func_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyBuiltinFunctionObject);
    const primitives = @import("primitives.zig");
    const PyStringObject = primitives.PyStringObject;
    var buf: [128]u8 = undefined;
    const repr_str = std.fmt.bufPrint(&buf, "<built-in function {s}>", .{obj.name}) catch "<built-in function>";
    return try PyStringObject.create(repr_str, mm);
}

