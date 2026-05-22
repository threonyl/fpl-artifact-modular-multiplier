"""
Cocotb testbench for the modacc (modular accumulator) module.

Latency Analysis
----------------
The modacc module supports two operating modes selected by USE_ADDTREE.

**USE_ADDTREE = 0 (legacy):**
  Binary reduction tree of modadd cells.  Each stage pairs inputs;
  an odd leftover is forwarded through a delay-matched shift register.

    NUM_STAGES     = ceil(log2(NUM_INPUTS))       (0 when NUM_INPUTS <= 1)
    MODADD_LATENCY = REG_IN + REG_ADD + (REG_ADD & ~CONC_ADDSUB) + REG_OUT
    LATENCY        = NUM_STAGES * MODADD_LATENCY

  Default parameters (LOGQ=32, NUM_INPUTS=16, REG_IN=1, REG_OUT=1,
  REG_ADD=1, CONC_ADDSUB=1):
      MODADD_LATENCY = 1 + 1 + 0 + 1 = 3
      NUM_STAGES     = 4
      LATENCY        = 4 * 3 = 12

**USE_ADDTREE = 1 (addtree + conditional subtraction):**
  Phase 1 - Unreduced summation via addtree (plain or CSA).
  Phase 2 - Binary-search conditional-subtraction chain that
            iteratively subtracts 2^k * q for k = K-1 ... 0,
            where K = clog2(MAX_COND_SUB + 1).

    LATENCY = addtree_latency(NUM_INPUTS, AT_REG_PERIOD,
                              AT_REG_IN, AT_REG_OUT, AT_USE_CSA,
                              AT_FF_ADD)
            + cond_sub_latency(MAX_COND_SUB, CS_REG_PERIOD, CS_REG_OUT)

Fixed-modulus mode (FIXED_Q=1)
------------------------------
When FIXED_Q=1 the compile-time constant Q_VALUE is used as the modulus
and the i_q input port is ignored.  Tests that change the modulus at
run time are skipped in this mode.
"""

import math
import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _modadd_latency(reg_in: int, reg_out: int, reg_add: int, conc_addsub: int) -> int:
    """Return the pipeline depth of a single modadd instance."""
    extra = reg_add if not conc_addsub else 0
    return reg_in + reg_add + extra + reg_out


def _num_stages(n: int) -> int:
    """Return the number of binary-reduction stages to reduce n inputs to 1."""
    s = 0
    while n > 1:
        n = (n + 1) // 2
        s += 1
    return s


def _clog2(n: int) -> int:
    """Ceiling-log2 matching modacc_pkg::clog2_val."""
    if n <= 1:
        return 0
    s = 0
    v = n - 1
    while v > 0:
        v >>= 1
        s += 1
    return s


def _num_cond_sub_stages(max_cond_sub: int) -> int:
    """Number of conditional-subtraction stages (matches modacc_pkg)."""
    if max_cond_sub == 0:
        return 0
    return _clog2(max_cond_sub + 1)


def _cond_sub_latency(max_cond_sub: int, cs_reg_period: int, cs_reg_out: int) -> int:
    """Pipeline latency of the conditional-subtraction chain (matches modacc_pkg)."""
    num_cs = _num_cond_sub_stages(max_cond_sub)
    if num_cs == 0:
        return 0

    lat = 0
    if cs_reg_period > 0:
        lat = num_cs // cs_reg_period

    last_has_reg = (cs_reg_period > 0) and ((num_cs % cs_reg_period) == 0)
    if cs_reg_out and not last_has_reg:
        lat += 1

    return lat


def _compute_legacy_latency(num_inputs: int, reg_in: int, reg_out: int,
                            reg_add: int, conc_addsub: int) -> int:
    """Return the total pipeline depth of the legacy modadd reduction tree."""
    return _num_stages(num_inputs) * _modadd_latency(reg_in, reg_out, reg_add, conc_addsub)


def _modacc_model(operands: list[int], q: int) -> int:
    """Golden-reference: sum all operands mod q using pairwise modular addition."""
    acc = 0
    for v in operands:
        acc = acc + v
        if acc >= q:
            acc -= q
    return acc


def _read_params(dut) -> dict:
    """
    Read synthesis parameters from the DUT and return them as a dict.

    Always includes the DUT-reported LATENCY so that all tests can use
    it directly, regardless of operating mode.
    """
    return dict(
        logq          = int(dut.LOGQ.value),
        num_inputs    = int(dut.NUM_INPUTS.value),
        reg_in        = int(dut.REG_IN.value),
        reg_out       = int(dut.REG_OUT.value),
        reg_add       = int(dut.REG_ADD.value),
        conc_addsub   = int(dut.CONC_ADDSUB.value),
        use_addtree   = int(dut.USE_ADDTREE.value),
        max_cond_sub  = int(dut.MAX_COND_SUB.value),
        at_reg_period = int(dut.AT_REG_PERIOD.value),
        at_reg_in     = int(dut.AT_REG_IN.value),
        at_reg_out    = int(dut.AT_REG_OUT.value),
        at_use_csa    = int(dut.AT_USE_CSA.value),
        cs_reg_period = int(dut.CS_REG_PERIOD.value),
        cs_reg_out    = int(dut.CS_REG_OUT.value),
        at_ff_add     = int(dut.AT_FF_ADD.value),
        fixed_q       = int(dut.FIXED_Q.value),
        q_value       = int(dut.Q_VALUE.value),
        latency       = int(dut.LATENCY.value),
    )


def _pack_operands(operands: list[int], logq: int) -> int:
    """Pack a list of operands into the wide i_a bus (little-endian packing)."""
    packed = 0
    for i, val in enumerate(operands):
        packed |= (val & ((1 << logq) - 1)) << (i * logq)
    return packed


def _default_q(logq: int) -> int:
    """Return a suitable test modulus derived from LOGQ (prime-ish, below 2^LOGQ)."""
    return (1 << logq) - 3 if logq >= 4 else (1 << logq) - 1


def _effective_q(p: dict) -> int:
    """Return the modulus the DUT will actually use.

    When FIXED_Q=1 the hardware ignores i_q and uses Q_VALUE, so the
    testbench must do the same.
    """
    if p['fixed_q']:
        return p['q_value']
    return _default_q(p['logq'])


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_latency_detection(dut):
    """
    Log the detected parameters and computed latency so it is visible
    in the simulation transcript, and verify against the DUT's LATENCY parameter.
    """
    p = _read_params(dut)
    dut_latency = p['latency']

    cocotb.log.info(
        f"DUT parameters: LOGQ={p['logq']}, NUM_INPUTS={p['num_inputs']}, "
        f"REG_IN={p['reg_in']}, REG_OUT={p['reg_out']}, "
        f"REG_ADD={p['reg_add']}, CONC_ADDSUB={p['conc_addsub']}, "
        f"USE_ADDTREE={p['use_addtree']}, "
        f"FIXED_Q={p['fixed_q']}, Q_VALUE={p['q_value']:#x}"
    )

    if p['use_addtree']:
        cocotb.log.info(
            f"  Addtree params: MAX_COND_SUB={p['max_cond_sub']}, "
            f"AT_REG_PERIOD={p['at_reg_period']}, AT_REG_IN={p['at_reg_in']}, "
            f"AT_REG_OUT={p['at_reg_out']}, AT_USE_CSA={p['at_use_csa']}, "
            f"AT_FF_ADD={p['at_ff_add']}, "
            f"CS_REG_PERIOD={p['cs_reg_period']}, CS_REG_OUT={p['cs_reg_out']}"
        )

        # We can at least verify the conditional-subtraction part of the
        # latency against our Python model.
        cs_lat = _cond_sub_latency(p['max_cond_sub'], p['cs_reg_period'], p['cs_reg_out'])
        cocotb.log.info(
            f"  Computed CS_LAT = {cs_lat}, "
            f"NUM_CS = {_num_cond_sub_stages(p['max_cond_sub'])}"
        )
    else:
        computed = _compute_legacy_latency(
            p['num_inputs'], p['reg_in'], p['reg_out'],
            p['reg_add'], p['conc_addsub']
        )
        cocotb.log.info(f"Computed pipeline LATENCY = {computed} cycle(s)")
        assert computed == dut_latency, (
            f"Latency mismatch: computed {computed} != DUT LATENCY parameter {dut_latency}"
        )

    cocotb.log.info(f"DUT LATENCY parameter     = {dut_latency} cycle(s)")


@cocotb.test()
async def test_all_zeros(dut):
    """Verify that all-zero inputs produce a zero output."""
    p = _read_params(dut)
    latency = p['latency']
    logq = p['logq']
    num_inputs = p['num_inputs']

    Clock(dut.clk, 10, "ns").start()

    q = _effective_q(p)

    operands = [0] * num_inputs
    dut.i_a.value = _pack_operands(operands, logq)
    dut.i_q.value = q

    # Wait for pipeline to flush
    flush = max(latency, 1)
    await ClockCycles(dut.clk, flush + 1)

    got = int(dut.o_c.value)
    assert got == 0, f"All-zeros: expected 0, got {got:#x}"
    cocotb.log.info("All-zeros test passed.")


@cocotb.test()
async def test_corner_cases(dut):
    """
    Drive hand-crafted corner cases through the pipeline and verify
    each output exactly latency cycles after the corresponding input.
    """
    p = _read_params(dut)
    latency = p['latency']
    logq = p['logq']
    n = p['num_inputs']

    Clock(dut.clk, 10, "ns").start()

    q = _effective_q(p)

    # Build corner-case vectors
    vectors = []

    # All zeros
    vectors.append(([0] * n, q))

    # All ones
    vectors.append(([1] * n, q))

    # All (q-1), largest valid operand
    vectors.append(([q - 1] * n, q))

    # Single non-zero in first position
    single = [0] * n
    single[0] = q - 1
    vectors.append((single[:], q))

    # Single non-zero in last position
    single = [0] * n
    single[-1] = q - 1
    vectors.append((single[:], q))

    # Alternating 0 and (q-1)
    alt = [(q - 1) if (i % 2 == 0) else 0 for i in range(n)]
    vectors.append((alt, q))

    # Half q//2 values
    vectors.append(([q // 2] * n, q))

    # Sequential 0, 1, 2, ... clamped to [0, q)
    seq = [i % q for i in range(n)]
    vectors.append((seq, q))

    # Initialise inputs
    dut.i_a.value = 0
    dut.i_q.value = q

    if latency == 0:
        for operands, q_val in vectors:
            dut.i_a.value = _pack_operands(operands, logq)
            dut.i_q.value = q_val
            await RisingEdge(dut.clk)
            got = int(dut.o_c.value)
            exp = _modacc_model(operands, q_val)
            assert got == exp, (
                f"Comb corner: expected {exp:#x}, got {got:#x}"
            )
        cocotb.log.info("All corner cases passed (combinatorial).")
        return

    # Pipelined check via a sliding window.
    expected: deque = deque()
    total_cycles = len(vectors) + latency

    vec_iter = iter(vectors)
    vec_exhausted = False

    for cycle in range(total_cycles):
        if not vec_exhausted:
            try:
                operands, q_val = next(vec_iter)
                dut.i_a.value = _pack_operands(operands, logq)
                dut.i_q.value = q_val
                expected.append(_modacc_model(operands, q_val))
            except StopIteration:
                vec_exhausted = True

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.o_c.value)
            assert got == exp, (
                f"Corner test cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info("All corner cases passed.")


@cocotb.test()
async def test_random_pipeline(dut):
    """
    Stress-test with random operands pipelined at full throughput.
    Inputs are applied every cycle and outputs are checked exactly
    `latency` cycles later.
    """
    p = _read_params(dut)
    latency = p['latency']
    logq = p['logq']
    n = p['num_inputs']

    Clock(dut.clk, 10, "ns").start()

    q = _effective_q(p)
    NUM_TESTS = 200
    rng = random.Random(0xACC0_1B)

    dut.i_a.value = 0
    dut.i_q.value = q

    if latency == 0:
        for _ in range(NUM_TESTS):
            operands = [rng.randint(0, q - 1) for _ in range(n)]
            dut.i_a.value = _pack_operands(operands, logq)
            dut.i_q.value = q
            await RisingEdge(dut.clk)
            got = int(dut.o_c.value)
            exp = _modacc_model(operands, q)
            assert got == exp, f"Random comb: exp={exp} got={got}"
        cocotb.log.info(f"Passed {NUM_TESTS} combinatorial random tests.")
        return

    expected: deque = deque()
    total_cycles = NUM_TESTS + latency

    for cycle in range(total_cycles):
        if cycle < NUM_TESTS:
            operands = [rng.randint(0, q - 1) for _ in range(n)]
            dut.i_a.value = _pack_operands(operands, logq)
            dut.i_q.value = q
            expected.append(_modacc_model(operands, q))

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.o_c.value)
            assert got == exp, (
                f"Random test cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(
        f"Passed {NUM_TESTS} pipelined random tests (LATENCY={latency})."
    )


@cocotb.test()
async def test_changing_modulus(dut):
    """
    Verify the design handles a mid-stream change of modulus q correctly
    once the pipeline has been flushed.

    Skipped when FIXED_Q=1 because the modulus is a compile-time constant
    and the i_q port is ignored.
    """
    p = _read_params(dut)

    if p['fixed_q']:
        cocotb.log.info(
            "FIXED_Q=1, skipping test_changing_modulus "
            "(i_q port is ignored, modulus is compile-time constant)."
        )
        return

    latency = p['latency']
    logq = p['logq']
    n = p['num_inputs']

    Clock(dut.clk, 10, "ns").start()

    flush = max(latency, 1)

    moduli = [
        (1 << logq) - 3,
        (1 << logq) - 15,
        (1 << (logq // 2)) - 3 if logq >= 4 else (1 << logq) - 1,
    ]

    for q in moduli:
        # Drain pipeline with zeros before switching modulus
        dut.i_a.value = 0
        dut.i_q.value = q
        await ClockCycles(dut.clk, flush)

        expected: deque = deque()
        rng = random.Random(q)
        NUM = 30
        total = NUM + latency

        for cycle in range(total):
            if cycle < NUM:
                operands = [rng.randint(0, q - 1) for _ in range(n)]
                dut.i_a.value = _pack_operands(operands, logq)
                dut.i_q.value = q
                expected.append(_modacc_model(operands, q))

            await RisingEdge(dut.clk)

            if latency > 0 and cycle >= latency and expected:
                exp = expected.popleft()
                got = int(dut.o_c.value)
                assert got == exp, (
                    f"q={q:#x} cycle={cycle}: expected {exp:#x}, got {got:#x}"
                )

        cocotb.log.info(f"Passed modulus q={q:#x}.")


@cocotb.test()
async def test_pipelined_changing_modulus(dut):
    """
    Every clock cycle presents a completely independent (A, q) pair,
    i.e. the modulus changes at full pipeline throughput.

    The expected queue tracks the per-cycle modular sum so the checker
    can verify each output independently.

    Skipped when FIXED_Q=1 because the modulus is a compile-time constant
    and the i_q port is ignored.
    """
    p = _read_params(dut)

    if p['fixed_q']:
        cocotb.log.info(
            "FIXED_Q=1, skipping test_pipelined_changing_modulus "
            "(i_q port is ignored, modulus is compile-time constant)."
        )
        return

    latency = p['latency']
    logq = p['logq']
    n = p['num_inputs']

    Clock(dut.clk, 10, "ns").start()

    NUM_TESTS = 200
    rng = random.Random(0xCA_FFEE)

    def _rand_modulus() -> int:
        lo = 1 << (logq // 2) if logq >= 4 else 3
        hi = (1 << logq) - 2
        return rng.randint(lo, hi) | 1  # force odd

    # Pre-generate all (operands, q) pairs
    test_vectors = []
    for _ in range(NUM_TESTS):
        q = _rand_modulus()
        operands = [rng.randint(0, q - 1) for _ in range(n)]
        test_vectors.append((operands, q))

    cocotb.log.info(
        "First 3 vectors: "
        + ", ".join(
            f"(sum_ops={sum(ops)}, q={q:#x})"
            for ops, q in test_vectors[:3]
        )
    )

    dut.i_a.value = 0
    dut.i_q.value = test_vectors[0][1]

    expected: deque = deque()
    total_cycles = NUM_TESTS + latency

    for cycle in range(total_cycles):
        if cycle < NUM_TESTS:
            operands, q = test_vectors[cycle]
            dut.i_a.value = _pack_operands(operands, logq)
            dut.i_q.value = q
            expected.append(_modacc_model(operands, q))

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.o_c.value)
            src_idx = cycle - latency
            _, q_src = test_vectors[src_idx]
            assert got == exp, (
                f"Cycle {cycle} (input #{src_idx}): "
                f"q={q_src:#x} -> expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(
        f"Passed {NUM_TESTS} pipelined independent-(A,q) tests "
        f"(LATENCY={latency})."
    )


@cocotb.test()
async def test_single_nonzero_operand(dut):
    """
    For each operand slot, set only that slot to a nonzero value and
    verify the output equals that value (since 0+...+v+...+0 mod q = v).
    """
    p = _read_params(dut)
    latency = p['latency']
    logq = p['logq']
    n = p['num_inputs']

    Clock(dut.clk, 10, "ns").start()

    q = _effective_q(p)
    rng = random.Random(0x51DE)

    dut.i_a.value = 0
    dut.i_q.value = q

    vectors = []
    for slot in range(n):
        operands = [0] * n
        val = rng.randint(1, q - 1)
        operands[slot] = val
        vectors.append((operands, q))

    if latency == 0:
        for operands, q_val in vectors:
            dut.i_a.value = _pack_operands(operands, logq)
            dut.i_q.value = q_val
            await RisingEdge(dut.clk)
            got = int(dut.o_c.value)
            exp = _modacc_model(operands, q_val)
            assert got == exp, (
                f"Single-nonzero comb: expected {exp:#x}, got {got:#x}"
            )
        cocotb.log.info("Single-nonzero test passed (combinatorial).")
        return

    expected: deque = deque()
    total_cycles = len(vectors) + latency
    vec_iter = iter(vectors)
    vec_exhausted = False

    for cycle in range(total_cycles):
        if not vec_exhausted:
            try:
                operands, q_val = next(vec_iter)
                dut.i_a.value = _pack_operands(operands, logq)
                dut.i_q.value = q_val
                expected.append(_modacc_model(operands, q_val))
            except StopIteration:
                vec_exhausted = True

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.o_c.value)
            assert got == exp, (
                f"Single-nonzero cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info("Single-nonzero test passed.")