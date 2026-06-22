b = b"hello"
print(type(b))
print(b)
print(b[0])
print(b[1])
print(b[4])

ba = bytearray(b"world")
print(type(ba))
print(ba)
print(ba[0])
ba[0] = 87 # 'W'
print(ba)

b2 = bytes(5)
print(b2)
ba2 = bytearray(3)
print(ba2)

b3 = bytes([97, 98, 99])
print(b3)

ba3 = bytearray([120, 121, 122])
print(ba3)

# Concatenation and comparison
print(b + ba)
print(b == b"hello")
print(b != b"world")
print(b < b"world")
