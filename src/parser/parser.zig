const std = @import("std");
const testing = std.testing;
const Lexer = @import("../lexer/lexer.zig").Lexer;
const Token = @import("../lexer/lexer.zig").Token;
const TokenType = @import("../lexer/lexer.zig").TokenType;
const AST = @import("../ast/ast.zig").AST;
const ASTBuilder = @import("../ast/ast.zig").ASTBuilder;
const Op = @import("../ast/ast.zig").Op;
const CompareOp = @import("../ast/ast.zig").CompareOp;
const ExceptHandler = @import("../ast/ast.zig").ExceptHandler;
const WithItem = @import("../ast/ast.zig").WithItem;
const Comprehension = @import("../ast/ast.zig").Comprehension;

pub const Parser = struct {
    lexer: *Lexer,
    current_token: Token,
    builder: ASTBuilder,

    const ParserState = struct {
        lexer_state: Lexer.State,
        current_token: Token,
    };

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator) Parser {
        var p = Parser{
            .lexer = lexer,
            .current_token = undefined,
            .builder = ASTBuilder.init(allocator),
        };
        p.advance();
        return p;
    }

    fn advance(self: *Parser) void {
        self.current_token = self.lexer.next();
    }

    fn peekType(self: Parser) TokenType {
        return self.current_token.type;
    }

    fn match(self: *Parser, t_type: TokenType) bool {
        if (self.peekType() == t_type) {
            self.advance();
            return true;
        }
        return false;
    }

    fn consume(self: *Parser, t_type: TokenType, err_msg: []const u8) !void {
        if (self.peekType() == t_type) {
            self.advance();
            return;
        }
        std.debug.print("Error at token '{s}' (line {d}, col {d}): {s}\n", .{self.current_token.lexeme, self.current_token.line, self.current_token.column, err_msg});
        return error.ParseError;
    }

    fn saveState(self: *Parser) ParserState {
        return .{
            .lexer_state = self.lexer.save(),
            .current_token = self.current_token,
        };
    }

    fn restoreState(self: *Parser, state: ParserState) void {
        self.lexer.restore(state.lexer_state);
        self.current_token = state.current_token;
    }

    fn peekNextType(self: *Parser) TokenType {
        const state = self.saveState();
        self.advance();
        const t = self.peekType();
        self.restoreState(state);
        return t;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.peekType() == .newline) {
            self.advance();
        }
    }

    fn parseBlock(self: *Parser) anyerror![]AST {
        self.skipNewlines();
        try self.consume(.indent, "Expect indented block");
        
        var stmts = std.ArrayList(AST).empty;
        errdefer stmts.deinit(self.builder.allocator);
        
        while (self.peekType() != .dedent and self.peekType() != .eof) {
            self.skipNewlines();
            if (self.peekType() == .dedent or self.peekType() == .eof) break;
            const stmt = try self.parseStatement();
            try stmts.append(self.builder.allocator, stmt);
            self.skipNewlines();
        }
        
        if (self.peekType() == .dedent) {
            self.advance();
        }
        
        return try stmts.toOwnedSlice(self.builder.allocator);
    }

    pub fn parseModule(self: *Parser) anyerror!AST {
        var stmts = std.ArrayList(AST).empty;
        errdefer stmts.deinit(self.builder.allocator);
        
        while (self.peekType() != .eof) {
            self.skipNewlines();
            if (self.peekType() == .eof) break;
            const stmt = try self.parseStatement();
            try stmts.append(self.builder.allocator, stmt);
            self.skipNewlines();
        }
        
        return AST{ .Module = .{
            .body = try stmts.toOwnedSlice(self.builder.allocator),
        } };
    }

    fn parseIfStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_if, "Expect 'if'");
        const cond = try self.parseExpression();
        try self.consume(.colon, "Expect ':' after if condition");
        const body = try self.parseBlock();
        
        var orelse_body: []AST = &[_]AST{};
        if (self.match(.kw_elif)) {
            // Re-parse as if statement
            const elif_cond = try self.parseExpression();
            try self.consume(.colon, "Expect ':' after elif condition");
            const elif_body = try self.parseBlock();
            
            var elif_orelse: []AST = &[_]AST{};
            if (self.peekType() == .kw_elif) {
                // Recursive elif
                const inner = try self.parseElifChain();
                var arr = try self.builder.allocator.alloc(AST, 1);
                arr[0] = inner;
                elif_orelse = arr;
            } else if (self.match(.kw_else)) {
                try self.consume(.colon, "Expect ':' after else");
                elif_orelse = try self.parseBlock();
            }
            
            var arr = try self.builder.allocator.alloc(AST, 1);
            arr[0] = AST{ .If = .{
                .cond = try self.builder.newAST(elif_cond),
                .body = elif_body,
                .orelse_body = elif_orelse,
            } };
            orelse_body = arr;
        } else if (self.match(.kw_else)) {
            try self.consume(.colon, "Expect ':' after else");
            orelse_body = try self.parseBlock();
        }
        
        return AST{ .If = .{
            .cond = try self.builder.newAST(cond),
            .body = body,
            .orelse_body = orelse_body,
        } };
    }

    fn parseElifChain(self: *Parser) anyerror!AST {
        try self.consume(.kw_elif, "Expect 'elif'");
        const cond = try self.parseExpression();
        try self.consume(.colon, "Expect ':' after elif condition");
        const body = try self.parseBlock();
        
        var orelse_body: []AST = &[_]AST{};
        if (self.peekType() == .kw_elif) {
            const inner = try self.parseElifChain();
            var arr = try self.builder.allocator.alloc(AST, 1);
            arr[0] = inner;
            orelse_body = arr;
        } else if (self.match(.kw_else)) {
            try self.consume(.colon, "Expect ':' after else");
            orelse_body = try self.parseBlock();
        }
        
        return AST{ .If = .{
            .cond = try self.builder.newAST(cond),
            .body = body,
            .orelse_body = orelse_body,
        } };
    }

    fn parseWhileStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_while, "Expect 'while'");
        const cond = try self.parseExpression();
        try self.consume(.colon, "Expect ':' after while condition");
        const body = try self.parseBlock();
        return AST{ .While = .{
            .cond = try self.builder.newAST(cond),
            .body = body,
        } };
    }

    fn parseForStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_for, "Expect 'for'");
        const target = self.current_token.lexeme;
        try self.consume(.identifier, "Expect loop variable name");
        try self.consume(.kw_in, "Expect 'in' after for variable");
        const iter = try self.parseExpression();
        try self.consume(.colon, "Expect ':' after for iterable");
        const body = try self.parseBlock();
        return AST{ .For = .{
            .target = try self.builder.allocator.dupe(u8, target),
            .iter = try self.builder.newAST(iter),
            .body = body,
        } };
    }

    fn parseFunctionDef(self: *Parser) anyerror!AST {
        try self.consume(.kw_def, "Expect 'def'");
        const name_tok = self.current_token;
        try self.consume(.identifier, "Expect function name");
        try self.consume(.lparen, "Expect '(' after function name");
        
        var args = std.ArrayList([]const u8).empty;
        var defaults = std.ArrayList(AST).empty;
        errdefer {
            for (args.items) |a| self.builder.allocator.free(a);
            args.deinit(self.builder.allocator);
            defaults.deinit(self.builder.allocator);
        }
        
        while (self.peekType() != .rparen) {
            const arg_name = self.current_token.lexeme;
            try self.consume(.identifier, "Expect parameter name");
            try args.append(self.builder.allocator, try self.builder.allocator.dupe(u8, arg_name));
            
            // Check for default value
            if (self.match(.equal)) {
                const default_val = try self.parseExpression();
                try defaults.append(self.builder.allocator, default_val);
            }
            
            if (self.peekType() == .comma) {
                self.advance();
            } else if (self.peekType() != .rparen) {
                std.debug.print("parseFunctionDef: unexpected token '{s}' ({s}) at line {d}, col {d}\n", .{self.current_token.lexeme, @tagName(self.peekType()), self.current_token.line, self.current_token.column});
                return error.ParseError;
            }
        }
        try self.consume(.rparen, "Expect ')' after parameters");
        try self.consume(.colon, "Expect ':' after function signature");
        const body = try self.parseBlock();

        return AST{ .FunctionDef = .{
            .name = try self.builder.allocator.dupe(u8, name_tok.lexeme),
            .args = try args.toOwnedSlice(self.builder.allocator),
            .defaults = try defaults.toOwnedSlice(self.builder.allocator),
            .body = body,
            .decorators = &[_]AST{},
        } };
    }

    fn parseReturnStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_return, "Expect 'return'");
        if (self.peekType() == .newline or self.peekType() == .dedent or self.peekType() == .eof) {
            return AST{ .Return = .{ .value = null } };
        }
        const expr = try self.parseExpression();
        return AST{ .Return = .{ .value = try self.builder.newAST(expr) } };
    }

    fn parseAssertStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_assert, "Expect 'assert'");
        const test_expr = try self.parseExpression();
        var msg: ?*AST = null;
        if (self.match(.comma)) {
            const msg_expr = try self.parseExpression();
            msg = try self.builder.newAST(msg_expr);
        }
        return AST{ .Assert = .{
            .test_expr = try self.builder.newAST(test_expr),
            .msg = msg,
        } };
    }

    fn parseDelStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_del, "Expect 'del'");
        // Parse a full expression (Name, Subscript, or Attribute)
        const target_expr = try self.parseExpression();
        // Normalize: if it's just a Name, we can use it directly; otherwise we need
        // the full expression tree for subscript/attribute deletion.
        return AST{ .Del = .{
            .target = try self.builder.newAST(target_expr),
        } };
    }

    fn parseGlobalStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_global, "Expect 'global'");
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| self.builder.allocator.free(name);
            names.deinit(self.builder.allocator);
        }
        while (true) {
            const name = self.current_token.lexeme;
            try self.consume(.identifier, "Expect variable name in global");
            try names.append(self.builder.allocator, try self.builder.allocator.dupe(u8, name));
            if (self.match(.comma)) {
                continue;
            }
            break;
        }
        return AST{ .Global = .{ .names = try names.toOwnedSlice(self.builder.allocator) } };
    }

    fn parseLambda(self: *Parser) anyerror!AST {
        try self.consume(.kw_lambda, "Expect 'lambda'");
        var args = std.ArrayList([]const u8).empty;
        errdefer {
            for (args.items) |a| self.builder.allocator.free(a);
            args.deinit(self.builder.allocator);
        }
        
        if (self.peekType() != .colon) {
            while (true) {
                const arg_name = self.current_token.lexeme;
                try self.consume(.identifier, "Expect parameter name in lambda");
                try args.append(self.builder.allocator, try self.builder.allocator.dupe(u8, arg_name));
                if (self.match(.comma)) {
                    continue;
                }
                break;
            }
        }
        try self.consume(.colon, "Expect ':' after lambda parameters");
        const body = try self.parseExpression();
        return AST{ .Lambda = .{
            .args = try args.toOwnedSlice(self.builder.allocator),
            .body = try self.builder.newAST(body),
        } };
    }

    fn parseStatement(self: *Parser) anyerror!AST {
        if (self.peekType() == .at) {
            return try self.parseDecoratedDef();
        }
        if (self.peekType() == .kw_if) {
            return try self.parseIfStatement();
        }
        if (self.peekType() == .kw_while) {
            return try self.parseWhileStatement();
        }
        if (self.peekType() == .kw_for) {
            return try self.parseForStatement();
        }
        if (self.peekType() == .kw_def) {
            return try self.parseFunctionDef();
        }
        if (self.peekType() == .kw_class) {
            return try self.parseClassDef();
        }
        if (self.peekType() == .kw_async) {
            self.advance(); // consume 'async'
            if (self.peekType() == .kw_def) {
                return try self.parseFunctionDef();
            }
            std.debug.print("Error: Expect 'def' after 'async'\n", .{});
            return error.ParseError;
        }
        if (self.peekType() == .kw_try) {
            return try self.parseTryStatement();
        }
        if (self.peekType() == .kw_with) {
            return try self.parseWithStatement();
        }
        if (self.peekType() == .kw_raise) {
            return try self.parseRaiseStatement();
        }
        if (self.peekType() == .kw_nonlocal) {
            return try self.parseNonlocalStatement();
        }
        if (self.peekType() == .kw_global) {
            return try self.parseGlobalStatement();
        }
        if (self.peekType() == .kw_import) {
            return try self.parseImportStatement();
        }
        if (self.peekType() == .kw_from) {
            return try self.parseImportFromStatement();
        }
        if (self.peekType() == .kw_return) {
            return try self.parseReturnStatement();
        }
        if (self.peekType() == .kw_assert) {
            return try self.parseAssertStatement();
        }
        if (self.peekType() == .kw_del) {
            return try self.parseDelStatement();
        }
        if (self.match(.kw_pass)) {
            return AST{ .Pass = {} };
        }
        if (self.match(.kw_break)) {
            return AST{ .Break = {} };
        }
        if (self.match(.kw_continue)) {
            return AST{ .Continue = {} };
        }

        // Try parsing Assignment: target = expr or target op= expr
        const state = self.saveState();
        if (self.peekType() == .identifier) {
            const target_expr = self.parsePrimary() catch blk: {
                self.restoreState(state);
                break :blk null;
            };
            if (target_expr) |t| {
                // Simple assignment
                if (self.match(.equal)) {
                    const expr = try self.parseExpression();
                    switch (t) {
                        .Name => |n| {
                            return AST{ .Assign = .{ .target = n, .value = try self.builder.newAST(expr) } };
                        },
                        .Attribute => |attr| {
                            return AST{ .AssignAttr = .{
                                .value = attr.value,
                                .attr = attr.attr,
                                .expr = try self.builder.newAST(expr),
                            } };
                        },
                        .Subscript => |sub| {
                            return AST{ .AssignSubscript = .{
                                .value = sub.value,
                                .index = sub.index,
                                .expr = try self.builder.newAST(expr),
                            } };
                        },
                        else => {
                            self.restoreState(state);
                        },
                    }
                }
                // Augmented assignment
                else if (self.peekType() == .plus_equal or
                         self.peekType() == .minus_equal or
                         self.peekType() == .star_equal or
                         self.peekType() == .slash_equal or
                         self.peekType() == .percent_equal or
                         self.peekType() == .double_star_equal or
                         self.peekType() == .double_slash_equal or
                         self.peekType() == .ampersand_equal or
                         self.peekType() == .vbar_equal or
                         self.peekType() == .caret_equal or
                         self.peekType() == .left_shift_equal or
                         self.peekType() == .right_shift_equal or
                         self.peekType() == .at_equal)
                {
                    const op: Op = switch (self.peekType()) {
                        .plus_equal => .Add,
                        .minus_equal => .Sub,
                        .star_equal => .Mul,
                        .slash_equal => .Div,
                        .percent_equal => .Mod,
                        .double_star_equal => .Pow,
                        .double_slash_equal => .FloorDiv,
                        .ampersand_equal => .And,
                        .vbar_equal => .Or,
                        .caret_equal => .Xor,
                        .left_shift_equal => .LShift,
                        .right_shift_equal => .RShift,
                        .at_equal => .MatMul,
                        else => unreachable,
                    };
                    self.advance(); // consume the augmented assignment token
                    const expr = try self.parseExpression();
                    switch (t) {
                        .Name => |n| {
                            return AST{ .AugAssign = .{ .target = n, .op = op, .value = try self.builder.newAST(expr) } };
                        },
                        else => {
                            self.restoreState(state);
                        },
                    }
                } else {
                    self.restoreState(state);
                }
            }
        } else {
            self.restoreState(state);
        }

        // Otherwise, it's just an expression statement
        const expr = try self.parseExpression();
        return AST{ .Expr = .{ .value = try self.builder.newAST(expr) } };
    }

    fn parseExpression(self: *Parser) anyerror!AST {
        // NamedExpr (walrus): identifier := value
        if (self.peekType() == .identifier and self.peekNextType() == .colon_equal) {
            const name = try self.builder.allocator.dupe(u8, self.current_token.lexeme);
            self.advance(); // consume name
            self.advance(); // consume :=
            const value = try self.parseExpression();
            return AST{ .NamedExpr = .{
                .target = name,
                .value = try self.builder.newAST(value),
            } };
        }
        // Yield / Yield From expression
        if (self.match(.kw_yield)) {
            if (self.match(.kw_from)) {
                const val = try self.parseExpression();
                return AST{ .YieldFrom = .{ .value = try self.builder.newAST(val) } };
            }
            var val: ?*AST = null;
            const next_tok = self.peekType();
            if (next_tok != .newline and next_tok != .rparen and next_tok != .rbracket and next_tok != .rbrace and next_tok != .colon and next_tok != .comma and next_tok != .semicolon and next_tok != .eof and next_tok != .dedent) {
                const yield_expr = try self.parseExpression();
                val = try self.builder.newAST(yield_expr);
            }
            return AST{ .Yield = .{ .value = val } };
        }
        // Check for lambda
        if (self.peekType() == .kw_lambda) {
            return try self.parseLambda();
        }
        return try self.parseOrTest();
    }

    fn parseOrTest(self: *Parser) anyerror!AST {
        var expr = try self.parseAndTest();
        while (true) {
            if (self.peekType() == .kw_or) {
                self.advance();
                const right = try self.parseAndTest();
                expr = AST{ .LogicalOp = .{
                    .op = .Or,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseAndTest(self: *Parser) anyerror!AST {
        var expr = try self.parseNotTest();
        while (true) {
            if (self.peekType() == .kw_and) {
                self.advance();
                const right = try self.parseNotTest();
                expr = AST{ .LogicalOp = .{
                    .op = .And,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseNotTest(self: *Parser) anyerror!AST {
        if (self.peekType() == .kw_not) {
            self.advance();
            const operand = try self.parseNotTest();
            return AST{ .UnaryOp = .{
                .op = .Not,
                .operand = try self.builder.newAST(operand),
            } };
        }
        return try self.parseComparison();
    }

    fn parseComparison(self: *Parser) anyerror!AST {
        var expr = try self.parseBitwiseOr();
        while (true) {
            const op: ?CompareOp = switch (self.peekType()) {
                .less => .Lt,
                .less_equal => .Le,
                .double_equal => .Eq,
                .not_equal => .Ne,
                .greater => .Gt,
                .greater_equal => .Ge,
                .kw_is => blk: {
                    self.advance();
                    if (self.peekType() == .kw_not) {
                        self.advance();
                        break :blk CompareOp.IsNot;
                    }
                    // Already consumed 'is'
                    const right = try self.parseBitwiseOr();
                    expr = AST{ .Compare = .{
                        .op = .Is,
                        .left = try self.builder.newAST(expr),
                        .right = try self.builder.newAST(right),
                    } };
                    continue;
                },
                .kw_not => blk: {
                    // "not in"
                    const save = self.saveState();
                    self.advance();
                    if (self.peekType() == .kw_in) {
                        self.advance();
                        break :blk CompareOp.NotIn;
                    }
                    self.restoreState(save);
                    break :blk null;
                },
                .kw_in => .In,
                else => null,
            };
            if (op) |cmp_op| {
                if (cmp_op != .Is and cmp_op != .IsNot and cmp_op != .NotIn) {
                    self.advance();
                }
                const right = try self.parseBitwiseOr();
                expr = AST{ .Compare = .{
                    .op = cmp_op,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseBitwiseOr(self: *Parser) anyerror!AST {
        var expr = try self.parseBitwiseXor();
        while (true) {
            if (self.match(.vbar)) {
                const right = try self.parseBitwiseXor();
                expr = AST{ .BinOp = .{
                    .op = .Or,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseBitwiseXor(self: *Parser) anyerror!AST {
        var expr = try self.parseBitwiseAnd();
        while (true) {
            if (self.match(.caret)) {
                const right = try self.parseBitwiseAnd();
                expr = AST{ .BinOp = .{
                    .op = .Xor,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseBitwiseAnd(self: *Parser) anyerror!AST {
        var expr = try self.parseShift();
        while (true) {
            if (self.match(.ampersand)) {
                const right = try self.parseShift();
                expr = AST{ .BinOp = .{
                    .op = .And,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseShift(self: *Parser) anyerror!AST {
        var expr = try self.parseTerm();
        while (true) {
            const op: ?Op = switch (self.peekType()) {
                .left_shift => .LShift,
                .right_shift => .RShift,
                else => null,
            };
            if (op) |bin_op| {
                self.advance();
                const right = try self.parseTerm();
                expr = AST{ .BinOp = .{
                    .op = bin_op,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseTerm(self: *Parser) anyerror!AST {
        var expr = try self.parseFactor();
        while (true) {
            const op: ?Op = switch (self.peekType()) {
                .plus => .Add,
                .minus => .Sub,
                else => null,
            };
            if (op) |bin_op| {
                self.advance();
                const right = try self.parseFactor();
                expr = AST{ .BinOp = .{
                    .op = bin_op,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseFactor(self: *Parser) anyerror!AST {
        var expr = try self.parseUnary();
        while (true) {
            const op: ?Op = switch (self.peekType()) {
                .star => .Mul,
                .slash => .Div,
                .percent => .Mod,
                .double_slash => .FloorDiv,
                .at => .MatMul,
                else => null,
            };
            if (op) |bin_op| {
                self.advance();
                const right = try self.parseUnary();
                expr = AST{ .BinOp = .{
                    .op = bin_op,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseUnary(self: *Parser) anyerror!AST {
        if (self.match(.minus)) {
            const operand = try self.parsePower();
            return AST{ .UnaryOp = .{
                .op = .Neg,
                .operand = try self.builder.newAST(operand),
            } };
        } else if (self.match(.tilde)) {
            const operand = try self.parsePower();
            return AST{ .UnaryOp = .{
                .op = .Invert,
                .operand = try self.builder.newAST(operand),
            } };
        } else if (self.match(.kw_await)) {
            const operand = try self.parsePower();
            return AST{ .Await = .{ .value = try self.builder.newAST(operand) } };
        } else if (self.match(.plus)) {
            return try self.parsePower();
        }
        return try self.parsePower();
    }

    fn parsePower(self: *Parser) anyerror!AST {
        var expr = try self.parsePrimary();
        if (self.peekType() == .double_star) {
            self.advance();
            const right = try self.parseUnary(); // right-associative
            expr = AST{ .BinOp = .{
                .op = .Pow,
                .left = try self.builder.newAST(expr),
                .right = try self.builder.newAST(right),
            } };
        }
        return expr;
    }

    fn parseComprehensionGenerators(self: *Parser) anyerror![]Comprehension {
        var generators = std.ArrayList(Comprehension).empty;
        errdefer {
            for (generators.items) |gen| {
                self.builder.allocator.free(gen.target);
                self.builder.allocator.free(gen.ifs);
            }
            generators.deinit(self.builder.allocator);
        }

        while (true) {
            try self.consume(.kw_for, "Expect 'for' in comprehension");
            const target = try self.builder.allocator.dupe(u8, self.current_token.lexeme);
            try self.consume(.identifier, "Expect loop variable in comprehension");
            try self.consume(.kw_in, "Expect 'in' in comprehension");
            const iter = try self.parseExpression();

            var ifs = std.ArrayList(AST).empty;
            errdefer ifs.deinit(self.builder.allocator);
            while (self.match(.kw_if)) {
                const cond = try self.parseExpression();
                try ifs.append(self.builder.allocator, cond);
            }

            try generators.append(self.builder.allocator, .{
                .target = target,
                .iter = try self.builder.newAST(iter),
                .ifs = try ifs.toOwnedSlice(self.builder.allocator),
            });

            if (self.peekType() != .kw_for) break;
        }

        return try generators.toOwnedSlice(self.builder.allocator);
    }

    fn parseBase(self: *Parser) anyerror!AST {
        if (self.match(.kw_None)) {
            return AST{ .Constant = .None };
        }
        if (self.match(.kw_True)) {
            return AST{ .Constant = .{ .Bool = true } };
        }
        if (self.match(.kw_False)) {
            return AST{ .Constant = .{ .Bool = false } };
        }
        if (self.peekType() == .number_int) {
            const val = try std.fmt.parseInt(i64, self.current_token.lexeme, 10);
            self.advance();
            return AST{ .Constant = .{ .Int = val } };
        }
        if (self.peekType() == .number_float) {
            const val = try std.fmt.parseFloat(f64, self.current_token.lexeme);
            self.advance();
            return AST{ .Constant = .{ .Float = val } };
        }
        if (self.peekType() == .number_complex) {
            const lexeme = self.current_token.lexeme;
            const stripped = lexeme[0 .. lexeme.len - 1];
            const val = try std.fmt.parseFloat(f64, stripped);
            self.advance();
            return AST{ .Constant = .{ .Complex = .{ .real = 0.0, .imag = val } } };
        }
        if (self.peekType() == .string) {
            const lexeme = self.current_token.lexeme;
            self.advance();
            return AST{ .Constant = .{ .String = lexeme } };
        }
        if (self.peekType() == .bytes) {
            const lexeme = self.current_token.lexeme;
            self.advance();
            return AST{ .Constant = .{ .Bytes = lexeme } };
        }
        if (self.peekType() == .identifier) {
            const name = self.current_token.lexeme;
            self.advance();
            return AST{ .Name = name };
        }

        // List literal or comprehension: [1, 2, 3] or [x for x in items]
        if (self.match(.lbracket)) {
            const first = try self.parseExpression();
            // Check for list comprehension: [expr for ...]
            if (self.peekType() == .kw_for) {
                const generators = try self.parseComprehensionGenerators();
                try self.consume(.rbracket, "Expect ']' after list comprehension");
                return AST{ .ListComp = .{
                    .elt = try self.builder.newAST(first),
                    .generators = generators,
                } };
            }
            var elts = std.ArrayList(AST).empty;
            errdefer elts.deinit(self.builder.allocator);
            try elts.append(self.builder.allocator, first);
            while (self.peekType() != .rbracket) {
                if (self.peekType() == .comma) {
                    self.advance();
                    if (self.peekType() == .rbracket) break;
                    const elt = try self.parseExpression();
                    try elts.append(self.builder.allocator, elt);
                } else {
                    std.debug.print("parseBase (list): unexpected token '{s}' ({s}) at line {d}, col {d}\n", .{self.current_token.lexeme, @tagName(self.peekType()), self.current_token.line, self.current_token.column});
                    return error.ParseError;
                }
            }
            try self.consume(.rbracket, "Expect ']'");
            return AST{ .List = .{ .elts = try elts.toOwnedSlice(self.builder.allocator) } };
        }

        // Tuple literal, grouped expression, or generator expression
        if (self.match(.lparen)) {
            if (self.match(.rparen)) {
                return AST{ .Tuple = .{ .elts = &[_]AST{} } };
            }
            const first = try self.parseExpression();
            // Check for generator expression: (expr for ...)
            if (self.peekType() == .kw_for) {
                const generators = try self.parseComprehensionGenerators();
                try self.consume(.rparen, "Expect ')' after generator expression");
                return AST{ .GeneratorExp = .{
                    .elt = try self.builder.newAST(first),
                    .generators = generators,
                } };
            }
            if (self.match(.comma)) {
                var elts = std.ArrayList(AST).empty;
                errdefer elts.deinit(self.builder.allocator);
                try elts.append(self.builder.allocator, first);
                while (self.peekType() != .rparen) {
                    const elt = try self.parseExpression();
                    try elts.append(self.builder.allocator, elt);
                    if (self.peekType() == .comma) {
                        self.advance();
                    } else if (self.peekType() != .rparen) {
                        std.debug.print("parseBase (tuple): unexpected token '{s}' ({s}) at line {d}, col {d}\n", .{self.current_token.lexeme, @tagName(self.peekType()), self.current_token.line, self.current_token.column});
                        return error.ParseError;
                    }
                }
                try self.consume(.rparen, "Expect ')'");
                return AST{ .Tuple = .{ .elts = try elts.toOwnedSlice(self.builder.allocator) } };
            } else {
                try self.consume(.rparen, "Expect ')'");
                return first;
            }
        }

        // Dict/Set literal or comprehension: { ... }
        if (self.match(.lbrace)) {
            if (self.peekType() == .rbrace) {
                try self.consume(.rbrace, "Expect '}'");
                return AST{ .Dict = .{
                    .keys = &[_]AST{},
                    .values = &[_]AST{},
                } };
            }
            
            const first = try self.parseExpression();
            if (self.match(.colon)) {
                // Dict literal or dict comprehension: {k: v} or {k: v for ...}
                const first_val = try self.parseExpression();
                if (self.peekType() == .kw_for) {
                    const generators = try self.parseComprehensionGenerators();
                    try self.consume(.rbrace, "Expect '}' after dict comprehension");
                    return AST{ .DictComp = .{
                        .key = try self.builder.newAST(first),
                        .value = try self.builder.newAST(first_val),
                        .generators = generators,
                    } };
                }
                var keys = std.ArrayList(AST).empty;
                var values = std.ArrayList(AST).empty;
                errdefer {
                    keys.deinit(self.builder.allocator);
                    values.deinit(self.builder.allocator);
                }
                try keys.append(self.builder.allocator, first);
                try values.append(self.builder.allocator, first_val);
                
                if (self.peekType() == .comma) {
                    self.advance();
                }
                
                while (self.peekType() != .rbrace) {
                    const k = try self.parseExpression();
                    try self.consume(.colon, "Expect ':' after key in dictionary literal");
                    const v = try self.parseExpression();
                    try keys.append(self.builder.allocator, k);
                    try values.append(self.builder.allocator, v);
                    if (self.peekType() == .comma) {
                        self.advance();
                    } else if (self.peekType() != .rbrace) {
                        std.debug.print("parseBase (dict): unexpected token '{s}' ({s}) at line {d}, col {d}\n", .{self.current_token.lexeme, @tagName(self.peekType()), self.current_token.line, self.current_token.column});
                        return error.ParseError;
                    }
                }
                try self.consume(.rbrace, "Expect '}'");
                return AST{ .Dict = .{
                    .keys = try keys.toOwnedSlice(self.builder.allocator),
                    .values = try values.toOwnedSlice(self.builder.allocator),
                } };
            } else {
                // Set literal/comprehension: {first, ...} or {expr for ...}
                if (self.peekType() == .kw_for) {
                    const generators = try self.parseComprehensionGenerators();
                    try self.consume(.rbrace, "Expect '}' after set comprehension");
                    return AST{ .SetComp = .{
                        .elt = try self.builder.newAST(first),
                        .generators = generators,
                    } };
                }
                var elts = std.ArrayList(AST).empty;
                errdefer elts.deinit(self.builder.allocator);
                try elts.append(self.builder.allocator, first);
                
                if (self.peekType() == .comma) {
                    self.advance();
                }
                
                while (self.peekType() != .rbrace) {
                    const elt = try self.parseExpression();
                    try elts.append(self.builder.allocator, elt);
                    if (self.peekType() == .comma) {
                        self.advance();
                    } else if (self.peekType() != .rbrace) {
                        std.debug.print("parseBase (set): unexpected token '{s}' ({s}) at line {d}, col {d}\n", .{self.current_token.lexeme, @tagName(self.peekType()), self.current_token.line, self.current_token.column});
                        return error.ParseError;
                    }
                }
                try self.consume(.rbrace, "Expect '}'");
                return AST{ .Set = .{
                    .elts = try elts.toOwnedSlice(self.builder.allocator),
                } };
            }
        }

        std.debug.print("parseBase: unexpected token '{s}' ({s}) at line {d}, col {d}\n", .{self.current_token.lexeme, @tagName(self.peekType()), self.current_token.line, self.current_token.column});
        return error.ParseError;
    }

    fn parsePrimary(self: *Parser) anyerror!AST {
        var expr = try self.parseBase();
        
        while (true) {
            if (self.match(.lparen)) {
                var args = std.ArrayList(AST).empty;
                errdefer args.deinit(self.builder.allocator);
                while (self.peekType() != .rparen) {
                    const arg = try self.parseExpression();
                    try args.append(self.builder.allocator, arg);
                    if (self.peekType() == .comma) {
                        self.advance();
                    } else if (self.peekType() != .rparen) {
                        std.debug.print("parsePrimary (call): unexpected token '{s}' ({s}) at line {d}, col {d}\n", .{self.current_token.lexeme, @tagName(self.peekType()), self.current_token.line, self.current_token.column});
                        return error.ParseError;
                    }
                }
                try self.consume(.rparen, "Expect ')' after arguments");
                expr = AST{ .Call = .{
                    .func = try self.builder.newAST(expr),
                    .args = try args.toOwnedSlice(self.builder.allocator),
                } };
            } else if (self.match(.dot)) {
                const name = self.current_token.lexeme;
                try self.consume(.identifier, "Expect attribute name after '.'");
                expr = AST{ .Attribute = .{
                    .value = try self.builder.newAST(expr),
                    .attr = try self.builder.allocator.dupe(u8, name),
                } };
            } else if (self.match(.lbracket)) {
                // Try to parse a slice (detected by ':')
                const first = if (self.peekType() == .colon) null else try self.parseExpression();
                if (self.match(.colon)) {
                    const stop = if (self.peekType() != .colon and self.peekType() != .rbracket) try self.parseExpression() else null;
                    const step: ?AST = if (self.match(.colon)) blk: {
                        if (self.peekType() != .rbracket) {
                            break :blk try self.parseExpression();
                        }
                        break :blk null;
                    } else null;
                    try self.consume(.rbracket, "Expect ']' after slice");
                    const start_ptr = if (first) |s| try self.builder.newAST(s) else null;
                    const stop_ptr = if (stop) |s| try self.builder.newAST(s) else null;
                    const step_ptr = if (step) |s| try self.builder.newAST(s) else null;
                    const slice = AST{ .Slice = .{ .start = start_ptr, .stop = stop_ptr, .step = step_ptr } };
                    expr = AST{ .Subscript = .{
                        .value = try self.builder.newAST(expr),
                        .index = try self.builder.newAST(slice),
                    } };
                } else {
                    try self.consume(.rbracket, "Expect ']' after subscript");
                    expr = AST{ .Subscript = .{
                        .value = try self.builder.newAST(expr),
                        .index = try self.builder.newAST(first.?),
                    } };
                }
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseClassDef(self: *Parser) anyerror!AST {
        try self.consume(.kw_class, "Expect 'class'");
        const name_tok = self.current_token;
        try self.consume(.identifier, "Expect class name");
        
        var base: ?[]const u8 = null;
        if (self.match(.lparen)) {
            if (self.peekType() == .identifier) {
                base = try self.builder.allocator.dupe(u8, self.current_token.lexeme);
                self.advance();
            }
            try self.consume(.rparen, "Expect ')' after base class");
        }
        try self.consume(.colon, "Expect ':' after class signature");
        const body = try self.parseBlock();
        
        return AST{ .ClassDef = .{
            .name = try self.builder.allocator.dupe(u8, name_tok.lexeme),
            .base = base,
            .body = body,
            .decorators = &[_]AST{},
        } };
    }

    fn parseDecoratedDef(self: *Parser) anyerror!AST {
        var decorators = std.ArrayList(AST).empty;
        errdefer decorators.deinit(self.builder.allocator);
        
        while (self.peekType() == .at) {
            self.advance(); // consume '@'
            const dec_expr = try self.parsePrimary();
            try self.consume(.newline, "Expect newline after decorator");
            try decorators.append(self.builder.allocator, dec_expr);
            self.skipNewlines();
        }
        
        if (self.peekType() == .kw_def) {
            var func = try self.parseFunctionDef();
            func.FunctionDef.decorators = try decorators.toOwnedSlice(self.builder.allocator);
            return func;
        } else if (self.peekType() == .kw_class) {
            var class_node = try self.parseClassDef();
            class_node.ClassDef.decorators = try decorators.toOwnedSlice(self.builder.allocator);
            return class_node;
        } else {
            std.debug.print("Error: Expect 'def' or 'class' after decorator\n", .{});
            return error.ParseError;
        }
    }

    fn parseTryStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_try, "Expect 'try'");
        try self.consume(.colon, "Expect ':' after try");
        const try_body = try self.parseBlock();
        
        var handlers = std.ArrayList(ExceptHandler).empty;
        errdefer {
            for (handlers.items) |h| {
                if (h.type_name) |t| self.builder.allocator.free(t);
                if (h.name) |n| self.builder.allocator.free(n);
                self.builder.allocator.free(h.body);
            }
            handlers.deinit(self.builder.allocator);
        }
        
        while (self.match(.kw_except)) {
            var type_name: ?[]const u8 = null;
            var as_name: ?[]const u8 = null;
            
            if (self.peekType() == .identifier) {
                type_name = try self.builder.allocator.dupe(u8, self.current_token.lexeme);
                self.advance();
                
                if (self.match(.kw_as)) {
                    as_name = try self.builder.allocator.dupe(u8, self.current_token.lexeme);
                    try self.consume(.identifier, "Expect identifier after 'as'");
                }
            }
            try self.consume(.colon, "Expect ':' after except");
            const handler_body = try self.parseBlock();
            
            try handlers.append(self.builder.allocator, .{
                .type_name = type_name,
                .name = as_name,
                .body = handler_body,
            });
        }
        
        var final_body: []AST = &[_]AST{};
        if (self.match(.kw_finally)) {
            try self.consume(.colon, "Expect ':' after finally");
            final_body = try self.parseBlock();
        }
        
        return AST{ .Try = .{
            .body = try_body,
            .handlers = try handlers.toOwnedSlice(self.builder.allocator),
            .finalbody = final_body,
        } };
    }

    fn parseRaiseStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_raise, "Expect 'raise'");
        var exc: ?*AST = null;
        if (self.peekType() != .newline and self.peekType() != .eof and self.peekType() != .dedent) {
            const expr = try self.parseExpression();
            exc = try self.builder.newAST(expr);
        }
        return AST{ .Raise = .{ .exc = exc } };
    }

    fn parseNonlocalStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_nonlocal, "Expect 'nonlocal'");
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| self.builder.allocator.free(name);
            names.deinit(self.builder.allocator);
        }
        while (true) {
            const name = self.current_token.lexeme;
            try self.consume(.identifier, "Expect variable name in nonlocal");
            try names.append(self.builder.allocator, try self.builder.allocator.dupe(u8, name));
            if (self.match(.comma)) {
                continue;
            }
            break;
        }
        return AST{ .Nonlocal = .{ .names = try names.toOwnedSlice(self.builder.allocator) } };
    }

    fn parseImportStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_import, "Expect 'import'");
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| self.builder.allocator.free(name);
            names.deinit(self.builder.allocator);
        }
        while (true) {
            const name = self.current_token.lexeme;
            try self.consume(.identifier, "Expect module name");
            try names.append(self.builder.allocator, try self.builder.allocator.dupe(u8, name));
            if (self.match(.comma)) {
                continue;
            }
            break;
        }
        return AST{ .Import = .{ .names = try names.toOwnedSlice(self.builder.allocator) } };
    }

    fn parseImportFromStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_from, "Expect 'from'");
        const mod_name = self.current_token.lexeme;
        try self.consume(.identifier, "Expect module name");
        try self.consume(.kw_import, "Expect 'import' after module");
        
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| self.builder.allocator.free(name);
            names.deinit(self.builder.allocator);
        }
        while (true) {
            const name = self.current_token.lexeme;
            try self.consume(.identifier, "Expect imported name");
            try names.append(self.builder.allocator, try self.builder.allocator.dupe(u8, name));
            if (self.match(.comma)) {
                continue;
            }
            break;
        }
        return AST{ .ImportFrom = .{
            .module = try self.builder.allocator.dupe(u8, mod_name),
            .names = try names.toOwnedSlice(self.builder.allocator),
        } };
    }

    fn parseWithStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_with, "Expect 'with'");
        
        var items = std.ArrayList(WithItem).empty;
        errdefer items.deinit(self.builder.allocator);
        
        while (true) {
            const context_expr = try self.parseExpression();
            var optional_vars: ?*AST = null;
            if (self.match(.kw_as)) {
                const target = try self.parseExpression();
                optional_vars = try self.builder.newAST(target);
            }
            try items.append(self.builder.allocator, .{
                .context_expr = context_expr,
                .optional_vars = optional_vars,
            });
            if (self.match(.comma)) {
                continue;
            }
            break;
        }
        
        try self.consume(.colon, "Expect ':' after with item(s)");
        const body = try self.parseBlock();
        
        return AST{ .With = .{
            .items = try items.toOwnedSlice(self.builder.allocator),
            .body = body,
        } };
    }
};

test "parser simple module, print and math" {
    const src =
        \\x = 10 + 5
        \\print(x)
    ;
    var lexer = Lexer.init(src);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    var parser = Parser.init(&lexer, arena.allocator());
    const module = try parser.parseModule();

    switch (module) {
        .Module => |mod| {
            try testing.expectEqual(@as(usize, 2), mod.body.len);
            
            // Check assignment
            switch (mod.body[0]) {
                .Assign => |assign| {
                    try testing.expectEqualStrings("x", assign.target);
                    switch (assign.value.*) {
                        .BinOp => |binop| {
                            try testing.expectEqual(Op.Add, binop.op);
                            try testing.expectEqual(@as(i64, 10), binop.left.*.Constant.Int);
                            try testing.expectEqual(@as(i64, 5), binop.right.*.Constant.Int);
                        },
                        else => return error.TestFailed,
                    }
                },
                else => return error.TestFailed,
            }

            // Check print (wrapped in Expr expression statement)
            switch (mod.body[1]) {
                .Expr => |expr_node| {
                    switch (expr_node.value.*) {
                        .Call => |call| {
                            try testing.expectEqualStrings("print", call.func.*.Name);
                            try testing.expectEqual(@as(usize, 1), call.args.len);
                            try testing.expectEqualStrings("x", call.args[0].Name);
                        },
                        else => return error.TestFailed,
                    }
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parser if and while" {
    const src =
        \\if x == 10:
        \\    pass
        \\else:
        \\    pass
        \\while x > 0:
        \\    x = x - 1
    ;
    var lexer = Lexer.init(src);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    var parser = Parser.init(&lexer, arena.allocator());
    const module = try parser.parseModule();
    
    switch (module) {
        .Module => |mod| {
            try testing.expectEqual(@as(usize, 2), mod.body.len);
            try testing.expect(mod.body[0] == .If);
            try testing.expect(mod.body[1] == .While);
        },
        else => return error.TestFailed,
    }
}
