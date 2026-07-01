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
const PyInt_Type = &primitives.PyInt_Type;
const PyFloat_Type = &primitives.PyFloat_Type;
const PyString_Type = &primitives.PyString_Type;
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
    .tp_richcompare = tuple_richcompare,
    .tp_mul = tuple_mul,
};

fn tuple_mul(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    if (other.type_obj != PyInt_Type) {
        return error.TypeError;
    }
    const tuple = self.as(PyTupleObject);
    const count = other.as(PyIntObject).value;
    if (count <= 0) {
        return & (try PyTupleObject.create(0, mm)).base;
    }
    const ucount = @as(usize, @intCast(count));
    const total_size = tuple.size * ucount;
    const new_tuple = try PyTupleObject.create(total_size, mm);
    errdefer new_tuple.base.decRef(mm);
    
    const slice = new_tuple.items();
    const old_slice = tuple.items();
    
    var i: usize = 0;
    while (i < ucount) : (i += 1) {
        if (tuple.size > 0) {
            for (0..tuple.size) |j| {
                const item = old_slice[j];
                const target_idx = i * tuple.size + j;
                slice[target_idx].decRef(mm);
                item.incRef();
                slice[target_idx] = item;
            }
        }
    }
    return &new_tuple.base;
}

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
        try self.ensureCapacity(self.size + 1, mm);
        item.incRef();
        self.items.?[self.size] = item;
        self.size += 1;
    }

    pub fn ensureCapacity(self: *PyListObject, needed: usize, mm: *PyMemoryManager) !void {
        if (needed <= self.capacity) return;
        const new_capacity = @max(if (self.capacity == 0) 4 else self.capacity * 2, needed);
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

    pub fn insert(self: *PyListObject, idx: i64, item: *PyObject, mm: *PyMemoryManager) !void {
        const len = @as(i64, @intCast(self.size));
        var pos = idx;
        if (pos < 0) pos = @max(len + pos, 0);
        if (pos > len) pos = len;
        const pos_u = @as(usize, @intCast(pos));
        try self.ensureCapacity(self.size + 1, mm);
        if (pos_u < self.size) {
            std.mem.copyBackwards(*PyObject, self.items.?[pos_u + 1 .. self.size + 1], self.items.?[pos_u..self.size]);
        }
        item.incRef();
        self.items.?[pos_u] = item;
        self.size += 1;
    }

    pub fn pop(self: *PyListObject, idx: ?i64) *PyObject {
        const actual = if (idx) |i| i else @as(i64, @intCast(@as(isize, @intCast(self.size - 1))));
        const pos = if (actual < 0) @as(i64, @intCast(self.size)) + actual else actual;
        const pos_u = @as(usize, @intCast(pos));
        const item = self.items.?[pos_u];
        if (pos_u < self.size - 1) {
            std.mem.copyForwards(*PyObject, self.items.?[pos_u..self.size], self.items.?[pos_u + 1 .. self.size]);
        }
        self.size -= 1;
        return item;
    }

    pub fn remove(self: *PyListObject, item: *PyObject, mm: *PyMemoryManager) !void {
        for (0..self.size) |i| {
            if (try elementsEqual(self.items.?[i], item, mm)) {
                self.items.?[i].decRef(mm);
                if (i < self.size - 1) {
                    std.mem.copyForwards(*PyObject, self.items.?[i..self.size], self.items.?[i + 1 .. self.size]);
                }
                self.size -= 1;
                return;
            }
        }
        return error.ValueError;
    }

    pub fn index(self: *PyListObject, item: *PyObject, mm: *PyMemoryManager) !i64 {
        for (0..self.size) |i| {
            if (try elementsEqual(self.items.?[i], item, mm)) {
                return @as(i64, @intCast(i));
            }
        }
        return error.ValueError;
    }

    pub fn count(self: *PyListObject, item: *PyObject, mm: *PyMemoryManager) !i64 {
        var cnt: i64 = 0;
        for (0..self.size) |i| {
            if (try elementsEqual(self.items.?[i], item, mm)) {
                cnt += 1;
            }
        }
        return cnt;
    }

    pub fn reverse(self: *PyListObject) void {
        if (self.size == 0) return;
        var i: usize = 0;
        var j: usize = self.size - 1;
        while (i < j) {
            const tmp = self.items.?[i];
            self.items.?[i] = self.items.?[j];
            self.items.?[j] = tmp;
            i += 1;
            j -= 1;
        }
    }

    pub fn sort(self: *PyListObject, mm: *PyMemoryManager) !void {
        if (self.size <= 1) return;
        for (1..self.size) |i| {
            const key = self.items.?[i];
            var j = i;
            while (j > 0) {
                if (self.items.?[j - 1].type_obj.tp_richcompare) |cmp_fn| {
                    const res = try cmp_fn(self.items.?[j - 1], key, .Gt, mm);
                    if (res == PyTrue) {
                        self.items.?[j] = self.items.?[j - 1];
                        j -= 1;
                    } else {
                        break;
                    }
                } else {
                    return error.TypeError;
                }
            }
            self.items.?[j] = key;
        }
    }

    pub fn extend(self: *PyListObject, iterable: *PyObject, mm: *PyMemoryManager) !void {
        if (iterable.type_obj == &PyList_Type) {
            const other = iterable.as(PyListObject);
            const new_size = self.size + other.size;
            try self.ensureCapacity(new_size, mm);
            if (other.items) |other_items| {
                @memcpy(self.items.?[self.size..new_size], other_items[0..other.size]);
                for (0..other.size) |i| {
                    other_items[i].incRef();
                }
            }
            self.size = new_size;
            return;
        }
        if (iterable.type_obj == &PyTuple_Type) {
            const other = iterable.as(PyTupleObject);
            const other_items = other.items();
            const new_size = self.size + other_items.len;
            try self.ensureCapacity(new_size, mm);
            @memcpy(self.items.?[self.size..new_size], other_items);
            for (other_items) |item| {
                item.incRef();
            }
            self.size = new_size;
            return;
        }
        return error.TypeError;
    }

    pub fn clear(self: *PyListObject, mm: *PyMemoryManager) void {
        if (self.items) |items| {
            for (0..self.size) |i| {
                items[i].decRef(mm);
            }
        }
        self.size = 0;
    }
};

pub const PyList_Type = PyTypeObject{
    .name = "list",
    .tp_dealloc = list_dealloc,
    .tp_repr = list_repr,
    .tp_str = list_repr,
    .tp_richcompare = list_richcompare,
    .tp_mul = list_mul,
};

fn list_mul(self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    if (other.type_obj != PyInt_Type) {
        return error.TypeError;
    }
    const list = self.as(PyListObject);
    const count = other.as(PyIntObject).value;
    if (count <= 0) {
        return & (try PyListObject.create(0, mm)).base;
    }
    const ucount = @as(usize, @intCast(count));
    const total_size = list.size * ucount;
    const new_list = try PyListObject.create(total_size, mm);
    errdefer new_list.base.decRef(mm);
    
    var i: usize = 0;
    while (i < ucount) : (i += 1) {
        if (list.size > 0) {
            for (0..list.size) |j| {
                const item = list.items.?[j];
                try new_list.append(item, mm);
            }
        }
    }
    return &new_list.base;
}

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

fn elementsEqual(a: *PyObject, b: *PyObject, mm: *PyMemoryManager) !bool {
    if (a == b) return true;
    if (a.type_obj.tp_richcompare) |cmp_fn| {
        const res = try cmp_fn(a, b, .Eq, mm);
        defer res.decRef(mm);
        return res == PyTrue;
    }
    return false;
}

fn list_richcompare(self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    const other_name = other.type_obj.name;
    if (!std.mem.eql(u8, other_name, "list")) {
        if (op == .Eq) return PyFalse;
        if (op == .Ne) return PyTrue;
        return error.TypeError;
    }
    const self_list = self.as(PyListObject);
    const other_list = other.as(PyListObject);

    const self_items = if (self_list.items) |items| items[0..self_list.size] else &[_]*PyObject{};
    const other_items = if (other_list.items) |items| items[0..other_list.size] else &[_]*PyObject{};

    const min_len = @min(self_items.len, other_items.len);
    for (0..min_len) |i| {
        if (!try elementsEqual(self_items[i], other_items[i], mm)) {
            if (op == .Eq) return PyFalse;
            if (op == .Ne) return PyTrue;
            if (self_items[i].type_obj.tp_richcompare) |cmp_fn| {
                return try cmp_fn(self_items[i], other_items[i], op, mm);
            }
            return error.TypeError;
        }
    }

    const result = switch (op) {
        .Lt => self_items.len < other_items.len,
        .Le => self_items.len <= other_items.len,
        .Eq => self_items.len == other_items.len,
        .Ne => self_items.len != other_items.len,
        .Gt => self_items.len > other_items.len,
        .Ge => self_items.len >= other_items.len,
    };
    return if (result) PyTrue else PyFalse;
}

fn tuple_richcompare(self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject {
    const other_name = other.type_obj.name;
    if (!std.mem.eql(u8, other_name, "tuple")) {
        if (op == .Eq) return PyFalse;
        if (op == .Ne) return PyTrue;
        return error.TypeError;
    }
    const self_tuple = self.as(PyTupleObject);
    const other_tuple = other.as(PyTupleObject);

    const self_items = self_tuple.items();
    const other_items = other_tuple.items();

    const min_len = @min(self_items.len, other_items.len);
    for (0..min_len) |i| {
        if (!try elementsEqual(self_items[i], other_items[i], mm)) {
            if (op == .Eq) return PyFalse;
            if (op == .Ne) return PyTrue;
            if (self_items[i].type_obj.tp_richcompare) |cmp_fn| {
                return try cmp_fn(self_items[i], other_items[i], op, mm);
            }
            return error.TypeError;
        }
    }

    const result = switch (op) {
        .Lt => self_items.len < other_items.len,
        .Le => self_items.len <= other_items.len,
        .Eq => self_items.len == other_items.len,
        .Ne => self_items.len != other_items.len,
        .Gt => self_items.len > other_items.len,
        .Ge => self_items.len >= other_items.len,
    };
    return if (result) PyTrue else PyFalse;
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
            for (0..self.entries_size) |entry_i| {
                const entry = &self.entries[entry_i];
                if (entry.key == null) continue; // skip empty or tombstoned
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

    pub fn keys(self: *PyDictObject, mm: *PyMemoryManager) !*PyListObject {
        const result = try PyListObject.create(self.active_count, mm);
        for (0..self.entries_size) |i| {
            const entry = &self.entries[i];
            if (entry.key == null) continue;
            try result.append(entry.key.?, mm);
        }
        return result;
    }

    pub fn values(self: *PyDictObject, mm: *PyMemoryManager) !*PyListObject {
        const result = try PyListObject.create(self.active_count, mm);
        for (0..self.entries_size) |i| {
            const entry = &self.entries[i];
            if (entry.key == null) continue;
            try result.append(entry.value.?, mm);
        }
        return result;
    }

    pub fn items(self: *PyDictObject, mm: *PyMemoryManager) !*PyListObject {
        const result = try PyListObject.create(self.active_count, mm);
        for (0..self.entries_size) |i| {
            const entry = &self.entries[i];
            if (entry.key == null) continue;
            const tup = try PyTupleObject.create(2, mm);
            tup.items()[0] = entry.key.?;
            entry.key.?.incRef();
            tup.items()[1] = entry.value.?;
            entry.value.?.incRef();
            try result.append(&tup.base, mm);
        }
        return result;
    }

    pub fn get(self: *PyDictObject, key: *PyObject, mm: *PyMemoryManager) ?*PyObject {
        if (self.indices_size == 0) return null;
        const hash = hashObject(key) catch return null;
        if (self.lookup(key, hash, mm) catch null) |bucket_idx| {
            const entry_idx = self.indices[bucket_idx];
            if (entry_idx >= 0) {
                return self.entries[@intCast(entry_idx)].value;
            }
        }
        return null;
    }

    pub fn dictPop(self: *PyDictObject, key: *PyObject, mm: *PyMemoryManager) !*PyObject {
        if (self.indices_size == 0) return error.KeyError;
        const hash = try hashObject(key);
        if (try self.lookup(key, hash, mm)) |bucket_idx| {
            const entry_idx = self.indices[bucket_idx];
            if (entry_idx >= 0) {
                const value = self.entries[@intCast(entry_idx)].value.?;
                value.incRef();
                _ = try self.delItem(key, mm);
                return value;
            }
        }
        return error.KeyError;
    }

    pub fn update(self: *PyDictObject, other: *PyDictObject, mm: *PyMemoryManager) !void {
        for (0..other.entries_size) |i| {
            const entry = &other.entries[i];
            if (entry.key == null) continue;
            try self.setItem(entry.key.?, entry.value.?, mm);
        }
    }

    pub fn clear(self: *PyDictObject, mm: *PyMemoryManager) void {
        for (0..self.indices_size) |i| {
            const entry_idx = self.indices[i];
            if (entry_idx < 0) continue;
            self.entries[@intCast(entry_idx)].key.?.decRef(mm);
            self.entries[@intCast(entry_idx)].value.?.decRef(mm);
            self.entries[@intCast(entry_idx)] = .{
                .hash = 0,
                .key = null,
                .value = null,
            };
            self.indices[i] = -1;
        }
        self.active_count = 0;
        self.entries_size = 0;
    }

    pub fn copy(self: *PyDictObject, mm: *PyMemoryManager) !*PyDictObject {
        const result = try PyDictObject.create(mm);
        for (0..self.entries_size) |i| {
            const entry = &self.entries[i];
            if (entry.key == null) continue;
            try result.setItem(entry.key.?, entry.value.?, mm);
        }
        return result;
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
    // Iterate over entries table to skip tombstoned entries
    for (0..obj.entries_size) |i| {
        const entry = &obj.entries[i];
        if (entry.key == null) continue; // skip empty or tombstoned
        
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
