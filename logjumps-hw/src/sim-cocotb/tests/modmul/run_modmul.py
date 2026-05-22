r"""
Python runner for the modmul cocotb testbench.

Usage
-----
# Run with default simulator (Icarus Verilog):
    python run_modmul.py

# Choose a different simulator:
    SIM=questa python run_modmul.py

# Enable waveform dumping:
    WAVES=1 python run_modmul.py

# Run a single test by name:
    COCOTB_TESTCASE=test_corner_cases python run_modmul.py

# Override LOGR explicitly (default is ceil(LOGQ/LOGW)*LOGW):
    LOGW=17 LOGQ=381 LOGR=391 python run_modmul.py

Fixed-modulus mode (FIXED_Q)
----------------------------
When FIXED_Q=1 the modulus and all derived Montgomery constants become
compile-time parameters.  The runner auto-computes all derived constants
from just Q_VALUE (plus LOGW, LOGQ and optionally LOGR for the bit-widths):

    FIXED_Q=1 Q_VALUE=0x7FFFFFFFFFFFFFFFFFFFFFFD python run_modmul.py

The runner derives MU_VALUE, RHO_VALUES, RHO_MU_VALUES, and
ACC_MAX_COND_SUB automatically.  Explicitly provided values take
precedence over auto-computed ones.

    # Custom dimensions:
    FIXED_Q=1 LOGW=17 LOGQ=51 Q_VALUE=0x7FFFFFFFFFFF5 python run_modmul.py

    # Override a single derived constant:
    FIXED_Q=1 Q_VALUE=0x... MU_VALUE=0x1234 python run_modmul.py

# Via pytest (the test_ prefix makes it auto-discoverable):
    pytest run_modmul.py
    pytest run_modmul.py -v -s          # verbose, print logs
    pytest run_modmul.py -k corner      # filter by name

Virtual-environment setup (one-time)
-------------------------------------
    python -m venv .venv
    source .venv/bin/activate           # Windows: .venv\Scripts\activate
    pip install cocotb cocotb-tools     # then install your simulator separately
    python run_modmul.py
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

HDL_TOPLEVEL = "modmul"
TEST_MODULE  = "test_modmul"

# Time unit and precision used throughout the testbench
HDL_TIMEUNIT      = "1ns"
HDL_TIMEPRECISION = "1ps"

# RTL defaults used when LOGW / LOGQ / LOGR are not overridden on the command line
DEFAULT_LOGW = 17
DEFAULT_LOGQ = 381
DEFAULT_LOGR = DEFAULT_LOGW * ((DEFAULT_LOGQ + DEFAULT_LOGW - 1) // DEFAULT_LOGW)


# ---------------------------------------------------------------------------
# RTL source collection
# ---------------------------------------------------------------------------

def _collect_rtl_sources(rtl_dir: Path) -> list[str]:
    """
    Read *compilation_order.f* from *rtl_dir* and return the listed files
    in the exact order specified.  This guarantees that packages are
    compiled before the modules that import them.

    Blank lines and lines starting with '#' are ignored.
    """
    filelist = rtl_dir / "compilation_order.f"
    if not filelist.exists():
        raise FileNotFoundError(
            f"Expected compilation order file at {filelist.resolve()}. "
            f"Create one or update RTL_DIR."
        )

    sources: list[str] = []
    for line in filelist.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        src = rtl_dir / line
        if not src.exists():
            raise FileNotFoundError(
                f"File listed in compilation_order.f not found: {src.resolve()}"
            )
        sources.append(str(src))
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
# Verilog literal formatting
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Montgomery constant computation (mirrors test_modmul.py helpers)
# ---------------------------------------------------------------------------

def _compute_mu(q: int, logw: int) -> int:
    """Compute mu = -q^{-1} mod 2^{LOGW}."""
    W = 1 << logw
    return pow(-q, -1, W)


def _compute_rho(q: int, logw: int, n: int) -> list[int]:
    """Compute rho[i] = (2^{LOGW})^{-i} mod q  for i = 0 ... n-1."""
    W = 1 << logw
    return [pow(W, -i, q) for i in range(n)]


def _pack_rho(rho_list: list[int], logq: int) -> int:
    """Pack rho[1..n-1] into the wide rho bus (LE)."""
    packed = 0
    mask = (1 << logq) - 1
    for k, val in enumerate(rho_list[1:]):
        packed |= (val & mask) << (k * logq)
    return packed


def _pack_rho_mu(rho_list: list[int], mu: int, logw: int) -> int:
    """Compute and pack the rho_mu constants (LE).

    rho_mu[k] = (rho[n-1-k] * mu) mod 2^{LOGW}   for k = 0 .. n-2
    """
    W = 1 << logw
    n = len(rho_list)
    n_mul = n - 1
    packed = 0
    mask = W - 1
    for k in range(n_mul):
        rho_mu_k = (rho_list[n - 1 - k] * mu) & mask
        packed |= rho_mu_k << (k * logw)
    return packed


# ---------------------------------------------------------------------------
# Parameter collection
# ---------------------------------------------------------------------------

def _collect_parameters() -> dict:
    """
    Collect DUT parameter overrides from environment variables.

    When FIXED_Q=1 and Q_VALUE is provided, any missing derived constants
    (MU_VALUE, RHO_VALUES, RHO_MU_VALUES, ACC_MAX_COND_SUB) are
    automatically computed.  Explicitly provided values take precedence
    over auto-computed ones.

    Wide parameters are emitted as Verilog hex literals (e.g. ``381'h1a...``)
    because simulators such as Verilator cannot parse very large decimal
    integers on the command line.
    """
    params = {}
    raw: dict[str, int] = {}

    # -- Scalar parameters (plain decimal on the command line) --
    scalar_names = (
        "LOGW", "LOGQ", "LOGR",
        # Big multiplier
        "MUL_FF_IN", "MUL_FF_MUL", "MUL_FF_OUT",
        "MUL_USE_CSA", "MUL_FF_CSA", "MUL_FF_DIAG", "MUL_FF_CSA_MID",
        "MUL_FF_ADD", "MUL_MORE_DSP", "MUL_NON_STD",
        "MUL_USE_KARATSUBA", "MUL_K_PIPE_DSP", "MUL_K_PIPE_PRE",
        "MUL_K_PIPE_POST", "MUL_K_PIPE_MID",
        # LogJumps reduction
        "LJ_FF_IN", "LJ_FF_MUL", "LJ_FF_OUT",
        "LJ_USE_CSA", "LJ_FF_CSA", "LJ_FF_DIAG", "LJ_FF_CSA_MID",
        "LJ_FF_ADD", "LJ_MORE_DSP", "LJ_NON_STD",
        "LJ_FF_MR_POST", "LJ_FF_JOIN_ADD", "LJ_DSP_SMALL", "LJ_FF_RM",
        "LJ_MT_REG_PERIOD", "LJ_MT_REG_IN", "LJ_MT_REG_OUT", "LJ_MT_USE_CSA",
        # modacc mode
        "ACC_USE_ADDTREE", "ACC_MAX_COND_SUB",
        "ACC_AT_REG_PERIOD", "ACC_AT_REG_IN", "ACC_AT_REG_OUT", "ACC_AT_USE_CSA",
        "ACC_CS_REG_PERIOD", "ACC_CS_REG_OUT",
        "ACC_AT_FF_ADD",
        # Fixed-modulus mode
        "FIXED_Q",
    )
    for name in scalar_names:
        val = os.environ.get(name)
        if val is not None:
            as_int = int(val, 0)
            raw[name] = as_int
            params[name] = str(as_int)

    # -- Wide parameters: parse from env first (explicit overrides) --
    for name in ("Q_VALUE", "MU_VALUE", "RHO_VALUES", "RHO_MU_VALUES"):
        val = os.environ.get(name)
        if val is not None:
            raw[name] = int(val, 0)

    # -- Auto-compute FIXED_Q derived constants -----------------------
    #
    # When FIXED_Q=1 and Q_VALUE is provided, compute any missing
    # constants.  Explicit env-var values take precedence.
    fixed_q = raw.get("FIXED_Q", 0)
    q_val   = raw.get("Q_VALUE")

    if fixed_q and q_val is not None:
        logw = raw.get("LOGW", DEFAULT_LOGW)
        logq = raw.get("LOGQ", DEFAULT_LOGQ)
        logr = raw.get("LOGR", logw * ((logq + logw - 1) // logw))
        n = logr // logw                # total limbs (from LOGR)
        n_mul = n - 1                   # number of dot-product multipliers

        # mu = -q^{-1} mod 2^{LOGW}
        if "MU_VALUE" not in raw:
            mu_auto = _compute_mu(q_val, logw)
            raw["MU_VALUE"] = mu_auto
            print(f"  auto MU_VALUE      = {mu_auto:#x}")
        mu = raw["MU_VALUE"]

        # rho[0..n-1] = (2^{LOGW})^{-i} mod q
        rho_list = _compute_rho(q_val, logw, n)

        # RHO_VALUES: packed rho[1..n-1]
        if "RHO_VALUES" not in raw:
            rho_packed = _pack_rho(rho_list, logq)
            raw["RHO_VALUES"] = rho_packed
            rho_hex = f"{rho_packed:#x}"
            print(f"  auto RHO_VALUES    = {rho_hex[:72]}..."
                  if len(rho_hex) > 72 else
                  f"  auto RHO_VALUES    = {rho_hex}")

        # RHO_MU_VALUES: packed rho_mu[0..n-2]
        if "RHO_MU_VALUES" not in raw:
            rho_mu_packed = _pack_rho_mu(rho_list, mu, logw)
            raw["RHO_MU_VALUES"] = rho_mu_packed
            rm_hex = f"{rho_mu_packed:#x}"
            print(f"  auto RHO_MU_VALUES = {rm_hex[:72]}..."
                  if len(rm_hex) > 72 else
                  f"  auto RHO_MU_VALUES = {rm_hex}")

        # ACC_MAX_COND_SUB: floor(sum(rho[1..n-1]) / q) + 1
        #   This is the tightest safe bound for the binary-search
        #   conditional subtraction chain in the modacc tree.
        #   Only auto-computed when not explicitly provided.
        if "ACC_MAX_COND_SUB" not in raw:
            rho_sum = sum(rho_list[1:])          # rho[1] + ... + rho[n-1]
            acc_mcs = rho_sum // q_val + 1
            raw["ACC_MAX_COND_SUB"] = acc_mcs
            params["ACC_MAX_COND_SUB"] = str(acc_mcs)
            print(f"  auto ACC_MAX_COND_SUB = {acc_mcs}"
                  f"  (floor(sum_rho/q)={rho_sum // q_val})")

    # -- Format all wide parameters as Verilog hex literals -----------
    logq = raw.get("LOGQ", DEFAULT_LOGQ)
    logw = raw.get("LOGW", DEFAULT_LOGW)
    logr = raw.get("LOGR", logw * ((logq + logw - 1) // logw))
    n_mul = logr // logw - 1

    wide_widths = {
        "Q_VALUE":        logq,
        "MU_VALUE":       logw,
        "RHO_VALUES":     n_mul * logq,
        "RHO_MU_VALUES":  n_mul * logw,
    }

    for name, width in wide_widths.items():
        if name in raw:
            params[name] = _verilog_hex_literal(raw[name], width)

    return params


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def test_modmul():
    """
    Build and run all modmul cocotb tests.

    The `test_` prefix means pytest discovers and executes this function
    automatically when you run `pytest run_modmul.py`.
    """
    sim   = os.environ.get("SIM",   "icarus")
    waves = os.environ.get("WAVES", "0") not in ("0", "false", "no", "")

    # Wipe the build directory so nothing stale is carried forward
    if BUILD_DIR.exists():
        shutil.rmtree(BUILD_DIR)

    # Write `timescale directive BEFORE calling runner.build().
    ts_file = _write_timescale_file(BUILD_DIR)

    # Collect every RTL file in the directory
    rtl_sources = _collect_rtl_sources(RTL_DIR)

    if not rtl_sources:
        raise FileNotFoundError(
            f"No .sv or .v files found in {RTL_DIR.resolve()}. "
            f"Check that RTL_DIR points to the correct location."
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
    # DUT parameter overrides
    # ------------------------------------------------------------------
    parameters = _collect_parameters()

    if parameters:
        print(f"Parameter overrides:")
        for k, v in parameters.items():
            # Truncate very wide hex literals for readability
            display = v if len(v) < 80 else v[:40] + "..." + v[-20:]
            print(f"  {k} = {display}")

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
        #   COCOTB_TESTCASE=test_random_pipeline python run_modmul.py
        testcase=os.environ.get("COCOTB_TESTCASE"),
        build_dir=str(BUILD_DIR),
        waves=waves,
    )


if __name__ == "__main__":
    test_modmul()