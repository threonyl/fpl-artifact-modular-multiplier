"""
Cocotb testbench for the addtree module (binary reduction / CSA tree).

Latency Analysis
----------------
The addtree module supports two reduction strategies selected by USE_CSA:

  USE_CSA = 0  (default, binary reduction)
    A binary reduction tree: at each stage inputs are paired and summed;
    an odd leftover element is forwarded to the next stage.

      NUM_STAGES = ceil(log2(NUM_INPUTS))     (0 when NUM_INPUTS <= 1)

  USE_CSA = 1  (carry-save compression + final binary add)
    A CSA tree compresses operands 3-to-2 each stage, then a single
    binary adder resolves the final pair.

      CSA_STAGES = number of 3->2 levels to reach <=2 operands
      TOTAL_STAGES = CSA_STAGES + 1           (the +1 is the final adder)

Pipeline registers are inserted every REG_PERIOD stages (compression
*and* final-adder stages are counted uniformly).
A register is placed after stage s when (s+1) % REG_PERIOD == 0.

The total pipeline latency is:

    LATENCY = REG_IN
            + floor(TOTAL_STAGES / REG_PERIOD)          [intermediate regs]
            + FF_ADD                                      [split adder, CSA only]
            + REG_OUT * (TOTAL_STAGES % REG_PERIOD != 0) [output reg, if not merged]

REG_OUT is merged with the last intermediate register when
TOTAL_STAGES is an exact multiple of REG_PERIOD.

When FF_ADD = 1 (CSA mode, NUM_INPUTS > 2), the final carry-propagate
adder is split at a CARRY8-aligned midpoint into two pipeline stages,
adding one extra clock cycle of latency.

Default parameters (WIDTH=32, NUM_INPUTS=16, REG_PERIOD=1,
REG_IN=1, REG_OUT=1, USE_CSA=0, FF_ADD=0):
    NUM_STAGES = 4
    intermediate regs = 4/1 = 4
    last stage has reg (4%1==0) -> REG_OUT merged
    LATENCY = 1 + 4 + 0 = 5
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _num_stages(n: int) -> int:
    """Return the number of binary-reduction stages to reduce n inputs to 1."""
    s = 0
    while n > 1:
        n = (n + 1) // 2
        s += 1
    return s


def _csa_num_stages(n: int) -> int:
    """Return the number of 3-to-2 compression stages to reduce n to <= 2."""
    s = 0
    while n > 2:
        n = 2 * (n // 3) + (n % 3)
        s += 1
    return s


def _total_stages(num_inputs: int, use_csa: int) -> int:
    """Return the unified stage count matching addtree_pkg::total_stages."""
    if use_csa and num_inputs > 2:
        return _csa_num_stages(num_inputs) + 1
    return _num_stages(num_inputs)


def _compute_latency(num_inputs: int, reg_period: int,
                     reg_in: int, reg_out: int,
                     use_csa: int = 0, ff_add: int = 0) -> int:
    """Return the total pipeline depth of the addtree, matching addtree_pkg."""
    ns = _total_stages(num_inputs, use_csa)
    if ns == 0:
        return 0

    lat = reg_in

    if reg_period > 0:
        lat += ns // reg_period

    # FF_ADD: split the final binary adder (CSA mode only, NUM_INPUTS > 2)
    if ff_add and use_csa and num_inputs > 2:
        lat += 1

    # REG_OUT adds a cycle only if the last stage doesn't already have a reg
    if reg_out and not (reg_period > 0 and (ns % reg_period) == 0):
        lat += 1

    return lat


def _addtree_model(operands: list[int], width: int) -> int:
    """Golden reference: sum all operands, truncated to WIDTH bits."""
    mask = (1 << width) - 1
    return sum(operands) & mask


def _read_params(dut) -> tuple[int, int, int, int, int, int, int]:
    """Read synthesis parameters from the DUT and return them as ints."""
    width      = int(dut.WIDTH.value)
    num_inputs = int(dut.NUM_INPUTS.value)
    reg_period = int(dut.REG_PERIOD.value)
    reg_in     = int(dut.REG_IN.value)
    reg_out    = int(dut.REG_OUT.value)
    use_csa    = int(dut.USE_CSA.value)
    ff_add     = int(dut.FF_ADD.value)
    return width, num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add


def _pack_operands(operands: list[int], width: int) -> int:
    """Pack a list of operands into the wide i_a bus (little-endian packing)."""
    mask = (1 << width) - 1
    packed = 0
    for i, val in enumerate(operands):
        packed |= (val & mask) << (i * width)
    return packed


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_latency_detection(dut):
    """
    Log the detected parameters and computed latency so it is visible
    in the simulation transcript, and verify against the DUT's LATENCY
    localparam.
    """
    width, num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add = _read_params(dut)
    latency = _compute_latency(num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add)

    mode = "CSA" if use_csa else "binary"
    cocotb.log.info(
        f"DUT parameters: WIDTH={width}, NUM_INPUTS={num_inputs}, "
        f"REG_PERIOD={reg_period}, REG_IN={reg_in}, REG_OUT={reg_out}, "
        f"USE_CSA={use_csa} ({mode} mode), FF_ADD={ff_add}"
    )
    cocotb.log.info(f"Computed pipeline LATENCY = {latency} cycle(s)")

    dut_latency = int(dut.LATENCY.value)
    cocotb.log.info(f"DUT LATENCY localparam    = {dut_latency} cycle(s)")
    assert latency == dut_latency, (
        f"Latency mismatch: computed {latency} != DUT LATENCY {dut_latency}"
    )


@cocotb.test()
async def test_all_zeros(dut):
    """Verify that all-zero inputs produce a zero output."""
    width, num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add = _read_params(dut)
    latency = _compute_latency(num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add)

    Clock(dut.clk, 10, "ns").start()

    operands = [0] * num_inputs
    dut.i_a.value = _pack_operands(operands, width)

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
    width, num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add = _read_params(dut)
    latency = _compute_latency(num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add)
    n = num_inputs
    mask = (1 << width) - 1

    Clock(dut.clk, 10, "ns").start()

    # Build corner-case vectors
    vectors = []

    # All zeros
    vectors.append([0] * n)

    # All ones
    vectors.append([1] * n)

    # All max-value operands (all bits set)
    vectors.append([mask] * n)

    # Single non-zero in first position
    single = [0] * n
    single[0] = mask
    vectors.append(single[:])

    # Single non-zero in last position
    single = [0] * n
    single[-1] = mask
    vectors.append(single[:])

    # Alternating 0 and max
    alt = [mask if (i % 2 == 0) else 0 for i in range(n)]
    vectors.append(alt)

    # All half-max values
    vectors.append([(mask >> 1)] * n)

    # Sequential 0, 1, 2, ... (clamped to width)
    seq = [i & mask for i in range(n)]
    vectors.append(seq)

    # Powers of two (wrapping within width)
    pows = [(1 << (i % width)) for i in range(n)]
    vectors.append(pows)

    # Sum that exactly equals 2^WIDTH (tests clean wraparound)
    if n >= 2:
        wrap = [0] * n
        wrap[0] = mask
        wrap[1] = 1
        vectors.append(wrap)

    # Initialise inputs
    dut.i_a.value = 0

    if latency == 0:
        for operands in vectors:
            dut.i_a.value = _pack_operands(operands, width)
            await RisingEdge(dut.clk)
            got = int(dut.o_c.value)
            exp = _addtree_model(operands, width)
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
                operands = next(vec_iter)
                dut.i_a.value = _pack_operands(operands, width)
                expected.append(_addtree_model(operands, width))
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
    width, num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add = _read_params(dut)
    latency = _compute_latency(num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add)
    n = num_inputs
    mask = (1 << width) - 1

    Clock(dut.clk, 10, "ns").start()

    NUM_TESTS = 200
    rng = random.Random(0xADD_78EE)

    dut.i_a.value = 0

    if latency == 0:
        for _ in range(NUM_TESTS):
            operands = [rng.randint(0, mask) for _ in range(n)]
            dut.i_a.value = _pack_operands(operands, width)
            await RisingEdge(dut.clk)
            got = int(dut.o_c.value)
            exp = _addtree_model(operands, width)
            assert got == exp, f"Random comb: exp={exp:#x} got={got:#x}"
        cocotb.log.info(f"Passed {NUM_TESTS} combinatorial random tests.")
        return

    expected: deque = deque()
    total_cycles = NUM_TESTS + latency

    for cycle in range(total_cycles):
        if cycle < NUM_TESTS:
            operands = [rng.randint(0, mask) for _ in range(n)]
            dut.i_a.value = _pack_operands(operands, width)
            expected.append(_addtree_model(operands, width))

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
async def test_single_nonzero_operand(dut):
    """
    For each operand slot, set only that slot to a nonzero value and
    verify the output equals that value (since 0+...+v+...+0 = v).
    This exercises every path through the tree including passthroughs
    for odd-numbered stages (binary mode) and remainder elements
    (CSA mode).
    """
    width, num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add = _read_params(dut)
    latency = _compute_latency(num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add)
    n = num_inputs
    mask = (1 << width) - 1

    Clock(dut.clk, 10, "ns").start()

    rng = random.Random(0x51DE)

    dut.i_a.value = 0

    vectors = []
    for slot in range(n):
        operands = [0] * n
        val = rng.randint(1, mask)
        operands[slot] = val
        vectors.append(operands)

    if latency == 0:
        for operands in vectors:
            dut.i_a.value = _pack_operands(operands, width)
            await RisingEdge(dut.clk)
            got = int(dut.o_c.value)
            exp = _addtree_model(operands, width)
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
                operands = next(vec_iter)
                dut.i_a.value = _pack_operands(operands, width)
                expected.append(_addtree_model(operands, width))
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


@cocotb.test()
async def test_overflow_wraparound(dut):
    """
    Verify that addition correctly wraps modulo 2^WIDTH.

    Drives operand sets whose exact sum exceeds 2^WIDTH by known amounts,
    checking that the truncated result matches the golden model.
    """
    width, num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add = _read_params(dut)
    latency = _compute_latency(num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add)
    n = num_inputs
    mask = (1 << width) - 1

    Clock(dut.clk, 10, "ns").start()

    vectors = []

    # All max-value: n * (2^WIDTH - 1) mod 2^WIDTH
    vectors.append([mask] * n)

    # (2^WIDTH - 1) + 1 + 0 + ... = 0  (exact single wraparound)
    if n >= 2:
        v = [0] * n
        v[0] = mask
        v[1] = 1
        vectors.append(v)

    # (2^WIDTH - 1) + 2 + 0 + ... = 1
    if n >= 2:
        v = [0] * n
        v[0] = mask
        v[1] = 2
        vectors.append(v)

    # Half the operands are (2^WIDTH - 1), the rest are 1
    half = n // 2
    v = [mask] * half + [1] * (n - half)
    vectors.append(v)

    # Descending from max
    v = [(mask - i) & mask for i in range(n)]
    vectors.append(v)

    dut.i_a.value = 0

    if latency == 0:
        for operands in vectors:
            dut.i_a.value = _pack_operands(operands, width)
            await RisingEdge(dut.clk)
            got = int(dut.o_c.value)
            exp = _addtree_model(operands, width)
            assert got == exp, (
                f"Overflow comb: expected {exp:#x}, got {got:#x}"
            )
        cocotb.log.info("Overflow wraparound test passed (combinatorial).")
        return

    expected: deque = deque()
    total_cycles = len(vectors) + latency
    vec_iter = iter(vectors)
    vec_exhausted = False

    for cycle in range(total_cycles):
        if not vec_exhausted:
            try:
                operands = next(vec_iter)
                dut.i_a.value = _pack_operands(operands, width)
                expected.append(_addtree_model(operands, width))
            except StopIteration:
                vec_exhausted = True

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.o_c.value)
            assert got == exp, (
                f"Overflow cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info("Overflow wraparound test passed.")


@cocotb.test()
async def test_back_to_back_patterns(dut):
    """
    Alternate between distinct patterns every cycle at full pipeline
    throughput to stress the register boundaries.

    Uses two patterns, all-ones and a counting sequence, to ensure
    data from different cycles does not bleed across pipeline stages.
    """
    width, num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add = _read_params(dut)
    latency = _compute_latency(num_inputs, reg_period, reg_in, reg_out, use_csa, ff_add)
    n = num_inputs
    mask = (1 << width) - 1

    Clock(dut.clk, 10, "ns").start()

    pattern_a = [mask] * n
    pattern_b = [(i + 1) & mask for i in range(n)]

    NUM_TESTS = 100
    dut.i_a.value = 0

    if latency == 0:
        for t in range(NUM_TESTS):
            ops = pattern_a if (t % 2 == 0) else pattern_b
            dut.i_a.value = _pack_operands(ops, width)
            await RisingEdge(dut.clk)
            got = int(dut.o_c.value)
            exp = _addtree_model(ops, width)
            assert got == exp, (
                f"Back-to-back comb t={t}: expected {exp:#x}, got {got:#x}"
            )
        cocotb.log.info("Back-to-back pattern test passed (combinatorial).")
        return

    expected: deque = deque()
    total_cycles = NUM_TESTS + latency

    for cycle in range(total_cycles):
        if cycle < NUM_TESTS:
            ops = pattern_a if (cycle % 2 == 0) else pattern_b
            dut.i_a.value = _pack_operands(ops, width)
            expected.append(_addtree_model(ops, width))

        await RisingEdge(dut.clk)

        if cycle >= latency and expected:
            exp = expected.popleft()
            got = int(dut.o_c.value)
            assert got == exp, (
                f"Back-to-back cycle={cycle}: expected {exp:#x}, got {got:#x}"
            )

    cocotb.log.info(
        f"Back-to-back pattern test passed (LATENCY={latency})."
    )