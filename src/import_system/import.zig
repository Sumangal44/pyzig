const std = @import("std");
const PyObject = @import("../objects/object.zig").PyObject;
const PyTypeObject = @import("../objects/object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyDictObject = @import("../objects/collections.zig").PyDictObject;
const PyStringObject = @import("../objects/primitives.zig").PyStringObject;
const Lexer = @import("../lexer/lexer.zig").Lexer;
const Parser = @import("../parser/parser.zig").Parser;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const VM = @import("../vm/vm.zig").VM;

pub const PyModuleObject = extern struct {
    base: PyObject,
    name: *PyObject, // PyStringObject
    dict: *PyObject, // PyDictObject
    
    pub fn create(name: *PyObject, dict: *PyObject, mm: *PyMemoryManager) !*PyModuleObject {
        const obj = try mm.alloc(PyModuleObject);
        obj.* = .{
            .base = PyObject.init(&PyModule_Type),
            .name = name,
            .dict = dict,
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
    mm.free(PyModuleObject, obj);
}

fn module_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyModuleObject);
    var buf: [128]u8 = undefined;
    const repr_str = std.fmt.bufPrint(&buf, "<module '{s}'>", .{obj.name.as(PyStringObject).value()}) catch "<module>";
    return try PyStringObject.create(repr_str, mm);
}

pub var sys_modules: ?std.StringHashMap(*PyObject) = null;

pub fn initImportSystem(allocator: std.mem.Allocator) void {
    if (sys_modules == null) {
        sys_modules = std.StringHashMap(*PyObject).init(allocator);
    }
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
}

pub fn importModule(name: []const u8, vm: *VM) anyerror!*PyObject {
    initImportSystem(vm.allocator);
    
    if (sys_modules.?.get(name)) |cached| {
        cached.incRef();
        return cached;
    }
    
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
    
    var module_globals = std.StringHashMap(*PyObject).init(vm.allocator);
    errdefer {
        var it = module_globals.iterator();
        while (it.next()) |entry| {
            vm.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.decRef(vm.mm);
        }
        module_globals.deinit();
    }
    
    const result = try vm.run(&code, &module_globals);
    result.decRef(vm.mm);
    
    const dict = try PyDictObject.create(vm.mm);
    defer dict.base.decRef(vm.mm);
    
    var it = module_globals.iterator();
    while (it.next()) |entry| {
        const key_str = try PyStringObject.create(entry.key_ptr.*, vm.mm);
        defer key_str.decRef(vm.mm);
        try dict.setItem(key_str, entry.value_ptr.*, vm.mm);
    }
    
    var clean_it = module_globals.iterator();
    while (clean_it.next()) |entry| {
        vm.allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.decRef(vm.mm);
    }
    module_globals.deinit();
    
    const name_str = try PyStringObject.create(name, vm.mm);
    defer name_str.decRef(vm.mm);
    const module_obj = try PyModuleObject.create(name_str, &dict.base, vm.mm);
    
    const name_copy = try vm.allocator.dupe(u8, name);
    module_obj.base.incRef();
    try sys_modules.?.put(name_copy, &module_obj.base);
    
    return &module_obj.base;
}
