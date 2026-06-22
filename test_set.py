s = {1, 2, 3}
print(type(s))
print(s)

s.add(4)
print(s)

s.remove(2)
print(s)

fs = frozenset([3, 4, 5])
print(type(fs))
print(fs)

# Comparisons
print({1, 3} == {3, 1})
print({1, 3} != {1, 2})
print({1, 3} <= {1, 3, 4})
print({1, 3} < {1, 3, 4})
