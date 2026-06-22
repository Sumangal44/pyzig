# Walrus operator test
if (x := 10) > 5:
    print(x)

y = (z := 5) + 2
print(y)
print(z)

# Expression context
a = [w := 1, w + 1, w + 2]
print(a)
print(w)
