class Animal:
    def __init__(self, name):
        self.name = name
    def speak(self):
        print(self.name)

dog = Animal("Rex")
dog.speak()
