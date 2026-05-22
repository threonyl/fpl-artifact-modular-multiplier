"""
Cocotb testbench for the logjumps (parallel-tree LogJumps Montgomery reduction) module.

Functional specification
------------------------
The module computes:

    D = C * 2^{-LOGR}  mod q

where  C in [0, (q-1)*(R-1)],  R = 2^{LOGR},  and q is an odd modulus
that fits in LOGQ bits.

NOTE: The default setup (LOGQ < LOGR) ONLY supports C in [0, (q-1)*(q-1)].
To remove this limitation, set LOGQ equal to LOGR at the cost of more area.

LOGR is the Montgomery constant width: the smallest multiple of LOGW
that is >= LOGQ.  Default: LOGW * ceil(LOGQ / LOGW).

Precomputed constants supplied per-modulus:
    rho[i] = (2^{LOGW})^{-i} mod q     for i = 1 ... n-1      (packed LE)
    mu     = -q^{-1}         mod 2^{LOGW}

where n = LOGR / LOGW (total limbs).

When FIXED_Q = 0 (default):
    The rho-mu constants (rho[i]*mu mod 2^{LOGW}) are computed internally
    by small intmul_wrapper instances and are *not* module inputs.  The
    run-time ports q, rho, mu carry the modulus and derived constants.

When FIXED_Q = 1:
    The modulus and all derived constants are compile-time parameters
    (Q_VALUE, MU_VALUE, RHO_VALUES, RHO_MU_VALUES).  The run-time ports
    q, rho, mu are ignored by the hardware.  Tests that change the modulus
    at run time are skipped in this mode.

Pipeline latency
----------------
The full pipeline depth is exposed as the localparam LAT inside the DUT:

    LAT = max(DOT_LAT + ACC_LAT,
              RM_MUL_LAT + FF_RM + MVAL_LAT + MR_LAT)
          + FF_JOIN_ADD + FF_MR_POST + FF_OUT

When FIXED_Q = 1, RM_MUL_LAT = 0 (rho*mu multipliers eliminated),
so Path A is shorter than in the variable-modulus configuration.

All inputs (C, q, rho, mu) for a given transaction are presented on the
same clock edge; internal delay chains inside the module align each
signal to the pipeline stage that consumes it.

Default parameters (LOGW=17, LOGQ=381, LOGR=391, FF_IN=1, FF_MUL=1,
                    FF_OUT=1, USE_CSA=1, FF_CSA=1, FF_DIAG=0,
                    FF_CSA_MID=0, FF_ADD=0, MORE_DSP=1, NON_STD=0,
                    FF_MR_POST=0, FF_JOIN_ADD=1, DSP_SMALL=1, FF_RM=1,
                    ACC_AT_FF_ADD=1):
    n = LOGR/LOGW = 23 limbs,  N_MUL = 22 dot-product multipliers,
    modacc tree with NUM_INPUTS=23 (num_stages=5).
"""

import random
from collections import deque
from math import gcd

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------

def _num_stages(n: int) -> int:
    """Return the number of binary-reduction stages to reduce n inputs to 1."""
    s = 0
    while n > 1:
        n = (n + 1) // 2
        s += 1
    return s


def _golden(C: int, q: int, logr: int) -> int:
    """Golden reference: C * R^{-1} mod q, where R = 2^{LOGR}."""
    R = 1 << logr
    return (C * pow(R, -1, q)) % q


def _compute_rho(q: int, logw: int, n: int) -> list[int]:
    """Compute rho[i] = (2^{LOGW})^{-i} mod q  for i = 0 ... n-1."""
    W = 1 << logw
    return [pow(W, -i, q) for i in range(n)]


def _compute_mu(q: int, logw: int) -> int:
    """Compute mu = -q^{-1} mod 2^{LOGW}."""
    W = 1 << logw
    return pow(-q, -1, W)


def _pack_rho(rho_list: list[int], logq: int) -> int:
    """
    Pack rho[1], rho[2], ..., rho[n-1] into the wide rho bus (LE).

    Bit layout:  rho[1] @ bits [LOGQ-1:0],
                 rho[2] @ bits [2*LOGQ-1:LOGQ], ...
    """
    packed = 0
    mask = (1 << logq) - 1
    for k, val in enumerate(rho_list[1:]):
        packed |= (val & mask) << (k * logq)
    return packed


def _precompute(q: int, logw: int, logq: int, logr: int) -> tuple[int, int]:
    """
    Return (rho_packed, mu) for a given odd modulus q.

    The number of limbs n = LOGR / LOGW determines the rho vector length.
    The rho-mu constants (rho[i]*mu mod 2^{LOGW}) are computed inside
    the DUT (when FIXED_Q=0) and do not need to be supplied externally.
    """
    n = logr // logw
    rho = _compute_rho(q, logw, n)
    mu = _compute_mu(q, logw)
    rho_packed = _pack_rho(rho, logq)
    return rho_packed, mu


def _read_params(dut) -> tuple[int, int, int, int]:
    """Read key synthesis parameters from the DUT."""
    logw = int(dut.LOGW.value)
    logq = int(dut.LOGQ.value)
    logr = int(dut.LOGR.value)
    ff_out = int(dut.FF_OUT.value)
    return logw, logq, logr, ff_out


def _read_fixed_q(dut) -> tuple[bool, int]:
    """Read the FIXED_Q mode and Q_VALUE from the DUT.

    Returns
    -------
    (is_fixed, q_value) : tuple
        is_fixed is True when FIXED_Q=1.
        q_value is the compile-time modulus (only meaningful when is_fixed).
    """
    fixed_q = int(dut.FIXED_Q.value)
    q_value = int(dut.Q_VALUE.value) if fixed_q else 0
    return bool(fixed_q), q_value


def _read_latency(dut) -> int:
    """Read the total pipeline depth from the DUT's LAT localparam."""
    return int(dut.LAT.value)


def _rand_odd_modulus(rng: random.Random, logq: int) -> int:
    """
    Generate a random odd modulus that occupies the full LOGQ-bit range.

    The modulus is forced odd so that gcd(q, 2^LOGW) = 1, which is
    required for both the Montgomery parameter mu and the rho inverses
    to exist.
    """
    lo = (1 << (logq - 1)) + 1      # at least LOGQ bits
    hi = (1 << logq) - 2
    return rng.randint(lo, hi) | 1   # force odd


def _drive_inputs(dut, C_val: int, q: int, rho_packed: int, mu: int):
    """Apply a complete input vector to the DUT ports.

    When FIXED_Q=1 the hardware ignores q, rho, mu, but the testbench
    still drives them to avoid X-propagation in simulation.  The caller
    should pass the matching constants (or zeros) regardless of mode.
    """
    dut.C.value = C_val
    dut.q.value = q
    dut.rho.value = rho_packed
    dut.mu.value = mu


def _effective_q(dut, logw: int, logq: int, logr: int) -> tuple[int, int, int]:
    """Return (q, rho_packed, mu) for the modulus the DUT actually uses.

    When FIXED_Q=1 the hardware uses the compile-time Q_VALUE; the
    testbench must compute rho/mu from that same value.

    When FIXED_Q=0 a default large odd modulus is chosen.
    """
    is_fixed, q_value = _read_fixed_q(dut)
    if is_fixed:
        q = q_value
    else:
        q = (1 << logq) - 3
    rho_packed, mu = _precompute(q, logw, logq, logr)
    return q, rho_packed, mu


# ---------------------------------------------------------------------------
#  Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_latency_detection(dut):
    """
    Log detected parameters and all sub-block pipeline latencies
    so they are visible in the simulation transcript.
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)
    is_fixed, q_value = _read_fixed_q(dut)

    n = logr // logw
    cocotb.log.info(
        f"DUT parameters: LOGW={logw}, LOGQ={logq}, LOGR={logr}, "
        + f"FF_IN={int(dut.FF_IN.value)}, FF_MUL={int(dut.FF_MUL.value)}, "
        + f"FF_OUT={ff_out}, "
        + f"USE_CSA={int(dut.USE_CSA.value)}, FF_CSA={int(dut.FF_CSA.value)}, "
        + f"FF_DIAG={int(dut.FF_DIAG.value)}, "
        + f"FF_CSA_MID={int(dut.FF_CSA_MID.value)}, "
        + f"FF_ADD={int(dut.FF_ADD.value)}, "
        + f"MORE_DSP={int(dut.MORE_DSP.value)}, NON_STD={int(dut.NON_STD.value)}, "
        + f"FF_MR_POST={int(dut.FF_MR_POST.value)}, "
        + f"FF_JOIN_ADD={int(dut.FF_JOIN_ADD.value)}, "
        + f"DSP_SMALL={int(dut.DSP_SMALL.value)}, "
        + f"FF_RM={int(dut.FF_RM.value)}, "
        + f"ACC_AT_FF_ADD={int(dut.ACC_AT_FF_ADD.value)}, "
        + f"FIXED_Q={int(is_fixed)}"
        + (f", Q_VALUE={q_value:#x}" if is_fixed else "")
        + f", n={n} limbs, N_MUL={n-1} dot multipliers, "
        + f"modacc NUM_INPUTS={n}, num_stages={_num_stages(n)}"
    )

    # Read all sub-block latencies exposed as localparams
    dot_lat   = int(dut.DOT_LAT.value)
    acc_lat   = int(dut.ACC_LAT.value)
    mr_lat    = int(dut.MR_LAT.value)
    mval_lat  = int(dut.MVAL_LAT.value)
    rm_mul_lat = int(dut.RM_MUL_LAT.value)
    path_a    = int(dut.PATH_A.value)
    path_b    = int(dut.PATH_B.value)
    join_cyc  = int(dut.JOIN_CYC.value)
    mq_delay  = int(dut.MQ_DELAY.value)
    tacc_delay = int(dut.TACC_DELAY.value)

    cocotb.log.info(
        f"Sub-block latencies: "
        f"DOT_LAT={dot_lat}, ACC_LAT={acc_lat}, "
        f"MR_LAT={mr_lat}, MVAL_LAT={mval_lat}, "
        f"RM_MUL_LAT={rm_mul_lat}"
    )
    if is_fixed:
        cocotb.log.info(
            f"FIXED_Q=1: RM_MUL_LAT={rm_mul_lat} "
            f"(expected 0, rho*mu multipliers eliminated)"
        )
    cocotb.log.info(
        f"Path A = RM_MUL_LAT({rm_mul_lat}) + FF_RM({int(dut.FF_RM.value)}) "
        f"+ MVAL_LAT({mval_lat}) + MR_LAT({mr_lat}) = {path_a}"
    )
    cocotb.log.info(
        f"Path B = DOT_LAT({dot_lat}) + ACC_LAT({acc_lat}) = {path_b}"
    )
    cocotb.log.info(
        f"JOIN_CYC = max({path_a}, {path_b}) = {join_cyc}, "
        f"MQ_DELAY={mq_delay}, TACC_DELAY={tacc_delay}"
    )
    cocotb.log.info(
        f"LAT = JOIN_CYC({join_cyc}) + FF_JOIN_ADD({int(dut.FF_JOIN_ADD.value)}) "
        f"+ FF_MR_POST({int(dut.FF_MR_POST.value)}) "
        f"+ FF_OUT({ff_out}) = {latency}"
    )


@cocotb.test()
async def test_latency_probe(dut):
    """
    Empirically determine the actual pipeline latency by driving a
    known non-trivial input and scanning the output cycle by cycle.

    This catches any mismatch between the DUT's LAT localparam and
    the real pipeline depth.
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr

    # Use C = R (so D = R * R^{-1} mod q = 1)
    C_val = R
    exp = _golden(C_val, q, logr)
    assert exp == 1, "Analytical check: C=R should give D=1"

    HEADROOM = 20
    scan_cycles = latency + HEADROOM

    # Flush with zeros
    _drive_inputs(dut, 0, q, rho_packed, mu)
    await ClockCycles(dut.clk, latency + HEADROOM)

    # Drive the real stimulus
    dut.C.value = C_val

    actual_lat = None
    for cycle in range(scan_cycles):
        await RisingEdge(dut.clk)
        got = int(dut.D.value)
        if got == exp and actual_lat is None:
            actual_lat = cycle

    if actual_lat is None:
        cocotb.log.error(
            f"Expected output {exp:#x} never appeared within "
            f"{scan_cycles} cycles!  Last D = {got:#x}"
        )
        assert False, "Output never matched expected value"

    # Log all sub-block latencies for diagnosis
    cocotb.log.info(
        f"Latency probe: first correct output at cycle {actual_lat} "
        f"(DUT LAT={latency}, "
        f"DOT_LAT={int(dut.DOT_LAT.value)}, "
        f"ACC_LAT={int(dut.ACC_LAT.value)}, "
        f"MR_LAT={int(dut.MR_LAT.value)}, "
        f"MVAL_LAT={int(dut.MVAL_LAT.value)}, "
        f"RM_MUL_LAT={int(dut.RM_MUL_LAT.value)}, "
        f"PATH_A={int(dut.PATH_A.value)}, "
        f"PATH_B={int(dut.PATH_B.value)})"
    )

    assert actual_lat == latency, (
        f"LATENCY MISMATCH: DUT reports LAT={latency} "
        f"but actual pipeline depth is {actual_lat} "
        f"(off by {actual_lat - latency}).  "
        f"Sub-block breakdown: "
        f"DOT_LAT={int(dut.DOT_LAT.value)}, "
        f"ACC_LAT={int(dut.ACC_LAT.value)}, "
        f"MR_LAT={int(dut.MR_LAT.value)}, "
        f"MVAL_LAT={int(dut.MVAL_LAT.value)}, "
        f"RM_MUL_LAT={int(dut.RM_MUL_LAT.value)}, "
        f"PATH_A={int(dut.PATH_A.value)}, "
        f"PATH_B={int(dut.PATH_B.value)}, "
        f"FF_JOIN_ADD={int(dut.FF_JOIN_ADD.value)}, "
        f"FF_MR_POST={int(dut.FF_MR_POST.value)}, "
        f"FF_OUT={ff_out}."
    )


@cocotb.test()
async def test_zero_input(dut):
    """C = 0 must always produce D = 0 regardless of the modulus."""
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)

    _drive_inputs(dut, 0, q, rho_packed, mu)

    flush = max(latency, 1)
    await ClockCycles(dut.clk, flush + 1)

    got = int(dut.D.value)
    assert got == 0, f"Zero input: expected 0, got {got:#x}"
    cocotb.log.info("Zero input test passed.")


@cocotb.test()
async def test_corner_cases(dut):
    """
    Hand-crafted corner-case C values driven through the pipeline
    with a fixed modulus.  Each output is checked exactly `latency`
    cycles after its corresponding input.
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr

    # Build corner-case C values
    c_max = (q - 1) * (q - 1)
    vectors: list[int] = [
        0,                          # zero
        1,                          # smallest positive
        q - 1,                      # largest single-word value < q
        q,                          # exactly q
        q + 1,                      # just above q
        R - 1,                      # all-ones in the lower half
        R,                          # power of two
        R + 1,                      # R boundary
        c_max,                      # maximum valid input (q-1)*(q-1)
        c_max - 1,                  # one below maximum
        (1 << logq) - 1,            # mid-range: 2^LOGQ - 1
        (1 << (2 * logq - 1)),      # MSB of C set
    ]
    # Clip to 2*LOGQ-bit bus width, then discard any that exceed c_max.
    # The hardware only guarantees correct results for C in [0, c_max].
    # With FIXED_Q the modulus can be much smaller than 2^LOGQ, making
    # some of the "large C" corner cases fall outside the valid domain.
    mask_2q = (1 << (2 * logq)) - 1
    vectors = [v & mask_2q for v in vectors]
    vectors = [v for v in vectors if v <= c_max]

    _drive_inputs(dut, 0, q, rho_packed, mu)

    if latency == 0:
        for C_val in vectors:
            dut.C.value = C_val
            await RisingEdge(dut.clk)
            got = int(dut.D.value)
            exp = _golden(C_val, q, logr)
            assert got == exp, (
                f"Corner (comb): C={C_val:#x} -> expected {exp:#x}, got {got:#x}"
            )
        cocotb.log.info("Corner cases passed (combinatorial).")
        return

    expected: deque[int] = deque()
    total_cycles = len(vectors) + latency
    vec_iter = iter(vectors)
    vec_exhausted = False

    for cycle in range(total_cycles):
        if not vec_exhausted:
            try:
                C_val = next(vec_iter)
                dut.C.value = C_val
                expected.append(_golden(C_val, q, logr))
            except StopIteration:
                vec_exhausted = True

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.D.value)
            assert got == exp, (
                f"Corner cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info("All corner cases passed.")


@cocotb.test()
async def test_identity_c_equals_r(dut):
    """
    C = R should yield D = R * R^{-1} mod q = 1.
    This is a useful sanity check that the Montgomery inversion is correct.
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr

    _drive_inputs(dut, R, q, rho_packed, mu)

    flush = max(latency, 1)
    await ClockCycles(dut.clk, flush + 1)

    got = int(dut.D.value)
    assert got == 1, f"C=R identity: expected 1, got {got:#x}"
    cocotb.log.info("C=R identity test passed (D=1).")


@cocotb.test()
async def test_random_pipeline(dut):
    """
    Stress-test with random C values pipelined at full throughput.
    Modulus (q, rho, mu) are held constant; only C changes every cycle.
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr
    c_max = (q - 1) * (q - 1)

    NUM_TESTS = 500
    rng = random.Random(0xBEEF_CAFE)

    _drive_inputs(dut, 0, q, rho_packed, mu)

    if latency == 0:
        for _ in range(NUM_TESTS):
            C_val = rng.randint(0, c_max)
            dut.C.value = C_val
            await RisingEdge(dut.clk)
            got = int(dut.D.value)
            exp = _golden(C_val, q, logr)
            assert got == exp, f"Random comb: C={C_val:#x} exp={exp:#x} got={got:#x}"
        cocotb.log.info(f"Passed {NUM_TESTS} combinatorial random tests.")
        return

    expected: deque[int] = deque()
    total_cycles = NUM_TESTS + latency

    for cycle in range(total_cycles):
        if cycle < NUM_TESTS:
            C_val = rng.randint(0, c_max)
            dut.C.value = C_val
            expected.append(_golden(C_val, q, logr))

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.D.value)
            assert got == exp, (
                f"Random cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(
        f"Passed {NUM_TESTS} pipelined random tests (LAT={latency})."
    )


@cocotb.test()
async def test_max_input(dut):
    """
    Drive the maximum valid input C = (q-1)*(R-1) for several different
    moduli to exercise the upper bound of the reduction range.

    When FIXED_Q=1, the modulus cannot be changed at run time, so only
    a single modulus (Q_VALUE) is tested.
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)
    is_fixed, q_fixed = _read_fixed_q(dut)

    Clock(dut.clk, 10, "ns").start()

    flush = max(latency, 1)
    rng = random.Random(0xDEAD_BEEF)

    if is_fixed:
        moduli = [q_fixed]
    else:
        moduli = [
            (1 << logq) - 3,
            (1 << logq) - 5,
            (1 << logq) - 9,
            _rand_odd_modulus(rng, logq),
            _rand_odd_modulus(rng, logq),
        ]

    for q in moduli:
        R = 1 << logr
        c_max = (q - 1) * (q - 1)
        rho_packed, mu = _precompute(q, logw, logq, logr)

        # Drain pipeline
        _drive_inputs(dut, 0, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        # Apply C_max
        dut.C.value = c_max
        await ClockCycles(dut.clk, flush + 1)

        got = int(dut.D.value)
        exp = _golden(c_max, q, logr)
        assert got == exp, (
            f"Max-input q={q:#x}: expected {exp:#x}, got {got:#x}"
        )

    cocotb.log.info(f"Max-input test passed for {len(moduli)} moduli.")


@cocotb.test()
async def test_changing_modulus_flushed(dut):
    """
    Verify the design handles a mid-stream change of modulus correctly
    when the pipeline is flushed between modulus switches.

    Skipped when FIXED_Q=1 because the modulus is a compile-time constant
    and the q, rho, mu ports are ignored.
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)
    is_fixed, _ = _read_fixed_q(dut)

    if is_fixed:
        cocotb.log.info(
            "FIXED_Q=1, skipping test_changing_modulus_flushed "
            "(q, rho, mu ports are ignored, modulus is compile-time constant)."
        )
        return

    Clock(dut.clk, 10, "ns").start()

    flush = max(latency, 1)

    moduli = [
        (1 << logq) - 3,
        (1 << logq) - 15,
        (1 << (logq - 1)) + 1,    # smaller modulus, still LOGQ bits
    ]

    for q in moduli:
        R = 1 << logr
        c_max = (q - 1) * (q - 1)
        rho_packed, mu = _precompute(q, logw, logq, logr)

        # Drain pipeline with zeros before switching modulus
        _drive_inputs(dut, 0, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        expected: deque[int] = deque()
        rng = random.Random(q & 0xFFFF_FFFF)
        NUM = 50
        total = NUM + latency

        for cycle in range(total):
            if cycle < NUM:
                C_val = rng.randint(0, c_max)
                dut.C.value = C_val
                expected.append(_golden(C_val, q, logr))

            await RisingEdge(dut.clk)

            if latency > 0 and cycle >= latency and expected:
                exp = expected.popleft()
                got = int(dut.D.value)
                assert got == exp, (
                    f"q={q:#x} cycle={cycle}: expected {exp:#x}, got {got:#x}"
                )

        cocotb.log.info(f"Passed flushed modulus q={q:#x}.")


@cocotb.test()
async def test_pipelined_changing_modulus(dut):
    """
    Every clock cycle presents a completely independent (C, q, rho, mu)
    tuple - the modulus changes at full pipeline throughput.

    The DUT's internal delay chains for q, mu, and c_hi must keep each
    transaction's constants aligned with the correct pipeline stage.

    Skipped when FIXED_Q=1 because the modulus is a compile-time constant
    and the q, rho, mu ports are ignored.
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)
    is_fixed, _ = _read_fixed_q(dut)

    if is_fixed:
        cocotb.log.info(
            "FIXED_Q=1, skipping test_pipelined_changing_modulus "
            "(q, rho, mu ports are ignored, modulus is compile-time constant)."
        )
        return

    Clock(dut.clk, 10, "ns").start()

    NUM_TESTS = 300
    rng = random.Random(0xCA_FFEE)

    # Pre-generate all test vectors: (C, q, rho_packed, mu, expected_D)
    test_vectors: list[tuple[int, int, int, int, int]] = []
    for _ in range(NUM_TESTS):
        q = _rand_odd_modulus(rng, logq)
        R = 1 << logr
        c_max = (q - 1) * (q - 1)
        C_val = rng.randint(0, c_max)
        rho_packed, mu = _precompute(q, logw, logq, logr)
        exp = _golden(C_val, q, logr)
        test_vectors.append((C_val, q, rho_packed, mu, exp))

    cocotb.log.info(
        "First 3 vectors: "
        + ", ".join(
            f"(C={C_val:#010x}, q={q:#010x}, exp={exp:#010x})"
            for C_val, q, _, _, exp in test_vectors[:3]
        )
    )

    # Initialise
    C0, q0, rho0, mu0, _ = test_vectors[0]
    _drive_inputs(dut, C0, q0, rho0, mu0)

    expected: deque[int] = deque()
    total_cycles = NUM_TESTS + latency

    for cycle in range(total_cycles):
        if cycle < NUM_TESTS:
            C_val, q, rho_packed, mu, exp = test_vectors[cycle]
            _drive_inputs(dut, C_val, q, rho_packed, mu)
            expected.append(exp)

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.D.value)
            src_idx = cycle - latency
            _, q_src, _, _, _ = test_vectors[src_idx]
            assert got == exp, (
                f"Cycle {cycle} (input #{src_idx}): "
                f"q={q_src:#x} -> expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(
        f"Passed {NUM_TESTS} pipelined independent-(C,q,rho,mu) tests "
        f"(LAT={latency})."
    )


@cocotb.test()
async def test_small_moduli(dut):
    """
    Test with the smallest valid LOGQ-bit odd moduli to exercise
    edge cases in conditional subtraction.

    When FIXED_Q=1, the modulus cannot be changed at run time, so only
    Q_VALUE is tested with the same C-value strategy.
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)
    is_fixed, q_fixed = _read_fixed_q(dut)

    Clock(dut.clk, 10, "ns").start()

    flush = max(latency, 1)

    if is_fixed:
        moduli = [q_fixed]
    else:
        # Smallest LOGQ-bit odd numbers
        base = (1 << (logq - 1))
        moduli = [base + 1, base + 3, base + 7, base + 15]

    rng = random.Random(0x5AA11)

    for q in moduli:
        R = 1 << logr
        c_max = (q - 1) * (q - 1)
        rho_packed, mu = _precompute(q, logw, logq, logr)

        _drive_inputs(dut, 0, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        expected: deque[int] = deque()
        NUM = 50
        total = NUM + latency

        for cycle in range(total):
            if cycle < NUM:
                C_val = rng.randint(0, c_max)
                dut.C.value = C_val
                expected.append(_golden(C_val, q, logr))

            await RisingEdge(dut.clk)

            if latency > 0 and cycle >= latency and expected:
                exp = expected.popleft()
                got = int(dut.D.value)
                assert got == exp, (
                    f"Small-q={q:#x} cycle={cycle}: "
                    f"expected {exp:#x}, got {got:#x}"
                )

    cocotb.log.info(f"Small-moduli test passed for {len(moduli)} moduli.")


@cocotb.test()
async def test_known_values(dut):
    """
    Verify a few analytically known Montgomery reductions.

    For any odd q and R = 2^{LOGR}:
        C = 0            ->  D = 0
        C = R mod (2q)   ->  D = 1          (since R*R^{-1} = 1 mod q)
        C = q*R - R      ->  D = q - 1      (since (q-1)*R * R^{-1} = q-1)
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr

    flush = max(latency, 1)

    # (C_value, expected_D, description)
    known: list[tuple[int, int, str]] = [
        (0,                 0,     "C=0 -> 0"),
        (R % (1 << 2*logq), 1,     "C=R -> 1"),
        (2 * R % (1 << 2*logq), 2,  "C=2R -> 2"),
    ]

    for C_val, exp_D, desc in known:
        # Verify analytical expectation matches golden model
        exp_golden = _golden(C_val, q, logr)
        assert exp_D == exp_golden, (
            f"Analytical vs golden mismatch for '{desc}': "
            f"{exp_D} != {exp_golden}"
        )

        _drive_inputs(dut, C_val, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        got = int(dut.D.value)
        assert got == exp_D, (
            f"Known-value '{desc}': expected {exp_D:#x}, got {got:#x}"
        )

    cocotb.log.info("Known-value tests passed.")


@cocotb.test()
async def test_back_to_back_same_value(dut):
    """
    Drive the same C value for many consecutive cycles and verify
    every output once the pipeline is primed.  This catches any
    state-dependent bugs in the datapath.
    """
    logw, logq, logr, ff_out = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr

    # Use a mid-range C
    C_val = ((q - 1) * (q - 1)) // 2
    exp = _golden(C_val, q, logr)

    _drive_inputs(dut, C_val, q, rho_packed, mu)

    NUM_CHECKS = 50
    total_cycles = NUM_CHECKS + latency + 1

    for cycle in range(total_cycles):
        await RisingEdge(dut.clk)

        if cycle >= latency:
            got = int(dut.D.value)
            assert got == exp, (
                f"Back-to-back cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(f"Back-to-back test passed ({NUM_CHECKS} checks).")