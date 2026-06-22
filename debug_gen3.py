def my_gen():
    yield 1

for x in my_gen():
    print(x)
