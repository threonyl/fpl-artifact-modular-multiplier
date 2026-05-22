# --------------------------------------------------------------
# modacc_helper.tcl, PRE_HOOK for modacc builds
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
#   WORD         , shift / limb width in bits       (default: 17)
#   COND_SUB_OPT , if 1, auto-compute MAX_COND_SUB (default: off)
#                   mutually exclusive with MAX_COND_SUB
#
# Produces (appended to generic_args):
#   FIXED_Q       = 1
#   LOGQ          = LOGQ_PRIME + WORD
#   Q_VALUE       = hex(prime << WORD)
#   MAX_COND_SUB  = floor(sum(rho_i / prime)) + 1    (if COND_SUB_OPT=1)
#       where rho_i = WORD^{-i} mod prime, i = 1 .. N_LIMBS-1
#
# Usage:
#   # Mode A + manual MAX_COND_SUB
#   ./build.sh impl_modacc.f PRE_HOOK=modacc_helper.tcl \
#       LOGQ_PRIME=381 MAX_COND_SUB=12 ...
#
#   # Mode B + auto MAX_COND_SUB
#   ./build.sh impl_modacc.f PRE_HOOK=modacc_helper.tcl \
#       Q_EFF_VAL=1a0111ea...aaab COND_SUB_OPT=1 ...
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
    puts "ERROR: modacc_helper.tcl: LOGQ_PRIME and Q_EFF_VAL are mutually exclusive."
    exit 1
}
if {$logq_prime eq "" && $q_eff_val eq ""} {
    puts "ERROR: modacc_helper.tcl requires either LOGQ_PRIME=<bits> or Q_EFF_VAL=<hex>."
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

# -- Common: shift and format ---------------------------------
set logq [expr {$logq_prime + $word}]
set qval [expr {$prime << $word}]

# Bare hex, no 0x prefix, what synth_design -generic expects
# for wide bit-vector parameters.
set q_hex [int2hex $qval [expr {($logq + 3) / 4}]]

set prime_hex [int2hex $prime]
puts "  LOGQ_PRIME  = $logq_prime"
puts "  WORD        = $word"
puts "  prime       = $prime_hex  ([string length $prime_hex] hex digits)"
puts "  LOGQ        = $logq"
puts "  Q_VALUE     = $q_hex"

# -- Optional: auto-compute MAX_COND_SUB ----------------------
# MAX_COND_SUB = ceil( sum_{i=1}^{N_LIMBS-1} rho_i / prime )
#   where rho_i = WORD^{-i} mod prime
if {$cond_sub_opt ne "" && $cond_sub_opt} {
    # Conflict check: pop MAX_COND_SUB, if present, the user
    # passed both, which is an error.
    set _mcs_existing [hook_pop MAX_COND_SUB ""]
    if {$_mcs_existing ne ""} {
        puts "ERROR: modacc_helper.tcl: COND_SUB_OPT and MAX_COND_SUB are mutually exclusive."
        exit 1
    }

    set w_val   [pow 2 $word]
    set n_limbs [expr {($logq_prime + $word - 1) / $word}]

    # sum of rho_i = WORD^{-i} mod prime, for i = 1 .. n_limbs-1
    set rho_sum 0
    for {set i 1} {$i < $n_limbs} {incr i} {
        set rho_sum [expr {$rho_sum + [pow $w_val [expr {-$i}] $prime]}]
    }

    # floor(rho_sum / prime) + 1
    set max_cond_sub [expr {$rho_sum / $prime + 1}]

    puts "  COND_SUB    = auto (n_limbs=$n_limbs, floor(sum_rho/N)=[expr {$rho_sum / $prime}])"
    puts "  MAX_COND_SUB= $max_cond_sub"

    lappend generic_args MAX_COND_SUB=$max_cond_sub
}

# -- Inject into generic_args ---------------------------------
lappend generic_args FIXED_Q=1
lappend generic_args LOGQ=$logq
lappend generic_args Q_VALUE=$q_hex