# --------------------------------------------------------------
# modmul_helper.tcl, PRE_HOOK for modmul builds
#
# Prime selection (exactly one required):
#
#   Mode A, generate prime from bit-width:
#     LOGQ_PRIME , bit-width of the prime
#     -> prime = prevprime(2^LOGQ_PRIME)
#
#   Mode B, use an explicit prime:
#     Q_EFF_VAL  , prime as a hex string (no 0x prefix)
#     -> LOGQ_PRIME is derived from the bit-length
#
# Common parameters:
#   WORD         , limb width in bits (= LOGW)       (default: 17)
#   COND_SUB_OPT , if 1, auto-compute ACC_MAX_COND_SUB (default: off)
#                   mutually exclusive with ACC_MAX_COND_SUB
#
# Produces (appended to generic_args):
#   FIXED_Q        = 1
#   LOGQ           = LOGQ_PRIME      (bit-width of the prime)
#   Q_VALUE        = hex(prime)
#   MU_VALUE       = hex( -prime^{-1} mod 2^{LOGW} )
#   RHO_VALUES     = hex( packed rho[1..n-1], LE, each LOGQ bits )
#                    where rho[i] = (2^{LOGW})^{-i} mod prime
#   RHO_MU_VALUES  = hex( packed rho_mu[0..n-2], LE, each LOGW bits )
#                    where rho_mu[k] = (rho[n-1-k] * mu) mod 2^{LOGW}
#   ACC_MAX_COND_SUB = floor(sum(rho[1..n-1]) / prime) + 1
#                      (only when COND_SUB_OPT=1)
#
# Derived internally (not injected, the RTL computes them):
#   LOGR           = LOGW * ceil(LOGQ / LOGW)
#   N_LIMBS        = LOGR / LOGW
#   N_MUL          = N_LIMBS - 1
#
# Usage:
#   # Mode A, prevprime(2^381), auto cond-sub
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       LOGQ_PRIME=381 COND_SUB_OPT=1 FREQ=400 ...
#
#   # Mode A, manual cond-sub override
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       LOGQ_PRIME=381 ACC_MAX_COND_SUB=12 ...
#
#   # Mode B, explicit BLS12-381 prime, auto cond-sub
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       Q_EFF_VAL=1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf \
#                 6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab \
#       COND_SUB_OPT=1 ...
#
#   # Mode A, custom limb width
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       LOGQ_PRIME=255 WORD=16 COND_SUB_OPT=1 ...
#
#   # Karatsuba big multiply + fixed modulus
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       LOGQ_PRIME=381 COND_SUB_OPT=1 FREQ=455 \
#       MUL_USE_KARATSUBA=1 MUL_K_PIPE_DSP=3 MUL_K_PIPE_MID=1
# --------------------------------------------------------------

# -- Load primes library --------------------------------------
# $proj_dir is set by _build_impl.tcl (src/vivado/) and is
# reliable across Vivado's nested source chain.
source [file join $proj_dir ../../lib/nthtcl/src/tcl/primes.tcl]

# -- Bignum hex helpers ---------------------------------------
# Vivado's Tcl truncates 0x... literals and format %x to 64 bits.
# These work digit-by-digit through Tcl's bignum expr instead.

proc hex2int {h} {
    set n 0
    foreach c [split $h ""] {
        scan $c %x d
        set n [expr {$n * 16 + $d}]
    }
    return $n
}

proc int2hex {n {pad 0}} {
    if {$n == 0} { return [string repeat 0 [expr {max($pad, 1)}]] }
    set h ""
    set tmp $n
    while {$tmp > 0} {
        set h [format %x [expr {$tmp & 15}]]$h
        set tmp [expr {$tmp >> 4}]
    }
    set p [expr {$pad - [string length $h]}]
    if {$p > 0} { set h "[string repeat 0 $p]$h" }
    return $h
}

# -- Consume hook-only parameters -----------------------------
set logq_prime   [hook_pop LOGQ_PRIME ""]
set q_eff_val    [hook_pop Q_EFF_VAL  ""]
set word         [hook_pop WORD 17]
set cond_sub_opt [hook_pop COND_SUB_OPT ""]

# -- Validate: exactly one mode -------------------------------
if {$logq_prime ne "" && $q_eff_val ne ""} {
    puts "ERROR: modmul_helper.tcl: LOGQ_PRIME and Q_EFF_VAL are mutually exclusive."
    exit 1
}
if {$logq_prime eq "" && $q_eff_val eq ""} {
    puts "ERROR: modmul_helper.tcl requires either LOGQ_PRIME=<bits> or Q_EFF_VAL=<hex>."
    exit 1
}

# -- Resolve prime and LOGQ_PRIME -----------------------------
if {$logq_prime ne ""} {
    # Mode A: generate prevprime(2^LOGQ_PRIME)
    set prime [prevprime [pow 2 $logq_prime]]
    puts "  Mode        = prevprime(2^$logq_prime)"
} else {
    # Mode B: explicit prime as hex
    set prime [hex2int $q_eff_val]

    # Compute bit-length = floor(log2(prime)) + 1
    set tmp $prime
    set logq_prime 0
    while {$tmp > 0} {
        incr logq_prime
        set tmp [expr {$tmp >> 1}]
    }
    puts "  Mode        = explicit Q_EFF_VAL ([string length $q_eff_val] hex digits)"
}

# -- Derived geometry -----------------------------------------
set logq    $logq_prime
set logr    [expr {$word * (($logq + $word - 1) / $word)}]
set n_limbs [expr {$logr / $word}]
set n_mul   [expr {$n_limbs - 1}]
set W       [pow 2 $word]

set prime_hex [int2hex $prime]
set q_hex     [int2hex $prime [expr {($logq + 3) / 4}]]

puts "  LOGQ_PRIME  = $logq_prime"
puts "  WORD (LOGW) = $word"
puts "  prime       = $prime_hex  ([string length $prime_hex] hex digits)"
puts "  LOGQ        = $logq"
puts "  LOGR        = $logr"
puts "  N_LIMBS     = $n_limbs"
puts "  N_MUL       = $n_mul"

# -- Compute mu = -prime^{-1} mod 2^{LOGW} -------------------
set mu [pow [expr {-$prime}] -1 $W]
set mu_hex [int2hex $mu [expr {($word + 3) / 4}]]
puts "  MU_VALUE    = $mu_hex"

# -- Compute rho[i] = (2^{LOGW})^{-i} mod prime -------------
# rho[0] = 1, rho[1] = W^{-1} mod q, ..., rho[n-1] = W^{-(n-1)} mod q
set rho [list]
for {set i 0} {$i < $n_limbs} {incr i} {
    lappend rho [pow $W [expr {-$i}] $prime]
}

# -- Pack RHO_VALUES: rho[1..n-1], LE, each LOGQ bits --------
# Bit layout: rho[1] @ bits [LOGQ-1:0],
#             rho[2] @ bits [2*LOGQ-1:LOGQ], ...
set rho_packed 0
set rho_mask [expr {(1 << $logq) - 1}]
for {set k 0} {$k < $n_mul} {incr k} {
    set rho_k [lindex $rho [expr {$k + 1}]]
    set rho_packed [expr {$rho_packed | (($rho_k & $rho_mask) << ($k * $logq))}]
}
set rho_width [expr {$n_mul * $logq}]
set rho_hex [int2hex $rho_packed [expr {($rho_width + 3) / 4}]]
puts "  RHO_VALUES  = [string range $rho_hex 0 63]... ([string length $rho_hex] hex digits)"

# -- Compute and pack RHO_MU_VALUES --------------------------
# rho_mu[k] = (rho[n-1-k] * mu) mod 2^{LOGW}  for k = 0..n_mul-1
#
# Bit layout: rho_mu[0] @ bits [LOGW-1:0],
#             rho_mu[1] @ bits [2*LOGW-1:LOGW], ...
set rm_packed 0
set w_mask [expr {$W - 1}]
for {set k 0} {$k < $n_mul} {incr k} {
    set rho_idx [expr {$n_limbs - 1 - $k}]
    set rho_mu_k [expr {([lindex $rho $rho_idx] * $mu) & $w_mask}]
    set rm_packed [expr {$rm_packed | ($rho_mu_k << ($k * $word))}]
}
set rm_width [expr {$n_mul * $word}]
set rm_hex [int2hex $rm_packed [expr {($rm_width + 3) / 4}]]
puts "  RHO_MU_VALUES = [string range $rm_hex 0 63]... ([string length $rm_hex] hex digits)"

# -- Optional: auto-compute ACC_MAX_COND_SUB ------------------
# ACC_MAX_COND_SUB = floor( sum_{i=1}^{n-1} rho[i] / prime ) + 1
#
# This is the tightest safe upper bound for the binary-search
# conditional subtraction chain in the modacc tree.
if {$cond_sub_opt ne "" && $cond_sub_opt} {
    # Conflict check: pop ACC_MAX_COND_SUB, if present, the user
    # passed both, which is an error.
    set _mcs_existing [hook_pop ACC_MAX_COND_SUB ""]
    if {$_mcs_existing ne ""} {
        puts "ERROR: modmul_helper.tcl: COND_SUB_OPT and ACC_MAX_COND_SUB are mutually exclusive."
        exit 1
    }

    set rho_sum 0
    for {set i 1} {$i < $n_limbs} {incr i} {
        set rho_sum [expr {$rho_sum + [lindex $rho $i]}]
    }

    # floor(rho_sum / prime) + 1
    set max_cond_sub [expr {$rho_sum / $prime + 1}]

    puts "  COND_SUB    = auto (n_limbs=$n_limbs, floor(sum_rho/q)=[expr {$rho_sum / $prime}])"
    puts "  ACC_MAX_COND_SUB = $max_cond_sub"

    lappend generic_args ACC_MAX_COND_SUB=$max_cond_sub
}

# -- Inject into generic_args ---------------------------------
lappend generic_args FIXED_Q=1
lappend generic_args LOGQ=$logq
lappend generic_args Q_VALUE=$q_hex
lappend generic_args MU_VALUE=$mu_hex
lappend generic_args RHO_VALUES=$rho_hex
lappend generic_args RHO_MU_VALUES=$rm_hex