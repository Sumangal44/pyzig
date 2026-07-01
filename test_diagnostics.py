# test_diagnostics.py
import subprocess
import sys

def run_pyzig(args, code):
    cmd = ["./zig-out/bin/pyzig"] + args + ["-c", code]
    res = subprocess.run(cmd, capture_output=True, text=True)
    return res.stdout, res.stderr, res.returncode

def test_diagnostics():
    print("Running diagnostics integration tests...")
    
    # 1. NameError --hinglish
    out, err, code = run_pyzig(["--hinglish"], "print(hello)")
    assert "--- BharatPython Enhanced Diagnostics ---" in out, "Hinglish header missing"
    assert "Bhai, yeh variable ya function kahan se laya?" in out, "Hinglish message missing"
    assert "Bro, where did this variable or function come from?" in out, "English message missing"
    
    # 2. NameError --jugaad
    out, err, code = run_pyzig(["--jugaad"], "print(hello)")
    assert "Variable dhundte dhundte thak gaya" in out, "Jugaad title missing"
    assert "Kya gadbad hai?" in out, "Jugaad body header missing"
    assert "Universe collapse ho gaya" in out, "Jugaad body content missing"
    
    # 3. ZeroDivisionError --hinglish
    out, err, code = run_pyzig(["--hinglish"], "1 / 0")
    assert "Maths ke niyam tod rahe ho!" in out, "Hinglish message missing"
    
    # 4. ZeroDivisionError --jugaad
    out, err, code = run_pyzig(["--jugaad"], "1 / 0")
    assert "Zero se divide?" in out, "Jugaad title missing"
    
    # 5. TypeError --hinglish
    out, err, code = run_pyzig(["--hinglish"], "'str'()")
    assert "Bhai, oil aur pani mix nahi hote!" in out, "Hinglish message missing"
    
    # 6. TypeError --jugaad
    out, err, code = run_pyzig(["--jugaad"], "'str'()")
    assert "Type mismatch ho gaya" in out, "Jugaad title missing"
    
    # 7. ValueError --hinglish
    out, err, code = run_pyzig(["--hinglish"], "a, b = (1,)")
    assert "Data type toh theek hai, par value mein ghapla hai!" in out, "Hinglish message missing"
    
    # 8. ValueError --jugaad
    out, err, code = run_pyzig(["--jugaad"], "a, b = (1,)")
    assert "Value galat hai boss!" in out, "Jugaad title missing"

    print("All diagnostic integration tests passed successfully!")

if __name__ == "__main__":
    test_diagnostics()
