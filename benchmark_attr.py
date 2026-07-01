class Foo:
    def __init__(self):
        self.x = 0
        self.y = 0

def run():
    foo = Foo()
    i = 0
    while i < 1000000:
        foo.x = foo.x + i
        foo.y = foo.y + 1
        i = i + 1
    print(foo.x)
    print(foo.y)

run()
