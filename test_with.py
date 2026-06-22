class MyContext:
    def __init__(self, suppress):
        self.suppress = suppress

    def __enter__(self):
        print("Enter")
        return 42

    def __exit__(self, exc_type, exc_val, exc_tb):
        print("Exit")
        if exc_type:
            print("Exception occurred")
            return self.suppress
        return False

with MyContext(False) as val:
    print(val)

print("---")

try:
    with MyContext(True):
        print("About to raise suppressed error")
        raise Exception("Suppressed error")
    print("Suppressed successfully")
except Exception as e:
    print("Should not be here")

print("---")

try:
    with MyContext(False):
        print("About to raise non-suppressed error")
        raise Exception("Non-suppressed error")
except Exception as e:
    print("Caught non-suppressed error")
