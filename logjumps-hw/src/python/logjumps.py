"""
A simple implementation of LogJumps

Experimental: The conditional subtraction bound at
non-power-of-two word bits has not been analyzed thoroughly.
The tree approach has been formalized but only tested with
8M cases.
Stable: Bounds for power-of-two word bits have been analyzed.

This script is a simple probabilistic test harness
to demonstrate the idea.
"""

import math
import random
from typing import list

import numpy
import sympy
from tqdm import tqdm


# ---------------------------------------------------------------------
#  Configuration
# ---------------------------------------------------------------------

RANDOMIZE = True
VERBOSE = False

WORD_BITS = 4                # Bits per limb
WORD = 1 << WORD_BITS        # Limb modulus (2^{word_bits})
N_TARGET_BITS = 32           # Bit-length of the random prime modulus
NUM_TESTS = 1 << 23          # Number of random trials


# ---------------------------------------------------------------------
#  Limb helpers
# ---------------------------------------------------------------------

def get_word(value: int, word_size: int, index: int) -> int:
    """
    Extract the index-th word (limb) from a multi-precision integer.

    Args:
        value:     The integer to extract from.
        word_size: Bits per word/limb.
        index:     Which word to extract (0-indexed, least-significant first).

    Returns:
        The requested limb value.
    """
    return (value >> (word_size * index)) & ((1 << word_size) - 1)


def int_to_limbs(value: int, word_size: int) -> list[int]:
    """
    Convert an integer to a list of limbs (least-significant first).

    Args:
        value:     The integer to convert.
        word_size: Bits per limb.

    Returns:
        List of limbs, least-significant first.
    """
    if value == 0:
        return [0]
    num_limbs = (value.bit_length() + word_size - 1) // word_size
    return [get_word(value, word_size, i) for i in range(num_limbs)]


def limbs_to_int(limbs: list[int], word_size: int) -> int:
    """
    Convert a list of limbs back to an integer.

    Args:
        limbs:     List of limbs, least-significant first.
        word_size: Bits per limb.

    Returns:
        The reconstructed integer value.
    """
    return sum(limb << (i * word_size) for i, limb in enumerate(limbs))


# ---------------------------------------------------------------------
#  Montgomery-style reduction helpers
# ---------------------------------------------------------------------

def montgomery_reduce(T: int, N: int, mu: int, shift_bits: int) -> int:
    """
    Perform one Montgomery reduction step:
      m  = (T mod 2^{shift_bits}) * mu   (mod 2^{shift_bits})
      T' = (T + m*N) >> shift_bits

    Args:
        T:          Value to reduce.
        N:          The modulus.
        mu:         -N^{-1} mod 2^{shift_bits}.
        shift_bits: Number of bits to divide out.

    Returns:
        The partially reduced value T'.
    """
    radix = 1 << shift_bits
    T_lo = T % radix
    m = (T_lo * mu) % radix
    return (T + m * N) >> shift_bits


def conditional_subtract(value: int, N: int, max_iterations: int) -> int:
    """
    Subtract N from value up to max_iterations times until value < N.

    Args:
        value:          The value to correct.
        N:              The modulus.
        max_iterations: Maximum number of subtractions allowed.

    Returns:
        The corrected value in [0, N).
    """
    for _ in range(max_iterations):
        if value >= N:
            value -= N
    return value


# ---------------------------------------------------------------------
#  Sequential LogJumps reduction
# ---------------------------------------------------------------------

def sequential_reduce(C: int, N: int, n: int, rho: list[int],
                      mu_r: int, rem: int, rem_word: int,
                      rem_mu_r: int) -> int:
    """
    Perform the *sequential* LogJumps reduction of C modulo N.

    Each iteration replaces T with:
        T = T // word  +  (T mod word) * rho[1]

    followed by a single Montgomery reduction step and conditional
    subtraction to bring the result into [0, N).
    """
    T = C

    # n-1 sequential "jump" iterations
    for _ in range(1, n):
        T = T // WORD + (T % WORD) * rho[1]

    # Final Montgomery reduction step (handles the remainder limb
    # differently when N_bits is not a multiple of word_bits).
    if rem != 0:
        T = montgomery_reduce(T, N, rem_mu_r, rem)
    else:
        T = montgomery_reduce(T, N, mu_r, WORD_BITS)

    # At most 3 conditional subtractions suffice for the sequential path.
    return conditional_subtract(T, N, max_iterations=3)


# ---------------------------------------------------------------------
#  Parallel LogJumps reduction
# ---------------------------------------------------------------------

def parallel_reduce(C: int, N: int, n: int, rho: list[int],
                    mu_r: int, rem: int, rem_word: int,
                    rem_mu_r: int) -> int:
    """
    Perform the *parallel* LogJumps reduction of C modulo N.

    The low (n-1) limbs are multiplied by the reversed rho vector
    (a dot-product that can be computed in parallel), then added
    to the high limb(s).
    """
    c_limbs = int_to_limbs(C, WORD_BITS)

    # Split into low limbs and high part
    c_lo = c_limbs[:n - 1]                          # low n-1 limbs
    c_hi = limbs_to_int(c_limbs[n - 1:], WORD_BITS) # remaining high limbs
    rho_rev = rho[:0:-1]                            # rho[n-1], rho[n-2], ..., rho[1]

    # Parallel dot-product + high part
    T = int(numpy.dot(c_lo, rho_rev)) + c_hi

    # Final Montgomery reduction step
    if rem != 0:
        T = montgomery_reduce(T, N, rem_mu_r, rem)
    else:
        T = montgomery_reduce(T, N, mu_r, WORD_BITS)

    # The parallel path may need up to (n + rem) conditional subtractions.
    return conditional_subtract(T, N, max_iterations=n + rem)

# ---------------------------------------------------------------------
#  Parallel LogJumps reduction with conditional subtraction tree
# ---------------------------------------------------------------------

def parallel_tree_reduce(C: int, N: int, n: int, rho: list[int],
                    mu_r: int, rem: int, rem_word: int,
                    rem_mu_r: int) -> int:
    """
    Perform the *parallel* LogJumps reduction of C modulo N.

    The low (n-1) limbs are multiplied by the reversed rho vector
    (a dot-product that can be computed in parallel), then added
    to the high limb(s).
    """
    c_limbs = int_to_limbs(C, WORD_BITS)

    # Split into low limbs and high part
    c_lo = c_limbs[:n - 1]                          # low n-1 limbs
    c_hi = limbs_to_int(c_limbs[n - 1:], WORD_BITS) # remaining high limbs
    rho_rev = rho[:0:-1]                            # rho[n-1], rho[n-2], ..., rho[1]

    # Parallel dot-product + high part
    T = int(numpy.dot(c_lo, rho_rev)) + c_hi

    # Conditional subtraction tree
    T = conditional_subtract(T, N*(1<<WORD_BITS), max_iterations=n + rem)

    # Final Montgomery reduction step
    if rem != 0:
        T = montgomery_reduce(T, N, rem_mu_r, rem)
    else:
        T = montgomery_reduce(T, N, mu_r, WORD_BITS)

    # The parallel tree path may need up to 1 conditional subtractions.
    return conditional_subtract(T, N, max_iterations=1)


# ---------------------------------------------------------------------
#  Parallel LogJumps reduction with FUSED Montgomery step
# ---------------------------------------------------------------------

def parallel_tree_m_reduce(C: int, N: int, n: int, rho: list[int],
                           mu_r: int, rem: int, rem_word: int,
                           rem_mu_r: int) -> int:
    """
    Fused parallel-tree LogJumps reduction.

    Key optimisation over parallel_tree_reduce:
      The Montgomery quotient  m = (T mod W) * mu  mod W  depends only
      on the low WORD_BITS of T.  Because the modacc tree reduces
      modulo q*W (a multiple of W), the low bits are invariant:

          raw_sum mod W  ==  T_acc mod W

      Therefore m (and the expensive m*q product) can be computed from
      the *raw* dot-product sum, in parallel with the modacc tree,
      instead of waiting for the tree to finish.

    Pipeline model (parallel paths marked ||):
      dot_mul  --+--  modacc_tree  ------------------+
                 |                                   +-- add + shift -- final sub
                 +--  low_add -- m_val -- m*q mul  --+

    Latency: max(modacc_tree, 1 + m*q_mul) + final_stages
    (versus: modacc_tree + m*q_mul + final_stages  in the original)
    """
    c_limbs = int_to_limbs(C, WORD_BITS)

    # Split into low limbs and high part
    c_lo = c_limbs[:n - 1]
    c_hi = limbs_to_int(c_limbs[n - 1:], WORD_BITS)
    rho_rev = rho[:0:-1]

    # Raw dot-product sum (before any modular reduction)
    raw_sum = int(numpy.dot(c_lo, rho_rev)) + c_hi

    # =================================================================
    # Path A  (cheap, fast):  Montgomery quotient from low bits
    #
    #   raw_sum mod 2^shift  is unchanged by subtracting multiples
    #   of q*W (since q*W is a multiple of 2^shift for shift <= WORD_BITS),
    #   so we can read it off immediately without waiting for the
    #   modacc tree.  This feeds the m*q multiplier early.
    # =================================================================
    if rem != 0:
        shift    = rem
        raw_lo   = raw_sum % rem_word
        m_val    = (raw_lo * rem_mu_r) % rem_word
        m_q      = m_val * N
    else:
        shift    = WORD_BITS
        raw_lo   = raw_sum % WORD
        m_val    = (raw_lo * mu_r) % WORD
        m_q      = m_val * N

    # =================================================================
    # Path B  (wide, slow):  Modular accumulation tree
    #
    #   Reduces raw_sum modulo q*W via the conditional-subtraction tree.
    #   Always uses q*W (not q*rem_word) - the modacc modulus must be
    #   a multiple of W so that the low-bit invariance holds for both
    #   the rem and non-rem cases.
    #   Runs in parallel with Path A.
    # =================================================================
    T_acc = conditional_subtract(raw_sum, N * WORD,
                                 max_iterations=n + rem)

    # =================================================================
    # Join:  combine both paths
    #
    #   T' = (T_acc + m*q) >> shift
    #
    #   This is the standard Montgomery identity - the low `shift` bits
    #   of (T_acc + m*q) are guaranteed to be zero.
    # =================================================================
    T_prime = (T_acc + m_q) >> shift

    # Final conditional subtraction (at most 1)
    return conditional_subtract(T_prime, N, max_iterations=1)


# ---------------------------------------------------------------------
#  Parallel LogJumps reduction with RHO-FUSED Montgomery step
# ---------------------------------------------------------------------

def parallel_tree_ro_reduce(C: int, N: int, n: int, rho: list[int],
                            mu_r: int, rem: int, rem_word: int,
                            rem_mu_r: int) -> int:
    """
    Rho-fused parallel-tree LogJumps reduction.

    Key optimisation over parallel_tree_m_reduce:
      m_val depends only on the low LOGW bits of the dot-product sum.
      Instead of waiting for the LOGW*LOGQ dot-product multipliers to
      finish and then summing their low bits, we push mod 2^W inside:

        m_val = (\sum c_lo[i] * rho[n-1-i] + c_hi) * mu   mod W
              = (\sum c_lo[i] * (rho[n-1-i] * mu mod W)
                 + c_hi_lo * mu)  mod W
              =  \sum c_lo[i] * rho_mu[n-1-i]  +  c_hi_lo * mu   mod W

      where  rho_mu[i] = rho[i] * mu  mod W  is a precomputed LOGW-bit
      constant.  Every term  c_lo[i] * rho_mu[j]  is a LOGW * LOGW
      truncated multiply on the *raw input limbs* - available at cycle 0,
      with no dependence on the expensive dot-product multipliers.

    Pipeline model:
      c_lo --+-- dot_mul [DOT_LAT] -- modacc_tree [ACC_LAT] ---------+
             |                                                       +-- join
             +-- rho_mu_mul [~1 cyc] -- m*q mul [MR_LAT] ------------+

    Latency: max(DOT_LAT + ACC_LAT,  1 + MR_LAT) + final_stages
           ~= DOT_LAT + ACC_LAT + final_stages   (m*q path fully hidden)
    """
    c_limbs = int_to_limbs(C, WORD_BITS)

    # Split into low limbs and high part
    c_lo = c_limbs[:n - 1]
    c_hi = limbs_to_int(c_limbs[n - 1:], WORD_BITS)
    rho_rev = rho[:0:-1]

    # Full dot-product (feeds both modacc tree and correctness check)
    raw_sum = int(numpy.dot(c_lo, rho_rev)) + c_hi

    # =================================================================
    # Path A  (tiny, immediate from inputs):  Montgomery quotient
    #
    #   Precomputed constants:  rho_mu[k] = rho_rev[k] * mu  mod W
    #   Each c_lo[i] * rho_mu[i] is a LOGW * LOGW truncated multiply
    #   on raw input limbs - no dependence on the dot-product results.
    #   The narrow mod-W sum of ~n terms takes ~1 clock cycle.
    # =================================================================
    if rem != 0:
        shift    = rem
        mu_used  = rem_mu_r
        mod_mask = rem_word
    else:
        shift    = WORD_BITS
        mu_used  = mu_r
        mod_mask = WORD

    # Precomputed LOGW-bit constants (would be ROM / parameters in RTL)
    rho_mu = [(r * mu_used) % mod_mask for r in rho_rev]

    # LOGW * LOGW truncated multiply per limb, then narrow sum mod W
    # All inputs are available at cycle 0 - no pipeline dependency.
    m_val = sum(c * rm for c, rm in zip(c_lo, rho_mu))
    m_val = (m_val + (c_hi % mod_mask) * mu_used) % mod_mask

    # Large multiply: m_val * N  (LOGW * LOGQ, starts at cycle ~1)
    m_q = m_val * N

    # =================================================================
    # Path B  (wide, slow):  Modular accumulation tree  (unchanged)
    # =================================================================
    T_acc = conditional_subtract(raw_sum, N * WORD,
                                 max_iterations=n + rem)

    # =================================================================
    # Join:  T' = (T_acc + m*q) >> shift
    # =================================================================
    T_prime = (T_acc + m_q) >> shift

    # Final conditional subtraction (at most 1)
    return conditional_subtract(T_prime, N, max_iterations=1)


# ---------------------------------------------------------------------
#  Main test loop
# ---------------------------------------------------------------------

def main() -> None:
    if not RANDOMIZE:
        random.seed(0)
        sympy.core.random.seed(0)

    error_seq = 0
    error_par = 0
    error_tre = 0
    error_mre = 0
    error_rre = 0

    for _ in tqdm(range(NUM_TESTS)):
        # Generate a random prime N of the target bit-length
        N = sympy.randprime(1 << (N_TARGET_BITS - 1), 1 << N_TARGET_BITS)
        N_bits = N.bit_length()
        n = math.ceil(N_bits / WORD_BITS)  # number of limbs

        # R = 2^{N_bits}  (Montgomery radix, matched to modulus bit-length)
        R = 1 << N_bits

        # Precompute rho[i] = (2^{word_bits})^{-i} mod N
        rho = [pow(WORD, -i, N) for i in range(n)]

        # Handle the case where N_bits is not a multiple of word_bits:
        # the most-significant limb is shorter.
        rem = N_bits - (N_bits // WORD_BITS) * WORD_BITS
        rem_word = 1 << rem
        rem_mu_r = pow(-N, -1, rem_word) if rem != 0 else 0

        # Standard Montgomery parameter: -N^{-1} mod 2^{word_bits}
        mu_r = pow(-N, -1, WORD)
        print(f'mu_r={mu_r:b}')

        C = random.randint(0, (N - 1) * (R - 1))
        C = (N-1)*(R-1)

        # --- Sequential reduction ---
        T_seq = sequential_reduce(C, N, n, rho, mu_r, rem, rem_word, rem_mu_r)

        # --- Parallel reduction ---
        T_par = parallel_reduce(C, N, n, rho, mu_r, rem, rem_word, rem_mu_r)

        # --- Parallel tree reduction ---
        T_tre = parallel_tree_reduce(C, N, n, rho, mu_r, rem, rem_word, rem_mu_r)

        # --- Parallel tree reduction with fused Montgomery ---
        T_mre = parallel_tree_m_reduce(C, N, n, rho, mu_r, rem, rem_word, rem_mu_r)

        # --- Parallel tree reduction with rho-fused Montgomery ---
        T_rre = parallel_tree_ro_reduce(C, N, n, rho, mu_r, rem, rem_word, rem_mu_r)

        # --- Expected result: C * R^{-1} mod N ---
        expected = (C * pow(R, -1, N)) % N

        if VERBOSE:
            print(f"N={hex(N)}  n={n}  rem={rem}")
            print(f"  exp: {hex(expected)}")
            print(f"  seq: {hex(T_seq)}")
            print(f"  par: {hex(T_par)}")
            print(f"  tre: {hex(T_tre)}")
            print(f"  mre: {hex(T_mre)}")
            print(f"  rre: {hex(T_rre)}")

        if expected != T_seq:
            error_seq += 1
            print(f"seq MISMATCH: {hex(expected)} != {hex(T_seq)}")
        if expected != T_par:
            error_par += 1
            print(f"par MISMATCH: {hex(expected)} != {hex(T_par)}")
        if expected != T_tre:
            error_tre += 1
            print(f"tre MISMATCH: {hex(expected)} != {hex(T_tre)}")
        if expected != T_mre:
            error_mre += 1
            print(f"mre MISMATCH: {hex(expected)} != {hex(T_mre)}")
        if expected != T_rre:
            error_rre += 1
            print(f"rre MISMATCH: {hex(expected)} != {hex(T_rre)}")

    print(f"error_seq = {error_seq}")
    print(f"error_par = {error_par}")
    print(f"error_tre = {error_tre}")
    print(f"error_mre = {error_mre}")
    print(f"error_rre = {error_rre}")


if __name__ == "__main__":
    main()