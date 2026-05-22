r"""
Python runner for the intmul_wrapper cocotb testbench.

Usage
-----
# Run with default simulator (Icarus Verilog):
    python run_intmul_wrapper.py

# Choose a different simulator:
    SIM=questa python run_intmul_wrapper.py

# Enable waveform dumping:
    WAVES=1 python run_intmul_wrapper.py

# Run a single test by name:
    COCOTB_TESTCASE=test_random_pipeline python run_intmul_wrapper.py

# Via pytest (the test_ prefix makes it auto-discoverable):
    pytest run_intmul_wrapper.py
    pytest run_intmul_wrapper.py -v -s          # verbose, print logs
    pytest run_intmul_wrapper.py -k corner      # filter by name

Virtual-environment setup (one-time)
-------------------------------------
    python -m venv .venv
    source .venv/bin/activate           # Windows: .venv\Scripts\activate
    pip install cocotb cocotb-tools     # then install your simulator separately
    python run_intmul_wrapper.py
"""

import os
import shutil
from pathlib import Path

from cocotb_tools.runner import get_runner

# ---------------------------------------------------------------------------
# Paths - adjust RTL_DIR if your directory layout is different
# ---------------------------------------------------------------------------
THIS_DIR     = Path(__file__).resolve().parent
RTL_DIR      = THIS_DIR / ".." / ".." / ".." / "rtl"   # .../sim-cocotb/tests/../../../rtl
BUILD_DIR    = THIS_DIR / "sim_build"

HDL_TOPLEVEL = "intmul_wrapper"
TEST_MODULE  = "test_intmul_wrapper"

# Time unit and precision used throughout the testbench
HDL_TIMEUNIT      = "1ns"
HDL_TIMEPRECISION = "1ps"

# Files required by intmul_wrapper, listed in compilation order
# (packages before the modules that import them).
# Only these are compiled, any new, unrelated files added to
# compilation_order.f will be ignored automatically.
_REQUIRED_STEMS = {
    "dsp_pkg",
    "csa_2_pkg",
    "csa_2",
    "csa_tree_pkg",
    "csa_tree",
    "dsp_mul",
    "mac_std_pkg",
    "mac_std",
    "intmul_nonstd_BBxAB_pkg",
    "intmul_nonstd_BBxAB",
    "intmul_nonstd_BBAxBBA_pkg",
    "intmul_nonstd_BBAxBBA",
    "karatsuba_mul_pkg",
    "karatsuba_mul",
    "intmul_wrapper_pkg",
    "intmul_wrapper",
}


# ---------------------------------------------------------------------------
# RTL source collection
# ---------------------------------------------------------------------------

def _collect_rtl_sources(rtl_dir: Path) -> list[str]:
    """
    Read *compilation_order.f* from *rtl_dir* and return only the files
    that intmul_wrapper actually depends on, in the exact order
    specified by the file.

    Blank lines and lines starting with '#' are ignored.
    Only lines whose stem (filename without extension) appears in
    ``_REQUIRED_STEMS`` are kept; everything else is silently skipped.
    """
    filelist = rtl_dir / "compilation_order.f"
    if not filelist.exists():
        raise FileNotFoundError(
            f"Expected compilation order file at {filelist.resolve()}.\nCreate one or update RTL_DIR."
        )

    sources: list[str] = []
    found_stems: set[str] = set()
    for line in filelist.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        stem = Path(line).stem                 # e.g. "mac_std_pkg"
        if stem not in _REQUIRED_STEMS:
            continue

        src = rtl_dir / line
        if not src.exists():
            raise FileNotFoundError(
                f"File listed in compilation_order.f not found: {src.resolve()}"
            )
        sources.append(str(src))
        found_stems.add(stem)

    missing = _REQUIRED_STEMS - found_stems
    if missing:
        raise FileNotFoundError(
            f"Required source(s) not found in compilation_order.f:\n{', '.join(sorted(missing))}"
        )

    return sources


# ---------------------------------------------------------------------------
# Timescale helper (Icarus needs an explicit `timescale somewhere)
# ---------------------------------------------------------------------------

def _write_timescale_file(build_dir: Path) -> Path:
    """
    Write a tiny Verilog file that sets the timescale for Icarus.

    The Python runner does not generate the +timescale command-file entry
    that the Makefile flow creates, so Icarus falls back to a 1-second
    precision and Clock(dut.clk, 10, 'ns') raises a ValueError.  Including
    a source file with an explicit `timescale directive is the most reliable
    fix: it is picked up at compile time regardless of how environment
    variables are propagated to subprocesses.
    """
    build_dir.mkdir(parents=True, exist_ok=True)
    ts_file = build_dir / "cocotb_timescale.v"
    ts_file.write_text(f"`timescale {HDL_TIMEUNIT}/{HDL_TIMEPRECISION}\n")
    return ts_file


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def test_intmul_wrapper():
    """
    Build and run all intmul_wrapper cocotb tests.

    The `test_` prefix means pytest discovers and executes this function
    automatically when you run `pytest run_intmul_wrapper.py`.
    """
    sim   = os.environ.get("SIM",   "icarus")
    waves = os.environ.get("WAVES", "0") not in ("0", "false", "no", "")

    # Wipe the build directory so nothing stale is carried forward
    if BUILD_DIR.exists():
        shutil.rmtree(BUILD_DIR)

    # Write `timescale directive BEFORE calling runner.build().
    ts_file = _write_timescale_file(BUILD_DIR)

    # Collect every relevant RTL file in the directory
    rtl_sources = _collect_rtl_sources(RTL_DIR)

    if not rtl_sources:
        raise FileNotFoundError(
            f"No .sv or .v files found in {RTL_DIR.resolve()}.\nCheck that RTL_DIR points to the correct location."
        )

    print(f"RTL directory : {RTL_DIR.resolve()}")
    print(f"RTL sources   : {len(rtl_sources)} file(s)")
    for src in rtl_sources:
        print(f"  {Path(src).name}")

    runner = get_runner(sim)

    # ------------------------------------------------------------------
    # Simulator-specific build arguments
    # ------------------------------------------------------------------
    build_args = []
    if sim == "verilator" and waves:
        build_args.append("--trace-fst")

    # ------------------------------------------------------------------
    # Build / elaboration
    # ------------------------------------------------------------------
    runner.build(
        # timescale file first so its directive applies globally,
        # then all RTL sources (packages before modules)
        sources=[str(ts_file)] + rtl_sources,
        hdl_toplevel=HDL_TOPLEVEL,
        build_dir=str(BUILD_DIR),
        build_args=build_args,
        waves=waves,
    )

    # ------------------------------------------------------------------
    # Simulation / test execution
    # ------------------------------------------------------------------
    runner.test(
        hdl_toplevel=HDL_TOPLEVEL,
        hdl_toplevel_lang="verilog",
        test_module=TEST_MODULE,
        # Pass through COCOTB_TESTCASE so a single test can be selected:
        #   COCOTB_TESTCASE=test_random_pipeline python run_intmul_wrapper.py
        testcase=os.environ.get("COCOTB_TESTCASE"),
        build_dir=str(BUILD_DIR),
        waves=waves,
    )


if __name__ == "__main__":
    test_intmul_wrapper()