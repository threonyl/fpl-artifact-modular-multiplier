# Testing RTL sources using cocotb

Verilator has better support for SystemVerilog. Hence, we will pass `SIM=verilator` to specify it. In the future an alternative can be used. (Future: Maybe vivado or modelsim?)

1. Run `uv sync` in this directory.
2. Run `SIM=verilator uv run tests/{module}/run_{module}.py` or go to `/tests/{module}` and run `SIM=verilator make`.

# Clean intermediate outputs
1. Run `make clean` in `/tests/{module}`.

# Generating waveforms
Verilator has a quirk with generating `.fst`. Using `make` with `--trace-fst` does not work.
## Option 1 (FST with Python Runner)
Smaller files. Better overall.
1. Run `SIM=verilator WAVES=1 uv run tests/{module}/run_{module}.py`.
2. Open the `.fst` waveform (using Surfer or GTKWave) file generated in `sim_build`.

## Option 2 (VCD with Makefile)
Larger files. If you want to use `make`.
1. Run `SIM=verilator WAVES=1 EXTRA_ARGS=--trace make`.
2. Open the `.vcd` waveform (using Surfer or GTKWave) file generated in the `{module}` directory.