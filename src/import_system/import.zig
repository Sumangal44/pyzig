const std = @import("std");
const PyObject = @import("../objects/object.zig").PyObject;
const PyTypeObject = @import("../objects/object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyDictObject = @import("../objects/collections.zig").PyDictObject;
const PyStringObject = @import("../objects/primitives.zig").PyStringObject;
const PyIntObject = @import("../objects/primitives.zig").PyIntObject;
const PyFloatObject = @import("../objects/primitives.zig").PyFloatObject;
const PyBuiltinFunctionObject = @import("../objects/function.zig").PyBuiltinFunctionObject;
const Lexer = @import("../lexer/lexer.zig").Lexer;
const Parser = @import("../parser/parser.zig").Parser;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const VM = @import("../vm/vm.zig").VM;
const PyInt_Type = &@import("../objects/primitives.zig").PyInt_Type;
const PyFloat_Type = &@import("../objects/primitives.zig").PyFloat_Type;
const PyTrue = @import("../objects/primitives.zig").PyTrue;
const PyFalse = @import("../objects/primitives.zig").PyFalse;

pub const PyModuleObject = struct {
    base: PyObject,
    name: *PyObject, // PyStringObject
    dict: *PyObject, // PyDictObject
    globals: *std.StringHashMap(*PyObject),
    
    pub fn create(name: *PyObject, dict: *PyObject, globals: *std.StringHashMap(*PyObject), mm: *PyMemoryManager) !*PyModuleObject {
        const obj = try mm.alloc(PyModuleObject);
        obj.* = .{
            .base = PyObject.init(&PyModule_Type),
            .name = name,
            .dict = dict,
            .globals = globals,
        };
        name.incRef();
        dict.incRef();
        return obj;
    }
};

pub const PyModule_Type = PyTypeObject{
    .name = "module",
    .tp_dealloc = module_dealloc,
    .tp_repr = module_repr,
    .tp_str = module_repr,
};

fn module_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyModuleObject);
    obj.name.decRef(mm);
    obj.dict.decRef(mm);
    
    // Clean up heap-allocated globals map and its entries
    var it = obj.globals.iterator();
    while (it.next()) |entry| {
        obj.globals.allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.decRef(mm);
    }
    const allocator = obj.globals.allocator;
    obj.globals.deinit();
    allocator.destroy(obj.globals);
    
    mm.free(PyModuleObject, obj);
}

fn module_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyModuleObject);
    var buf: [128]u8 = undefined;
    const repr_str = std.fmt.bufPrint(&buf, "<module '{s}'>", .{obj.name.as(PyStringObject).value()}) catch "<module>";
    return try PyStringObject.create(repr_str, mm);
}

pub var sys_modules: ?std.StringHashMap(*PyObject) = null;
pub var sys_modules_dict: ?*PyObject = null;
pub var sys_argv: ?*PyObject = null;

pub fn initImportSystem(allocator: std.mem.Allocator, mm: *PyMemoryManager) !void {
    if (sys_modules == null) {
        sys_modules = std.StringHashMap(*PyObject).init(allocator);
    }
    if (sys_modules_dict == null) {
        const dict = try PyDictObject.create(mm);
        sys_modules_dict = &dict.base;
    }
}

pub fn setSysArgv(argv: *PyObject) void {
    sys_argv = argv;
}

pub fn deinitImportSystem(mm: *PyMemoryManager) void {
    if (sys_modules) |*modules| {
        var it = modules.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.decRef(mm);
            modules.allocator.free(entry.key_ptr.*);
        }
        modules.deinit();
        sys_modules = null;
    }
    if (sys_modules_dict) |dict| {
        const obj = dict.as(PyDictObject);
        if (obj.indices_size > 0) {
            for (0..obj.entries_size) |i| {
                const entry = &obj.entries[i];
                if (entry.key) |k| {
                    k.decRef(mm);
                    entry.key = null;
                }
                if (entry.value) |v| {
                    v.decRef(mm);
                    entry.value = null;
                }
            }
            @memset(obj.indices[0..obj.indices_size], -1);
            obj.entries_size = 0;
            obj.active_count = 0;
        }
        dict.decRef(mm);
        sys_modules_dict = null;
    }
    if (sys_argv) |argv| {
        argv.decRef(mm);
        sys_argv = null;
    }
}

pub fn importModule(name: []const u8, vm: *VM) anyerror!*PyObject {
    try initImportSystem(vm.allocator, vm.mm);
    
    if (sys_modules.?.get(name)) |cached| {
        cached.incRef();
        return cached;
    }
    
    // Allocate globals map on the heap
    const heap_globals = try vm.allocator.create(std.StringHashMap(*PyObject));
    heap_globals.* = std.StringHashMap(*PyObject).init(vm.allocator);
    errdefer {
        var it = heap_globals.iterator();
        while (it.next()) |entry| {
            vm.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.decRef(vm.mm);
        }
        heap_globals.deinit();
        vm.allocator.destroy(heap_globals);
    }
    
    var compiled_success = false;
    
    if (std.mem.eql(u8, name, "keyword")) {
        const keyword_src =
            \\kwlist = ['False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def', 'del', 'elif', 'else', 'except', 'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield']
            \\softkwlist = ['_', 'case', 'match', 'type']
            \\
            \\def iskeyword(s):
            \\    return s in kwlist
            \\
            \\def issoftkeyword(s):
            \\    return s in softkwlist
            \\
        ;
        
        var lexer = Lexer.init(keyword_src);
        var arena = std.heap.ArenaAllocator.init(vm.allocator);
        defer arena.deinit();
        
        var parser = Parser.init(&lexer, arena.allocator());
        const module_ast = parser.parseModule() catch return error.SyntaxError;
        
        var compiler = Compiler.init(arena.allocator(), vm.mm);
        defer compiler.deinit();
        
        var code = try compiler.compile(&module_ast);
        defer code.deinit(arena.allocator(), vm.mm);
        
        const result = try vm.run(&code, heap_globals);
        result.decRef(vm.mm);
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "math")) {
        // Register math constants
        const constant_names = &.{ "pi", "e", "tau" };
        const constant_values = [_]f64{ std.math.pi, std.math.e, std.math.tau };
        inline for (constant_names, &constant_values) |cname, cval| {
            const val_obj = try PyFloatObject.create(cval, vm.mm);
            const name_c = try vm.allocator.dupe(u8, cname);
            try heap_globals.put(name_c, val_obj);
        }
        
        // Register inf/nan
        {
            const inf_obj = try PyFloatObject.create(std.math.inf(f64), vm.mm);
            const inf_c = try vm.allocator.dupe(u8, "inf");
            try heap_globals.put(inf_c, inf_obj);
        }
        {
            const nan_obj = try PyFloatObject.create(std.math.nan(f64), vm.mm);
            const nan_c = try vm.allocator.dupe(u8, "nan");
            try heap_globals.put(nan_c, nan_obj);
        }
        
        // Register native math functions
        inline for (&.{ "sqrt", "sin", "cos", "tan", "log", "log10", "log2", "floor", "ceil", "radians", "degrees", "exp" }) |fn_name| {
            const T = struct {
                fn mathFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    const num = args[0];
                    const val: f64 = if (num.type_obj == PyFloat_Type) num.as(PyFloatObject).value
                        else if (num.type_obj == PyInt_Type) @floatFromInt(num.as(PyIntObject).value)
                        else return error.TypeError;
                    const op = comptime fn_name;
                    const res = if (comptime std.mem.eql(u8, op, "sqrt")) std.math.sqrt(val)
                        else if (comptime std.mem.eql(u8, op, "sin")) std.math.sin(val)
                        else if (comptime std.mem.eql(u8, op, "cos")) std.math.cos(val)
                        else if (comptime std.mem.eql(u8, op, "tan")) std.math.tan(val)
                        else if (comptime std.mem.eql(u8, op, "log")) std.math.log(f64, std.math.e, val)
                        else if (comptime std.mem.eql(u8, op, "log10")) std.math.log10(val)
                        else if (comptime std.mem.eql(u8, op, "log2")) std.math.log2(val)
                        else if (comptime std.mem.eql(u8, op, "floor")) @floor(val)
                        else if (comptime std.mem.eql(u8, op, "ceil")) @ceil(val)
                        else if (comptime std.mem.eql(u8, op, "radians")) val * std.math.pi / 180.0
                        else if (comptime std.mem.eql(u8, op, "degrees")) val * 180.0 / std.math.pi
                        else if (comptime std.mem.eql(u8, op, "exp")) std.math.exp(val)
                        else val;
                    return try PyFloatObject.create(res, vm2.mm);
                }
            };
            const builtin_func = try PyBuiltinFunctionObject.create(fn_name, T.mathFn, vm.mm);
            const name_c = try vm.allocator.dupe(u8, fn_name);
            try heap_globals.put(name_c, &builtin_func.base);
        }
        
        // Register isfinite, isinf, isnan as native functions
        {
            const T = struct {
                fn isfiniteFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    _ = vm_opaque;
                    if (args.len != 1) return error.TypeError;
                    const num = args[0];
                    if (num.type_obj == PyFloat_Type) {
                        const val = num.as(PyFloatObject).value;
                        return if (std.math.isFinite(val)) PyTrue else PyFalse;
                    } else if (num.type_obj == PyInt_Type) {
                        return PyTrue;
                    }
                    return PyFalse;
                }
            };
            const func = try PyBuiltinFunctionObject.create("isfinite", T.isfiniteFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "isfinite");
            try heap_globals.put(c, &func.base);
        }
        {
            const T = struct {
                fn isinfFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    _ = vm_opaque;
                    if (args.len != 1) return error.TypeError;
                    const num = args[0];
                    if (num.type_obj == PyFloat_Type) {
                        const val = num.as(PyFloatObject).value;
                        return if (std.math.isInf(val)) PyTrue else PyFalse;
                    }
                    return PyFalse;
                }
            };
            const func = try PyBuiltinFunctionObject.create("isinf", T.isinfFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "isinf");
            try heap_globals.put(c, &func.base);
        }
        {
            const T = struct {
                fn isnanFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    _ = vm_opaque;
                    if (args.len != 1) return error.TypeError;
                    const num = args[0];
                    if (num.type_obj == PyFloat_Type) {
                        const val = num.as(PyFloatObject).value;
                        return if (std.math.isNan(val)) PyTrue else PyFalse;
                    }
                    return PyFalse;
                }
            };
            const func = try PyBuiltinFunctionObject.create("isnan", T.isnanFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "isnan");
            try heap_globals.put(c, &func.base);
        }
        
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "random")) {
        // Register random.random()
        {
            const T = struct {
                fn randomFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 0) return error.TypeError;
                    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@intFromPtr(args.ptr))));
                    const val = prng.random().float(f64);
                    return try PyFloatObject.create(val, vm2.mm);
                }
            };
            const func = try PyBuiltinFunctionObject.create("random", T.randomFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "random");
            try heap_globals.put(c, &func.base);
        }
        
        // Register random.randint(a, b)
        {
            const T = struct {
                fn randintFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 2) return error.TypeError;
                    if (args[0].type_obj != PyInt_Type or args[1].type_obj != PyInt_Type) return error.TypeError;
                    const a = args[0].as(PyIntObject).value;
                    const b = args[1].as(PyIntObject).value;
                    if (a > b) return error.TypeError;
                    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@intFromPtr(args.ptr))));
                    const range = b - a + 1;
                    const val = a + @as(i64, @intCast(prng.random().uintLessThan(u64, @as(u64, @intCast(range)))));
                    return try PyIntObject.create(val, vm2.mm);
                }
            };
            const func = try PyBuiltinFunctionObject.create("randint", T.randintFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "randint");
            try heap_globals.put(c, &func.base);
        }
        
        // Register random.choice(seq)
        {
            const T = struct {
                fn choiceFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    const seq = args[0];
                    const type_name = seq.type_obj.name;
                    var len: usize = 0;
                    if (std.mem.eql(u8, type_name, "list")) {
                        len = seq.as(@import("../objects/collections.zig").PyListObject).size;
                    } else if (std.mem.eql(u8, type_name, "tuple")) {
                        len = seq.as(@import("../objects/collections.zig").PyTupleObject).size;
                    } else if (std.mem.eql(u8, type_name, "str")) {
                        len = seq.as(@import("../objects/primitives.zig").PyStringObject).len;
                    } else {
                        return error.TypeError;
                    }
                    if (len == 0) return error.TypeError;
                    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@intFromPtr(args.ptr))));
                    const idx = prng.random().uintLessThan(u64, @as(u64, @intCast(len)));
                    const collections = @import("../objects/collections.zig");
                    const primitives = @import("../objects/primitives.zig");
                    if (std.mem.eql(u8, type_name, "list")) {
                        const item = seq.as(collections.PyListObject).items.?[idx];
                        item.incRef();
                        return item;
                    } else if (std.mem.eql(u8, type_name, "tuple")) {
                        const item = seq.as(collections.PyTupleObject).items()[idx];
                        item.incRef();
                        return item;
                    } else {
                        const str_val = seq.as(primitives.PyStringObject).value();
                        const ch = try primitives.PyStringObject.create(str_val[idx..idx+1], vm2.mm);
                        return ch;
                    }
                }
            };
            const func = try PyBuiltinFunctionObject.create("choice", T.choiceFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "choice");
            try heap_globals.put(c, &func.base);
        }
        
        // Register random.shuffle(x)
        {
            const T = struct {
                fn shuffleFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    _ = vm_opaque;
                    if (args.len != 1) return error.TypeError;
                    const seq = args[0];
                    if (seq.type_obj != &(@import("../objects/collections.zig").PyList_Type)) return error.TypeError;
                    const list = seq.as(@import("../objects/collections.zig").PyListObject);
                    const PyNone = @import("../objects/primitives.zig").PyNone;
                    if (list.size <= 1) { PyNone.incRef(); return PyNone; }
                    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@intFromPtr(args.ptr))));
                    const rng = prng.random();
                    var i: usize = list.size;
                    while (i > 1) {
                        i -= 1;
                        const j = rng.uintLessThan(u64, @as(u64, @intCast(i + 1)));
                        const tmp = list.items.?[i];
                        list.items.?[i] = list.items.?[j];
                        list.items.?[j] = tmp;
                    }
                    PyNone.incRef();
                    return PyNone;
                }
            };
            const func = try PyBuiltinFunctionObject.create("shuffle", T.shuffleFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "shuffle");
            try heap_globals.put(c, &func.base);
        }
        
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "sys")) {
        if (sys_argv) |argv| {
            argv.incRef();
            const argv_c = try vm.allocator.dupe(u8, "argv");
            try heap_globals.put(argv_c, argv);
        }
        if (sys_modules_dict) |modules| {
            modules.incRef();
            const modules_c = try vm.allocator.dupe(u8, "modules");
            try heap_globals.put(modules_c, modules);
        }
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "os")) {
        const path_globals = try vm.allocator.create(std.StringHashMap(*PyObject));
        path_globals.* = std.StringHashMap(*PyObject).init(vm.allocator);
        errdefer {
            var it = path_globals.iterator();
            while (it.next()) |entry| {
                vm.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.decRef(vm.mm);
            }
            path_globals.deinit();
            vm.allocator.destroy(path_globals);
        }
        
        {
            const T = struct {
                fn existsFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    if (args[0].type_obj != &@import("../objects/primitives.zig").PyString_Type) return error.TypeError;
                    const path = args[0].as(PyStringObject).value();
                    const cwd = std.Io.Dir.cwd();
                    const exists = blk: {
                        if (cwd.access(vm2.io, path, .{})) |_| {
                            break :blk true;
                        } else |err| {
                            break :blk (err != error.FileNotFound);
                        }
                    };
                    return if (exists) PyTrue else PyFalse;
                }
            };
            const func = try PyBuiltinFunctionObject.create("exists", T.existsFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "exists");
            try path_globals.put(c, &func.base);
        }
        
        {
            const T = struct {
                fn getsizeFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    if (args[0].type_obj != &@import("../objects/primitives.zig").PyString_Type) return error.TypeError;
                    const path = args[0].as(PyStringObject).value();
                    const cwd = std.Io.Dir.cwd();
                    var file = cwd.openFile(vm2.io, path, .{ .mode = .read_only }) catch return error.OSError;
                    defer file.close(vm2.io);
                    const size = file.length(vm2.io) catch return error.OSError;
                    return try @import("../objects/primitives.zig").PyIntObject.create(@as(i64, @intCast(size)), vm2.mm);
                }
            };
            const func = try PyBuiltinFunctionObject.create("getsize", T.getsizeFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "getsize");
            try path_globals.put(c, &func.base);
        }
        
        const path_dict = try PyDictObject.create(vm.mm);
        defer path_dict.base.decRef(vm.mm);
        
        var path_it = path_globals.iterator();
        while (path_it.next()) |entry| {
            const key_str = try PyStringObject.create(entry.key_ptr.*, vm.mm);
            defer key_str.decRef(vm.mm);
            try path_dict.setItem(key_str, entry.value_ptr.*, vm.mm);
        }
        
        const path_name_str = try PyStringObject.create("os.path", vm.mm);
        defer path_name_str.decRef(vm.mm);
        const path_module_obj = try PyModuleObject.create(path_name_str, &path_dict.base, path_globals, vm.mm);
        
        {
            const T = struct {
                fn removeFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    if (args[0].type_obj != &@import("../objects/primitives.zig").PyString_Type) return error.TypeError;
                    const path = args[0].as(PyStringObject).value();
                    const cwd = std.Io.Dir.cwd();
                    cwd.deleteFile(vm2.io, path) catch return error.OSError;
                    const PyNone = @import("../objects/primitives.zig").PyNone;
                    PyNone.incRef();
                    return PyNone;
                }
            };
            const func = try PyBuiltinFunctionObject.create("remove", T.removeFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "remove");
            try heap_globals.put(c, &func.base);
        }
        
        {
            const T = struct {
                fn renameFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 2) return error.TypeError;
                    if (args[0].type_obj != &@import("../objects/primitives.zig").PyString_Type) return error.TypeError;
                    if (args[1].type_obj != &@import("../objects/primitives.zig").PyString_Type) return error.TypeError;
                    const old = args[0].as(PyStringObject).value();
                    const new = args[1].as(PyStringObject).value();
                    const cwd = std.Io.Dir.cwd();
                    cwd.rename(old, cwd, new, vm2.io) catch return error.OSError;
                    const PyNone = @import("../objects/primitives.zig").PyNone;
                    PyNone.incRef();
                    return PyNone;
                }
            };
            const func = try PyBuiltinFunctionObject.create("rename", T.renameFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "rename");
            try heap_globals.put(c, &func.base);
        }
        
        {
            const T = struct {
                fn mkdirFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    if (args[0].type_obj != &@import("../objects/primitives.zig").PyString_Type) return error.TypeError;
                    const path = args[0].as(PyStringObject).value();
                    const cwd = std.Io.Dir.cwd();
                    cwd.createDir(vm2.io, path, .default_dir) catch return error.OSError;
                    const PyNone = @import("../objects/primitives.zig").PyNone;
                    PyNone.incRef();
                    return PyNone;
                }
            };
            const func = try PyBuiltinFunctionObject.create("mkdir", T.mkdirFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "mkdir");
            try heap_globals.put(c, &func.base);
        }
        
        {
            const T = struct {
                fn chdirFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    if (args[0].type_obj != &@import("../objects/primitives.zig").PyString_Type) return error.TypeError;
                    const path = args[0].as(PyStringObject).value();
                    const cwd = std.Io.Dir.cwd();
                    var target_dir = cwd.openDir(vm2.io, path, .{}) catch return error.OSError;
                    defer target_dir.close(vm2.io);
                    std.process.setCurrentDir(vm2.io, target_dir) catch return error.OSError;
                    const PyNone = @import("../objects/primitives.zig").PyNone;
                    PyNone.incRef();
                    return PyNone;
                }
            };
            const func = try PyBuiltinFunctionObject.create("chdir", T.chdirFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "chdir");
            try heap_globals.put(c, &func.base);
        }
        
        {
            const T = struct {
                fn getcwdFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    _ = args;
                    const path = std.process.currentPathAlloc(vm2.io, vm2.allocator) catch return error.OSError;
                    defer vm2.allocator.free(path);
                    return try PyStringObject.create(path, vm2.mm);
                }
            };
            const func = try PyBuiltinFunctionObject.create("getcwd", T.getcwdFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "getcwd");
            try heap_globals.put(c, &func.base);
        }
        
        {
            const T = struct {
                fn listdirFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    if (args[0].type_obj != &@import("../objects/primitives.zig").PyString_Type) return error.TypeError;
                    const path = args[0].as(PyStringObject).value();
                    const cwd = std.Io.Dir.cwd();
                    var dir = cwd.openDir(vm2.io, path, .{}) catch return error.OSError;
                    defer dir.close(vm2.io);
                    
                    const list = try @import("../objects/collections.zig").PyListObject.create(0, vm2.mm);
                    errdefer list.base.decRef(vm2.mm);
                    
                    var it = dir.iterate();
                    while (try it.next(vm2.io)) |entry| {
                        const name_str = try PyStringObject.create(entry.name, vm2.mm);
                        defer name_str.decRef(vm2.mm);
                        try list.append(name_str, vm2.mm);
                    }
                    return &list.base;
                }
            };
            const func = try PyBuiltinFunctionObject.create("listdir", T.listdirFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "listdir");
            try heap_globals.put(c, &func.base);
        }

        {
            const T = struct {
                fn systemFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    if (args[0].type_obj != &@import("../objects/primitives.zig").PyString_Type) return error.TypeError;
                    const command = args[0].as(PyStringObject).value();
                    
                    const argv = [_][]const u8{ "/bin/sh", "-c", command };
                    var child = std.process.Child.init(&argv, vm2.allocator);
                    const term = child.spawnAndWait() catch return error.OSError;
                    const exit_code = switch (term) {
                        .Exited => |code| code,
                        else => -1,
                    };
                    return try @import("../objects/primitives.zig").PyIntObject.create(@as(i64, @intCast(exit_code)), vm2.mm);
                }
            };
            const func = try PyBuiltinFunctionObject.create("system", T.systemFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "system");
            try heap_globals.put(c, &func.base);
        }
        
        {
            const path_c = try vm.allocator.dupe(u8, "path");
            try heap_globals.put(path_c, &path_module_obj.base);
        }
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "copy")) {
        const copy_src =
            \\def copy(x):
            \\    if hasattr(x, 'copy') and callable(x.copy):
            \\        return x.copy()
            \\    t = type(x)
            \\    if t is list:
            \\        return x.copy()
            \\    elif t is dict:
            \\        return x.copy()
            \\    elif t is set:
            \\        return set(x)
            \\    return x
            \\
            \\def deepcopy(x):
            \\    t = type(x)
            \\    if t is list:
            \\        res = list()
            \\        for item in x:
            \\            res.append(deepcopy(item))
            \\        return res
            \\    elif t is dict:
            \\        res = {}
            \\        for item in x.items():
            \\            res[deepcopy(item[0])] = deepcopy(item[1])
            \\        return res
            \\    elif t is tuple:
            \\        res = list()
            \\        for item in x:
            \\            res.append(deepcopy(item))
            \\        return tuple(res)
            \\    elif t is set:
            \\        res = set()
            \\        for item in x:
            \\            res.add(deepcopy(item))
            \\        return res
            \\    return copy(x)
            \\
        ;
        var lexer = Lexer.init(copy_src);
        var arena = std.heap.ArenaAllocator.init(vm.allocator);
        defer arena.deinit();
        
        var parser = Parser.init(&lexer, arena.allocator());
        const module_ast = parser.parseModule() catch return error.SyntaxError;
        
        var compiler = Compiler.init(arena.allocator(), vm.mm);
        defer compiler.deinit();
        
        var code = try compiler.compile(&module_ast);
        defer code.deinit(arena.allocator(), vm.mm);
        
        const result = try vm.run(&code, heap_globals);
        result.decRef(vm.mm);
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "collections")) {
        const collections_src =
            \\class Sentinel:
            \\    pass
            \\_sentinel = Sentinel()
            \\
            \\def namedtuple(typename, field_names):
            \\    if isinstance(field_names, str):
            \\        field_names = field_names.replace(',', ' ').split()
            \\    
            \\    class NT:
            \\        def __init__(self, val_list):
            \\            self._vals = val_list
            \\            for i in range(len(self._fields)):
            \\                setattr(self, self._fields[i], val_list[i])
            \\        def __getitem__(self, idx):
            \\            return self._vals[idx]
            \\        def __len__(self):
            \\            return len(self._vals)
            \\        def __repr__(self):
            \\            parts = list()
            \\            for i in range(len(self._fields)):
            \\                parts.append(self._fields[i] + "=" + repr(self._vals[i]))
            \\            return self._typename + "(" + ", ".join(parts) + ")"
            \\    
            \\    NT._fields = field_names
            \\    NT._typename = typename
            \\    
            \\    def factory(v0=_sentinel, v1=_sentinel, v2=_sentinel, v3=_sentinel, v4=_sentinel, v5=_sentinel, v6=_sentinel, v7=_sentinel):
            \\        vals = list()
            \\        if v0 is not _sentinel:
            \\            vals.append(v0)
            \\        if v1 is not _sentinel:
            \\            vals.append(v1)
            \\        if v2 is not _sentinel:
            \\            vals.append(v2)
            \\        if v3 is not _sentinel:
            \\            vals.append(v3)
            \\        if v4 is not _sentinel:
            \\            vals.append(v4)
            \\        if v5 is not _sentinel:
            \\            vals.append(v5)
            \\        if v6 is not _sentinel:
            \\            vals.append(v6)
            \\        if v7 is not _sentinel:
            \\            vals.append(v7)
            \\        return NT(vals)
            \\    
            \\    return factory
            \\
            \\class defaultdict:
            \\    def __init__(self, default_factory=None):
            \\        self._d = dict()
            \\        self.default_factory = default_factory
            \\    def __getitem__(self, key):
            \\        if key in self._d:
            \\            return self._d[key]
            \\        if self.default_factory is None:
            \\            raise KeyError(key)
            \\        val = self.default_factory()
            \\        self._d[key] = val
            \\        return val
            \\    def __setitem__(self, key, value):
            \\        self._d[key] = value
            \\    def __delitem__(self, key):
            \\        del self._d[key]
            \\    def __contains__(self, key):
            \\        return key in self._d
            \\    def __len__(self):
            \\        return len(self._d)
            \\    def keys(self):
            \\        return self._d.keys()
            \\    def values(self):
            \\        return self._d.values()
            \\    def items(self):
            \\        return self._d.items()
            \\    def get(self, key, default=None):
            \\        return self._d.get(key, default)
            \\    def pop(self, key, default=_sentinel):
            \\        if default is _sentinel:
            \\            return self._d.pop(key)
            \\        return self._d.pop(key, default)
            \\    def popitem(self):
            \\        return self._d.popitem()
            \\    def clear(self):
            \\        self._d.clear()
            \\    def update(self, other):
            \\        self._d.update(other)
            \\    def copy(self):
            \\        new_dd = defaultdict(self.default_factory)
            \\        new_dd._d = self._d.copy()
            \\        return new_dd
            \\    def __repr__(self):
            \\        return "defaultdict(" + repr(self.default_factory) + ", " + repr(self._d) + ")"
            \\
            \\OrderedDict = dict
            \\
            \\class Counter:
            \\    def __init__(self, iterable=None):
            \\        self._d = dict()
            \\        if iterable is not None:
            \\            for item in iterable:
            \\                self[item] = self.get(item, 0) + 1
            \\    def __getitem__(self, key):
            \\        return self._d.get(key, 0)
            \\    def __setitem__(self, key, value):
            \\        self._d[key] = value
            \\    def __delitem__(self, key):
            \\        if key in self._d:
            \\            del self._d[key]
            \\    def __contains__(self, key):
            \\        return key in self._d
            \\    def __len__(self):
            \\        return len(self._d)
            \\    def keys(self):
            \\        return self._d.keys()
            \\    def values(self):
            \\        return self._d.values()
            \\    def items(self):
            \\        return self._d.items()
            \\    def get(self, key, default=0):
            \\        return self._d.get(key, default)
            \\    def pop(self, key, default=_sentinel):
            \\        if default is _sentinel:
            \\            return self._d.pop(key)
            \\        return self._d.pop(key, default)
            \\    def clear(self):
            \\        self._d.clear()
            \\    def update(self, other):
            \\        if hasattr(other, 'keys'):
            \\            for k in other.keys():
            \\                self[k] = self.get(k, 0) + other[k]
            \\        else:
            \\            for item in other:
            \\                self[item] = self.get(item, 0) + 1
            \\    def __repr__(self):
            \\        return "Counter(" + repr(self._d) + ")"
            \\
        ;
        var lexer = Lexer.init(collections_src);
        var arena = std.heap.ArenaAllocator.init(vm.allocator);
        defer arena.deinit();
        
        var parser = Parser.init(&lexer, arena.allocator());
        const module_ast = parser.parseModule() catch return error.SyntaxError;
        
        var compiler = Compiler.init(arena.allocator(), vm.mm);
        defer compiler.deinit();
        
        var code = try compiler.compile(&module_ast);
        defer code.deinit(arena.allocator(), vm.mm);
        
        const result = try vm.run(&code, heap_globals);
        result.decRef(vm.mm);
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "functools")) {
        const functools_src =
            \\class Sentinel:
            \\    pass
            \\_sentinel = Sentinel()
            \\
            \\class partial:
            \\    def __init__(self, func, arg0=_sentinel, arg1=_sentinel, arg2=_sentinel):
            \\        self.func = func
            \\        self.arg0 = arg0
            \\        self.arg1 = arg1
            \\        self.arg2 = arg2
            \\    def __call__(self, v0=_sentinel, v1=_sentinel, v2=_sentinel):
            \\        args = list()
            \\        if self.arg0 is not _sentinel:
            \\            args.append(self.arg0)
            \\        if self.arg1 is not _sentinel:
            \\            args.append(self.arg1)
            \\        if self.arg2 is not _sentinel:
            \\            args.append(self.arg2)
            \\        if v0 is not _sentinel:
            \\            args.append(v0)
            \\        if v1 is not _sentinel:
            \\            args.append(v1)
            \\        if v2 is not _sentinel:
            \\            args.append(v2)
            \\        if len(args) == 1:
            \\            return self.func(args[0])
            \\        elif len(args) == 2:
            \\            return self.func(args[0], args[1])
            \\        elif len(args) == 3:
            \\            return self.func(args[0], args[1], args[2])
            \\        elif len(args) == 4:
            \\            return self.func(args[0], args[1], args[2], args[3])
            \\        elif len(args) == 5:
            \\            return self.func(args[0], args[1], args[2], args[3], args[4])
            \\        return self.func()
            \\
        ;
        var lexer = Lexer.init(functools_src);
        var arena = std.heap.ArenaAllocator.init(vm.allocator);
        defer arena.deinit();
        
        var parser = Parser.init(&lexer, arena.allocator());
        const module_ast = parser.parseModule() catch return error.SyntaxError;
        
        var compiler = Compiler.init(arena.allocator(), vm.mm);
        defer compiler.deinit();
        
        var code = try compiler.compile(&module_ast);
        defer code.deinit(arena.allocator(), vm.mm);
        
        const result = try vm.run(&code, heap_globals);
        result.decRef(vm.mm);
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "abc")) {
        const abc_src =
            \\_abstract_methods = list()
            \\
            \\def abstractmethod(func):
            \\    _abstract_methods.append(func)
            \\    return func
            \\
            \\class ABC:
            \\    def __init__(self):
            \\        for name in dir(self):
            \\            attr = getattr(type(self), name)
            \\            found = False
            \\            for f in _abstract_methods:
            \\                if f is attr:
            \\                    found = True
            \\            if found:
            \\                raise TypeError("Can't instantiate abstract class with abstract methods")
            \\
        ;
        var lexer = Lexer.init(abc_src);
        var arena = std.heap.ArenaAllocator.init(vm.allocator);
        defer arena.deinit();
        
        var parser = Parser.init(&lexer, arena.allocator());
        const module_ast = parser.parseModule() catch return error.SyntaxError;
        
        var compiler = Compiler.init(arena.allocator(), vm.mm);
        defer compiler.deinit();
        
        var code = try compiler.compile(&module_ast);
        defer code.deinit(arena.allocator(), vm.mm);
        
        const result = try vm.run(&code, heap_globals);
        result.decRef(vm.mm);
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "dataclasses")) {
        const dataclasses_src =
            \\class Sentinel:
            \\    pass
            \\_sentinel = Sentinel()
            \\
            \\def dataclass(cls):
            \\    fields = list()
            \\    anns = getattr(cls, '__annotations__', None)
            \\    if anns:
            \\        for k in anns.keys():
            \\            fields.append(k)
            \\    else:
            \\        for name in dir(cls):
            \\            if not name.startswith('_'):
            \\                val = getattr(cls, name)
            \\                if not callable(val):
            \\                    fields.append(name)
            \\    cls._fields = fields
            \\    cls._name = getattr(cls, '__name__', 'Point')
            \\    
            \\    def __init__(self, v0=_sentinel, v1=_sentinel, v2=_sentinel, v3=_sentinel, v4=_sentinel, v5=_sentinel):
            \\        vals = list()
            \\        if v0 is not _sentinel:
            \\            vals.append(v0)
            \\        if v1 is not _sentinel:
            \\            vals.append(v1)
            \\        if v2 is not _sentinel:
            \\            vals.append(v2)
            \\        if v3 is not _sentinel:
            \\            vals.append(v3)
            \\        if v4 is not _sentinel:
            \\            vals.append(v4)
            \\        if v5 is not _sentinel:
            \\            vals.append(v5)
            \\        for i in range(len(vals)):
            \\            if i < len(self._fields):
            \\                setattr(self, self._fields[i], vals[i])
            \\    
            \\    def __repr__(self):
            \\        parts = list()
            \\        for f in self._fields:
            \\            parts.append(f + "=" + repr(getattr(self, f, None)))
            \\        return self._name + "(" + ", ".join(parts) + ")"
            \\    
            \\    cls.__init__ = __init__
            \\    cls.__repr__ = __repr__
            \\    return cls
            \\
        ;
        var lexer = Lexer.init(dataclasses_src);
        var arena = std.heap.ArenaAllocator.init(vm.allocator);
        defer arena.deinit();
        
        var parser = Parser.init(&lexer, arena.allocator());
        const module_ast = parser.parseModule() catch return error.SyntaxError;
        
        var compiler = Compiler.init(arena.allocator(), vm.mm);
        defer compiler.deinit();
        
        var code = try compiler.compile(&module_ast);
        defer code.deinit(arena.allocator(), vm.mm);
        
        const result = try vm.run(&code, heap_globals);
        result.decRef(vm.mm);
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "importlib")) {
        {
            const T = struct {
                fn reloadFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    const module_obj = args[0];
                    if (module_obj.type_obj != &@import("import.zig").PyModule_Type) return error.TypeError;
                    
                    const module = module_obj.as(@import("import.zig").PyModuleObject);
                    const mod_name = module.name.as(PyStringObject).value();
                    
                    var file_name_buf: [128]u8 = undefined;
                    const file_name = std.fmt.bufPrint(&file_name_buf, "{s}.py", .{mod_name}) catch return error.ImportError;
                    
                    const cwd = std.Io.Dir.cwd();
                    var file = cwd.openFile(vm2.io, file_name, .{ .mode = .read_only }) catch return error.ImportError;
                    defer file.close(vm2.io);
                    
                    var buf: [1024]u8 = undefined;
                    var file_reader = file.reader(vm2.io, &buf);
                    const reader = &file_reader.interface;
                    const content = try reader.allocRemaining(vm2.allocator, .unlimited);
                    defer vm2.allocator.free(content);
                    
                    var lexer = Lexer.init(content);
                    var arena = std.heap.ArenaAllocator.init(vm2.allocator);
                    defer arena.deinit();
                    
                    var parser = Parser.init(&lexer, arena.allocator());
                    const module_ast = parser.parseModule() catch return error.SyntaxError;
                    
                    var compiler = Compiler.init(arena.allocator(), vm2.mm);
                    defer compiler.deinit();
                    
                    var code = try compiler.compile(&module_ast);
                    defer code.deinit(arena.allocator(), vm2.mm);
                    
                    const result = try vm2.run(&code, module.globals);
                    result.decRef(vm2.mm);
                    
                    const dict = module.dict.as(PyDictObject);
                    var git = module.globals.iterator();
                    while (git.next()) |entry| {
                        const key_str = try PyStringObject.create(entry.key_ptr.*, vm2.mm);
                        defer key_str.decRef(vm2.mm);
                        try dict.setItem(key_str, entry.value_ptr.*, vm2.mm);
                    }
                    
                    module_obj.incRef();
                    return module_obj;
                }
            };
            const func = try PyBuiltinFunctionObject.create("reload", T.reloadFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "reload");
            try heap_globals.put(c, &func.base);
        }
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "asyncio")) {
        {
            const T = struct {
                fn nativeSleepFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    const seconds = if (args[0].type_obj == PyFloat_Type) args[0].as(PyFloatObject).value
                        else if (args[0].type_obj == PyInt_Type) @as(f64, @floatFromInt(args[0].as(PyIntObject).value))
                        else return error.TypeError;
                    
                    const ns = @as(i96, @intFromFloat(seconds * 1_000_000_000.0));
                    const clock_dur = std.Io.Clock.Duration{
                        .raw = std.Io.Duration.fromNanoseconds(ns),
                        .clock = .awake,
                    };
                    clock_dur.sleep(vm2.io) catch return error.OSError;
                    const PyNone = @import("../objects/primitives.zig").PyNone;
                    PyNone.incRef();
                    return PyNone;
                }
            };
            const func = try PyBuiltinFunctionObject.create("_sleep", T.nativeSleepFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "_sleep");
            try heap_globals.put(c, &func.base);
        }
        const asyncio_src =
            \\def sleep(seconds):
            \\    _sleep(seconds)
            \\    yield None
            \\
        ;
        var lexer = Lexer.init(asyncio_src);
        var arena = std.heap.ArenaAllocator.init(vm.allocator);
        defer arena.deinit();
        
        var parser = Parser.init(&lexer, arena.allocator());
        const module_ast = parser.parseModule() catch return error.SyntaxError;
        
        var compiler = Compiler.init(arena.allocator(), vm.mm);
        defer compiler.deinit();
        
        var code = try compiler.compile(&module_ast);
        defer code.deinit(arena.allocator(), vm.mm);
        
        const result = try vm.run(&code, heap_globals);
        result.decRef(vm.mm);
        compiled_success = true;
    } else {
        var file_name_buf: [128]u8 = undefined;
        const file_name = std.fmt.bufPrint(&file_name_buf, "{s}.py", .{name}) catch return error.ImportError;
        
        const cwd = std.Io.Dir.cwd();
        var file = cwd.openFile(vm.io, file_name, .{ .mode = .read_only }) catch {
            std.debug.print("ImportError: Module '{s}' not found\n", .{name});
            return error.ImportError;
        };
        defer file.close(vm.io);
        
        var buf: [1024]u8 = undefined;
        var file_reader = file.reader(vm.io, &buf);
        const reader = &file_reader.interface;
        const content = try reader.allocRemaining(vm.allocator, .unlimited);
        defer vm.allocator.free(content);
        
        var lexer = Lexer.init(content);
        var arena = std.heap.ArenaAllocator.init(vm.allocator);
        defer arena.deinit();
        
        var parser = Parser.init(&lexer, arena.allocator());
        const module_ast = parser.parseModule() catch return error.SyntaxError;
        
        var compiler = Compiler.init(arena.allocator(), vm.mm);
        defer compiler.deinit();
        
        var code = try compiler.compile(&module_ast);
        defer code.deinit(arena.allocator(), vm.mm);
        
        const result = try vm.run(&code, heap_globals);
        result.decRef(vm.mm);
        compiled_success = true;
    }
    
    if (!compiled_success) return error.ImportError;
    
    const dict = try PyDictObject.create(vm.mm);
    defer dict.base.decRef(vm.mm);
    
    var it = heap_globals.iterator();
    while (it.next()) |entry| {
        const key_str = try PyStringObject.create(entry.key_ptr.*, vm.mm);
        defer key_str.decRef(vm.mm);
        try dict.setItem(key_str, entry.value_ptr.*, vm.mm);
    }
    
    const name_str = try PyStringObject.create(name, vm.mm);
    defer name_str.decRef(vm.mm);
    const module_obj = try PyModuleObject.create(name_str, &dict.base, heap_globals, vm.mm);
    
    const name_copy = try vm.allocator.dupe(u8, name);
    module_obj.base.incRef();
    try sys_modules.?.put(name_copy, &module_obj.base);
    
    if (sys_modules_dict) |sys_dict| {
        const key_str = try PyStringObject.create(name, vm.mm);
        defer key_str.decRef(vm.mm);
        try sys_dict.as(PyDictObject).setItem(key_str, &module_obj.base, vm.mm);
    }
    
    return &module_obj.base;
}
