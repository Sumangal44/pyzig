def my_gen():
    yield 1

print("before call")
g = my_gen()
print("before next")
next(g)
print("after next")
