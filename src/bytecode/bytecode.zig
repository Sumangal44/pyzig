const std = @import("std");
const PyObject = @import("../objects/object.zig").PyObject;
const PyTypeObject = @import("../objects/object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;

pub const Opcode = enum(u8) {
    LOAD_CONST,
    STORE_NAME,
    LOAD_NAME,
    BINARY_ADD,
    BINARY_SUB,
    BINARY_MUL,
    BINARY_DIV,
    BINARY_MOD,
    BINARY_POW,
    BINARY_FLOOR_DIV,
    COMPARE_OP,
    PRINT_EXPR,
    RETURN_VALUE,
    
    // Phase 2 opcodes
    JUMP_FORWARD,
    JUMP_BACKWARD,
    POP_JUMP_IF_FALSE,
    POP_JUMP_IF_TRUE,
    BUILD_LIST,
    BUILD_TUPLE,
    BUILD_MAP,
    BUILD_SET,
    BUILD_SLICE,
    MAKE_FUNCTION,
    CALL,
    
    // Phase 3 opcodes
    LOAD_ATTR,
    STORE_ATTR,
    LOAD_METHOD,
    CALL_METHOD,
    SETUP_FINALLY,
    POP_BLOCK,
    RAISE_VARARGS,
    LOAD_CLOSURE,
    LOAD_DEREF,
    STORE_DEREF,
    IMPORT_NAME,
    IMPORT_FROM,
    POP_TOP,
    CHECK_EXCEPTION,
    LOAD_FAST,
    STORE_FAST,
    UNARY_NOT,
    JUMP_IF_FALSE_OR_POP,
    JUMP_IF_TRUE_OR_POP,
    
    // Phase 4 opcodes — full Python feature set
    UNARY_NEG,
    GET_ITER,
    FOR_ITER,
    BINARY_SUBSCR,
    STORE_SUBSCR,
    DELETE_NAME,
    DELETE_FAST,
    DELETE_SUBSCR,
    DELETE_ATTR,
    IS_OP,         // arg=0 for `is`, arg=1 for `is not`
    CONTAINS_OP,   // arg=0 for `in`, arg=1 for `not in`
    BINARY_AND,
    BINARY_OR,
    BINARY_XOR,
    BINARY_LSHIFT,
    BINARY_RSHIFT,
    BINARY_MATRIX_MULTIPLY,
    UNARY_INVERT,
    BEFORE_WITH,
    YIELD_VALUE,
    EXIT_WITH,

    // Phase 5 opcodes — *args/**kwargs, unpacking, augmented attr/subscr
    UNPACK_SEQUENCE,       // arg = expected count; pop iterable, push N items
    CALL_EX,              // arg = has_kwargs (0 or 1); TOS[0]=callable, TOS[1]=args tuple, TOS[2]=kwargs dict if has_kwargs
    LIST_EXTEND,           // extend list at TOS[arg] with iterable at TOS
    DICT_MERGE,            // merge dict at TOS[arg] with dict at TOS
    STORE_SUBSCR_AUG,      // for d[k] op= v  (load + op + store in one sequence)
    STORE_ATTR_AUG,        // for obj.attr op= v
    SWAP,                  // swaps TOS and TOS1
    CALL_KW,               // call with kwargs, TOS is tuple of kw names
    BUILD_TUPLE_UNPACK,    // pop arg iterables, build tuple
    BUILD_LIST_UNPACK,     // pop arg iterables, build list
    BUILD_SET_UNPACK,      // pop arg iterables, build set
};

pub const Instruction = struct {
    op: Opcode,
    arg: u16 = 0,
};

pub const PyCodeObject = struct {
    instructions: []Instruction,
    consts: []*PyObject,
    names: [][]const u8,
    argcount: usize = 0,
    varnames: [][]const u8 = &[_][]const u8{},
    is_generator: bool = false,
    vararg_name: ?[]const u8 = null,  // name for *args parameter
    kwarg_name: ?[]const u8 = null,   // name for **kwargs parameter
    kwonlycount: usize = 0,            // number of keyword-only args (after vararg)

    pub fn deinit(self: *PyCodeObject, allocator: std.mem.Allocator, mm: *PyMemoryManager) void {
        allocator.free(self.instructions);
        for (self.consts) |c| {
            c.decRef(mm);
        }
        allocator.free(self.consts);
        for (self.names) |name| {
            allocator.free(name);
        }
        allocator.free(self.names);
        for (self.varnames) |name| {
            allocator.free(name);
        }
        if (self.varnames.len > 0) {
            allocator.free(self.varnames);
        }
        if (self.vararg_name) |va| {
            allocator.free(va);
        }
        if (self.kwarg_name) |ka| {
            allocator.free(ka);
        }
    }
};

pub const PyCodeObjectWrapper = extern struct {
    base: PyObject,
    code: *PyCodeObject,
    
    pub fn create(code: *PyCodeObject, mm: *PyMemoryManager) !*PyObject {
        const obj = try mm.alloc(PyCodeObjectWrapper);
        obj.* = .{
            .base = PyObject.init(&PyCode_Type),
            .code = code,
        };
        return &obj.base;
    }
};

pub const PyCode_Type = PyTypeObject{
    .name = "code",
    .tp_dealloc = code_dealloc,
};

fn code_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyCodeObjectWrapper);
    obj.code.deinit(mm.allocator, mm);
    mm.allocator.destroy(obj.code);
    mm.free(PyCodeObjectWrapper, obj);
}
