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
    .tp_hash = bool_hash,
    .tp_richcompare = bool_richcompare,
};

fn bool_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const val = self.as(PyBoolObject).value;
    return try PyStringObject.create(if (val) "True" else "False", mm);
}

fn bool_bool(self: *PyObject) bool {
    return self.as(PyBoolObject).value;
}

fn bool_hash(self: *PyObject) anyerror!i64 {
    return if (self.as(PyBoolObject).value) @as(i64, 1) else @as(i64, 0);
}

fn bool_richcompare(self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    const val_int = if (self.as(PyBoolObject).value) @as(i64, 1) else @as(i64, 0);
    var self_int = try PyIntObject.create(val_int, mm);
    defer self_int.decRef(mm);
    return try int_richcompare(self_int, other, op, mm);
}

fn makeSmallIntCache() [262]PyIntObject {
    var cache: [262]PyIntObject = undefined;
    var i: i64 = -5;
    while (i <= 256) : (i += 1) {
        const idx = @as(usize, @intCast(i + 5));
        cache[idx] = .{
            .base = .{
                .refcnt = 999999,
                .type_obj = &PyInt_Type,
            },
            .value = i,
        };
    }
    return cache;
}

pub var small_int_cache = makeSmallIntCache();

// --- Int Type ---
pub const PyIntObject = extern struct {
    base: PyObject,
    value: i64,

    pub fn create(value: i64, mm: *PyMemoryManager) !*PyObject {
        if (value >= -5 and value <= 256) {
            const idx = @as(usize, @intCast(value + 5));
            return &small_int_cache[idx].base;
        }

        if (mm.int_free_list) |node| {
            mm.int_free_list = @as(*?*anyopaque, @ptrCast(@alignCast(node))).*;
            const obj = @as(*PyIntObject, @ptrCast(@alignCast(node)));
            mm.object_count += 1;
            obj.* = .{
                .base = PyObject.init(&PyInt_Type),
                .value = value,
            };
            return &obj.base;
        }

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
    if (obj.value >= -5 and obj.value <= 256) {
        return;
    }
    const node = @as(*anyopaque, @ptrCast(obj));
    @as(*?*anyopaque, @ptrCast(@alignCast(node))).* = mm.int_free_list;
    mm.int_free_list = node;
    mm.object_count -= 1;
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
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "int")) {
        return try PyIntObject.create(self.as(PyIntObject).value + other.as(PyIntObject).value, mm);
    } else if (std.mem.eql(u8, other_name, "float")) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyFloatObject).value;
        return try PyFloatObject.create(a + b, mm);
    } else if (std.mem.eql(u8, other_name, "complex")) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyComplexObject);
        return try PyComplexObject.create(a + b.real, b.imag, mm);
    }
    return error.TypeError;
}

fn int_sub(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "int")) {
        return try PyIntObject.create(self.as(PyIntObject).value - other.as(PyIntObject).value, mm);
    } else if (std.mem.eql(u8, other_name, "float")) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyFloatObject).value;
        return try PyFloatObject.create(a - b, mm);
    } else if (std.mem.eql(u8, other_name, "complex")) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyComplexObject);
        return try PyComplexObject.create(a - b.real, -b.imag, mm);
    }
    return error.TypeError;
}

fn int_mul(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "int")) {
        return try PyIntObject.create(self.as(PyIntObject).value * other.as(PyIntObject).value, mm);
    } else if (std.mem.eql(u8, other_name, "float")) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyFloatObject).value;
        return try PyFloatObject.create(a * b, mm);
    } else if (std.mem.eql(u8, other_name, "complex")) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyComplexObject);
        return try PyComplexObject.create(a * b.real, a * b.imag, mm);
    }
    return error.TypeError;
}

fn int_truediv(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        if (b == 0.0) return error.ZeroDivisionError;
        return try PyFloatObject.create(a / b, mm);
    } else if (std.mem.eql(u8, other_name, "float")) {
        const b = other.as(PyFloatObject).value;
        if (b == 0.0) return error.ZeroDivisionError;
        return try PyFloatObject.create(a / b, mm);
    } else if (std.mem.eql(u8, other_name, "complex")) {
        const b = other.as(PyComplexObject);
        const denom = b.real * b.real + b.imag * b.imag;
        if (denom == 0.0) return error.ZeroDivisionError;
        return try PyComplexObject.create((a * b.real) / denom, (-a * b.imag) / denom, mm);
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
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "int")) {
        const a = self.as(PyIntObject).value;
        const b = other.as(PyIntObject).value;
        return if (match_cmp(a, b, op)) PyTrue else PyFalse;
    } else if (std.mem.eql(u8, other_name, "float")) {
        const a = @as(f64, @floatFromInt(self.as(PyIntObject).value));
        const b = other.as(PyFloatObject).value;
        return if (match_cmp(a, b, op)) PyTrue else PyFalse;
    } else if (std.mem.eql(u8, other_name, "bool")) {
        const a = self.as(PyIntObject).value;
        const b = if (other.as(PyBoolObject).value) @as(i64, 1) else @as(i64, 0);
        return if (match_cmp(a, b, op)) PyTrue else PyFalse;
    } else if (std.mem.eql(u8, other_name, "complex")) {
        if (op == .Eq or op == .Ne) {
            return try complex_richcompare(other, self, op, mm);
        }
        return error.TypeError;
    }
    return error.TypeError;
}

// --- Float Type ---
pub const PyFloatObject = extern struct {
    base: PyObject,
    value: f64,

    pub fn create(value: f64, mm: *PyMemoryManager) !*PyObject {
        if (mm.float_free_list) |node| {
            mm.float_free_list = @as(*?*anyopaque, @ptrCast(@alignCast(node))).*;
            const obj = @as(*PyFloatObject, @ptrCast(@alignCast(node)));
            mm.object_count += 1;
            obj.* = .{
                .base = PyObject.init(&PyFloat_Type),
                .value = value,
            };
            return &obj.base;
        }

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
    const node = @as(*anyopaque, @ptrCast(obj));
    @as(*?*anyopaque, @ptrCast(@alignCast(node))).* = mm.float_free_list;
    mm.float_free_list = node;
    mm.object_count -= 1;
}

fn float_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const val = self.as(PyFloatObject).value;
    var buf: [64]u8 = undefined;
    var slice: []const u8 = undefined;
    if (val == std.math.inf(f64)) {
        slice = "inf";
    } else if (val == -std.math.inf(f64)) {
        slice = "-inf";
    } else if (std.math.isNan(val)) {
        slice = "nan";
    } else {
        const fmt_d = try std.fmt.bufPrint(&buf, "{d}", .{val});
        if (std.mem.indexOfScalar(u8, fmt_d, '.') == null and std.mem.indexOfScalar(u8, fmt_d, 'e') == null) {
            slice = try std.fmt.bufPrint(&buf, "{d}.0", .{val});
        } else {
            slice = fmt_d;
        }
    }
    return try PyStringObject.create(slice, mm);
}

fn float_bool(self: *PyObject) bool {
    return self.as(PyFloatObject).value != 0.0;
}

fn float_add(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = self.as(PyFloatObject).value;
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "float")) {
        return try PyFloatObject.create(a + other.as(PyFloatObject).value, mm);
    } else if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return try PyFloatObject.create(a + b, mm);
    } else if (std.mem.eql(u8, other_name, "complex")) {
        const b = other.as(PyComplexObject);
        return try PyComplexObject.create(a + b.real, b.imag, mm);
    }
    return error.TypeError;
}

fn float_sub(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = self.as(PyFloatObject).value;
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "float")) {
        return try PyFloatObject.create(a - other.as(PyFloatObject).value, mm);
    } else if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return try PyFloatObject.create(a - b, mm);
    } else if (std.mem.eql(u8, other_name, "complex")) {
        const b = other.as(PyComplexObject);
        return try PyComplexObject.create(a - b.real, -b.imag, mm);
    }
    return error.TypeError;
}

fn float_mul(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = self.as(PyFloatObject).value;
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "float")) {
        return try PyFloatObject.create(a * other.as(PyFloatObject).value, mm);
    } else if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return try PyFloatObject.create(a * b, mm);
    } else if (std.mem.eql(u8, other_name, "complex")) {
        const b = other.as(PyComplexObject);
        return try PyComplexObject.create(a * b.real, a * b.imag, mm);
    }
    return error.TypeError;
}

fn float_truediv(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = self.as(PyFloatObject).value;
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "float")) {
        const b = other.as(PyFloatObject).value;
        if (b == 0.0) return error.ZeroDivisionError;
        return try PyFloatObject.create(a / b, mm);
    } else if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        if (b == 0.0) return error.ZeroDivisionError;
        return try PyFloatObject.create(a / b, mm);
    } else if (std.mem.eql(u8, other_name, "complex")) {
        const b = other.as(PyComplexObject);
        const denom = b.real * b.real + b.imag * b.imag;
        if (denom == 0.0) return error.ZeroDivisionError;
        return try PyComplexObject.create((a * b.real) / denom, (-a * b.imag) / denom, mm);
    }
    return error.TypeError;
}

fn float_richcompare(self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    const a = self.as(PyFloatObject).value;
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "float")) {
        const b = other.as(PyFloatObject).value;
        return if (match_cmp(a, b, op)) PyTrue else PyFalse;
    } else if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return if (match_cmp(a, b, op)) PyTrue else PyFalse;
    } else if (std.mem.eql(u8, other_name, "bool")) {
        const b = if (other.as(PyBoolObject).value) @as(f64, 1.0) else @as(f64, 0.0);
        return if (match_cmp(a, b, op)) PyTrue else PyFalse;
    } else if (std.mem.eql(u8, other_name, "complex")) {
        if (op == .Eq or op == .Ne) {
            return try complex_richcompare(other, self, op, mm);
        }
        return error.TypeError;
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

// --- Complex Type ---
pub const PyComplexObject = extern struct {
    base: PyObject,
    real: f64,
    imag: f64,

    pub fn create(real: f64, imag: f64, mm: *PyMemoryManager) !*PyObject {
        if (mm.complex_free_list) |node| {
            mm.complex_free_list = @as(*?*anyopaque, @ptrCast(@alignCast(node))).*;
            const obj = @as(*PyComplexObject, @ptrCast(@alignCast(node)));
            mm.object_count += 1;
            obj.* = .{
                .base = PyObject.init(&PyComplex_Type),
                .real = real,
                .imag = imag,
            };
            return &obj.base;
        }

        const obj = try mm.alloc(PyComplexObject);
        obj.* = .{
            .base = PyObject.init(&PyComplex_Type),
            .real = real,
            .imag = imag,
        };
        return &obj.base;
    }
};

pub const PyComplex_Type = PyTypeObject{
    .name = "complex",
    .tp_dealloc = complex_dealloc,
    .tp_repr = complex_repr,
    .tp_str = complex_repr,
    .tp_add = complex_add,
    .tp_sub = complex_sub,
    .tp_mul = complex_mul,
    .tp_truediv = complex_truediv,
    .tp_richcompare = complex_richcompare,
    .tp_bool = complex_bool,
};

fn complex_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyComplexObject);
    const node = @as(*anyopaque, @ptrCast(obj));
    @as(*?*anyopaque, @ptrCast(@alignCast(node))).* = mm.complex_free_list;
    mm.complex_free_list = node;
    mm.object_count -= 1;
}

fn formatFloatRepr(val: f64, buf: []u8) ![]const u8 {
    if (val == std.math.inf(f64)) {
        return "inf";
    } else if (val == -std.math.inf(f64)) {
        return "-inf";
    } else if (std.math.isNan(val)) {
        return "nan";
    } else {
        return try std.fmt.bufPrint(buf, "{d}", .{val});
    }
}

fn complex_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyComplexObject);
    const real = obj.real;
    const imag = obj.imag;

    var buf_real: [64]u8 = undefined;
    var buf_imag: [64]u8 = undefined;
    var buf_out: [256]u8 = undefined;

    const real_str = try formatFloatRepr(real, &buf_real);
    const imag_str = try formatFloatRepr(imag, &buf_imag);

    if (real == 0.0 and std.math.copysign(@as(f64, 1.0), real) > 0.0) {
        const out = try std.fmt.bufPrint(&buf_out, "{s}j", .{imag_str});
        return try PyStringObject.create(out, mm);
    } else {
        const sign = if (imag_str[0] == '-') "" else "+";
        const out = try std.fmt.bufPrint(&buf_out, "({s}{s}{s}j)", .{real_str, sign, imag_str});
        return try PyStringObject.create(out, mm);
    }
}

fn complex_bool(self: *PyObject) bool {
    const obj = self.as(PyComplexObject);
    return obj.real != 0.0 or obj.imag != 0.0;
}

fn complex_add(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyComplexObject);
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "complex")) {
        const b = other.as(PyComplexObject);
        return try PyComplexObject.create(obj.real + b.real, obj.imag + b.imag, mm);
    } else if (std.mem.eql(u8, other_name, "float")) {
        const b = other.as(PyFloatObject).value;
        return try PyComplexObject.create(obj.real + b, obj.imag, mm);
    } else if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return try PyComplexObject.create(obj.real + b, obj.imag, mm);
    }
    return error.TypeError;
}

fn complex_sub(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyComplexObject);
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "complex")) {
        const b = other.as(PyComplexObject);
        return try PyComplexObject.create(obj.real - b.real, obj.imag - b.imag, mm);
    } else if (std.mem.eql(u8, other_name, "float")) {
        const b = other.as(PyFloatObject).value;
        return try PyComplexObject.create(obj.real - b, obj.imag, mm);
    } else if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return try PyComplexObject.create(obj.real - b, obj.imag, mm);
    }
    return error.TypeError;
}

fn complex_mul(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyComplexObject);
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "complex")) {
        const b = other.as(PyComplexObject);
        return try PyComplexObject.create(
            obj.real * b.real - obj.imag * b.imag,
            obj.real * b.imag + obj.imag * b.real,
            mm,
        );
    } else if (std.mem.eql(u8, other_name, "float")) {
        const b = other.as(PyFloatObject).value;
        return try PyComplexObject.create(obj.real * b, obj.imag * b, mm);
    } else if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        return try PyComplexObject.create(obj.real * b, obj.imag * b, mm);
    }
    return error.TypeError;
}

fn complex_truediv(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyComplexObject);
    const other_name = other.type_obj.name;
    if (std.mem.eql(u8, other_name, "complex")) {
        const b = other.as(PyComplexObject);
        const denom = b.real * b.real + b.imag * b.imag;
        if (denom == 0.0) return error.ZeroDivisionError;
        return try PyComplexObject.create(
            (obj.real * b.real + obj.imag * b.imag) / denom,
            (obj.imag * b.real - obj.real * b.imag) / denom,
            mm,
        );
    } else if (std.mem.eql(u8, other_name, "float")) {
        const b = other.as(PyFloatObject).value;
        if (b == 0.0) return error.ZeroDivisionError;
        return try PyComplexObject.create(obj.real / b, obj.imag / b, mm);
    } else if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        if (b == 0.0) return error.ZeroDivisionError;
        return try PyComplexObject.create(obj.real / b, obj.imag / b, mm);
    }
    return error.TypeError;
}

fn complex_richcompare(self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    _ = mm;
    const obj = self.as(PyComplexObject);
    const other_name = other.type_obj.name;
    
    if (op != .Eq and op != .Ne) {
        return error.TypeError;
    }

    var eq = false;
    if (std.mem.eql(u8, other_name, "complex")) {
        const b = other.as(PyComplexObject);
        eq = (obj.real == b.real and obj.imag == b.imag);
    } else if (std.mem.eql(u8, other_name, "float")) {
        const b = other.as(PyFloatObject).value;
        eq = (obj.real == b and obj.imag == 0.0);
    } else if (std.mem.eql(u8, other_name, "int")) {
        const b = @as(f64, @floatFromInt(other.as(PyIntObject).value));
        eq = (obj.real == b and obj.imag == 0.0);
    } else {
        eq = false;
    }

    const result = if (op == .Eq) eq else !eq;
    return if (result) PyTrue else PyFalse;
}

// --- Bytes Type ---
pub const PyBytesObject = extern struct {
    base: PyObject,
    ptr: [*]const u8,
    len: usize,

    pub fn value(self: *const PyBytesObject) []const u8 {
        return self.ptr[0..self.len];
    }

    pub fn create(val: []const u8, mm: *PyMemoryManager) !*PyObject {
        const copy = try mm.allocBytes(val.len);
        @memcpy(copy, val);
        const obj = try mm.alloc(PyBytesObject);
        obj.* = .{
            .base = PyObject.init(&PyBytes_Type),
            .ptr = copy.ptr,
            .len = copy.len,
        };
        return &obj.base;
    }
};

pub const PyBytes_Type = PyTypeObject{
    .name = "bytes",
    .tp_dealloc = bytes_dealloc,
    .tp_repr = bytes_repr,
    .tp_str = bytes_repr,
    .tp_add = bytes_add,
    .tp_richcompare = bytes_richcompare,
    .tp_bool = bytes_bool,
    .tp_hash = bytes_hash,
};

fn bytes_hash(self: *PyObject) anyerror!i64 {
    const val = self.as(PyBytesObject).value();
    var hash: usize = 14695981039346656037;
    for (val) |c| {
        hash ^= c;
        hash = hash *% 1099511628211;
    }
    return @bitCast(hash);
}

fn bytes_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyBytesObject);
    if (obj.len > 0) {
        const ptr_u8: [*]u8 = @constCast(@ptrCast(obj.ptr));
        mm.freeBytes(ptr_u8[0..obj.len]);
    }
    mm.free(PyBytesObject, obj);
}

fn bytes_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyBytesObject);
    const val = obj.value();
    
    var alloc_writer = std.Io.Writer.Allocating.init(mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    
    try writer.writeAll("b'");
    for (val) |b| {
        switch (b) {
            '\\' => try writer.writeAll("\\\\"),
            '\'' => try writer.writeAll("\\'"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (b >= 32 and b <= 126) {
                    try writer.writeByte(b);
                } else {
                    try writer.print("\\x{x:0>2}", .{b});
                }
            },
        }
    }
    try writer.writeAll("'");
    return try PyStringObject.create(alloc_writer.written(), mm);
}

fn bytes_add(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const self_name = self.type_obj.name;
    const other_name = other.type_obj.name;
    
    var self_bytes: []const u8 = undefined;
    if (std.mem.eql(u8, self_name, "bytes")) {
        self_bytes = self.as(PyBytesObject).value();
    } else if (std.mem.eql(u8, self_name, "bytearray")) {
        self_bytes = self.as(PyByteArrayObject).value();
    } else {
        return error.TypeError;
    }
    
    var other_bytes: []const u8 = undefined;
    if (std.mem.eql(u8, other_name, "bytes")) {
        other_bytes = other.as(PyBytesObject).value();
    } else if (std.mem.eql(u8, other_name, "bytearray")) {
        other_bytes = other.as(PyByteArrayObject).value();
    } else {
        return error.TypeError;
    }
    
    const total_len = self_bytes.len + other_bytes.len;
    const copy = try mm.allocBytes(total_len);
    @memcpy(copy[0..self_bytes.len], self_bytes);
    @memcpy(copy[self_bytes.len..], other_bytes);
    
    const obj = try mm.alloc(PyBytesObject);
    obj.* = .{
        .base = PyObject.init(&PyBytes_Type),
        .ptr = copy.ptr,
        .len = copy.len,
    };
    return &obj.base;
}

fn bytes_richcompare(self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    _ = mm;
    const self_name = self.type_obj.name;
    const other_name = other.type_obj.name;
    
    var self_bytes: []const u8 = undefined;
    if (std.mem.eql(u8, self_name, "bytes")) {
        self_bytes = self.as(PyBytesObject).value();
    } else if (std.mem.eql(u8, self_name, "bytearray")) {
        self_bytes = self.as(PyByteArrayObject).value();
    } else {
        return error.TypeError;
    }
    
    var other_bytes: []const u8 = undefined;
    if (std.mem.eql(u8, other_name, "bytes")) {
        other_bytes = other.as(PyBytesObject).value();
    } else if (std.mem.eql(u8, other_name, "bytearray")) {
        other_bytes = other.as(PyByteArrayObject).value();
    } else {
        if (op == .Eq) return PyFalse;
        if (op == .Ne) return PyTrue;
        return error.TypeError;
    }
    
    const cmp_res = std.mem.order(u8, self_bytes, other_bytes);
    var result = false;
    switch (op) {
        .Lt => result = cmp_res == .lt,
        .Le => result = cmp_res == .lt or cmp_res == .eq,
        .Eq => result = cmp_res == .eq,
        .Ne => result = cmp_res != .eq,
        .Gt => result = cmp_res == .gt,
        .Ge => result = cmp_res == .gt or cmp_res == .eq,
    }
    return if (result) PyTrue else PyFalse;
}

fn bytes_bool(self: *PyObject) bool {
    return self.as(PyBytesObject).len > 0;
}

// --- ByteArray Type ---
pub const PyByteArrayObject = extern struct {
    base: PyObject,
    items: ?[*]u8,
    size: usize,
    capacity: usize,

    pub fn value(self: *const PyByteArrayObject) []const u8 {
        if (self.size == 0 or self.items == null) return &[_]u8{};
        return self.items.?[0..self.size];
    }

    pub fn create(capacity: usize, mm: *PyMemoryManager) !*PyByteArrayObject {
        const obj = try mm.alloc(PyByteArrayObject);
        obj.* = .{
            .base = PyObject.init(&PyByteArray_Type),
            .items = null,
            .size = 0,
            .capacity = capacity,
        };
        if (capacity > 0) {
            const bytes = try mm.allocBytes(capacity);
            obj.items = @ptrCast(bytes.ptr);
        }
        return obj;
    }

    pub fn append(self: *PyByteArrayObject, byte_val: u8, mm: *PyMemoryManager) !void {
        if (self.size >= self.capacity) {
            const new_capacity = if (self.capacity == 0) 8 else self.capacity * 2;
            const new_bytes = try mm.allocBytes(new_capacity);
            if (self.size > 0 and self.items != null) {
                @memcpy(new_bytes[0..self.size], self.items.?[0..self.size]);
                mm.freeBytes(self.items.?[0..self.capacity]);
            }
            self.items = new_bytes.ptr;
            self.capacity = new_capacity;
        }
        self.items.?[self.size] = byte_val;
        self.size += 1;
    }
};

pub const PyByteArray_Type = PyTypeObject{
    .name = "bytearray",
    .tp_dealloc = bytearray_dealloc,
    .tp_repr = bytearray_repr,
    .tp_str = bytearray_repr,
    .tp_add = bytes_add,
    .tp_richcompare = bytes_richcompare,
    .tp_bool = bytearray_bool,
};

fn bytearray_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyByteArrayObject);
    if (obj.items) |items| {
        mm.freeBytes(items[0..obj.capacity]);
    }
    mm.free(PyByteArrayObject, obj);
}

fn bytearray_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyByteArrayObject);
    const val = obj.value();
    
    var alloc_writer = std.Io.Writer.Allocating.init(mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    
    try writer.writeAll("bytearray(b'");
    for (val) |b| {
        switch (b) {
            '\\' => try writer.writeAll("\\\\"),
            '\'' => try writer.writeAll("\\'"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (b >= 32 and b <= 126) {
                    try writer.writeByte(b);
                } else {
                    try writer.print("\\x{x:0>2}", .{b});
                }
            },
        }
    }
    try writer.writeAll("')");
    return try PyStringObject.create(alloc_writer.written(), mm);
}

fn bytearray_bool(self: *PyObject) bool {
    return self.as(PyByteArrayObject).size > 0;
}

test "primitives creation and arithmetic" {
    const allocator = std.testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

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

    const c1 = try PyComplexObject.create(2.0, 3.0, &mm);
    defer c1.decRef(&mm);
    const c2 = try PyComplexObject.create(4.0, -5.0, &mm);
    defer c2.decRef(&mm);

    const c_sum = try c1.type_obj.tp_add.?(c1, c2, &mm);
    defer c_sum.decRef(&mm);

    try std.testing.expectEqual(@as(f64, 6.0), c_sum.as(PyComplexObject).real);
    try std.testing.expectEqual(@as(f64, -2.0), c_sum.as(PyComplexObject).imag);
}
