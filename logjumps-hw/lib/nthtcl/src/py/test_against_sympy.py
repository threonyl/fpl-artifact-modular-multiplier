#!/usr/bin/env python3
"""Compare Tcl primes.tcl output against sympy for correctness."""

import json
import subprocess
import sys

from sympy import isprime, nextprime, prevprime


def main():
    # Run the Tcl script in --test mode to get JSON output
    print("Running Tcl primes.tcl --test ...")
    result = subprocess.run(
        ["tclsh", "../tcl/primes.tcl", "--test"],
        capture_output=True, text=True, timeout=300,
    )
    if result.returncode != 0:
        print(f"Tcl script failed:\n{result.stderr}")
        sys.exit(1)

    tcl_data = json.loads(result.stdout.strip())

    total = 0
    passed = 0
    failed = 0

    # -- pow --
    print("\n=== pow ===")
    pow_passed = 0
    pow_total = 0
    for entry in tcl_data["pow"]:
        b = int(entry["base"])
        e = int(entry["exp"])
        m_str = entry["mod"]
        tcl_result = int(entry["result"])
        if m_str == "":
            expected = pow(b, e)
        else:
            expected = pow(b, e, int(m_str))
        pow_total += 1
        total += 1
        if tcl_result == expected:
            pow_passed += 1
            passed += 1
        else:
            failed += 1
            mod_part = f", {m_str}" if m_str else ""
            print(f"  FAIL pow({b}, {e}{mod_part}): tcl={tcl_result}, python={expected}")
    print(f"  {pow_passed}/{pow_total} passed")

    # -- isprime --
    print("\n=== isprime ===")
    for n_str, tcl_val in tcl_data["isprime"].items():
        n = int(n_str)
        expected = isprime(n)
        tcl_bool = bool(tcl_val)
        total += 1
        if tcl_bool == expected:
            passed += 1
        else:
            failed += 1
            print(f"  FAIL isprime({n}): tcl={tcl_bool}, sympy={expected}")
    print(f"  {passed}/{total} passed")

    # -- nextprime --
    print("\n=== nextprime ===")
    np_passed = 0
    np_total = 0
    for n_str, tcl_val in tcl_data["nextprime"].items():
        n = int(n_str)
        expected = nextprime(n)
        tcl_int = int(tcl_val)
        np_total += 1
        total += 1
        if tcl_int == expected:
            np_passed += 1
            passed += 1
        else:
            failed += 1
            print(f"  FAIL nextprime({n}): tcl={tcl_int}, sympy={expected}")
    print(f"  {np_passed}/{np_total} passed")

    # -- prevprime --
    print("\n=== prevprime ===")
    pp_passed = 0
    pp_total = 0
    for n_str, tcl_val in tcl_data["prevprime"].items():
        n = int(n_str)
        expected = prevprime(n)
        tcl_int = int(tcl_val)
        pp_total += 1
        total += 1
        if tcl_int == expected:
            pp_passed += 1
            passed += 1
        else:
            failed += 1
            print(f"  FAIL prevprime({n}): tcl={tcl_int}, sympy={expected}")
    print(f"  {pp_passed}/{pp_total} passed")

    # -- Summary --
    print(f"\n{'='*40}")
    print(f"TOTAL: {passed}/{total} passed, {failed} failed")
    if failed:
        print("SOME TESTS FAILED!")
        sys.exit(1)
    else:
        print("ALL TESTS PASSED!")


if __name__ == "__main__":
    main()
