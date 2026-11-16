---
name: cocotb-run
description: Run an NDK-FPGA cocotb bench with nvc and judge the result correctly — environment, seeding, wall caps, the 10x pre-build gate and the traps that make a run lie. Use whenever a cocotb test or suite is run, compared (A/B, bisect) or reported as green.
---

# Run a cocotb bench

## 1. Environment
```sh
source env.sh
export PATH=$HOME/miniforge3/envs/ndk-env/bin:$PATH   # pytest + xdist + cocotb live only here
export SIM=nvc                                        # TARGET=cocotb benches switch to nvc with it
```
Never pass `PYTHON=` alone: the cocotb Makefile derives `PYTHON_LIBDIR` from `python3` on `PATH`, so a
split interpreter fails every test with `nvc produced no results.xml (exit 0)`. That is the VHPI
bridge failing to load, not an RTL fault.

## 2. Pick the run
| Purpose | Run | Seed |
|---|---|---|
| "did I break something" during development | the suite once (`make sim-parallel` where it exists, else `make`) | random |
| prove a fix, A/B two configs, `git bisect` | the same tests at >= 3 pinned seeds | `COCOTB_RANDOM_SEED=<n>` |
| gate before a bitstream build | the full suite 10x | random each time |

- Pinned seeds prove a fix; only random seeds prove green.
- Report a rate (`pass=8 fail=2`), never a single "it passes".
- A failing seed is an asset: keep it for a deterministic waveform.
- The 10x gate comes before a build is proposed. The build itself needs the user's go-ahead.

## 3. Wall cap
- ZITI benches: 10 min per scenario, enforced inside the test too (`WALL_CAP_S`). Hitting the cap is
  a failure. CESNET's own benches run uncapped apart from their hang guard.
- Time a new or changed test solo (`pytest -n 5`, `WALL_CAP_S=600`). The sharded suite's larger cap
  hides solo overruns.
- An overrunning scenario gets a smaller stimulus or a shard, not a higher cap.

## 4. Waiting on a background run
Wait on the artefact: `results.xml`, the pytest tally line or an exit code. Never wait on
`pgrep -f <pattern>`, which matches the waiter's own command line. Poll at 5, 15, 30 or 60 s.

## 5. Judge the result
- `results.xml` must exist and be newer than the launch. A zero exit without it means nothing ran.
- CPU time / test count == the wall cap means every test hung. That is a deadlock, not a slowdown.
- Identical numbers across "two" runs mean the second run never happened.
- Silent no-ops in cocotb 2.0.1 / cocotb_bus:
  - `reorder_depth` is ignored when `add_interface` also gets `compare_fn`
  - `@cocotb.test(skip=...)` is ignored whenever `COCOTB_TESTCASE` is set (the pytest wrappers set
    it), so gate in the wrapper
  - renaming a test changes its seed (`seed + sha1(fullname)`): instrument in place
- A checker that samples at `RisingEdge` + `ReadOnly` misreads signals that a driver writes past
  the edge. Realign the sample (`sample_delay`) before reporting a protocol violation.

## 6. Questa
Local runs use nvc only. A CESNET-bound bench gets one Questa run before its PR is published.
