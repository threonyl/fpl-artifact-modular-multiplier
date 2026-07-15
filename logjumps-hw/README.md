# LogJumps Modular Reduction in HW

## Quickstart

This repo has submodules don't forget to recurse through them.

```sh
git submodule update --init --recursive
```

Run `uv sync` then `uv run src/python/logjumps.py`.


## Implement a module

**Example:** For modacc (without helper):
```sh
./build.sh impl_modacc.f FIXED_Q=1 LOGQ=398 MAX_COND_SUB=12 AT_REG_PERIOD=3 CS_REG_PERIOD=1 Q_VALUE=340223d472ffcd3496374f6c869759aec8ee9709e70a257ece61a541ed61ec483d57fffd62a7ffff73fdffffffff55560000 FREQ=400
```

For modacc (with helper):
```sh
./build.sh impl_modacc.f PRE_HOOK=modacc_helper.tcl Q_EFF_VAL=1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab COND_SUB_OPT=1 AT_REG_PERIOD=3 CS_REG_PERIOD=1 FREQ=400
```

This helper computes the conditional subtractions and determines the parameters automatically. The corresponding parameters are as follows:

```
modacc  (modacc)
  AT_REG_IN = 1
  AT_REG_OUT = 1
  AT_REG_PERIOD = 3
  AT_USE_CSA = 1
  CONC_ADDSUB = 0
  CS_REG_OUT = 1
  CS_REG_PERIOD = 1
  FIXED_Q = 1
  LATENCY = 8
  LOGQ = 398
  MAX_COND_SUB = 12
  NUM_CS = 4
  NUM_INPUTS = 23
  Q_VALUE = 524603825222014388590056548038856429608223744975045641546243524018049076493135100568231952925198341116774878092956401664
  REG_ADD = 1
  REG_IN = 1
  REG_OUT = 1
  SUM_EXTRA = 5
  SUM_W = 403
  USE_ADDTREE = 1
```

Example result:
```
------------------------------------------------------------
  BUILD COMPLETE
------------------------------------------------------------

  Top module        modacc
  Part              xcu55c-fsvh2892-2L-e
  Target freq       400 MHz

  WNS (setup)       0.033 ns
  WHS (hold)        0.044 ns
  Fmax (est.)       405.4 MHz

  LUTs              13936 / 1303680  (1.07%)
  FFs               15542 / 2607360  (0.60%)
  DSPs              0 / 9024  (0.00%)
  BRAM              0 / 2016  (0.00%)

  Reports           /dir/logjumps-hw/src/vivado/build/modacc_400mhz_AT_REG_PERIOD-3_CS_REG_PERIOD-1_MAX_COND_SUB-12_FIXED_Q-1_LOGQ-398_Q_VALUE-340223d472ffcd3496374f6c869759aec8ee9709e70a257ece61a541ed61ec483d57fffd62a7ffff73fdffffffff55560000

------------------------------------------------------------
```

### Modmul

```sh
./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl Q_EFF_VAL=1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab COND_SUB_OPT=1 FREQ=400
```

## Reproducing the results

All numbers come from out-of-context (OOC) synthesis + place-and-route of
`modmul` on the Alveo U250 (`xcu250-figd2104-2L-e`) at LOGW = 17, driven by
`build.sh` with the `modmul_helper.tcl` pre-hook. Runs used Vivado 2024.2,
EFFORT=0. Place-and-route is not bit-reproducible, so Fmax and utilization
may vary by a few percent across Vivado versions and runs.

### Base-field primes (Q_EFF_VAL, hex, no 0x prefix)

```
BLS12-381  1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab
BLS12-377  1ae3a4617c510eac63b05c06ca1493b1a22d9f300f5138f1ef3622fba094800170b5d44300000008508c00000000001
BN254      30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47
secp256k1  fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f
BW6-761    122e824fb83ce0ad187c94004faff3eb926186a81d14688528275ef8087be41707ba638e584e91903cebaff25b423048689c8ed12f9fd9071dcd3dc73ebff2e98a116c25667a8f8160cf8aeeaf0a437e6913e6870000082f49d00000000008b
```

### Pipeline presets (TUNE)

`TUNE` picks a tuned pipeline configuration so a design point can be
reproduced with one flag instead of ~16 individual FF/pipeline generics:

- `TUNE=250` -> minimum-latency pipeline that closes 250 MHz (the "17cc"
  points). Light pipelining.
- `TUNE=400` -> deep pipeline that closes 400 MHz (the "30cc" points).

### Build command

```sh
cd src/vivado
./build.sh impl_modmul.f PRE_HOOK=modmul_helper.tcl \
    Q_EFF_VAL=<prime-hex> COND_SUB_OPT=1 \
    TUNE=<250|400> PART=xcu250-figd2104-2L-e FREQ=<250|400> \
    EFFORT=<0..3>
```

`EFFORT` selects the implementation strategy (0 = normal, 1 = high,
2 = aggressive, 3 = ultra; see `build.sh`). `EFFORT=0` closes every point
in the table below. Harder corners need more effort: on U250 the
BLS12-381 400 MHz point closes only at `EFFORT=3`, for example.

### Points and expected results

```
Curve      TUNE  FREQ  EFFORT  LAT    Fmax      LUT      FF       DSP    notes
BLS12-381  250   250   0       17cc   251 MHz   67200    44673    584
BLS12-377  250   250   0       17cc   253 MHz   63773    43279    584
BN254      250   250   0       16cc   268 MHz   27734    19740    273
secp256k1  250   250   0       17cc   270 MHz   29538    21007    279
BW6-761    250   250   0       20cc   165 MHz   274032   163683   2043   does not meet 250 MHz
BN254      400   400   0       29cc   414 MHz   25107    36685    273
secp256k1  400   400   0       30cc   440 MHz   26489    38656    284
BW6-761    400   250   0       35cc   254 MHz   275950   269737   2043
```

BW6-761 (45 limbs) needs the deep pipeline even for 250 MHz: the light
`TUNE=250` tops out near 165 MHz, so build it with `TUNE=400 FREQ=250`.

### Reading a result

For a finished build in `src/vivado/build/<tag>/`:

- Fmax / slack: `post_route_timing.rpt` (design WNS), or the `BUILD COMPLETE`
  banner. `Fmax = 1000 / (1000/FREQ - WNS_ns)`.
- Utilization (LUT / FF / DSP / CARRY8): `post_route_util.rpt`.
- Latency in clock cycles: `LAT` in `elaboration_params.rpt`
  (`LAT = MUL_LAT + LJ_LAT`).

### Per-module area and latency breakdown

`report_breakdown.tcl` prints, for each build, the per-module pipeline depth
("Stages") together with LUT / FF / DSP, plus the point's target frequency,
worst slack and Fmax. Run it on one or more finished build dirs, or with no
arguments to report every routed build under `build/` and `Design_Points/`:

```sh
cd src/vivado
vivado -mode batch -source report_breakdown.tcl -tclargs build/<tag>
# a post_route.dcp path also works:
vivado -mode batch -source report_breakdown.tcl -tclargs build/<tag>/post_route.dcp
# or all of them at once:
vivado -mode batch -source report_breakdown.tcl
```

Example output for one point:

```
==== modmul_250mhz_449BC2AC ====
  target 250 MHz   WNS +0.019 ns   Fmax 251 MHz
  Module   Stages  LUT       FF        DSP
  ModMul   17      67200     44673     584
  IntMul   6       20394     7445      216
  ModRed   11      46806     37228     368
  ModAcc   7       16587     12716     0
```