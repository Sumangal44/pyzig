const std = @import("std");
const Lexer = @import("lexer/lexer.zig").Lexer;
const Parser = @import("parser/parser.zig").Parser;
const Compiler = @import("compiler/compiler.zig").Compiler;
const VM = @import("vm/vm.zig").VM;
const PyMemoryManager = @import("memory/allocator.zig").PyMemoryManager;
const primitives = @import("objects/primitives.zig");
const PyNone = primitives.PyNone;

fn executeString(
    gpa: std.mem.Allocator,
    mm: *PyMemoryManager,
    source: []const u8,
    stdout_writer: *std.Io.Writer,
    vm: *VM,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    var lexer = Lexer.init(source);
    var parser = Parser.init(&lexer, temp_allocator);
    const module_ast = parser.parseModule() catch |err| {
        try stdout_writer.print("SyntaxError: invalid syntax\n", .{});
        return err;
    };

    var compiler = Compiler.init(temp_allocator, mm);
    defer compiler.deinit();

    var code = compiler.compile(&module_ast) catch |err| {
        try stdout_writer.print("CompilerError: failed to compile code\n", .{});
        return err;
    };
    defer code.deinit(temp_allocator, mm);

    const result = try vm.run(&code, null);
    result.decRef(mm);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Setup stdout writer
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    defer stdout_file_writer.flush() catch {};

    var mm = PyMemoryManager.init(allocator);
    defer {
        mm.deinit();
        if (mm.allocated_bytes > 0) {
            std.debug.print("[pyzig memory leak check] Warning: leaked {d} bytes, {d} objects!\n", .{mm.allocated_bytes, mm.object_count});
        }
    }

    var args = init.minimal.args.iterate();
    // Skip executable name
    _ = args.next();

    var run_repl = true;
    var run_code_str: ?[]const u8 = null;
    var run_file_path: ?[]const u8 = null;
    var diagnostic_mode: VM.DiagnosticMode = .none;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c")) {
            if (args.next()) |code_str| {
                run_code_str = code_str;
                run_repl = false;
            } else {
                try stdout_writer.print("Error: -c option requires an argument\n", .{});
                try stdout_writer.flush();
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--hinglish")) {
            diagnostic_mode = .hinglish;
        } else if (std.mem.eql(u8, arg, "--jugaad")) {
            diagnostic_mode = .jugaad;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stdout_writer.print("Unknown option: {s}\n", .{arg});
            try stdout_writer.flush();
            std.process.exit(1);
        } else {
            run_file_path = arg;
            run_repl = false;
        }
    }

    // Initialize the VM with the stdout writer, memory manager, and IO context
    var vm = try VM.init(allocator, &mm, stdout_writer, io);
    vm.diagnostic_mode = diagnostic_mode;
    defer vm.deinit();

    // Populate sys.argv list
    {
        const collections = @import("objects/collections.zig");
        const sys_argv = try collections.PyListObject.create(0, &mm);
        errdefer sys_argv.base.decRef(&mm);

        var args_it = init.minimal.args.iterate();
        _ = args_it.next(); // Skip executable

        var has_added_first = false;
        while (args_it.next()) |arg| {
            if (!has_added_first) {
                if (std.mem.eql(u8, arg, "-c")) {
                    const py_arg = try primitives.PyStringObject.create("-c", &mm);
                    defer py_arg.decRef(&mm);
                    try sys_argv.append(py_arg, &mm);
                    has_added_first = true;
                    _ = args_it.next(); // Skip code string
                } else if (std.mem.startsWith(u8, arg, "-")) {
                    // Skip interpreter flags
                } else {
                    const py_arg = try primitives.PyStringObject.create(arg, &mm);
                    defer py_arg.decRef(&mm);
                    try sys_argv.append(py_arg, &mm);
                    has_added_first = true;
                }
            } else {
                const py_arg = try primitives.PyStringObject.create(arg, &mm);
                defer py_arg.decRef(&mm);
                try sys_argv.append(py_arg, &mm);
            }
        }
        if (!has_added_first) {
            const py_arg = try primitives.PyStringObject.create("", &mm);
            defer py_arg.decRef(&mm);
            try sys_argv.append(py_arg, &mm);
        }

        // Initialize import system and set sys.argv
        const import_system = @import("import_system/import.zig");
        try import_system.initImportSystem(allocator, &mm);
        import_system.setSysArgv(&sys_argv.base);
    }

    if (run_code_str) |code| {
        executeString(allocator, &mm, code, stdout_writer, &vm) catch |err| {
            try stdout_writer.print("Error: {any}\n", .{err});
            try stdout_writer.flush();
            std.process.exit(1);
        };
    } else if (run_file_path) |file_path| {
        const cwd = std.Io.Dir.cwd();
        var file = cwd.openFile(io, file_path, .{ .mode = .read_only }) catch {
            try stdout_writer.print("FileNotFoundError: [Errno 2] No such file or directory: '{s}'\n", .{file_path});
            try stdout_writer.flush();
            std.process.exit(1);
        };
        defer file.close(io);

        var buf: [1024]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        const reader = &file_reader.interface;

        const content = try reader.allocRemaining(allocator, .unlimited);
        defer allocator.free(content);

        executeString(allocator, &mm, content, stdout_writer, &vm) catch |err| {
            try stdout_writer.print("Error: {any}\n", .{err});
            try stdout_writer.flush();
            std.process.exit(1);
        };
    } else if (run_repl) {
        try stdout_writer.print("pyzig 0.1.0 (Phase 1) - Python 3.14+ in Zig\n", .{});
        try stdout_writer.print("Type \"exit\" or \"exit()\" to exit.\n", .{});
        try stdout_writer.flush();

        var stdin_buffer: [1024]u8 = undefined;
        var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
        const stdin_reader = &stdin_file_reader.interface;

        while (true) {
            try stdout_writer.print(">>> ", .{});
            try stdout_writer.flush();

            var line_writer = std.Io.Writer.Allocating.init(allocator);
            defer line_writer.deinit();

            _ = stdin_reader.streamDelimiter(&line_writer.writer, '\n') catch |err| {
                if (err == error.EndOfStream) break;
                try stdout_writer.print("ReadError: {any}\n", .{err});
                try stdout_writer.flush();
                break;
            };

            const line = line_writer.written();
            const line_str = std.mem.trim(u8, line, " \r\n");
            if (std.mem.eql(u8, line_str, "exit") or std.mem.eql(u8, line_str, "exit()")) {
                break;
            }
            if (line_str.len == 0) continue;

            executeString(allocator, &mm, line_str, stdout_writer, &vm) catch |err| {
                try stdout_writer.print("Error: {any}\n", .{err});
                try stdout_writer.flush();
            };
        }
    }
}

test {
    _ = @import("memory/allocator.zig");
    _ = @import("objects/object.zig");
    _ = @import("objects/primitives.zig");
    _ = @import("objects/collections.zig");
    _ = @import("objects/function.zig");
    _ = @import("objects/class.zig");
    _ = @import("objects/exception.zig");
    _ = @import("objects/cell.zig");
    _ = @import("import_system/import.zig");
    _ = @import("stdlib/builtins.zig");
    _ = @import("lexer/lexer.zig");
    _ = @import("parser/parser.zig");
    _ = @import("ast/ast.zig");
    _ = @import("bytecode/bytecode.zig");
    _ = @import("compiler/compiler.zig");
    _ = @import("vm/vm.zig");
}





