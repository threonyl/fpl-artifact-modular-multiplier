#!/usr/bin/env python3
"""
Generate Montgomery modular multiplication test vectors for BLS12-381.

    D = A * B * R^{-1} mod q

where q  = BLS12-381 prime,
      R  = 2^LOGR,
      LOGR = LOGW * ceil(LOGQ / LOGW).

Output: one line per test case,  A B D  (hex, no 0x prefix).
"""

import random, math

Q = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab
LOGQ = Q.bit_length()                          # 381
LOGW = 17                                       # typical DSP word width
N    = math.ceil(LOGQ / LOGW)                   # 23 limbs
LOGR = LOGW * N                                 # 391
R    = 1 << LOGR
RINV = pow(R, -1, Q)

def golden(A, B):
    return A * B % Q * RINV % Q                 # (A*B * R^{-1}) mod q

rng = random.Random(0xB1512_381)
R_mod_q = R % Q

# ---------- deterministic corner cases + random vectors ----------
vectors = []

# corners
vectors.append((0,       0))
vectors.append((1,       1))
vectors.append((0,       Q - 1))
vectors.append((Q - 1,   0))
vectors.append((Q - 1,   Q - 1))
vectors.append((R_mod_q, R_mod_q))              # identity^2 = identity
vectors.append((R_mod_q, 1))                    # identity * 1 = 1
vectors.append((1,       R_mod_q))
vectors.append((Q - 1,   1))
vectors.append((Q - 1,   R_mod_q))
vectors.append((2,       (Q + 1) // 2))         # 2 * inv(2)
vectors.append(((Q - 1) // 2, (Q - 1) // 3))

# random
for _ in range(488):
    vectors.append((rng.randint(0, Q - 1), rng.randint(0, Q - 1)))

W = LOGQ  # hex width = ceil(LOGQ/4)
HW = (LOGQ + 3) // 4

with open("modmul_bls12_381_vectors.txt", "w") as f:
    # f.write(f"# Montgomery modmul test vectors for BLS12-381\n")
    # f.write(f"# q    = {Q:#0{HW+2}x}\n")
    # f.write(f"# LOGQ = {LOGQ}, LOGW = {LOGW}, LOGR = {LOGR}\n")
    # f.write(f"# R    = 2^{LOGR}\n")
    # f.write(f"# D    = A * B * R^{{-1}} mod q\n")
    # f.write(f"# Format: A B D  (hex, zero-padded to {HW} nibbles)\n")
    # f.write(f"# {len(vectors)} vectors\n")
    for A, B in vectors:
        D = golden(A, B)
        f.write(f"{A:0{HW}x} {B:0{HW}x} {D:0{HW}x}\n")

print(f"Wrote {len(vectors)} vectors to modmul_bls12_381_vectors.txt")
print(f"  LOGQ={LOGQ}  LOGW={LOGW}  N={N}  LOGR={LOGR}")