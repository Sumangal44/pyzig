def my_gen():
    print("Gen start")
    yield 1
    print("Gen mid")
    yield 2
    print("Gen end")

print("--- For loop ---")
for x in my_gen():
    print(x)

print("--- After loop ---")
