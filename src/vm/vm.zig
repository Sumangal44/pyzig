const std = @import("std");
const testing = std.testing;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyObject = @import("../objects/object.zig").PyObject;
const PyTypeObject = @import("../objects/object.zig").PyTypeObject;
const CompareOp = @import("../objects/object.zig").CompareOp;
const primitives = @import("../objects/primitives.zig");
const PyNone = primitives.PyNone;
const PyTrue = primitives.PyTrue;
const PyFalse = primitives.PyFalse;
const PyStringObject = primitives.PyStringObject;
const PyString_Type = &primitives.PyString_Type;
const PyNone_Type = &primitives.PyNone_Type;
const PyBool_Type = &primitives.PyBool_Type;
const PyInt_Type = &primitives.PyInt_Type;
const PyFloat_Type = &primitives.PyFloat_Type;
const PyComplex_Type = &primitives.PyComplex_Type;
const PyBytes_Type = &primitives.PyBytes_Type;
const PyByteArray_Type = &primitives.PyByteArray_Type;
const bytecode = @import("../bytecode/bytecode.zig");
const Opcode = bytecode.Opcode;

fn swapOp(op: CompareOp) CompareOp {
    return switch (op) {
        .Lt => .Gt,
        .Le => .Ge,
        .Eq => .Eq,
        .Ne => .Ne,
        .Gt => .Lt,
        .Ge => .Le,
    };
}
const Instruction = bytecode.Instruction;
const PyCodeObject = bytecode.PyCodeObject;
const PyCodeObjectWrapper = bytecode.PyCodeObjectWrapper;

const collections = @import("../objects/collections.zig");
const PyTupleObject = collections.PyTupleObject;
const PyTuple_Type = &collections.PyTuple_Type;
const PyListObject = collections.PyListObject;
const PyList_Type = &collections.PyList_Type;
const PyDictObject = collections.PyDictObject;
const PyDict_Type = &collections.PyDict_Type;
const PySet_Type = &collections.PySet_Type;
const PyFrozenSet_Type = &collections.PyFrozenSet_Type;

const function_mod = @import("../objects/function.zig");
const PyFunctionObject = function_mod.PyFunctionObject;
const PyFunction_Type = &function_mod.PyFunction_Type;
const PyBuiltinFunctionObject = function_mod.PyBuiltinFunctionObject;
const PyBuiltinFunction_Type = &function_mod.PyBuiltinFunction_Type;
const PyGenerator_Type = &function_mod.PyGenerator_Type;

const class_mod = @import("../objects/class.zig");
const PyClassObject = class_mod.PyClassObject;
const PyInstanceObject = class_mod.PyInstanceObject;
const PyMethodObject = class_mod.PyMethodObject;
const PyMethod_Type = &class_mod.PyMethod_Type;
const PyClass_Type = &class_mod.PyClass_Type;
const PyInstance_Type = &class_mod.PyInstance_Type;
const PySuperObject = class_mod.PySuperObject;
const PySuper_Type = &class_mod.PySuper_Type;
const exception_mod = @import("../objects/exception.zig");
const PyExceptionObject = exception_mod.PyExceptionObject;
const PyException_Type = &exception_mod.PyException_Type;
const PyAssertionError_Type = &exception_mod.PyAssertionError_Type;
const PyTypeError_Type = &exception_mod.PyTypeError_Type;
const PyValueError_Type = &exception_mod.PyValueError_Type;
const PyKeyError_Type = &exception_mod.PyKeyError_Type;
const PyIndexError_Type = &exception_mod.PyIndexError_Type;
const PyStopIteration_Type = &exception_mod.PyStopIteration_Type;
const PyAttributeError_Type = &exception_mod.PyAttributeError_Type;
const PyNameError_Type = &exception_mod.PyNameError_Type;
const PyRuntimeError_Type = &exception_mod.PyRuntimeError_Type;
const cell_mod = @import("../objects/cell.zig");
const PyCellObject = cell_mod.PyCellObject;
const PyCell_Type = &cell_mod.PyCell_Type;
const slice_mod = @import("../objects/slice.zig");
const PySliceObject = slice_mod.PySliceObject;
const PySlice_Type = &slice_mod.PySlice_Type;
const PyProperty_Type = &(@import("../objects/property.zig").PyProperty_Type);
const PyClassMethod_Type = &(@import("../objects/classmethod.zig").PyClassMethod_Type);
const PyStaticMethod_Type = &(@import("../objects/staticmethod.zig").PyStaticMethod_Type);
const PyRange_Type = &(@import("../objects/range.zig").PyRange_Type);
const PyTypeWrapper_Type = &(@import("../stdlib/builtins.zig").PyTypeWrapper_Type);
const PyModule_Type = &(@import("../import_system/import.zig").PyModule_Type);

pub const BlockType = enum {
    Finally,
    Except,
    With,
};

pub const Block = struct {
    type: BlockType,
    handler: usize,
    stack_level: usize,
    exit_func: ?*PyObject = null,
};

pub const StackHelper = struct {
    pub inline fn push(f: *PyFrameObject, stack_top: *usize, obj: *PyObject) void {
        f.stack[stack_top.*] = obj;
        stack_top.* += 1;
    }
    pub inline fn pop(f: *PyFrameObject, stack_top: *usize) *PyObject {
        stack_top.* -= 1;
        return f.stack[stack_top.*];
    }
};

pub const PyFrameObject = struct {
    code: *PyCodeObject,
    ip: usize = 0,
    stack: [256]*PyObject = undefined,
    stack_top: usize = 0,
    locals: std.StringHashMap(*PyObject),
    globals: *std.StringHashMap(*PyObject),
    is_module: bool,
    fastlocals: []?*PyObject = &[_]?*PyObject{},
    
    // Exception blocks and class/method fields
    block_stack: [16]Block = undefined,
    block_stack_top: usize = 0,
    is_class_body: bool = false,
    class_name: ?*PyObject = null,
    class_base: ?*PyObject = null,
    init_instance: ?*PyObject = null,
    func: ?*PyFunctionObject = null,
    active_exception: ?*PyObject = null,
    generator: ?*PyObject = null,

    pub fn init(allocator: std.mem.Allocator, code: *PyCodeObject, globals: *std.StringHashMap(*PyObject), is_module: bool) PyFrameObject {
        var fastlocals: []?*PyObject = &[_]?*PyObject{};
        if (code.varnames.len > 0) {
            fastlocals = allocator.alloc(?*PyObject, code.varnames.len) catch @panic("OOM");
            @memset(fastlocals, null);
        }
        return .{
            .code = code,
            .locals = std.StringHashMap(*PyObject).init(allocator),
            .globals = globals,
            .is_module = is_module,
            .fastlocals = fastlocals,
        };
    }

    pub fn deinit(self: *PyFrameObject, mm: *PyMemoryManager, allocator: std.mem.Allocator) void {
        var it = self.locals.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.decRef(mm);
        }
        self.locals.deinit();
        for (self.fastlocals) |opt_val| {
            if (opt_val) |val| val.decRef(mm);
        }
        if (self.fastlocals.len > 0) {
            allocator.free(self.fastlocals);
        }
        while (self.stack_top > 0) {
            self.stack_top -= 1;
            self.stack[self.stack_top].decRef(mm);
        }
        if (self.class_name) |cn| cn.decRef(mm);
        if (self.class_base) |cb| cb.decRef(mm);
        if (self.init_instance) |ii| ii.decRef(mm);
        if (self.func) |fu| fu.base.decRef(mm);
        if (self.active_exception) |ae| ae.decRef(mm);
    }

    pub inline fn push(self: *PyFrameObject, obj: *PyObject) void {
        if (std.debug.runtime_safety) {
            if (self.stack_top >= 256) {
                @panic("Stack overflow");
            }
        }
        self.stack[self.stack_top] = obj;
        self.stack_top += 1;
    }

    pub inline fn pop(self: *PyFrameObject) *PyObject {
        if (std.debug.runtime_safety) {
            if (self.stack_top == 0) {
                @panic("Stack underflow");
            }
        }
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }
};

pub fn isTrue(obj: *PyObject) bool {
    if (obj == PyTrue) return true;
    if (obj == PyFalse or obj == PyNone) return false;
    const t = obj.type_obj;
    if (t == PyList_Type) {
        return obj.as(PyListObject).size > 0;
    }
    if (t == PyTuple_Type) {
        return obj.as(PyTupleObject).size > 0;
    }
    if (t == PyDict_Type) {
        return obj.as(PyDictObject).active_count > 0;
    }
    if (t == PyInt_Type) {
        return obj.as(primitives.PyIntObject).value != 0;
    }
    if (t == PyFloat_Type) {
        return obj.as(primitives.PyFloatObject).value != 0.0;
    }
    if (t.tp_bool) |bool_fn| {
        return bool_fn(obj);
    }
    return true;
}

pub const VM = struct {
    pub const DiagnosticMode = enum {
        none,
        hinglish,
        jugaad,
    };

    allocator: std.mem.Allocator,
    mm: *PyMemoryManager,
    frames: [64]PyFrameObject = undefined,
    frame_count: usize = 0,
    globals: std.StringHashMap(*PyObject),
    stdout_writer: *std.Io.Writer,
    last_result: ?*PyObject = null,
    suppress_exception_handling: bool = false,
    io: std.Io,
    diagnostic_mode: DiagnosticMode = .none,

    fn buildClass(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
        // args[0] = body func, args[1] = class name str, args[2]? = base class
        const vm: *VM = @ptrCast(@alignCast(vm_opaque));
        if (args.len < 2) return error.TypeError;
        
        const body_func = args[0];
        const name_obj = args[1];
        const base_obj: ?*PyObject = if (args.len >= 3) args[2] else null;
        
        if (body_func.type_obj != PyFunction_Type) return error.TypeError;
        if (name_obj.type_obj != PyString_Type) return error.TypeError;
        
        const func = body_func.as(PyFunctionObject);
        const code_wrapper = func.code.as(PyCodeObjectWrapper);
        const func_code = code_wrapper.code;
        
        if (vm.frame_count >= 64) return error.StackOverflow;
        
        // Build a class frame — locals become class attributes
        const child_frame = PyFrameObject{
            .code = func_code,
            .ip = 0,
            .stack_top = 0,
            .locals = std.StringHashMap(*PyObject).init(vm.allocator),
            .globals = func.globals,
            .is_module = false,
            .is_class_body = true,
            .class_name = name_obj,
            .class_base = base_obj,
            .func = func,
        };
        name_obj.incRef();
        if (base_obj) |b| b.incRef();
        func.base.incRef();
        
        vm.frames[vm.frame_count] = child_frame;
        vm.frame_count += 1;
        // Return sentinel None; popFrameAndPushResult will push the real class object
        return PyNone;
    }

    fn registerBuiltin(self: *VM, name: []const u8, func: *const fn (args: []*PyObject, vm: *anyopaque) anyerror!*PyObject) !void {
        const builtin_obj = try PyBuiltinFunctionObject.create(name, func, self.mm);
        errdefer builtin_obj.base.decRef(self.mm);
        const name_copy = try self.allocator.dupe(u8, name);
        try self.globals.put(name_copy, &builtin_obj.base);
    }

    fn registerExceptionClass(self: *VM) !void {
        var wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyException_Type, self.mm);
        var name_copy = try self.allocator.dupe(u8, "Exception");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyAssertionError_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "AssertionError");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyTypeError_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "TypeError");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyValueError_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "ValueError");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyKeyError_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "KeyError");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyIndexError_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "IndexError");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyStopIteration_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "StopIteration");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyAttributeError_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "AttributeError");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyNameError_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "NameError");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyRuntimeError_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "RuntimeError");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/class.zig").PyInstance_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "object");
        try self.globals.put(name_copy, &wrapper.base);
    }

    pub fn init(allocator: std.mem.Allocator, mm: *PyMemoryManager, stdout_writer: *std.Io.Writer, io: std.Io) anyerror!VM {
        var vm = VM{
            .allocator = allocator,
            .mm = mm,
            .stdout_writer = stdout_writer,
            .globals = std.StringHashMap(*PyObject).init(allocator),
            .io = io,
            .diagnostic_mode = .none,
        };
        errdefer vm.deinit();
        
        const builtins = @import("../stdlib/builtins.zig");
        try vm.registerBuiltin("len", builtins.builtinLen);
        try vm.registerBuiltin("type", builtins.builtinType);
        try vm.registerBuiltin("next", builtins.builtinNext);
        try vm.registerBuiltin("range", builtins.builtinRange);
        try vm.registerBuiltin("str", builtins.builtinStr);
        try vm.registerBuiltin("classmethod", builtins.builtinClassmethod);
        try vm.registerBuiltin("staticmethod", builtins.builtinStaticmethod);
        try vm.registerBuiltin("eval", builtins.builtinEval);
        try vm.registerBuiltin("print", builtins.builtinPrint);
        try vm.registerBuiltin("input", builtins.builtinInput);
        try vm.registerBuiltin("int", builtins.builtinInt);
        try vm.registerBuiltin("float", builtins.builtinFloat);
        try vm.registerBuiltin("complex", builtins.builtinComplex);
        try vm.registerBuiltin("bool", builtins.builtinBool);
        try vm.registerBuiltin("abs", builtins.builtinAbs);
        try vm.registerBuiltin("max", builtins.builtinMax);
        try vm.registerBuiltin("min", builtins.builtinMin);
        try vm.registerBuiltin("sum", builtins.builtinSum);
        try vm.registerBuiltin("list", builtins.builtinList);
        try vm.registerBuiltin("tuple", builtins.builtinTuple);
        try vm.registerBuiltin("dict", builtins.builtinDict);
        try vm.registerBuiltin("bytes", builtins.builtinBytes);
        try vm.registerBuiltin("bytearray", builtins.builtinByteArray);
        try vm.registerBuiltin("set", builtins.builtinSet);
        try vm.registerBuiltin("frozenset", builtins.builtinFrozenSet);
        try vm.registerBuiltin("isinstance", builtins.builtinIsinstance);
        try vm.registerBuiltin("hasattr", builtins.builtinHasattr);
        try vm.registerBuiltin("getattr", builtins.builtinGetattr);
        try vm.registerBuiltin("setattr", builtins.builtinSetattr);
        try vm.registerBuiltin("repr", builtins.builtinRepr);
        try vm.registerBuiltin("id", builtins.builtinId);
        try vm.registerBuiltin("chr", builtins.builtinChr);
        try vm.registerBuiltin("ord", builtins.builtinOrd);
        try vm.registerBuiltin("hex", builtins.builtinHex);
        try vm.registerBuiltin("oct", builtins.builtinOct);
        try vm.registerBuiltin("bin", builtins.builtinBin);
        try vm.registerBuiltin("enumerate", builtins.builtinEnumerate);
        try vm.registerBuiltin("zip", builtins.builtinZip);
        try vm.registerBuiltin("map", builtins.builtinMap);
        try vm.registerBuiltin("filter", builtins.builtinFilter);
        try vm.registerBuiltin("sorted", builtins.builtinSorted);
        try vm.registerBuiltin("reversed", builtins.builtinReversed);
        try vm.registerBuiltin("any", builtins.builtinAny);
        try vm.registerBuiltin("all", builtins.builtinAll);
        try vm.registerBuiltin("pow", builtins.builtinPow);
        try vm.registerBuiltin("round", builtins.builtinRound);
        try vm.registerBuiltin("hash", builtins.builtinHash);
        try vm.registerBuiltin("property", builtins.builtinProperty);
        try vm.registerBuiltin("dir", builtins.builtinDir);
        try vm.registerBuiltin("callable", builtins.builtinCallable);
        try vm.registerBuiltin("delattr", builtins.builtinDelattr);
        try vm.registerBuiltin("divmod", builtins.builtinDivmod);
        try vm.registerBuiltin("ascii", builtins.builtinAscii);
        try vm.registerBuiltin("globals", builtins.builtinGlobals);
        try vm.registerBuiltin("locals", builtins.builtinLocals);
        try vm.registerBuiltin("vars", builtins.builtinVars);
        try vm.registerBuiltin("issubclass", builtins.builtinIssubclass);
        try vm.registerBuiltin("open", builtins.builtinOpen);
        try vm.registerBuiltin("help", builtins.builtinHelp);
        try vm.registerBuiltin("super", builtins.builtinSuper);
        try vm.registerBuiltin("__build_class__", buildClass);
        try vm.registerExceptionClass();
        
        return vm;
    }

    pub fn deinit(self: *VM) void {
        var it = self.globals.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.decRef(self.mm);
        }
        self.globals.deinit();
        
        @import("../import_system/import.zig").deinitImportSystem(self.mm);
        
        while (self.frame_count > 0) {
            self.frame_count -= 1;
            self.frames[self.frame_count].deinit(self.mm, self.allocator);
        }
    }

    fn popFrameAndPushResult(self: *VM, result: *PyObject, starting_frame_count: usize) void {
        var f = &self.frames[self.frame_count - 1];
        
        if (f.generator) |gen_val| {
            const gen = gen_val.as(function_mod.PyGeneratorObject);
            gen.is_closed = true;
            result.decRef(self.mm);
            
            f.deinit(self.mm, self.allocator);
            self.frame_count -= 1;
            
            if (self.frame_count > starting_frame_count) {
                const caller_f = &self.frames[self.frame_count - 1];
                if (caller_f.code.instructions[caller_f.ip].op == .FOR_ITER) {
                    const dummy = primitives.PyIntObject.create(0, self.mm) catch @panic("OOM");
                    caller_f.push(dummy);
                }
            }
            return;
        }

        var actual_result = result;
        if (f.is_class_body) {
            result.decRef(self.mm);
            
            const dict = PyDictObject.create(self.mm) catch @panic("OOM");
            var it = f.locals.iterator();
            while (it.next()) |entry| {
                const key_str = PyStringObject.create(entry.key_ptr.*, self.mm) catch @panic("OOM");
                defer key_str.decRef(self.mm);
                dict.setItem(key_str, entry.value_ptr.*, self.mm) catch @panic("OOM");
            }
            
            const class_obj = PyClassObject.create(f.class_name.?, f.class_base, &dict.base, self.mm) catch @panic("OOM");
            dict.base.decRef(self.mm); // PyClassObject.create did incRef; drop our local ref
            actual_result = &class_obj.base;
        } else if (f.init_instance) |inst| {
            result.decRef(self.mm);
            // Transfer ownership: null out init_instance so f.deinit doesn't decRef it,
            // then use that reference as actual_result directly.
            f.init_instance = null;
            actual_result = inst;
        }
        
        f.deinit(self.mm, self.allocator);
        self.frame_count -= 1;
        
        if (self.frame_count > starting_frame_count) {
            self.frames[self.frame_count - 1].push(actual_result);
        } else {
            self.last_result = actual_result;
        }
    }

    pub fn lookupClassAttribute(self: *VM, class_obj: *PyClassObject, name: []const u8) anyerror!?*PyObject {
        const key_str = try self.mm.internString(name);
        
        var current: ?*PyClassObject = class_obj;
        while (current) |curr| {
            const dict = curr.dict.as(PyDictObject);
            if (try dict.getItem(key_str, self.mm)) |val| {
                val.incRef();
                return val;
            }
            if (curr.base_class) |base| {
                if (base.type_obj == PyTypeWrapper_Type) {
                    // Built-in base (e.g., Exception) — stop traversal
                    current = null;
                } else {
                    current = base.as(PyClassObject);
                }
            } else {
                current = null;
            }
        }
        return null;
    }

    fn isExceptionMatch(self: *VM, exc: *PyObject, type_name: []const u8) bool {
        _ = self;
        // User-defined class instance (PyInstanceObject wraps PyClassObject)
        if (exc.type_obj == PyInstance_Type) {
            const inst = exc.as(PyInstanceObject);
            var curr: ?*PyClassObject = inst.class_obj;
            while (curr) |cls| {
                const cls_name = cls.name.as(PyStringObject).value();
                if (std.mem.eql(u8, cls_name, type_name)) return true;
                if (cls.base_class) |bc| {
                    if (bc.type_obj == PyTypeWrapper_Type) {
                        const wrapper = bc.as(@import("../stdlib/builtins.zig").PyTypeWrapper);
                        if (std.mem.eql(u8, wrapper.type_ptr.name, type_name)) return true;
                        if (std.mem.eql(u8, type_name, "Exception")) return true;
                        break;
                    }
                    curr = bc.as(PyClassObject);
                } else {
                    break;
                }
            }
            if (std.mem.eql(u8, type_name, "Exception")) {
                var c: ?*PyClassObject = inst.class_obj;
                while (c) |cls| {
                    if (cls.base_class) |bc| {
                        if (bc.type_obj == PyTypeWrapper_Type) {
                            return true;
                        }
                        c = bc.as(PyClassObject);
                    } else break;
                }
            }
        }
        const exc_type_name = exc.type_obj.name;
        if (std.mem.eql(u8, exc_type_name, type_name)) return true;
        if (std.mem.eql(u8, type_name, "Exception")) return true;
        return false;
    }

    fn returnAttributeError(self: *VM, inst: *PyObject, name: []const u8) anyerror!*PyObject {
        var buf: [256]u8 = undefined;
        const type_name = if (inst.type_obj == PyInstance_Type)
            inst.as(PyInstanceObject).class_obj.name.as(PyStringObject).value()
        else
            inst.type_obj.name;
        const msg = std.fmt.bufPrint(&buf, "AttributeError: '{s}' object has no attribute '{s}'. (Did you typo it, or did it vanish into thin air?)", .{type_name, name}) catch "AttributeError: missing attribute";
        try self.raiseAttributeError(msg);
        return error.PythonException;
    }

    pub fn loadAttribute(self: *VM, inst: *PyObject, name: []const u8) anyerror!*PyObject {
        const key_str = try self.mm.internString(name);
        
        if (inst.type_obj == PySuper_Type) {
            const super_obj = inst.as(PySuperObject);
            if (super_obj.lookup_class) |lookup_class| {
                if (try self.lookupClassAttribute(lookup_class, name)) |val| {
                    if (val.type_obj == PyProperty_Type) {
                        const prop = val.as(@import("../objects/property.zig").PyPropertyObject);
                        val.decRef(self.mm);
                        if (prop.fget) |fget| {
                            var call_args = [_]*PyObject{super_obj.self_obj};
                            return try self.callCallable(fget, &call_args);
                        }
                        return try self.returnAttributeError(inst, name);
                    }
                    if (val.type_obj == PyStaticMethod_Type) {
                        const sm = val.as(@import("../objects/staticmethod.zig").PyStaticMethodObject);
                        const func = sm.func;
                        func.incRef();
                        val.decRef(self.mm);
                        return func;
                    }
                    if (val.type_obj == PyClassMethod_Type) {
                        const cm = val.as(@import("../objects/classmethod.zig").PyClassMethodObject);
                        const self_class_base = super_obj.self_obj;
                        const bound = try PyMethodObject.create(self_class_base, cm.func, self.mm);
                        val.decRef(self.mm);
                        return &bound.base;
                    }
                    if (val.type_obj == PyFunction_Type) {
                        const bound = try PyMethodObject.create(super_obj.self_obj, val, self.mm);
                        val.decRef(self.mm);
                        return &bound.base;
                    }
                    return val;
                }
            }
            return try self.returnAttributeError(inst, name);
        }

        if (inst.type_obj == PyInstance_Type) {
            const instance = inst.as(PyInstanceObject);
            const dict = instance.dict.as(PyDictObject);
            if (try dict.getItem(key_str, self.mm)) |val| {
                val.incRef();
                return val;
            }
            
            if (try self.lookupClassAttribute(instance.class_obj, name)) |val| {
                if (val.type_obj == PyProperty_Type) {
                    const prop = val.as(@import("../objects/property.zig").PyPropertyObject);
                    val.decRef(self.mm);
                    if (prop.fget) |fget| {
                        var call_args = [_]*PyObject{inst};
                        return try self.callCallable(fget, &call_args);
                    }
                    return try self.returnAttributeError(inst, name);
                }
                if (val.type_obj == PyStaticMethod_Type) {
                    const sm = val.as(@import("../objects/staticmethod.zig").PyStaticMethodObject);
                    const func = sm.func;
                    func.incRef();
                    val.decRef(self.mm);
                    return func;
                }
                if (val.type_obj == PyClassMethod_Type) {
                    const cm = val.as(@import("../objects/classmethod.zig").PyClassMethodObject);
                    const bound = try PyMethodObject.create(&instance.class_obj.base, cm.func, self.mm);
                    val.decRef(self.mm);
                    return &bound.base;
                }
                if (val.type_obj == PyFunction_Type) {
                    const bound = try PyMethodObject.create(inst, val, self.mm);
                    val.decRef(self.mm);
                    return &bound.base;
                }
                return val;
            }
            

            return try self.returnAttributeError(inst, name);
        } else if (inst.type_obj == PyModule_Type) {
            const module = inst.as(@import("../import_system/import.zig").PyModuleObject);
            const dict = module.dict.as(PyDictObject);
            if (try dict.getItem(key_str, self.mm)) |val| {
                val.incRef();
                return val;
            }

            return try self.returnAttributeError(inst, name);
        } else if (inst.type_obj == PySet_Type) {
            const builtins = @import("../stdlib/builtins.zig");
            var method_func: *PyObject = undefined;
            if (std.mem.eql(u8, name, "add")) {
                const builtin_func = try PyBuiltinFunctionObject.create("add", builtins.setAddMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "remove")) {
                const builtin_func = try PyBuiltinFunctionObject.create("remove", builtins.setRemoveMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "discard")) {
                const builtin_func = try PyBuiltinFunctionObject.create("discard", builtins.setDiscardMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "pop")) {
                const builtin_func = try PyBuiltinFunctionObject.create("pop", builtins.setPopMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "clear")) {
                const builtin_func = try PyBuiltinFunctionObject.create("clear", builtins.setClearMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "copy")) {
                const builtin_func = try PyBuiltinFunctionObject.create("copy", builtins.setCopyMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "issubset")) {
                const builtin_func = try PyBuiltinFunctionObject.create("issubset", builtins.setIssubsetMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "issuperset")) {
                const builtin_func = try PyBuiltinFunctionObject.create("issuperset", builtins.setIssupersetMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "isdisjoint")) {
                const builtin_func = try PyBuiltinFunctionObject.create("isdisjoint", builtins.setIsdisjointMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "update")) {
                const builtin_func = try PyBuiltinFunctionObject.create("update", builtins.setUpdateMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "difference_update")) {
                const builtin_func = try PyBuiltinFunctionObject.create("difference_update", builtins.setDifferenceUpdateMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "intersection_update")) {
                const builtin_func = try PyBuiltinFunctionObject.create("intersection_update", builtins.setIntersectionUpdateMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "symmetric_difference_update")) {
                const builtin_func = try PyBuiltinFunctionObject.create("symmetric_difference_update", builtins.setSymmetricDifferenceUpdateMethod, self.mm);
                method_func = &builtin_func.base;
            } else {
                return try self.returnAttributeError(inst, name);
            }
            const bound = try PyMethodObject.create(inst, method_func, self.mm);
            method_func.decRef(self.mm);
            return &bound.base;
        } else if (inst.type_obj == PyList_Type) {
            const builtins = @import("../stdlib/builtins.zig");
            var method_func: *PyObject = undefined;
            if (std.mem.eql(u8, name, "append")) {
                const builtin_func = try PyBuiltinFunctionObject.create("append", builtins.listAppendMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "insert")) {
                const builtin_func = try PyBuiltinFunctionObject.create("insert", builtins.listInsertMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "pop")) {
                const builtin_func = try PyBuiltinFunctionObject.create("pop", builtins.listPopMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "remove")) {
                const builtin_func = try PyBuiltinFunctionObject.create("remove", builtins.listRemoveMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "index")) {
                const builtin_func = try PyBuiltinFunctionObject.create("index", builtins.listIndexMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "count")) {
                const builtin_func = try PyBuiltinFunctionObject.create("count", builtins.listCountMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "reverse")) {
                const builtin_func = try PyBuiltinFunctionObject.create("reverse", builtins.listReverseMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "sort")) {
                const builtin_func = try PyBuiltinFunctionObject.create("sort", builtins.listSortMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "extend")) {
                const builtin_func = try PyBuiltinFunctionObject.create("extend", builtins.listExtendMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "clear")) {
                const builtin_func = try PyBuiltinFunctionObject.create("clear", builtins.listClearMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "copy")) {
                const builtin_func = try PyBuiltinFunctionObject.create("copy", builtins.listCopyMethod, self.mm);
                method_func = &builtin_func.base;
            } else {
                return try self.returnAttributeError(inst, name);
            }
            const bound = try PyMethodObject.create(inst, method_func, self.mm);
            method_func.decRef(self.mm);
            return &bound.base;
        } else if (inst.type_obj == PyDict_Type) {
            const builtins = @import("../stdlib/builtins.zig");
            var method_func: *PyObject = undefined;
            if (std.mem.eql(u8, name, "keys")) {
                const builtin_func = try PyBuiltinFunctionObject.create("keys", builtins.dictKeysMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "values")) {
                const builtin_func = try PyBuiltinFunctionObject.create("values", builtins.dictValuesMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "items")) {
                const builtin_func = try PyBuiltinFunctionObject.create("items", builtins.dictItemsMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "get")) {
                const builtin_func = try PyBuiltinFunctionObject.create("get", builtins.dictGetMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "pop")) {
                const builtin_func = try PyBuiltinFunctionObject.create("pop", builtins.dictPopMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "update")) {
                const builtin_func = try PyBuiltinFunctionObject.create("update", builtins.dictUpdateMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "clear")) {
                const builtin_func = try PyBuiltinFunctionObject.create("clear", builtins.dictClearMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "copy")) {
                const builtin_func = try PyBuiltinFunctionObject.create("copy", builtins.dictCopyMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "setdefault")) {
                const builtin_func = try PyBuiltinFunctionObject.create("setdefault", builtins.dictSetdefaultMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "popitem")) {
                const builtin_func = try PyBuiltinFunctionObject.create("popitem", builtins.dictPopitemMethod, self.mm);
                method_func = &builtin_func.base;
            } else {
                return try self.returnAttributeError(inst, name);
            }
            const bound = try PyMethodObject.create(inst, method_func, self.mm);
            method_func.decRef(self.mm);
            return &bound.base;
        } else if (inst.type_obj == PyString_Type) {
            const builtins = @import("../stdlib/builtins.zig");
            var method_func: *PyObject = undefined;
            if (std.mem.eql(u8, name, "split")) {
                const builtin_func = try PyBuiltinFunctionObject.create("split", builtins.stringSplitMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "join")) {
                const builtin_func = try PyBuiltinFunctionObject.create("join", builtins.stringJoinMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "replace")) {
                const builtin_func = try PyBuiltinFunctionObject.create("replace", builtins.stringReplaceMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "strip")) {
                const builtin_func = try PyBuiltinFunctionObject.create("strip", builtins.stringStripMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "lower")) {
                const builtin_func = try PyBuiltinFunctionObject.create("lower", builtins.stringLowerMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "upper")) {
                const builtin_func = try PyBuiltinFunctionObject.create("upper", builtins.stringUpperMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "startswith")) {
                const builtin_func = try PyBuiltinFunctionObject.create("startswith", builtins.stringStartsWithMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "endswith")) {
                const builtin_func = try PyBuiltinFunctionObject.create("endswith", builtins.stringEndsWithMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "capitalize")) {
                const builtin_func = try PyBuiltinFunctionObject.create("capitalize", builtins.stringCapitalizeMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "title")) {
                const builtin_func = try PyBuiltinFunctionObject.create("title", builtins.stringTitleMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "swapcase")) {
                const builtin_func = try PyBuiltinFunctionObject.create("swapcase", builtins.stringSwapcaseMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "lstrip")) {
                const builtin_func = try PyBuiltinFunctionObject.create("lstrip", builtins.stringLstripMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "rstrip")) {
                const builtin_func = try PyBuiltinFunctionObject.create("rstrip", builtins.stringRstripMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "find")) {
                const builtin_func = try PyBuiltinFunctionObject.create("find", builtins.stringFindMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "count")) {
                const builtin_func = try PyBuiltinFunctionObject.create("count", builtins.stringCountMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "center")) {
                const builtin_func = try PyBuiltinFunctionObject.create("center", builtins.stringCenterMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "ljust")) {
                const builtin_func = try PyBuiltinFunctionObject.create("ljust", builtins.stringLjustMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "rjust")) {
                const builtin_func = try PyBuiltinFunctionObject.create("rjust", builtins.stringRjustMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "zfill")) {
                const builtin_func = try PyBuiltinFunctionObject.create("zfill", builtins.stringZfillMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "isalpha")) {
                const builtin_func = try PyBuiltinFunctionObject.create("isalpha", builtins.stringIsalphaMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "isdigit")) {
                const builtin_func = try PyBuiltinFunctionObject.create("isdigit", builtins.stringIsdigitMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "isalnum")) {
                const builtin_func = try PyBuiltinFunctionObject.create("isalnum", builtins.stringIsalnumMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "isspace")) {
                const builtin_func = try PyBuiltinFunctionObject.create("isspace", builtins.stringIsspaceMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "islower")) {
                const builtin_func = try PyBuiltinFunctionObject.create("islower", builtins.stringIslowerMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "isupper")) {
                const builtin_func = try PyBuiltinFunctionObject.create("isupper", builtins.stringIsupperMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "istitle")) {
                const builtin_func = try PyBuiltinFunctionObject.create("istitle", builtins.stringIstitleMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "expandtabs")) {
                const builtin_func = try PyBuiltinFunctionObject.create("expandtabs", builtins.stringExpandtabsMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "partition")) {
                const builtin_func = try PyBuiltinFunctionObject.create("partition", builtins.stringPartitionMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "rpartition")) {
                const builtin_func = try PyBuiltinFunctionObject.create("rpartition", builtins.stringRpartitionMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "rfind")) {
                const builtin_func = try PyBuiltinFunctionObject.create("rfind", builtins.stringRfindMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "rindex")) {
                const builtin_func = try PyBuiltinFunctionObject.create("rindex", builtins.stringRindexMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "splitlines")) {
                const builtin_func = try PyBuiltinFunctionObject.create("splitlines", builtins.stringSplitlinesMethod, self.mm);
                method_func = &builtin_func.base;
            } else {
                return try self.returnAttributeError(inst, name);
            }
            const bound = try PyMethodObject.create(inst, method_func, self.mm);
            method_func.decRef(self.mm);
            return &bound.base;
        } else if (inst.type_obj == PyBytes_Type) {
            const builtins = @import("../stdlib/builtins.zig");
            var method_func: *PyObject = undefined;
            if (std.mem.eql(u8, name, "decode")) {
                const builtin_func = try PyBuiltinFunctionObject.create("decode", builtins.bytesDecodeMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "hex")) {
                const builtin_func = try PyBuiltinFunctionObject.create("hex", builtins.bytesHexMethod, self.mm);
                method_func = &builtin_func.base;
            } else {
                return try self.returnAttributeError(inst, name);
            }
            const bound = try PyMethodObject.create(inst, method_func, self.mm);
            method_func.decRef(self.mm);
            return &bound.base;
        } else if (inst.type_obj == PyByteArray_Type) {
            const builtins = @import("../stdlib/builtins.zig");
            var method_func: *PyObject = undefined;
            if (std.mem.eql(u8, name, "append")) {
                const builtin_func = try PyBuiltinFunctionObject.create("append", builtins.bytearrayAppendMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "decode")) {
                const builtin_func = try PyBuiltinFunctionObject.create("decode", builtins.bytesDecodeMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "hex")) {
                const builtin_func = try PyBuiltinFunctionObject.create("hex", builtins.bytesHexMethod, self.mm);
                method_func = &builtin_func.base;
            } else {
                return try self.returnAttributeError(inst, name);
            }
            const bound = try PyMethodObject.create(inst, method_func, self.mm);
            method_func.decRef(self.mm);
            return &bound.base;
        } else if (inst.type_obj == &@import("../objects/file.zig").PyFile_Type) {
            const file_mod = @import("../objects/file.zig");
            var method_func: *PyObject = undefined;
            if (std.mem.eql(u8, name, "read")) {
                const builtin_func = try PyBuiltinFunctionObject.create("read", file_mod.fileReadMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "write")) {
                const builtin_func = try PyBuiltinFunctionObject.create("write", file_mod.fileWriteMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "close")) {
                const builtin_func = try PyBuiltinFunctionObject.create("close", file_mod.fileCloseMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "readlines")) {
                const builtin_func = try PyBuiltinFunctionObject.create("readlines", file_mod.fileReadlinesMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "writelines")) {
                const builtin_func = try PyBuiltinFunctionObject.create("writelines", file_mod.fileWritelinesMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "__enter__")) {
                const builtin_func = try PyBuiltinFunctionObject.create("__enter__", file_mod.fileEnterMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "__exit__")) {
                const builtin_func = try PyBuiltinFunctionObject.create("__exit__", file_mod.fileExitMethod, self.mm);
                method_func = &builtin_func.base;
            } else {
                return try self.returnAttributeError(inst, name);
            }
            const bound = try PyMethodObject.create(inst, method_func, self.mm);
            method_func.decRef(self.mm);
            return &bound.base;
        } else if (inst.type_obj == PyTuple_Type) {
            const builtins = @import("../stdlib/builtins.zig");
            var method_func: *PyObject = undefined;
            if (std.mem.eql(u8, name, "index")) {
                const builtin_func = try PyBuiltinFunctionObject.create("index", builtins.tupleIndexMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "count")) {
                const builtin_func = try PyBuiltinFunctionObject.create("count", builtins.tupleCountMethod, self.mm);
                method_func = &builtin_func.base;
            } else {
                return try self.returnAttributeError(inst, name);
            }
            const bound = try PyMethodObject.create(inst, method_func, self.mm);
            method_func.decRef(self.mm);
            return &bound.base;
        } else if (inst.type_obj == PyInt_Type) {
            const builtins = @import("../stdlib/builtins.zig");
            var method_func: *PyObject = undefined;
            if (std.mem.eql(u8, name, "bit_length")) {
                const builtin_func = try PyBuiltinFunctionObject.create("bit_length", builtins.intBitLengthMethod, self.mm);
                method_func = &builtin_func.base;
            } else if (std.mem.eql(u8, name, "to_bytes")) {
                const builtin_func = try PyBuiltinFunctionObject.create("to_bytes", builtins.intToBytesMethod, self.mm);
                method_func = &builtin_func.base;
            } else {
                return try self.returnAttributeError(inst, name);
            }
            const bound = try PyMethodObject.create(inst, method_func, self.mm);
            method_func.decRef(self.mm);
            return &bound.base;
        } else if (inst.type_obj == PyBuiltinFunction_Type) {
            const builtin_func = inst.as(PyBuiltinFunctionObject);
            if (std.mem.eql(u8, builtin_func.name, "int") and std.mem.eql(u8, name, "from_bytes")) {
                const builtins = @import("../stdlib/builtins.zig");
                const bfunc = try PyBuiltinFunctionObject.create("int.from_bytes", builtins.intFromBytesMethod, self.mm);
                return &bfunc.base;
            }
            if (std.mem.eql(u8, builtin_func.name, "bytes") and std.mem.eql(u8, name, "fromhex")) {
                const builtins = @import("../stdlib/builtins.zig");
                const bfunc = try PyBuiltinFunctionObject.create("bytes.fromhex", builtins.bytesFromHexMethod, self.mm);
                return &bfunc.base;
            }
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TypeError: You tried to access attributes on a '{s}' object, but it has none! (It's like asking a fish to climb a tree!)", .{inst.type_obj.name}) catch "TypeError: object has no attributes";
            try self.raiseTypeError(msg);
            return error.PythonException;
        } else if (inst.type_obj == PyClass_Type) {
            const class_obj = inst.as(PyClassObject);
            if (std.mem.eql(u8, name, "__name__")) {
                class_obj.name.incRef();
                return class_obj.name;
            }
            if (try self.lookupClassAttribute(class_obj, name)) |val| {
                if (val.type_obj == PyStaticMethod_Type) {
                    const sm = val.as(@import("../objects/staticmethod.zig").PyStaticMethodObject);
                    const func = sm.func;
                    func.incRef();
                    val.decRef(self.mm);
                    return func;
                }
                if (val.type_obj == PyClassMethod_Type) {
                    const cm = val.as(@import("../objects/classmethod.zig").PyClassMethodObject);
                    const bound = try PyMethodObject.create(inst, cm.func, self.mm);
                    val.decRef(self.mm);
                    return &bound.base;
                }
                return val;
            }

            return try self.returnAttributeError(inst, name);
        } else {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TypeError: You tried to access attributes on a '{s}' object, but it has none! (It's like asking a fish to climb a tree!)", .{inst.type_obj.name}) catch "TypeError: object has no attributes";
            try self.raiseTypeError(msg);
            return error.PythonException;
        }
    }

    pub fn storeAttribute(self: *VM, inst: *PyObject, name: []const u8, val: *PyObject) anyerror!void {
        const key_str = try self.mm.internString(name);
        
        if (inst.type_obj == PyInstance_Type) {
            const instance = inst.as(PyInstanceObject);
            const dict = instance.dict.as(PyDictObject);
            try dict.setItem(key_str, val, self.mm);
        } else if (inst.type_obj == PyClass_Type) {
            const class_obj = inst.as(PyClassObject);
            const dict = class_obj.dict.as(PyDictObject);
            try dict.setItem(key_str, val, self.mm);
        } else {
            std.debug.print("TypeError: You tried to assign an attribute to a '{s}' object, but it doesn't support that! (No stick-on pockets allowed here!)\n", .{inst.type_obj.name});
            return error.TypeError;
        }
    }

    pub fn callObject(self: *VM, callable: *PyObject, args: []*PyObject, init_instance: ?*PyObject) anyerror!void {
        return self.callObjectKw(callable, args, null, init_instance);
    }

    pub fn callObjectKw(self: *VM, callable: *PyObject, args: []*PyObject, kwargs: ?*collections.PyDictObject, init_instance: ?*PyObject) anyerror!void {
        const f = &self.frames[self.frame_count - 1];
        if (callable.type_obj == PyFunction_Type) {
            const func = callable.as(PyFunctionObject);
            const code_wrapper = func.code.as(PyCodeObjectWrapper);
            const func_code = code_wrapper.code;
            
            // Compute effective defaults count (lower 16 bits of MAKE_FUNCTION arg)
            const pos_defaults_len = func.defaults.len & 0xFFFF;
            
            // Check argument count — relax upper bound if function accepts *args
            // Early lower bound check is skipped since kwargs can supply missing args; late check will catch it.
            if (func_code.vararg_name == null and args.len > func_code.argcount) {
                std.debug.print("TypeError: This function expected at most {d} arguments, but you overloaded it with {d}! (Too much info!)\n", .{func_code.argcount, args.len});
                for (args) |arg| arg.decRef(self.mm);
                return error.TypeError;
            }
            
            if (self.frame_count >= 64 and !func_code.is_generator) {
                for (args) |arg| arg.decRef(self.mm);
                return error.StackOverflow;
            }
            
            var child_frame = PyFrameObject.init(self.allocator, func_code, func.globals, false);
            child_frame.func = func;
            child_frame.init_instance = init_instance;
            func.base.incRef();
            if (init_instance) |ii| ii.incRef();
            errdefer child_frame.deinit(self.mm, self.allocator);
            
            // Fill regular positional args
            for (0..func_code.argcount) |idx| {
                if (idx < args.len) {
                    child_frame.fastlocals[idx] = args[idx];
                }
            }
            
            // Process kwargs
            if (kwargs) |kw_dict| {
                for (0..kw_dict.entries_size) |dict_idx| {
                    const entry = &kw_dict.entries[dict_idx];
                    if (entry.key == null) continue;
                    const key_obj = entry.key.?;
                    const val_obj = entry.value.?;
                    if (key_obj.type_obj != &primitives.PyString_Type) continue;
                    const kw_name = key_obj.as(primitives.PyStringObject).value();
                    
                    var found_idx: ?usize = null;
                    for (func_code.varnames, 0..) |vname, vi| {
                        if (std.mem.eql(u8, vname, kw_name)) {
                            found_idx = vi;
                            break;
                        }
                    }
                    
                    if (found_idx) |idx| {
                        if (idx < func_code.argcount) {
                            if (child_frame.fastlocals[idx] != null) {
                                std.debug.print("TypeError: got multiple values for argument '{s}'\n", .{kw_name});
                                return error.TypeError;
                            }
                            child_frame.fastlocals[idx] = val_obj;
                        }
                    } else {
                        std.debug.print("TypeError: unexpected keyword argument '{s}'\n", .{kw_name});
                        return error.TypeError;
                    }
                }
            }
            
            // Apply defaults / verify missing
            for (0..func_code.argcount) |idx| {
                if (child_frame.fastlocals[idx] == null) {
                    if (idx >= func_code.argcount - pos_defaults_len) {
                        const def_idx = idx - (func_code.argcount - pos_defaults_len);
                        const def_val = func.defaults[def_idx];
                        def_val.incRef();
                        child_frame.fastlocals[idx] = def_val;
                    } else {
                        std.debug.print("TypeError: missing required argument\n", .{});
                        return error.TypeError;
                    }
                }
            }
            
            // Pack extra positional args into *args tuple if vararg is declared
            if (func_code.vararg_name != null) {
                const vararg_idx = func_code.argcount;
                const extra_count = if (args.len > func_code.argcount) args.len - func_code.argcount else 0;
                const vararg_tuple = try collections.PyTupleObject.create(extra_count, self.mm);
                if (extra_count > 0) {
                    const tup_items = vararg_tuple.items();
                    for (0..extra_count) |i| {
                        args[func_code.argcount + i].incRef();
                        tup_items[i] = args[func_code.argcount + i];
                    }
                }
                child_frame.fastlocals[vararg_idx] = &vararg_tuple.base;
            }
            
            if (func_code.is_generator) {
                const gen_obj = try function_mod.PyGeneratorObject.create(child_frame, self.mm);
                gen_obj.frame.generator = &gen_obj.base;
                f.push(&gen_obj.base);
                return;
            }
            
            // Normal function invocation
            self.frames[self.frame_count] = child_frame;
            if (func_code.kwarg_name != null) {
                const kwarg_idx = func_code.argcount + (if (func_code.vararg_name != null) @as(usize, 1) else 0) + func_code.kwonlycount;
                const kwargs_dict = try PyDictObject.create(self.mm);
                child_frame.fastlocals[kwarg_idx] = &kwargs_dict.base;
            }
            
            self.frames[self.frame_count] = child_frame;
            self.frame_count += 1;
        } else if (callable.type_obj == PyBuiltinFunction_Type) {
            const func = callable.as(PyBuiltinFunctionObject);
            const prev_frame_count = self.frame_count;
            const res = try func.func(args, self);
            for (args) |arg| {
                arg.decRef(self.mm);
            }
            if (self.frame_count > prev_frame_count) {
                // Builtin pushed a new frame (e.g., __build_class__); don't push sentinel result
                res.decRef(self.mm);
            } else {
                f.push(res);
                if (init_instance) |inst| {
                    res.decRef(self.mm);
                    inst.incRef();
                    f.push(inst);
                }
            }
        } else if (callable.type_obj == PyMethod_Type) {
            const method = callable.as(PyMethodObject);
            var new_args = try self.allocator.alloc(*PyObject, args.len + 1);
            defer self.allocator.free(new_args);
            
            new_args[0] = method.self_obj;
            method.self_obj.incRef();
            
            for (args, 0..) |arg, idx| {
                new_args[idx + 1] = arg;
            }
            
            try self.callObjectKw(method.func, new_args, kwargs, init_instance);
        } else if (callable.type_obj == PyTypeWrapper_Type) {
            const wrapper = callable.as(@import("../stdlib/builtins.zig").PyTypeWrapper);
            if (!std.mem.eql(u8, wrapper.type_ptr.name, "object")) {
                const msg = if (args.len > 0) args[0] else try PyStringObject.create("", self.mm);
                const exc = try PyExceptionObject.create(wrapper.type_ptr, msg, self.mm);
                if (args.len == 0) {
                    msg.decRef(self.mm);
                }
                f.push(&exc.base);
                for (args) |arg| arg.decRef(self.mm);
            } else {
                std.debug.print("TypeError: built-in type '{s}' is not subclassable or directly constructible here\n", .{wrapper.type_ptr.name});
                for (args) |arg| arg.decRef(self.mm);
                return error.TypeError;
            }
        } else if (callable.type_obj == PyClass_Type) {
            const class_obj = callable.as(PyClassObject);
            const inst = try PyInstanceObject.create(class_obj, self.mm);
            
            if (try self.lookupClassAttribute(class_obj, "__init__")) |init_func| {
                defer init_func.decRef(self.mm);
                const bound_init = try PyMethodObject.create(&inst.base, init_func, self.mm);
                defer bound_init.base.decRef(self.mm);
                
                try self.callObjectKw(&bound_init.base, args, kwargs, &inst.base);
                // popFrameAndPushResult will push inst (via init_instance ownership);
                // release our local create-reference now.
                inst.base.decRef(self.mm);
            } else {
                for (args) |arg| {
                    arg.decRef(self.mm);
                }
                f.push(&inst.base);
            }
        } else if (callable.type_obj == &@import("../objects/class.zig").PyInstance_Type) {
            const inst = callable.as(@import("../objects/class.zig").PyInstanceObject);
            if (try self.lookupClassAttribute(inst.class_obj, "__call__")) |call_func| {
                defer call_func.decRef(self.mm);
                const bound_call = try PyMethodObject.create(callable, call_func, self.mm);
                defer bound_call.base.decRef(self.mm);
                try self.callObjectKw(&bound_call.base, args, kwargs, init_instance);
            } else {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "TypeError: You tried to call a '{s}' object like a function, but it doesn't have a __call__ method! (It's not that kind of phone line!)", .{callable.type_obj.name}) catch "TypeError: object is not callable";
                for (args) |arg| arg.decRef(self.mm);
                try self.raiseTypeError(msg);
            }
        } else {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TypeError: You tried to call a '{s}' object like a function! Only functions, methods, and classes can be called. (Did you put parentheses where they don't belong?)", .{callable.type_obj.name}) catch "TypeError: object is not callable";
            for (args) |arg| arg.decRef(self.mm);
            try self.raiseTypeError(msg);
        }
    }

    fn setIntersection(self: *VM, a: *PyObject, b: *PyObject) anyerror!*PyObject {
        const is_frozen = a.type_obj == PyFrozenSet_Type;
        const res = if (is_frozen) try collections.PySetObject.createFrozen(self.mm) else try collections.PySetObject.create(self.mm);
        errdefer res.base.decRef(self.mm);
        const set_a = a.as(collections.PySetObject);
        const set_b = b.as(collections.PySetObject);
        for (0..set_a.entries_size) |i| {
            if (set_a.entries[i].key) |key| {
                if (try set_b.contains(key, self.mm)) {
                    try res.add(key, self.mm);
                }
            }
        }
        return &res.base;
    }

    fn setUnion(self: *VM, a: *PyObject, b: *PyObject) anyerror!*PyObject {
        const is_frozen = a.type_obj == PyFrozenSet_Type;
        const res = if (is_frozen) try collections.PySetObject.createFrozen(self.mm) else try collections.PySetObject.create(self.mm);
        errdefer res.base.decRef(self.mm);
        const set_a = a.as(collections.PySetObject);
        const set_b = b.as(collections.PySetObject);
        for (0..set_a.entries_size) |i| {
            if (set_a.entries[i].key) |key| {
                try res.add(key, self.mm);
            }
        }
        for (0..set_b.entries_size) |i| {
            if (set_b.entries[i].key) |key| {
                try res.add(key, self.mm);
            }
        }
        return &res.base;
    }

    fn setXor(self: *VM, a: *PyObject, b: *PyObject) anyerror!*PyObject {
        const is_frozen = a.type_obj == PyFrozenSet_Type;
        const res = if (is_frozen) try collections.PySetObject.createFrozen(self.mm) else try collections.PySetObject.create(self.mm);
        errdefer res.base.decRef(self.mm);
        const set_a = a.as(collections.PySetObject);
        const set_b = b.as(collections.PySetObject);
        for (0..set_a.entries_size) |i| {
            if (set_a.entries[i].key) |key| {
                if (!(try set_b.contains(key, self.mm))) {
                    try res.add(key, self.mm);
                }
            }
        }
        for (0..set_b.entries_size) |i| {
            if (set_b.entries[i].key) |key| {
                if (!(try set_a.contains(key, self.mm))) {
                    try res.add(key, self.mm);
                }
            }
        }
        return &res.base;
    }

    fn setDifference(self: *VM, a: *PyObject, b: *PyObject) anyerror!*PyObject {
        const is_frozen = a.type_obj == PyFrozenSet_Type;
        const res = if (is_frozen) try collections.PySetObject.createFrozen(self.mm) else try collections.PySetObject.create(self.mm);
        errdefer res.base.decRef(self.mm);
        const set_a = a.as(collections.PySetObject);
        const set_b = b.as(collections.PySetObject);
        for (0..set_a.entries_size) |i| {
            if (set_a.entries[i].key) |key| {
                if (!(try set_b.contains(key, self.mm))) {
                    try res.add(key, self.mm);
                }
            }
        }
        return &res.base;
    }

    fn raiseException(self: *VM, exc: *PyObject) anyerror!void {
        exc.incRef();
        
        if (self.suppress_exception_handling) {
            self.suppress_exception_handling = false;
            const f = &self.frames[self.frame_count - 1];
            f.deinit(self.mm, self.allocator);
            self.frame_count -= 1;
            exc.decRef(self.mm);
            return error.PythonException;
        }
        
        while (self.frame_count > 0) {
            const f = &self.frames[self.frame_count - 1];
            if (f.block_stack_top > 0) {
                f.block_stack_top -= 1;
                const block = f.block_stack[f.block_stack_top];
                
                if (block.type == .With) {
                    defer block.exit_func.?.decRef(self.mm);
                    
                    while (f.stack_top > block.stack_level) {
                        f.stack_top -= 1;
                        f.stack[f.stack_top].decRef(self.mm);
                    }
                    
                    const exc_type = if (exc.type_obj == PyInstance_Type) b: {
                        const inst = exc.as(class_mod.PyInstanceObject);
                        inst.class_obj.base.incRef();
                        break :b &inst.class_obj.base;
                    } else b: {
                        const wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(exc.type_obj, self.mm);
                        break :b &wrapper.base;
                    };
                    defer exc_type.decRef(self.mm);
                    
                    exc.incRef();
                    PyNone.incRef();
                    exc_type.incRef();
                    var args = [_]*PyObject{ exc_type, exc, PyNone };
                    
                    var nesting: usize = 0;
                    var scan_ip = f.ip;
                    var exit_ip: ?usize = null;
                    while (scan_ip < f.code.instructions.len) : (scan_ip += 1) {
                        const op = f.code.instructions[scan_ip].op;
                        if (op == .BEFORE_WITH) {
                            nesting += 1;
                        } else if (op == .EXIT_WITH) {
                            if (nesting == 0) {
                                exit_ip = scan_ip;
                                break;
                            } else {
                                nesting -= 1;
                            }
                        }
                    }
                    
                    const prev_frame_count = self.frame_count;
                    try self.callObject(block.exit_func.?, &args, null);
                    
                    if (self.frame_count > prev_frame_count) {
                        try self.runLoop(prev_frame_count);
                    }
                    
                    // __exit__ return value is in last_result (child frame returns into last_result)
                    const exit_res = self.last_result orelse PyNone;
                    exit_res.incRef();
                    defer exit_res.decRef(self.mm);
                    
                    var is_true = false;
                    if (exit_res.type_obj == PyBool_Type) {
                        is_true = exit_res == PyTrue;
                    } else if (exit_res.type_obj.tp_bool) |bool_fn| {
                        is_true = bool_fn(exit_res);
                    }
                    
                    if (is_true) {
                        f.ip = exit_ip.? + 1;
                        PyNone.incRef();
                        f.push(PyNone);
                        return;
                    }
                    // Not suppressed: re-raise, continue searching for a handler
                    continue;
                } else {
                    while (f.stack_top > block.stack_level) {
                        f.stack_top -= 1;
                        f.stack[f.stack_top].decRef(self.mm);
                    }
                    
                    if (f.active_exception) |ae| ae.decRef(self.mm);
                    f.active_exception = exc;
                    
                    f.ip = block.handler;
                    exc.incRef();
                    f.push(exc);
                    return;
                }
            }
            
            f.deinit(self.mm, self.allocator);
            self.frame_count -= 1;
        }
        
        const repr_val = try exc.type_obj.tp_repr.?(exc, self.mm);
        defer repr_val.decRef(self.mm);
        try self.stdout_writer.print("{s}\n", .{repr_val.as(PyStringObject).value()});
        if (self.diagnostic_mode != .none) {
            try self.printDiagnostics(exc);
        }
        exc.decRef(self.mm);
        return error.PythonException;
    }

    fn printDiagnostics(self: *VM, exc: *PyObject) !void {
        const type_name = exc.type_obj.name;
        const exc_obj = exc.as(exception_mod.PyExceptionObject);
        const clean_msg = exc_obj.message.as(PyStringObject).value();

        if (self.diagnostic_mode == .hinglish) {
            try self.stdout_writer.print("\n--- BharatPython Enhanced Diagnostics ---\n", .{});
            
            var hinglish_msg: []const u8 = "Kuch aisi galti hui hai jiska exact reason nahi pata. (An unknown error occurred).";
            var english_msg: []const u8 = "An unknown error occurred.";
            var suggestion_msg: []const u8 = "";
            
            if (std.mem.eql(u8, type_name, "NameError")) {
                hinglish_msg = "Bhai, yeh variable ya function kahan se laya? Pehle isko define toh kar le, ya phir typo check kar!";
                english_msg = "Bro, where did this variable or function come from? Define it first, or check for typos!";
                suggestion_msg = "Define the variable before using it, or fix the spelling.";
            } else if (std.mem.eql(u8, type_name, "SyntaxError")) {
                hinglish_msg = "Arre yaar! Code likhne mein syntax ki galti kar di. Shayad koi bracket ')' ya colon ':' lagana bhool gaye.";
                english_msg = "Oops! You made a grammatical error in your code. Maybe you forgot a bracket ')' or a colon ':'.";
                suggestion_msg = "Check for missing parentheses, colons, or quotes.";
            } else if (std.mem.eql(u8, type_name, "TypeError")) {
                hinglish_msg = "Bhai, oil aur pani mix nahi hote! Tum alag-alag data types (jaise string aur int) ko ek sath jod rahe ho.";
                english_msg = "Bro, oil and water don't mix! You are trying to combine incompatible data types (like string and int).";
                suggestion_msg = "Convert variables to the correct type (e.g., using str() or int()) before operating on them.";
            } else if (std.mem.eql(u8, type_name, "ValueError")) {
                hinglish_msg = "Data type toh theek hai, par value mein ghapla hai! Jaise 'abc' ko integer banane ki koshish.";
                english_msg = "Data type is correct, but the value is fishy! Like trying to turn 'abc' into an integer.";
                suggestion_msg = "Ensure the value you are passing is valid for the operation.";
            } else if (std.mem.eql(u8, type_name, "ImportError")) {
                hinglish_msg = "Jo module tum import karna chahte ho uske andar yeh function nahi mila. Sahi function ka naam daalo.";
                english_msg = "The module you are importing from doesn't have this function. Check the function name.";
                suggestion_msg = "Verify the function name inside the module you are importing from.";
            } else if (std.mem.eql(u8, type_name, "ModuleNotFoundError")) {
                hinglish_msg = "Lagta hai yeh package tumhare computer mein hai hi nahi! Pehle 'pip install' kar lo bhai.";
                english_msg = "Looks like this package doesn't exist on your computer! Do a 'pip install' first bro.";
                suggestion_msg = "Run 'pip install <package_name>' in your terminal.";
            } else if (std.mem.eql(u8, type_name, "KeyError")) {
                hinglish_msg = "Dictionary mein yeh chabi (key) mila hi nahi! Dusre dictionary mein toh nahi dhund rahe?";
                english_msg = "This key was not found in the dictionary! Are you looking in the wrong dictionary?";
                suggestion_msg = "Check if the key exists using 'key in dict' or use 'dict.get(key)'.";
            } else if (std.mem.eql(u8, type_name, "IndexError")) {
                hinglish_msg = "List ke aukaat ke bahar ja rahe ho! Jitne items hain list mein, usse bada index daal diya.";
                english_msg = "You're going out of the list's bounds! You provided an index larger than the list size.";
                suggestion_msg = "Remember that lists start at index 0. Make sure your index is less than len(list).";
            } else if (std.mem.eql(u8, type_name, "RuntimeError")) {
                hinglish_msg = "Code chalte-chalte raaste mein accident ho gaya! Kuch unexpected hua hai.";
                english_msg = "The code had an accident while running! Something unexpected happened.";
                suggestion_msg = "Check the exact error message and your logic.";
            } else if (std.mem.eql(u8, type_name, "AttributeError")) {
                hinglish_msg = "Is object ke paas yeh superpower (attribute/method) nahi hai jo tum use karna chahte ho.";
                english_msg = "This object doesn't have the superpower (attribute/method) you are trying to use.";
                suggestion_msg = "Check the object's type and see if you misspelled the method name.";
            } else if (std.mem.eql(u8, type_name, "FileNotFoundError")) {
                hinglish_msg = "File ghayab hai boss! Ya toh file wahan hai hi nahi, ya path galat diya hai.";
                english_msg = "The file is missing boss! Either the file doesn't exist there, or the path is wrong.";
                suggestion_msg = "Check the file path and make sure the file exists.";
            } else if (std.mem.eql(u8, type_name, "ZeroDivisionError")) {
                hinglish_msg = "Maths ke niyam tod rahe ho! Kisi bhi number ko zero se divide karna paap hai.";
                english_msg = "You're breaking the rules of Math! Dividing any number by zero is a sin.";
                suggestion_msg = "Ensure the denominator is not zero before dividing.";
            } else if (std.mem.eql(u8, type_name, "MemoryError")) {
                hinglish_msg = "RAM full ho gayi hai bhai! Bahut zyada data ek sath load karne ki koshish mat karo.";
                english_msg = "Your RAM is full bro! Don't try to load too much data all at once.";
                suggestion_msg = "Process data in smaller chunks or optimize your memory usage.";
            } else if (std.mem.eql(u8, type_name, "RecursionError")) {
                hinglish_msg = "Tumhara function khud ko itni baar bula raha hai ki Python thak gaya (Infinite loop alert!).";
                english_msg = "Your function is calling itself so many times that Python got tired (Infinite loop alert!).";
                suggestion_msg = "Add a proper base case to your recursive function to make it stop.";
            } else if (std.mem.eql(u8, type_name, "IndentationError")) {
                hinglish_msg = "Arre yaar! Code ke blocks mein spacing (indentation) ka lafda hai. Tabs aur spaces check karo, ya sahi spaces daalo.";
                english_msg = "Oops! There is a spacing (indentation) issue in your code blocks. Check tabs and spaces, or ensure consistent spacing.";
                suggestion_msg = "Ensure all lines in the same block have the same amount of indentation (usually 4 spaces).";
            } else if (std.mem.eql(u8, type_name, "AssertionError")) {
                hinglish_msg = "Bhai, jo check (assert) tumne lagaya tha, woh fail ho gaya. Conditions match nahi kar rahi hain.";
                english_msg = "Bro, the check (assertion) you set up has failed. The condition did not evaluate to True.";
                suggestion_msg = "Double check the value being asserted and verify your assumptions.";
            } else if (std.mem.eql(u8, type_name, "UnboundLocalError")) {
                hinglish_msg = "Bhai, local variable ko pehle value dene se pehle hi use kar rahe ho. global ya nonlocal keyword use karo agar zaroorat ho.";
                english_msg = "Bro, you are referencing a local variable before assigning a value to it. Use global or nonlocal if needed.";
                suggestion_msg = "Assign a value to the variable in the local scope, or declare it global/nonlocal.";
            } else if (std.mem.eql(u8, type_name, "PermissionError")) {
                hinglish_msg = "Access denied boss! Is file ya folder ko padhne ya likhne ki permission nahi hai tumhare paas.";
                english_msg = "Access denied boss! You don't have permission to read or write this file or folder.";
                suggestion_msg = "Check the file permissions or run the script with administrator/superuser privileges.";
            }
            
            try self.stdout_writer.print("Explanation: {s}\n", .{hinglish_msg});
            try self.stdout_writer.print("English: {s}\n", .{english_msg});
            if (suggestion_msg.len > 0) {
                try self.stdout_writer.print("Suggestion: {s}\n", .{suggestion_msg});
            }
        } else if (self.diagnostic_mode == .jugaad) {
            var title: []const u8 = "💥 Gadbad Ho Gayi";
            var body: []const u8 = clean_msg;
            
            if (std.mem.eql(u8, type_name, "SyntaxError")) {
                title = "🤦 Bhai kya likh diya?";
                body = "Keyboard strike par hai kya? Code check karo.";
            } else if (std.mem.eql(u8, type_name, "NameError")) {
                title = "🕵️ Variable dhundte dhundte thak gaya.";
                body = "Possible reasons:\n  • Typo kiya hai\n  • Variable declare karna bhool gaye\n  • Universe collapse ho gaya";
            } else if (std.mem.eql(u8, type_name, "ZeroDivisionError")) {
                title = "💀 Zero se divide?";
                body = "Newton bhi confuse ho gaya. Maths seekh lo thoda.";
            } else if (std.mem.eql(u8, type_name, "TypeError")) {
                title = "🤔 Type mismatch ho gaya.";
                body = "Galat data-type use kiya hai. Computation shock me chala gaya.";
            } else if (std.mem.eql(u8, type_name, "IndexError")) {
                title = "📭 List mein itna nahi hai!";
                body = "List ke bahar chala gaya! Itna bada index kahan se mila?";
            } else if (std.mem.eql(u8, type_name, "KeyError")) {
                title = "🔑 Key gayab hai!";
                body = "Dictionary mein ye key to hai hi nahi. Dhyan se check karo.";
            } else if (std.mem.eql(u8, type_name, "AttributeError")) {
                title = "🚫 Attribute mila hi nahi.";
                body = "Object me ye feature/method nahi hai boss.";
            } else if (std.mem.eql(u8, type_name, "ModuleNotFoundError")) {
                title = "📦 Module missing!";
                body = "Dhundne se bhi nahi mila. Install kiya hai kya? (jug install check karo)";
            } else if (std.mem.eql(u8, type_name, "ValueError")) {
                title = "🎭 Value galat hai boss!";
                body = "Function ko sahi value do na. Ye kya bhej diya?";
            } else if (std.mem.eql(u8, type_name, "ImportError")) {
                title = "📥 Import gadbad ho gaya.";
                body = "Kuch laane mein problem hai. Module ka naam check karo.";
            } else if (std.mem.eql(u8, type_name, "FileNotFoundError")) {
                title = "📁 File mili hi nahi!";
                body = "Jagah sahi hai? File gayab ho gayi? Check karo path.";
            } else if (std.mem.eql(u8, type_name, "PermissionError")) {
                title = "🚫 Ijjazat nahi hai!";
                body = "Permission nahi mili. Root bano ya sudo lagao.";
            } else if (std.mem.eql(u8, type_name, "TimeoutError")) {
                title = "⏰ Time khatam ho gaya!";
                body = "Kaafi wait kar liya. Kuch gadbad hai operation mein.";
            } else if (std.mem.eql(u8, type_name, "ConnectionError")) {
                title = "🔌 Connection nahi ho raha!";
                body = "Internet band hai ya server so gaya. Dobara try karo.";
            } else if (std.mem.eql(u8, type_name, "RecursionError")) {
                title = "🔄 Loop mein phans gaye!";
                body = "Recursion itni deep aa gayi ki stack ka dhakkan khul gaya. Base case daalo.";
            } else if (std.mem.eql(u8, type_name, "StopIteration")) {
                title = "🏁 Iterator khatam ho gaya.";
                body = "Aur kuch nahi bacha. Next call mat karo ab.";
            } else if (std.mem.eql(u8, type_name, "MemoryError")) {
                title = "🧠 Yaad kam pad gayi.";
                body = "RAM ka saath nahi de rahi. Kuch band karo ya RAM badhao.";
            } else if (std.mem.eql(u8, type_name, "OverflowError")) {
                title = "📈 Hadd se zyada ho gaya!";
                body = "Number itna bada ki calculator bhi haar gaya.";
            } else if (std.mem.eql(u8, type_name, "FloatingPointError")) {
                title = "🎯 Point mein gadbad.";
                body = "Floating point ki precision ne dhoka de diya. Round karke dekho.";
            } else if (std.mem.eql(u8, type_name, "EOFError")) {
                title = "📄 File achanak khatam!";
                body = "Padhte padhte end aa gaya. Aur kuch data nahi hai.";
            } else if (std.mem.eql(u8, type_name, "UnicodeError")) {
                title = "🔤 Unicode samajh nahi aaya.";
                body = "Characters encoding ki problem. UTF-8 try karo.";
            } else if (std.mem.eql(u8, type_name, "KeyboardInterrupt")) {
                title = "⌨️ Ctrl+C! Kaunsi shakti hai ye?";
                body = "Achha choro, aadha kaam theek hai. Agli baar file se chalao.";
            } else if (std.mem.eql(u8, type_name, "AssertionError")) {
                title = "🎯 Assert ka pakka fail!";
                body = "Na maanne wali baat galat nikli. Dhyan se check karo.";
            } else if (std.mem.eql(u8, type_name, "NotImplementedError")) {
                title = "🏗️ Abhi baki hai!";
                body = "Ye feature abhi implement nahi hua. Khud likhdo.";
            }
            
            try self.stdout_writer.print("{s}\n", .{title});
            try self.stdout_writer.print("\nKya gadbad hai?\n  {s}\n", .{body});
            try self.stdout_writer.print("\nOriginal System Error: {s}: {s}\n", .{type_name, clean_msg});
        }
        exc.decRef(self.mm);
        return error.PythonException;
    }

    pub fn run(self: *VM, code: *PyCodeObject, opt_globals: ?*std.StringHashMap(*PyObject)) anyerror!*PyObject {
        self.last_result = null;
        if (self.frame_count >= 64) return error.StackOverflow;
        
        const starting_frame_count = self.frame_count;
        const globals_ptr = opt_globals orelse &self.globals;
        self.frames[self.frame_count] = PyFrameObject.init(self.allocator, code, globals_ptr, true);
        self.frame_count += 1;

        var current_starting_frame = starting_frame_count;
        while (true) {
            self.runLoop(current_starting_frame) catch |err| {
                if (err == error.PythonException) {
                    return error.PythonException;
                }
                try self.raiseZigError(err);
                if (self.frame_count > starting_frame_count) {
                    current_starting_frame = self.frame_count - 1;
                    continue;
                }
                return error.PythonException;
            };
            break;
        }
        return self.last_result.?;
    }

    pub fn runLoop(self: *VM, starting_frame_count: usize) anyerror!void {
        const push = StackHelper.push;
        const pop = StackHelper.pop;

        var frame_idx = self.frame_count - 1;
        var f = &self.frames[frame_idx];
        var ip = f.ip;
        var stack_top = f.stack_top;
        var instructions = f.code.instructions;
        var consts = f.code.consts;
        var names = f.code.names;
        var varnames = f.code.varnames;
        var fastlocals = f.fastlocals;
        var globals = f.globals;
        var locals = &f.locals;
        var is_module = f.is_module;
        var is_class_body = f.is_class_body;
        var func = f.func;

        defer {
            if (frame_idx < self.frame_count) {
                self.frames[frame_idx].ip = ip;
                self.frames[frame_idx].stack_top = stack_top;
            }
        }

        while (self.frame_count > starting_frame_count) {
            if (self.frame_count - 1 != frame_idx) {
                if (frame_idx < self.frame_count) {
                    self.frames[frame_idx].ip = ip;
                    self.frames[frame_idx].stack_top = stack_top;
                }
                frame_idx = self.frame_count - 1;
                f = &self.frames[frame_idx];
                ip = f.ip;
                stack_top = f.stack_top;
                instructions = f.code.instructions;
                consts = f.code.consts;
                names = f.code.names;
                varnames = f.code.varnames;
                fastlocals = f.fastlocals;
                globals = f.globals;
                locals = &f.locals;
                is_module = f.is_module;
                is_class_body = f.is_class_body;
                func = f.func;
            }

            if (ip >= instructions.len) {
                // Implicit return None
                f.ip = ip;
                f.stack_top = stack_top;
                PyNone.incRef();
                self.popFrameAndPushResult(PyNone, starting_frame_count);
                if (self.frame_count == 0) return;
                frame_idx = self.frame_count - 1;
                f = &self.frames[frame_idx];
                ip = f.ip;
                stack_top = f.stack_top;
                instructions = f.code.instructions;
                consts = f.code.consts;
                names = f.code.names;
                varnames = f.code.varnames;
                fastlocals = f.fastlocals;
                globals = f.globals;
                locals = &f.locals;
                is_module = f.is_module;
                is_class_body = f.is_class_body;
                func = f.func;
                continue;
            }

            const instr = instructions[ip];
            ip += 1;

            switch (instr.op) {
                .LOAD_CONST => {
                    const obj = consts[instr.arg];
                    obj.incRef();
                    push(f, &stack_top, obj);
                },
                .STORE_NAME => {
                    const obj = pop(f, &stack_top);
                    const name = names[instr.arg];
                    const map = if (is_class_body) locals else globals;
                    const g = try map.getOrPut(name);
                    if (g.found_existing) {
                        g.value_ptr.*.decRef(self.mm);
                    } else {
                        g.key_ptr.* = try self.allocator.dupe(u8, name);
                    }
                    g.value_ptr.* = obj;
                },
                .LOAD_NAME => {
                    const name = names[instr.arg];
                    var found_obj: ?*PyObject = null;
                    if (!is_module) {
                        found_obj = locals.get(name);
                    }
                    if (found_obj == null) {
                        found_obj = globals.get(name);
                    }
                    if (found_obj == null and globals != &self.globals) {
                        found_obj = self.globals.get(name);
                    }
                    
                    if (found_obj) |obj| {
                        obj.incRef();
                        push(f, &stack_top, obj);
                    } else {
                        f.ip = ip;
                        f.stack_top = stack_top;
                        
                        var buf: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "NameError: I looked everywhere, but I couldn't find '{s}'. Did you forget to define it or spell it wrong? (Maybe it's hiding behind the couch?)", .{name}) catch "NameError: undefined name";
                        try self.raiseNameError(msg);
                        
                        frame_idx = self.frame_count - 1;
                        f = &self.frames[frame_idx];
                        ip = f.ip;
                        stack_top = f.stack_top;
                        instructions = f.code.instructions;
                        consts = f.code.consts;
                        names = f.code.names;
                        varnames = f.code.varnames;
                        fastlocals = f.fastlocals;
                        globals = f.globals;
                        locals = &f.locals;
                        is_module = f.is_module;
                        is_class_body = f.is_class_body;
                        func = f.func;
                    }
                },
                .BINARY_ADD => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(val_a + val_b, self.mm);
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else if (a.type_obj == &@import("../objects/class.zig").PyInstance_Type) {
                        const instance = a.as(@import("../objects/class.zig").PyInstanceObject);
                        if (try self.lookupClassAttribute(instance.class_obj, "__add__")) |add_func| {
                            defer add_func.decRef(self.mm);
                            const bound = try PyMethodObject.create(&instance.base, add_func, self.mm);
                            defer bound.base.decRef(self.mm);
                            var call_args = [_]*PyObject{b};
                            const res = try self.callCallable(&bound.base, &call_args);
                            a.decRef(self.mm);
                            b.decRef(self.mm);
                            push(f, &stack_top, res);
                        } else {
                            defer a.decRef(self.mm);
                            defer b.decRef(self.mm);
                            return error.TypeError;
                        }
                    } else {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        if (a.type_obj.tp_add) |add_fn| {
                            const res = try add_fn(a, b, self.mm);
                            push(f, &stack_top, res);
                        } else {
                            return error.TypeError;
                        }
                    }
                },
                .BINARY_SUB => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(val_a - val_b, self.mm);
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else if ((a.type_obj == PySet_Type or a.type_obj == PyFrozenSet_Type) and
                               (b.type_obj == PySet_Type or b.type_obj == PyFrozenSet_Type)) {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        const res = try self.setDifference(a, b);
                        push(f, &stack_top, res);
                    } else {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        if (a.type_obj.tp_sub) |sub_fn| {
                            const res = try sub_fn(a, b, self.mm);
                            push(f, &stack_top, res);
                        } else {
                            return error.TypeError;
                        }
                    }
                },
                .BINARY_MUL => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(val_a * val_b, self.mm);
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        if (a.type_obj.tp_mul) |mul_fn| {
                            const res = try mul_fn(a, b, self.mm);
                            push(f, &stack_top, res);
                        } else {
                            return error.TypeError;
                        }
                    }
                },
                .BINARY_DIV => {
                    const b = pop(f, &stack_top);
                    defer b.decRef(self.mm);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);

                    if (a.type_obj.tp_truediv) |div_fn| {
                        const res = try div_fn(a, b, self.mm);
                        push(f, &stack_top, res);
                    } else {
                        return error.TypeError;
                    }
                },
                .COMPARE_OP => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const op: CompareOp = @enumFromInt(instr.arg);
                        const match = switch (op) {
                            .Lt => val_a < val_b,
                            .Le => val_a <= val_b,
                            .Eq => val_a == val_b,
                            .Ne => val_a != val_b,
                            .Gt => val_a > val_b,
                            .Ge => val_a >= val_b,
                        };
                        const res = if (match) PyTrue else PyFalse;
                        res.incRef();
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else {
                        const op: CompareOp = @enumFromInt(instr.arg);
                        var res: ?*PyObject = null;
                        
                        if (a.type_obj == &@import("../objects/class.zig").PyInstance_Type) {
                            const instance = a.as(@import("../objects/class.zig").PyInstanceObject);
                            const dunder_name = switch (op) {
                                .Lt => "__lt__",
                                .Le => "__le__",
                                .Eq => "__eq__",
                                .Ne => "__ne__",
                                .Gt => "__gt__",
                                .Ge => "__ge__",
                            };
                            if (try self.lookupClassAttribute(instance.class_obj, dunder_name)) |cmp_func| {
                                defer cmp_func.decRef(self.mm);
                                const bound = try PyMethodObject.create(&instance.base, cmp_func, self.mm);
                                defer bound.base.decRef(self.mm);
                                var call_args = [_]*PyObject{b};
                                res = try self.callCallable(&bound.base, &call_args);
                            }
                        } else if (a.type_obj.tp_richcompare) |cmp_fn| {
                            res = try cmp_fn(a, b, op, self.mm);
                        }
                        
                        if (res == null) {
                            if (b.type_obj == &@import("../objects/class.zig").PyInstance_Type) {
                                const instance = b.as(@import("../objects/class.zig").PyInstanceObject);
                                const dunder_name = switch (op) {
                                    .Lt => "__gt__",
                                    .Le => "__ge__",
                                    .Eq => "__eq__",
                                    .Ne => "__ne__",
                                    .Gt => "__lt__",
                                    .Ge => "__le__",
                                };
                                if (try self.lookupClassAttribute(instance.class_obj, dunder_name)) |cmp_func| {
                                    defer cmp_func.decRef(self.mm);
                                    const bound = try PyMethodObject.create(&instance.base, cmp_func, self.mm);
                                    defer bound.base.decRef(self.mm);
                                    var call_args = [_]*PyObject{a};
                                    res = try self.callCallable(&bound.base, &call_args);
                                }
                            } else if (b.type_obj.tp_richcompare) |cmp_fn| {
                                res = try cmp_fn(b, a, swapOp(op), self.mm);
                            }
                        }
                        
                        if (res) |r| {
                            a.decRef(self.mm);
                            b.decRef(self.mm);
                            push(f, &stack_top, r);
                        } else {
                            defer a.decRef(self.mm);
                            defer b.decRef(self.mm);
                            if (op == .Eq or op == .Ne) {
                                var is_same = (a == b);
                                if (!is_same and a.type_obj == PyTypeWrapper_Type and b.type_obj == PyTypeWrapper_Type) {
                                    const wrapper_a = a.as(@import("../stdlib/builtins.zig").PyTypeWrapper);
                                    const wrapper_b = b.as(@import("../stdlib/builtins.zig").PyTypeWrapper);
                                    is_same = (wrapper_a.type_ptr == wrapper_b.type_ptr);
                                }
                                const match = if (op == .Eq) is_same else !is_same;
                                const default_res = if (match) PyTrue else PyFalse;
                                default_res.incRef();
                                push(f, &stack_top, default_res);
                            } else {
                                return error.TypeError;
                            }
                        }
                    }
                },
                .PRINT_EXPR => {
                    const obj = pop(f, &stack_top);
                    defer obj.decRef(self.mm);

                    var str_obj: *PyObject = undefined;
                    if (obj.type_obj.tp_str) |str_fn| {
                        str_obj = try str_fn(obj, self.mm);
                    } else if (obj.type_obj.tp_repr) |repr_fn| {
                        str_obj = try repr_fn(obj, self.mm);
                    } else {
                        str_obj = try PyStringObject.create(obj.type_obj.name, self.mm);
                    }
                    defer str_obj.decRef(self.mm);

                    try self.stdout_writer.print("{s}\n", .{str_obj.as(PyStringObject).value()});
                },
                .RETURN_VALUE => {
                    const res = pop(f, &stack_top);
                    f.ip = ip;
                    f.stack_top = stack_top;
                    self.popFrameAndPushResult(res, starting_frame_count);
                    if (self.frame_count == 0) return;
                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },
                .JUMP_FORWARD => {
                    ip = instr.arg;
                },
                .JUMP_BACKWARD => {
                    ip = instr.arg;
                },
                .POP_JUMP_IF_FALSE => {
                    const cond_val = pop(f, &stack_top);
                    defer cond_val.decRef(self.mm);
                    if (!(try self.isTrueObj(cond_val))) {
                        ip = instr.arg;
                    }
                },
                .POP_JUMP_IF_TRUE => {
                    const cond_val = pop(f, &stack_top);
                    defer cond_val.decRef(self.mm);
                    if (try self.isTrueObj(cond_val)) {
                        ip = instr.arg;
                    }
                },
                .UNARY_NOT => {
                    const val = pop(f, &stack_top);
                    defer val.decRef(self.mm);
                    const res = if (try self.isTrueObj(val)) PyFalse else PyTrue;
                    res.incRef();
                    push(f, &stack_top, res);
                },
                .JUMP_IF_FALSE_OR_POP => {
                    const cond = f.stack[stack_top - 1];
                    if (!(try self.isTrueObj(cond))) {
                        ip = instr.arg;
                    } else {
                        _ = pop(f, &stack_top);
                        cond.decRef(self.mm);
                    }
                },
                .JUMP_IF_TRUE_OR_POP => {
                    const cond = f.stack[stack_top - 1];
                    if (try self.isTrueObj(cond)) {
                        ip = instr.arg;
                    } else {
                        _ = pop(f, &stack_top);
                        cond.decRef(self.mm);
                    }
                },
                .BUILD_LIST => {
                    const count = instr.arg;
                    const list = try PyListObject.create(count, self.mm);
                    if (count > 0) {
                        var i: usize = 0;
                        while (i < count) : (i += 1) {
                            list.items.?[count - 1 - i] = pop(f, &stack_top);
                        }
                        list.size = count;
                    }
                    push(f, &stack_top, &list.base);
                },
                .BUILD_TUPLE => {
                    const count = instr.arg;
                    const tuple = try PyTupleObject.create(count, self.mm);
                    const slice = tuple.items();
                    if (count > 0) {
                        var i: usize = 0;
                        while (i < count) : (i += 1) {
                            PyNone.decRef(self.mm);
                            slice[count - 1 - i] = pop(f, &stack_top);
                        }
                    }
                    push(f, &stack_top, &tuple.base);
                },
                .BUILD_MAP => {
                    const count = instr.arg;
                    const dict = try PyDictObject.create(self.mm);
                    errdefer dict.base.decRef(self.mm);
                    
                    var keys = try self.allocator.alloc(*PyObject, count);
                    defer self.allocator.free(keys);
                    var values = try self.allocator.alloc(*PyObject, count);
                    defer self.allocator.free(values);
                    
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        values[count - 1 - i] = pop(f, &stack_top);
                        keys[count - 1 - i] = pop(f, &stack_top);
                    }
                    
                    for (0..count) |idx| {
                        try dict.setItem(keys[idx], values[idx], self.mm);
                        keys[idx].decRef(self.mm);
                        values[idx].decRef(self.mm);
                    }
                    push(f, &stack_top, &dict.base);
                },
                .BUILD_SET => {
                    const count = instr.arg;
                    const set_obj = try collections.PySetObject.create(self.mm);
                    errdefer set_obj.base.decRef(self.mm);
                    
                    if (count > 0) {
                        var keys = try self.allocator.alloc(*PyObject, count);
                        defer self.allocator.free(keys);
                        
                        var i: usize = 0;
                        while (i < count) : (i += 1) {
                            keys[count - 1 - i] = pop(f, &stack_top);
                        }
                        for (keys) |key| {
                            try set_obj.add(key, self.mm);
                            key.decRef(self.mm);
                        }
                    }
                    push(f, &stack_top, &set_obj.base);
                },
                .BUILD_SLICE => {
                    const step = pop(f, &stack_top);
                    const stop = pop(f, &stack_top);
                    const start = pop(f, &stack_top);
                    defer step.decRef(self.mm);
                    defer stop.decRef(self.mm);
                    defer start.decRef(self.mm);
                    const start_val = if (start == PyNone) null else start;
                    const stop_val = if (stop == PyNone) null else stop;
                    const step_val = if (step == PyNone) null else step;
                    const slice_obj = try PySliceObject.create(start_val, stop_val, step_val, self.mm);
                    push(f, &stack_top, &slice_obj.base);
                },
                .MAKE_FUNCTION => {
                    const code_obj = pop(f, &stack_top);
                    defer code_obj.decRef(self.mm);
                    
                    const num_defaults = instr.arg;
                    var defaults = try self.allocator.alloc(*PyObject, num_defaults);
                    defer self.allocator.free(defaults);
                    var def_i: usize = num_defaults;
                    while (def_i > 0) {
                        def_i -= 1;
                        defaults[def_i] = pop(f, &stack_top);
                    }
                    
                    defer {
                        for (defaults) |d| {
                            d.decRef(self.mm);
                        }
                    }
                    
                    const func_obj = try PyFunctionObject.create(code_obj, globals, defaults, self.mm);
                    errdefer func_obj.base.decRef(self.mm);
                    
                    const code_wrapper = code_obj.as(PyCodeObjectWrapper);
                    const func_code = code_wrapper.code;
                    
                    try self.scanForFreeVars(func_code, func_obj, f);
                    
                    push(f, &stack_top, &func_obj.base);
                },
                .CALL => {
                    const argc = instr.arg;
                    var args = try self.allocator.alloc(*PyObject, argc);
                    defer self.allocator.free(args);
                    var i: usize = 0;
                    while (i < argc) : (i += 1) {
                        stack_top -= 1;
                        args[argc - 1 - i] = f.stack[stack_top];
                    }
                    stack_top -= 1;
                    const callable = f.stack[stack_top];
                    defer callable.decRef(self.mm);
                    
                    f.ip = ip;
                    f.stack_top = stack_top;
                    
                    if (self.callObject(callable, args, null)) {
                        // success — fall through to frame refresh
                    } else |err| {
                        if (err == error.StopIteration) {
                            const msg = try primitives.PyStringObject.create("", self.mm);
                            const exc = try exception_mod.PyExceptionObject.create(
                                &exception_mod.PyStopIteration_Type, msg, self.mm
                            );
                            try self.raiseException(&exc.base);
                            exc.base.decRef(self.mm);
                            msg.decRef(self.mm);
                        } else {
                            return err;
                        }
                    }
                    
                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },
                .LOAD_ATTR => {
                    const inst = pop(f, &stack_top);
                    defer inst.decRef(self.mm);
                    const name = names[instr.arg];
                    f.ip = ip;
                    f.stack_top = stack_top;
                    const attr = self.loadAttribute(inst, name) catch |err| {
                        if (err == error.PythonException) {
                            if (self.frame_count == 0) return error.PythonException;
                            frame_idx = self.frame_count - 1;
                            f = &self.frames[frame_idx];
                            ip = f.ip;
                            stack_top = f.stack_top;
                            instructions = f.code.instructions;
                            consts = f.code.consts;
                            names = f.code.names;
                            varnames = f.code.varnames;
                            fastlocals = f.fastlocals;
                            globals = f.globals;
                            locals = &f.locals;
                            is_module = f.is_module;
                            is_class_body = f.is_class_body;
                            func = f.func;
                            continue;
                        }
                        return err;
                    };
                    push(f, &stack_top, attr);
                },
                .STORE_ATTR => {
                    const inst = pop(f, &stack_top);
                    defer inst.decRef(self.mm);
                    const val = pop(f, &stack_top);
                    defer val.decRef(self.mm);
                    const name = names[instr.arg];
                    f.ip = ip;
                    f.stack_top = stack_top;
                    self.storeAttribute(inst, name, val) catch |err| {
                        if (err == error.PythonException) {
                            if (self.frame_count == 0) return error.PythonException;
                            frame_idx = self.frame_count - 1;
                            f = &self.frames[frame_idx];
                            ip = f.ip;
                            stack_top = f.stack_top;
                            instructions = f.code.instructions;
                            consts = f.code.consts;
                            names = f.code.names;
                            varnames = f.code.varnames;
                            fastlocals = f.fastlocals;
                            globals = f.globals;
                            locals = &f.locals;
                            is_module = f.is_module;
                            is_class_body = f.is_class_body;
                            func = f.func;
                            continue;
                        }
                        return err;
                    };
                },
                .LOAD_METHOD => {
                    const inst = pop(f, &stack_top);
                    defer inst.decRef(self.mm);
                    const name = names[instr.arg];
                    f.ip = ip;
                    f.stack_top = stack_top;
                    const attr = self.loadAttribute(inst, name) catch |err| {
                        if (err == error.PythonException) {
                            if (self.frame_count == 0) return error.PythonException;
                            frame_idx = self.frame_count - 1;
                            f = &self.frames[frame_idx];
                            ip = f.ip;
                            stack_top = f.stack_top;
                            instructions = f.code.instructions;
                            consts = f.code.consts;
                            names = f.code.names;
                            varnames = f.code.varnames;
                            fastlocals = f.fastlocals;
                            globals = f.globals;
                            locals = &f.locals;
                            is_module = f.is_module;
                            is_class_body = f.is_class_body;
                            func = f.func;
                            continue;
                        }
                        return err;
                    };
                    push(f, &stack_top, attr);
                },
                .CALL_METHOD => {
                    const argc = instr.arg;
                    var args = try self.allocator.alloc(*PyObject, argc);
                    defer self.allocator.free(args);
                    var i: usize = 0;
                    while (i < argc) : (i += 1) {
                        stack_top -= 1;
                        args[argc - 1 - i] = f.stack[stack_top];
                    }
                    stack_top -= 1;
                    const callable = f.stack[stack_top];
                    defer callable.decRef(self.mm);
                    
                    f.ip = ip;
                    f.stack_top = stack_top;
                    
                    try self.callObject(callable, args, null);
                    
                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },
                .SETUP_FINALLY => {
                    if (f.block_stack_top >= 16) return error.StackOverflow;
                    f.block_stack[f.block_stack_top] = .{
                        .type = .Finally,
                        .handler = instr.arg,
                        .stack_level = stack_top,
                    };
                    f.block_stack_top += 1;
                },
                .POP_BLOCK => {
                    if (f.block_stack_top == 0) return error.SystemError;
                    f.block_stack_top -= 1;
                },
                .RAISE_VARARGS => {
                    f.ip = ip;

                    if (instr.arg == 1) {
                        const exc = pop(f, &stack_top);
                        f.stack_top = stack_top;
                        try self.raiseException(exc);
                        exc.decRef(self.mm);
                    } else {
                        f.stack_top = stack_top;
                        if (f.active_exception) |ae| {
                            try self.raiseException(ae);
                        } else {
                            std.debug.print("RuntimeError: No active exception to re-raise\n", .{});
                            return error.RuntimeError;
                        }
                    }

                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },
                .LOAD_CLOSURE => {
                    const name = names[instr.arg];
                    var cell_obj: ?*PyObject = null;
                    if (locals.get(name)) |val| {
                        if (val.type_obj == PyCell_Type) {
                            cell_obj = val;
                        } else {
                            const cell = try PyCellObject.create(val, self.mm);
                            const g = try locals.getOrPut(name);
                            if (!g.found_existing) {
                                g.key_ptr.* = try self.allocator.dupe(u8, name);
                            }
                            g.value_ptr.* = &cell.base;
                            val.decRef(self.mm);
                            cell_obj = &cell.base;
                        }
                    } else if (func) |fu| {
                        if (fu.closure.get(name)) |c| {
                            cell_obj = c;
                        }
                    }
                    
                    if (cell_obj) |co| {
                        co.incRef();
                        push(f, &stack_top, co);
                    } else {
                        const cell = try PyCellObject.create(null, self.mm);
                        const g = try locals.getOrPut(name);
                        if (g.found_existing) {
                            g.value_ptr.*.decRef(self.mm);
                        } else {
                            g.key_ptr.* = try self.allocator.dupe(u8, name);
                        }
                        g.value_ptr.* = &cell.base;
                        cell.base.incRef();
                        push(f, &stack_top, &cell.base);
                    }
                },
                .LOAD_DEREF => {
                    const name = names[instr.arg];
                    var cell_val: ?*PyObject = null;
                    if (locals.get(name)) |c| {
                        cell_val = c.as(PyCellObject).value;
                    } else if (func) |fu| {
                        if (fu.closure.get(name)) |c| {
                            cell_val = c.as(PyCellObject).value;
                        }
                    }
                    
                    if (cell_val) |cv| {
                        cv.incRef();
                        push(f, &stack_top, cv);
                    } else {
                        f.ip = ip;
                        f.stack_top = stack_top;
                        
                        var buf: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "NameError: You tried to use the free variable '{s}' before defining it! (It's free, but not that free!)", .{name}) catch "NameError: undefined free variable";
                        try self.raiseNameError(msg);
                        
                        frame_idx = self.frame_count - 1;
                        f = &self.frames[frame_idx];
                        ip = f.ip;
                        stack_top = f.stack_top;
                        instructions = f.code.instructions;
                        consts = f.code.consts;
                        names = f.code.names;
                        varnames = f.code.varnames;
                        fastlocals = f.fastlocals;
                        globals = f.globals;
                        locals = &f.locals;
                        is_module = f.is_module;
                        is_class_body = f.is_class_body;
                        func = f.func;
                    }
                },
                .STORE_DEREF => {
                    const val = pop(f, &stack_top);
                    const name = names[instr.arg];
                    var cell_obj: ?*PyCellObject = null;
                    if (locals.get(name)) |c| {
                        cell_obj = c.as(PyCellObject);
                    } else if (func) |fu| {
                        if (fu.closure.get(name)) |c| {
                            cell_obj = c.as(PyCellObject);
                        }
                    }
                    
                    if (cell_obj) |co| {
                        if (co.value) |old_val| old_val.decRef(self.mm);
                        co.value = val;
                    } else {
                        const cell = try PyCellObject.create(val, self.mm);
                        const g = try locals.getOrPut(name);
                        if (g.found_existing) {
                            g.value_ptr.*.decRef(self.mm);
                        } else {
                            g.key_ptr.* = try self.allocator.dupe(u8, name);
                        }
                        g.value_ptr.* = &cell.base;
                        val.decRef(self.mm);
                    }
                },
                .IMPORT_NAME => {
                    const name = names[instr.arg];
                    const mod = try @import("../import_system/import.zig").importModule(name, self);
                    push(f, &stack_top, mod);
                },
                .IMPORT_FROM => {
                    const mod = f.stack[stack_top - 1];
                    const name = names[instr.arg];
                    const val = try self.loadAttribute(mod, name);
                    push(f, &stack_top, val);
                },
                .POP_TOP => {
                    const obj = pop(f, &stack_top);
                    obj.decRef(self.mm);
                },
                .CHECK_EXCEPTION => {
                    const name = names[instr.arg];
                    const exc = f.stack[stack_top - 1];
                    const is_match = self.isExceptionMatch(exc, name);
                    
                    const res = if (is_match) PyTrue else PyFalse;
                    res.incRef();
                    push(f, &stack_top, res);
                },
                .LOAD_FAST => {
                    const idx = instr.arg;
                    if (fastlocals[idx]) |val| {
                        val.incRef();
                        push(f, &stack_top, val);
                    } else {
                        const name = varnames[idx];
                        f.ip = ip;
                        f.stack_top = stack_top;
                        
                        var buf: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "NameError: You tried to read the local variable '{s}' before giving it a value! (That's like looking for water in an empty cup!)", .{name}) catch "NameError: undefined local variable";
                        try self.raiseNameError(msg);
                        
                        frame_idx = self.frame_count - 1;
                        f = &self.frames[frame_idx];
                        ip = f.ip;
                        stack_top = f.stack_top;
                        instructions = f.code.instructions;
                        consts = f.code.consts;
                        names = f.code.names;
                        varnames = f.code.varnames;
                        fastlocals = f.fastlocals;
                        globals = f.globals;
                        locals = &f.locals;
                        is_module = f.is_module;
                        is_class_body = f.is_class_body;
                        func = f.func;
                    }
                },
                .STORE_FAST => {
                    const val = pop(f, &stack_top);
                    const idx = instr.arg;
                    if (fastlocals[idx]) |old_val| {
                        old_val.decRef(self.mm);
                    }
                    fastlocals[idx] = val;
                },
                .BINARY_MOD => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        if (val_b == 0) return error.ZeroDivisionError;
                        const res = try primitives.PyIntObject.create(@rem(val_a, val_b), self.mm);
                        push(f, &stack_top, res);
                    } else if (a.type_obj == PyFloat_Type or b.type_obj == PyFloat_Type) {
                        const fa = if (a.type_obj == PyFloat_Type)
                            a.as(primitives.PyFloatObject).value
                        else
                            @as(f64, @floatFromInt(a.as(primitives.PyIntObject).value));
                        const fb = if (b.type_obj == PyFloat_Type)
                            b.as(primitives.PyFloatObject).value
                        else
                            @as(f64, @floatFromInt(b.as(primitives.PyIntObject).value));
                        if (fb == 0.0) return error.ZeroDivisionError;
                        const res = try primitives.PyFloatObject.create(@mod(fa, fb), self.mm);
                        push(f, &stack_top, res);
                    } else if (a.type_obj == PyString_Type) {
                        a.incRef();
                        push(f, &stack_top, a);
                    } else {
                        return error.TypeError;
                    }
                },
                .BINARY_POW => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const base_val = a.as(primitives.PyIntObject).value;
                        const exp_val = b.as(primitives.PyIntObject).value;
                        var result: i64 = 1;
                        var i_exp: i64 = 0;
                        while (i_exp < exp_val) : (i_exp += 1) {
                            result = result * base_val;
                        }
                        const res = try primitives.PyIntObject.create(result, self.mm);
                        push(f, &stack_top, res);
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
                        const res = try primitives.PyFloatObject.create(std.math.pow(f64, fa, fb), self.mm);
                        push(f, &stack_top, res);
                    }
                },
                .BINARY_FLOOR_DIV => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        if (val_b == 0) return error.ZeroDivisionError;
                        const res = try primitives.PyIntObject.create(@divFloor(val_a, val_b), self.mm);
                        push(f, &stack_top, res);
                    } else {
                        const fa = if (a.type_obj == PyFloat_Type)
                            a.as(primitives.PyFloatObject).value
                        else
                            @as(f64, @floatFromInt(a.as(primitives.PyIntObject).value));
                        const fb = if (b.type_obj == PyFloat_Type)
                            b.as(primitives.PyFloatObject).value
                        else
                            @as(f64, @floatFromInt(b.as(primitives.PyIntObject).value));
                        if (fb == 0.0) return error.ZeroDivisionError;
                        const res = try primitives.PyFloatObject.create(@floor(fa / fb), self.mm);
                        push(f, &stack_top, res);
                    }
                },
                .UNARY_NEG => {
                    const val = pop(f, &stack_top);
                    defer val.decRef(self.mm);
                    if (val.type_obj == PyInt_Type) {
                        const v = val.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(-v, self.mm);
                        push(f, &stack_top, res);
                    } else if (val.type_obj == PyFloat_Type) {
                        const v = val.as(primitives.PyFloatObject).value;
                        const res = try primitives.PyFloatObject.create(-v, self.mm);
                        push(f, &stack_top, res);
                    } else {
                        return error.TypeError;
                    }
                },
                .GET_ITER => {
                    // The iterable is on the stack. We push an iterator object.
                    // For simplicity, we use a PyListObject as a "materialized iterator":
                    // Convert range/list/tuple/str/dict to list, push [list, index=0]
                    const iterable = pop(f, &stack_top);
                    defer iterable.decRef(self.mm);
                    
                    if (iterable.type_obj == PyGenerator_Type) {
                        iterable.incRef();
                        push(f, &stack_top, iterable);
                        PyNone.incRef();
                        push(f, &stack_top, PyNone);
                    } else if (iterable.type_obj == PyList_Type) {
                        iterable.incRef();
                        push(f, &stack_top, iterable);
                        const idx_obj = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, idx_obj);
                    } else if (iterable.type_obj == PyTuple_Type) {
                        iterable.incRef();
                        push(f, &stack_top, iterable);
                        const idx_obj = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, idx_obj);
                    } else if (iterable.type_obj == PyString_Type) {
                        const str_val = iterable.as(PyStringObject).value();
                        const list = try PyListObject.create(str_val.len, self.mm);
                        for (str_val, 0..) |ch, i| {
                            const ch_str = try PyStringObject.create(str_val[i..i+1], self.mm);
                            _ = ch;
                            list.items.?[i] = ch_str;
                        }
                        list.size = str_val.len;
                        push(f, &stack_top, &list.base);
                        const idx_obj = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, idx_obj);
                    } else if (iterable.type_obj == PyDict_Type) {
                        const dict = iterable.as(PyDictObject);
                        const list = try PyListObject.create(dict.active_count, self.mm);
                        var list_idx: usize = 0;
                        for (0..dict.entries_size) |i| {
                            if (dict.entries[i].key) |key| {
                                key.incRef();
                                list.items.?[list_idx] = key;
                                list_idx += 1;
                            }
                        }
                        list.size = list_idx;
                        push(f, &stack_top, &list.base);
                        const idx_obj = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, idx_obj);
                    } else if (iterable.type_obj == PyInstance_Type) {
                        // User-defined instance — try __iter__ protocol
                        const iter_method = self.loadAttribute(iterable, "__iter__") catch {
                            std.debug.print("TypeError: You tried to loop over a '{s}' object, but it isn't iterable! (It doesn't know how to line up its elements!)\n", .{iterable.as(PyInstanceObject).class_obj.name.as(PyStringObject).value()});
                            return error.TypeError;
                        };
                        defer iter_method.decRef(self.mm);
                        
                        f.ip = ip;
                        f.stack_top = stack_top;
                        const prev_frame = self.frame_count;
                        try self.callObject(iter_method, &.{}, null);
                        if (self.frame_count > prev_frame) {
                            self.suppress_exception_handling = true;
                            defer self.suppress_exception_handling = false;
                            try self.runLoop(prev_frame);
                        }
                        
                        const iter_obj = self.last_result orelse return error.TypeError;
                        self.last_result = null;
                        
                        frame_idx = self.frame_count - 1;
                        f = &self.frames[frame_idx];
                        stack_top = f.stack_top;
                        
                        push(f, &stack_top, iter_obj);
                        PyNone.incRef();
                        push(f, &stack_top, PyNone);
                    } else {
                        // Try if it's a range object (which is a list in our implementation)
                        iterable.incRef();
                        push(f, &stack_top, iterable);
                        const idx_obj = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, idx_obj);
                    }
                },
                .FOR_ITER => {
                    // Stack: [..., iterable, index]
                    // If index < len: push iterable[index], index += 1
                    // If index >= len: jump to arg (end of for loop)
                    const idx_obj = pop(f, &stack_top);
                    defer idx_obj.decRef(self.mm);
                    const iterable = f.stack[stack_top - 1]; // peek, don't pop
                    
                    if (iterable.type_obj == PyGenerator_Type) {
                        const gen = iterable.as(function_mod.PyGeneratorObject);
                        if (gen.is_closed) {
                            // Leave generator on stack for POP_TOP to clean up
                            ip = instr.arg;
                        } else {
                            f.ip = ip - 1;
                            f.stack_top = stack_top;
                            
                            self.frames[self.frame_count] = gen.frame;
                            self.frame_count += 1;
                            
                            frame_idx = self.frame_count - 1;
                            f = &self.frames[frame_idx];
                            ip = f.ip;
                            stack_top = f.stack_top;
                            instructions = f.code.instructions;
                            consts = f.code.consts;
                            names = f.code.names;
                            varnames = f.code.varnames;
                            fastlocals = f.fastlocals;
                            globals = f.globals;
                            locals = &f.locals;
                            is_module = f.is_module;
                            is_class_body = f.is_class_body;
                            func = f.func;
                        }
                    } else if (@intFromPtr(idx_obj) == @intFromPtr(PyNone)) {
                        // User-defined iterator — call __next__
                        const next_method = self.loadAttribute(iterable, "__next__") catch {
                            std.debug.print("StopIteration: iterator has no __next__\n", .{});
                            return error.TypeError;
                        };
                        defer next_method.decRef(self.mm);
                        
                        f.ip = ip;
                        f.stack_top = stack_top;
                        const prev_frame = self.frame_count;
                        try self.callObject(next_method, &.{}, null);
                        if (self.frame_count > prev_frame) {
                            self.suppress_exception_handling = true;
                            defer self.suppress_exception_handling = false;
                            self.runLoop(prev_frame) catch |err| {
                                if (err == error.PythonException) {
                                    // __next__ raised StopIteration (or any exception) — terminate loop
                                    _ = pop(f, &stack_top); // remove iterator
                                    stack_top = f.stack_top;
                                    ip = instr.arg;
                                    continue;
                                }
                                return err;
                            };
                        }
                        
                        // __next__ returned normally
                        const val = self.last_result orelse return error.TypeError;
                        self.last_result = null;
                        
                        frame_idx = self.frame_count - 1;
                        f = &self.frames[frame_idx];
                        stack_top = f.stack_top;
                        
                        PyNone.incRef();
                        push(f, &stack_top, PyNone);
                        push(f, &stack_top, val);
                    } else {
                        const idx = idx_obj.as(primitives.PyIntObject).value;
                        
                        var size: i64 = 0;
                        if (iterable.type_obj == PyList_Type) {
                            size = @intCast(iterable.as(PyListObject).size);
                        } else if (iterable.type_obj == PyTuple_Type) {
                            size = @intCast(iterable.as(PyTupleObject).size);
                        }
                        
                        if (idx < size) {
                            var item: *PyObject = undefined;
                            if (iterable.type_obj == PyList_Type) {
                                const list = iterable.as(PyListObject);
                                item = list.items.?[@intCast(idx)];
                            } else if (iterable.type_obj == PyTuple_Type) {
                                const tuple = iterable.as(PyTupleObject);
                                item = tuple.items()[@intCast(idx)];
                            } else {
                                return error.TypeError;
                            }
                            
                            // Push next index
                            const new_idx = try primitives.PyIntObject.create(idx + 1, self.mm);
                            push(f, &stack_top, new_idx);
                            
                            // Push the item
                            item.incRef();
                            push(f, &stack_top, item);
                        } else {
                            // Iterator exhausted — jump to end
                            ip = instr.arg;
                        }
                    }
                },
                .BINARY_SUBSCR => {
                    const index = pop(f, &stack_top);
                    const container = pop(f, &stack_top);
                    defer index.decRef(self.mm);
                    defer container.decRef(self.mm);

                    if (index.type_obj == PySlice_Type) {
                        const slice = index.as(PySliceObject);
                        if (container.type_obj == PyList_Type) {
                            const list = container.as(PyListObject);
                            const items = if (list.items) |it| it[0..list.size] else &[_]*PyObject{};
                            const length = @as(i64, @intCast(items.len));
                            const info = slice.computeIndices(length);
                            const step = info.step;
                            if (step == 0) return error.ValueError;
                            const result = try PyListObject.create(0, self.mm);
                            if (step > 0) {
                                var i: i64 = info.start;
                                while (i < info.stop) : (i += step) {
                                    const item = items[@intCast(i)];
                                    try result.append(item, self.mm);
                                }
                            } else {
                                var i: i64 = info.start;
                                while (i > info.stop) : (i += step) {
                                    const item = items[@intCast(i)];
                                    try result.append(item, self.mm);
                                }
                            }
                            push(f, &stack_top, &result.base);
                        } else if (container.type_obj == PyTuple_Type) {
                            const tuple = container.as(PyTupleObject);
                            const items = tuple.items();
                            const length = @as(i64, @intCast(items.len));
                            const info = slice.computeIndices(length);
                            const step = info.step;
                            if (step == 0) return error.ValueError;
                            const count = blk: {
                                var c: i64 = 0;
                                if (step > 0) { var i = info.start; while (i < info.stop) : (i += step) c += 1; }
                                else { var i = info.start; while (i > info.stop) : (i += step) c += 1; }
                                break :blk @as(usize, @intCast(c));
                            };
                            const result = try PyTupleObject.create(count, self.mm);
                            var ri: usize = 0;
                            if (step > 0) {
                                var i: i64 = info.start;
                                while (i < info.stop) : (i += step) {
                                    const item = items[@intCast(i)];
                                    item.incRef();
                                    result.items()[ri] = item;
                                    ri += 1;
                                }
                            } else {
                                var i: i64 = info.start;
                                while (i > info.stop) : (i += step) {
                                    const item = items[@intCast(i)];
                                    item.incRef();
                                    result.items()[ri] = item;
                                    ri += 1;
                                }
                            }
                            push(f, &stack_top, &result.base);
                        } else if (container.type_obj == PyString_Type) {
                            const str_val = container.as(PyStringObject).value();
                            const length = @as(i64, @intCast(str_val.len));
                            const info = slice.computeIndices(length);
                            const step = info.step;
                            if (step == 0) return error.ValueError;
                            var alloc_writer = std.Io.Writer.Allocating.init(self.mm.allocator);
                            defer alloc_writer.deinit();
                            const writer = &alloc_writer.writer;
                            if (step > 0) {
                                var i: i64 = info.start;
                                while (i < info.stop) : (i += step) {
                                    try writer.writeByte(str_val[@intCast(i)]);
                                }
                            } else {
                                var i: i64 = info.start;
                                while (i > info.stop) : (i += step) {
                                    try writer.writeByte(str_val[@intCast(i)]);
                                }
                            }
                            const result = try PyStringObject.create(alloc_writer.written(), self.mm);
                            push(f, &stack_top, result);
                        } else {
                            return error.TypeError;
                        }
                    } else if (container.type_obj == PyList_Type) {
                        const list = container.as(PyListObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(list.size)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(list.size))) {
                            return error.IndexError;
                        }
                        const item = list.items.?[@intCast(actual_idx)];
                        item.incRef();
                        push(f, &stack_top, item);
                    } else if (container.type_obj == PyTuple_Type) {
                        const tuple = container.as(PyTupleObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(tuple.size)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(tuple.size))) {
                            return error.IndexError;
                        }
                        const item = tuple.items()[@intCast(actual_idx)];
                        item.incRef();
                        push(f, &stack_top, item);
                    } else if (container.type_obj == PyDict_Type) {
                        const dict = container.as(PyDictObject);
                        if (try dict.getItem(index, self.mm)) |val| {
                            val.incRef();
                            push(f, &stack_top, val);
                        } else {
                            return error.KeyError;
                        }
                    } else if (container.type_obj == PyString_Type) {
                        const str_val = container.as(PyStringObject).value();
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(str_val.len)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(str_val.len))) {
                            return error.IndexError;
                        }
                        const uidx: usize = @intCast(actual_idx);
                        const ch_str = try PyStringObject.create(str_val[uidx..uidx+1], self.mm);
                        push(f, &stack_top, ch_str);
                    } else if (container.type_obj == PyBytes_Type) {
                        const bytes_obj = container.as(primitives.PyBytesObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(bytes_obj.len)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(bytes_obj.len))) {
                            return error.IndexError;
                        }
                        const uidx: usize = @intCast(actual_idx);
                        const val = bytes_obj.ptr[uidx];
                        const int_obj = try primitives.PyIntObject.create(val, self.mm);
                        push(f, &stack_top, int_obj);
                    } else if (container.type_obj == PyByteArray_Type) {
                        const ba_obj = container.as(primitives.PyByteArrayObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(ba_obj.size)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(ba_obj.size))) {
                            return error.IndexError;
                        }
                        const uidx: usize = @intCast(actual_idx);
                        const val = ba_obj.items.?[uidx];
                        const int_obj = try primitives.PyIntObject.create(val, self.mm);
                        push(f, &stack_top, int_obj);
                    } else if (container.type_obj == &@import("../objects/class.zig").PyInstance_Type) {
                        const instance = container.as(@import("../objects/class.zig").PyInstanceObject);
                        if (try self.lookupClassAttribute(instance.class_obj, "__getitem__")) |getitem_func| {
                            defer getitem_func.decRef(self.mm);
                            const bound = try PyMethodObject.create(&instance.base, getitem_func, self.mm);
                            defer bound.base.decRef(self.mm);
                            var call_args = [_]*PyObject{index};
                            const res = try self.callCallable(&bound.base, &call_args);
                            push(f, &stack_top, res);
                        } else {
                            return error.TypeError;
                        }
                    } else {
                        return error.TypeError;
                    }
                },
                .STORE_SUBSCR => {
                    // Stack: value, container, index
                    const index = pop(f, &stack_top);
                    const container = pop(f, &stack_top);
                    const value = pop(f, &stack_top);
                    defer index.decRef(self.mm);
                    defer container.decRef(self.mm);
                    defer value.decRef(self.mm);
                    
                    if (container.type_obj == PyList_Type) {
                        const list = container.as(PyListObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(list.size)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(list.size))) {
                            return error.IndexError;
                        }
                        const uidx: usize = @intCast(actual_idx);
                        list.items.?[uidx].decRef(self.mm);
                        value.incRef();
                        list.items.?[uidx] = value;
                    } else if (container.type_obj == PyDict_Type) {
                        const dict = container.as(PyDictObject);
                        try dict.setItem(index, value, self.mm);
                    } else if (container.type_obj == PyByteArray_Type) {
                        const ba_obj = container.as(primitives.PyByteArrayObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(ba_obj.size)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(ba_obj.size))) {
                            return error.IndexError;
                        }
                        const uidx: usize = @intCast(actual_idx);
                        if (value.type_obj != PyInt_Type) {
                            return error.TypeError;
                        }
                        const val = value.as(primitives.PyIntObject).value;
                        if (val < 0 or val > 255) {
                            return error.ValueError;
                        }
                        ba_obj.items.?[uidx] = @intCast(val);
                    } else if (container.type_obj == &@import("../objects/class.zig").PyInstance_Type) {
                        const instance = container.as(@import("../objects/class.zig").PyInstanceObject);
                        if (try self.lookupClassAttribute(instance.class_obj, "__setitem__")) |setitem_func| {
                            defer setitem_func.decRef(self.mm);
                            const bound = try PyMethodObject.create(&instance.base, setitem_func, self.mm);
                            defer bound.base.decRef(self.mm);
                            var call_args = [_]*PyObject{index, value};
                            const res = try self.callCallable(&bound.base, &call_args);
                            res.decRef(self.mm);
                        } else {
                            return error.TypeError;
                        }
                    } else {
                        return error.TypeError;
                    }
                },
                .DELETE_NAME => {
                    const name = names[instr.arg];
                    const map = if (is_class_body) locals else globals;
                    if (map.fetchRemove(name)) |kv| {
                        self.allocator.free(kv.key);
                        kv.value.decRef(self.mm);
                    }
                },
                .DELETE_FAST => {
                    const idx = instr.arg;
                    if (fastlocals[idx]) |val| {
                        val.decRef(self.mm);
                        fastlocals[idx] = null;
                    }
                },
                .DELETE_SUBSCR => {
                    // Stack: container, index
                    const index = pop(f, &stack_top);
                    const container = pop(f, &stack_top);
                    defer index.decRef(self.mm);
                    defer container.decRef(self.mm);
                    
                    if (container.type_obj == PyDict_Type) {
                        const dict = container.as(PyDictObject);
                        _ = dict.delItem(index, self.mm) catch {};
                    } else if (container.type_obj == PyList_Type) {
                        const list = container.as(PyListObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(list.size)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(list.size))) {
                            return error.IndexError;
                        }
                        const uidx: usize = @intCast(actual_idx);
                        list.items.?[uidx].decRef(self.mm);
                        for (uidx..list.size - 1) |j| {
                            list.items.?[j] = list.items.?[j + 1];
                        }
                        list.size -= 1;
                    } else if (container.type_obj == &@import("../objects/class.zig").PyInstance_Type) {
                        const instance = container.as(@import("../objects/class.zig").PyInstanceObject);
                        if (try self.lookupClassAttribute(instance.class_obj, "__delitem__")) |delitem_func| {
                            defer delitem_func.decRef(self.mm);
                            const bound = try PyMethodObject.create(&instance.base, delitem_func, self.mm);
                            defer bound.base.decRef(self.mm);
                            var call_args = [_]*PyObject{index};
                            const res = try self.callCallable(&bound.base, &call_args);
                            res.decRef(self.mm);
                        } else {
                            return error.TypeError;
                        }
                    } else {
                        return error.TypeError;
                    }
                },
                .DELETE_ATTR => {
                    const obj = pop(f, &stack_top);
                    defer obj.decRef(self.mm);
                    const name = names[instr.arg];
                    const key_str = try self.mm.internString(name);
                    
                    if (obj.type_obj == PyInstance_Type) {
                        const instance = obj.as(PyInstanceObject);
                        const dict = instance.dict.as(PyDictObject);
                        _ = dict.delItem(key_str, self.mm) catch {};
                    } else {
                        return error.TypeError;
                    }
                },
                .IS_OP => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);
                    var is_same = (a == b);
                    if (!is_same) {
                        const builtins = @import("../stdlib/builtins.zig");
                        if (a.type_obj == PyTypeWrapper_Type and b.type_obj == PyTypeWrapper_Type) {
                            const wrapper_a = a.as(builtins.PyTypeWrapper);
                            const wrapper_b = b.as(builtins.PyTypeWrapper);
                            is_same = (wrapper_a.type_ptr == wrapper_b.type_ptr);
                        } else if (a.type_obj == PyTypeWrapper_Type and b.type_obj == PyBuiltinFunction_Type) {
                            const wrapper_a = a.as(builtins.PyTypeWrapper);
                            const func_b = b.as(PyBuiltinFunctionObject);
                            if (builtins.matchBuiltinType(func_b.name)) |t_ptr| {
                                is_same = (wrapper_a.type_ptr == t_ptr);
                            }
                        } else if (a.type_obj == PyBuiltinFunction_Type and b.type_obj == PyTypeWrapper_Type) {
                            const func_a = a.as(PyBuiltinFunctionObject);
                            const wrapper_b = b.as(builtins.PyTypeWrapper);
                            if (builtins.matchBuiltinType(func_a.name)) |t_ptr| {
                                is_same = (t_ptr == wrapper_b.type_ptr);
                            }
                        }
                    }
                    const result = if (instr.arg == 0) is_same else !is_same;
                    const res = if (result) PyTrue else PyFalse;
                    res.incRef();
                    push(f, &stack_top, res);
                },
                .CONTAINS_OP => {
                    const container = pop(f, &stack_top);
                    const item = pop(f, &stack_top);
                    defer container.decRef(self.mm);
                    defer item.decRef(self.mm);
                    
                    var found = false;
                    if (container.type_obj == PyList_Type) {
                        const list = container.as(PyListObject);
                        for (0..list.size) |i| {
                            const el = list.items.?[i];
                            if (try self.objectsEqual(el, item)) {
                                found = true;
                                break;
                            }
                        }
                    } else if (container.type_obj == PyTuple_Type) {
                        const tuple = container.as(PyTupleObject);
                        for (tuple.items()) |el| {
                            if (try self.objectsEqual(el, item)) {
                                found = true;
                                break;
                            }
                        }
                    } else if (container.type_obj == PyDict_Type) {
                        const dict = container.as(PyDictObject);
                        if (try dict.getItem(item, self.mm)) |_| {
                            found = true;
                        }
                    } else if (container.type_obj == PyString_Type) {
                        const hay = container.as(PyStringObject).value();
                        const needle = item.as(PyStringObject).value();
                        found = std.mem.indexOf(u8, hay, needle) != null;
                    }
                    
                    const result = if (instr.arg == 0) found else !found;
                    const res = if (result) PyTrue else PyFalse;
                    res.incRef();
                    push(f, &stack_top, res);
                },
                .BINARY_AND => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(val_a & val_b, self.mm);
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else if ((a.type_obj == PySet_Type or a.type_obj == PyFrozenSet_Type) and
                               (b.type_obj == PySet_Type or b.type_obj == PyFrozenSet_Type)) {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        const res = try self.setIntersection(a, b);
                        push(f, &stack_top, res);
                    } else {
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        return error.TypeError;
                    }
                },
                .BINARY_OR => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(val_a | val_b, self.mm);
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else if ((a.type_obj == PySet_Type or a.type_obj == PyFrozenSet_Type) and
                               (b.type_obj == PySet_Type or b.type_obj == PyFrozenSet_Type)) {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        const res = try self.setUnion(a, b);
                        push(f, &stack_top, res);
                    } else {
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        return error.TypeError;
                    }
                },
                .BINARY_XOR => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(val_a ^ val_b, self.mm);
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else if ((a.type_obj == PySet_Type or a.type_obj == PyFrozenSet_Type) and
                               (b.type_obj == PySet_Type or b.type_obj == PyFrozenSet_Type)) {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        const res = try self.setXor(a, b);
                        push(f, &stack_top, res);
                    } else {
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        return error.TypeError;
                    }
                },
                .BINARY_LSHIFT => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        if (val_b < 0) {
                            std.debug.print("ValueError: You tried to shift bits by a negative count ({d})! (Shifting backwards in time is not yet supported in this dimension!)\n", .{val_b});
                            return error.ValueError;
                        }
                        const res_val = if (val_b >= 64) @as(i64, 0) else val_a << @intCast(val_b);
                        const res = try primitives.PyIntObject.create(res_val, self.mm);
                        push(f, &stack_top, res);
                    } else {
                        return error.TypeError;
                    }
                },
                .BINARY_RSHIFT => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);

                    if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        if (val_b < 0) {
                            std.debug.print("ValueError: You tried to shift bits by a negative count ({d})! (Shifting backwards in time is not yet supported in this dimension!)\n", .{val_b});
                            return error.ValueError;
                        }
                        const res_val = if (val_b >= 64) (if (val_a < 0) @as(i64, -1) else @as(i64, 0)) else val_a >> @intCast(val_b);
                        const res = try primitives.PyIntObject.create(res_val, self.mm);
                        push(f, &stack_top, res);
                    } else {
                        return error.TypeError;
                    }
                },
                .BINARY_MATRIX_MULTIPLY => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);
                    return error.TypeError;
                },
                .UNARY_INVERT => {
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);

                    if (a.type_obj == PyInt_Type) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(~val_a, self.mm);
                        push(f, &stack_top, res);
                    } else {
                        return error.TypeError;
                    }
                },
                .BEFORE_WITH => {
                    const mgr = pop(f, &stack_top);
                    defer mgr.decRef(self.mm);

                    const enter_fn = try self.loadAttribute(mgr, "__enter__");
                    defer enter_fn.decRef(self.mm);
                    const exit_fn = try self.loadAttribute(mgr, "__exit__");

                    if (f.block_stack_top >= 16) return error.StackOverflow;
                    f.block_stack[f.block_stack_top] = .{
                        .type = .With,
                        .handler = 0,
                        .stack_level = stack_top,
                        .exit_func = exit_fn,
                    };
                    f.block_stack_top += 1;

                    f.ip = ip;
                    f.stack_top = stack_top;
                    const args = &[_]*PyObject{};
                    try self.callObject(enter_fn, args, null);

                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },
                .EXIT_WITH => {
                    if (f.block_stack_top == 0) return error.SystemError;
                    f.block_stack_top -= 1;
                    const block = f.block_stack[f.block_stack_top];
                    if (block.type != .With) return error.SystemError;

                    const exit_fn = block.exit_func.?;
                    defer exit_fn.decRef(self.mm);

                    f.ip = ip;
                    f.stack_top = stack_top;

                    PyNone.incRef();
                    PyNone.incRef();
                    PyNone.incRef();
                    var args = [_]*PyObject{ PyNone, PyNone, PyNone };
                    try self.callObject(exit_fn, &args, null);

                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },
                .YIELD_VALUE => {
                    const val = pop(f, &stack_top);
                    const gen = f.generator.?.as(function_mod.PyGeneratorObject);

                    // Push sentinel for POP_TOP to consume on resumption
                    PyNone.incRef();
                    push(f, &stack_top, PyNone);

                    f.ip = ip;
                    f.stack_top = stack_top;
                    gen.frame = f.*;

                    self.frame_count -= 1;

                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;

                    if (ip < instructions.len and instructions[ip].op == .FOR_ITER) {
                        // Advance past FOR_ITER — the yielded value is the loop item
                        ip += 1;
                        // Push a dummy index for FOR_ITER to pop on the next iteration
                        const dummy = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, dummy);
                    }
                    push(f, &stack_top, val);
                },

                // --- Phase 5 new opcodes ---
                .UNPACK_SEQUENCE => {
                    const count = instr.arg;
                    const seq = pop(f, &stack_top);
                    defer seq.decRef(self.mm);

                    // Materialize iterable into a temporary items list
                    var items_list = std.ArrayList(*PyObject).empty;
                    defer {
                        // Items that weren't pushed get decRef'd
                        items_list.deinit(self.allocator);
                    }

                    if (seq.type_obj == PyList_Type) {
                        const lst = seq.as(PyListObject);
                        try items_list.ensureTotalCapacity(self.allocator, lst.size);
                        for (0..lst.size) |i| {
                            lst.items.?[i].incRef();
                            try items_list.append(self.allocator, lst.items.?[i]);
                        }
                    } else if (seq.type_obj == PyTuple_Type) {
                        const tup = seq.as(PyTupleObject);
                        const tup_items = tup.items();
                        try items_list.ensureTotalCapacity(self.allocator, tup_items.len);
                        for (tup_items) |item| {
                            item.incRef();
                            try items_list.append(self.allocator, item);
                        }
                    } else if (seq.type_obj == PyString_Type) {
                        const str_val = seq.as(PyStringObject).value();
                        try items_list.ensureTotalCapacity(self.allocator, str_val.len);
                        for (str_val, 0..) |_, i| {
                            const ch = try PyStringObject.create(str_val[i..i+1], self.mm);
                            try items_list.append(self.allocator, ch);
                        }
                    } else {
                        f.ip = ip;
                        f.stack_top = stack_top;
                        
                        var buf: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "TypeError: You tried to unpack a '{s}' object which isn't a list, tuple, or string! (You can't unpack a single object like a present without wrapping it first!)", .{seq.type_obj.name}) catch "TypeError: cannot unpack non-sequence";
                        try self.raiseTypeError(msg);
                        
                        if (self.frame_count == 0) return error.PythonException;
                        frame_idx = self.frame_count - 1;
                        f = &self.frames[frame_idx];
                        ip = f.ip;
                        stack_top = f.stack_top;
                        instructions = f.code.instructions;
                        consts = f.code.consts;
                        names = f.code.names;
                        varnames = f.code.varnames;
                        fastlocals = f.fastlocals;
                        globals = f.globals;
                        locals = &f.locals;
                        is_module = f.is_module;
                        is_class_body = f.is_class_body;
                        func = f.func;
                        continue;
                    }

                    if (items_list.items.len != count) {
                        f.ip = ip;
                        f.stack_top = stack_top;
                        
                        var buf: [512]u8 = undefined;
                        const msg = if (items_list.items.len < count)
                            std.fmt.bufPrint(&buf, "ValueError: You tried to unpack {d} values, but only got {d}! (You can't get two shoes out of one box!)", .{count, items_list.items.len}) catch "ValueError: not enough values to unpack"
                        else
                            std.fmt.bufPrint(&buf, "ValueError: You tried to unpack {d} values, but there's too much stuff in here ({d} items)! (It's like trying to fit a sleeping bag back into its original pouch!)", .{count, items_list.items.len}) catch "ValueError: too many values to unpack";
                        
                        try self.raiseValueError(msg);
                        for (items_list.items) |item| item.decRef(self.mm);
                        
                        if (self.frame_count == 0) return error.PythonException;
                        frame_idx = self.frame_count - 1;
                        f = &self.frames[frame_idx];
                        ip = f.ip;
                        stack_top = f.stack_top;
                        instructions = f.code.instructions;
                        consts = f.code.consts;
                        names = f.code.names;
                        varnames = f.code.varnames;
                        fastlocals = f.fastlocals;
                        globals = f.globals;
                        locals = &f.locals;
                        is_module = f.is_module;
                        is_class_body = f.is_class_body;
                        func = f.func;
                        continue;
                    }

                    // Push in reverse so TOS = first item
                    var ri: usize = count;
                    while (ri > 0) {
                        ri -= 1;
                        push(f, &stack_top, items_list.items[ri]);
                    }
                    // Clear the list without decRef (items were transferred to stack)
                    items_list.clearRetainingCapacity();
                },

                .CALL_EX => {
                    // arg=0: TOS=args_tuple, TOS1=callable
                    // arg=1: TOS=kwargs_dict, TOS1=args_tuple, TOS2=callable
                    const has_kwargs = instr.arg != 0;
                    const kwargs_obj: ?*PyObject = if (has_kwargs) pop(f, &stack_top) else null;
                    defer if (kwargs_obj) |k| k.decRef(self.mm);
                    const args_obj = pop(f, &stack_top);
                    defer args_obj.decRef(self.mm);
                    const callable = pop(f, &stack_top);
                    defer callable.decRef(self.mm);

                    // Convert args_obj (tuple or list) to a slice
                    var args_slice: []*PyObject = undefined;
                    var args_backing: std.ArrayList(*PyObject) = std.ArrayList(*PyObject).empty;
                    defer args_backing.deinit(self.allocator);

                    if (args_obj.type_obj == PyList_Type) {
                        const lst = args_obj.as(PyListObject);
                        try args_backing.ensureTotalCapacity(self.allocator, lst.size);
                        for (0..lst.size) |i| {
                            lst.items.?[i].incRef();
                            try args_backing.append(self.allocator, lst.items.?[i]);
                        }
                        args_slice = args_backing.items;
                    } else if (args_obj.type_obj == PyTuple_Type) {
                        const tup = args_obj.as(PyTupleObject);
                        const tup_items = tup.items();
                        try args_backing.ensureTotalCapacity(self.allocator, tup_items.len);
                        for (tup_items) |item| {
                            item.incRef();
                            try args_backing.append(self.allocator, item);
                        }
                        args_slice = args_backing.items;
                    } else {
                        std.debug.print("TypeError: You tried to use '*' on a non-iterable argument! The argument after '*' must be a list, tuple, or string. (I can't spread a single value for you!)\n", .{});
                        return error.TypeError;
                    }

                    // If kwargs, merge keyword args from dict into fastlocals later
                    // For now: just call with positional args
                    f.ip = ip;
                    f.stack_top = stack_top;
                    try self.callObject(callable, args_slice, null);
                    for (args_slice) |a| a.decRef(self.mm);

                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },

                .LIST_EXTEND => {
                    // TOS = iterable to extend with, TOS[arg] = list to extend
                    const iterable = pop(f, &stack_top);
                    defer iterable.decRef(self.mm);
                    const list_obj = f.stack[stack_top - 1 - instr.arg];
                    if (list_obj.type_obj != PyList_Type) return error.TypeError;
                    const list = list_obj.as(PyListObject);
                    
                    if (iterable.type_obj == PyList_Type) {
                        const src = iterable.as(PyListObject);
                        for (0..src.size) |idx| {
                            src.items.?[idx].incRef();
                            try list.append(src.items.?[idx], self.mm);
                        }
                    } else if (iterable.type_obj == PyTuple_Type) {
                        const tup = iterable.as(PyTupleObject);
                        for (tup.items()) |item| {
                            item.incRef();
                            try list.append(item, self.mm);
                        }
                    } else if (iterable.type_obj == PyString_Type) {
                        const str_val = iterable.as(PyStringObject).value();
                        for (str_val, 0..) |_, idx| {
                            const ch = try PyStringObject.create(str_val[idx..idx+1], self.mm);
                            try list.append(ch, self.mm);
                            ch.decRef(self.mm);
                        }
                    } else {
                        std.debug.print("TypeError: You tried to unpack a non-iterable using '*' inside a list/tuple literal! (I can't extend this list without something to loop over!)\n", .{});
                        return error.TypeError;
                    }
                },

                .DICT_MERGE => {
                    // TOS = dict to merge from, TOS[arg] = dict to merge into
                    const src = pop(f, &stack_top);
                    defer src.decRef(self.mm);
                    const dst_obj = f.stack[stack_top - 1 - instr.arg];
                    if (dst_obj.type_obj != PyDict_Type) return error.TypeError;
                    if (src.type_obj != PyDict_Type) return error.TypeError;
                    const dst = dst_obj.as(PyDictObject);
                    const src_dict = src.as(PyDictObject);
                    var idx: usize = 0;
                    while (idx < src_dict.entries_size) : (idx += 1) {
                        const entry = &src_dict.entries[idx];
                        if (entry.key) |k| {
                            try dst.setItem(k, entry.value.?, self.mm);
                        }
                    }
                },

                .STORE_SUBSCR_AUG, .STORE_ATTR_AUG => {
                    // These are unused (augmented assign is lowered to load+op+store)
                    // Treat as no-ops for safety
                },
                .SWAP => {
                    const temp = f.stack[stack_top - 1];
                    f.stack[stack_top - 1] = f.stack[stack_top - 2];
                    f.stack[stack_top - 2] = temp;
                },
                .CALL_KW => {
                    const kw_names_obj = pop(f, &stack_top);
                    defer kw_names_obj.decRef(self.mm);
                    const kw_names = kw_names_obj.as(collections.PyTupleObject).items();
                    
                    const total_argc = instr.arg;
                    const kw_argc = kw_names.len;
                    const pos_argc = total_argc - kw_argc;
                    
                    var temp_args = try self.allocator.alloc(*PyObject, total_argc);
                    defer self.allocator.free(temp_args);
                    var i: usize = 0;
                    while (i < total_argc) : (i += 1) {
                        stack_top -= 1;
                        temp_args[total_argc - 1 - i] = f.stack[stack_top];
                    }
                    
                    stack_top -= 1;
                    const callable = f.stack[stack_top];
                    defer callable.decRef(self.mm);
                    
                    const kwargs_dict = try collections.PyDictObject.create(self.mm);
                    for (0..kw_argc) |k| {
                        const name_obj = kw_names[k];
                        const val_obj = temp_args[pos_argc + k];
                        try kwargs_dict.setItem(name_obj, val_obj, self.mm);
                    }
                    defer kwargs_dict.base.decRef(self.mm);
                    
                    f.ip = ip;
                    f.stack_top = stack_top;
                    
                    if (self.callObjectKw(callable, temp_args[0..pos_argc], kwargs_dict, null)) {
                        // success — fall through to frame refresh
                    } else |err| {
                        if (err == error.StopIteration) {
                            const msg = try primitives.PyStringObject.create("", self.mm);
                            const exc = try @import("../objects/exception.zig").PyExceptionObject.create(
                                &@import("../objects/exception.zig").PyStopIteration_Type, msg, self.mm
                            );
                            try self.raiseException(&exc.base);
                            exc.base.decRef(self.mm);
                            msg.decRef(self.mm);
                        } else {
                            return err;
                        }
                    }
                    
                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },
                .BUILD_TUPLE_UNPACK, .BUILD_LIST_UNPACK, .BUILD_SET_UNPACK => {
                    const count = instr.arg;
                    var unpacked = std.ArrayListUnmanaged(*PyObject).empty;
                    defer unpacked.deinit(self.allocator);
                    
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const iterable = f.stack[stack_top - count + i];
                        if (iterable.type_obj == &collections.PyTuple_Type) {
                            const tup = iterable.as(collections.PyTupleObject);
                            for (tup.items()) |item| {
                                item.incRef();
                                try unpacked.append(self.allocator, item);
                            }
                        } else if (iterable.type_obj == &collections.PyList_Type) {
                            const lst = iterable.as(collections.PyListObject);
                            if (lst.items) |items| {
                                for (0..lst.size) |j| {
                                    items[j].incRef();
                                    try unpacked.append(self.allocator, items[j]);
                                }
                            }
                        } else {
                            std.debug.print("TypeError: Cannot unpack non-iterable object\n", .{});
                            return error.TypeError;
                        }
                        iterable.decRef(self.mm);
                    }
                    stack_top -= count;
                    
                    if (instr.op == .BUILD_TUPLE_UNPACK) {
                        const new_tup = try collections.PyTupleObject.create(unpacked.items.len, self.mm);
                        for (unpacked.items, 0..) |item, j| {
                            new_tup.items()[j] = item;
                        }
                        push(f, &stack_top, &new_tup.base);
                    } else if (instr.op == .BUILD_LIST_UNPACK) {
                        const new_list = try collections.PyListObject.create(unpacked.items.len, self.mm);
                        for (unpacked.items) |item| {
                            try new_list.append(item, self.mm);
                        }
                        push(f, &stack_top, &new_list.base);
                    } else if (instr.op == .BUILD_SET_UNPACK) {
                        return error.NotImplemented; // TODO Set unpack
                    }
                },
            }
        }
    }

    pub fn raiseExceptionType(self: *VM, exc_type: *const PyTypeObject, msg: []const u8) anyerror!void {
        const msg_obj = try PyStringObject.create(msg, self.mm);
        const exc = try PyExceptionObject.create(exc_type, msg_obj, self.mm);
        msg_obj.decRef(self.mm);
        defer exc.base.decRef(self.mm);
        try self.raiseException(&exc.base);
    }

    pub fn raiseTypeError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyTypeError_Type, msg);
    }

    pub fn raiseNameError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyNameError_Type, msg);
    }

    pub fn raiseValueError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyValueError_Type, msg);
    }

    pub fn raiseAttributeError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyAttributeError_Type, msg);
    }

    pub fn raiseZeroDivisionError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyZeroDivisionError_Type, msg);
    }

    pub fn raiseKeyError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyKeyError_Type, msg);
    }

    pub fn raiseIndexError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyIndexError_Type, msg);
    }

    pub fn raiseAssertionError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyAssertionError_Type, msg);
    }

    pub fn raiseRuntimeError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyRuntimeError_Type, msg);
    }

    pub fn raiseImportError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyImportError_Type, msg);
    }

    pub fn raiseModuleNotFoundError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyModuleNotFoundError_Type, msg);
    }

    pub fn scanForFreeVars(self: *VM, func_code: *PyCodeObject, func_obj: *PyFunctionObject, f: *PyFrameObject) anyerror!void {
        for (func_code.instructions) |instr_val| {
            if (instr_val.op == .LOAD_DEREF or instr_val.op == .STORE_DEREF or instr_val.op == .LOAD_CLOSURE) {
                const name = func_code.names[instr_val.arg];
                if (func_obj.closure.contains(name)) continue;
                
                var found_cell: ?*PyObject = null;
                
                if (f.locals.get(name)) |c| {
                    if (c.type_obj == PyCell_Type) {
                        found_cell = c;
                    } else {
                        const cell = try PyCellObject.create(c, self.mm);
                        const g = try f.locals.getOrPut(name);
                        if (!g.found_existing) {
                            g.key_ptr.* = try self.allocator.dupe(u8, name);
                        }
                        g.value_ptr.* = &cell.base;
                        c.decRef(self.mm);
                        found_cell = &cell.base;
                    }
                } else if (f.func) |curr_func| {
                    if (curr_func.closure.get(name)) |c| {
                        found_cell = c;
                    }
                }
                
                if (found_cell == null) {
                    // Check current frame's fastlocals (function args)
                    const f_varnames = f.code.varnames;
                    for (f_varnames, 0..) |vname, vi| {
                        if (std.mem.eql(u8, vname, name)) {
                            if (f.fastlocals[vi]) |val| {
                                const cell = try PyCellObject.create(val, self.mm);
                                val.decRef(self.mm);
                                f.fastlocals[vi] = &cell.base;
                                const g = try f.locals.getOrPut(name);
                                if (!g.found_existing) {
                                    g.key_ptr.* = try self.allocator.dupe(u8, name);
                                } else {
                                    g.value_ptr.*.decRef(self.mm);
                                }
                                g.value_ptr.* = &cell.base;
                                cell.base.incRef();
                                found_cell = &cell.base;
                            }
                            break;
                        }
                    }
                }
                
                if (found_cell == null) {
                    var idx = self.frame_count - 1;
                    while (idx > 0) {
                        idx -= 1;
                        const pf = &self.frames[idx];
                        // Check locals hashmap
                        if (pf.locals.get(name)) |c| {
                            if (c.type_obj == PyCell_Type) {
                                found_cell = c;
                            } else {
                                const cell = try PyCellObject.create(c, self.mm);
                                const g = try pf.locals.getOrPut(name);
                                if (!g.found_existing) {
                                    g.key_ptr.* = try self.allocator.dupe(u8, name);
                                }
                                g.value_ptr.* = &cell.base;
                                c.decRef(self.mm);
                                found_cell = &cell.base;
                            }
                            break;
                        }
                        // Check fastlocals too (function parameters)
                        const pf_varnames = pf.code.varnames;
                        for (pf_varnames, 0..) |vname, vi| {
                            if (std.mem.eql(u8, vname, name)) {
                                if (pf.fastlocals[vi]) |val| {
                                    const cell = try PyCellObject.create(val, self.mm);
                                    val.decRef(self.mm);
                                    pf.fastlocals[vi] = &cell.base;
                                    // Also put in locals so future lookups find it
                                    const g = try pf.locals.getOrPut(name);
                                    if (!g.found_existing) {
                                        g.key_ptr.* = try self.allocator.dupe(u8, name);
                                    } else {
                                        g.value_ptr.*.decRef(self.mm);
                                    }
                                    g.value_ptr.* = &cell.base;
                                    cell.base.incRef();
                                    found_cell = &cell.base;
                                }
                                break;
                            }
                        }
                        if (found_cell != null) break;
                    }
                }
                
                if (found_cell) |fc| {
                    fc.incRef();
                    try func_obj.closure.put(try self.allocator.dupe(u8, name), fc);
                }
            }
        }
        
        // Recursively scan code constants!
        for (func_code.consts) |c| {
            if (c.type_obj == &bytecode.PyCode_Type) {
                const child_code = c.as(bytecode.PyCodeObjectWrapper).code;
                try self.scanForFreeVars(child_code, func_obj, f);
            }
        }
    }
    pub fn isTrueObj(self: *VM, obj: *PyObject) anyerror!bool {
        if (obj.type_obj == &@import("../objects/class.zig").PyInstance_Type) {
            const instance = obj.as(@import("../objects/class.zig").PyInstanceObject);
            if (try self.lookupClassAttribute(instance.class_obj, "__bool__")) |bool_method| {
                defer bool_method.decRef(self.mm);
                const bound = try class_mod.PyMethodObject.create(obj, bool_method, self.mm);
                defer bound.base.decRef(self.mm);
                var call_args = [_]*PyObject{};
                const res = try self.callCallable(&bound.base, &call_args);
                defer res.decRef(self.mm);
                if (res == PyTrue) return true;
                if (res == PyFalse) return false;
                return error.TypeError;
            }
            if (try self.lookupClassAttribute(instance.class_obj, "__len__")) |len_method| {
                defer len_method.decRef(self.mm);
                const bound = try class_mod.PyMethodObject.create(obj, len_method, self.mm);
                defer bound.base.decRef(self.mm);
                var call_args = [_]*PyObject{};
                const res = try self.callCallable(&bound.base, &call_args);
                defer res.decRef(self.mm);
                if (res.type_obj == &primitives.PyInt_Type) {
                    return res.as(primitives.PyIntObject).value != 0;
                }
                return error.TypeError;
            }
        }
        return isTrue(obj);
    }


    pub fn raiseFileNotFoundError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyFileNotFoundError_Type, msg);
    }

    pub fn raisePermissionError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyPermissionError_Type, msg);
    }

    pub fn raiseMemoryError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyMemoryError_Type, msg);
    }

    pub fn raiseRecursionError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyRecursionError_Type, msg);
    }

    pub fn raiseIndentationError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyIndentationError_Type, msg);
    }

    pub fn raiseUnboundLocalError(self: *VM, msg: []const u8) anyerror!void {
        try self.raiseExceptionType(&exception_mod.PyUnboundLocalError_Type, msg);
    }

    pub fn raiseZigError(self: *VM, err: anyerror) anyerror!void {
        switch (err) {
            error.ZeroDivisionError => try self.raiseZeroDivisionError("ZeroDivisionError: division by zero"),
            error.TypeError => try self.raiseTypeError("TypeError: incompatible types or invalid operation"),
            error.ValueError => try self.raiseValueError("ValueError: invalid value"),
            error.KeyError => try self.raiseKeyError("KeyError: key not found"),
            error.IndexError => try self.raiseIndexError("IndexError: index out of range"),
            error.AttributeError => try self.raiseAttributeError("AttributeError: attribute not found"),
            error.FileNotFoundError => try self.raiseFileNotFoundError("FileNotFoundError: file not found"),
            error.PermissionError => try self.raisePermissionError("PermissionError: permission denied"),
            error.MemoryError => try self.raiseMemoryError("MemoryError: out of memory"),
            error.RecursionError => try self.raiseRecursionError("RecursionError: maximum recursion depth exceeded"),
            error.IndentationError => try self.raiseIndentationError("IndentationError: bad indentation"),
            error.AssertionError => try self.raiseAssertionError("AssertionError: assertion failed"),
            else => {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "RuntimeError: execution error: {s}", .{@errorName(err)}) catch "RuntimeError: execution error";
                try self.raiseRuntimeError(msg);
            }
        }
    }

    pub fn objectsEqual(self: *VM, a: *PyObject, b: *PyObject) anyerror!bool {
        if (a == b) return true;
        if (a.type_obj == PyInt_Type and b.type_obj == PyInt_Type) {
            return a.as(primitives.PyIntObject).value == b.as(primitives.PyIntObject).value;
        }
        if (a.type_obj == PyString_Type and b.type_obj == PyString_Type) {
            return std.mem.eql(u8, a.as(PyStringObject).value(), b.as(PyStringObject).value());
        }
        if (a.type_obj.tp_richcompare) |cmp_fn| {
            const res = try cmp_fn(a, b, .Eq, self.mm);
            defer res.decRef(self.mm);
            return res == PyTrue;
        }
        return false;
    }

    pub fn callCallable(self: *VM, callable: *PyObject, args: []*PyObject) anyerror!*PyObject {
        if (callable.type_obj == PyBuiltinFunction_Type) {
            const func = callable.as(PyBuiltinFunctionObject);
            for (args) |arg| arg.incRef();
            const res = try func.func(args, self);
            return res;
        } else if (callable.type_obj == PyFunction_Type) {
            const func = callable.as(PyFunctionObject);
            const code_wrapper = func.code.as(PyCodeObjectWrapper);
            const func_code = code_wrapper.code;
            
            const min_args = func_code.argcount - func.defaults.len;
            if (args.len < min_args or args.len > func_code.argcount) {
                std.debug.print("TypeError: expected {d} to {d} arguments, got {d}\n", .{min_args, func_code.argcount, args.len});
                return error.TypeError;
            }
            
            if (self.frame_count >= 64) return error.StackOverflow;
            
            var child_frame = PyFrameObject.init(self.allocator, func_code, func.globals, false);
            child_frame.func = func;
            func.base.incRef();
            
            for (0..func_code.argcount) |idx| {
                if (idx < args.len) {
                    const arg_val = args[idx];
                    arg_val.incRef();
                    child_frame.fastlocals[idx] = arg_val;
                } else {
                    const def_idx = idx - (func_code.argcount - func.defaults.len);
                    const def_val = func.defaults[def_idx];
                    def_val.incRef();
                    child_frame.fastlocals[idx] = def_val;
                }
            }
            
            const starting_frame_count = self.frame_count;
            self.frames[self.frame_count] = child_frame;
            self.frame_count += 1;
            
            const saved_result = self.last_result;
            defer self.last_result = saved_result;
            self.last_result = null;
            
            try self.runLoop(starting_frame_count);
            
            return self.last_result orelse PyNone;
        } else if (callable.type_obj == PyMethod_Type) {
            const method = callable.as(PyMethodObject);
            var new_args = try self.allocator.alloc(*PyObject, args.len + 1);
            defer self.allocator.free(new_args);
            new_args[0] = method.self_obj;
            for (args, 0..) |arg, idx| {
                new_args[idx + 1] = arg;
            }
            return try self.callCallable(method.func, new_args);
        } else {
            return error.TypeError;
        }
    }
};


test "VM execution of simple arithmetic" {
    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    // Dynamic output capture for test
    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var vm = try VM.init(allocator, &mm, &alloc_writer.writer, io);
    defer vm.deinit();

    // Bytecode to run: x = 10 + 20; print(x)
    // Consts: 10, 20, None
    // Names: "x"
    // Instructions:
    // 0: LOAD_CONST 0 (10)
    // 1: LOAD_CONST 1 (20)
    // 2: BINARY_ADD
    // 3: STORE_NAME 0 ("x")
    // 4: LOAD_NAME 0 ("x")
    // 5: PRINT_EXPR
    // 6: LOAD_CONST 2 (None)
    // 7: RETURN_VALUE

    const c10 = try primitives.PyIntObject.create(10, &mm);
    const c20 = try primitives.PyIntObject.create(20, &mm);
    PyNone.incRef();

    var consts = [_]*PyObject{ c10, c20, PyNone };
    var names = [_][]const u8{ try allocator.dupe(u8, "x") };

    var instrs = [_]Instruction{
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .BINARY_ADD },
        .{ .op = .STORE_NAME, .arg = 0 },
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .PRINT_EXPR },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .RETURN_VALUE },
    };

    var code = PyCodeObject{
        .instructions = instrs[0..],
        .consts = consts[0..],
        .names = names[0..],
    };

    const res = try vm.run(&code, null);
    try testing.expectEqual(PyNone, res);

    try testing.expectEqualStrings("30\n", alloc_writer.written());

    c10.decRef(&mm);
    c20.decRef(&mm);

    // Free manually duplicated name
    allocator.free(names[0]);
    // Note: PyCodeObject deinit will be bypassed because we allocated static instrs/consts on stack
}

test "VM integration test - control flow and collections" {
    const Lexer = @import("../lexer/lexer.zig").Lexer;
    const Parser = @import("../parser/parser.zig").Parser;
    const Compiler = @import("../compiler/compiler.zig").Compiler;

    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var vm = try VM.init(allocator, &mm, &alloc_writer.writer, io);
    defer vm.deinit();

    const src =
        \\x = 10
        \\if x > 5:
        \\    y = 100
        \\else:
        \\    y = 200
        \\print(y)
        \\
        \\a = 0
        \\b = 0
        \\while a < 5:
        \\    b = b + a
        \\    a = a + 1
        \\print(b)
        \\
        \\l = [1, 2]
        \\t = (3, 4)
        \\print(l)
        \\print(t)
    ;

    var lexer = Lexer.init(src);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    
    var parser = Parser.init(&lexer, arena.allocator());
    const module_ast = try parser.parseModule();

    var compiler = Compiler.init(arena.allocator(), &mm);
    defer compiler.deinit();

    var code = try compiler.compile(&module_ast);
    defer code.deinit(arena.allocator(), &mm);

    const res = try vm.run(&code, null);
    res.decRef(&mm);

    try testing.expectEqualStrings("100\n10\n[1, 2]\n(3, 4)\n", alloc_writer.written());
}

test "VM integration test - recursive function" {
    const Lexer = @import("../lexer/lexer.zig").Lexer;
    const Parser = @import("../parser/parser.zig").Parser;
    const Compiler = @import("../compiler/compiler.zig").Compiler;

    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var vm = try VM.init(allocator, &mm, &alloc_writer.writer, io);
    defer vm.deinit();

    const src =
        \\def fib(n):
        \\    if n <= 1:
        \\        return n
        \\    return fib(n-1) + fib(n-2)
        \\print(fib(5))
    ;

    var lexer = Lexer.init(src);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser.init(&lexer, arena.allocator());
    const module_ast = try parser.parseModule();

    var compiler = Compiler.init(arena.allocator(), &mm);
    defer compiler.deinit();

    var code = try compiler.compile(&module_ast);
    defer code.deinit(arena.allocator(), &mm);

    const res = try vm.run(&code, null);
    res.decRef(&mm);

    try testing.expectEqualStrings("5\n", alloc_writer.written());
}

