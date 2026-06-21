# Constants
sahi_val = True
galat_val = False
empty_val = None

# Logic operators
if sahi_val and (not galat_val or sahi_val):
    print("Logical operators and/or work")

# Exceptions
try:
    raise Exception("An error occurred")
except Exception as e:
    print("Exception caught")
finally:
    print("Finally block executed")

# Classes and Methods
class Person:
    def __init__(self, name):
        self.name = name
    
    def get_name(self):
        return self.name

person = Person("Sumangal")
print(person.get_name())
