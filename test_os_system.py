import os
print("Before running bash script...")
exit_code = os.system("bash test_script.sh")
print("Bash script finished with exit code:", exit_code)
