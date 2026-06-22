def my_gen():
    print("Gen start")
    yield 1
    print("Gen mid")
    yield 2
    print("Gen end")

for x in my_gen():
    print(x)

print("---")

g = my_gen()
print(next(g))
print(next(g))
try:
    print(next(g))
except StopIteration:
    print("Caught StopIteration")
