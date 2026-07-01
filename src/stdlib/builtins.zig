const std = @import("std");
const PyObject = @import("../objects/object.zig").PyObject;
const PyTypeObject = @import("../objects/object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const primitives = @import("../objects/primitives.zig");
const PyNone = primitives.PyNone;
const PyTrue = primitives.PyTrue;
const PyFalse = primitives.PyFalse;
const PyIntObject = primitives.PyIntObject;
const PyStringObject = primitives.PyStringObject;
const PyInt_Type = &primitives.PyInt_Type;
const PyFloat_Type = &primitives.PyFloat_Type;
const PyString_Type = &primitives.PyString_Type;
const PyBool_Type = &primitives.PyBool_Type;
const PyComplex_Type = &primitives.PyComplex_Type;
const PyBytes_Type = &primitives.PyBytes_Type;
const PyByteArray_Type = &primitives.PyByteArray_Type;
const PyBuiltinFunctionObject = @import("../objects/function.zig").PyBuiltinFunctionObject;
const function_mod = @import("../objects/function.zig");
const PyFunction_Type = &function_mod.PyFunction_Type;
const PyBuiltinFunction_Type = &function_mod.PyBuiltinFunction_Type;
const PyGenerator_Type = &function_mod.PyGenerator_Type;
const class_mod = @import("../objects/class.zig");
const PyClass_Type = &class_mod.PyClass_Type;
const PyInstance_Type = &class_mod.PyInstance_Type;
const PyMethod_Type = &class_mod.PyMethod_Type;
const PyClassObject = class_mod.PyClassObject;
const collections = @import("../objects/collections.zig");
const PyListObject = collections.PyListObject;
const PyTupleObject = collections.PyTupleObject;
const PyDictObject = collections.PyDictObject;
const PyList_Type = &collections.PyList_Type;
const PyTuple_Type = &collections.PyTuple_Type;
const PyDict_Type = &collections.PyDict_Type;
const PySet_Type = &collections.PySet_Type;
const PyFrozenSet_Type = &collections.PyFrozenSet_Type;

pub const PyTypeWrapper = extern struct {
    base: PyObject,
    type_ptr: *const PyTypeObject,
    
    pub fn create(type_ptr: *const PyTypeObject, mm: *PyMemoryManager) !*PyTypeWrapper {
        const obj = try mm.alloc(PyTypeWrapper);
        obj.* = .{
            .base = PyObject.init(&PyTypeWrapper_Type),
            .type_ptr = type_ptr,
        };
        return obj;
    }
};

pub const PyTypeWrapper_Type = PyTypeObject{
    .name = "type",
    .tp_dealloc = type_wrapper_dealloc,
    .tp_repr = type_wrapper_repr,
    .tp_str = type_wrapper_repr,
    .tp_richcompare = type_wrapper_richcompare,
};

fn type_wrapper_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyTypeWrapper);
    mm.free(PyTypeWrapper, obj);
}

fn type_wrapper_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyTypeWrapper);
    var buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "<class '{s}'>", .{obj.type_ptr.name}) catch "<class>";
    return try PyStringObject.create(name, mm);
}

pub fn matchBuiltinType(func_name: []const u8) ?*const PyTypeObject {
    if (std.mem.eql(u8, func_name, "list")) return PyList_Type;
    if (std.mem.eql(u8, func_name, "tuple")) return PyTuple_Type;
    if (std.mem.eql(u8, func_name, "dict")) return PyDict_Type;
    if (std.mem.eql(u8, func_name, "str")) return PyString_Type;
    if (std.mem.eql(u8, func_name, "int")) return PyInt_Type;
    if (std.mem.eql(u8, func_name, "float")) return PyFloat_Type;
    if (std.mem.eql(u8, func_name, "bool")) return PyBool_Type;
    if (std.mem.eql(u8, func_name, "set")) return PySet_Type;
    if (std.mem.eql(u8, func_name, "frozenset")) return PyFrozenSet_Type;
    if (std.mem.eql(u8, func_name, "bytes")) return PyBytes_Type;
    if (std.mem.eql(u8, func_name, "bytearray")) return PyByteArray_Type;
    return null;
}

fn type_wrapper_richcompare(self: *PyObject, other: *PyObject, op: @import("../objects/object.zig").CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    _ = mm;
    if (op != .Eq and op != .Ne) return error.TypeError;
    var is_eq = false;
    if (other.type_obj == &PyTypeWrapper_Type) {
        const a = self.as(PyTypeWrapper);
        const b = other.as(PyTypeWrapper);
        is_eq = (a.type_ptr == b.type_ptr);
    } else if (other.type_obj == &@import("../objects/function.zig").PyBuiltinFunction_Type) {
        const a = self.as(PyTypeWrapper);
        const b = other.as(@import("../objects/function.zig").PyBuiltinFunctionObject);
        if (matchBuiltinType(b.name)) |t_ptr| {
            is_eq = (a.type_ptr == t_ptr);
        }
    }
    const result = if (op == .Eq) is_eq else !is_eq;
    const res = if (result) PyTrue else PyFalse;
    res.incRef();
    return res;
}

// len(x)
pub fn builtinLen(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const obj = args[0];
    var size: usize = 0;
    if (obj.type_obj == PyList_Type) {
        size = obj.as(PyListObject).size;
    } else if (obj.type_obj == PyTuple_Type) {
        size = obj.as(PyTupleObject).size;
    } else if (obj.type_obj == PyDict_Type) {
        size = obj.as(PyDictObject).active_count;
    } else if (obj.type_obj == PyString_Type) {
        size = obj.as(PyStringObject).len;
    } else if (obj.type_obj == PySet_Type) {
        size = obj.as(collections.PySetObject).entries_size;
    } else if (obj.type_obj == PyFrozenSet_Type) {
        size = obj.as(collections.PySetObject).entries_size;
    } else if (obj.type_obj == PyBytes_Type) {
        size = obj.as(primitives.PyBytesObject).len;
    } else if (obj.type_obj == PyByteArray_Type) {
        size = obj.as(primitives.PyByteArrayObject).size;
    } else if (obj.type_obj == PyInstance_Type) {
        const inst = obj.as(class_mod.PyInstanceObject);
        if (try vm.lookupClassAttribute(inst.class_obj, "__len__")) |len_method| {
            defer len_method.decRef(vm.mm);
            const bound_len = try class_mod.PyMethodObject.create(obj, len_method, vm.mm);
            defer bound_len.base.decRef(vm.mm);
            const res = try vm.callCallable(&bound_len.base, &[_]*PyObject{});
            defer res.decRef(vm.mm);
            if (res.type_obj != &primitives.PyInt_Type) return error.TypeError;
            size = @intCast(res.as(PyIntObject).value);
        } else {
            return error.TypeError;
        }
    } else {
        return error.TypeError;
    }
    return try PyIntObject.create(@intCast(size), vm.mm);
}

// type(x)
pub fn builtinType(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const obj = args[0];
    if (obj.type_obj == PyInstance_Type) {
        const inst = obj.as(@import("../objects/class.zig").PyInstanceObject);
        inst.class_obj.base.incRef();
        return &inst.class_obj.base;
    }
    const wrapper = try PyTypeWrapper.create(obj.type_obj, vm.mm);
    return &wrapper.base;
}

// range(stop) or range(start, stop)
pub fn builtinRange(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    
    var start: i64 = 0;
    var stop: i64 = 0;
    if (args.len == 1) {
        if (args[0].type_obj != PyInt_Type) return error.TypeError;
        stop = args[0].as(PyIntObject).value;
    } else {
        if (args[0].type_obj != PyInt_Type) return error.TypeError;
        if (args[1].type_obj != PyInt_Type) return error.TypeError;
        start = args[0].as(PyIntObject).value;
        stop = args[1].as(PyIntObject).value;
    }
    
    const count: usize = if (stop > start) @intCast(stop - start) else 0;
    const list = try PyListObject.create(count, vm.mm);
    errdefer list.base.decRef(vm.mm);
    
    var val = start;
    while (val < stop) : (val += 1) {
        const int_obj = try PyIntObject.create(val, vm.mm);
        try list.append(int_obj, vm.mm);
        int_obj.decRef(vm.mm);
    }
    return &list.base;
}

// str(x)
pub fn builtinStr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len > 1) return error.TypeError;
    if (args.len == 0) {
        return try PyStringObject.create("", vm.mm);
    }
    
    const obj = args[0];
    if (obj.type_obj.tp_str) |str_fn| {
        return try str_fn(obj, vm.mm);
    } else if (obj.type_obj.tp_repr) |repr_fn| {
        return try repr_fn(obj, vm.mm);
    }
    return try PyStringObject.create(obj.type_obj.name, vm.mm);
}

// print(*args) — writes to VM's stdout writer
pub fn builtinPrint(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    
    for (args, 0..) |obj, i| {
        if (i > 0) try vm.stdout_writer.print(" ", .{});
        var str_obj: *PyObject = undefined;
        if (obj.type_obj.tp_str) |str_fn| {
            str_obj = try str_fn(obj, vm.mm);
        } else if (obj.type_obj.tp_repr) |repr_fn| {
            str_obj = try repr_fn(obj, vm.mm);
        } else {
            str_obj = try PyStringObject.create(obj.type_obj.name, vm.mm);
        }
        defer str_obj.decRef(vm.mm);
        try vm.stdout_writer.print("{s}", .{str_obj.as(PyStringObject).value()});
    }
    try vm.stdout_writer.print("\n", .{});
    
    PyNone.incRef();
    return PyNone;
}

// int(x)
pub fn builtinInt(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len > 1) return error.TypeError;
    if (args.len == 0) {
        return try PyIntObject.create(0, vm.mm);
    }
    const obj = args[0];
    if (obj.type_obj == PyInt_Type) {
        obj.incRef();
        return obj;
    } else if (obj.type_obj == PyFloat_Type) {
        const val: i64 = @intFromFloat(obj.as(@import("../objects/primitives.zig").PyFloatObject).value);
        return try PyIntObject.create(val, vm.mm);
    } else if (obj.type_obj == PyString_Type) {
        const s = obj.as(PyStringObject).value();
        const val = std.fmt.parseInt(i64, s, 10) catch return error.ValueError;
        return try PyIntObject.create(val, vm.mm);
    } else if (obj.type_obj == PyBool_Type) {
        const bval = obj == PyTrue;
        return try PyIntObject.create(if (bval) 1 else 0, vm.mm);
    }
    return error.TypeError;
}

// float(x)
pub fn builtinFloat(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len > 1) return error.TypeError;
    if (args.len == 0) {
        const primitives_mod = @import("../objects/primitives.zig");
        return try primitives_mod.PyFloatObject.create(0.0, vm.mm);
    }
    const obj = args[0];
    const primitives_mod = @import("../objects/primitives.zig");
    if (obj.type_obj == PyFloat_Type) {
        obj.incRef();
        return obj;
    } else if (obj.type_obj == PyInt_Type) {
        const val: f64 = @floatFromInt(obj.as(PyIntObject).value);
        return try primitives_mod.PyFloatObject.create(val, vm.mm);
    } else if (obj.type_obj == PyString_Type) {
        const s = obj.as(PyStringObject).value();
        const val = std.fmt.parseFloat(f64, s) catch return error.ValueError;
        return try primitives_mod.PyFloatObject.create(val, vm.mm);
    }
    return error.TypeError;
}

fn toFloatVal(obj: *PyObject) anyerror!f64 {
    const primitives_mod = @import("../objects/primitives.zig");
    if (obj.type_obj == PyFloat_Type) {
        return obj.as(primitives_mod.PyFloatObject).value;
    } else if (obj.type_obj == PyInt_Type) {
        return @floatFromInt(obj.as(primitives_mod.PyIntObject).value);
    } else if (obj.type_obj == PyBool_Type) {
        return if (obj == primitives_mod.PyTrue) 1.0 else 0.0;
    } else if (obj.type_obj == PyString_Type) {
        const s = obj.as(primitives_mod.PyStringObject).value();
        return std.fmt.parseFloat(f64, s) catch return error.ValueError;
    }
    return error.TypeError;
}

// complex([real[, imag]])
pub fn builtinComplex(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const primitives_mod = @import("../objects/primitives.zig");
    if (args.len == 0) {
        return try primitives_mod.PyComplexObject.create(0.0, 0.0, vm.mm);
    } else if (args.len == 1) {
        const arg = args[0];
        if (arg.type_obj == PyComplex_Type) {
            arg.incRef();
            return arg;
        }
        const real_val = try toFloatVal(arg);
        return try primitives_mod.PyComplexObject.create(real_val, 0.0, vm.mm);
    } else if (args.len == 2) {
        const real_val = try toFloatVal(args[0]);
        const imag_val = try toFloatVal(args[1]);
        return try primitives_mod.PyComplexObject.create(real_val, imag_val, vm.mm);
    }
    return error.TypeError;
}

// bool(x)
pub fn builtinBool(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len > 1) return error.TypeError;
    if (args.len == 0) {
        PyFalse.incRef();
        return PyFalse;
    }
    const obj = args[0];
    // Simple truthiness
    if (obj == PyTrue or obj == PyFalse) {
        obj.incRef();
        return obj;
    }
    if (obj == PyNone) {
        PyFalse.incRef();
        return PyFalse;
    }
    if (obj.type_obj == PyInt_Type) {
        const v = obj.as(PyIntObject).value;
        const res = if (v != 0) PyTrue else PyFalse;
        res.incRef();
        return res;
    }
    if (obj.type_obj == PyString_Type) {
        const s = obj.as(PyStringObject).value();
        const res = if (s.len > 0) PyTrue else PyFalse;
        res.incRef();
        return res;
    }
    PyTrue.incRef();
    return PyTrue;
}

// abs(x)
pub fn builtinAbs(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    if (obj.type_obj == PyInt_Type) {
        const v = obj.as(PyIntObject).value;
        return try PyIntObject.create(if (v < 0) -v else v, vm.mm);
    }
    const primitives_mod = @import("../objects/primitives.zig");
    if (obj.type_obj == PyFloat_Type) {
        const v = obj.as(primitives_mod.PyFloatObject).value;
        return try primitives_mod.PyFloatObject.create(if (v < 0) -v else v, vm.mm);
    }
    return error.TypeError;
}

// max(*args) or max(iterable)
pub fn builtinMax(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) return error.TypeError;
    // If single list argument, treat elements as args
    if (args.len == 1 and args[0].type_obj == PyList_Type) {
        const lst = args[0].as(PyListObject);
        if (lst.size == 0) return error.ValueError;
        var best = lst.items.?[0];
        for (lst.items.?[1..lst.size]) |item| {
            if (item.type_obj.tp_richcompare) |cmp| {
                const gt = try cmp(item, best, .Gt, vm.mm);
                const is_gt = gt == PyTrue;
                gt.decRef(vm.mm);
                if (is_gt) best = item;
            }
        }
        best.incRef();
        return best;
    }
    var best = args[0];
    for (args[1..]) |item| {
        if (item.type_obj.tp_richcompare) |cmp| {
            const gt = try cmp(item, best, .Gt, vm.mm);
            const is_gt = gt == PyTrue;
            gt.decRef(vm.mm);
            if (is_gt) best = item;
        }
    }
    best.incRef();
    return best;
}

// min(*args) or min(iterable)
pub fn builtinMin(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) return error.TypeError;
    if (args.len == 1 and args[0].type_obj == PyList_Type) {
        const lst = args[0].as(PyListObject);
        if (lst.size == 0) return error.ValueError;
        var best = lst.items.?[0];
        for (lst.items.?[1..lst.size]) |item| {
            if (item.type_obj.tp_richcompare) |cmp| {
                const lt = try cmp(item, best, .Lt, vm.mm);
                const is_lt = lt == PyTrue;
                lt.decRef(vm.mm);
                if (is_lt) best = item;
            }
        }
        best.incRef();
        return best;
    }
    var best = args[0];
    for (args[1..]) |item| {
        if (item.type_obj.tp_richcompare) |cmp| {
            const lt = try cmp(item, best, .Lt, vm.mm);
            const is_lt = lt == PyTrue;
            lt.decRef(vm.mm);
            if (is_lt) best = item;
        }
    }
    best.incRef();
    return best;
}

// sum(iterable)
pub fn builtinSum(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1) return error.TypeError;
    const iterable = args[0];
    if (iterable.type_obj != PyList_Type) return error.TypeError;
    const lst = iterable.as(PyListObject);
    var total: i64 = 0;
    if (args.len >= 2 and args[1].type_obj == PyInt_Type) {
        total = args[1].as(PyIntObject).value;
    }
    for (lst.items.?[0..lst.size]) |item| {
        if (item.type_obj != PyInt_Type) return error.TypeError;
        total += item.as(PyIntObject).value;
    }
    return try PyIntObject.create(total, vm.mm);
}

// list(iterable) -> list
fn iterateIterable(
    iterable: *PyObject,
    mm: *PyMemoryManager,
    context: *anyopaque,
    callback: *const fn (ctx: *anyopaque, item: *PyObject, mm: *PyMemoryManager) anyerror!void,
) anyerror!void {
    const name = iterable.type_obj.name;
    if (std.mem.eql(u8, name, "list")) {
        const lst = iterable.as(PyListObject);
        if (lst.size > 0) {
            for (lst.items.?[0..lst.size]) |item| {
                try callback(context, item, mm);
            }
        }
    } else if (std.mem.eql(u8, name, "tuple")) {
        const tup = iterable.as(PyTupleObject);
        for (tup.items()) |item| {
            try callback(context, item, mm);
        }
    } else if (std.mem.eql(u8, name, "dict")) {
        const dict = iterable.as(PyDictObject);
        for (0..dict.indices_size) |i| {
            const entry_idx = dict.indices[i];
            if (entry_idx < 0) continue;
            const entry = &dict.entries[@intCast(entry_idx)];
            try callback(context, entry.key.?, mm);
        }
    } else if (std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "frozenset")) {
        const set_obj = iterable.as(collections.PySetObject);
        for (0..set_obj.indices_size) |i| {
            const entry_idx = set_obj.indices[i];
            if (entry_idx < 0) continue;
            const entry = &set_obj.entries[@intCast(entry_idx)];
            try callback(context, entry.key.?, mm);
        }
    } else if (std.mem.eql(u8, name, "str")) {
        const str_val = iterable.as(PyStringObject).value();
        for (str_val) |c| {
            const char_str = try PyStringObject.create(&[_]u8{c}, mm);
            errdefer char_str.decRef(mm);
            try callback(context, char_str, mm);
            char_str.decRef(mm);
        }
    } else if (std.mem.eql(u8, name, "bytes")) {
        const bytes_val = iterable.as(primitives.PyBytesObject).value();
        for (bytes_val) |b| {
            const int_obj = try PyIntObject.create(b, mm);
            errdefer int_obj.decRef(mm);
            try callback(context, int_obj, mm);
            int_obj.decRef(mm);
        }
    } else if (std.mem.eql(u8, name, "bytearray")) {
        const ba_val = iterable.as(primitives.PyByteArrayObject).value();
        for (ba_val) |b| {
            const int_obj = try PyIntObject.create(b, mm);
            errdefer int_obj.decRef(mm);
            try callback(context, int_obj, mm);
            int_obj.decRef(mm);
        }
    } else {
        return error.TypeError;
    }
}

fn listAppendCallback(ctx: *anyopaque, item: *PyObject, mm: *PyMemoryManager) anyerror!void {
    const lst: *PyListObject = @alignCast(@ptrCast(ctx));
    try lst.append(item, mm);
}

// list(iterable) -> list
pub fn builtinList(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const lst = try PyListObject.create(0, vm.mm);
        return &lst.base;
    }
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    const lst = try PyListObject.create(0, vm.mm);
    errdefer lst.base.decRef(vm.mm);
    try iterateIterable(obj, vm.mm, lst, listAppendCallback);
    return &lst.base;
}

// tuple(iterable) -> tuple
pub fn builtinTuple(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const tup = try PyTupleObject.create(0, vm.mm);
        return &tup.base;
    }
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    const temp_lst = try PyListObject.create(0, vm.mm);
    defer temp_lst.base.decRef(vm.mm);
    try iterateIterable(obj, vm.mm, temp_lst, listAppendCallback);
    
    const tup = try PyTupleObject.create(temp_lst.size, vm.mm);
    const slice = tup.items();
    for (temp_lst.items.?[0..temp_lst.size], 0..) |item, i| {
        item.incRef();
        PyNone.decRef(vm.mm);
        slice[i] = item;
    }
    return &tup.base;
}

fn setAddCallback(ctx: *anyopaque, item: *PyObject, mm: *PyMemoryManager) anyerror!void {
    const set_obj: *collections.PySetObject = @alignCast(@ptrCast(ctx));
    try set_obj.add(item, mm);
}

// set(iterable) -> set
pub fn builtinSet(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const set_obj = try collections.PySetObject.create(vm.mm);
        return &set_obj.base;
    }
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    const set_obj = try collections.PySetObject.create(vm.mm);
    errdefer set_obj.base.decRef(vm.mm);
    try iterateIterable(obj, vm.mm, set_obj, setAddCallback);
    return &set_obj.base;
}

// frozenset(iterable) -> frozenset
pub fn builtinFrozenSet(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const set_obj = try collections.PySetObject.createFrozen(vm.mm);
        return &set_obj.base;
    }
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    const set_obj = try collections.PySetObject.createFrozen(vm.mm);
    errdefer set_obj.base.decRef(vm.mm);
    try iterateIterable(obj, vm.mm, set_obj, setAddCallback);
    return &set_obj.base;
}

fn bytesAppendCallback(ctx: *anyopaque, item: *PyObject, mm: *PyMemoryManager) anyerror!void {
    const list_bytes: *std.ArrayList(u8) = @alignCast(@ptrCast(ctx));
    if (item.type_obj != PyInt_Type) {
        return error.TypeError;
    }
    const val = item.as(PyIntObject).value;
    if (val < 0 or val > 255) {
        return error.ValueError;
    }
    try list_bytes.append(mm.allocator, @intCast(val));
}

// bytes() -> bytes
pub fn builtinBytes(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        return try primitives.PyBytesObject.create("", vm.mm);
    }
    if (args.len > 1) return error.TypeError;
    const obj = args[0];
    
    if (obj.type_obj == PyInt_Type) {
        const len_val = obj.as(PyIntObject).value;
        if (len_val < 0) return error.ValueError;
        const ulen: usize = @intCast(len_val);
        const buf = try vm.mm.allocator.alloc(u8, ulen);
        defer vm.mm.allocator.free(buf);
        @memset(buf, 0);
        return try primitives.PyBytesObject.create(buf, vm.mm);
    } else if (obj.type_obj == PyString_Type) {
        const s = obj.as(PyStringObject).value();
        return try primitives.PyBytesObject.create(s, vm.mm);
    } else {
        var list_bytes = std.ArrayList(u8).empty;
        defer list_bytes.deinit(vm.mm.allocator);
        try iterateIterable(obj, vm.mm, &list_bytes, bytesAppendCallback);
        return try primitives.PyBytesObject.create(list_bytes.items, vm.mm);
    }
}

fn bytearrayAppendCallback(ctx: *anyopaque, item: *PyObject, mm: *PyMemoryManager) anyerror!void {
    const ba: *primitives.PyByteArrayObject = @alignCast(@ptrCast(ctx));
    if (item.type_obj != PyInt_Type) {
        return error.TypeError;
    }
    const val = item.as(PyIntObject).value;
    if (val < 0 or val > 255) {
        return error.ValueError;
    }
    try ba.append(@intCast(val), mm);
}

// bytearray() -> bytearray
pub fn builtinByteArray(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const ba = try primitives.PyByteArrayObject.create(0, vm.mm);
        return &ba.base;
    }
    if (args.len > 1) return error.TypeError;
    const obj = args[0];
    
    if (obj.type_obj == PyInt_Type) {
        const len_val = obj.as(PyIntObject).value;
        if (len_val < 0) return error.ValueError;
        const ulen: usize = @intCast(len_val);
        const ba = try primitives.PyByteArrayObject.create(ulen, vm.mm);
        errdefer ba.base.decRef(vm.mm);
        if (ulen > 0) {
            @memset(ba.items.?[0..ulen], 0);
            ba.size = ulen;
        }
        return &ba.base;
    } else if (obj.type_obj == PyString_Type) {
        const s = obj.as(PyStringObject).value();
        const ba = try primitives.PyByteArrayObject.create(s.len, vm.mm);
        errdefer ba.base.decRef(vm.mm);
        if (s.len > 0) {
            @memcpy(ba.items.?[0..s.len], s);
            ba.size = s.len;
        }
        return &ba.base;
    } else {
        const ba = try primitives.PyByteArrayObject.create(0, vm.mm);
        errdefer ba.base.decRef(vm.mm);
        try iterateIterable(obj, vm.mm, ba, bytearrayAppendCallback);
        return &ba.base;
    }
}

// dict() -> empty dict
pub fn builtinDict(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = args;
    const d = try PyDictObject.create(vm.mm);
    return &d.base;
}


// input([prompt]) -> str
pub fn builtinInput(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len > 1) return error.TypeError;

    if (args.len == 1) {
        const prompt_obj = args[0];
        var str_obj: *PyObject = undefined;
        if (prompt_obj.type_obj.tp_str) |str_fn| {
            str_obj = try str_fn(prompt_obj, vm.mm);
        } else if (prompt_obj.type_obj.tp_repr) |repr_fn| {
            str_obj = try repr_fn(prompt_obj, vm.mm);
        } else {
            str_obj = try PyStringObject.create(prompt_obj.type_obj.name, vm.mm);
        }
        defer str_obj.decRef(vm.mm);
        try vm.stdout_writer.print("{s}", .{str_obj.as(PyStringObject).value()});
    }

    var line_writer = std.Io.Writer.Allocating.init(vm.allocator);
    defer line_writer.deinit();

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), vm.io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    _ = stdin_reader.streamDelimiter(&line_writer.writer, '\n') catch |err| {
        if (err == error.EndOfStream) {
            // EOF
        } else return err;
    };

    const line = line_writer.written();
    const line_trimmed = std.mem.trim(u8, line, " \r\n");
    return try PyStringObject.create(line_trimmed, vm.mm);
}

pub fn builtinOpen(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    
    const path_obj = args[0];
    if (path_obj.type_obj != PyString_Type) return error.TypeError;
    const path = path_obj.as(PyStringObject).value();

    var mode: []const u8 = "r";
    if (args.len == 2) {
        if (args[1].type_obj != PyString_Type) return error.TypeError;
        mode = args[1].as(PyStringObject).value();
    }

    const cwd = std.Io.Dir.cwd();
    var file: std.Io.File = undefined;
    var pos: u64 = 0;
    if (std.mem.eql(u8, mode, "r")) {
        file = try cwd.openFile(vm.io, path, .{ .mode = .read_only });
    } else if (std.mem.eql(u8, mode, "w")) {
        file = try cwd.createFile(vm.io, path, .{});
    } else if (std.mem.eql(u8, mode, "a")) {
        file = cwd.openFile(vm.io, path, .{ .mode = .read_write }) catch try cwd.createFile(vm.io, path, .{});
        pos = try file.length(vm.io);
    } else {
        return error.ValueError;
    }

    const file_mod = @import("../objects/file.zig");
    const file_obj = try file_mod.PyFileObject.create(file, vm.io, mode, pos, vm.mm);
    return &file_obj.base;
}

pub fn builtinHelp(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    try vm.stdout_writer.print("Help on {s} object:\n\n", .{obj.type_obj.name});
    if (obj.type_obj.tp_repr) |repr_fn| {
        const repr_str = try repr_fn(obj, vm.mm);
        defer repr_str.decRef(vm.mm);
        try vm.stdout_writer.print("{s}\n", .{repr_str.as(PyStringObject).value()});
    } else {
        try vm.stdout_writer.print("<{s} object>\n", .{obj.type_obj.name});
    }
    PyNone.incRef();
    return PyNone;
}

fn isSubclass(a: *PyObject, b: *PyObject) bool {
    if (a == b) return true;
    if (a.type_obj == PyClass_Type) {
        const cls_a = a.as(@import("../objects/class.zig").PyClassObject);
        if (cls_a.base_class) |base| {
            return isSubclass(base, b);
        }
    }
    return false;
}

fn checkIsinstance(obj: *PyObject, classinfo: *PyObject, vm: *anyopaque) anyerror!bool {
    const VM = @import("../vm/vm.zig").VM;
    const vm_ptr: *VM = @ptrCast(@alignCast(vm));
    if (classinfo.type_obj == PyTuple_Type) {
        const tup = classinfo.as(PyTupleObject);
        for (tup.items()) |item| {
            if (try checkIsinstance(obj, item, vm_ptr)) return true;
        }
        return false;
    }
    
    if (classinfo.type_obj == PyClass_Type) {
    if (obj.type_obj == PyInstance_Type) {
            const inst = obj.as(@import("../objects/class.zig").PyInstanceObject);
            return isSubclass(&inst.class_obj.base, classinfo);
        }
        return false;
    } else if (classinfo.type_obj == &PyTypeWrapper_Type) {
        const wrapper = classinfo.as(PyTypeWrapper);
        if (wrapper.type_ptr == PyInstance_Type) {
            return obj.type_obj == PyInstance_Type;
        }
        if (wrapper.type_ptr == PyInt_Type and obj.type_obj == PyBool_Type) {
            return true;
        }
        return obj.type_obj == wrapper.type_ptr;
    } else if (classinfo.type_obj == PyBuiltinFunction_Type) {
        const func = classinfo.as(PyBuiltinFunctionObject);
        if (std.mem.eql(u8, func.name, "int") and obj.type_obj == PyBool_Type) {
            return true;
        }
        return std.mem.eql(u8, func.name, obj.type_obj.name);
    } else {
        return error.TypeError;
    }
}

pub fn builtinIsinstance(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    if (args.len != 2) return error.TypeError;
    const obj = args[0];
    const classinfo = args[1];
    const result = try checkIsinstance(obj, classinfo, vm_opaque);
    const res = if (result) PyTrue else PyFalse;
    res.incRef();
    return res;
}

pub fn builtinHasattr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    if (args[1].type_obj != PyString_Type) return error.TypeError;
    
    const obj = args[0];
    const name = args[1].as(PyStringObject).value();
    
    const attr = vm.loadAttribute(obj, name) catch |err| {
        if (err == error.AttributeError or err == error.TypeError) {
            PyFalse.incRef();
            return PyFalse;
        }
        return err;
    };
    attr.decRef(vm.mm);
    PyTrue.incRef();
    return PyTrue;
}

pub fn builtinGetattr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    if (args[1].type_obj != PyString_Type) return error.TypeError;
    
    const obj = args[0];
    const name = args[1].as(PyStringObject).value();
    
    const attr = vm.loadAttribute(obj, name) catch |err| {
        if (err == error.AttributeError and args.len == 3) {
            args[2].incRef();
            return args[2];
        }
        return err;
    };
    return attr;
}

pub fn builtinSetattr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 3) return error.TypeError;
    if (args[1].type_obj != PyString_Type) return error.TypeError;
    
    const obj = args[0];
    const name = args[1].as(PyStringObject).value();
    const val = args[2];
    
    try vm.storeAttribute(obj, name, val);
    PyNone.incRef();
    return PyNone;
}

pub fn builtinRepr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const obj = args[0];
    if (obj.type_obj.tp_repr) |repr_fn| {
        return try repr_fn(obj, vm.mm);
    } else if (obj.type_obj.tp_str) |str_fn| {
        return try str_fn(obj, vm.mm);
    }
    return try PyStringObject.create(obj.type_obj.name, vm.mm);
}

pub fn builtinId(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    return try PyIntObject.create(@intCast(@intFromPtr(args[0])), vm.mm);
}

pub fn builtinChr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (args[0].type_obj != PyInt_Type) return error.TypeError;
    const val = args[0].as(PyIntObject).value;
    if (val < 0 or val > 1114111) return error.ValueError;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(val), &buf) catch return error.ValueError;
    return try PyStringObject.create(buf[0..len], vm.mm);
}

pub fn builtinOrd(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (args[0].type_obj != PyString_Type) return error.TypeError;
    const s = args[0].as(PyStringObject).value();
    if (s.len == 0) return error.TypeError;
    const cp = std.unicode.utf8Decode(s) catch return error.ValueError;
    const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch return error.ValueError;
    if (s.len != cp_len) return error.TypeError;
    return try PyIntObject.create(@intCast(cp), vm.mm);
}

pub fn builtinHex(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (args[0].type_obj != PyInt_Type) return error.TypeError;
    const val = args[0].as(PyIntObject).value;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "0x{x}", .{val}) catch return error.ValueError;
    return try PyStringObject.create(s, vm.mm);
}

pub fn builtinOct(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (args[0].type_obj != PyInt_Type) return error.TypeError;
    const val = args[0].as(PyIntObject).value;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "0o{o}", .{val}) catch return error.ValueError;
    return try PyStringObject.create(s, vm.mm);
}

pub fn builtinBin(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (args[0].type_obj != PyInt_Type) return error.TypeError;
    const val = args[0].as(PyIntObject).value;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "0b{b}", .{val}) catch return error.ValueError;
    return try PyStringObject.create(s, vm.mm);
}

fn iterableToList(iterable: *PyObject, mm: *PyMemoryManager) anyerror!*PyListObject {
    const name = iterable.type_obj.name;
    if (std.mem.eql(u8, name, "list")) {
        const list = iterable.as(PyListObject);
        list.base.incRef();
        return list;
    } else if (std.mem.eql(u8, name, "tuple")) {
        const tup = iterable.as(PyTupleObject);
        const list = try PyListObject.create(tup.size, mm);
        const tup_items = tup.items();
        for (tup_items[0..tup.size], 0..) |item, i| {
            item.incRef();
            list.items.?[i] = item;
        }
        list.size = tup.size;
        return list;
    } else if (std.mem.eql(u8, name, "str")) {
        const str_val = iterable.as(PyStringObject).value();
        const list = try PyListObject.create(str_val.len, mm);
        for (str_val, 0..) |ch, i| {
            const ch_str = try PyStringObject.create(str_val[i..i+1], mm);
            _ = ch;
            list.items.?[i] = ch_str;
        }
        list.size = str_val.len;
        return list;
    } else if (std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "frozenset")) {
        const set_obj = iterable.as(collections.PySetObject);
        const list = try PyListObject.create(set_obj.active_count, mm);
        var list_idx: usize = 0;
        for (0..set_obj.entries_size) |i| {
            if (set_obj.entries[i].key) |key| {
                key.incRef();
                list.items.?[list_idx] = key;
                list_idx += 1;
            }
        }
        list.size = list_idx;
        return list;
    } else if (std.mem.eql(u8, name, "dict")) {
        const dict = iterable.as(PyDictObject);
        const list = try PyListObject.create(dict.active_count, mm);
        var list_idx: usize = 0;
        for (0..dict.entries_size) |i| {
            if (dict.entries[i].key) |key| {
                key.incRef();
                list.items.?[list_idx] = key;
                list_idx += 1;
            }
        }
        list.size = list_idx;
        return list;
    } else {
        return error.TypeError;
    }
}

pub fn builtinEnumerate(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    
    const iterable = args[0];
    var start: i64 = 0;
    if (args.len == 2) {
        if (args[1].type_obj != PyInt_Type) return error.TypeError;
        start = args[1].as(PyIntObject).value;
    }
    
    const list = try iterableToList(iterable, vm.mm);
    defer list.base.decRef(vm.mm);
    
    const result_list = try PyListObject.create(list.size, vm.mm);
    errdefer result_list.base.decRef(vm.mm);
    
    for (0..list.size) |i| {
        const idx = try PyIntObject.create(start + @as(i64, @intCast(i)), vm.mm);
        defer idx.decRef(vm.mm);
        
        const item = list.items.?[i];
        
        const tuple = try PyTupleObject.create(2, vm.mm);
        const tup_items = tuple.items();
        
        tup_items[0].decRef(vm.mm);
        idx.incRef();
        tup_items[0] = idx;
        
        tup_items[1].decRef(vm.mm);
        item.incRef();
        tup_items[1] = item;
        
        try result_list.append(&tuple.base, vm.mm);
        tuple.base.decRef(vm.mm);
    }
    return &result_list.base;
}

pub fn builtinZip(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const lst = try PyListObject.create(0, vm.mm);
        return &lst.base;
    }
    
    var lists = try vm.allocator.alloc(*PyListObject, args.len);
    defer vm.allocator.free(lists);
    for (args, 0..) |arg, i| {
        lists[i] = try iterableToList(arg, vm.mm);
    }
    defer {
        for (lists) |list| {
            list.base.decRef(vm.mm);
        }
    }
    
    var min_size: usize = lists[0].size;
    for (lists[1..]) |list| {
        if (list.size < min_size) min_size = list.size;
    }
    
    const result_list = try PyListObject.create(min_size, vm.mm);
    errdefer result_list.base.decRef(vm.mm);
    
    for (0..min_size) |i| {
        const tuple = try PyTupleObject.create(args.len, vm.mm);
        const tup_items = tuple.items();
        for (lists, 0..) |list, j| {
            tup_items[j].decRef(vm.mm);
            const item = list.items.?[i];
            item.incRef();
            tup_items[j] = item;
        }
        try result_list.append(&tuple.base, vm.mm);
        tuple.base.decRef(vm.mm);
    }
    return &result_list.base;
}

pub fn builtinMap(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    
    const callable = args[0];
    const iterable = args[1];
    
    const list = try iterableToList(iterable, vm.mm);
    defer list.base.decRef(vm.mm);
    
    const result_list = try PyListObject.create(list.size, vm.mm);
    errdefer result_list.base.decRef(vm.mm);
    
    for (0..list.size) |i| {
        const item = list.items.?[i];
        
        var call_args = [_]*PyObject{item};
        const res = try vm.callCallable(callable, &call_args);
        
        try result_list.append(res, vm.mm);
        res.decRef(vm.mm);
    }
    return &result_list.base;
}

pub fn builtinFilter(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    
    const callable = args[0];
    const iterable = args[1];
    
    const list = try iterableToList(iterable, vm.mm);
    defer list.base.decRef(vm.mm);
    
    const result_list = try PyListObject.create(0, vm.mm);
    errdefer result_list.base.decRef(vm.mm);
    
    for (0..list.size) |i| {
        const item = list.items.?[i];
        var is_ok = false;
        
        if (callable == PyNone) {
            is_ok = try vm.isTrueObj(item);
        } else {
            var call_args = [_]*PyObject{item};
            const res = try vm.callCallable(callable, &call_args);
            is_ok = try vm.isTrueObj(res);
            res.decRef(vm.mm);
        }
        
        if (is_ok) {
            try result_list.append(item, vm.mm);
        }
    }
    return &result_list.base;
}

pub fn builtinSorted(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const iterable = args[0];
    const orig_list = try iterableToList(iterable, vm.mm);
    defer orig_list.base.decRef(vm.mm);
    
    const list = try PyListObject.create(orig_list.size, vm.mm);
    errdefer list.base.decRef(vm.mm);
    
    for (0..orig_list.size) |i| {
        const item = orig_list.items.?[i];
        item.incRef();
        try list.append(item, vm.mm);
        item.decRef(vm.mm);
    }
    
    if (list.size > 1) {
        var i: usize = 0;
        while (i < list.size - 1) : (i += 1) {
            var j: usize = 0;
            while (j < list.size - i - 1) : (j += 1) {
                const a = list.items.?[j];
                const b = list.items.?[j + 1];
                if (a.type_obj.tp_richcompare) |cmp| {
                    const gt = try cmp(a, b, .Gt, vm.mm);
                    const is_gt = gt == PyTrue;
                    gt.decRef(vm.mm);
                    if (is_gt) {
                        list.items.?[j] = b;
                        list.items.?[j + 1] = a;
                    }
                }
            }
        }
    }
    return &list.base;
}

pub fn builtinReversed(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const iterable = args[0];
    const orig_list = try iterableToList(iterable, vm.mm);
    defer orig_list.base.decRef(vm.mm);
    
    const list = try PyListObject.create(orig_list.size, vm.mm);
    errdefer list.base.decRef(vm.mm);
    
    var i = orig_list.size;
    while (i > 0) {
        i -= 1;
        const item = orig_list.items.?[i];
        try list.append(item, vm.mm);
    }
    return &list.base;
}

pub fn builtinAny(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const orig_list = try iterableToList(args[0], vm.mm);
    defer orig_list.base.decRef(vm.mm);
    
    for (0..orig_list.size) |i| {
        const item = orig_list.items.?[i];
        if (try vm.isTrueObj(item)) {
            PyTrue.incRef();
            return PyTrue;
        }
    }
    PyFalse.incRef();
    return PyFalse;
}

pub fn builtinCallable(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    const callable = obj.type_obj.tp_call != null or
        obj.type_obj == PyFunction_Type or
        obj.type_obj == PyBuiltinFunction_Type or
        obj.type_obj == PyMethod_Type or
        obj.type_obj == &PyTypeWrapper_Type or
        obj.type_obj == PyClass_Type;
    return if (callable) PyTrue else PyFalse;
}

pub fn builtinDelattr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const obj = args[0];
    const name_obj = args[1];
    if (name_obj.type_obj != PyString_Type) return error.TypeError;
    const name = name_obj.as(PyStringObject).value();
    const key_str = try PyStringObject.create(name, vm.mm);
    defer key_str.decRef(vm.mm);
    if (obj.type_obj == PyInstance_Type) {
        const instance = obj.as(class_mod.PyInstanceObject);
        const dict = instance.dict.as(PyDictObject);
        _ = dict.delItem(key_str, vm.mm) catch {};
        PyNone.incRef();
        return PyNone;
    }
    return error.TypeError;
}

pub fn builtinDivmod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const a = args[0];
    const b = args[1];
    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
        const va = a.as(PyIntObject).value;
        const vb = b.as(PyIntObject).value;
        if (vb == 0) return error.ZeroDivisionError;
        const result = try PyTupleObject.create(2, vm.mm);
        const items = result.items();
        items[0] = try PyIntObject.create(@divFloor(va, vb), vm.mm);
        items[1] = try PyIntObject.create(@rem(va, vb), vm.mm);
        return &result.base;
    }
    if (a.type_obj == PyFloat_Type or b.type_obj == PyFloat_Type) {
        const fa = if (a.type_obj == PyFloat_Type) a.as(primitives.PyFloatObject).value else @as(f64, @floatFromInt(a.as(PyIntObject).value));
        const fb = if (b.type_obj == PyFloat_Type) b.as(primitives.PyFloatObject).value else @as(f64, @floatFromInt(b.as(PyIntObject).value));
        if (fb == 0.0) return error.ZeroDivisionError;
        const result = try PyTupleObject.create(2, vm.mm);
        const items = result.items();
        items[0] = try primitives.PyFloatObject.create(@floor(fa / fb), vm.mm);
        items[1] = try primitives.PyFloatObject.create(@rem(fa, fb), vm.mm);
        return &result.base;
    }
    return error.TypeError;
}

pub fn builtinGlobals(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 0) return error.TypeError;
    const f = &vm.frames[vm.frame_count - 1];
    const dict = try PyDictObject.create(vm.mm);
    var it = f.globals.iterator();
    while (it.next()) |entry| {
        const key = try PyStringObject.create(entry.key_ptr.*, vm.mm);
        try dict.setItem(key, entry.value_ptr.*, vm.mm);
        key.decRef(vm.mm);
    }
    return &dict.base;
}

pub fn builtinLocals(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 0) return error.TypeError;
    const f = &vm.frames[vm.frame_count - 1];
    const dict = try PyDictObject.create(vm.mm);
    var it = f.locals.iterator();
    while (it.next()) |entry| {
        const key = try PyStringObject.create(entry.key_ptr.*, vm.mm);
        try dict.setItem(key, entry.value_ptr.*, vm.mm);
        key.decRef(vm.mm);
    }
    return &dict.base;
}

pub fn builtinVars(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    if (args.len == 0) {
        return try builtinLocals(args, vm_opaque);
    }
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    if (obj.type_obj == PyInstance_Type) {
        const inst = obj.as(@import("../objects/class.zig").PyInstanceObject);
        inst.dict.incRef();
        return inst.dict;
    } else if (obj.type_obj == PyClass_Type) {
        const cls = obj.as(@import("../objects/class.zig").PyClassObject);
        cls.dict.incRef();
        return cls.dict;
    } else if (obj.type_obj == PyDict_Type) {
        obj.incRef();
        return obj;
    }
    return error.TypeError;
}

fn asciiEscape(val: []const u8, mm: *PyMemoryManager) !*PyObject {
    var needs_escape = false;
    for (val) |c| { if (c > 127) { needs_escape = true; break; } }
    if (!needs_escape) return try PyStringObject.create(val, mm);
    var result = std.ArrayList(u8).empty;
    defer result.deinit(mm.allocator);
    for (val) |c| {
        if (c <= 127) { try result.append(mm.allocator, c); }
        else {
            try result.appendSlice(mm.allocator, "\\x");
            var hex_buf: [2]u8 = undefined;
            _ = try std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{c});
            try result.appendSlice(mm.allocator, &hex_buf);
        }
    }
    return try PyStringObject.create(result.items, mm);
}

pub fn builtinAscii(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    if (obj.type_obj.tp_repr) |repr_fn| {
        const repr_str = try repr_fn(obj, vm.mm);
        defer repr_str.decRef(vm.mm);
        if (repr_str.type_obj != PyString_Type) return repr_str;
        return try asciiEscape(repr_str.as(PyStringObject).value(), vm.mm);
    } else if (obj.type_obj.tp_str) |str_fn| {
        const str_val = try str_fn(obj, vm.mm);
        defer str_val.decRef(vm.mm);
        if (str_val.type_obj != PyString_Type) return str_val;
        return try asciiEscape(str_val.as(PyStringObject).value(), vm.mm);
    }
    return try PyStringObject.create(obj.type_obj.name, vm.mm);
}

pub fn builtinSuper(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    
    var self_obj: *PyObject = undefined;
    var lookup_class: ?*PyClassObject = null;
    
    if (args.len == 0) {
        // Dynamic zero-argument lookup: retrieve calling frame
        if (vm.frame_count < 1) return error.RuntimeError;
        const calling_frame = &vm.frames[vm.frame_count - 1];
        
        // Grab 'self' from fastlocals[0]
        if (calling_frame.fastlocals.len == 0 or calling_frame.fastlocals[0] == null) {
            std.debug.print("RuntimeError: super() called outside of method context (no self argument)\n", .{});
            return error.RuntimeError;
        }
        self_obj = calling_frame.fastlocals[0].?;
        
        const func = calling_frame.func orelse {
            std.debug.print("RuntimeError: super() called outside of method context (no active function)\n", .{});
            return error.RuntimeError;
        };
        
        // Find which class defines `func`
        if (self_obj.type_obj == &@import("../objects/class.zig").PyInstance_Type) {
            const inst = self_obj.as(@import("../objects/class.zig").PyInstanceObject);
            var current_class: ?*PyClassObject = inst.class_obj;
            while (current_class) |cls| {
                const dict = cls.dict.as(@import("../objects/collections.zig").PyDictObject);
                var idx: usize = 0;
                var found = false;
                while (idx < dict.entries_size) : (idx += 1) {
                    const entry = &dict.entries[idx];
                    if (entry.key != null and entry.value != null and entry.value.? == &func.base) {
                        found = true;
                        break;
                    }
                }
                if (found) {
                    if (cls.base_class) |bc| {
                        lookup_class = bc.as(PyClassObject);
                    }
                    break;
                }
                current_class = if (cls.base_class) |bc| bc.as(PyClassObject) else null;
            }
            if (lookup_class == null) {
                // Default fallback if not found in chain
                if (inst.class_obj.base_class) |bc| {
                    lookup_class = bc.as(PyClassObject);
                }
            }
        } else {
            std.debug.print("TypeError: super() argument 1 must be instance, not '{s}'\n", .{self_obj.type_obj.name});
            return error.TypeError;
        }
    } else if (args.len == 2) {
        const cls_arg = args[0];
        self_obj = args[1];
        if (cls_arg.type_obj == PyClass_Type) {
            const cls = cls_arg.as(PyClassObject);
            if (cls.base_class) |bc| {
                lookup_class = bc.as(PyClassObject);
            }
        } else {
            return error.TypeError;
        }
    } else {
        return error.TypeError;
    }
    
    const super_class = @import("../objects/class.zig");
    const super_obj = try super_class.PySuperObject.create(self_obj, lookup_class, vm.mm);
    return &super_obj.base;
}

pub fn builtinIssubclass(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 2) return error.TypeError;
    const cls = args[0];
    const base = args[1];
    if (cls.type_obj == PyClass_Type and base.type_obj == PyClass_Type) {
        const res = if (isSubclass(cls, base)) PyTrue else PyFalse;
        res.incRef();
        return res;
    }
    return error.TypeError;
}

pub fn intBitLengthMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyInt_Type) return error.TypeError;
    const val = self_obj.as(PyIntObject).value;
    if (val == 0) return try PyIntObject.create(0, vm.mm);
    const abs_val = if (val > 0) @as(u64, @intCast(val)) else @as(u64, @intCast(-val));
    const bits = @as(i64, @intCast(@bitSizeOf(u64) - @clz(abs_val)));
    return try PyIntObject.create(bits, vm.mm);
}

pub fn intToBytesMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 3 or args.len > 4) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyInt_Type) return error.TypeError;
    const val = self_obj.as(PyIntObject).value;
    if (args[1].type_obj != PyInt_Type) return error.TypeError;
    if (args[2].type_obj != PyString_Type) return error.TypeError;
    const length = args[1].as(PyIntObject).value;
    const byteorder = args[2].as(PyStringObject).value();
    const signed = if (args.len == 4) (args[3] == PyTrue) else false;
    if (length <= 0) return error.TypeError;
    if (!std.mem.eql(u8, byteorder, "big") and !std.mem.eql(u8, byteorder, "little")) return error.TypeError;
    if (!signed and val < 0) return error.TypeError;
    
    const is_big = std.mem.eql(u8, byteorder, "big");
    const byte_len = @as(usize, @intCast(length));
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(vm.mm.allocator);
    
    var abs_val: u64 = @bitCast(val);
    if (val >= 0) {
        abs_val = @as(u64, @intCast(val));
    }
    // For negative with signed=True, use two's complement
    if (signed and val < 0) {
        abs_val = @as(u64, @bitCast(val));
    } else if (val < 0) {
        abs_val = @as(u64, @intCast(-val));
    }
    
    for (0..byte_len) |_| {
        try buf.append(vm.mm.allocator, @as(u8, @intCast(abs_val & 0xFF)));
        abs_val >>= 8;
    }
    
    if (is_big) {
        // reverse to big-endian
        var i: usize = 0;
        var j: usize = byte_len - 1;
        while (i < j) {
            const tmp = buf.items[i];
            buf.items[i] = buf.items[j];
            buf.items[j] = tmp;
            i += 1;
            j -= 1;
        }
    }
    
    return try primitives.PyBytesObject.create(buf.items, vm.mm);
}

pub fn intFromBytesMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const bytes_obj = args[0];
    if (bytes_obj.type_obj != PyBytes_Type and bytes_obj.type_obj != PyByteArray_Type) return error.TypeError;
    if (args[1].type_obj != PyString_Type) return error.TypeError;
    const bytes_val = if (bytes_obj.type_obj == PyBytes_Type)
        bytes_obj.as(primitives.PyBytesObject).value()
    else
        bytes_obj.as(primitives.PyByteArrayObject).value();
    const byteorder = args[1].as(PyStringObject).value();
    const signed = if (args.len == 3) (args[2] == PyTrue) else false;
    if (!std.mem.eql(u8, byteorder, "big") and !std.mem.eql(u8, byteorder, "little")) return error.TypeError;
    if (bytes_val.len == 0) return error.TypeError;
    if (bytes_val.len > 8) return error.TypeError;
    
    const is_big = std.mem.eql(u8, byteorder, "big");
    var result: u64 = 0;
    
    if (is_big) {
        for (bytes_val) |b| {
            result = (result << 8) | @as(u64, b);
        }
    } else {
        var i: usize = bytes_val.len;
        while (i > 0) {
            i -= 1;
            result = (result << 8) | @as(u64, bytes_val[i]);
        }
    }
    
    if (signed and (bytes_val[if (is_big) 0 else bytes_val.len - 1] & 0x80) != 0) {
        return try PyIntObject.create(@as(i64, @bitCast(~result +% 1)), vm.mm);
    }
    
    return try PyIntObject.create(@as(i64, @intCast(result)), vm.mm);
}

pub fn dictSetdefaultMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyDict_Type) return error.TypeError;
    const dict = self_obj.as(PyDictObject);
    const key = args[1];
    const default_val = if (args.len == 3) args[2] else PyNone;
    if (try dict.getItem(key, vm.mm)) |val| {
        val.incRef();
        return val;
    }
    try dict.setItem(key, default_val, vm.mm);
    default_val.incRef();
    return default_val;
}

pub fn dictPopitemMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyDict_Type) return error.TypeError;
    const dict = self_obj.as(PyDictObject);
    for (0..dict.indices_size) |i| {
        const entry_idx = dict.indices[i];
        if (entry_idx < 0) continue;
        const entry = &dict.entries[@intCast(entry_idx)];
        const k = entry.key.?;
        const val = entry.value.?;
        k.incRef();
        val.incRef();
        _ = dict.delItem(k, vm.mm) catch {};
        const result = try PyTupleObject.create(2, vm.mm);
        const items = result.items();
        items[0] = k;
        items[1] = val;
        return &result.base;
    }
    return error.KeyError;
}

pub fn setCopyMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PySet_Type) return error.TypeError;
    const set = self_obj.as(collections.PySetObject);
    const new_set = try collections.PySetObject.create(vm.mm);
    errdefer new_set.base.decRef(vm.mm);
    for (0..set.entries_size) |i| {
        if (set.entries[i].key) |key| {
            try new_set.add(key, vm.mm);
        }
    }
    return &new_set.base;
}

pub fn builtinAll(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const orig_list = try iterableToList(args[0], vm.mm);
    defer orig_list.base.decRef(vm.mm);
    
    for (0..orig_list.size) |i| {
        const item = orig_list.items.?[i];
        if (!(try vm.isTrueObj(item))) {
            PyFalse.incRef();
            return PyFalse;
        }
    }
    PyTrue.incRef();
    return PyTrue;
}

pub fn builtinPow(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    
    const a = args[0];
    const b = args[1];
    
    if (args.len == 2) {
        if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
            const base_val = a.as(primitives.PyIntObject).value;
            const exp_val = b.as(primitives.PyIntObject).value;
            var result: i64 = 1;
            var i_exp: i64 = 0;
            while (i_exp < exp_val) : (i_exp += 1) {
                result = result * base_val;
            }
            return try PyIntObject.create(result, vm.mm);
        } else {
            const fa = if (a.type_obj == PyFloat_Type)
                a.as(primitives.PyFloatObject).value
            else if (a.type_obj == PyInt_Type)
                @as(f64, @floatFromInt(a.as(primitives.PyIntObject).value))
            else
                return error.TypeError;
            const fb = if (b.type_obj == PyFloat_Type)
                b.as(primitives.PyFloatObject).value
            else if (b.type_obj == PyInt_Type)
                @as(f64, @floatFromInt(b.as(primitives.PyIntObject).value))
            else
                return error.TypeError;
            return try primitives.PyFloatObject.create(std.math.pow(f64, fa, fb), vm.mm);
        }
    } else {
        if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type and args[2].type_obj == PyInt_Type) {
            const base_val = a.as(primitives.PyIntObject).value;
            const exp_val = b.as(primitives.PyIntObject).value;
            const mod_val = args[2].as(primitives.PyIntObject).value;
            if (mod_val == 0) return error.ZeroDivisionError;
            
            var res: i64 = 1;
            var base = @rem(base_val, mod_val);
            var exp = exp_val;
            while (exp > 0) {
                if (@rem(exp, 2) == 1) {
                    res = @rem(res * base, mod_val);
                }
                exp = @divFloor(exp, 2);
                base = @rem(base * base, mod_val);
            }
            return try PyIntObject.create(res, vm.mm);
        }
        return error.TypeError;
    }
}

pub fn builtinRound(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    
    const num = args[0];
    var ndigits: i64 = 0;
    if (args.len == 2) {
        if (args[1].type_obj != PyInt_Type) return error.TypeError;
        ndigits = args[1].as(PyIntObject).value;
    }
    
    const val = if (num.type_obj == PyFloat_Type)
        num.as(primitives.PyFloatObject).value
    else if (num.type_obj == PyInt_Type)
        @as(f64, @floatFromInt(num.as(PyIntObject).value))
    else
        return error.TypeError;
        
    if (args.len == 1) {
        return try PyIntObject.create(@intFromFloat(std.math.round(val)), vm.mm);
    } else {
        const factor = std.math.pow(f64, 10.0, @floatFromInt(ndigits));
        return try primitives.PyFloatObject.create(std.math.round(val * factor) / factor, vm.mm);
    }
}

pub fn builtinHash(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const obj = args[0];
    if (obj.type_obj.tp_hash) |hash_fn| {
        const h = try hash_fn(obj);
        return try PyIntObject.create(h, vm.mm);
    } else {
        const h: i64 = @intCast(@intFromPtr(obj));
        return try PyIntObject.create(h, vm.mm);
    }
}

pub fn setAddMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const key = args[1];
    if (self_obj.type_obj != PySet_Type) return error.TypeError;
    try self_obj.as(collections.PySetObject).add(key, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn setRemoveMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const key = args[1];
    if (self_obj.type_obj != PySet_Type) return error.TypeError;
    const removed = try self_obj.as(collections.PySetObject).remove(key, vm.mm);
    if (!removed) return error.KeyError;
    PyNone.incRef();
    return PyNone;
}

pub fn setDiscardMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const key = args[1];
    if (self_obj.type_obj != PySet_Type) return error.TypeError;
    _ = try self_obj.as(collections.PySetObject).remove(key, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn setIssubsetMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const other = args[1];
    if (self_obj.type_obj != PySet_Type and self_obj.type_obj != PyFrozenSet_Type) return error.TypeError;
    const self_set = self_obj.as(collections.PySetObject);

    const is_other_set = other.type_obj == PySet_Type or other.type_obj == PyFrozenSet_Type;
    const other_set: *collections.PySetObject = if (is_other_set)
        other.as(collections.PySetObject)
    else
        blk: {
            const s = try collections.PySetObject.create(vm.mm);
            errdefer s.base.decRef(vm.mm);
            try iterateIterable(other, vm.mm, s, setAddCallback);
            break :blk s;
        };
    defer if (!is_other_set) other_set.base.decRef(vm.mm);

    for (0..self_set.entries_size) |i| {
        if (self_set.entries[i].key) |key| {
            if (!try other_set.contains(key, vm.mm)) {
                PyFalse.incRef();
                return PyFalse;
            }
        }
    }
    PyTrue.incRef();
    return PyTrue;
}

pub fn setIssupersetMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const other = args[1];
    if (self_obj.type_obj != PySet_Type and self_obj.type_obj != PyFrozenSet_Type) return error.TypeError;
    const self_set = self_obj.as(collections.PySetObject);

    const is_other_set = other.type_obj == PySet_Type or other.type_obj == PyFrozenSet_Type;
    const other_set: *collections.PySetObject = if (is_other_set)
        other.as(collections.PySetObject)
    else
        blk: {
            const s = try collections.PySetObject.create(vm.mm);
            errdefer s.base.decRef(vm.mm);
            try iterateIterable(other, vm.mm, s, setAddCallback);
            break :blk s;
        };
    defer if (!is_other_set) other_set.base.decRef(vm.mm);

    for (0..other_set.entries_size) |i| {
        if (other_set.entries[i].key) |key| {
            if (!try self_set.contains(key, vm.mm)) {
                PyFalse.incRef();
                return PyFalse;
            }
        }
    }
    PyTrue.incRef();
    return PyTrue;
}

pub fn setIsdisjointMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const other = args[1];
    if (self_obj.type_obj != PySet_Type and self_obj.type_obj != PyFrozenSet_Type) return error.TypeError;
    const self_set = self_obj.as(collections.PySetObject);

    const is_other_set = other.type_obj == PySet_Type or other.type_obj == PyFrozenSet_Type;
    const other_set: *collections.PySetObject = if (is_other_set)
        other.as(collections.PySetObject)
    else
        blk: {
            const s = try collections.PySetObject.create(vm.mm);
            errdefer s.base.decRef(vm.mm);
            try iterateIterable(other, vm.mm, s, setAddCallback);
            break :blk s;
        };
    defer if (!is_other_set) other_set.base.decRef(vm.mm);

    const iter_set = if (self_set.entries_size <= other_set.entries_size) self_set else other_set;
    const check_set = if (self_set.entries_size <= other_set.entries_size) other_set else self_set;
    for (0..iter_set.entries_size) |i| {
        if (iter_set.entries[i].key) |key| {
            if (try check_set.contains(key, vm.mm)) {
                PyFalse.incRef();
                return PyFalse;
            }
        }
    }
    PyTrue.incRef();
    return PyTrue;
}

pub fn setUpdateMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const other = args[1];
    if (self_obj.type_obj != PySet_Type) return error.TypeError;
    const self_set = self_obj.as(collections.PySetObject);

    if (other.type_obj == PySet_Type or other.type_obj == PyFrozenSet_Type) {
        const other_set = other.as(collections.PySetObject);
        for (0..other_set.entries_size) |i| {
            if (other_set.entries[i].key) |key| {
                try self_set.add(key, vm.mm);
            }
        }
    } else {
        try iterateIterable(other, vm.mm, self_set, setAddCallback);
    }
    PyNone.incRef();
    return PyNone;
}

pub fn setDifferenceUpdateMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const other = args[1];
    if (self_obj.type_obj != PySet_Type) return error.TypeError;
    const self_set = self_obj.as(collections.PySetObject);

    if (other.type_obj == PySet_Type or other.type_obj == PyFrozenSet_Type) {
        const other_set = other.as(collections.PySetObject);
        for (0..other_set.entries_size) |i| {
            if (other_set.entries[i].key) |key| {
                _ = try self_set.remove(key, vm.mm);
            }
        }
    } else {
        const other_set = try collections.PySetObject.create(vm.mm);
        errdefer other_set.base.decRef(vm.mm);
        try iterateIterable(other, vm.mm, other_set, setAddCallback);
        for (0..other_set.entries_size) |i| {
            if (other_set.entries[i].key) |key| {
                _ = try self_set.remove(key, vm.mm);
            }
        }
        other_set.base.decRef(vm.mm);
    }
    PyNone.incRef();
    return PyNone;
}

pub fn setIntersectionUpdateMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const other = args[1];
    if (self_obj.type_obj != PySet_Type) return error.TypeError;
    const self_set = self_obj.as(collections.PySetObject);

    const is_other_set = other.type_obj == PySet_Type or other.type_obj == PyFrozenSet_Type;
    const other_set: *collections.PySetObject = if (is_other_set)
        other.as(collections.PySetObject)
    else
        blk: {
            const s = try collections.PySetObject.create(vm.mm);
            errdefer s.base.decRef(vm.mm);
            try iterateIterable(other, vm.mm, s, setAddCallback);
            break :blk s;
        };
    defer if (!is_other_set) other_set.base.decRef(vm.mm);

    var i: usize = 0;
    while (i < self_set.entries_size) {
        if (self_set.entries[i].key) |key| {
            if (!try other_set.contains(key, vm.mm)) {
                _ = try self_set.remove(key, vm.mm);
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    PyNone.incRef();
    return PyNone;
}

pub fn setSymmetricDifferenceUpdateMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const other = args[1];
    if (self_obj.type_obj != PySet_Type) return error.TypeError;
    const self_set = self_obj.as(collections.PySetObject);

    if (other.type_obj == PySet_Type or other.type_obj == PyFrozenSet_Type) {
        const other_set = other.as(collections.PySetObject);
        for (0..other_set.entries_size) |i| {
            if (other_set.entries[i].key) |key| {
                const removed = try self_set.remove(key, vm.mm);
                if (!removed) {
                    try self_set.add(key, vm.mm);
                }
            }
        }
    } else {
        const other_set = try collections.PySetObject.create(vm.mm);
        errdefer other_set.base.decRef(vm.mm);
        try iterateIterable(other, vm.mm, other_set, setAddCallback);
        for (0..other_set.entries_size) |i| {
            if (other_set.entries[i].key) |key| {
                const removed = try self_set.remove(key, vm.mm);
                if (!removed) {
                    try self_set.add(key, vm.mm);
                }
            }
        }
        other_set.base.decRef(vm.mm);
    }
    PyNone.incRef();
    return PyNone;
}

pub fn listAppendMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const item = args[1];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    try self_obj.as(collections.PyListObject).append(item, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listInsertMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 3) return error.TypeError;
    const self_obj = args[0];
    const index = args[1];
    const item = args[2];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    if (index.type_obj != PyInt_Type) return error.TypeError;
    try self_obj.as(collections.PyListObject).insert(index.as(PyIntObject).value, item, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listPopMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm;
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    const self = self_obj.as(collections.PyListObject);
    if (self.size == 0) return error.IndexError;
    const index: ?i64 = if (args.len == 2) blk: {
        if (args[1].type_obj != PyInt_Type) return error.TypeError;
        break :blk args[1].as(PyIntObject).value;
    } else null;
    return self.pop(index);
}

pub fn listRemoveMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const item = args[1];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    try self_obj.as(collections.PyListObject).remove(item, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listIndexMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const item = args[1];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    const idx = try self_obj.as(collections.PyListObject).index(item, vm.mm);
    return try PyIntObject.create(idx, vm.mm);
}

pub fn listCountMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const item = args[1];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    const cnt = try self_obj.as(collections.PyListObject).count(item, vm.mm);
    return try PyIntObject.create(cnt, vm.mm);
}

pub fn listReverseMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm;
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    self_obj.as(collections.PyListObject).reverse();
    PyNone.incRef();
    return PyNone;
}

pub fn listSortMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    try self_obj.as(collections.PyListObject).sort(vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listExtendMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const iterable = args[1];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    try self_obj.as(collections.PyListObject).extend(iterable, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listClearMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    self_obj.as(collections.PyListObject).clear(vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listCopyMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyList_Type) return error.TypeError;
    const list = self_obj.as(collections.PyListObject);
    const new_list = try collections.PyListObject.create(0, vm.mm);
    errdefer new_list.base.decRef(vm.mm);
    if (list.size > 0) {
        for (0..list.size) |i| {
            const item = list.items.?[i];
            try new_list.append(item, vm.mm);
        }
    }
    return &new_list.base;
}

pub fn dictKeysMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyDict_Type) return error.TypeError;
    const result = try self_obj.as(collections.PyDictObject).keys(vm.mm);
    return &result.base;
}

pub fn dictValuesMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyDict_Type) return error.TypeError;
    const result = try self_obj.as(collections.PyDictObject).values(vm.mm);
    return &result.base;
}

pub fn dictItemsMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyDict_Type) return error.TypeError;
    const result = try self_obj.as(collections.PyDictObject).items(vm.mm);
    return &result.base;
}

pub fn dictGetMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const self_obj = args[0];
    const key = args[1];
    if (self_obj.type_obj != PyDict_Type) return error.TypeError;
    if (self_obj.as(collections.PyDictObject).get(key, vm.mm)) |val| {
        val.incRef();
        return val;
    }
    if (args.len == 3) {
        args[2].incRef();
        return args[2];
    }
    PyNone.incRef();
    return PyNone;
}

pub fn dictPopMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const self_obj = args[0];
    const key = args[1];
    if (self_obj.type_obj != PyDict_Type) return error.TypeError;
    const result = self_obj.as(collections.PyDictObject).dictPop(key, vm.mm) catch |err| {
        if (err == error.KeyError and args.len == 3) {
            args[2].incRef();
            return args[2];
        }
        return err;
    };
    return result;
}

pub fn dictUpdateMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const other = args[1];
    if (self_obj.type_obj != PyDict_Type) return error.TypeError;
    if (other.type_obj != PyDict_Type) return error.TypeError;
    try self_obj.as(collections.PyDictObject).update(other.as(collections.PyDictObject), vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn dictClearMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyDict_Type) return error.TypeError;
    self_obj.as(collections.PyDictObject).clear(vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn dictCopyMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyDict_Type) return error.TypeError;
    const result = try self_obj.as(collections.PyDictObject).copy(vm.mm);
    return &result.base;
}

pub fn stringSplitMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const s = self.value();

    const result = try PyListObject.create(0, vm.mm);
    if (args.len == 2) {
        const sep_obj = args[1];
        if (sep_obj.type_obj != PyString_Type) return error.TypeError;
        const sep_str = sep_obj.as(PyStringObject).value();
        if (sep_str.len == 0) return error.ValueError;
        var start: usize = 0;
        while (std.mem.indexOf(u8, s[start..], sep_str)) |pos| {
            const part = s[start..][0..pos];
            const str_obj = try PyStringObject.create(part, vm.mm);
            try result.append(str_obj, vm.mm);
            str_obj.decRef(vm.mm);
            start += pos + sep_str.len;
        }
        const last = s[start..];
        const str_obj = try PyStringObject.create(last, vm.mm);
        try result.append(str_obj, vm.mm);
        str_obj.decRef(vm.mm);
    } else {
        var start: usize = 0;
        while (start < s.len and std.ascii.isWhitespace(s[start])) {
            start += 1;
        }
        while (start < s.len) {
            var end = start;
            while (end < s.len and !std.ascii.isWhitespace(s[end])) {
                end += 1;
            }
            const part = s[start..end];
            const str_obj = try PyStringObject.create(part, vm.mm);
            try result.append(str_obj, vm.mm);
            str_obj.decRef(vm.mm);
            start = end;
            while (start < s.len and std.ascii.isWhitespace(s[start])) {
                start += 1;
            }
        }
    }
    return &result.base;
}

pub fn stringJoinMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const iterable = args[1];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    if (iterable.type_obj != PyList_Type) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const sep = self.value();
    const lst = iterable.as(PyListObject);

    const items = if (lst.items) |it| it[0..lst.size] else &[_]*PyObject{};
    var total_len: usize = 0;
    for (items, 0..) |item, i| {
        if (item.type_obj != PyString_Type) return error.TypeError;
        total_len += item.as(PyStringObject).len;
        if (i < items.len - 1) total_len += sep.len;
    }

    const buf = try vm.mm.allocBytes(total_len);
    var offset: usize = 0;
    for (items, 0..) |item, i| {
        const part = item.as(PyStringObject).value();
        @memcpy(buf[offset..][0..part.len], part);
        offset += part.len;
        if (i < items.len - 1) {
            @memcpy(buf[offset..][0..sep.len], sep);
            offset += sep.len;
        }
    }
    return try PyStringObject.create(buf, vm.mm);
}

pub fn stringReplaceMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 3 or args.len > 4) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const old_obj = args[1];
    const new_obj = args[2];
    if (old_obj.type_obj != PyString_Type) return error.TypeError;
    if (new_obj.type_obj != PyString_Type) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const s = self.value();
    const old_str = old_obj.as(PyStringObject).value();
    const new_str = new_obj.as(PyStringObject).value();
    const count: usize = if (args.len == 4) blk: {
        if (args[3].type_obj != PyInt_Type) return error.TypeError;
        const c = args[3].as(PyIntObject).value;
        break :blk if (c < 0) std.math.maxInt(usize) else @intCast(c);
    } else std.math.maxInt(usize);

    if (old_str.len == 0) return error.ValueError;

    var alloc_writer = std.Io.Writer.Allocating.init(vm.mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;

    var remaining = count;
    var start: usize = 0;
    while (remaining > 0) {
        if (std.mem.indexOf(u8, s[start..], old_str)) |pos| {
            try writer.writeAll(s[start..][0..pos]);
            try writer.writeAll(new_str);
            start += pos + old_str.len;
            remaining -= 1;
        } else {
            break;
        }
    }
    try writer.writeAll(s[start..]);
    return try PyStringObject.create(alloc_writer.written(), vm.mm);
}

pub fn stringStripMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const s = self.value();

    if (args.len == 2) {
        const chars_obj = args[1];
        if (chars_obj.type_obj != PyString_Type) return error.TypeError;
        const chars = chars_obj.as(PyStringObject).value();
        const trimmed = std.mem.trim(u8, s, chars);
        return try PyStringObject.create(trimmed, vm.mm);
    } else {
        var start: usize = 0;
        while (start < s.len and std.ascii.isWhitespace(s[start])) {
            start += 1;
        }
        if (start == s.len) return try PyStringObject.create("", vm.mm);
        var end = s.len - 1;
        while (end > start and std.ascii.isWhitespace(s[end])) {
            end -= 1;
        }
        return try PyStringObject.create(s[start..end + 1], vm.mm);
    }
}

pub fn stringLowerMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const s = self.value();

    var alloc_writer = std.Io.Writer.Allocating.init(vm.mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    for (s) |c| {
        try writer.writeByte(std.ascii.toLower(c));
    }
    return try PyStringObject.create(alloc_writer.written(), vm.mm);
}

pub fn stringUpperMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const s = self.value();

    var alloc_writer = std.Io.Writer.Allocating.init(vm.mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    for (s) |c| {
        try writer.writeByte(std.ascii.toUpper(c));
    }
    return try PyStringObject.create(alloc_writer.written(), vm.mm);
}

pub fn stringStartsWithMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm;
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const prefix_obj = args[1];
    if (prefix_obj.type_obj != PyString_Type) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const prefix = prefix_obj.as(PyStringObject).value();
    const s = self.value();
    if (prefix.len > s.len) return PyFalse;
    return if (std.mem.eql(u8, s[0..prefix.len], prefix)) PyTrue else PyFalse;
}

pub fn stringEndsWithMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm;
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const suffix_obj = args[1];
    if (suffix_obj.type_obj != PyString_Type) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const suffix = suffix_obj.as(PyStringObject).value();
    const s = self.value();
    if (suffix.len > s.len) return PyFalse;
    return if (std.mem.eql(u8, s[s.len - suffix.len ..], suffix)) PyTrue else PyFalse;
}

pub fn builtinProperty(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const PyPropertyObject = @import("../objects/property.zig").PyPropertyObject;

    const fget = if (args.len >= 1) args[0] else null;
    const fset = if (args.len >= 2) args[1] else null;
    const fdel = if (args.len >= 3) args[2] else null;
    const doc = if (args.len >= 4) args[3] else null;

    const prop = try PyPropertyObject.create(fget, fset, fdel, doc, vm.mm);
    return &prop.base;
}

pub fn builtinClassmethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const func = args[0];
    return try @import("../objects/classmethod.zig").PyClassMethodObject.create(func, vm.mm);
}

pub fn builtinStaticmethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const func = args[0];
    return try @import("../objects/staticmethod.zig").PyStaticMethodObject.create(func, vm.mm);
}

pub fn bytearrayAppendMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const item = args[1];
    if (self_obj.type_obj != PyByteArray_Type) return error.TypeError;
    if (item.type_obj != PyInt_Type) return error.TypeError;
    const val = item.as(PyIntObject).value;
    if (val < 0 or val > 255) return error.ValueError;
    try self_obj.as(primitives.PyByteArrayObject).append(@intCast(val), vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn bytesDecodeMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 3) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyBytes_Type and self_obj.type_obj != PyByteArray_Type) return error.TypeError;
    const val = if (self_obj.type_obj == PyBytes_Type)
        self_obj.as(primitives.PyBytesObject).value()
    else
        self_obj.as(primitives.PyByteArrayObject).value();
    return try PyStringObject.create(val, vm.mm);
}

pub fn bytesHexMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyBytes_Type and self_obj.type_obj != PyByteArray_Type) return error.TypeError;
    const val = if (self_obj.type_obj == PyBytes_Type)
        self_obj.as(primitives.PyBytesObject).value()
    else
        self_obj.as(primitives.PyByteArrayObject).value();
    var result = std.ArrayList(u8).empty;
    defer result.deinit(vm.mm.allocator);
    for (val) |b| {
        var hex_buf: [2]u8 = undefined;
        _ = try std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{b});
        try result.appendSlice(vm.mm.allocator, &hex_buf);
    }
    return try PyStringObject.create(result.items, vm.mm);
}

pub fn bytesFromHexMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (args[0].type_obj != PyString_Type) return error.TypeError;
    const hex_str = args[0].as(PyStringObject).value();
    if (hex_str.len % 2 != 0) return error.TypeError;
    var result = std.ArrayList(u8).empty;
    defer result.deinit(vm.mm.allocator);
    var i: usize = 0;
    while (i < hex_str.len) {
        const byte_val = (try std.fmt.charToDigit(hex_str[i], 16)) * 16 + (try std.fmt.charToDigit(hex_str[i + 1], 16));
        try result.append(vm.mm.allocator, byte_val);
        i += 2;
    }
    return try primitives.PyBytesObject.create(result.items, vm.mm);
}

pub fn builtinNext(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    
    const iterable = args[0];
    const default_val = if (args.len == 2) args[1] else null;
    
    if (iterable.type_obj == PyGenerator_Type) {
        const gen = iterable.as(@import("../objects/function.zig").PyGeneratorObject);
        if (gen.is_closed) {
            if (default_val) |dv| {
                dv.incRef();
                return dv;
            }
            return error.StopIteration;
        }
        
        const prev_frame_count = vm.frame_count;
        
        vm.frames[vm.frame_count] = gen.frame;
        vm.frame_count += 1;
        
        try vm.runLoop(prev_frame_count);
        
        if (gen.is_closed) {
            if (default_val) |dv| {
                dv.incRef();
                return dv;
            }
            return error.StopIteration;
        }
        
        const caller_frame = &vm.frames[vm.frame_count - 1];
        return caller_frame.pop();
    } else if (iterable.type_obj == PyInstance_Type) {
        // User-defined iterator — call __next__
        const next_method = vm.loadAttribute(iterable, "__next__") catch {
            if (default_val) |dv| {
                dv.incRef();
                return dv;
            }
            return error.StopIteration;
        };
        defer next_method.decRef(vm.mm);
        
        const prev_frame_count = vm.frame_count;
        try vm.callObject(next_method, &.{}, null);
        if (vm.frame_count > prev_frame_count) {
            vm.suppress_exception_handling = true;
            defer vm.suppress_exception_handling = false;
            vm.runLoop(prev_frame_count) catch |err| {
                if (err == error.PythonException) {
                    if (default_val) |dv| {
                        dv.incRef();
                        return dv;
                    }
                    return error.StopIteration;
                }
                return err;
            };
        }
        
        const result = vm.last_result orelse {
            if (default_val) |dv| {
                dv.incRef();
                return dv;
            }
            return error.StopIteration;
        };
        vm.last_result = null;
        return result;
    } else {
        return error.TypeError;
    }
}

pub fn stringCapitalizeMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    if (s.len == 0) { self_obj.incRef(); return self_obj; }
    var buf = try vm.mm.allocBytes(s.len);
    errdefer vm.mm.freeBytes(buf);
    for (s, 0..) |c, i| {
        buf[i] = if (i == 0) std.ascii.toUpper(c) else std.ascii.toLower(c);
    }
    return try PyStringObject.create(buf, vm.mm);
}

pub fn stringTitleMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    var buf = try vm.mm.allocBytes(s.len);
    errdefer vm.mm.freeBytes(buf);
    var prev_alpha = false;
    for (s, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c)) {
            buf[i] = if (prev_alpha) std.ascii.toLower(c) else std.ascii.toUpper(c);
            prev_alpha = true;
        } else {
            buf[i] = c;
            prev_alpha = false;
        }
    }
    return try PyStringObject.create(buf, vm.mm);
}

pub fn stringSwapcaseMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    var buf = try vm.mm.allocBytes(s.len);
    errdefer vm.mm.freeBytes(buf);
    for (s, 0..) |c, i| {
        buf[i] = if (std.ascii.isUpper(c)) std.ascii.toLower(c) else if (std.ascii.isLower(c)) std.ascii.toUpper(c) else c;
    }
    return try PyStringObject.create(buf, vm.mm);
}

pub fn stringLstripMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    const chars = if (args.len == 2) blk: {
        if (args[1].type_obj != PyString_Type) return error.TypeError;
        break :blk args[1].as(PyStringObject).value();
    } else " \t\n\r\x0c\x0b";
    var start: usize = 0;
    while (start < s.len and std.mem.indexOfScalar(u8, chars, s[start]) != null) {
        start += 1;
    }
    if (start == 0) { self_obj.incRef(); return self_obj; }
    return try PyStringObject.create(s[start..], vm.mm);
}

pub fn stringRstripMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    const chars = if (args.len == 2) blk: {
        if (args[1].type_obj != PyString_Type) return error.TypeError;
        break :blk args[1].as(PyStringObject).value();
    } else " \t\n\r\x0c\x0b";
    var end = s.len;
    while (end > 0 and std.mem.indexOfScalar(u8, chars, s[end - 1]) != null) {
        end -= 1;
    }
    if (end == s.len) { self_obj.incRef(); return self_obj; }
    return try PyStringObject.create(s[0..end], vm.mm);
}

pub fn stringFindMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 4) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const sub = args[1];
    if (sub.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    const needle = sub.as(PyStringObject).value();
    var start: usize = 0;
    var end: usize = s.len;
    if (args.len >= 3) {
        if (args[2].type_obj != PyInt_Type) return error.TypeError;
        start = @intCast(@max(0, args[2].as(PyIntObject).value));
    }
    if (args.len >= 4) {
        if (args[3].type_obj != PyInt_Type) return error.TypeError;
        end = @intCast(@max(0, @min(args[3].as(PyIntObject).value, @as(i64, @intCast(s.len)))));
    }
    if (start >= end or start >= s.len) return PyIntObject.create(-1, vm.mm);
    const search_space = if (end <= s.len) s[start..end] else s[start..];
    return if (std.mem.indexOf(u8, search_space, needle)) |pos|
        try PyIntObject.create(@intCast(start + pos), vm.mm)
    else
        try PyIntObject.create(-1, vm.mm);
}

pub fn stringCountMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 4) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const sub = args[1];
    if (sub.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    const needle = sub.as(PyStringObject).value();
    var start: usize = 0;
    var end: usize = s.len;
    if (args.len >= 3) {
        if (args[2].type_obj != PyInt_Type) return error.TypeError;
        start = @intCast(@max(0, args[2].as(PyIntObject).value));
    }
    if (args.len >= 4) {
        if (args[3].type_obj != PyInt_Type) return error.TypeError;
        end = @intCast(@max(0, @min(args[3].as(PyIntObject).value, @as(i64, @intCast(s.len)))));
    }
    if (needle.len == 0) {
        const range_len = if (end > s.len) s.len - start else if (end > start) end - start else 0;
        return try PyIntObject.create(@intCast(range_len + 1), vm.mm);
    }
    const search_space = if (end <= s.len and start < end) s[start..end] else return try PyIntObject.create(0, vm.mm);
    var count: i64 = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, search_space[pos..], needle)) |found| {
        count += 1;
        pos += found + needle.len;
        if (pos >= search_space.len) break;
    }
    return try PyIntObject.create(count, vm.mm);
}

pub fn stringCenterMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    if (args[1].type_obj != PyInt_Type) return error.TypeError;
    const width = @max(0, args[1].as(PyIntObject).value);
    const fillchar: u8 = if (args.len == 3) blk: {
        if (args[2].type_obj != PyString_Type) return error.TypeError;
        const fc = args[2].as(PyStringObject).value();
        if (fc.len != 1) return error.TypeError;
        break :blk fc[0];
    } else ' ';
    const s = self_obj.as(PyStringObject).value();
    if (@as(i64, @intCast(s.len)) >= width) { self_obj.incRef(); return self_obj; }
    const total_pad = @as(usize, @intCast(width)) - s.len;
    const left_pad = total_pad / 2;
    var buf = try vm.mm.allocBytes(@intCast(width));
    errdefer vm.mm.freeBytes(buf);
    @memset(buf[0..left_pad], fillchar);
    @memcpy(buf[left_pad..][0..s.len], s);
    @memset(buf[left_pad + s.len ..], fillchar);
    return try PyStringObject.create(buf, vm.mm);
}

pub fn stringLjustMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    if (args[1].type_obj != PyInt_Type) return error.TypeError;
    const width = @max(0, args[1].as(PyIntObject).value);
    const fillchar: u8 = if (args.len == 3) blk: {
        if (args[2].type_obj != PyString_Type) return error.TypeError;
        const fc = args[2].as(PyStringObject).value();
        if (fc.len != 1) return error.TypeError;
        break :blk fc[0];
    } else ' ';
    const s = self_obj.as(PyStringObject).value();
    if (@as(i64, @intCast(s.len)) >= width) { self_obj.incRef(); return self_obj; }
    const pad_len = @as(usize, @intCast(width)) - s.len;
    var buf = try vm.mm.allocBytes(@intCast(width));
    errdefer vm.mm.freeBytes(buf);
    @memcpy(buf[0..s.len], s);
    @memset(buf[s.len..], fillchar);
    _ = pad_len;
    return try PyStringObject.create(buf, vm.mm);
}

pub fn stringRjustMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    if (args[1].type_obj != PyInt_Type) return error.TypeError;
    const width = @max(0, args[1].as(PyIntObject).value);
    const fillchar: u8 = if (args.len == 3) blk: {
        if (args[2].type_obj != PyString_Type) return error.TypeError;
        const fc = args[2].as(PyStringObject).value();
        if (fc.len != 1) return error.TypeError;
        break :blk fc[0];
    } else ' ';
    const s = self_obj.as(PyStringObject).value();
    if (@as(i64, @intCast(s.len)) >= width) { self_obj.incRef(); return self_obj; }
    const pad = @as(usize, @intCast(width)) - s.len;
    var buf = try vm.mm.allocBytes(@intCast(width));
    errdefer vm.mm.freeBytes(buf);
    @memset(buf[0..pad], fillchar);
    @memcpy(buf[pad..][0..s.len], s);
    return try PyStringObject.create(buf, vm.mm);
}

pub fn stringZfillMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    if (args[1].type_obj != PyInt_Type) return error.TypeError;
    const width = @max(0, args[1].as(PyIntObject).value);
    const s = self_obj.as(PyStringObject).value();
    if (@as(i64, @intCast(s.len)) >= width) { self_obj.incRef(); return self_obj; }
    const pad = @as(usize, @intCast(width)) - s.len;
    var buf = try vm.mm.allocBytes(@intCast(width));
    errdefer vm.mm.freeBytes(buf);
    const sign_prefix: usize = if (s.len > 0 and (s[0] == '+' or s[0] == '-')) 1 else 0;
    if (sign_prefix > 0) {
        buf[0] = s[0];
        @memset(buf[1..][0..pad], '0');
        @memcpy(buf[1 + pad ..][0..s.len - 1], s[1..]);
    } else {
        @memset(buf[0..pad], '0');
        @memcpy(buf[pad..][0..s.len], s);
    }
    return try PyStringObject.create(buf, vm.mm);
}

fn stringIsCheck(args: []*PyObject, vm_opaque: *anyopaque, comptime check_fn: fn (u8) bool) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    if (s.len == 0) { PyFalse.incRef(); return PyFalse; }
    for (s) |c| { if (!check_fn(c)) { PyFalse.incRef(); return PyFalse; } }
    PyTrue.incRef();
    return PyTrue;
}

pub fn stringIsalphaMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    return stringIsCheck(args, vm_opaque, std.ascii.isAlphabetic);
}

pub fn stringIsdigitMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    return stringIsCheck(args, vm_opaque, std.ascii.isDigit);
}

pub fn stringIsalnumMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    return stringIsCheck(args, vm_opaque, struct {
        fn check(c: u8) bool { return std.ascii.isAlphanumeric(c); }
    }.check);
}

pub fn stringIsspaceMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    return stringIsCheck(args, vm_opaque, std.ascii.isWhitespace);
}

pub fn stringIslowerMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    if (s.len == 0) { PyFalse.incRef(); return PyFalse; }
    var has_cased = false;
    for (s) |c| {
        if (std.ascii.isUpper(c)) { PyFalse.incRef(); return PyFalse; }
        if (std.ascii.isLower(c)) has_cased = true;
    }
    return if (has_cased) PyTrue else PyFalse;
}

pub fn stringIsupperMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    if (s.len == 0) { PyFalse.incRef(); return PyFalse; }
    var has_cased = false;
    for (s) |c| {
        if (std.ascii.isLower(c)) { PyFalse.incRef(); return PyFalse; }
        if (std.ascii.isUpper(c)) has_cased = true;
    }
    return if (has_cased) PyTrue else PyFalse;
}

fn addDictKeys(result: *PyListObject, dict_obj: *PyObject, vm: *anyopaque) anyerror!void {
    const VM = @import("../vm/vm.zig").VM;
    const vm_ptr: *VM = @ptrCast(@alignCast(vm));
    const dict = dict_obj.as(PyDictObject);
    var i: usize = 0;
    while (i < dict.entries_size) : (i += 1) {
        if (dict.entries[i].key) |key| {
            if (key.type_obj == PyString_Type) {
                var found = false;
                var j: usize = 0;
                while (j < result.size) : (j += 1) {
                    const item = result.items.?[j];
                    if (item.type_obj == PyString_Type) {
                        if (std.mem.eql(u8, item.as(PyStringObject).value(), key.as(PyStringObject).value())) {
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) {
                    try result.append(key, vm_ptr.mm);
                }
            }
        }
    }
}

fn compareStrings(context: void, a: *PyObject, b: *PyObject) bool {
    _ = context;
    const sa = a.as(PyStringObject).value();
    const sb = b.as(PyStringObject).value();
    return std.mem.lessThan(u8, sa, sb);
}

pub fn builtinDir(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const obj = if (args.len == 0) null else args[0];
    const result = try PyListObject.create(0, vm.mm);
    if (obj) |o| {
        if (o.type_obj == PyList_Type) {
            const names = [_][]const u8{"append", "clear", "copy", "count", "extend", "index", "insert", "pop", "remove", "reverse", "sort"};
            for (names) |n| { const s = try PyStringObject.create(n, vm.mm); defer s.decRef(vm.mm); try result.append(s, vm.mm); }
        } else if (o.type_obj == PyDict_Type) {
            const names = [_][]const u8{"clear", "copy", "get", "items", "keys", "pop", "popitem", "setdefault", "update", "values"};
            for (names) |n| { const s = try PyStringObject.create(n, vm.mm); defer s.decRef(vm.mm); try result.append(s, vm.mm); }
        } else if (o.type_obj == PyString_Type) {
            const names = [_][]const u8{"capitalize", "center", "count", "endswith", "find", "isalnum", "isalpha", "isdigit", "islower", "isspace", "istitle", "isupper", "join", "ljust", "lower", "lstrip", "replace", "rjust", "rstrip", "split", "startswith", "strip", "swapcase", "title", "upper", "zfill"};
            for (names) |n| { const s = try PyStringObject.create(n, vm.mm); defer s.decRef(vm.mm); try result.append(s, vm.mm); }
        } else if (o.type_obj == PySet_Type) {
            const names = [_][]const u8{"add", "clear", "copy", "discard", "pop", "remove", "issubset", "issuperset", "isdisjoint", "union", "intersection", "difference", "symmetric_difference"};
            for (names) |n| { const s = try PyStringObject.create(n, vm.mm); defer s.decRef(vm.mm); try result.append(s, vm.mm); }
        } else if (o.type_obj == PyTuple_Type) {
            const names = [_][]const u8{"count", "index"};
            for (names) |n| { const s = try PyStringObject.create(n, vm.mm); defer s.decRef(vm.mm); try result.append(s, vm.mm); }
        } else if (o.type_obj == PyFloat_Type) {
            const names = [_][]const u8{"as_integer_ratio", "is_integer"};
            for (names) |n| { const s = try PyStringObject.create(n, vm.mm); defer s.decRef(vm.mm); try result.append(s, vm.mm); }
        } else if (o.type_obj == PyInt_Type) {
            const names = [_][]const u8{"bit_length", "to_bytes", "from_bytes", "as_integer_ratio"};
            for (names) |n| { const s = try PyStringObject.create(n, vm.mm); defer s.decRef(vm.mm); try result.append(s, vm.mm); }
        } else if (o.type_obj == PyInstance_Type) {
            const inst = o.as(class_mod.PyInstanceObject);
            try addDictKeys(result, inst.dict, vm_opaque);
            var curr_class: ?*class_mod.PyClassObject = inst.class_obj;
            while (curr_class) |cls| {
                try addDictKeys(result, cls.dict, vm_opaque);
                if (cls.base_class) |bc| {
                    if (bc.type_obj == PyClass_Type) {
                        curr_class = bc.as(class_mod.PyClassObject);
                    } else {
                        curr_class = null;
                    }
                } else {
                    curr_class = null;
                }
            }
        } else if (o.type_obj == PyClass_Type) {
            const class_obj = o.as(class_mod.PyClassObject);
            var curr_class: ?*class_mod.PyClassObject = class_obj;
            while (curr_class) |cls| {
                try addDictKeys(result, cls.dict, vm_opaque);
                if (cls.base_class) |bc| {
                    if (bc.type_obj == PyClass_Type) {
                        curr_class = bc.as(class_mod.PyClassObject);
                    } else {
                        curr_class = null;
                    }
                } else {
                    curr_class = null;
                }
            }
        }
    }
    if (result.size > 0) {
        std.mem.sort(*PyObject, result.items.?[0..result.size], {}, compareStrings);
    }
    return &result.base;
}

pub fn tupleIndexMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyTuple_Type) return error.TypeError;
    const tuple = self_obj.as(PyTupleObject);
    const item = args[1];
    for (tuple.items(), 0..) |el, i| {
        const eq = try vm.objectsEqual(el, item);
        if (eq) return try PyIntObject.create(@intCast(i), vm.mm);
    }
    return error.ValueError;
}

pub fn tupleCountMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyTuple_Type) return error.TypeError;
    const tuple = self_obj.as(PyTupleObject);
    const item = args[1];
    var count: i64 = 0;
    for (tuple.items()) |el| {
        const eq = try vm.objectsEqual(el, item);
        if (eq) count += 1;
    }
    return try PyIntObject.create(count, vm.mm);
}

pub fn setPopMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PySet_Type) return error.TypeError;
    const set = self_obj.as(collections.PySetObject);
    for (0..set.entries_size) |i| {
        if (set.entries[i].key) |key| {
            key.incRef();
            _ = set.remove(key, vm.mm) catch {};
            return key;
        }
    }
    return error.KeyError;
}

pub fn setClearMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PySet_Type) return error.TypeError;
    const set = self_obj.as(collections.PySetObject);
    for (0..set.entries_size) |i| {
        if (set.entries[i].key) |key| {
            key.decRef(vm.mm);
            set.entries[i].key = null;
            set.entries[i].hash = 0;
        }
    }
    set.entries_size = 0;
    set.active_count = 0;
    PyNone.incRef();
    return PyNone;
}

pub fn stringIstitleMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    if (s.len == 0) { PyFalse.incRef(); return PyFalse; }
    var prev_cased = false;
    for (s) |c| {
        if (std.ascii.isUpper(c)) {
            if (prev_cased) { PyFalse.incRef(); return PyFalse; }
            prev_cased = true;
        } else if (std.ascii.isLower(c)) {
            if (!prev_cased) { PyFalse.incRef(); return PyFalse; }
        } else {
            prev_cased = false;
        }
    }
    PyTrue.incRef();
    return PyTrue;
}

pub fn stringExpandtabsMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    var tabsize: usize = 8;
    if (args.len >= 2) {
        if (args[1].type_obj != PyInt_Type) return error.TypeError;
        const t = args[1].as(PyIntObject).value;
        if (t <= 0) return error.TypeError;
        tabsize = @intCast(t);
    }
    var alloc_writer = std.Io.Writer.Allocating.init(vm.mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    var col: usize = 0;
    for (s) |c| {
        if (c == '\t') {
            const spaces = tabsize - (col % tabsize);
            var j: usize = 0;
            while (j < spaces) : (j += 1) try writer.writeByte(' ');
            col += spaces;
        } else if (c == '\n' or c == '\r') {
            try writer.writeByte(c);
            col = 0;
        } else {
            try writer.writeByte(c);
            col += 1;
        }
    }
    return try PyStringObject.create(alloc_writer.written(), vm.mm);
}

pub fn stringPartitionMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    if (args[1].type_obj != PyString_Type) return error.TypeError;
    const sep = args[1].as(PyStringObject).value();
    if (sep.len == 0) return error.TypeError;
    const tuple = try PyTupleObject.create(3, vm.mm);
    const tup_items = tuple.items();
    if (std.mem.indexOf(u8, s, sep)) |pos| {
        tup_items[0].decRef(vm.mm);
        tup_items[0] = try PyStringObject.create(s[0..pos], vm.mm);
        tup_items[1].decRef(vm.mm);
        tup_items[1] = try PyStringObject.create(sep, vm.mm);
        tup_items[2].decRef(vm.mm);
        tup_items[2] = try PyStringObject.create(s[pos + sep.len ..], vm.mm);
    } else {
        tup_items[0].decRef(vm.mm);
        tup_items[0] = try PyStringObject.create(s, vm.mm);
        tup_items[1].decRef(vm.mm);
        tup_items[1] = try PyStringObject.create("", vm.mm);
        tup_items[2].decRef(vm.mm);
        tup_items[2] = try PyStringObject.create("", vm.mm);
    }
    return &tuple.base;
}

pub fn stringRpartitionMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    if (args[1].type_obj != PyString_Type) return error.TypeError;
    const sep = args[1].as(PyStringObject).value();
    if (sep.len == 0) return error.TypeError;
    const tuple = try PyTupleObject.create(3, vm.mm);
    const tup_items = tuple.items();
    if (std.mem.lastIndexOf(u8, s, sep)) |pos| {
        tup_items[0].decRef(vm.mm);
        tup_items[0] = try PyStringObject.create(s[0..pos], vm.mm);
        tup_items[1].decRef(vm.mm);
        tup_items[1] = try PyStringObject.create(sep, vm.mm);
        tup_items[2].decRef(vm.mm);
        tup_items[2] = try PyStringObject.create(s[pos + sep.len ..], vm.mm);
    } else {
        tup_items[0].decRef(vm.mm);
        tup_items[0] = try PyStringObject.create("", vm.mm);
        tup_items[1].decRef(vm.mm);
        tup_items[1] = try PyStringObject.create("", vm.mm);
        tup_items[2].decRef(vm.mm);
        tup_items[2] = try PyStringObject.create(s, vm.mm);
    }
    return &tuple.base;
}

pub fn stringRfindMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 4) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    if (args[1].type_obj != PyString_Type) return error.TypeError;
    const needle = args[1].as(PyStringObject).value();
    var start: usize = 0;
    var end: usize = s.len;
    if (args.len >= 3) {
        if (args[2].type_obj != PyInt_Type) return error.TypeError;
        const sval = args[2].as(PyIntObject).value;
        start = if (sval < 0) 0 else @intCast(sval);
    }
    if (args.len >= 4) {
        if (args[3].type_obj != PyInt_Type) return error.TypeError;
        const eval = args[3].as(PyIntObject).value;
        end = if (eval < 0) 0 else @intCast(eval);
    }
    if (start >= s.len or start >= end) {
        return try PyIntObject.create(-1, vm.mm);
    }
    if (end > s.len) end = s.len;
    const search_slice = s[start..end];
    const pos = std.mem.lastIndexOf(u8, search_slice, needle);
    return try PyIntObject.create(if (pos) |p| @as(i64, @intCast(p + start)) else -1, vm.mm);
}

pub fn stringRindexMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 4) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    if (args[1].type_obj != PyString_Type) return error.TypeError;
    const needle = args[1].as(PyStringObject).value();
    var start: usize = 0;
    var end: usize = s.len;
    if (args.len >= 3) {
        if (args[2].type_obj != PyInt_Type) return error.TypeError;
        const sval = args[2].as(PyIntObject).value;
        start = if (sval < 0) 0 else @intCast(sval);
    }
    if (args.len >= 4) {
        if (args[3].type_obj != PyInt_Type) return error.TypeError;
        const eval = args[3].as(PyIntObject).value;
        end = if (eval < 0) 0 else @intCast(eval);
    }
    if (start >= s.len or start >= end) return error.ValueError;
    if (end > s.len) end = s.len;
    const search_slice = s[start..end];
    const pos = std.mem.lastIndexOf(u8, search_slice, needle);
    if (pos) |p| {
        return try PyIntObject.create(@as(i64, @intCast(p + start)), vm.mm);
    }
    return error.ValueError;
}

pub fn stringSplitlinesMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const self_obj = args[0];
    if (self_obj.type_obj != PyString_Type) return error.TypeError;
    const s = self_obj.as(PyStringObject).value();
    var keepends = false;
    if (args.len >= 2) {
        if (args[1] == PyTrue) {
            keepends = true;
        }
    }
    const list = try PyListObject.create(0, vm.mm);
    if (s.len == 0) return &list.base;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\n') {
            const end = if (keepends) i + 1 else i;
            const line = try PyStringObject.create(s[line_start..end], vm.mm);
            try list.append(line, vm.mm);
            i += 1;
            line_start = i;
        } else if (c == '\r') {
            if (i + 1 < s.len and s[i + 1] == '\n') {
                const end = if (keepends) i + 2 else i;
                const line = try PyStringObject.create(s[line_start..end], vm.mm);
                try list.append(line, vm.mm);
                i += 2;
            } else {
                const end = if (keepends) i + 1 else i;
                const line = try PyStringObject.create(s[line_start..end], vm.mm);
                try list.append(line, vm.mm);
                i += 1;
            }
            line_start = i;
        } else {
            i += 1;
        }
    }
    if (line_start < s.len) {
        const last_line = try PyStringObject.create(s[line_start..s.len], vm.mm);
        try list.append(last_line, vm.mm);
    }
    return &list.base;
}

pub fn builtinEval(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 3) return error.TypeError;
    
    const src_obj = args[0];
    if (src_obj.type_obj != PyString_Type) return error.TypeError;
    const src = src_obj.as(PyStringObject).value();
    
    var globals: ?*std.StringHashMap(*PyObject) = null;
    if (args.len >= 2 and args[1].type_obj == PyDict_Type) {
        // Fallback to current globals
        globals = vm.frames[vm.frame_count - 1].globals;
    } else {
        globals = vm.frames[vm.frame_count - 1].globals;
    }
    
    var temp_arena = std.heap.ArenaAllocator.init(vm.allocator);
    defer temp_arena.deinit();
    const temp_alloc = temp_arena.allocator();
    
    var lexer = @import("../lexer/lexer.zig").Lexer.init(src);
    var p = @import("../parser/parser.zig").Parser.init(&lexer, temp_alloc);
    // don't defer p.deinit(), it uses temp_alloc
    
    var expr_ast = p.parseExpression() catch |err| {
        try vm.stdout_writer.print("SyntaxError in eval: {any}\n", .{err});
        return error.SyntaxError;
    };
    
    const Compiler = @import("../compiler/compiler.zig").Compiler;
    var compiler = Compiler.init(temp_alloc, vm.mm);
    // compiler uses temp_alloc, so deinit is optional but good practice
    defer compiler.deinit();
    
    var code = compiler.compileExpr(&expr_ast) catch |err| {
        try vm.stdout_writer.print("CompilerError in eval: {any}\n", .{err});
        return error.SyntaxError;
    };
    // code uses temp_alloc, so it lives until temp_arena.deinit()
    
    const res = try vm.run(&code, globals);
    return res;
}
