"""
Cocotb testbench for the modadd (modular adder) module.

Latency Analysis
----------------
The pipeline depth depends on the four boolean parameters:

    LATENCY = REG_IN + REG_ADD + (REG_ADD & ~CONC_ADDSUB) + REG_OUT

When CONC_ADDSUB=0 the subtraction result r_s is computed *after* the
registered addition result r, so REG_ADD contributes an extra stage.

Default parameters (REG_IN=1, REG_OUT=1, REG_ADD=1, CONC_ADDSUB=1):
    LATENCY = 1 + 1 + 0 + 1 = 3

Fixed-modulus mode (FIXED_Q=1)
------------------------------
When FIXED_Q=1 the compile-time constant Q_VALUE is used as the modulus
and the i_q input port is ignored.  Tests that change the modulus at
run time are skipped in this mode.
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _compute_latency(reg_in: int, reg_out: int, reg_add: int, conc_addsub: int) -> int:
    """Return the pipeline depth for the given parameter combination."""
    extra = reg_add if not conc_addsub else 0
    return reg_in + reg_add + extra + reg_out


def _modadd_model(a: int, b: int, q: int) -> int:
    """Golden-reference: conditional-subtraction modular addition."""
    s = a + b
    return s - q if s >= q else s


def _read_params(dut) -> tuple[int, int, int, int, int, int, int]:
    """Read synthesis parameters from the DUT and return them as ints."""
    logq        = int(dut.LOGQ.value)
    reg_in      = int(dut.REG_IN.value)
    reg_out     = int(dut.REG_OUT.value)
    reg_add     = int(dut.REG_ADD.value)
    conc_addsub = int(dut.CONC_ADDSUB.value)
    fixed_q     = int(dut.FIXED_Q.value)
    q_value     = int(dut.Q_VALUE.value)
    return logq, reg_in, reg_out, reg_add, conc_addsub, fixed_q, q_value


def _default_q(logq: int) -> int:
    """Return a suitable test modulus derived from LOGQ (prime-ish, below 2^LOGQ)."""
    return (1 << logq) - (3 if logq >= 4 else 1)


def _effective_q(logq: int, fixed_q: int, q_value: int) -> int:
    """Return the modulus the DUT will actually use.

    When FIXED_Q=1 the hardware ignores i_q and uses Q_VALUE, so the
    testbench must do the same.
    """
    if fixed_q:
        return q_value
    return _default_q(logq)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_latency_detection(dut):
    """
    Log the detected parameters and computed latency so it is visible
    in the simulation transcript.  No assertions - purely informational.
    """
    logq, reg_in, reg_out, reg_add, conc_addsub, fixed_q, q_value = _read_params(dut)
    latency = _compute_latency(reg_in, reg_out, reg_add, conc_addsub)

    cocotb.log.info(
        f"DUT parameters: LOGQ={logq}, REG_IN={reg_in}, REG_OUT={reg_out}, "
        f"REG_ADD={reg_add}, CONC_ADDSUB={conc_addsub}, "
        f"FIXED_Q={fixed_q}, Q_VALUE={q_value:#x}"
    )
    cocotb.log.info(f"Computed pipeline LATENCY = {latency} cycle(s)")

    dut_latency = int(dut.LATENCY.value)
    cocotb.log.info(f"DUT LATENCY parameter     = {dut_latency} cycle(s)")
    assert latency == dut_latency, (
        f"Latency mismatch: computed {latency} != DUT LATENCY parameter {dut_latency}"
    )


@cocotb.test()
async def test_corner_cases(dut):
    """
    Drive hand-crafted corner cases through the pipeline and verify
    each output exactly latency cycles after the corresponding input.
    """
    logq, reg_in, reg_out, reg_add, conc_addsub, fixed_q, q_value = _read_params(dut)
    latency = _compute_latency(reg_in, reg_out, reg_add, conc_addsub)

    Clock(dut.clk, 10, "ns").start()

    q = _effective_q(logq, fixed_q, q_value)

    vectors = [
        (0,     0,     q),       # 0 + 0 = 0
        (0,     1,     q),       # 0 + 1 = 1
        (q - 1, 1,     q),       # boundary -> 0
        (q - 1, 2,     q),       # boundary -> 1
        (q - 1, q - 1, q),       # largest + largest -> q-2
        (q // 2, q // 2, q),     # mid + mid
        (1,     q - 1, q),       # 1 + (q-1) -> 0
        (q - 2, q - 2, q),       # near-boundary
    ]

    # Initialise inputs to a safe state
    dut.i_a.value = 0
    dut.i_b.value = 0
    dut.i_q.value = q

    # When latency == 0 the output is purely combinatorial
    if latency == 0:
        for a, b, q_val in vectors:
            dut.i_a.value = a
            dut.i_b.value = b
            dut.i_q.value = q_val
            # One delta cycle for combinatorial settle
            await RisingEdge(dut.clk)
            got = int(dut.o_c.value)
            exp = _modadd_model(a, b, q_val)
            assert got == exp, (
                f"Comb: a={a:#x} b={b:#x} q={q_val:#x} -> "
                f"expected {exp:#x}, got {got:#x}"
            )
        return

    # Pipelined check via a sliding window.
    #
    # Timing note: await RisingEdge() resumes in the "Values Changed" phase,
    # BEFORE the DUT's always_ff blocks evaluate.  Reading o_c right after
    # RisingEdge gives the value registered at the *previous* edge, not the
    # current one.  Therefore the correct check offset is `cycle >= latency`
    # (not latency-1): input applied at cycle C is readable after the rising
    # edge of cycle C+latency.
    expected: deque = deque()
    total_cycles = len(vectors) + latency

    vec_iter = iter(vectors)
    vec_exhausted = False

    for cycle in range(total_cycles):
        # Apply next input (if any remain)
        if not vec_exhausted:
            try:
                a, b, q_val = next(vec_iter)
                dut.i_a.value = a
                dut.i_b.value = b
                dut.i_q.value = q_val
                expected.append(_modadd_model(a, b, q_val))
            except StopIteration:
                vec_exhausted = True

        await RisingEdge(dut.clk)

        # o_c now holds the value registered on the *previous* rising edge.
        # That corresponds to the input applied latency cycles ago.
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
    logq, reg_in, reg_out, reg_add, conc_addsub, fixed_q, q_value = _read_params(dut)
    latency = _compute_latency(reg_in, reg_out, reg_add, conc_addsub)

    Clock(dut.clk, 10, "ns").start()

    q = _effective_q(logq, fixed_q, q_value)
    NUM_TESTS = 200
    rng = random.Random(0xC0C0_1B)

    dut.i_a.value = 0
    dut.i_b.value = 0
    dut.i_q.value = q

    if latency == 0:
        # Combinatorial: check immediately after each assignment
        for _ in range(NUM_TESTS):
            a = rng.randint(0, q - 1)
            b = rng.randint(0, q - 1)
            dut.i_a.value = a
            dut.i_b.value = b
            dut.i_q.value = q
            await RisingEdge(dut.clk)
            got = int(dut.o_c.value)
            exp = _modadd_model(a, b, q)
            assert got == exp, f"Random comb: {a}+{b} mod {q}: exp={exp} got={got}"
        cocotb.log.info(f"Passed {NUM_TESTS} combinatorial random tests.")
        return

    expected: deque = deque()
    total_cycles = NUM_TESTS + latency

    for cycle in range(total_cycles):
        # Apply a new input every cycle for full-throughput pipelining
        if cycle < NUM_TESTS:
            a = rng.randint(0, q - 1)
            b = rng.randint(0, q - 1)
            dut.i_a.value = a
            dut.i_b.value = b
            dut.i_q.value = q
            expected.append(_modadd_model(a, b, q))

        await RisingEdge(dut.clk)

        # See timing note in test_corner_cases: check at cycle >= latency.
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
    logq, reg_in, reg_out, reg_add, conc_addsub, fixed_q, q_value = _read_params(dut)

    if fixed_q:
        cocotb.log.info(
            "FIXED_Q=1, skipping test_changing_modulus "
            "(i_q port is ignored, modulus is compile-time constant)."
        )
        return

    latency = _compute_latency(reg_in, reg_out, reg_add, conc_addsub)

    Clock(dut.clk, 10, "ns").start()

    flush = max(latency, 1)

    moduli = [
        (1 << logq) - 3,
        (1 << logq) - 15,
        (1 << (logq // 2)) - 3,
    ]

    for q in moduli:
        # Let the pipeline drain with zeros before switching modulus
        dut.i_a.value = 0
        dut.i_b.value = 0
        dut.i_q.value = q
        await ClockCycles(dut.clk, flush)

        expected: deque = deque()
        rng = random.Random(q)
        NUM = 30
        total = NUM + latency

        for cycle in range(total):
            if cycle < NUM:
                a = rng.randint(0, q - 1)
                b = rng.randint(0, q - 1)
                dut.i_a.value = a
                dut.i_b.value = b
                dut.i_q.value = q
                expected.append(_modadd_model(a, b, q))

            await RisingEdge(dut.clk)

            # See timing note in test_corner_cases: check at cycle >= latency.
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
    Every clock cycle presents a completely independent (a, b, q) triple,
    i.e. the modulus changes at full pipeline throughput:

        CC 0 :  a=a_0, b=b_0, q=q_0
        CC 1 :  a=a_1, b=b_1, q=q_1
        CC 2 :  a=a_2, b=b_2, q=q_2
        ...

    The expected queue tracks (a_i + b_i) mod q_i for each individual triple
    so the checker can verify each output independently of all others.

    Skipped when FIXED_Q=1 because the modulus is a compile-time constant
    and the i_q port is ignored.
    """
    logq, reg_in, reg_out, reg_add, conc_addsub, fixed_q, q_value = _read_params(dut)

    if fixed_q:
        cocotb.log.info(
            "FIXED_Q=1, skipping test_pipelined_changing_modulus "
            "(i_q port is ignored, modulus is compile-time constant)."
        )
        return

    latency = _compute_latency(reg_in, reg_out, reg_add, conc_addsub)

    Clock(dut.clk, 10, "ns").start()

    NUM_TESTS = 200
    rng = random.Random(0xC0_FFEE)

    # Build a pool of distinct, varied moduli, one per input cycle.
    # We pick primes just below different powers of 2 to exercise a wide range.
    def _rand_modulus() -> int:
        """Return a random odd number in (2^(logq//2), 2^logq - 1)."""
        lo = 1 << (logq // 2)
        hi = (1 << logq) - 2
        m = rng.randint(lo, hi) | 1   # force odd so it stays away from powers-of-2
        return m

    # Pre-generate all (a, b, q) triples up front so they are independent
    # of the simulation loop timing.
    triples = []
    for _ in range(NUM_TESTS):
        q = _rand_modulus()
        a = rng.randint(0, q - 1)
        b = rng.randint(0, q - 1)
        triples.append((a, b, q))

    # Log a short sample so the transcript shows the variety
    cocotb.log.info(
        "First 4 triples: "
        + ", ".join(f"(a={a:#x}, b={b:#x}, q={q:#x})" for a, b, q in triples[:4])
    )

    # Initialise inputs to a safe state before the first edge
    dut.i_a.value = 0
    dut.i_b.value = 0
    dut.i_q.value = triples[0][2]

    expected: deque = deque()   # holds _modadd_model results in order
    total_cycles = NUM_TESTS + latency

    for cycle in range(total_cycles):
        # Apply the next triple on every cycle until we run out of inputs
        if cycle < NUM_TESTS:
            a, b, q = triples[cycle]
            dut.i_a.value = a
            dut.i_b.value = b
            dut.i_q.value = q
            expected.append(_modadd_model(a, b, q))

        await RisingEdge(dut.clk)

        # The output seen after this edge corresponds to the input applied
        # `latency` cycles ago (see timing note in test_corner_cases).
        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.o_c.value)
            # Also re-derive which triple this output belongs to for the message
            src_idx = cycle - latency
            a_src, b_src, q_src = triples[src_idx]
            assert got == exp, (
                f"Cycle {cycle} (input #{src_idx}): "
                f"a={a_src:#x} b={b_src:#x} q={q_src:#x} -> "
                f"expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(
        f"Passed {NUM_TESTS} pipelined independent-(a,b,q) tests "
        f"(LATENCY={latency})."
    )