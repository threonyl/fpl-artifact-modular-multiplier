r"""
Python runner for the modadd cocotb testbench.

Usage
-----
# Run with default simulator (Icarus Verilog):
    python run_modadd.py

# Choose a different simulator:
    SIM=questa python run_modadd.py

# Enable waveform dumping:
    WAVES=1 python run_modadd.py

# Run a single test by name:
    COCOTB_TESTCASE=test_corner_cases python run_modadd.py

# Enable fixed-modulus mode with a specific Q_VALUE (hex accepted):
    FIXED_Q=1 Q_VALUE=0xFFFFFFFD python run_modadd.py

# Via pytest (the test_ prefix makes it auto-discoverable):
    pytest run_modadd.py
    pytest run_modadd.py -v -s          # verbose, print logs
    pytest run_modadd.py -k corner      # filter by name

Virtual-environment setup (one-time)
-------------------------------------
    python -m venv .venv
    source .venv/bin/activate           # Windows: .venv\Scripts\activate
    pip install cocotb cocotb-tools     # then install your simulator separately
    python run_modadd.py
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

HDL_TOPLEVEL = "modadd"
TEST_MODULE  = "test_modadd"

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


def _verilog_hex_literal(value: int, width: int | None = None) -> str:
    """Format a potentially wide integer as a Verilog hex literal.

    Simulators (Verilator in particular) cannot parse arbitrarily large
    plain-decimal integers on the ``-G`` command line.  A Verilog-style
    hex literal such as ``398'h1a0111ea...`` is accepted by all major
    simulators and avoids the issue entirely.

    Parameters
    ----------
    value : int
        Non-negative integer to format.
    width : int, optional
        Explicit bit-width for the literal.  When *None* the minimum
        width required to represent *value* is used (at least 1).
    """
    if width is None:
        width = max(value.bit_length(), 1)
    return f"{width}'h{value:x}"


def _collect_parameters() -> dict:
    """
    Collect DUT parameter overrides from environment variables.

    Supported environment variables (all optional):
        LOGQ, REG_IN, REG_OUT, REG_ADD, CONC_ADDSUB,
        FIXED_Q, Q_VALUE

    Values are parsed with Python's int() auto-base detection, so hex
    (0x...), binary (0b...), octal (0o...) and plain decimal are all accepted.

    Q_VALUE is emitted as a Verilog hex literal (e.g. ``398'h1a01...``)
    because simulators such as Verilator cannot parse very large decimal
    integers on the command line.  The bit-width is taken from LOGQ when
    available, otherwise inferred from the value itself.
    """
    params = {}
    raw: dict[str, int] = {}          # keep parsed ints for post-processing
    for name in ("LOGQ", "REG_IN", "REG_OUT", "REG_ADD", "CONC_ADDSUB",
                  "FIXED_Q", "Q_VALUE"):
        val = os.environ.get(name)
        if val is not None:
            as_int = int(val, 0)
            raw[name] = as_int
            params[name] = str(as_int)

    # Reformat Q_VALUE as a Verilog hex literal so Verilator (and others)
    # can handle arbitrarily wide values on the command line.
    if "Q_VALUE" in raw:
        width = raw.get("LOGQ")       # use LOGQ if provided, else auto
        params["Q_VALUE"] = _verilog_hex_literal(raw["Q_VALUE"], width)

    return params


def test_modadd():
    """
    Build and run all modadd cocotb tests.

    The `test_` prefix means pytest discovers and executes this function
    automatically when you run `pytest run_modadd.py`.
    """
    sim   = os.environ.get("SIM",   "icarus")
    waves = os.environ.get("WAVES", "0") not in ("0", "false", "no", "")

    # Wipe the build directory so nothing stale is carried forward
    if BUILD_DIR.exists():
        shutil.rmtree(BUILD_DIR)

    # Write `timescale directive BEFORE calling runner.build().
    # This file is included first in the sources list so Icarus sees the
    # directive before it processes any other source file.
    ts_file = _write_timescale_file(BUILD_DIR)

    runner = get_runner(sim)

    # ------------------------------------------------------------------
    # Simulator-specific build arguments
    # ------------------------------------------------------------------
    build_args = []
    if sim == "verilator" and waves:
        build_args.append("--trace-fst")

    # ------------------------------------------------------------------
    # DUT parameter overrides
    # ------------------------------------------------------------------
    parameters = _collect_parameters()

    # ------------------------------------------------------------------
    # Build / elaboration
    # ------------------------------------------------------------------
    runner.build(
        # timescale file must come first so its directive applies globally
        sources=[str(ts_file), str(RTL_DIR / "modadd.sv"), str(RTL_DIR / "modadd_pkg.sv")],
        hdl_toplevel=HDL_TOPLEVEL,
        build_dir=str(BUILD_DIR),
        build_args=build_args,
        parameters=parameters,
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
        #   COCOTB_TESTCASE=test_corner_cases python run_modadd.py
        testcase=os.environ.get("COCOTB_TESTCASE"),
        build_dir=str(BUILD_DIR),
        waves=waves,
    )


if __name__ == "__main__":
    test_modadd()