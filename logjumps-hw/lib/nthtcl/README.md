# Number Theory in TCL

**Problem:** You are writing a verilog source where you need compile-time generated parameters. You need number theory functions (like sympy, prime generation, EEA). You don't want to add python as a dependency, well because it takes you a few hops. Run python script (make sure that you have a nice virtual environment setup), generate file (or verilog), read from file, simulate.

**Solution:** You insert this in your synthesis hook in vivado (or any other EDA tool for that matter), use the functions from this library in your own pre-synthesis/simulation hook tcl script, click run!

**Why?:** Shorter feedback loop, you stay in the _"zone"_ :).

# Documentation

Currently no separate documentation, the code _is_ the documentation.

## Developing nthtcl

There is a python script (irony is not lost on me), that checks the tcl library for functional correctness.
+ Run `uv sync` (you need to install uv of course)
+ Then `cd src/py`
+ Finally `uv run test_against_sympy.py`
+ Check that all tests pass.