const std = @import("std");
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyObject = @import("object.zig").PyObject;
const PyTypeObject = @import("object.zig").PyTypeObject;
const CompareOp = @import("object.zig").CompareOp;

// Global singletons for None, True, False
pub var PyNone_Struct = PyObject{
    .refcnt = 999999, // large refcount to prevent destruction
    .type_obj = &PyNone_Type,
};
pub const PyNone = &PyNone_Struct;

pub var PyTrue_Struct = PyBoolObject{
    .base = PyObject{
        .refcnt = 999999,
        .type_obj = &PyBool_Type,
    },
    .value = true,
};
pub const PyTrue = &PyTrue_Struct.base;

pub var PyFalse_Struct = PyBoolObject{
    .base = PyObject{
        .refcnt = 999999,
        .type_obj = &PyBool_Type,
    },
    .value = false,
};
pub const PyFalse = &PyFalse_Struct.base;

// --- None Type ---
pub const PyNone_Type = PyTypeObject{
    .name = "NoneType",
    .tp_dealloc = null, // Never deallocated
    .tp_repr = none_repr,
    .tp_str = none_repr,
    .tp_bool = none_bool,
};

fn none_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    _ = self;
    return try PyStringObject.create("None", mm);
}

fn none_bool(self: *PyObject) bool {
    _ = self;
    return false;
}

// --- Bool Type ---
pub const PyBoolObject = extern struct {
    base: PyObject,
    value: bool,
};

pub const PyBool_Type = PyTypeObject{
    .name = "bool",
    .tp_dealloc = null, // Never deallocated
    .tp_repr = bool_repr,
    .tp_str = bool_repr,
    .tp_bool = bool_bool,
};

fn bool_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const val = self.as(PyBoolObject).value;
    return try PyStringObject.create(if (val) "True" else "False", mm);
}

fn bool_bool(self: *PyObject) bool {
    return self.as(PyBoolObject).value;
}

// --- Int Type ---
pub const PyIntObject = extern struct {
    base: PyObject,
    value: i64,

    pub fn create(value: i64, mm: *PyMemoryManager) !*PyObject {
        const obj = try mm.alloc(PyIntObject);
        obj.* = .{
            .base = PyObject.init(&PyInt_Type),
            .value = value,
        };
        return &obj.base;
    }
};

pub const PyInt_Type = PyTypeObject{
    .name = "int",
    .tp_dealloc = int_dealloc,
    .tp_repr = int_repr,
    .tp_str = int_repr,
    .tp_add = int_add,
    .tp_sub = int_sub,
    .tp_mul = int_mul,
    .tp_truediv = int_truediv,
    .tp_richcompare = int_richcompare,
    .tp_bool = int_bool,
    .tp_hash = int_hash,
};

fn int_hash(self: *PyObject) anyerror!i64 {
    return self.as(PyIntObject).value;
}

fn int_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyIntObject);
    mm.free(PyIntObject, obj);
}

fn int_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const val = self.as(PyIntObject).value;
    var buf: [32]u8 = undefined;
    const slice = try std.fmt.bufPrint(&buf, "{d}", .{val});
    return try PyStringObject.create(slice, mm);
}

fn int_bool(self: *PyObject) bool {
    return self.as(PyIntObject).value != 0;
}

fn int_add(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    if (other.type_obj == &PyInt_Type) {
        return try PyIntObject.create(self.as(PyIntObject).value + other.as(PyIntObject).value, mm);
    } else if (other.type_obj == &PyFloat_Type) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyFloatObject).value;
        return try PyFloatObject.create(a + b, mm);
    }
    return error.TypeError;
}

fn int_sub(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    if (other.type_obj == &PyInt_Type) {
        return try PyIntObject.create(self.as(PyIntObject).value - other.as(PyIntObject).value, mm);
    } else if (other.type_obj == &PyFloat_Type) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyFloatObject).value;
        return try PyFloatObject.create(a - b, mm);
    }
    return error.TypeError;
}

fn int_mul(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    if (other.type_obj == &PyInt_Type) {
        return try PyIntObject.create(self.as(PyIntObject).value * other.as(PyIntObject).value, mm);
    } else if (other.type_obj == &PyFloat_Type) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyFloatObject).value;
        return try PyFloatObject.create(a * b, mm);
    }
    return error.TypeError;
}

fn int_truediv(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
    if (other.type_obj == &PyInt_Type) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        if (b == 0.0) return error.ZeroDivisionError;
        return try PyFloatObject.create(a / b, mm);
    } else if (other.type_obj == &PyFloat_Type) {
        const b = other.as(PyFloatObject).value;
        if (b == 0.0) return error.ZeroDivisionError;
        return try PyFloatObject.create(a / b, mm);
    }
    return error.TypeError;
}

fn match_cmp(a: anytype, b: anytype, op: CompareOp) bool {
    return switch (op) {
        .Lt => a < b,
        .Le => a <= b,
        .Eq => a == b,
        .Ne => a != b,
        .Gt => a > b,
        .Ge => a >= b,
    };
}

fn int_richcompare(self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    _ = mm;
    if (other.type_obj == &PyInt_Type) {
        const a = self.as(PyIntObject).value;
        const b = other.as(PyIntObject).value;
        return if (match_cmp(a, b, op)) PyTrue else PyFalse;
    } else if (other.type_obj == &PyFloat_Type) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyFloatObject).value;
        return if (match_cmp(a, b, op)) PyTrue else PyFalse;
    }
    return error.TypeError;
}

// --- Float Type ---
pub const PyFloatObject = extern struct {
    base: PyObject,
    value: f64,

    pub fn create(value: f64, mm: *PyMemoryManager) !*PyObject {
        const obj = try mm.alloc(PyFloatObject);
        obj.* = .{
            .base = PyObject.init(&PyFloat_Type),
            .value = value,
        };
        return &obj.base;
    }
};

pub const PyFloat_Type = PyTypeObject{
    .name = "float",
    .tp_dealloc = float_dealloc,
    .tp_repr = float_repr,
    .tp_str = float_repr,
    .tp_add = float_add,
    .tp_sub = float_sub,
    .tp_mul = float_mul,
    .tp_truediv = float_truediv,
    .tp_richcompare = float_richcompare,
    .tp_bool = float_bool,
};

fn float_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyFloatObject);
    mm.free(PyFloatObject, obj);
}

fn float_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const val = self.as(PyFloatObject).value;
    var buf: [64]u8 = undefined;
    const slice = try std.fmt.bufPrint(&buf, "{d}", .{val});
    return try PyStringObject.create(slice, mm);
}

fn float_bool(self: *PyObject) bool {
    return self.as(PyFloatObject).value != 0.0;
}

fn float_add(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = self.as(PyFloatObject).value;
    if (other.type_obj == &PyFloat_Type) {
        return try PyFloatObject.create(a + other.as(PyFloatObject).value, mm);
    } else if (other.type_obj == &PyInt_Type) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return try PyFloatObject.create(a + b, mm);
    }
    return error.TypeError;
}

fn float_sub(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = self.as(PyFloatObject).value;
    if (other.type_obj == &PyFloat_Type) {
        return try PyFloatObject.create(a - other.as(PyFloatObject).value, mm);
    } else if (other.type_obj == &PyInt_Type) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return try PyFloatObject.create(a - b, mm);
    }
    return error.TypeError;
}

fn float_mul(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = self.as(PyFloatObject).value;
    if (other.type_obj == &PyFloat_Type) {
        return try PyFloatObject.create(a * other.as(PyFloatObject).value, mm);
    } else if (other.type_obj == &PyInt_Type) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return try PyFloatObject.create(a * b, mm);
    }
    return error.TypeError;
}

fn float_truediv(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = self.as(PyFloatObject).value;
    if (other.type_obj == &PyFloat_Type) {
        const b = other.as(PyFloatObject).value;
        if (b == 0.0) return error.ZeroDivisionError;
        return try PyFloatObject.create(a / b, mm);
    } else if (other.type_obj == &PyInt_Type) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        if (b == 0.0) return error.ZeroDivisionError;
        return try PyFloatObject.create(a / b, mm);
    }
    return error.TypeError;
}

fn float_richcompare(self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    _ = mm;
    const a = self.as(PyFloatObject).value;
    if (other.type_obj == &PyFloat_Type) {
        const b = other.as(PyFloatObject).value;
        return if (match_cmp(a, b, op)) PyTrue else PyFalse;
    } else if (other.type_obj == &PyInt_Type) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return if (match_cmp(a, b, op)) PyTrue else PyFalse;
    }
    return error.TypeError;
}

// --- String Type ---
pub const PyStringObject = extern struct {
    base: PyObject,
    ptr: [*]const u8,
    len: usize,

    pub fn value(self: *const PyStringObject) []const u8 {
        return self.ptr[0..self.len];
    }

    pub fn create(val: []const u8, mm: *PyMemoryManager) !*PyObject {
        const copy = try mm.allocBytes(val.len);
        @memcpy(copy, val);
        const obj = try mm.alloc(PyStringObject);
        obj.* = .{
            .base = PyObject.init(&PyString_Type),
            .ptr = copy.ptr,
            .len = copy.len,
        };
        return &obj.base;
    }
};

pub const PyString_Type = PyTypeObject{
    .name = "str",
    .tp_dealloc = string_dealloc,
    .tp_repr = string_repr,
    .tp_str = string_str,
    .tp_add = string_add,
    .tp_richcompare = string_richcompare,
    .tp_bool = string_bool,
    .tp_hash = string_hash,
};

fn string_hash(self: *PyObject) anyerror!i64 {
    const val = self.as(PyStringObject).value();
    var hash: usize = 14695981039346656037;
    for (val) |c| {
        hash ^= c;
        hash = hash *% 1099511628211;
    }
    return @bitCast(hash);
}

fn string_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyStringObject);
    mm.freeBytes(@constCast(obj.ptr[0..obj.len]));
    mm.free(PyStringObject, obj);
}

fn string_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const val = self.as(PyStringObject).value();
    // Simple wrapping in single quotes
    const size = val.len + 2;
    const buf = try mm.allocBytes(size);
    buf[0] = '\'';
    @memcpy(buf[1..size - 1], val);
    buf[size - 1] = '\'';

    const obj = try mm.alloc(PyStringObject);
    obj.* = .{
        .base = PyObject.init(&PyString_Type),
        .ptr = buf.ptr,
        .len = buf.len,
    };
    return &obj.base;
}

fn string_str(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const val = self.as(PyStringObject).value();
    return try PyStringObject.create(val, mm);
}

fn string_bool(self: *PyObject) bool {
    return self.as(PyStringObject).len != 0;
}

fn string_add(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    if (other.type_obj != &PyString_Type) {
        return error.TypeError;
    }
    const a = self.as(PyStringObject).value();
    const b = other.as(PyStringObject).value();

    const merged = try mm.allocBytes(a.len + b.len);
    @memcpy(merged[0..a.len], a);
    @memcpy(merged[a.len..], b);

    const obj = try mm.alloc(PyStringObject);
    obj.* = .{
        .base = PyObject.init(&PyString_Type),
        .ptr = merged.ptr,
        .len = merged.len,
    };
    return &obj.base;
}

fn string_richcompare(self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    _ = mm;
    if (other.type_obj != &PyString_Type) {
        return error.TypeError;
    }
    const a = self.as(PyStringObject).value();
    const b = other.as(PyStringObject).value();
    const cmp = std.mem.order(u8, a, b);
    const result = switch (op) {
        .Lt => cmp == .lt,
        .Le => cmp == .lt or cmp == .eq,
        .Eq => cmp == .eq,
        .Ne => cmp == .gt or cmp == .lt,
        .Gt => cmp == .gt,
        .Ge => cmp == .gt or cmp == .eq,
    };
    return if (result) PyTrue else PyFalse;
}

test "primitives creation and arithmetic" {
    const allocator = std.testing.allocator;
    var mm = PyMemoryManager.init(allocator);

    const int1 = try PyIntObject.create(10, &mm);
    defer int1.decRef(&mm);
    const int2 = try PyIntObject.create(5, &mm);
    defer int2.decRef(&mm);

    const sum = try int1.type_obj.tp_add.?(int1, int2, &mm);
    defer sum.decRef(&mm);

    try std.testing.expectEqual(@as(i64, 15), sum.as(PyIntObject).value);

    const str1 = try PyStringObject.create("hello", &mm);
    defer str1.decRef(&mm);
    const str2 = try PyStringObject.create(" world", &mm);
    defer str2.decRef(&mm);

    const str_sum = try str1.type_obj.tp_add.?(str1, str2, &mm);
    defer str_sum.decRef(&mm);

    try std.testing.expectEqualStrings("hello world", str_sum.as(PyStringObject).value());
}
