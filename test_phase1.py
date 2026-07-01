# test_phase1.py
# Verification of newly implemented Phase 1 features

# 1. *args (varargs) positional argument packing
def test_varargs(a, *args):
    print(a)
    print(len(args))
    if len(args) > 0:
        print(args[0])
        print(args[1])

test_varargs(10, 20, 30) # expected: 10, 2, 20, 30

# 2. **kwargs (kwarg) placeholder
def test_kwargs(a, **kwargs):
    print(a)
    # kwargs should currently default to an empty dict
    print(len(kwargs))

test_kwargs(100) # expected: 100, 0

# 3. super() support
class Base:
    def __init__(self, val):
        self.val = val
    def greet(self):
        print("Base greeting")

class Derived(Base):
    def __init__(self, val):
        super().__init__(val)
    def greet(self):
        super().greet()
        print("Derived greeting")

d = Derived(42)
print(d.val) # expected: 42
d.greet() # expected: Base greeting, Derived greeting

# 4. for-else and while-else support
print("--- for-else ---")
for i in [1, 2, 3]:
    print(i)
else:
    print("for-else executed")

for i in [1, 2, 3]:
    if i == 2:
        break
    print(i)
else:
    print("for-else broke, should NOT run")

print("--- while-else ---")
count = 0
while count < 3:
    print(count)
    count += 1
else:
    print("while-else executed")

count = 0
while count < 3:
    if count == 1:
        break
    print(count)
    count += 1
else:
    print("while-else broke, should NOT run")

# 5. Tuple unpacking assignment
print("--- Tuple Unpacking ---")
x, y = (50, 60)
print(x) # 50
print(y) # 60

# 6. Augmented assignment on subscripts/attrs
print("--- Subscript/Attr AugAssign ---")
d_map = {"a": 10}
d_map["a"] += 5
print(d_map["a"]) # 15

class Dummy:
    def __init__(self):
        self.x = 20

dummy = Dummy()
dummy.x += 10
print(dummy.x) # 30

# 7. f-strings
name = "World"
num = 123
print(f"Hello {name}! {num + 1} is a number.") # Hello World! 124 is a number.
