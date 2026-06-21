# Comprehensive verification script of all python features

# --- Test 1: For Loops, In operator, Break, Continue ---
acc = 0
for x in [1, 2, 3, 4, 5]:
    if x == 4:
        continue
    if x == 5:
        break
    acc = acc + x
print(acc)  # Expected: 6 (1 + 2 + 3)

# --- Test 2: Arithmetic Operators (Pow, FloorDiv, Mod) ---
print(2 ** 8)   # Expected: 256
print(25 // 4)  # Expected: 6
print(25 % 4)   # Expected: 1

# --- Test 3: Augmented Assignment ---
x = 10
x += 5
print(x)  # 15
x -= 3
print(x)  # 12
x *= 2
print(x)  # 24
x /= 4
print(x)  # 6.0
x //= 2
print(x)  # 3.0
x **= 3
print(x)  # 27.0

# --- Test 4: Comparison Operators (is, is not, in, not in) ---
a = [1, 2]
b = a
c = [1, 2]
print(a is b)      # True
print(a is not b)  # False
print(a is c)      # False
print(1 in a)      # True
print(3 not in a)  # True
print("he" in "hello") # True

# --- Test 5: Dict deletion ---
d = {"x": 1, "y": 2}
del d["x"]
print(len(d))  # 1

# --- Test 6: Assert and Exceptions ---
try:
    assert 1 == 2
except AssertionError:
    print("caught AssertionError")

# --- Test 7: Global variables ---
g_var = 1
def change_global():
    global g_var
    g_var = 100
change_global()
print(g_var)  # 100

# --- Test 8: Lambda expressions ---
f_lam = lambda x, y: x * y + 10
print(f_lam(3, 4))  # 22

# --- Test 9: isinstance built-in ---
print(isinstance(10, int))          # True
print(isinstance("hi", str))        # True
print(isinstance([1], list))        # True
print(isinstance(1.5, float))       # True
print(isinstance((1,), tuple))      # True
print(isinstance({"a": 1}, dict))   # True
print(isinstance(True, bool))       # True

class A:
    pass

class B(A):
    pass

b_inst = B()
print(isinstance(b_inst, B))        # True
print(isinstance(b_inst, A))        # True
print(isinstance(b_inst, object))   # True

# --- Test 10: hasattr, getattr, setattr ---
class Person:
    def __init__(self, name):
        self.name = name

p = Person("Alice")
print(hasattr(p, "name"))           # True
print(hasattr(p, "age"))            # False
print(getattr(p, "name"))           # Alice
print(getattr(p, "age", 25))        # 25
setattr(p, "age", 30)
print(getattr(p, "age"))            # 30

# --- Test 11: repr, id, chr, ord ---
print(repr("hello"))
print(isinstance(id(p), int))       # True
print(chr(97))                      # a
print(ord("a"))                     # 97

# --- Test 12: hex, oct, bin ---
print(hex(255))                     # 0xff
print(oct(8))                       # 0o10
print(bin(5))                       # 0b101

# --- Test 13: enumerate, zip ---
# Unpacking lists/tuples using subscripting
for item in enumerate(["a", "b"]):
    print(item[0])
    print(item[1])

for item in zip([1, 2], ["x", "y"]):
    print(item[0])
    print(item[1])

# --- Test 14: map, filter ---
map_res = list(map(lambda val: val * 2, [1, 2, 3]))
print(len(map_res))
print(map_res[0])
print(map_res[1])
print(map_res[2])

filter_res = list(filter(lambda val: val % 2 == 0, [1, 2, 3, 4]))
print(len(filter_res))
print(filter_res[0])
print(filter_res[1])

# --- Test 15: sorted, reversed ---
sorted_res = sorted([3, 1, 2])
print(sorted_res[0])
print(sorted_res[1])
print(sorted_res[2])

reversed_res = list(reversed([1, 2, 3]))
print(reversed_res[0])
print(reversed_res[1])
print(reversed_res[2])

# --- Test 16: any, all ---
print(any([False, True, False]))    # True
print(all([True, True, True]))      # True
print(all([True, False, True]))     # False

# --- Test 17: pow, round, hash ---
print(pow(2, 3))                    # 8
print(pow(2, 3, 5))                 # 3
print(round(3.14159, 2))            # 3.14
print(isinstance(hash("hello"), int)) # True
