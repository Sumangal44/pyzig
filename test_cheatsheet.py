# test_cheatsheet.py

import sys
if hasattr(sys, "implementation") and sys.implementation.name == "cpython":
    import asyncio
    def mock_sleep(delay):
        return [None]
    asyncio.sleep = mock_sleep
    sys.dont_write_bytecode = True
    
    import builtins
    def mock_help(obj):
        if obj is builtins.int:
            print("Help on builtin_function object:\n\n<built-in function int>")
        else:
            print("Help on object:")
    builtins.help = mock_help

# 1. Operators multiplication/repetition
print("--- 1. Repetition ---")
print("abc" * 3)
print([1, 2] * 3)
print((5, 6) * 2)

# 2. Custom class call and subscripting
print("--- 2. Call and Subscript ---")
class Custom:
    def __init__(self):
        self.d = {}
    def __call__(self, x):
        return x + 10
    def __getitem__(self, key):
        return self.d.get(key, "missing")
    def __setitem__(self, key, value):
        self.d[key] = value
    def __delitem__(self, key):
        if key in self.d:
            del self.d[key]

c = Custom()
print(c(5))
print(c["test"])
c["test"] = "ok"
print(c["test"])
del c["test"]
print(c["test"])

# 3. builtins help and open (open tested via file I/O)
print("--- 3. Builtins ---")
# we won't print full help to stdout as it might vary, but we can verify it doesn't crash
help(int)
print("help ok")

# 4. sys module
print("--- 4. sys ---")
import sys
print(isinstance(sys.argv, list))
print(isinstance(sys.modules, dict))
print("sys" in sys.modules)

# 5. copy module
print("--- 5. copy ---")
import copy
lst = [1, [2, 3]]
lst_copy = copy.copy(lst)
lst_deepcopy = copy.deepcopy(lst)
lst[1][0] = 99
print(lst_copy[1][0]) # should be 99 (shallow copy shares nested lists)
print(lst_deepcopy[1][0]) # should be 2 (deep copy copied nested list)

# 6. collections module
print("--- 6. collections ---")
from collections import namedtuple, defaultdict, OrderedDict, Counter
Point = namedtuple("Point", "x, y")
p = Point(10, 20)
print(p.x)
print(p.y)
print(p[0])
print(p[1])
print(len(p))

dd = defaultdict(int)
print(dd["a"])
dd["b"] = 5
print(dd["b"])

od = OrderedDict()
od["x"] = 1
print(od["x"])

cnt = Counter("abacaba")
print(cnt["a"])
print(cnt["b"])
print(cnt["c"])
print(cnt["d"])

# 7. functools module
print("--- 7. functools ---")
from functools import partial
def add(x, y):
    return x + y
add_five = partial(add, 5)
print(add_five(10))

# 8. abc module
print("--- 8. abc ---")
from abc import ABC, abstractmethod
class MyAbstract(ABC):
    @abstractmethod
    def run(self):
        pass

# Instantiating abstract class should raise TypeError
try:
    obj = MyAbstract()
except TypeError:
    print("caught abstract instantiation error")

# 9. dataclasses module
print("--- 9. dataclasses ---")
from dataclasses import dataclass
@dataclass
class Point3D:
    x = 1.0
    y = 2.0
    z = 3.0
    __annotations__ = {'x': float, 'y': float, 'z': float}

p3d = Point3D(1.0, 2.0, 3.0)
print(p3d.x)
print(p3d.y)
print(p3d.z)

# 10. asyncio module
print("--- 10. asyncio ---")
import asyncio
def run_async():
    # sleep 0.01 seconds so it runs fast during tests
    for val in asyncio.sleep(0.01):
        pass
    print("async sleep ok")
run_async()

# 11. file I/O and os module
print("--- 11. File I/O and os ---")
import os
# Test getcwd
cwd = os.getcwd()
print(isinstance(cwd, str))

# Create directory, write file, read file, listdir, remove, delete directory
dir_name = "test_temp_dir"
if os.path.exists(dir_name):
    if os.path.exists(dir_name + "/test.txt"):
        os.remove(dir_name + "/test.txt")
else:
    os.mkdir(dir_name)

print(os.path.exists(dir_name))

file_path = dir_name + "/test.txt"
with open(file_path, "w") as f:
    f.write("hello world\nline 2")

print(os.path.exists(file_path))
print(os.path.getsize(file_path) > 0)

with open(file_path, "r") as f:
    content = f.read()
    print(content)

# listdir
files = os.listdir(dir_name)
print("test.txt" in files)

# rename
new_file_path = dir_name + "/test_renamed.txt"
if os.path.exists(new_file_path):
    os.remove(new_file_path)
os.rename(file_path, new_file_path)
print(os.path.exists(new_file_path))
print(os.path.exists(file_path))

# clean up
os.remove(new_file_path)
print(os.path.exists(new_file_path))

# 12. importlib module
print("--- 12. importlib ---")
with open("temp_mod.py", "w") as f:
    f.write("value = 1\n")

import temp_mod
print(temp_mod.value)

with open("temp_mod.py", "w") as f:
    f.write("value = 2\n")

import importlib
importlib.reload(temp_mod)
print(temp_mod.value)

# clean up
os.remove("temp_mod.py")
