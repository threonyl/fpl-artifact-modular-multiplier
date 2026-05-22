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