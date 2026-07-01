# print_funny_errors.py
# Verification of all funny error messages

print("--- 1. NameError (undefined variable) ---")
try:
    print(unknown_variable_name)
except NameError:
    # Print the NameError message to stdout so we see it
    # (In Python, print(sys.exception()) or print(e) shows the message)
    # Since sys.exception() might not be fully populated in PyZig yet,
    # let's just trigger it uncaught inside individual sub-runs.
    pass

# We will run another file to show them uncaught!
