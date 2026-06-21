import subprocess
import time
import os

# List of files to run
test_files = [
    "test_loop.py",
    "test_class.py",
    "test_import.py",
    "test_logical.py",
    "test_phase3.py",
    "test_comprehensive.py",
    "test_keyword.py",
    "benchmark.py"
]

print("=" * 70)
print(f"{'Pyzig vs CPython Correctness & Performance Comparison':^70}")
print("=" * 70)

header = f"| {'Test File':<20} | {'Output Match':<12} | {'CPython Time':<12} | {'Pyzig Time':<12} | {'Speedup':<10} |"
separator = "| " + "-"*20 + " | " + "-"*12 + " | " + "-"*12 + " | " + "-"*12 + " | " + "-"*10 + " |"
print(header)
print(separator)

pyzig_path = "./zig-out/bin/pyzig"

all_success = True

for test_file in test_files:
    if not os.path.exists(test_file):
        print(f"| {test_file:<20} | {'NOT FOUND':<12} | {'-':<12} | {'-':<12} | {'-':<10} |")
        continue

    # --- Run under CPython ---
    t0_c = time.perf_counter()
    res_c = subprocess.run(["python3", test_file], capture_output=True, text=True)
    t1_c = time.perf_counter()
    time_c = t1_c - t0_c

    # --- Run under Pyzig ---
    t0_p = time.perf_counter()
    res_p = subprocess.run([pyzig_path, test_file], capture_output=True, text=True)
    t1_p = time.perf_counter()
    time_p = t1_p - t0_p

    # --- Compare correctness ---
    match_status = "FAIL"
    if res_c.returncode == res_p.returncode:
        # Check standard outputs
        if res_c.stdout.strip() == res_p.stdout.strip():
            match_status = "SUCCESS"
        else:
            all_success = False
            # If they differ, print diff for debug
            print(f"\n--- Output mismatch in {test_file} ---")
            print("CPython Output:")
            print(res_c.stdout.strip())
            print("Pyzig Output:")
            print(res_p.stdout.strip())
            print("-" * 50)
    else:
        all_success = False

    # --- Calculate speedup ---
    speedup = f"{time_c / time_p:.2f}x"

    # --- Format row ---
    print(f"| {test_file:<20} | {match_status:<12} | {time_c:.4f}s      | {time_p:.4f}s      | {speedup:<10} |")

print("=" * 70)
if all_success:
    print(f"{'ALL TESTS PASSED SUCCESSFULLY!':^70}")
else:
    print(f"{'SOME TESTS FAILED CORRECTNESS MATCHING!':^70}")
print("=" * 70)
