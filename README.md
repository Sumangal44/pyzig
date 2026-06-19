# pyzig

`pyzig` is a complete, production-grade, high-performance Python 3.14+ compatible interpreter written from scratch in Zig. It features a custom PEG parser, a compiler targeting custom bytecode, and a flat non-recursive virtual machine with manual reference-counted memory management.

---

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Supported Python Features](#supported-python-features)
   - [Primitive Types](#primitive-types)
   - [Collections](#collections)
   - [Control Flow](#control-flow)
   - [Functions & Closures](#functions--closures)
   - [Object-Oriented Programming (OOP)](#object-oriented-programming-oop)
   - [Exception Handling](#exception-handling)
   - [Import System](#import-system)
   - [Built-in Functions](#built-in-functions)
3. [Building and Getting Started](#building-and-getting-started)
   - [Prerequisites](#prerequisites)
   - [Compiling](#compiling)
   - [Running Tests](#running-tests)
4. [How to Use](#how-to-use)
   - [Interactive REPL](#interactive-repl)
   - [Executing Scripts](#executing-scripts)
   - [Executing Inline Code](#executing-inline-code)
5. [Memory Management & GC](#memory-management--gc)

---

## Architecture Overview

`pyzig` is designed for low startup latency and efficient memory usage. Its architecture is divided into three key layers:

```
[Source Code] ──> [Lexer & PEG Parser] ──> [AST]
                                            │
                                            ▼
[Flat VM Loop] <── [Custom Bytecode] <── [Compiler]
  ├── Frame Stack (Max Depth 64)
  ├── Exception Block Stack
  └── PyMemoryManager (Ref Counting)
```

1. **Frontend (Lexer & PEG Parser)**:
   - **Lexer**: Performs tokenization supporting Python indentation blocks (INDENT/DEDENT), unicode identifiers, string/number literals, line continuations, and comments.
   - **Parser**: A backtracking parser that processes expression precedence and parses complex statement hierarchies into a structured Abstract Syntax Tree (AST).
2. **Compiler**:
   - Performs lexical scope analysis to distinguish between local, global, and free variables.
   - Emits optimized bytecode instructions (e.g., cell-wrapping operations for closures).
   - Manages constants and name pools.
3. **Virtual Machine (VM)**:
   - Evaluates instructions iteratively in a flat non-recursive loop, avoiding host call-stack overflow.
   - Utilizes a pre-allocated stack of 64 `PyFrameObject` structures.
   - Handles exceptions using a 16-element try-except-finally block stack per frame.
4. **Memory Manager (`PyMemoryManager`)**:
   - Manages object lifecycles using manual reference counting (`incRef` and `decRef`).
   - Ensures memory safety and implements deallocation hooks (`tp_dealloc`) on type descriptors.

---

## Supported Python Features

### Primitive Types
- `None` (`NoneType`)
- Booleans (`True`, `False`)
- Integers (64-bit signed representation)
- Floats (64-bit float representation)
- Strings (immutable UTF-8 sequence with slice representation)

### Collections
- **Lists**: Resizable dynamic arrays of Python objects.
  ```python
  x = [1, 2, 3]
  x.append(4)
  print(x) # [1, 2, 3, 4]
  ```
- **Tuples**: Immutable, inline-allocated arrays.
  ```python
  y = (5, 6)
  print(y) # (5, 6)
  ```
- **Dictionaries**: Modern CPython-like ordered split-table design using open addressing, hash-collision probing, and FNV-1a hashing.
  ```python
  z = {"a": 1, "b": 2}
  print(z["a"]) # 1
  ```

### Control Flow
- Conditional branching:
  ```python
  if x < 10:
      print("small")
  elif x < 20:
      print("medium")
  else:
      print("large")
  ```
- Iteration:
  ```python
  i = 0
  while i < 3:
      print(i)
      i = i + 1
  ```
- Logical operators (`and`, `or`, `not`).

### Functions & Closures
- Positional argument binding and lexical local scoping.
- **Closures**: Full support for `nonlocal` variable access and modification using cell references (`PyCellObject`).
  ```python
  def make_counter():
      count = 0
      def increment():
          nonlocal count
          count = count + 1
          return count
      return increment

  counter = make_counter()
  print(counter()) # 1
  print(counter()) # 2
  ```

### Object-Oriented Programming (OOP)
- Class definitions and single inheritance.
- Automatic method binding (`PyMethodObject`) mapping `self` to instance invocations.
- Attribute lookup hierarchy (instance dictionary -> class dictionary -> parent class dictionary).
  ```python
  class Animal:
      def __init__(self, name):
          self.name = name
      def speak(self):
          print(self.name)

  class Dog(Animal):
      def speak(self):
          print("Woof: " + self.name)

  rex = Dog("Rex")
  rex.speak() # Prints "Woof: Rex"
  ```

### Exception Handling
- Custom exception types inheriting from `Exception`.
- Block stack unwinding supporting `try...except...finally` blocks.
  ```python
  class MathError(Exception):
      pass

  def safe_divide(a, b):
      if b == 0:
          raise MathError("division by zero")
      return a + b

  try:
      safe_divide(5, 0)
  except MathError:
      print("Caught MathError!")
  ```

### Import System
- Dynamic search and loading of `.py` files inside the execution directory.
- Execution in isolated module namespaces (`PyModuleObject`).
- Cache tracking in a global `sys_modules` table to prevent duplicate execution.
  ```python
  import math_util
  print(math_util.constant)

  from math_util import add
  print(add(10, 20))
  ```

### Built-in Functions
- `print(*args)`: Outputs text representations to standard output.
- `len(x)`: Returns the item count of a list, tuple, dict, or string.
- `range(stop)` / `range(start, stop)`: Generates list intervals.
- `type(x)`: Inspects and returns the type wrapper of an object.
- Type converters: `str(x)`, `int(x)`, `float(x)`, `list(x)`, `tuple(x)`, `dict(x)`.
- Helpers: `abs(x)`, `max(x)`, `min(x)`, `sum(x)`.

---

## Building and Getting Started

### Prerequisites
- [Zig Compiler](https://ziglang.org/) (Version `0.13.0` or higher recommended).

### Compiling
Build the optimized executable:
```bash
zig build -Doptimize=ReleaseFast
```
The output binary will be located at:
`./zig-out/bin/pyzig`

### Running Tests
Execute the unit and integration test suite (covering primitives, parser, VM frame structures, closures, and collections):
```bash
zig build test
```

---

## How to Use

### Interactive REPL
Start an interactive Python session:
```bash
./zig-out/bin/pyzig
```
Example session:
```
pyzig 0.1.0 (Phase 1) - Python 3.14+ in Zig
Type "exit" or "exit()" to exit.
>>> x = [10, 20]
>>> x.append(30)
>>> print(len(x))
3
>>> exit()
```

### Executing Scripts
Run a Python source file directly:
```bash
./zig-out/bin/pyzig test_phase3.py
```

### Executing Inline Code
Pass a Python statement as an inline string:
```bash
./zig-out/bin/pyzig -c "print(2 ** 10)"
```

---

## Memory Management & GC

`pyzig` operates without a traditional stop-the-world tracing garbage collector. Instead, it relies on strict reference counting.
- Every Python object wrapper inherits from `PyObject` containing a `refcnt` field.
- Reference ownership transfers are explicitly managed at the VM instruction level.
- High-level containers (like Lists, Dicts, and Modules) recursively decref their elements during destruction (`tp_dealloc`).
- Zig-native memory allocations are safely tracked in the debug allocator, reporting any unfreed byte upon execution teardown.
