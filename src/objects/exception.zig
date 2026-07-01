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

pub const PyTypeError_Type = PyTypeObject{
    .name = "TypeError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyValueError_Type = PyTypeObject{
    .name = "ValueError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyKeyError_Type = PyTypeObject{
    .name = "KeyError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyIndexError_Type = PyTypeObject{
    .name = "IndexError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyStopIteration_Type = PyTypeObject{
    .name = "StopIteration",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyAttributeError_Type = PyTypeObject{
    .name = "AttributeError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyNameError_Type = PyTypeObject{
    .name = "NameError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyRuntimeError_Type = PyTypeObject{
    .name = "RuntimeError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyZeroDivisionError_Type = PyTypeObject{
    .name = "ZeroDivisionError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyImportError_Type = PyTypeObject{
    .name = "ImportError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyModuleNotFoundError_Type = PyTypeObject{
    .name = "ModuleNotFoundError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyFileNotFoundError_Type = PyTypeObject{
    .name = "FileNotFoundError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyPermissionError_Type = PyTypeObject{
    .name = "PermissionError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyMemoryError_Type = PyTypeObject{
    .name = "MemoryError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyRecursionError_Type = PyTypeObject{
    .name = "RecursionError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyIndentationError_Type = PyTypeObject{
    .name = "IndentationError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};

pub const PyUnboundLocalError_Type = PyTypeObject{
    .name = "UnboundLocalError",
    .tp_dealloc = exception_dealloc,
    .tp_repr = exception_repr,
    .tp_str = exception_repr,
};
