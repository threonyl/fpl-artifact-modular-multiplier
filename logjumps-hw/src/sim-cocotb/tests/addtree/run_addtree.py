r"""
Python runner for the addtree cocotb testbench.

Usage
-----
# Run with default simulator (Icarus Verilog):
    python run_addtree.py

# Choose a different simulator:
    SIM=questa python run_addtree.py

# Enable waveform dumping:
    WAVES=1 python run_addtree.py

# Run a single test by name:
    COCOTB_TESTCASE=test_corner_cases python run_addtree.py

# Via pytest (the test_ prefix makes it auto-discoverable):
    pytest run_addtree.py
    pytest run_addtree.py -v -s          # verbose, print logs
    pytest run_addtree.py -k corner      # filter by name

Virtual-environment setup (one-time)
-------------------------------------
    python -m venv .venv
    source .venv/bin/activate           # Windows: .venv\Scripts\activate
    pip install cocotb cocotb-tools     # then install your simulator separately
    python run_addtree.py
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

HDL_TOPLEVEL = "addtree"
TEST_MODULE  = "test_addtree"

# Time unit and precision used throughout the testbench
HDL_TIMEUNIT      = "1ns"
HDL_TIMEPRECISION = "1ps"


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


def test_addtree():
    """
    Build and run all addtree cocotb tests.

    The `test_` prefix means pytest discovers and executes this function
    automatically when you run `pytest run_addtree.py`.
    """
    sim   = os.environ.get("SIM",   "icarus")
    waves = os.environ.get("WAVES", "0") not in ("0", "false", "no", "")

    # Wipe the build directory so nothing stale is carried forward
    if BUILD_DIR.exists():
        shutil.rmtree(BUILD_DIR)

    # Write `timescale directive BEFORE calling runner.build().
    ts_file = _write_timescale_file(BUILD_DIR)

    runner = get_runner(sim)

    # ------------------------------------------------------------------
    # Simulator-specific build arguments
    # ------------------------------------------------------------------
    build_args = []
    if sim == "verilator" and waves:
        build_args.append("--trace-fst")

    # ------------------------------------------------------------------
    # Build / elaboration
    #
    # csa_2 sources are always compiled so that addtree can be
    # elaborated with USE_CSA = 0 or 1 without rebuilding.
    # ------------------------------------------------------------------
    runner.build(
        # timescale file must come first so its directive applies globally
        sources=[
            str(ts_file),
            str(RTL_DIR / "csa_2_pkg.sv"),
            str(RTL_DIR / "csa_2.sv"),
            str(RTL_DIR / "addtree_pkg.sv"),
            str(RTL_DIR / "addtree.sv"),
        ],
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
        #   COCOTB_TESTCASE=test_corner_cases python run_addtree.py
        testcase=os.environ.get("COCOTB_TESTCASE"),
        build_dir=str(BUILD_DIR),
        waves=waves,
    )


if __name__ == "__main__":
    test_addtree()