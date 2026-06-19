# Phase 3 E2E verification script

# --- Test 1: OOP with __init__ and methods ---
class Animal:
    def __init__(self, name):
        self.name = name

    def speak(self):
        print(self.name)

dog = Animal("Rex")
dog.speak()

# --- Test 2: Inheritance ---
class Dog(Animal):
    def speak(self):
        print("Woof: " + self.name)

d2 = Dog("Buddy")
d2.speak()

# --- Test 3: Closures / Counter ---
def make_counter():
    count = 0
    def increment():
        nonlocal count
        count = count + 1
        return count
    return increment

counter = make_counter()
print(counter())
print(counter())
print(counter())

# --- Test 4: Exception handling ---
class MathError(Exception):
    pass

def safe_divide(a, b):
    if b == 0:
        raise MathError("division by zero")
    return a + b

try:
    result = safe_divide(10, 2)
    print(result)
    safe_divide(5, 0)
except MathError:
    print("Caught MathError")

# --- Test 5: Built-ins ---
nums = [1, 2, 3, 4, 5]
print(len(nums))

r = range(3)
print(len(r))

x = 42
print(str(x))
