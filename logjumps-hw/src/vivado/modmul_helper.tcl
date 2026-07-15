# --------------------------------------------------------------
# modmul_helper.tcl, PRE_HOOK for modmul builds
#
# FIXED_Q controls whether a compile-time fixed modulus is used:
#
#   FIXED_Q=1, Fixed-modulus mode (prime baked into the design)
#     Requires one of:
#       LOGQ_PRIME , bit-width -> prime = prevprime(2^LOGQ_PRIME)
#       Q_EFF_VAL  , explicit prime as hex (no 0x prefix)
#     Produces Q_VALUE, MU_VALUE, RHO_VALUES, RHO_MU_VALUES generics.
#
#   FIXED_Q=0 (default, or omitted), Run-time generic mode
#     Requires:
#       LOGQ_PRIME , bit-width of Q (no prime is generated)
#     Only produces FIXED_Q=0 and LOGQ generics; the RTL handles
#     Q, MU, RHO, etc. as run-time inputs.
#
#   Note: Q_EFF_VAL implies FIXED_Q=1 automatically.
#         FIXED_Q only needs to be set explicitly with LOGQ_PRIME.
#
# Common parameters:
#   TUNE        , pipeline preset: 250 (17cc, min-latency @250MHz)
#                   or 400 (30cc, high-Fmax @400MHz).  See the preset
#                   table at the bottom of this file.  (default: none)
#   WORD        , limb width in bits (= LOGW)       (default: 17)
#   COND_SUB_OPT, if 1, auto-compute ACC_MAX_COND_SUB (default: off)
#                   mutually exclusive with ACC_MAX_COND_SUB
#                   only valid when FIXED_Q=1
#
# Produces when FIXED_Q=1 (appended to generic_args):
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
# Produces when FIXED_Q=0 (appended to generic_args):
#   FIXED_Q        = 0
#   LOGQ           = LOGQ_PRIME      (bit-width of Q)
#
# Derived internally (not injected, the RTL computes them):
#   LOGR           = LOGW * ceil(LOGQ / LOGW)
#   N_LIMBS        = LOGR / LOGW
#   N_MUL          = N_LIMBS - 1
#
# Usage:
#   # Run-time generic, 381-bit Q (default FIXED_Q=0)
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       LOGQ_PRIME=381 FREQ=400 ...
#
#   # Fixed prime, prevprime(2^381), auto cond-sub
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       FIXED_Q=1 LOGQ_PRIME=381 COND_SUB_OPT=1 FREQ=400 ...
#
#   # Fixed prime, manual cond-sub override
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       FIXED_Q=1 LOGQ_PRIME=381 ACC_MAX_COND_SUB=12 ...
#
#   # Fixed prime, explicit BLS12-381 prime, auto cond-sub
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       Q_EFF_VAL=1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf \
#                 6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab \
#       COND_SUB_OPT=1 ...
#
#   # Fixed prime, custom limb width
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       FIXED_Q=1 LOGQ_PRIME=255 WORD=16 COND_SUB_OPT=1 ...
#
#   # Karatsuba big multiply + fixed modulus
#   ./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
#       FIXED_Q=1 LOGQ_PRIME=381 COND_SUB_OPT=1 FREQ=455 \
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
set fixed_q      [hook_pop FIXED_Q 0]
set logq_prime   [hook_pop LOGQ_PRIME ""]
set q_eff_val    [hook_pop Q_EFF_VAL  ""]
set word         [hook_pop WORD 17]
set cond_sub_opt [hook_pop COND_SUB_OPT ""]
set tune         [hook_pop TUNE ""]

# -- Validate parameters -------------------------------------
if {$logq_prime ne "" && $q_eff_val ne ""} {
    puts "ERROR: modmul_helper.tcl: LOGQ_PRIME and Q_EFF_VAL are mutually exclusive."
    exit 1
}
if {$logq_prime eq "" && $q_eff_val eq ""} {
    puts "ERROR: modmul_helper.tcl requires either LOGQ_PRIME=<bits> or Q_EFF_VAL=<hex>."
    exit 1
}

# Q_EFF_VAL implies FIXED_Q=1, the user is supplying a concrete prime.
if {$q_eff_val ne ""} {
    set fixed_q 1
}

if {!$fixed_q && $cond_sub_opt ne "" && $cond_sub_opt} {
    puts "ERROR: modmul_helper.tcl: COND_SUB_OPT requires FIXED_Q=1 (needs prime to compute ACC_MAX_COND_SUB)."
    exit 1
}

# -- Resolve LOGQ_PRIME (needed for both modes) --------------
if {$logq_prime eq ""} {
    # Q_EFF_VAL given (fixed_q forced to 1 above)
    set prime [hex2int $q_eff_val]

    # Compute bit-length = floor(log2(prime)) + 1
    set tmp $prime
    set logq_prime 0
    while {$tmp > 0} {
        incr logq_prime
        set tmp [expr {$tmp >> 1}]
    }
}

set logq $logq_prime

# ==============================================================
# Branch: FIXED_Q=1 (fixed-modulus) vs FIXED_Q=0 (run-time generic)
# ==============================================================
if {$fixed_q} {
    # -- Fixed-modulus path --------------------------------------
    if {$q_eff_val ne ""} {
        # Mode B: explicit prime as hex (prime already set above)
        puts "  Mode        = fixed, explicit Q_EFF_VAL ([string length $q_eff_val] hex digits)"
    } else {
        # Mode A: generate prevprime(2^LOGQ_PRIME)
        set prime [prevprime [pow 2 $logq_prime]]
        puts "  Mode        = fixed, prevprime(2^$logq_prime)"
    }

    # -- Derived geometry -----------------------------------------
    set logr    [expr {$word * (($logq + $word - 1) / $word)}]
    set n_limbs [expr {$logr / $word}]
    set n_mul   [expr {$n_limbs - 1}]
    set W       [pow 2 $word]

    set prime_hex [int2hex $prime]
    set q_hex     [int2hex $prime [expr {($logq + 3) / 4}]]

    puts "  FIXED_Q     = 1"
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

} else {
    # -- Run-time generic path ------------------------------------
    # Only LOGQ is needed; the RTL accepts Q, MU, RHO, etc. as
    # run-time inputs (ports or configuration registers).
    puts "  Mode        = run-time generic (FIXED_Q=0)"
    puts "  LOGQ_PRIME  = $logq_prime"
    puts "  LOGQ        = $logq"

    lappend generic_args FIXED_Q=0
    lappend generic_args LOGQ=$logq
}

# ==============================================================
# Pipeline tuning presets  (TUNE=<250|400>)
# ==============================================================
# The modmul micro-architecture exposes a family of FF_*/pipeline
# parameters that trade latency (clock cycles) against Fmax.
#
#   TUNE=250, minimum-latency configuration that closes 250 MHz.
#              Light pipelining (most FF_* stages off, K_PIPE_DSP=1,
#              long register periods).  ~17 cycles for BLS12-381 at
#              LOGW=17 -> the "17cc" design points.
#
#   TUNE=400, high-Fmax configuration that closes 400 MHz.
#              Deep pipelining (all FF_* stages on, K_PIPE_DSP=3,
#              short register periods).  ~30 cycles for BLS12-381/377.
#
#
# Omit TUNE to leave the raw RTL defaults untouched.  Any pipeline
# parameter passed explicitly on the command line wins over the preset.
#
#   parameter          TUNE=250 (17cc)   TUNE=400 (30cc)
#   -----------------  ---------------   ---------------
#   MUL_K_PIPE_DSP          1                   3
#   MUL_K_PIPE_MID          0                   1
#   MUL_FF_ADD              0                   1
#   MUL_FF_CPA              0                   1
#   MUL_FF_CSA              0                   1
#   MUL_FF_CSA_MID          0                   1
#   MUL_FF_DIAG             0                   1
#   MUL_FF_OUT              0                   1
#   LJ_FF_IN                0                   1
#   LJ_FF_ADD               0                   1
#   LJ_FF_CSA_MID           0                   1
#   LJ_FF_JOIN_ADD          0                   1
#   LJ_FF_MR_POST           0                   1
#   LJ_MT_REG_PERIOD        4                   2
#   ACC_AT_REG_PERIOD       5                   3
#   ACC_AT_FF_ADD           0                   1
# --------------------------------------------------------------
if {$tune ne ""} {
    set preset_250 {
        MUL_K_PIPE_DSP    1   MUL_K_PIPE_MID    0
        MUL_FF_ADD        0   MUL_FF_CPA        0
        MUL_FF_CSA        0   MUL_FF_CSA_MID    0
        MUL_FF_DIAG       0   MUL_FF_OUT        0
        LJ_FF_IN          0   LJ_FF_ADD         0
        LJ_FF_CSA_MID     0   LJ_FF_JOIN_ADD    0
        LJ_FF_MR_POST     0   LJ_MT_REG_PERIOD  4
        ACC_AT_REG_PERIOD 5   ACC_AT_FF_ADD     0
    }
    set preset_400 {
        MUL_K_PIPE_DSP    3   MUL_K_PIPE_MID    1
        MUL_FF_ADD        1   MUL_FF_CPA        1
        MUL_FF_CSA        1   MUL_FF_CSA_MID    1
        MUL_FF_DIAG       1   MUL_FF_OUT        1
        LJ_FF_IN          1   LJ_FF_ADD         1
        LJ_FF_CSA_MID     1   LJ_FF_JOIN_ADD    1
        LJ_FF_MR_POST     1   LJ_MT_REG_PERIOD  2
        ACC_AT_REG_PERIOD 3   ACC_AT_FF_ADD     1
    }

    switch -exact -- $tune {
        250     { set preset $preset_250 }
        400     { set preset $preset_400 }
        default {
            puts "ERROR: modmul_helper.tcl: TUNE must be 250 or 400 (got '$tune')."
            exit 1
        }
    }

    puts ""
    puts "  Pipeline preset : TUNE=$tune"
    foreach {k v} $preset {
        set have 0
        foreach g $generic_args {
            if {[regexp "^${k}=" $g]} { set have 1; break }
        }
        if {$have} {
            puts "    $k = (user override kept)"
        } else {
            lappend generic_args $k=$v
            puts "    $k = $v"
        }
    }
}

# ==============================================================
# OOC top wrapper for fixed-Q builds  (FIXED_Q=1 only)
# ==============================================================
# When FIXED_Q=1 the modulus and its derived constants (q, rho, mu) are
# compile-time parameters, yet modmul still DECLARES the run-time
# q/rho/mu input ports. They are simply left unconnected internally
# (assign ..._aligned = <constant>).  In out-of-context synthesis those
# unused ports survive as top-level I/O terminals.
#
# So, ONLY in fixed-Q mode, we generate a thin wrapper modmul_ooc on
# the fly and make it the synthesis top. It forwards every parameter to
# modmul but exposes only clk/A/B/D and ties q/rho/mu to 0.  The logic
# measured is identical.
if {$fixed_q} {
    # Names already declared explicitly in the wrapper preamble; do not
    # re-emit them from generic_args.
    set _skip {LOGQ LOGW LOGR Q_VALUE MU_VALUE RHO_VALUES RHO_MU_VALUES}

    # Parameter declarations. Order matters: the packed-constant widths
    # depend on LOGQ/LOGW/LOGR, so those come first. Widths mirror
    # modmul.sv exactly so no truncation can occur.
    set _decls [list]
    lappend _decls "    parameter int LOGQ = $logq"
    lappend _decls "    parameter int LOGW = $word"
    lappend _decls "    parameter int LOGR = LOGW*((LOGQ+LOGW-1)/LOGW)"
    lappend _decls "    parameter bit \[LOGQ-1:0\]                  Q_VALUE       = '0"
    lappend _decls "    parameter bit \[LOGW-1:0\]                  MU_VALUE      = '0"
    lappend _decls "    parameter bit \[(LOGR/LOGW-1)*LOGQ-1:0\]    RHO_VALUES    = '0"
    lappend _decls "    parameter bit \[(LOGR/LOGW-1)*LOGW-1:0\]    RHO_MU_VALUES = '0"

    # Forwarded #(...) connections to the inner modmul instance.
    set _conns [list ".LOGQ(LOGQ)" ".LOGW(LOGW)" \
                     ".Q_VALUE(Q_VALUE)" ".MU_VALUE(MU_VALUE)" \
                     ".RHO_VALUES(RHO_VALUES)" ".RHO_MU_VALUES(RHO_MU_VALUES)"]

    # Everything else in generic_args (FIXED_Q, ACC_MAX_COND_SUB, the
    # pipeline knobs, ...) forwarded generically as int parameters.
    foreach g $generic_args {
        if {![regexp {^(\w+)=(.+)$} $g -> k v]} { continue }
        if {$k in $_skip} { continue }
        lappend _decls "    parameter int $k = $v"
        lappend _conns  ".${k}(${k})"
    }

    set _w  "// Auto-generated OOC top wrapper (FIXED_Q=1), generated on the fly.\n"
    append _w "module modmul_ooc #(\n"
    append _w [join $_decls ",\n"]
    append _w "\n) (\n"
    append _w "    input  logic             clk,\n"
    append _w "    input  logic \[LOGQ-1:0\] A,\n"
    append _w "    input  logic \[LOGQ-1:0\] B,\n"
    append _w "    output logic \[LOGQ-1:0\] D\n"
    append _w ");\n"
    append _w "    modmul #(\n        "
    append _w [join $_conns ",\n        "]
    append _w "\n    ) u_modmul (\n"
    append _w "        .clk (clk),\n"
    append _w "        .A   (A),\n"
    append _w "        .B   (B),\n"
    append _w "        .q   ('0),\n"
    append _w "        .rho ('0),\n"
    append _w "        .mu  ('0),\n"
    append _w "        .D   (D)\n"
    append _w "    );\n"
    append _w "endmodule\n"

    # Hand off to _build_impl.tcl (writes into build_dir, reads after .f).
    set TOP_WRAPPER_SRC $_w
    set TOP             modmul_ooc

    puts ""
    puts "  OOC wrapper : modmul_ooc as top (q/rho/mu tied off);\
 [llength $_conns] params forwarded to modmul"
}