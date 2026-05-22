#!/usr/bin/env tclsh
#
# Tcl port of sympy's isprime / nextprime / prevprime / randprime
#
# isprime uses:
#   - Trial division for small factors (primes up to 47)
#   - Euler pseudoprime shortcut for n < 65077
#   - Deterministic Miller-Rabin with range-specific minimal witness sets for n < 2^64
#   - Strong BPSW (MR base-2 + strong Lucas PRP) for n >= 2^64
#
# nextprime / prevprime use 6k+/-1 wheel stepping, matching sympy.
# randprime matches sympy's algorithm exactly.

proc egcd {a b} {
    set old_r $a; set r $b
    set old_s 1;  set s 0
    set old_t 0;  set t 1

    while {$r != 0} {
        set q [expr {$old_r / $r}]

        set tmp $r
        set r [expr {$old_r - $q * $r}]
        set old_r $tmp

        set tmp $s
        set s [expr {$old_s - $q * $s}]
        set old_s $tmp

        set tmp $t
        set t [expr {$old_t - $q * $t}]
        set old_t $tmp
    }

    return [list $old_r $old_s $old_t]
}

# ---------------------------------------------------------------------
# pow, mirrors Python's pow(base, exp[, mod])
#
#   pow base exp       -> base^exp  (integer exponentiation)
#   pow base exp mod   -> (base^exp) % mod  (modular exponentiation)
#
# Negative exp with mod computes the modular inverse, then raises it
# to |exp|, matching Python's pow(base, -exp, mod) semantics.
# Uses Hensel lifting (Newton iteration) when mod = p^k (k > 1) for
# O(log k) convergence instead of O(k*log p) via egcd.
# Falls back to egcd for non-prime-power moduli.
# Errors if the inverse does not exist (gcd(base, mod) != 1).
# ---------------------------------------------------------------------
proc pow {base exp args} {
    if {[llength $args] > 1} {
        error "pow expected 2 or 3 arguments, got [expr {2 + [llength $args]}]"
    }

    if {[llength $args] == 0} {
        # No mod, plain integer exponentiation
        if {$exp < 0} {
            error "pow: negative exp requires a modulus"
        }
        # Use Tcl's arbitrary-precision integer math
        set result 1
        while {$exp > 0} {
            if {$exp & 1} {
                set result [expr {$result * $base}]
            }
            set exp [expr {$exp >> 1}]
            if {$exp > 0} {
                set base [expr {$base * $base}]
            }
        }
        return $result
    }

    # Modular exponentiation
    set mod [lindex $args 0]
    if {$mod == 0} {
        error "pow: modulus must be nonzero"
    }
    if {$mod == 1 || $mod == -1} {
        return 0
    }

    set absmod [expr {abs($mod)}]

    if {$exp < 0} {
        set base [expr {$base % $absmod}]
        if {$base < 0} {set base [expr {$base + $absmod}]}
        set exp [expr {-$exp}]

        # Try Hensel lifting for prime power moduli (faster for large k)
        set pp [prime_power $absmod]
        if {[llength $pp] == 2} {
            lassign $pp p k
            if {$k > 1} {
                # Hensel lifting: compute inverse mod p, lift to mod p^k
                if {$base % $p == 0} {
                    error "pow: base is not invertible for the given modulus"
                }
                # Inverse mod p via egcd (cheap, p is small or at least < absmod)
                lassign [egcd [expr {$base % $p}] $p] g inv _
                set x [expr {$inv % $p}]
                if {$x < 0} {set x [expr {$x + $p}]}

                # Newton iteration: x_{i+1} = 2*x - base*x^{2} (mod p^(2^(i+1)))
                # Doubles precision each step -> O(log k) iterations
                set cur_mod $p
                while {$cur_mod < $absmod} {
                    set cur_mod [expr {$cur_mod * $cur_mod}]
                    if {$cur_mod > $absmod} {set cur_mod $absmod}
                    set x [expr {(2 * $x - $base * $x * $x) % $cur_mod}]
                    if {$x < 0} {set x [expr {$x + $cur_mod}]}
                }
                set base $x
            } else {
                # Prime modulus (k == 1), egcd is optimal
                lassign [egcd $base $absmod] g inv _
                if {$g != 1} {
                    error "pow: base is not invertible for the given modulus"
                }
                set base [expr {$inv % $absmod}]
                if {$base < 0} {set base [expr {$base + $absmod}]}
            }
        } else {
            # Not a prime power, use egcd
            lassign [egcd $base $absmod] g inv _
            if {$g != 1} {
                error "pow: base is not invertible for the given modulus"
            }
            set base [expr {$inv % $absmod}]
            if {$base < 0} {set base [expr {$base + $absmod}]}
        }
    }

    # Standard binary modular exponentiation
    set result 1
    set base [expr {$base % $absmod}]
    if {$base < 0} {set base [expr {$base + $absmod}]}
    while {$exp > 0} {
        if {$exp & 1} {
            set result [expr {($result * $base) % $absmod}]
        }
        set exp [expr {$exp >> 1}]
        set base [expr {($base * $base) % $absmod}]
    }

    # Python's pow with mod always returns a non-negative result
    if {$result < 0} {set result [expr {$result + $absmod}]}
    return $result
}

# ---------------------------------------------------------------------
# Miller-Rabin test with given list of bases.
# Returns 1 if n is a probable prime to all bases, 0 if composite.
# Handles bases >= n by reducing mod n.
# ---------------------------------------------------------------------
proc mr {n bases} {
    # write n-1 = 2^s * d, d odd
    set d [expr {$n - 1}]
    set s 0
    while {($d & 1) == 0} {
        set d [expr {$d >> 1}]
        incr s
    }
    set nm1 [expr {$n - 1}]
    foreach a $bases {
        set a [expr {$a % $n}]
        if {$a < 0} {set a [expr {$a + $n}]}
        if {$a == 0} continue
        set x [pow $a $d $n]
        if {$x == 1 || $x == $nm1} continue
        set found 0
        for {set r 1} {$r < $s} {incr r} {
            set x [expr {($x * $x) % $n}]
            if {$x == $nm1} {
                set found 1
                break
            }
        }
        if {!$found} {return 0}
    }
    return 1
}

# ---------------------------------------------------------------------
# Jacobi symbol (a/n), n must be positive and odd
# ---------------------------------------------------------------------
proc jacobi {a n} {
    if {$n <= 0 || ($n & 1) == 0} {
        error "jacobi: n must be a positive odd integer"
    }
    set a [expr {$a % $n}]
    if {$a < 0} {set a [expr {$a + $n}]}
    set result 1
    while {$a != 0} {
        # Remove factors of 2 from a
        while {($a & 1) == 0} {
            set a [expr {$a >> 1}]
            set r [expr {$n & 7}]
            if {$r == 3 || $r == 5} {
                set result [expr {-$result}]
            }
        }
        # Swap a and n
        set tmp $a
        set a $n
        set n $tmp
        # Quadratic reciprocity
        if {($a & 3) == 3 && ($n & 3) == 3} {
            set result [expr {-$result}]
        }
        set a [expr {$a % $n}]
    }
    if {$n == 1} {
        return $result
    }
    return 0
}

# ---------------------------------------------------------------------
# Integer square root (floor), used for perfect-square check
# ---------------------------------------------------------------------
proc isqrt {n} {
    if {$n < 0} {error "isqrt of negative"}
    if {$n == 0} {return 0}
    # Newton's method
    set x $n
    set y [expr {($x + 1) >> 1}]
    while {$y < $x} {
        set x $y
        set y [expr {($x + $n / $x) >> 1}]
    }
    return $x
}

# ---------------------------------------------------------------------
# Integer k-th root (floor), generalizes isqrt
# ---------------------------------------------------------------------
proc iroot {n k} {
    if {$k == 1} {return $n}
    if {$k == 2} {return [isqrt $n]}
    if {$n <= 1} {return $n}

    # Bit-length for initial guess
    set bits 0
    set tmp $n
    while {$tmp > 0} {
        incr bits
        set tmp [expr {$tmp >> 1}]
    }
    # Start above the answer: 2^ceil(bits/k)
    set x [expr {1 << (($bits + $k - 1) / $k)}]

    set km1 [expr {$k - 1}]
    while {1} {
        # x^(k-1) via binary exponentiation
        set xkm1 1
        set b $x
        set e $km1
        while {$e > 0} {
            if {$e & 1} {set xkm1 [expr {$xkm1 * $b}]}
            set e [expr {$e >> 1}]
            if {$e > 0} {set b [expr {$b * $b}]}
        }
        # Newton step: x_new = ((k-1)*x + n / x^(k-1)) / k
        set x_new [expr {($km1 * $x + $n / $xkm1) / $k}]
        if {$x_new >= $x} break
        set x $x_new
    }
    return $x
}

# ---------------------------------------------------------------------
# prime_power, check if n = p^k for some prime p, k >= 1
# Returns {p k} if so, {} otherwise.
# ---------------------------------------------------------------------
proc prime_power {n} {
    if {$n < 2} {return {}}

    # Quick check: small prime factors via trial division
    foreach p {2 3 5 7 11 13 17 19 23 29 31 37 41 43 47} {
        if {$n % $p == 0} {
            set k 0
            set m $n
            while {$m % $p == 0} {
                set m [expr {$m / $p}]
                incr k
            }
            if {$m == 1} {return [list $p $k]}
            return {}
        }
    }

    # No small factor; check if n itself is prime
    if {[isprime $n]} {return [list $n 1]}

    # Try each exponent k = 2, 3, ... up to bit-length
    set bits 0
    set tmp $n
    while {$tmp > 0} {incr bits; set tmp [expr {$tmp >> 1}]}

    for {set k 2} {$k <= $bits} {incr k} {
        set r [iroot $n $k]
        if {$r < 2} break
        # Verify r^k == n
        set rk 1
        set b $r
        set e $k
        while {$e > 0} {
            if {$e & 1} {set rk [expr {$rk * $b}]}
            set e [expr {$e >> 1}]
            if {$e > 0} {set b [expr {$b * $b}]}
        }
        if {$rk == $n && [isprime $r]} {
            return [list $r $k]
        }
    }
    return {}
}

# ---------------------------------------------------------------------
# (x / 2) mod n , used in Lucas sequence computation
# ---------------------------------------------------------------------
proc div2mod {x n} {
    if {($x & 1) == 0} {
        return [expr {$x >> 1}]
    } else {
        return [expr {($x + $n) >> 1}]
    }
}

# ---------------------------------------------------------------------
# Strong Lucas Probable Prime test (Selfridge method A for parameter selection)
#
# This is the Lucas half of the BPSW test.
# Finds D in {5, -7, 9, -11, 13, ...} such that Jacobi(D, n) = -1,
# sets P = 1, Q = (1-D)/4, then checks the strong Lucas conditions.
# ---------------------------------------------------------------------
proc is_strong_lucas_prp {n} {
    # --- Perfect square check (Jacobi will never be -1 for a perfect square) ---
    set sq [isqrt $n]
    if {$sq * $sq == $n} {return 0}

    # --- Selfridge method A: find D ---
    set D 5
    while {1} {
        set j [jacobi $D $n]
        if {$j == -1} break
        if {$j == 0} {
            set absD [expr {abs($D)}]
            if {$absD != $n} {return 0}
        }
        # Sequence: 5, -7, 9, -11, 13, -15, ...
        if {$D > 0} {
            set D [expr {-$D - 2}]
        } else {
            set D [expr {-$D + 2}]
        }
    }

    set P 1
    set Q [expr {(1 - $D) / 4}]

    # --- Write n+1 = 2^s * d, d odd ---
    set np1 [expr {$n + 1}]
    set d $np1
    set s 0
    while {($d & 1) == 0} {
        set d [expr {$d >> 1}]
        incr s
    }

    # --- Compute U_d, V_d mod n using the binary chain method ---
    # Start: U_1 = 1, V_1 = P, Q_k = Q
    set U 1
    set V $P
    set Qk $Q

    # Get the binary digits of d (MSB first), skip the leading 1
    set bits {}
    set tmp $d
    while {$tmp > 0} {
        lappend bits [expr {$tmp & 1}]
        set tmp [expr {$tmp >> 1}]
    }
    # bits is LSB-first; reverse to get MSB-first, then drop the leading 1
    set bits [lreverse $bits]
    set bits [lrange $bits 1 end]

    foreach bit $bits {
        # --- Double step: index k -> 2k ---
        # U_{2k} = U_k * V_k mod n
        set U [expr {($U * $V) % $n}]
        # V_{2k} = V_k^2 - 2*Q^k mod n
        set V [expr {($V * $V - 2 * $Qk) % $n}]
        # Q^{2k} = (Q^k)^2 mod n
        set Qk [expr {($Qk * $Qk) % $n}]

        if {$bit} {
            # --- Add step: index k -> k+1 ---
            # U_{k+1} = (P*U_k + V_k) / 2 mod n
            # V_{k+1} = (D*U_k + P*V_k) / 2 mod n
            set Unew [div2mod [expr {$P * $U + $V}] $n]
            set Vnew [div2mod [expr {$D * $U + $P * $V}] $n]
            set U $Unew
            set V $Vnew
            # Q^{k+1} = Q^k * Q mod n
            set Qk [expr {($Qk * $Q) % $n}]
        }
    }

    # Normalize to [0, n)
    set U [expr {$U % $n}]
    if {$U < 0} {set U [expr {$U + $n}]}
    set V [expr {$V % $n}]
    if {$V < 0} {set V [expr {$V + $n}]}

    # --- Strong Lucas PRP conditions ---
    # Condition 1: U_d = 0 (mod n)
    if {$U == 0} {return 1}
    # Condition 2: V_{d*2^r} = 0 (mod n) for some 0 <= r < s
    if {$V == 0} {return 1}
    for {set r 1} {$r < $s} {incr r} {
        # V_{2k} = V_k^2 - 2*Q^k mod n
        set V [expr {($V * $V - 2 * $Qk) % $n}]
        if {$V < 0} {set V [expr {$V + $n}]}
        set Qk [expr {($Qk * $Qk) % $n}]
        if {$V == 0} {return 1}
    }

    return 0
}

# ---------------------------------------------------------------------
# Strong BPSW probable prime test = MR(2) + strong Lucas PRP
# No known counterexamples exist.
# ---------------------------------------------------------------------
proc is_strong_bpsw_prp {n} {
    if {![mr $n {2}]} {return 0}
    return [is_strong_lucas_prp $n]
}

# ---------------------------------------------------------------------
# isprime, faithful port of sympy.ntheory.primetest.isprime
# ---------------------------------------------------------------------
proc isprime {n} {
    # Step 1: quick composite testing via trial division
    if {$n == 2 || $n == 3 || $n == 5} {return 1}
    if {$n < 2 || $n % 2 == 0 || $n % 3 == 0 || $n % 5 == 0} {return 0}
    if {$n < 49} {return 1}
    if {$n %  7 == 0 || $n % 11 == 0 || $n % 13 == 0 || $n % 17 == 0 ||
        $n % 19 == 0 || $n % 23 == 0 || $n % 29 == 0 || $n % 31 == 0 ||
        $n % 37 == 0 || $n % 41 == 0 || $n % 43 == 0 || $n % 47 == 0} {
        return 0
    }
    if {$n < 2809} {return 1}
    if {$n < 65077} {
        # Euler pseudoprime test with base 2
        set r [pow 2 [expr {$n >> 1}] $n]
        if {$r != 1 && $r != $n - 1} {return 0}
        # Exclude the five Euler pseudoprimes in this range with least prime factor > 47
        if {$n in {8321 31621 42799 49141 49981}} {return 0}
        return 1
    }

    # Step 2: deterministic Miller-Rabin for n < 2^64
    # Range-specific minimal witness sets (from https://miller-rabin.appspot.com/)
    if {$n < 341531} {
        return [mr $n {9345883071009581737}]
    }
    # Skip the hash-based single-base test; use a known 3-base set instead
    if {$n < 4759123141} {
        return [mr $n {2 7 61}]
    }
    if {$n < 350269456337} {
        return [mr $n {4230279247111683200 14694767155120705706 16641139526367750375}]
    }
    if {$n < 55245642489451} {
        return [mr $n {2 141889084524735 1199124725622454117 11096072698276303650}]
    }
    if {$n < 7999252175582851} {
        return [mr $n {2 4130806001517 149795463772692060 186635894390467037 3967304179347715805}]
    }
    if {$n < 585226005592931977} {
        return [mr $n {2 123635709730000 9233062284813009 43835965440333360 761179012939631437 1263739024124850375}]
    }
    if {$n < 18446744073709551616} {
        return [mr $n {2 325 9375 28178 450775 9780504 1795265022}]
    }
    # Extended deterministic ranges from https://arxiv.org/pdf/1509.00864.pdf
    if {$n < 318665857834031151167461} {
        return [mr $n {2 3 5 7 11 13 17 19 23 29 31 37}]
    }
    if {$n < 3317044064679887385961981} {
        return [mr $n {2 3 5 7 11 13 17 19 23 29 31 37 41}]
    }

    # Step 3: strong BPSW for everything else
    return [is_strong_bpsw_prp $n]
}

# ---------------------------------------------------------------------
# nextprime, return the first prime > n, using 6k+/-1 wheel stepping
# ---------------------------------------------------------------------
proc nextprime {n} {
    if {$n < 2} {return 2}
    if {$n < 3} {return 3}
    if {$n < 5} {return 5}

    set nn [expr {6 * ($n / 6)}]
    if {$nn == $n} {
        # n divisible by 6 -> try 6k+1
        set n [expr {$nn + 1}]
        if {[isprime $n]} {return $n}
        set n [expr {$nn + 5}]
    } elseif {$n - $nn == 5} {
        # n = 5 mod 6 -> try next 6k+1
        set n [expr {$nn + 7}]
        if {[isprime $n]} {return $n}
        set n [expr {$nn + 11}]
    } else {
        set n [expr {$nn + 5}]
    }

    # n is now at a 6k+5 position; alternate +2 (->6k+1) then +4 (->6k+5)
    while {1} {
        if {[isprime $n]} {return $n}
        set n [expr {$n + 2}]
        if {[isprime $n]} {return $n}
        set n [expr {$n + 4}]
    }
}

# ---------------------------------------------------------------------
# prevprime, return the largest prime < n, using 6k+/-1 wheel stepping
# ---------------------------------------------------------------------
proc prevprime {n} {
    if {$n < 3} {error "no preceding primes"}
    if {$n < 4} {return 2}
    if {$n < 6} {return 3}
    if {$n < 8} {return 5}

    set nn [expr {6 * ($n / 6)}]
    if {$n - $nn <= 1} {
        # n is 6k or 6k+1 -> try 6k-1 then step backward
        set n [expr {$nn - 1}]
        if {[isprime $n]} {return $n}
        set n [expr {$n - 4}]
    } else {
        set n [expr {$nn + 1}]
    }

    # n is now at a 6k+1 position; alternate -2 (->6k-1) then -4 (->6k+1)
    while {1} {
        if {[isprime $n]} {return $n}
        set n [expr {$n - 2}]
        if {[isprime $n]} {return $n}
        set n [expr {$n - 4}]
    }
}

# ---------------------------------------------------------------------
# randint, random integer in [a, b] inclusive, supporting bignums
# ---------------------------------------------------------------------
proc randint {a b} {
    set range [expr {$b - $a + 1}]
    if {$range <= 0} {error "empty range"}
    # Count bits needed
    set bits 0
    set tmp $range
    while {$tmp > 0} {
        incr bits
        set tmp [expr {$tmp >> 1}]
    }
    # Rejection sampling with random bits
    while {1} {
        set n 0
        for {set i 0} {$i < $bits} {incr i} {
            set n [expr {($n << 1) | int(rand() * 2)}]
        }
        if {$n < $range} {
            return [expr {$a + $n}]
        }
    }
}

# ---------------------------------------------------------------------
# randprime, random prime in [a, b), matching sympy's algorithm exactly
# ---------------------------------------------------------------------
proc randprime {a b} {
    if {$a >= $b} {return}
    set a [expr {int($a)}]
    set b [expr {int($b)}]
    set n [randint [expr {$a - 1}] $b]
    set p [nextprime $n]
    if {$p >= $b} {
        set p [prevprime $b]
    }
    if {$p < $a} {
        error "no primes exist in the specified range"
    }
    return $p
}


# =====================================================================
# JSON output mode for testing against sympy
# =====================================================================
if {[info script] eq $argv0} {
    if {[lindex $argv 0] eq "--test"} {
        # Output JSON results for automated comparison
        set results {}

        # isprime tests
        set isprime_tests {0 1 2 3 4 5 6 7 8 9 10 11 13 15 17 19 23 25 29 31
            37 41 43 47 49 51 53 59 61 67 71 73 79 83 89 97
            100 101 103 107 109 113 121 127 131 137 139 149 151 157
            2809 2810 2811 8321 31621 42799 49141 49981
            65077 65078 65079 104729 104730
            341531 341532 999961 999979
            4759123141 4759123142
            100000000003 100000000019 100000000057
            999999999999999989 999999999999999990
            1000000000000000000000000000000000000121
            1000000000000000000000000000000000000123
            170141183460469231731687303715884105727}

        # pow tests (list of {base exp mod expected} or {base exp expected} for no-mod)
        set pow_tests {
            {2 10 {} 1024}
            {3 0 {} 1}
            {5 1 {} 5}
            {2 0 7 1}
            {2 10 1000 24}
            {3 100 997 847}
            {7 256 13 9}
            {2 -1 7 4}
            {3 -1 11 4}
            {5 -3 17 12}
            {7 -2 13 4}
            {2 -1 1000000007 500000004}
            {123456789 -1 1000000007 18633540}
            {2 100 1000000007 976371285}
            {0 0 {} 1}
            {0 5 {} 0}
            {10 3 {} 1000}
            {-3 3 {} -27}
            {-2 4 {} 16}
            {2 10 1 0}
            {100 0 1 0}
            {3 -1 128 43}
            {3 -1 1024 683}
            {7 -1 2187 625}
            {3 -1 1048576 699051}
            {11 -3 65536 32251}
            {7 -2 59049 14461}
            {13 -5 16807 1791}
            {3 -1 1267650600228229401496703205376 845100400152152934331135470251}
            {5 -1 12157665459056928801 9726132367245543041}
            {17 -1 8589934592 4042322161}
            {101 -1 4747561509943 2068244618193}
        }

        puts -nonewline "\{\"pow\":\["
        set first 1
        foreach t $pow_tests {
            lassign $t b e m expected
            if {!$first} {puts -nonewline ","}
            set first 0
            if {$m eq {}} {
                set result [pow $b $e]
            } else {
                set result [pow $b $e $m]
            }
            puts -nonewline "\{\"base\":$b,\"exp\":$e,\"mod\":\"$m\",\"result\":$result\}"
        }
        puts -nonewline "\],"

        puts -nonewline "\"isprime\":\{"
        set first 1
        foreach n $isprime_tests {
            if {!$first} {puts -nonewline ","}
            set first 0
            puts -nonewline "\"$n\":[isprime $n]"
        }
        puts -nonewline "\},"

        # nextprime tests
        set nextprime_tests {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20
            50 97 100 1000 10000 99999 100000
            999999 1000000 999999999999999900 999999999999999989}

        puts -nonewline "\"nextprime\":\{"
        set first 1
        foreach n $nextprime_tests {
            if {!$first} {puts -nonewline ","}
            set first 0
            puts -nonewline "\"$n\":[nextprime $n]"
        }
        puts -nonewline "\},"

        # prevprime tests
        set prevprime_tests {3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20
            50 100 101 1000 10000 100000 1000000
            999999999999999990 1000000000000000000}

        puts -nonewline "\"prevprime\":\{"
        set first 1
        foreach n $prevprime_tests {
            if {!$first} {puts -nonewline ","}
            set first 0
            puts -nonewline "\"$n\":[prevprime $n]"
        }
        puts -nonewline "\}\}"
        puts ""
    } else {
        puts "=== isprime tests ==="
        foreach n {2 3 4 5 13 15 49 2809 8321 31621 65077 104729
                   341531 4759123141 100000000003 999999999999999989} {
            puts "  isprime($n) = [isprime $n]"
        }

        puts "\n=== nextprime / prevprime ==="
        foreach n {10 100 1000 999999999999999900} {
            puts "  nextprime($n) = [nextprime $n]"
            puts "  prevprime($n) = [prevprime $n]"
        }

        puts "\n=== randprime ==="
        foreach {a b} {1 30  100 200  1000000 2000000  100000000000000 100000000100000} {
            set p [randprime $a $b]
            puts "  randprime($a, $b) = $p  (isprime=[isprime $p])"
        }

        puts "\n=== BPSW range: large primes ==="
        set big 1000000000000000000000000000000000000121
        puts "  isprime($big) = [isprime $big]"
        set big2 1000000000000000000000000000000000000123
        puts "  isprime($big2) = [isprime $big2]"
    }
}
