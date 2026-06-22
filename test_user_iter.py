class Counter:
    def __init__(self, limit):
        self.limit = limit
        self.value = 0
    def __iter__(self):
        return self
    def __next__(self):
        if self.value >= self.limit:
            raise StopIteration
        val = self.value
        self.value = self.value + 1
        return val

print("Test 1: for loop over user-defined iterator")
result = []
for x in Counter(5):
    result.append(x)
print(result)

print("Test 2: explicit next() calls")
c = Counter(3)
print(next(c))
print(next(c))
print(next(c))
try:
    next(c)
    print("ERROR: should not reach")
except StopIteration:
    print("StopIteration caught correctly")

print("Test 3: for loop with manual iterator class")
class RangeIter:
    def __init__(self, n):
        self.n = n
        self.i = 0
    def __next__(self):
        if self.i >= self.n:
            raise StopIteration
        val = self.i
        self.i = self.i + 1
        return val

class MyRange:
    def __init__(self, n):
        self.n = n
    def __iter__(self):
        return RangeIter(self.n)

result = []
for x in MyRange(4):
    result.append(x)
print(result)
assert result == [0, 1, 2, 3], f"Expected [0,1,2,3], got {result}"

print("All tests passed!")
