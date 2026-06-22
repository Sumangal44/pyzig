# Bitwise tests
print(10 & 6)
print(10 | 6)
print(10 ^ 6)
print(1 << 4)
print(32 >> 3)
print(~5)

# Set bitwise tests
s1 = {1, 2, 3}
s2 = {3, 4, 5}
# We use list sorted representation to guarantee matching string output order between CPython and Pyzig
print(sorted(list(s1 & s2)))
print(sorted(list(s1 | s2)))
print(sorted(list(s1 ^ s2)))
print(sorted(list(s1 - s2)))
