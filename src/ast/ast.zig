const std = @import("std");

pub const Op = enum {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Pow,
    FloorDiv,
};

pub const CompareOp = enum {
    Lt,
    Le,
    Eq,
    Ne,
    Gt,
    Ge,
    Is,
    IsNot,
    In,
    NotIn,
};

pub const ConstantValue = union(enum) {
    None,
    Bool: bool,
    Int: i64,
    Float: f64,
    String: []const u8,
};

pub const ExceptHandler = struct {
    type_name: ?[]const u8,
    name: ?[]const u8,
    body: []AST,
};

pub const AST = union(enum) {
    Module: struct {
        body: []AST,
    },
    Assign: struct {
        target: []const u8,
        value: *AST,
    },
    AugAssign: struct {
        target: []const u8,
        op: Op,
        value: *AST,
    },
    BinOp: struct {
        op: Op,
        left: *AST,
        right: *AST,
    },
    Compare: struct {
        op: CompareOp,
        left: *AST,
        right: *AST,
    },
    Constant: ConstantValue,
    Name: []const u8,
    Print: struct {
        value: *AST,
    },
    If: struct {
        cond: *AST,
        body: []AST,
        orelse_body: []AST,
    },
    While: struct {
        cond: *AST,
        body: []AST,
    },
    For: struct {
        target: []const u8,
        iter: *AST,
        body: []AST,
    },
    Break: void,
    Continue: void,
    List: struct {
        elts: []AST,
    },
    Tuple: struct {
        elts: []AST,
    },
    Dict: struct {
        keys: []AST,
        values: []AST,
    },
    FunctionDef: struct {
        name: []const u8,
        args: [][]const u8,
        defaults: []AST,
        body: []AST,
    },
    Lambda: struct {
        args: [][]const u8,
        body: *AST,
    },
    Return: struct {
        value: ?*AST,
    },
    Call: struct {
        func: *AST,
        args: []AST,
    },
    Pass: void,
    ClassDef: struct {
        name: []const u8,
        base: ?[]const u8,
        body: []AST,
    },
    Attribute: struct {
        value: *AST,
        attr: []const u8,
    },
    AssignAttr: struct {
        value: *AST,
        attr: []const u8,
        expr: *AST,
    },
    Subscript: struct {
        value: *AST,
        index: *AST,
    },
    AssignSubscript: struct {
        value: *AST,
        index: *AST,
        expr: *AST,
    },
    Try: struct {
        body: []AST,
        handlers: []ExceptHandler,
        finalbody: []AST,
    },
    Raise: struct {
        exc: ?*AST,
    },
    Nonlocal: struct {
        names: [][]const u8,
    },
    Global: struct {
        names: [][]const u8,
    },
    Assert: struct {
        test_expr: *AST,
        msg: ?*AST,
    },
    Del: struct {
        target: *AST,
    },
    Import: struct {
        names: [][]const u8,
    },
    ImportFrom: struct {
        module: []const u8,
        names: [][]const u8,
    },
    LogicalOp: struct {
        op: enum { And, Or },
        left: *AST,
        right: *AST,
    },
    UnaryOp: struct {
        op: enum { Not, Neg },
        operand: *AST,
    },
};

// Helper struct to build AST nodes on an allocator.
pub const ASTBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ASTBuilder {
        return .{ .allocator = allocator };
    }

    pub fn newAST(self: ASTBuilder, node: AST) !*AST {
        const ptr = try self.allocator.create(AST);
        ptr.* = node;
        return ptr;
    }
};
