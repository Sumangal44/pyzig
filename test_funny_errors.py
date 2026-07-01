# test_funny_errors.py

# Trigger NameError
try:
    print(non_existent_var)
except NameError:
    pass

# Trigger TypeError (object not callable)
try:
    s = "hello"
    s()
except TypeError:
    pass

# Trigger AttributeError (attributes on non-object primitives)
try:
    x = 10
    print(x.foo)
except AttributeError:
    pass

# Trigger ValueError (not enough unpacking)
try:
    a, b = (1,)
except ValueError:
    pass

# Trigger ZeroDivisionError
try:
    1 / 0
except ZeroDivisionError:
    pass
