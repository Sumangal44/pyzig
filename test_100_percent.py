def assert_eq(a, b, msg):
    if a != b:
        print("FAIL:", msg, "-", a, "!=", b)
    else:
        print("PASS:", msg)

# 1. Keyword Arguments
def kwarg_func(a, b):
    return a - b

try:
    res = kwarg_func(b=5, a=10)
    assert_eq(res, 5, "Keyword arguments")
except Exception as e:
    print("FAIL: Keyword arguments -", e)

# 2. Tuple Unpacking in Literals
try:
    tup = (*[1, 2], *[3, 4])
    assert_eq(tup, (1, 2, 3, 4), "Tuple unpack literals")
except Exception as e:
    print("FAIL: Tuple unpack literals -", e)

# 3. Decorator with arguments
def dec_factory(inc):
    def decorator(func):
        def wrapper(x):
            return func(x) + inc
        return wrapper
    return decorator

try:
    @dec_factory(10)
    def my_func(x):
        return x
    assert_eq(my_func(5), 15, "Decorator with args")
except Exception as e:
    print("FAIL: Decorator with args -", e)

# 4. Dunder Methods
class DunderTester:
    def __init__(self, val):
        self.val = val
        
    def __add__(self, other):
        return self.val + other.val
        
    def __eq__(self, other):
        return self.val == other.val
        
    def __len__(self):
        return self.val
        
    def __getitem__(self, key):
        return key * 2
        
    def __str__(self):
        return "Dunder" + str(self.val)

try:
    a = DunderTester(5)
    b = DunderTester(10)
    assert_eq(a + b, 15, "Dunder __add__")
    assert_eq(a == DunderTester(5), True, "Dunder __eq__")
    assert_eq(len(a), 5, "Dunder __len__")
    assert_eq(a[3], 6, "Dunder __getitem__")
except Exception as e:
    print("FAIL: Dunder methods -", e)

# 5. classmethod / staticmethod
class MethodTester:
    @classmethod
    def cm(cls):
        return "class"
        
    @staticmethod
    def sm():
        return "static"

try:
    assert_eq(MethodTester.cm(), "class", "classmethod")
    assert_eq(MethodTester.sm(), "static", "staticmethod")
except Exception as e:
    print("FAIL: class/static methods -", e)

# 6. eval
try:
    assert_eq(eval("2 + 3"), 5, "eval()")
except Exception as e:
    print("FAIL: eval() -", e)

print("Done running 100% Python Support Tests!")
