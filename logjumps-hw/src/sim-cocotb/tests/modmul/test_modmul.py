"""
Cocotb testbench for the modmul (Montgomery modular multiplication) module.

Functional specification
------------------------
The module computes:

    D = A * B * R^{-1}  mod q

where  A, B  are LOGQ-bit Montgomery-domain operands in [0, q-1],
       q     is an odd modulus that fits in LOGQ bits,
       R     = 2^{LOGR},
       LOGR  = LOGW * ceil(LOGQ / LOGW).

Precomputed constants supplied per-modulus:
    rho[i] = (2^{LOGW})^{-i} mod q     for i = 1 ... n-1      (packed LE)
    mu     = -q^{-1}         mod 2^{LOGW}

where n = LOGR / LOGW (total limbs).

When FIXED_Q = 0 (default):
    The rho-mu constants (rho[i]*mu mod 2^{LOGW}) are computed internally
    by the logjumps sub-block and are *not* module inputs.  The run-time
    ports q, rho, mu carry the modulus and derived constants.

When FIXED_Q = 1:
    The modulus and all derived constants are compile-time parameters
    (Q_VALUE, MU_VALUE, RHO_VALUES, RHO_MU_VALUES).  The run-time ports
    q, rho, mu are ignored by the hardware.  Tests that change the modulus
    at run time are skipped in this mode.

Architecture
------------
    +------------------+       +------------------+
    |  intmul_wrapper  |  C    |     logjumps     |
    |  (LOGQ x LOGQ)   |------>|   (Montgomery    |----> D
    | integer multiply |       |    reduction)    |
    +------------------+       +------------------+
          MUL_LAT                     LJ_LAT

When FIXED_Q = 0:
    Side-band inputs (q, rho, mu) are delay-matched through the integer
    multiplier's latency via SRL-friendly shift registers before being
    fed to the logjumps reduction block.

When FIXED_Q = 1:
    The q, rho, mu delay chains are eliminated.  logjumps receives
    compile-time constants directly.

Pipeline latency
----------------
The full pipeline depth is exposed as the localparam LAT inside the DUT:

    LAT = MUL_LAT + LJ_LAT

All inputs (A, B, q, rho, mu) for a given transaction are presented on
the same clock edge; internal delay chains inside the module align each
signal to the pipeline stage that consumes it.
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------

def _golden(A: int, B: int, q: int, logr: int) -> int:
    """Golden reference: A * B * R^{-1} mod q, where R = 2^{LOGR}."""
    R = 1 << logr
    return (A * B * pow(R, -1, q)) % q


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
    the logjumps sub-block (when FIXED_Q=0) and do not need to be
    supplied externally.
    """
    n = logr // logw
    rho = _compute_rho(q, logw, n)
    mu = _compute_mu(q, logw)
    rho_packed = _pack_rho(rho, logq)
    return rho_packed, mu


def _read_params(dut) -> tuple[int, int, int]:
    """Read key synthesis parameters from the DUT."""
    logw = int(dut.LOGW.value)
    logq = int(dut.LOGQ.value)
    logr = int(dut.LOGR.value)
    return logw, logq, logr


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


def _drive_inputs(dut, A_val: int, B_val: int,
                  q: int, rho_packed: int, mu: int):
    """Apply a complete input vector to the DUT ports.

    When FIXED_Q=1 the hardware ignores q, rho, mu, but the testbench
    still drives them to avoid X-propagation in simulation.  The caller
    should pass the matching constants (or zeros) regardless of mode.
    """
    dut.A.value = A_val
    dut.B.value = B_val
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
    Log detected parameters and the pipeline latency so they are
    visible in the simulation transcript.
    """
    logw, logq, logr = _read_params(dut)
    latency = _read_latency(dut)
    mul_lat = int(dut.MUL_LAT.value)
    lj_lat  = int(dut.LJ_LAT.value)
    is_fixed, q_value = _read_fixed_q(dut)

    n = logr // logw
    cocotb.log.info(
        f"DUT parameters: LOGW={logw}, LOGQ={logq}, LOGR={logr}, "
        + f"FIXED_Q={int(is_fixed)}"
        + (f", Q_VALUE={q_value:#x}" if is_fixed else "")
        + f", n={n} limbs"
    )
    cocotb.log.info(
        f"MUL: FF_IN={int(dut.MUL_FF_IN.value)}, "
        + f"FF_MUL={int(dut.MUL_FF_MUL.value)}, "
        + f"FF_OUT={int(dut.MUL_FF_OUT.value)}, "
        + f"USE_CSA={int(dut.MUL_USE_CSA.value)}, "
        + f"FF_CSA={int(dut.MUL_FF_CSA.value)}, "
        + f"USE_KARATSUBA={int(dut.MUL_USE_KARATSUBA.value)}"
    )
    cocotb.log.info(
        f"LJ: FF_IN={int(dut.LJ_FF_IN.value)}, "
        + f"FF_MUL={int(dut.LJ_FF_MUL.value)}, "
        + f"FF_OUT={int(dut.LJ_FF_OUT.value)}, "
        + f"FF_MR_POST={int(dut.LJ_FF_MR_POST.value)}, "
        + f"FF_JOIN_ADD={int(dut.LJ_FF_JOIN_ADD.value)}, "
        + f"DSP_SMALL={int(dut.LJ_DSP_SMALL.value)}, "
        + f"FF_RM={int(dut.LJ_FF_RM.value)}"
    )
    cocotb.log.info(
        f"ACC: USE_ADDTREE={int(dut.ACC_USE_ADDTREE.value)}, "
        + f"MAX_COND_SUB={int(dut.ACC_MAX_COND_SUB.value)}, "
        + f"AT_FF_ADD={int(dut.ACC_AT_FF_ADD.value)}"
    )
    cocotb.log.info(
        f"Pipeline: MUL_LAT={mul_lat}, LJ_LAT={lj_lat}, "
        f"LAT={latency} cycle(s)"
    )


@cocotb.test()
async def test_latency_probe(dut):
    """
    Empirically determine the actual pipeline latency by driving a
    known non-trivial input and scanning the output cycle by cycle.

    This catches any mismatch between the DUT's LAT localparam and
    the real pipeline depth - in particular a wrong MUL_LAT from
    intmul_wrapper_pkg::latency (e.g. for Karatsuba configurations).

    A MUL_LAT that is too small causes the q/rho/mu delay lines
    inside modmul to deliver side-band constants EARLY, so logjumps
    processes C with stale q/rho/mu from a previous cycle.
    """
    logw, logq, logr = _read_params(dut)
    latency = _read_latency(dut)
    mul_lat = int(dut.MUL_LAT.value)
    lj_lat  = int(dut.LJ_LAT.value)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr
    R_mod_q = R % q                   # Montgomery form of 1

    # modmul(R_mod_q, R_mod_q) = R_mod_q * R_mod_q * R^{-1}
    #                           = R * R * R^{-1} = R mod q
    exp = _golden(R_mod_q, R_mod_q, q, logr)
    assert exp == R_mod_q, "Analytical check failed"

    # Drive zeros long enough to guarantee the pipeline is clean,
    # then switch to the known input and scan for the expected output.
    HEADROOM = 20
    scan_cycles = latency + HEADROOM

    _drive_inputs(dut, 0, 0, q, rho_packed, mu)
    await ClockCycles(dut.clk, latency + HEADROOM)

    # Now drive the real stimulus
    _drive_inputs(dut, R_mod_q, R_mod_q, q, rho_packed, mu)

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

    cocotb.log.info(
        f"Latency probe: first correct output at cycle {actual_lat} "
        f"(DUT LAT={latency}, MUL_LAT={mul_lat}, LJ_LAT={lj_lat})"
    )

    assert actual_lat == latency, (
        f"LATENCY MISMATCH: DUT reports LAT={latency} "
        f"(MUL_LAT={mul_lat} + LJ_LAT={lj_lat}) "
        f"but actual pipeline depth is {actual_lat}.  "
        f"Check intmul_wrapper_pkg::latency for the Karatsuba "
        f"configuration (K_PIPE_DSP={int(dut.MUL_K_PIPE_DSP.value)}, "
        f"K_PIPE_PRE={int(dut.MUL_K_PIPE_PRE.value)}, "
        f"K_PIPE_POST={int(dut.MUL_K_PIPE_POST.value)}, "
        f"K_PIPE_MID={int(dut.MUL_K_PIPE_MID.value)})."
    )


@cocotb.test()
async def test_zero_operand(dut):
    """A=0 or B=0 must always produce D=0 regardless of the modulus."""
    logw, logq, logr = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)

    flush = max(latency, 1)

    # A = 0, B = arbitrary
    _drive_inputs(dut, 0, q - 1, q, rho_packed, mu)
    await ClockCycles(dut.clk, flush + 1)

    got = int(dut.D.value)
    assert got == 0, f"A=0: expected 0, got {got:#x}"

    # B = 0, A = arbitrary
    _drive_inputs(dut, q - 1, 0, q, rho_packed, mu)
    await ClockCycles(dut.clk, flush + 1)

    got = int(dut.D.value)
    assert got == 0, f"B=0: expected 0, got {got:#x}"

    # Both zero
    _drive_inputs(dut, 0, 0, q, rho_packed, mu)
    await ClockCycles(dut.clk, flush + 1)

    got = int(dut.D.value)
    assert got == 0, f"A=B=0: expected 0, got {got:#x}"

    cocotb.log.info("Zero operand tests passed.")


@cocotb.test()
async def test_montgomery_identity(dut):
    """
    A * R mod q is the Montgomery form of A.  Therefore:
        modmul(A, R mod q) = A * (R mod q) * R^{-1} mod q = A

    This confirms that R mod q acts as the multiplicative identity
    in the Montgomery domain.
    """
    logw, logq, logr = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr
    R_mod_q = R % q                   # Montgomery form of 1

    flush = max(latency, 1)

    rng = random.Random(0xAAAA)
    for _ in range(10):
        A_val = rng.randint(0, q - 1)
        exp = _golden(A_val, R_mod_q, q, logr)
        # Analytically: A * R * R^{-1} = A mod q
        assert exp == A_val, (
            f"Golden mismatch: A={A_val:#x}, R_mod_q={R_mod_q:#x}, "
            f"expected A={A_val:#x}, got golden={exp:#x}"
        )

        _drive_inputs(dut, A_val, R_mod_q, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        got = int(dut.D.value)
        assert got == A_val, (
            f"Montgomery identity: A={A_val:#x}, expected {A_val:#x}, "
            f"got {got:#x}"
        )

    cocotb.log.info("Montgomery identity test passed (A * R_mod_q = A).")


@cocotb.test()
async def test_known_values(dut):
    """
    Verify a few analytically known Montgomery multiplications.

    For any odd q and R = 2^{LOGQ}:
        modmul(0, x)   = 0
        modmul(R, x)   = x   (R is the Montgomery identity)
        modmul(R, R)   = R   (identity squared is identity)
        modmul(1, 1)   = R^{-1} mod q
    """
    logw, logq, logr = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr
    R_mod_q = R % q
    Rinv = pow(R, -1, q)

    flush = max(latency, 1)

    # (A, B, expected_D, description)
    known: list[tuple[int, int, int, str]] = [
        (0,         q - 1,   0,         "0 * (q-1) = 0"),
        (R_mod_q,   R_mod_q, R_mod_q,   "R * R * R^{-1} = R"),
        (R_mod_q,   1,       1,         "R * 1 * R^{-1} = 1"),
        (1,         1,       Rinv,      "1 * 1 * R^{-1} = R^{-1}"),
        (R_mod_q,   0,       0,         "R * 0 = 0"),
    ]

    for A_val, B_val, exp_D, desc in known:
        # Verify analytical expectation matches golden model
        exp_golden = _golden(A_val, B_val, q, logr)
        assert exp_D == exp_golden, (
            f"Analytical vs golden mismatch for '{desc}': "
            f"{exp_D} != {exp_golden}"
        )

        _drive_inputs(dut, A_val, B_val, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        got = int(dut.D.value)
        assert got == exp_D, (
            f"Known-value '{desc}': expected {exp_D:#x}, got {got:#x}"
        )

    cocotb.log.info("Known-value tests passed.")


@cocotb.test()
async def test_commutativity(dut):
    """
    Montgomery multiplication is commutative: A*B = B*A.
    Drive both orderings and verify they produce the same result.
    """
    logw, logq, logr = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)

    flush = max(latency, 1)
    rng = random.Random(0xC0DE)

    for _ in range(20):
        A_val = rng.randint(0, q - 1)
        B_val = rng.randint(0, q - 1)

        # A * B
        _drive_inputs(dut, A_val, B_val, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)
        d_ab = int(dut.D.value)

        # B * A
        _drive_inputs(dut, B_val, A_val, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)
        d_ba = int(dut.D.value)

        assert d_ab == d_ba, (
            f"Commutativity: A={A_val:#x}, B={B_val:#x} -> "
            f"A*B={d_ab:#x}, B*A={d_ba:#x}"
        )

        # Also check against golden
        exp = _golden(A_val, B_val, q, logr)
        assert d_ab == exp, (
            f"Commutativity golden: A={A_val:#x}, B={B_val:#x} -> "
            f"expected {exp:#x}, got {d_ab:#x}"
        )

    cocotb.log.info("Commutativity test passed (20 pairs).")


@cocotb.test()
async def test_corner_cases(dut):
    """
    Hand-crafted corner-case (A, B) pairs driven through the pipeline
    with a fixed modulus.  Each output is checked exactly `latency`
    cycles after its corresponding input.
    """
    logw, logq, logr = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr
    R_mod_q = R % q

    # Build corner-case (A, B) pairs
    vectors: list[tuple[int, int]] = [
        (0,         0),             # both zero
        (1,         1),             # smallest positive
        (0,         q - 1),         # zero times max
        (q - 1,     0),             # max times zero
        (q - 1,     q - 1),         # max times max
        (1,         q - 1),         # one times max
        (q - 1,     1),             # max times one
        (R_mod_q,   R_mod_q),       # identity squared
        (R_mod_q,   q - 1),         # identity times max
        (q - 2,     q - 2),         # (q-2)^2
        (2,         (q + 1) // 2),  # 2 * (q+1)/2 if q is odd
    ]

    _drive_inputs(dut, 0, 0, q, rho_packed, mu)

    if latency == 0:
        for A_val, B_val in vectors:
            dut.A.value = A_val
            dut.B.value = B_val
            await RisingEdge(dut.clk)
            got = int(dut.D.value)
            exp = _golden(A_val, B_val, q, logr)
            assert got == exp, (
                f"Corner (comb): A={A_val:#x} B={B_val:#x} -> "
                f"expected {exp:#x}, got {got:#x}"
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
                A_val, B_val = next(vec_iter)
                dut.A.value = A_val
                dut.B.value = B_val
                expected.append(_golden(A_val, B_val, q, logr))
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
async def test_random_pipeline(dut):
    """
    Stress-test with random (A, B) values pipelined at full throughput.
    Modulus (q, rho, mu) are held constant; only A, B change every cycle.
    """
    logw, logq, logr = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)

    NUM_TESTS = 500
    rng = random.Random(0xBEEF_CAFE)

    _drive_inputs(dut, 0, 0, q, rho_packed, mu)

    if latency == 0:
        for _ in range(NUM_TESTS):
            A_val = rng.randint(0, q - 1)
            B_val = rng.randint(0, q - 1)
            dut.A.value = A_val
            dut.B.value = B_val
            await RisingEdge(dut.clk)
            got = int(dut.D.value)
            exp = _golden(A_val, B_val, q, logr)
            assert got == exp, (
                f"Random comb: A={A_val:#x} B={B_val:#x} "
                f"exp={exp:#x} got={got:#x}"
            )
        cocotb.log.info(f"Passed {NUM_TESTS} combinatorial random tests.")
        return

    expected: deque[int] = deque()
    total_cycles = NUM_TESTS + latency

    for cycle in range(total_cycles):
        if cycle < NUM_TESTS:
            A_val = rng.randint(0, q - 1)
            B_val = rng.randint(0, q - 1)
            dut.A.value = A_val
            dut.B.value = B_val
            expected.append(_golden(A_val, B_val, q, logr))

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
async def test_max_operands(dut):
    """
    Drive A = q-1 and B = q-1 for several different moduli to exercise
    the upper bound of the product range.

    When FIXED_Q=1, the modulus cannot be changed at run time, so only
    a single modulus (Q_VALUE) is tested.
    """
    logw, logq, logr = _read_params(dut)
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
        rho_packed, mu = _precompute(q, logw, logq, logr)

        # Drain pipeline
        _drive_inputs(dut, 0, 0, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        # Apply A = B = q-1
        A_val = q - 1
        B_val = q - 1
        _drive_inputs(dut, A_val, B_val, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        got = int(dut.D.value)
        exp = _golden(A_val, B_val, q, logr)
        assert got == exp, (
            f"Max-operands q={q:#x}: expected {exp:#x}, got {got:#x}"
        )

    cocotb.log.info(f"Max-operands test passed for {len(moduli)} moduli.")


@cocotb.test()
async def test_changing_modulus_flushed(dut):
    """
    Verify the design handles a mid-stream change of modulus correctly
    when the pipeline is flushed between modulus switches.

    Skipped when FIXED_Q=1 because the modulus is a compile-time constant
    and the q, rho, mu ports are ignored.
    """
    logw, logq, logr = _read_params(dut)
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
        rho_packed, mu = _precompute(q, logw, logq, logr)

        # Drain pipeline with zeros before switching modulus
        _drive_inputs(dut, 0, 0, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        expected: deque[int] = deque()
        rng = random.Random(q & 0xFFFF_FFFF)
        NUM = 50
        total = NUM + latency

        for cycle in range(total):
            if cycle < NUM:
                A_val = rng.randint(0, q - 1)
                B_val = rng.randint(0, q - 1)
                dut.A.value = A_val
                dut.B.value = B_val
                expected.append(_golden(A_val, B_val, q, logr))

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
    Every clock cycle presents a completely independent (A, B, q, rho, mu)
    tuple - the modulus changes at full pipeline throughput.

    The DUT's internal delay chains for q, rho, mu must keep each
    transaction's constants aligned with the correct pipeline stage.

    Skipped when FIXED_Q=1 because the modulus is a compile-time constant
    and the q, rho, mu ports are ignored.
    """
    logw, logq, logr = _read_params(dut)
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

    # Pre-generate all test vectors: (A, B, q, rho_packed, mu, expected_D)
    test_vectors: list[tuple[int, int, int, int, int, int]] = []
    for _ in range(NUM_TESTS):
        q = _rand_odd_modulus(rng, logq)
        A_val = rng.randint(0, q - 1)
        B_val = rng.randint(0, q - 1)
        rho_packed, mu = _precompute(q, logw, logq, logr)
        exp = _golden(A_val, B_val, q, logr)
        test_vectors.append((A_val, B_val, q, rho_packed, mu, exp))

    cocotb.log.info(
        "First 3 vectors: "
        + ", ".join(
            f"(A={A:#010x}, B={B:#010x}, q={q:#010x}, exp={exp:#010x})"
            for A, B, q, _, _, exp in test_vectors[:3]
        )
    )

    # Initialise
    A0, B0, q0, rho0, mu0, _ = test_vectors[0]
    _drive_inputs(dut, A0, B0, q0, rho0, mu0)

    expected: deque[int] = deque()
    total_cycles = NUM_TESTS + latency

    for cycle in range(total_cycles):
        if cycle < NUM_TESTS:
            A_val, B_val, q, rho_packed, mu, exp = test_vectors[cycle]
            _drive_inputs(dut, A_val, B_val, q, rho_packed, mu)
            expected.append(exp)

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.D.value)
            src_idx = cycle - latency
            _, _, q_src, _, _, _ = test_vectors[src_idx]
            assert got == exp, (
                f"Cycle {cycle} (input #{src_idx}): "
                f"q={q_src:#x} -> expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(
        f"Passed {NUM_TESTS} pipelined independent-(A,B,q,rho,mu) tests "
        f"(LAT={latency})."
    )


@cocotb.test()
async def test_small_moduli(dut):
    """
    Test with the smallest valid LOGQ-bit odd moduli to exercise
    edge cases in conditional subtraction.

    When FIXED_Q=1, the modulus cannot be changed at run time, so only
    Q_VALUE is tested with the same strategy.
    """
    logw, logq, logr = _read_params(dut)
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
        rho_packed, mu = _precompute(q, logw, logq, logr)

        _drive_inputs(dut, 0, 0, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        expected: deque[int] = deque()
        NUM = 50
        total = NUM + latency

        for cycle in range(total):
            if cycle < NUM:
                A_val = rng.randint(0, q - 1)
                B_val = rng.randint(0, q - 1)
                dut.A.value = A_val
                dut.B.value = B_val
                expected.append(_golden(A_val, B_val, q, logr))

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
async def test_back_to_back_same_value(dut):
    """
    Drive the same (A, B) pair for many consecutive cycles and verify
    every output once the pipeline is primed.  This catches any
    state-dependent bugs in the datapath.
    """
    logw, logq, logr = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)

    # Use mid-range operands
    A_val = (q - 1) // 2
    B_val = (q - 1) // 3
    exp = _golden(A_val, B_val, q, logr)

    _drive_inputs(dut, A_val, B_val, q, rho_packed, mu)

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


@cocotb.test()
async def test_squaring(dut):
    """
    Verify A * A (Montgomery squaring) for several random values.
    This exercises the case where both multiplier inputs are identical.
    """
    logw, logq, logr = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)

    flush = max(latency, 1)
    rng = random.Random(0x5C1_5C1)

    for _ in range(20):
        A_val = rng.randint(0, q - 1)

        _drive_inputs(dut, A_val, A_val, q, rho_packed, mu)
        await ClockCycles(dut.clk, flush + 1)

        got = int(dut.D.value)
        exp = _golden(A_val, A_val, q, logr)
        assert got == exp, (
            f"Squaring: A={A_val:#x} -> expected {exp:#x}, got {got:#x}"
        )

    cocotb.log.info("Squaring test passed (20 values).")


# ---------------------------------------------------------------------------
#  Karatsuba latency diagnostic
# ---------------------------------------------------------------------------

def _try_read(obj, path: str) -> str:
    """Try to read a localparam/signal from the DUT hierarchy."""
    try:
        parts = path.split(".")
        node = obj
        for part in parts:
            node = getattr(node, part)
        return str(int(node.value))
    except Exception as e:
        return f"<{e.__class__.__name__}: {e}>"


@cocotb.test()
async def test_karatsuba_latency_diag(dut):
    """
    Walk the karatsuba_mul hierarchy and log every LAT, DELAY,
    and pipeline parameter to find where DUT LAT diverges from
    the actual pipeline depth.

    Run standalone:
        COCOTB_TESTCASE=test_karatsuba_latency_diag python run_modmul.py
    """
    cocotb.log.info("=" * 70)
    cocotb.log.info("Karatsuba Latency Diagnostic")
    cocotb.log.info("=" * 70)

    # -- Top-level modmul parameters --
    for name in ("LOGQ", "LOGW", "LOGR", "MUL_LAT", "LJ_LAT", "LAT",
                 "MUL_USE_KARATSUBA", "MUL_K_PIPE_DSP",
                 "MUL_K_PIPE_PRE", "MUL_K_PIPE_POST", "MUL_K_PIPE_MID",
                 "FIXED_Q"):
        cocotb.log.info(f"  dut.{name} = {_try_read(dut, name)}")

    # -- intmul_wrapper --
    cocotb.log.info("-" * 70)
    cocotb.log.info("intmul_wrapper (u_intmul):")
    for name in ("LOGA", "LOGB", "LAT", "USE_KARATSUBA",
                 "K_PIPE_DSP", "K_PIPE_PRE", "K_PIPE_POST", "K_PIPE_MID"):
        cocotb.log.info(f"  u_intmul.{name} = {_try_read(dut, f'u_intmul.{name}')}")

    # -- karatsuba_mul top (level 0) --
    cocotb.log.info("-" * 70)
    cocotb.log.info("karatsuba_mul level 0 (u_intmul.gen_karatsuba.u_karatsuba):")
    km0 = "u_intmul.gen_karatsuba.u_karatsuba"
    for name in ("LOGA", "LOGB", "LOGC", "LAT",
                 "PIPE_DSP", "PIPE_PRE", "PIPE_POST", "PIPE_MID"):
        cocotb.log.info(f"  {name} = {_try_read(dut, f'{km0}.{name}')}")

    # The Karatsuba decomposition generate block
    gk0 = f"{km0}.gen_karatsuba"
    for name in ("HALF", "W_ALO", "W_AHI", "W_BLO", "W_BHI",
                 "W_ASUM", "W_BSUM", "W_Z0", "W_Z2", "W_CROSS",
                 "LAT_Z0", "LAT_Z2", "LAT_ZX", "LAT_SUB_MAX",
                 "DELAY_Z0", "DELAY_Z2", "DELAY_ZX"):
        cocotb.log.info(f"  gen_karatsuba.{name} = {_try_read(dut, f'{gk0}.{name}')}")

    # -- Level 1: z0, z2, zx sub-multiplies --
    for sub, label in [("u_z0", "z0"), ("u_z2", "z2"), ("u_zx", "zx")]:
        cocotb.log.info("-" * 70)
        cocotb.log.info(f"karatsuba_mul level 1 - {label} ({gk0}.{sub}):")
        km1 = f"{gk0}.{sub}"
        for name in ("LOGA", "LOGB", "LOGC", "LAT",
                     "PIPE_DSP", "PIPE_PRE", "PIPE_POST", "PIPE_MID"):
            cocotb.log.info(f"  {name} = {_try_read(dut, f'{km1}.{name}')}")

        # Check if this level is a base case or another Karatsuba
        gk1 = f"{km1}.gen_karatsuba"
        half_val = _try_read(dut, f"{gk1}.HALF")
        if half_val.startswith("<"):
            cocotb.log.info(f"  -> BASE CASE (gen_base)")
            base_lat = _try_read(dut, f"{km1}.gen_base.u_base.LAT")
            cocotb.log.info(f"  gen_base.u_base.LAT = {base_lat}")
        else:
            cocotb.log.info(f"  -> KARATSUBA (gen_karatsuba)")
            for name in ("HALF", "W_ALO", "W_AHI", "W_BLO", "W_BHI",
                         "W_ASUM", "W_BSUM",
                         "LAT_Z0", "LAT_Z2", "LAT_ZX", "LAT_SUB_MAX",
                         "DELAY_Z0", "DELAY_Z2", "DELAY_ZX"):
                cocotb.log.info(f"  gen_karatsuba.{name} = {_try_read(dut, f'{gk1}.{name}')}")

            # Level 2 sub-multiplies
            for sub2, label2 in [("u_z0", "z0"), ("u_z2", "z2"), ("u_zx", "zx")]:
                km2 = f"{gk1}.{sub2}"
                lat2 = _try_read(dut, f"{km2}.LAT")
                loga2 = _try_read(dut, f"{km2}.LOGA")
                logb2 = _try_read(dut, f"{km2}.LOGB")
                cocotb.log.info(f"    {label2}: LOGA={loga2}, LOGB={logb2}, LAT={lat2}")

                half2 = _try_read(dut, f"{km2}.gen_karatsuba.HALF")
                if half2.startswith("<"):
                    base2_lat = _try_read(dut, f"{km2}.gen_base.u_base.LAT")
                    cocotb.log.info(f"      -> BASE CASE, mac_std LAT={base2_lat}")
                else:
                    cocotb.log.info(f"      -> KARATSUBA (another level)")
                    gk2 = f"{km2}.gen_karatsuba"
                    for name in ("LAT_Z0", "LAT_Z2", "LAT_ZX", "LAT_SUB_MAX",
                                 "DELAY_Z0", "DELAY_Z2", "DELAY_ZX"):
                        cocotb.log.info(f"        {name} = {_try_read(dut, f'{gk2}.{name}')}")

    # -- Empirical probe --
    cocotb.log.info("=" * 70)
    cocotb.log.info("Empirical latency probe:")

    Clock(dut.clk, 10, "ns").start()

    logw, logq, logr = _read_params(dut)
    q, rho_packed, mu = _effective_q(dut, logw, logq, logr)
    R = 1 << logr
    R_mod_q = R % q
    exp = _golden(R_mod_q, R_mod_q, q, logr)

    _drive_inputs(dut, 0, 0, q, rho_packed, mu)
    await ClockCycles(dut.clk, 80)

    _drive_inputs(dut, R_mod_q, R_mod_q, q, rho_packed, mu)

    first_match = None
    for cycle in range(60):
        await RisingEdge(dut.clk)
        got = int(dut.D.value)
        if got == exp and first_match is None:
            first_match = cycle

    mul_lat = int(dut.MUL_LAT.value)
    lj_lat = int(dut.LJ_LAT.value)

    cocotb.log.info(
        f"Empirical: first correct output at cycle {first_match} "
        f"(DUT LAT={int(dut.LAT.value)} = MUL_LAT({mul_lat}) + LJ_LAT({lj_lat}))"
    )
    if first_match is not None:
        cocotb.log.info(
            f"Implied actual MUL_LAT = {first_match} - {lj_lat} "
            f"= {first_match - lj_lat}"
        )