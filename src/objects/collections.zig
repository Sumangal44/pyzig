const std = @import("std");
const testing = std.testing;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyObject = @import("object.zig").PyObject;
const PyTypeObject = @import("object.zig").PyTypeObject;
const primitives = @import("primitives.zig");
const PyNone = primitives.PyNone;
const PyTrue = primitives.PyTrue;
const PyFalse = primitives.PyFalse;
const PyStringObject = primitives.PyStringObject;
const PyIntObject = primitives.PyIntObject;
const PyInt_Type = primitives.PyInt_Type;
const PyFloat_Type = primitives.PyFloat_Type;
const PyString_Type = primitives.PyString_Type;
const CompareOp = @import("object.zig").CompareOp;

// --- Helper for Repr ---
fn get_repr(item: *PyObject, mm: *PyMemoryManager) !*PyObject {
    if (item.type_obj.tp_repr) |repr_fn| {
        return try repr_fn(item, mm);
    }
    return try PyStringObject.create(item.type_obj.name, mm);
}

// --- Tuple Object ---
pub const PyTupleObject = extern struct {
    base: PyObject,
    size: usize,

    pub fn items(self: *PyTupleObject) []*PyObject {
        const ptr: [*]*PyObject = @ptrCast(@alignCast(@as([*]u8, @ptrCast(self)) + @sizeOf(PyTupleObject)));
        return ptr[0..self.size];
    }

    pub fn create(size: usize, mm: *PyMemoryManager) !*PyTupleObject {
        const total_bytes = @sizeOf(PyTupleObject) + size * @sizeOf(*PyObject);
        const bytes = try mm.allocBytes(total_bytes);
        const self: *PyTupleObject = @ptrCast(@alignCast(bytes.ptr));
        self.* = .{
            .base = PyObject.init(&PyTuple_Type),
            .size = size,
        };
        const slice = self.items();
        for (0..size) |i| {
            PyNone.incRef();
            slice[i] = PyNone;
        }
        return self;
    }
};

pub const PyTuple_Type = PyTypeObject{
    .name = "tuple",
    .tp_dealloc = tuple_dealloc,
    .tp_repr = tuple_repr,
    .tp_str = tuple_repr,
};

fn tuple_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyTupleObject);
    for (obj.items()) |item| {
        item.decRef(mm);
    }
    const total_bytes = @sizeOf(PyTupleObject) + obj.size * @sizeOf(*PyObject);
    mm.freeBytes(@as([*]u8, @ptrCast(obj))[0..total_bytes]);
}

fn tuple_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyTupleObject);
    if (obj.size == 0) {
        return try PyStringObject.create("()", mm);
    }
    var alloc_writer = std.Io.Writer.Allocating.init(mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    
    try writer.writeAll("(");
    for (0..obj.size) |i| {
        if (i > 0) try writer.writeAll(", ");
        const item = obj.items()[i];
        const repr_val = try get_repr(item, mm);
        defer repr_val.decRef(mm);
        try writer.writeAll(repr_val.as(PyStringObject).value());
    }
    if (obj.size == 1) {
        try writer.writeAll(",");
    }
    try writer.writeAll(")");
    return try PyStringObject.create(alloc_writer.written(), mm);
}

// --- List Object ---
pub const PyListObject = extern struct {
    base: PyObject,
    items: ?[*]*PyObject,
    size: usize,
    capacity: usize,

    pub fn create(capacity: usize, mm: *PyMemoryManager) !*PyListObject {
        const obj = try mm.alloc(PyListObject);
        obj.* = .{
            .base = PyObject.init(&PyList_Type),
            .items = null,
            .size = 0,
            .capacity = capacity,
        };
        if (capacity > 0) {
            const bytes = try mm.allocBytes(capacity * @sizeOf(*PyObject));
            obj.items = @ptrCast(@alignCast(bytes.ptr));
        }
        return obj;
    }

    pub fn append(self: *PyListObject, item: *PyObject, mm: *PyMemoryManager) !void {
        if (self.size >= self.capacity) {
            const new_capacity = if (self.capacity == 0) 4 else self.capacity * 2;
            const new_bytes = try mm.allocBytes(new_capacity * @sizeOf(*PyObject));
            const new_items: [*]*PyObject = @ptrCast(@alignCast(new_bytes.ptr));
            
            if (self.size > 0) {
                if (self.items) |items| {
                    @memcpy(new_items[0..self.size], items[0..self.size]);
                    mm.freeBytes(@as([*]u8, @ptrCast(items))[0..(self.capacity * @sizeOf(*PyObject))]);
                }
            }
            self.items = new_items;
            self.capacity = new_capacity;
        }
        item.incRef();
        self.items.?[self.size] = item;
        self.size += 1;
    }
};

pub const PyList_Type = PyTypeObject{
    .name = "list",
    .tp_dealloc = list_dealloc,
    .tp_repr = list_repr,
    .tp_str = list_repr,
};

fn list_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyListObject);
    if (obj.items) |items| {
        for (0..obj.size) |i| {
            items[i].decRef(mm);
        }
        mm.freeBytes(@as([*]u8, @ptrCast(items))[0..(obj.capacity * @sizeOf(*PyObject))]);
    }
    mm.free(PyListObject, obj);
}

fn list_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyListObject);
    if (obj.size == 0) {
        return try PyStringObject.create("[]", mm);
    }
    var alloc_writer = std.Io.Writer.Allocating.init(mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    
    try writer.writeAll("[");
    if (obj.items) |items| {
        for (0..obj.size) |i| {
            if (i > 0) try writer.writeAll(", ");
            const item = items[i];
            const repr_val = try get_repr(item, mm);
            defer repr_val.decRef(mm);
            try writer.writeAll(repr_val.as(PyStringObject).value());
        }
    }
    try writer.writeAll("]");
    return try PyStringObject.create(alloc_writer.written(), mm);
}

// --- Dict Object ---
pub const PyDictEntry = extern struct {
    hash: i64,
    key: ?*PyObject,
    value: ?*PyObject,
};

pub const PyDictObject = extern struct {
    base: PyObject,
    indices: [*]i32,
    indices_size: usize,
    entries: [*]PyDictEntry,
    entries_size: usize,
    entries_capacity: usize,
    active_count: usize,

    pub fn create(mm: *PyMemoryManager) !*PyDictObject {
        const obj = try mm.alloc(PyDictObject);
        obj.* = .{
            .base = PyObject.init(&PyDict_Type),
            .indices = undefined,
            .indices_size = 0,
            .entries = undefined,
            .entries_size = 0,
            .entries_capacity = 0,
            .active_count = 0,
        };
        return obj;
    }

    fn hashObject(key: *PyObject) !i64 {
        if (key.type_obj.tp_hash) |hash_fn| {
            return try hash_fn(key);
        }
        return error.TypeError;
    }

    fn keysEqual(a: *PyObject, b: *PyObject, mm: *PyMemoryManager) !bool {
        if (a == b) return true;
        if (a.type_obj.tp_richcompare) |cmp_fn| {
            const res = try cmp_fn(a, b, .Eq, mm);
            defer res.decRef(mm);
            return res == PyTrue;
        }
        return false;
    }

    fn lookup(self: *PyDictObject, key: *PyObject, hash: i64, mm: *PyMemoryManager) !?usize {
        if (self.indices_size == 0) return null;
        const mask = self.indices_size - 1;
        var idx = @as(usize, @truncate(@as(u64, @bitCast(hash)))) & mask;
        var perturb = @as(u64, @bitCast(hash));
        
        while (true) {
            const entry_idx = self.indices[idx];
            if (entry_idx == -1) {
                return idx;
            } else if (entry_idx == -2) {
                // deleted slot, continue probing
            } else {
                const entry = &self.entries[@intCast(entry_idx)];
                if (entry.hash == hash and try keysEqual(entry.key.?, key, mm)) {
                    return idx;
                }
            }
            idx = (idx * 5 + perturb + 1) & mask;
            perturb >>= 5;
        }
    }

    pub fn setItem(self: *PyDictObject, key: *PyObject, value: *PyObject, mm: *PyMemoryManager) !void {
        const hash = try hashObject(key);
        if (self.indices_size == 0) {
            try self.resize(8, mm);
        }
        
        const lookup_res = (try self.lookup(key, hash, mm)).?;
        const entry_idx = self.indices[lookup_res];
        if (entry_idx < 0) {
            // New key
            if (self.entries_size >= self.entries_capacity) {
                try self.resize(self.indices_size * 2, mm);
                const new_res = (try self.lookup(key, hash, mm)).?;
                try self.insertAt(new_res, key, value, hash, mm);
            } else {
                try self.insertAt(lookup_res, key, value, hash, mm);
            }
        } else {
            // Existing key
            const entry = &self.entries[@intCast(entry_idx)];
            value.incRef();
            entry.value.?.decRef(mm);
            entry.value = value;
        }
    }

    fn insertAt(self: *PyDictObject, bucket_idx: usize, key: *PyObject, value: *PyObject, hash: i64, mm: *PyMemoryManager) !void {
        _ = mm;
        const entry_idx = self.entries_size;
        self.indices[bucket_idx] = @intCast(entry_idx);
        
        key.incRef();
        value.incRef();
        
        self.entries[entry_idx] = .{
            .hash = hash,
            .key = key,
            .value = value,
        };
        self.entries_size += 1;
        self.active_count += 1;
    }

    pub fn getItem(self: *PyDictObject, key: *PyObject, mm: *PyMemoryManager) !?*PyObject {
        if (self.indices_size == 0) return null;
        const hash = try hashObject(key);
        if (try self.lookup(key, hash, mm)) |res| {
            const entry_idx = self.indices[res];
            if (entry_idx >= 0) {
                return self.entries[@intCast(entry_idx)].value;
            }
        }
        return null;
    }

    pub fn delItem(self: *PyDictObject, key: *PyObject, mm: *PyMemoryManager) !bool {
        if (self.indices_size == 0) return false;
        const hash = try hashObject(key);
        if (try self.lookup(key, hash, mm)) |bucket_idx| {
            const entry_idx = self.indices[bucket_idx];
            if (entry_idx >= 0) {
                // Mark index as deleted (tombstone)
                self.indices[bucket_idx] = -2;
                // DecRef the key and value
                self.entries[@intCast(entry_idx)].key.?.decRef(mm);
                self.entries[@intCast(entry_idx)].value.?.decRef(mm);
                // Zero out the entry to prevent use-after-free during resize
                self.entries[@intCast(entry_idx)] = .{
                    .hash = 0,
                    .key = null,
                    .value = null,
                };
                self.active_count -= 1;
                return true;
            }
        }
        return false;
    }

    fn resize(self: *PyDictObject, new_indices_size: usize, mm: *PyMemoryManager) !void {
        const new_indices_bytes = try mm.allocBytes(new_indices_size * @sizeOf(i32));
        const new_indices: [*]i32 = @ptrCast(@alignCast(new_indices_bytes.ptr));
        for (0..new_indices_size) |i| {
            new_indices[i] = -1;
        }

        const new_entries_capacity = new_indices_size * 2 / 3;
        const new_entries_bytes = try mm.allocBytes(new_entries_capacity * @sizeOf(PyDictEntry));
        const new_entries: [*]PyDictEntry = @ptrCast(@alignCast(new_entries_bytes.ptr));
        
        var new_entries_size: usize = 0;
        
        if (self.indices_size > 0) {
            // Iterate over indices table to skip tombstoned (-2) and empty (-1) entries.
            // This prevents use-after-free from deleted entries whose keys/values have been decRef'd.
            for (0..self.indices_size) |bucket_i| {
                const entry_idx = self.indices[bucket_i];
                if (entry_idx < 0) continue; // skip empty or tombstoned
                const entry = &self.entries[@intCast(entry_idx)];
                new_entries[new_entries_size] = entry.*;
                
                const mask = new_indices_size - 1;
                var idx = @as(usize, @truncate(@as(u64, @bitCast(entry.hash)))) & mask;
                var perturb = @as(u64, @bitCast(entry.hash));
                while (new_indices[idx] != -1) {
                    idx = (idx * 5 + perturb + 1) & mask;
                    perturb >>= 5;
                }
                new_indices[idx] = @intCast(new_entries_size);
                new_entries_size += 1;
            }
            
            mm.freeBytes(@as([*]u8, @ptrCast(self.indices))[0..(self.indices_size * @sizeOf(i32))]);
            mm.freeBytes(@as([*]u8, @ptrCast(self.entries))[0..(self.entries_capacity * @sizeOf(PyDictEntry))]);
        }
        
        self.indices = new_indices;
        self.indices_size = new_indices_size;
        self.entries = new_entries;
        self.entries_capacity = new_entries_capacity;
        self.entries_size = new_entries_size;
    }
};

pub const PyDict_Type = PyTypeObject{
    .name = "dict",
    .tp_dealloc = dict_dealloc,
    .tp_repr = dict_repr,
    .tp_str = dict_repr,
};

fn dict_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyDictObject);
    if (obj.indices_size > 0) {
        for (0..obj.entries_size) |i| {
            const entry = &obj.entries[i];
            if (entry.key) |k| k.decRef(mm);
            if (entry.value) |v| v.decRef(mm);
        }
        mm.freeBytes(@as([*]u8, @ptrCast(obj.indices))[0..(obj.indices_size * @sizeOf(i32))]);
        mm.freeBytes(@as([*]u8, @ptrCast(obj.entries))[0..(obj.entries_capacity * @sizeOf(PyDictEntry))]);
    }
    mm.free(PyDictObject, obj);
}

fn dict_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyDictObject);
    if (obj.active_count == 0) {
        return try PyStringObject.create("{}", mm);
    }
    var alloc_writer = std.Io.Writer.Allocating.init(mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    
    try writer.writeAll("{");
    var first = true;
    // Iterate over indices table to skip tombstoned entries
    for (0..obj.indices_size) |i| {
        const entry_idx = obj.indices[i];
        if (entry_idx < 0) continue; // skip empty or tombstoned
        const entry = &obj.entries[@intCast(entry_idx)];
        
        if (!first) try writer.writeAll(", ");
        first = false;
        
        const k_repr = try get_repr(entry.key.?, mm);
        defer k_repr.decRef(mm);
        const v_repr = try get_repr(entry.value.?, mm);
        defer v_repr.decRef(mm);
        
        try writer.print("{s}: {s}", .{k_repr.as(PyStringObject).value(), v_repr.as(PyStringObject).value()});
    }
    try writer.writeAll("}");
    return try PyStringObject.create(alloc_writer.written(), mm);
}

// --- Unit Tests for Collections ---
test "tuple basic functionality" {
    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    const int1 = try PyIntObject.create(10, &mm);
    const int2 = try PyIntObject.create(20, &mm);

    const tup = try PyTupleObject.create(2, &mm);
    defer tup.base.decRef(&mm);

    const items = tup.items();
    // Replaces default None
    items[0].decRef(&mm);
    int1.incRef();
    items[0] = int1;

    items[1].decRef(&mm);
    int2.incRef();
    items[1] = int2;

    try testing.expectEqual(@as(usize, 2), tup.size);
    try testing.expectEqual(@as(i64, 10), tup.items()[0].as(PyIntObject).value);
    try testing.expectEqual(int1, tup.items()[0]);

    // Cleanup constants
    int1.decRef(&mm);
    int2.decRef(&mm);
}

test "list basic functionality" {
    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    const list = try PyListObject.create(0, &mm);
    defer list.base.decRef(&mm);

    const int1 = try PyIntObject.create(42, &mm);
    defer int1.decRef(&mm);

    try list.append(int1, &mm);

    try testing.expectEqual(@as(usize, 1), list.size);
    try testing.expectEqual(@as(i64, 42), list.items.?[0].as(PyIntObject).value);
}

test "dict basic functionality" {
    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    const dict = try PyDictObject.create(&mm);
    defer dict.base.decRef(&mm);

    const key = try PyStringObject.create("hello", &mm);
    defer key.decRef(&mm);

    const val = try PyIntObject.create(100, &mm);
    defer val.decRef(&mm);

    try dict.setItem(key, val, &mm);

    const retrieved = try dict.getItem(key, &mm);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(i64, 100), retrieved.?.as(PyIntObject).value);
}

// --- Set and FrozenSet Opcodes and Types ---

pub const PySetEntry = extern struct {
    hash: i64,
    key: ?*PyObject,
};

pub const PySetObject = extern struct {
    base: PyObject,
    indices: [*]i32,
    indices_size: usize,
    entries: [*]PySetEntry,
    entries_size: usize,
    entries_capacity: usize,
    active_count: usize,

    pub fn create(mm: *PyMemoryManager) !*PySetObject {
        const obj = try mm.alloc(PySetObject);
        obj.* = .{
            .base = PyObject.init(&PySet_Type),
            .indices = undefined,
            .indices_size = 0,
            .entries = undefined,
            .entries_size = 0,
            .entries_capacity = 0,
            .active_count = 0,
        };
        return obj;
    }

    pub fn createFrozen(mm: *PyMemoryManager) !*PySetObject {
        const obj = try mm.alloc(PySetObject);
        obj.* = .{
            .base = PyObject.init(&PyFrozenSet_Type),
            .indices = undefined,
            .indices_size = 0,
            .entries = undefined,
            .entries_size = 0,
            .entries_capacity = 0,
            .active_count = 0,
        };
        return obj;
    }

    fn hashObject(key: *PyObject) !i64 {
        if (key.type_obj.tp_hash) |hash_fn| {
            return try hash_fn(key);
        }
        return error.TypeError;
    }

    fn keysEqual(a: *PyObject, b: *PyObject, mm: *PyMemoryManager) !bool {
        if (a == b) return true;
        if (a.type_obj.tp_richcompare) |cmp_fn| {
            const res = try cmp_fn(a, b, .Eq, mm);
            defer res.decRef(mm);
            return res == PyTrue;
        }
        return false;
    }

    fn lookup(self: *PySetObject, key: *PyObject, hash: i64, mm: *PyMemoryManager) !?usize {
        if (self.indices_size == 0) return null;
        const mask = self.indices_size - 1;
        var idx = @as(usize, @truncate(@as(u64, @bitCast(hash)))) & mask;
        var perturb = @as(u64, @bitCast(hash));
        
        while (true) {
            const entry_idx = self.indices[idx];
            if (entry_idx == -1) {
                return idx;
            } else if (entry_idx == -2) {
                // deleted slot
            } else {
                const entry = &self.entries[@intCast(entry_idx)];
                if (entry.hash == hash and try keysEqual(entry.key.?, key, mm)) {
                    return idx;
                }
            }
            idx = (idx * 5 + perturb + 1) & mask;
            perturb >>= 5;
        }
    }

    pub fn add(self: *PySetObject, key: *PyObject, mm: *PyMemoryManager) !void {
        const hash = try hashObject(key);
        if (self.indices_size == 0) {
            try self.resize(8, mm);
        }
        
        const lookup_res = (try self.lookup(key, hash, mm)).?;
        const entry_idx = self.indices[lookup_res];
        if (entry_idx < 0) {
            if (self.entries_size >= self.entries_capacity) {
                try self.resize(self.indices_size * 2, mm);
                const new_res = (try self.lookup(key, hash, mm)).?;
                try self.insertAt(new_res, key, hash, mm);
            } else {
                try self.insertAt(lookup_res, key, hash, mm);
            }
        }
    }

    fn insertAt(self: *PySetObject, bucket_idx: usize, key: *PyObject, hash: i64, mm: *PyMemoryManager) !void {
        _ = mm;
        const entry_idx = self.entries_size;
        self.indices[bucket_idx] = @intCast(entry_idx);
        
        key.incRef();
        
        self.entries[entry_idx] = .{
            .hash = hash,
            .key = key,
        };
        self.entries_size += 1;
        self.active_count += 1;
    }

    pub fn contains(self: *PySetObject, key: *PyObject, mm: *PyMemoryManager) !bool {
        if (self.indices_size == 0) return false;
        const hash = try hashObject(key);
        if (try self.lookup(key, hash, mm)) |res| {
            const entry_idx = self.indices[res];
            return entry_idx >= 0;
        }
        return false;
    }

    pub fn remove(self: *PySetObject, key: *PyObject, mm: *PyMemoryManager) !bool {
        if (self.indices_size == 0) return false;
        const hash = try hashObject(key);
        if (try self.lookup(key, hash, mm)) |bucket_idx| {
            const entry_idx = self.indices[bucket_idx];
            if (entry_idx >= 0) {
                self.indices[bucket_idx] = -2;
                self.entries[@intCast(entry_idx)].key.?.decRef(mm);
                self.entries[@intCast(entry_idx)] = .{
                    .hash = 0,
                    .key = null,
                };
                self.active_count -= 1;
                return true;
            }
        }
        return false;
    }

    fn resize(self: *PySetObject, new_indices_size: usize, mm: *PyMemoryManager) !void {
        const new_indices_bytes = try mm.allocBytes(new_indices_size * @sizeOf(i32));
        const new_indices: [*]i32 = @ptrCast(@alignCast(new_indices_bytes.ptr));
        for (0..new_indices_size) |i| {
            new_indices[i] = -1;
        }

        const new_entries_capacity = new_indices_size * 2 / 3;
        const new_entries_bytes = try mm.allocBytes(new_entries_capacity * @sizeOf(PySetEntry));
        const new_entries: [*]PySetEntry = @ptrCast(@alignCast(new_entries_bytes.ptr));
        
        var new_entries_size: usize = 0;
        
        if (self.indices_size > 0) {
            for (0..self.indices_size) |bucket_i| {
                const entry_idx = self.indices[bucket_i];
                if (entry_idx < 0) continue;
                const entry = &self.entries[@intCast(entry_idx)];
                new_entries[new_entries_size] = entry.*;
                
                const mask = new_indices_size - 1;
                var idx = @as(usize, @truncate(@as(u64, @bitCast(entry.hash)))) & mask;
                var perturb = @as(u64, @bitCast(entry.hash));
                while (new_indices[idx] != -1) {
                    idx = (idx * 5 + perturb + 1) & mask;
                    perturb >>= 5;
                }
                new_indices[idx] = @intCast(new_entries_size);
                new_entries_size += 1;
            }
            
            mm.freeBytes(@as([*]u8, @ptrCast(self.indices))[0..(self.indices_size * @sizeOf(i32))]);
            mm.freeBytes(@as([*]u8, @ptrCast(self.entries))[0..(self.entries_capacity * @sizeOf(PySetEntry))]);
        }
        
        self.indices = new_indices;
        self.indices_size = new_indices_size;
        self.entries = new_entries;
        self.entries_capacity = new_entries_capacity;
        self.entries_size = new_entries_size;
    }
};

pub const PySet_Type = PyTypeObject{
    .name = "set",
    .tp_dealloc = set_dealloc,
    .tp_repr = set_repr,
    .tp_str = set_repr,
    .tp_richcompare = set_richcompare,
};

pub const PyFrozenSet_Type = PyTypeObject{
    .name = "frozenset",
    .tp_dealloc = set_dealloc,
    .tp_repr = frozenset_repr,
    .tp_str = frozenset_repr,
    .tp_richcompare = set_richcompare,
    .tp_hash = frozenset_hash,
};

fn set_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PySetObject);
    if (obj.indices_size > 0) {
        for (0..obj.entries_size) |i| {
            const entry = &obj.entries[i];
            if (entry.key) |k| k.decRef(mm);
        }
        mm.freeBytes(@as([*]u8, @ptrCast(obj.indices))[0..(obj.indices_size * @sizeOf(i32))]);
        mm.freeBytes(@as([*]u8, @ptrCast(obj.entries))[0..(obj.entries_capacity * @sizeOf(PySetEntry))]);
    }
    mm.free(PySetObject, obj);
}

fn set_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PySetObject);
    if (obj.active_count == 0) {
        return try PyStringObject.create("set()", mm);
    }
    var alloc_writer = std.Io.Writer.Allocating.init(mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    
    try writer.writeAll("{");
    var first = true;
    for (0..obj.indices_size) |i| {
        const entry_idx = obj.indices[i];
        if (entry_idx < 0) continue;
        const entry = &obj.entries[@intCast(entry_idx)];
        if (!first) try writer.writeAll(", ");
        first = false;
        
        const k_repr = try get_repr(entry.key.?, mm);
        defer k_repr.decRef(mm);
        try writer.print("{s}", .{k_repr.as(PyStringObject).value()});
    }
    try writer.writeAll("}");
    return try PyStringObject.create(alloc_writer.written(), mm);
}

fn frozenset_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PySetObject);
    if (obj.active_count == 0) {
        return try PyStringObject.create("frozenset()", mm);
    }
    var alloc_writer = std.Io.Writer.Allocating.init(mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    
    try writer.writeAll("frozenset({");
    var first = true;
    for (0..obj.indices_size) |i| {
        const entry_idx = obj.indices[i];
        if (entry_idx < 0) continue;
        const entry = &obj.entries[@intCast(entry_idx)];
        if (!first) try writer.writeAll(", ");
        first = false;
        
        const k_repr = try get_repr(entry.key.?, mm);
        defer k_repr.decRef(mm);
        try writer.print("{s}", .{k_repr.as(PyStringObject).value()});
    }
    try writer.writeAll("})");
    return try PyStringObject.create(alloc_writer.written(), mm);
}

fn set_richcompare(self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    const other_name = other.type_obj.name;
    if (!std.mem.eql(u8, other_name, "set") and !std.mem.eql(u8, other_name, "frozenset")) {
        if (op == .Eq) return PyFalse;
        if (op == .Ne) return PyTrue;
        return error.TypeError;
    }
    const self_set = self.as(PySetObject);
    const other_set = other.as(PySetObject);
    
    var result = false;
    switch (op) {
        .Eq => {
            if (self_set.active_count == other_set.active_count) {
                result = true;
                for (0..self_set.indices_size) |i| {
                    const entry_idx = self_set.indices[i];
                    if (entry_idx < 0) continue;
                    const key = self_set.entries[@intCast(entry_idx)].key.?;
                    if (!try other_set.contains(key, mm)) {
                        result = false;
                        break;
                    }
                }
            }
        },
        .Ne => {
            const eq_res = try set_richcompare(self, other, .Eq, mm);
            defer eq_res.decRef(mm);
            result = eq_res == PyFalse;
        },
        .Le => {
            if (self_set.active_count <= other_set.active_count) {
                result = true;
                for (0..self_set.indices_size) |i| {
                    const entry_idx = self_set.indices[i];
                    if (entry_idx < 0) continue;
                    const key = self_set.entries[@intCast(entry_idx)].key.?;
                    if (!try other_set.contains(key, mm)) {
                        result = false;
                        break;
                    }
                }
            }
        },
        .Lt => {
            if (self_set.active_count < other_set.active_count) {
                result = true;
                for (0..self_set.indices_size) |i| {
                    const entry_idx = self_set.indices[i];
                    if (entry_idx < 0) continue;
                    const key = self_set.entries[@intCast(entry_idx)].key.?;
                    if (!try other_set.contains(key, mm)) {
                        result = false;
                        break;
                    }
                }
            }
        },
        .Ge => {
            return try set_richcompare(other, self, .Le, mm);
        },
        .Gt => {
            return try set_richcompare(other, self, .Lt, mm);
        },
    }
    return if (result) PyTrue else PyFalse;
}

fn frozenset_hash(self: *PyObject) anyerror!i64 {
    const obj = self.as(PySetObject);
    var hash_val: i64 = 0;
    for (0..obj.indices_size) |i| {
        const entry_idx = obj.indices[i];
        if (entry_idx < 0) continue;
        const key = obj.entries[@intCast(entry_idx)].key.?;
        if (key.type_obj.tp_hash) |hash_fn| {
            hash_val ^= try hash_fn(key);
        } else {
            return error.TypeError;
        }
    }
    return hash_val;
}

test "set basic functionality" {
    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    const set = try PySetObject.create(&mm);
    defer set.base.decRef(&mm);

    const key = try PyStringObject.create("item", &mm);
    defer key.decRef(&mm);

    try set.add(key, &mm);
    try testing.expect(try set.contains(key, &mm));

    const removed = try set.remove(key, &mm);
    try testing.expect(removed);
    try testing.expect(!(try set.contains(key, &mm)));
}
