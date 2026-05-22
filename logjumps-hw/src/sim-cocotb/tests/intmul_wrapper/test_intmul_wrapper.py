"""
Cocotb testbench for the intmul_wrapper (unsigned integer multiplier) module.

Functional specification
------------------------
The module computes the unsigned product:

    C = A * B

where  A is LOGA bits wide  and  B is LOGB bits wide.
The result C is (LOGA + LOGB) bits wide.

Depending on the NON_STD and USE_KARATSUBA parameters and the operand
widths, the wrapper selects among four multiplication topologies
(mac_std, BBxAB, BBAxBBA, karatsuba_mul).  USE_KARATSUBA takes priority
over NON_STD.  From the testbench's perspective the topology is
transparent -- the golden model is always A * B.

Pipeline latency
----------------
The full pipeline depth is exposed as the localparam LAT inside the DUT:

    LAT = f(FF_IN, FF_MUL, FF_OUT, USE_CSA, FF_CSA, topology,
            USE_KARATSUBA, K_PIPE_DSP, K_PIPE_PRE, K_PIPE_POST, K_PIPE_MID)

All inputs (A, B) for a given transaction are presented on the same
clock edge; the result appears LAT cycles later.

Default parameters (LOGA=384, LOGB=384, FF_IN=1, FF_MUL=1, FF_OUT=1,
                    USE_CSA=0, FF_CSA=0, MORE_DSP=0, NON_STD=0,
                    USE_KARATSUBA=0, K_PIPE_DSP=3, K_PIPE_PRE=1,
                    K_PIPE_POST=1, K_PIPE_MID=1).
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------

def _golden(A: int, B: int) -> int:
    """Golden reference: unsigned A * B."""
    return A * B


def _read_params(dut) -> tuple[int, int]:
    """Read key synthesis parameters from the DUT."""
    loga = int(dut.LOGA.value)
    logb = int(dut.LOGB.value)
    return loga, logb


def _read_latency(dut) -> int:
    """Read the total pipeline depth from the DUT's LAT localparam."""
    return int(dut.LAT.value)


def _drive_inputs(dut, A_val: int, B_val: int):
    """Apply a complete input vector to the DUT ports."""
    dut.A.value = A_val
    dut.B.value = B_val


# ---------------------------------------------------------------------------
#  Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_latency_detection(dut):
    """
    Log detected parameters and the pipeline latency so they are
    visible in the simulation transcript.
    """
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    cocotb.log.info(
        f"DUT parameters: LOGA={loga}, LOGB={logb}, "
        f"FF_IN={int(dut.FF_IN.value)}, FF_MUL={int(dut.FF_MUL.value)}, "
        f"FF_OUT={int(dut.FF_OUT.value)}, "
        f"USE_CSA={int(dut.USE_CSA.value)}, FF_CSA={int(dut.FF_CSA.value)}, "
        f"MORE_DSP={int(dut.MORE_DSP.value)}, NON_STD={int(dut.NON_STD.value)}, "
        f"USE_KARATSUBA={int(dut.USE_KARATSUBA.value)}, "
        f"K_PIPE_DSP={int(dut.K_PIPE_DSP.value)}, "
        f"K_PIPE_PRE={int(dut.K_PIPE_PRE.value)}, "
        f"K_PIPE_POST={int(dut.K_PIPE_POST.value)}, "
        f"K_PIPE_MID={int(dut.K_PIPE_MID.value)}"
    )
    cocotb.log.info(f"DUT pipeline LAT = {latency} cycle(s)")


@cocotb.test()
async def test_zero_inputs(dut):
    """A=0 or B=0 must always produce C=0."""
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    flush = max(latency, 1)
    mask_a = (1 << loga) - 1
    mask_b = (1 << logb) - 1

    # A=0, B=max
    _drive_inputs(dut, 0, mask_b)
    await ClockCycles(dut.clk, flush + 1)
    got = int(dut.C.value)
    assert got == 0, f"A=0, B=max: expected 0, got {got:#x}"

    # A=max, B=0
    _drive_inputs(dut, mask_a, 0)
    await ClockCycles(dut.clk, flush + 1)
    got = int(dut.C.value)
    assert got == 0, f"A=max, B=0: expected 0, got {got:#x}"

    # A=0, B=0
    _drive_inputs(dut, 0, 0)
    await ClockCycles(dut.clk, flush + 1)
    got = int(dut.C.value)
    assert got == 0, f"A=0, B=0: expected 0, got {got:#x}"

    cocotb.log.info("Zero-input tests passed.")


@cocotb.test()
async def test_identity_multiply(dut):
    """Multiplying by 1 must return the other operand."""
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    flush = max(latency, 1)
    rng = random.Random(0x1DEA)

    mask_a = (1 << loga) - 1
    mask_b = (1 << logb) - 1

    # A=1, B=random
    for _ in range(5):
        b_val = rng.randint(0, mask_b)
        _drive_inputs(dut, 1, b_val)
        await ClockCycles(dut.clk, flush + 1)
        got = int(dut.C.value)
        exp = b_val
        assert got == exp, f"1*B: expected {exp:#x}, got {got:#x}"

    # A=random, B=1
    for _ in range(5):
        a_val = rng.randint(0, mask_a)
        _drive_inputs(dut, a_val, 1)
        await ClockCycles(dut.clk, flush + 1)
        got = int(dut.C.value)
        exp = a_val
        assert got == exp, f"A*1: expected {exp:#x}, got {got:#x}"

    cocotb.log.info("Identity-multiply tests passed.")


@cocotb.test()
async def test_corner_cases(dut):
    """
    Hand-crafted corner-case (A, B) pairs driven through the pipeline.
    Each output is checked exactly `latency` cycles after its
    corresponding input.
    """
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    mask_a = (1 << loga) - 1
    mask_b = (1 << logb) - 1
    mask_c = (1 << (loga + logb)) - 1

    # Build corner-case (A, B) pairs
    vectors: list[tuple[int, int]] = [
        (0,      0),                        # zero * zero
        (1,      1),                        # one * one
        (mask_a, mask_b),                   # max * max
        (mask_a, 1),                        # max * one
        (1,      mask_b),                   # one * max
        (1 << (loga - 1), 1),               # MSB of A set
        (1,               1 << (logb - 1)), # MSB of B set
        (1 << (loga - 1), 1 << (logb - 1)), # both MSBs set
        (mask_a, 2),                        # max * 2 (shift check)
        (2,      mask_b),                   # 2 * max
        ((1 << loga) - 2, (1 << logb) - 2), # (max-1) * (max-1)
    ]

    _drive_inputs(dut, 0, 0)

    if latency == 0:
        for A_val, B_val in vectors:
            _drive_inputs(dut, A_val, B_val)
            await RisingEdge(dut.clk)
            got = int(dut.C.value)
            exp = _golden(A_val, B_val) & mask_c
            assert got == exp, (
                f"Corner (comb): A={A_val:#x}, B={B_val:#x} "
                f"-> expected {exp:#x}, got {got:#x}"
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
                _drive_inputs(dut, A_val, B_val)
                expected.append(_golden(A_val, B_val) & mask_c)
            except StopIteration:
                vec_exhausted = True

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.C.value)
            assert got == exp, (
                f"Corner cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info("All corner cases passed.")


@cocotb.test()
async def test_powers_of_two(dut):
    """
    Multiply by powers of two to verify shift-like behaviour
    across the full operand width.
    """
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    flush = max(latency, 1)
    mask_c = (1 << (loga + logb)) - 1
    rng = random.Random(0xBEAD)

    mask_a = (1 << loga) - 1
    mask_b = (1 << logb) - 1

    # A = power-of-two, B = random constant
    b_const = rng.randint(1, mask_b)
    for shift in range(0, loga, max(1, loga // 16)):
        a_val = 1 << shift
        _drive_inputs(dut, a_val, b_const)
        await ClockCycles(dut.clk, flush + 1)
        got = int(dut.C.value)
        exp = _golden(a_val, b_const) & mask_c
        assert got == exp, (
            f"Pow2 A=2^{shift}: expected {exp:#x}, got {got:#x}"
        )

    # B = power-of-two, A = random constant
    a_const = rng.randint(1, mask_a)
    for shift in range(0, logb, max(1, logb // 16)):
        b_val = 1 << shift
        _drive_inputs(dut, a_const, b_val)
        await ClockCycles(dut.clk, flush + 1)
        got = int(dut.C.value)
        exp = _golden(a_const, b_val) & mask_c
        assert got == exp, (
            f"Pow2 B=2^{shift}: expected {exp:#x}, got {got:#x}"
        )

    cocotb.log.info("Power-of-two tests passed.")


@cocotb.test()
async def test_random_pipeline(dut):
    """
    Stress-test with random (A, B) values pipelined at full throughput.
    """
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    mask_a = (1 << loga) - 1
    mask_b = (1 << logb) - 1
    mask_c = (1 << (loga + logb)) - 1

    NUM_TESTS = pow(2,15)
    rng = random.Random(0xBEEF_CAFE)

    _drive_inputs(dut, 0, 0)

    if latency == 0:
        for _ in range(NUM_TESTS):
            A_val = rng.randint(0, mask_a)
            B_val = rng.randint(0, mask_b)
            _drive_inputs(dut, A_val, B_val)
            await RisingEdge(dut.clk)
            got = int(dut.C.value)
            exp = _golden(A_val, B_val) & mask_c
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
            A_val = rng.randint(0, mask_a)
            B_val = rng.randint(0, mask_b)
            _drive_inputs(dut, A_val, B_val)
            expected.append(_golden(A_val, B_val) & mask_c)

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.C.value)
            assert got == exp, (
                f"Random cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(
        f"Passed {NUM_TESTS} pipelined random tests (LAT={latency})."
    )


@cocotb.test()
async def test_max_product(dut):
    """
    Drive A = max and B = max to exercise the full output width.
    The product (2^LOGA - 1) * (2^LOGB - 1) should fill every bit
    of C except the MSB.
    """
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    flush = max(latency, 1)
    mask_a = (1 << loga) - 1
    mask_b = (1 << logb) - 1
    mask_c = (1 << (loga + logb)) - 1

    _drive_inputs(dut, mask_a, mask_b)
    await ClockCycles(dut.clk, flush + 1)

    got = int(dut.C.value)
    exp = _golden(mask_a, mask_b) & mask_c
    assert got == exp, f"Max product: expected {exp:#x}, got {got:#x}"

    cocotb.log.info("Max-product test passed.")


@cocotb.test()
async def test_back_to_back_same_value(dut):
    """
    Drive the same (A, B) pair for many consecutive cycles and verify
    every output once the pipeline is primed.  This catches any
    state-dependent bugs in the datapath.
    """
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    mask_a = (1 << loga) - 1
    mask_b = (1 << logb) - 1
    mask_c = (1 << (loga + logb)) - 1

    # Use mid-range values
    A_val = mask_a >> 1
    B_val = mask_b >> 1
    exp = _golden(A_val, B_val) & mask_c

    _drive_inputs(dut, A_val, B_val)

    NUM_CHECKS = 50
    total_cycles = NUM_CHECKS + latency + 1

    for cycle in range(total_cycles):
        await RisingEdge(dut.clk)

        if cycle >= latency:
            got = int(dut.C.value)
            assert got == exp, (
                f"Back-to-back cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(f"Back-to-back test passed ({NUM_CHECKS} checks).")


@cocotb.test()
async def test_alternating_operands(dut):
    """
    Alternate between two distinct (A, B) pairs every cycle at full
    pipeline throughput.  This stresses the pipeline's ability to
    keep independent transactions separated.
    """
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    mask_a = (1 << loga) - 1
    mask_b = (1 << logb) - 1
    mask_c = (1 << (loga + logb)) - 1

    pair_0 = (mask_a, 1)                    # max * 1
    pair_1 = (1, mask_b)                    # 1 * max
    exp_0  = _golden(*pair_0) & mask_c
    exp_1  = _golden(*pair_1) & mask_c

    _drive_inputs(dut, 0, 0)

    NUM_PAIRS = 100
    expected: deque[int] = deque()
    total_cycles = NUM_PAIRS + latency

    for cycle in range(total_cycles):
        if cycle < NUM_PAIRS:
            pair = pair_0 if cycle % 2 == 0 else pair_1
            _drive_inputs(dut, *pair)
            expected.append(exp_0 if cycle % 2 == 0 else exp_1)

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.C.value)
            assert got == exp, (
                f"Alternating cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(f"Alternating-operand test passed ({NUM_PAIRS} pairs).")


@cocotb.test()
async def test_single_bit_walk(dut):
    """
    Walk a single '1' bit across A while B is held at all-ones.
    This verifies each bit position contributes correctly to the product.
    """
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    mask_b = (1 << logb) - 1
    mask_c = (1 << (loga + logb)) - 1

    # Sample a subset of bit positions to keep simulation time reasonable
    step = max(1, loga // 32)
    positions = list(range(0, loga, step))

    _drive_inputs(dut, 0, 0)

    if latency == 0:
        for pos in positions:
            a_val = 1 << pos
            _drive_inputs(dut, a_val, mask_b)
            await RisingEdge(dut.clk)
            got = int(dut.C.value)
            exp = _golden(a_val, mask_b) & mask_c
            assert got == exp, (
                f"Bit-walk A[{pos}] (comb): expected {exp:#x}, got {got:#x}"
            )
        cocotb.log.info(
            f"Single-bit-walk test passed (combinatorial, {len(positions)} positions)."
        )
        return

    expected: deque[int] = deque()
    total_cycles = len(positions) + latency
    pos_iter = iter(positions)
    pos_exhausted = False

    for cycle in range(total_cycles):
        if not pos_exhausted:
            try:
                pos = next(pos_iter)
                a_val = 1 << pos
                _drive_inputs(dut, a_val, mask_b)
                expected.append(_golden(a_val, mask_b) & mask_c)
            except StopIteration:
                pos_exhausted = True

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.C.value)
            assert got == exp, (
                f"Bit-walk cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(
        f"Single-bit-walk test passed ({len(positions)} positions, LAT={latency})."
    )


@cocotb.test()
async def test_small_operands(dut):
    """
    Exhaustively test all products for small operand values (0..63).
    This catches any errors in the low bits of the multiplier.
    """
    loga, logb = _read_params(dut)
    latency = _read_latency(dut)

    Clock(dut.clk, 10, "ns").start()

    mask_c = (1 << (loga + logb)) - 1
    LIMIT = min(64, (1 << loga), (1 << logb))

    _drive_inputs(dut, 0, 0)

    if latency == 0:
        for a in range(LIMIT):
            for b in range(LIMIT):
                _drive_inputs(dut, a, b)
                await RisingEdge(dut.clk)
                got = int(dut.C.value)
                exp = _golden(a, b) & mask_c
                assert got == exp, (
                    f"Small ({a}*{b}): expected {exp}, got {got}"
                )
        cocotb.log.info(
            f"Small-operand exhaustive test passed\n({LIMIT}x{LIMIT} = {LIMIT*LIMIT} products, combinatorial)."
        )
        return

    # Pipelined: flatten all pairs into a stream
    pairs = [(a, b) for a in range(LIMIT) for b in range(LIMIT)]
    expected: deque[int] = deque()
    total_cycles = len(pairs) + latency
    pair_iter = iter(pairs)
    pair_exhausted = False

    for cycle in range(total_cycles):
        if not pair_exhausted:
            try:
                a, b = next(pair_iter)
                _drive_inputs(dut, a, b)
                expected.append(_golden(a, b) & mask_c)
            except StopIteration:
                pair_exhausted = True

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.C.value)
            assert got == exp, (
                f"Small cycle={cycle}: expected {exp}, got {got}"
            )

    cocotb.log.info(
        f"Small-operand exhaustive test passed\n({LIMIT}x{LIMIT} = {LIMIT*LIMIT} products, LAT={latency})."
    )