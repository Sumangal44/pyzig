import keyword

print("False" in keyword.kwlist)
print("None" in keyword.kwlist)
print("True" in keyword.kwlist)
print("def" in keyword.kwlist)
print("case" in keyword.softkwlist)
print("match" in keyword.softkwlist)

print(keyword.iskeyword("if"))
print(keyword.iskeyword("hello"))
print(keyword.issoftkeyword("match"))
print(keyword.issoftkeyword("hello"))
