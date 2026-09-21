#!/bin/sh
set -e

# Experiment 008: Host-side cost of Metal platform
# Target: M3 Ultra and M2

OUT_PATH="${1:-/tmp/results-008.json}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Building Experiment 008 harnesses ==="
swiftc -O "$DIR/harness_q1_q3.swift" -o "$DIR/q1_dispatch"
swiftc -O "$DIR/harness_q2.swift" -o "$DIR/q2_step"
swiftc -O "$DIR/harness_q4.swift" -o "$DIR/q4_storage"
clang++ -std=c++17 -O3 -I"$DIR/metal-cpp" -framework Metal -framework Foundation "$DIR/q5_metal_cpp.cpp" -o "$DIR/q5_cpp"
clang -O3 -framework Metal -framework Foundation "$DIR/q5_objc.m" -o "$DIR/q5_objc"
swiftc -O "$DIR/q5_swift.swift" -o "$DIR/q5_swift"
swiftc -O "$DIR/harness_q6.swift" -o "$DIR/q6_timestamps"
swiftc -O "$DIR/harness_q7.swift" -o "$DIR/q7_hangs"
swiftc -O "$DIR/harness_q8.swift" -o "$DIR/q8_fma"

echo "=== Running Experiment 008 matrix ==="
TMP_DIR=$(mktemp -d /tmp/exp008.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "1/7 Running Q1 and Q3 (dispatch overhead and Metal 4)..."
"$DIR/q1_dispatch" "$TMP_DIR/q1.json"

echo "2/7 Running Q2 (50-dispatch real MD kernel step replay)..."
"$DIR/q2_step" "$TMP_DIR/q2.json"

echo "3/7 Running Q4 (storage modes and energy readback)..."
"$DIR/q4_storage" "$TMP_DIR/q4.json"

echo "4/7 Running Q5 (metal-cpp wrapper overhead)..."
"$DIR/q5_cpp" > "$TMP_DIR/q5_cpp.json"
"$DIR/q5_objc" > "$TMP_DIR/q5_objc.json"
"$DIR/q5_swift" > "$TMP_DIR/q5_swift.json"

echo "5/7 Running Q6 (timestamp units)..."
"$DIR/q6_timestamps" "$TMP_DIR/q6.json"

echo "6/7 Running Q7 (hang and fault modes)..."
"$DIR/q7_hangs" "$TMP_DIR/q7.json"

echo "7/7 Running Q8 (bonded FMA contraction)..."
"$DIR/q8_fma" "$TMP_DIR/q8.json"

echo "=== Aggregating results into $OUT_PATH ==="
python3 - "$TMP_DIR" "$OUT_PATH" << 'EOF'
import sys, os, json, subprocess

tmp_dir = sys.argv[1]
out_path = sys.argv[2]

q1 = json.load(open(os.path.join(tmp_dir, "q1.json")))
q2 = json.load(open(os.path.join(tmp_dir, "q2.json")))
q4 = json.load(open(os.path.join(tmp_dir, "q4.json")))
q5_cpp = json.load(open(os.path.join(tmp_dir, "q5_cpp.json")))
q5_objc = json.load(open(os.path.join(tmp_dir, "q5_objc.json")))
q5_swift = json.load(open(os.path.join(tmp_dir, "q5_swift.json")))
q6 = json.load(open(os.path.join(tmp_dir, "q6.json")))
q7 = json.load(open(os.path.join(tmp_dir, "q7.json")))
q8 = json.load(open(os.path.join(tmp_dir, "q8.json")))

# System details
chip_name = q1.get("device_name", "Apple Silicon")
os_version = subprocess.check_output(["sw_vers", "-productVersion"]).decode().strip()
build_version = subprocess.check_output(["sw_vers", "-buildVersion"]).decode().strip()

# Verification checks
checks = {
    "q1_dispatch": q1["verification"]["status"] == "PASS",
    "q2_step_replay": q2["verification"]["status"] == "PASS",
    "q4_storage_modes": q4["verification"]["status"] == "PASS",
    "q5_metal_cpp": q5_cpp["verification"] == "PASS",
    "q5_objc": q5_objc["verification"] == "PASS",
    "q5_swift": q5_swift["verification"] == "PASS",
    "q6_timestamps": q6["verification"]["status"] == "PASS",
    "q7_hangs": q7["verification"]["status"] == "PASS",
    "q8_fma": q8["verification"]["status"] == "PASS"
}

all_passed = all(checks.values())

consolidated = {
    "system_info": {
        "device_name": chip_name,
        "macos_version": os_version,
        "macos_build": build_version,
        "command": "sh experiments/008-host-cost/run.sh"
    },
    "verification": {
        "status": "PASS" if all_passed else "FAIL",
        "all_methods_checked_on_host": True,
        "section_checks": checks
    },
    "q1_per_dispatch_cost": {
        "repeats": q1["repeats"],
        "methods": q1["methods"]
    },
    "q2_step_workload_replay": {
        "num_atoms": q2["num_atoms"],
        "dispatches_per_step": q2["dispatches_per_step"],
        "steps_per_repeat": q2["steps_per_repeat"],
        "repeats": q2["repeats"],
        "configurations": q2["configurations"]
    },
    "q3_metal4": {
        "metal4_supported_without_xcode": q1.get("metal4_supported_without_xcode", False),
        "methods": {
            "metal4_one_encoder": q1["methods"].get("metal4_one_encoder"),
            "metal4_encoder_per_kernel": q1["methods"].get("metal4_encoder_per_kernel")
        }
    },
    "q4_storage_modes": {
        "buffer_size_mb": q4["buffer_size_mb"],
        "elements": q4["elements"],
        "repeats": q4["repeats"],
        "shared_mode": q4["shared_mode"],
        "private_mode": q4["private_mode"],
        "readback_penalty_private_us": q4["readback_penalty_private_us"],
        "bandwidth_difference_pct": q4["bandwidth_difference_pct"]
    },
    "q5_wrapper_overhead": {
        "dispatches": q5_cpp["dispatches"],
        "metal_cpp": {
            "median_us_per_dispatch": q5_cpp["median_us_per_dispatch"],
            "iqr_us_per_dispatch": q5_cpp["iqr_us_per_dispatch"]
        },
        "objc": {
            "median_us_per_dispatch": q5_objc["median_us_per_dispatch"],
            "iqr_us_per_dispatch": q5_objc["iqr_us_per_dispatch"]
        },
        "swift": {
            "median_us_per_dispatch": q5_swift["median_us_per_dispatch"],
            "iqr_us_per_dispatch": q5_swift["iqr_us_per_dispatch"]
        },
        "delta_cpp_vs_objc_ns": (q5_cpp["median_us_per_dispatch"] - q5_objc["median_us_per_dispatch"]) * 1000.0
    },
    "q6_timestamp_units": {
        "iterations": q6["iterations"],
        "mach_timebase_numer": q6["mach_timebase_numer"],
        "mach_timebase_denom": q6["mach_timebase_denom"],
        "conversion_factor_ns_per_tick": q6["conversion_factor_ns_per_tick"],
        "metal_wall_ms": q6["metal_wall_ms"],
        "metal_gpu_ms": q6["metal_gpu_ms"],
        "opencl_wall_ms": q6["opencl_wall_ms"],
        "opencl_raw_diff_ticks": q6["opencl_raw_diff_ticks"],
        "opencl_if_ns_ms": q6["opencl_if_ns_ms"],
        "opencl_if_mach_ticks_ms": q6["opencl_if_mach_ticks_ms"],
        "ratio_opencl_wall_to_raw": q6["ratio_opencl_wall_to_raw"]
    },
    "q7_hang_modes": {
        "modes": q7["modes"]
    },
    "q8_bonded_fma_contraction": {
        "tiny_kernel_verification": q8["tiny_kernel_verification"],
        "bonded_forces_comparison": q8["bonded_forces_comparison"]
    }
}

os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
with open(out_path, "w") as f:
    json.dump(consolidated, f, indent=2, sort_keys=True)

print(f"Results successfully written to {out_path}")
print(f"Overall verification status: {'PASS' if all_passed else 'FAIL'}")

if not all_passed:
    print("FAILED checks:", [k for k, v in checks.items() if not v], file=sys.stderr)
    sys.exit(1)
EOF

echo "=== Gate verification passed ==="
