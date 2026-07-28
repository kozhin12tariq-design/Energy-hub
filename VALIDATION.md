# Validation log — PWL/MILP fuel cell integration

This log records the verification performed while embedding the fuel
cell's piecewise-linear (PWL) part-load efficiency curves into the
actual Month 3 dispatch optimization as a genuine MILP (Tasks 1-5 of
the `claude_code_prompt_v2.md` instruction set), rather than leaving
PWL as a standalone Month 2 demonstration. All numbers below were
measured directly on the development container (Octave 8.4, headless);
absolute wall-clock times are machine-dependent, but the relative
before/after comparisons and all correctness checks are not.

## Constraints re-checked after every task

These four checks were re-run after each of the five tasks below and
never moved:

| Check | Result |
|---|---|
| IEEE 33-bus total losses | 202.677 kW (published benchmark: ~202.7 kW) |
| IEEE 33-bus minimum voltage | 0.9131 pu at bus 18 (published benchmark: ~0.9131 pu) |
| `ieee33_data.m` assertions (3715 kW, 2300 kVAr) | Pass |
| `energy_hub_coupling_matrix.m` refuses PWL edges | Still throws its existing `energy_hub_coupling_matrix:pwl` error |
| Every `main_month*.m` script | Runs end-to-end without error after every task |

## Task 1 — Day-ahead: LP → genuine MILP

`dayahead_dispatch.m`'s single scalar-efficiency `PH2` variable was
replaced with a segment-splitter + concentrator + fill-order-binary
MILP structure (`p.PWL.nSegments`, default 5).

**Why binaries are mandatory** (not a nicety): the fitted curves are
non-concave/S-shaped. At `nSegments=5`, the electrical curve's segment
slopes are `0.4453, 0.5078, 0.4578, 0.3245, 0.1146` — segment 2's slope
*exceeds* segment 1's. A plain LP relaxation cherry-picks the
higher-slope segment while leaving a lower one empty, reporting more
electricity than the fuel cell can physically produce at that fuel
level. A standalone GLPK test confirmed this directly before the file
was rewritten:

| | Segment allocation (kW) |
|---|---|
| LP, no fill-order binaries (bug reproduced) | `[0, 30, 10, 0, 0]` |
| MILP, with fill-order binaries (correct) | `[30, 10, ~0, ~0, 0]`, `u=[1,0,0,0]` |

**Verification gate:**

1. **Fill-order assertion** (`PH2seg(k+1)>0` while `PH2seg(k)` not full
   ⇒ hard error): never trips. Confirmed under forced FC utilization
   (cheap H2 test price) — segments fill sequentially (30, 30, 24.5→7.2→
   9.5→13.5→19.8→28.7→30 across active hours), never out of order.
2. **`nSegments=1` degenerate case**: collapses to the old
   constant-efficiency LP exactly. Forcing FC utilization for the
   check, `nSegments=1` cost = **11.276869**, identical (bit-for-bit) to
   running the pre-change file with `eta_FC_e`/`eta_FC_th` hardcoded to
   the `nSegments=1` slopes (0.37 / 0.40).
3. **`main_month3_multiscale_dispatch.m` end-to-end**: runs without
   error; `sol.PH2` still exists (now the segment total,
   `sum(sol.PH2seg,2)` matches exactly) and Month 3 plots render.
4. **Default-scenario check**: under the project's default
   `price_H2=$0.22` and forecast (seed 42), the fuel cell is unused
   (`PH2≡0`) both before and after this change — confirmed by running
   the pre-change file directly (identical $43.03 planned cost, `PH2≡0`
   both ways) — so this is pre-existing economics, not a regression
   introduced by the MILP embedding.

**Solve time** (mean of 10 day-ahead-only solves / 5 full 385-solve
closed-loop days):

| | Day-ahead MILP alone | Full 385-solve closed-loop day |
|---|---|---|
| Before (constant-efficiency LP) | 0.033 s | 0.80 s |
| After Task 1 (MILP day-ahead only) | 0.069 s | 0.94 s |

## Task 2 — Propagate PWL to intraday and real-time

`intraday_dispatch.m`: the same segment+concentrator+fill-order-binary
structure, applied independently to stage 1 and every stage-2 scenario
block (each makes its own fuel cell decision). `realtime_balance.m`:
the fuel cell is *held fixed* at intraday's committed `PH2` here (not
re-optimized), so no segments/binaries are needed — only an exact curve
lookup via `pwl_utils('eval', ...)` replacing the old flat
`p.eta_FC_e` multiplier. No heat-side balance exists in that file, so
there was nothing else to change there.

Also found and fixed the identical stale-scalar bug in
`simulate_multiscale_day.m`'s `simulate_open_loop` (used by Case 2,
"day-ahead only"), which was reconverting the day-ahead PWL-derived
`PH2` total back to electricity with the same flat `p.eta_FC_e`
multiplier — inconsistent the moment day-ahead started computing `PH2`
from real segment slopes. Fixed with the same `pwl_utils('eval', ...)`
lookup.

**Verification:**

- `intraday_dispatch.m`: forcing FC utilization (cheap H2) fills
  segments sequentially (30, 30, 10.78, 0, 0) across all blocks, no
  fill-order violations. `nSegments=1` degenerate case matches the old
  scalar-efficiency (0.37/0.40) intraday LP exactly: **-0.347092** both
  ways.
- `realtime_balance.m`: PWL eval at `PH2=80` gives **37.75 kW** vs. the
  old flat-scalar **36.00 kW** — the true nonlinear value now used.
- `main_month3_multiscale_dispatch.m` and `main_month4a_case_studies.m`
  (which exercises the open-loop fix via Case 2) both run end-to-end
  without error.

**Solve time** (full 385-solve closed-loop day, mean of 5):

| | Time |
|---|---|
| Before (constant-efficiency LP) | 0.80 s |
| After Task 1 only (day-ahead MILP) | 0.94 s |
| After Task 1+2 (day-ahead + intraday MILP) | 1.66 s |

Intraday now solves 96 small MILPs/day instead of LPs, which is the
dominant contributor to the further increase.

## Task 3 — Case 5: constant efficiency vs. PWL (isolates PWL's own value)

Added `opts.usePWL` (default `true`) to `simulate_multiscale_day.m`. When
`false`, the **planning** stack (day-ahead + intraday) is given a
1-segment ("constant efficiency") fit of the fuel cell curve instead of
the real PWL fit — exactly the `nSegments=1` degenerate case verified in
Tasks 1-2 — while the **physical/realized** side always converts the
committed `PH2` through the TRUE nonlinear curve, since the fuel cell
doesn't know what the planner assumed about it.

Added Case 5 to `main_month4a_case_studies.m`. Under the default
`price_H2=$0.22` the fuel cell is never economically dispatched at all
(checked across every seed/uncertainty combination already used
elsewhere in this project: seeds `{42,7,123}` × uncertainty scales
`{0.5,1,1.5,2,3}`, all 15 combinations give `PH2≡0`), which would make
the comparison vacuous — so Case 5 uses its own `price_H2=$0.06`, the
cheapest round number at which the day-ahead MILP actually dispatches
the fuel cell across several hours (5 active hours, utilization
spanning roughly 37%-55% of rated power) without pinning it at its
rated maximum.

| Case 5 variant | Planned ($) | Actual/realized ($) | Gap ($) | Gap (%) |
|---|---|---|---|---|
| PWL (correct model) | 34.6777 | 38.1960 | 3.5183 | 10.15% |
| Constant efficiency | 37.1684 | 38.7564 | 1.5880 | 4.27% |

Comparing **realized** cost (both variants evaluated against the one
true curve, isolating the modeling choice from forecast noise):
constant efficiency costs **1.47% more** than PWL. Same direction as
Huang et al.'s reported 13.7% for a constant-efficiency baseline
(different system/curves/price levels — not a claim of matching their
number, only the same kind of finding). CO2: PWL 106.56 kg vs. constant
106.01 kg. Reliability: no violations either way at this scenario.

Regression check: Cases 1-4 are byte-identical to the pre-Task-3 run
(same cost/CO2/peak/unmetE/violHrs), since `usePWL=true` (default)
makes `pPlan == pTrue` exactly.

## Task 4 — Segment-count trade-off sweep

New script `main_month4c_pwl_segment_sweep.m`, sweeping
`p.PWL.nSegments ∈ {1, 2, 5, 10, 20, 36}` at the same `price_H2=$0.06`
fuel-cell-active scenario as Case 5.

| nSegments | MaxErr-E (kW) | RMSE-E (kW) | MaxErr-T (kW) | RMSE-T (kW) | Solve (s) | Planned ($) | Realized ($) | Gap (%) |
|---|---|---|---|---|---|---|---|---|
| 1 | 9.1534 | 6.1694 | 7.2355 | 5.3589 | 0.038 | 37.1684 | 35.5466 | -4.36 |
| 2 | 4.5050 | 2.3852 | 2.2270 | 1.4114 | 0.041 | 34.3998 | 42.9298 | +24.80 |
| 5 | 0.9268 | 0.4334 | 0.4690 | 0.2363 | 0.107 | 34.6777 | 34.6360 | -0.12 |
| 10 | 0.2488 | 0.1128 | 0.1444 | 0.0601 | 0.161 | 34.6155 | 34.6089 | -0.02 |
| 20 | 0.0851 | 0.0283 | 0.0444 | 0.0149 | 0.447 | 34.6093 | 34.6068 | -0.01 |
| 36 | 0.0262 | 0.0084 | 0.0125 | 0.0045 | 1.076 | 34.6071 | 34.6061 | -0.00 |

Curve-fit error (Max/RMSE, kW, vs. the exact continuous efficiency
function) falls monotonically as segment count rises — same
qualitative shape as Huang et al.'s reported accuracy-vs-computation
trend (13.7%→8.35%→1.11%→0.06%, their system/curves — not the same
numbers). MILP solve time grows from 0.04s to 1.08s (more segment and
fill-order-binary variables per hour) — the tractability side of the
trade-off.

**Honest note on the Gap(%) column**: it is *not* monotonic (nSegments=2
has a larger gap than nSegments=1). Verified this is not a bug: each
segment count gives the day-ahead MILP a genuinely different feasible
region and therefore chooses a genuinely different `PH2` fuel schedule
(confirmed by inspecting the hour-by-hour `PH2` profiles at n=1, 2, 5 —
they differ materially, not just in evaluation), rather than only
re-evaluating one fixed plan more accurately. The curve-fit error
columns are the cleaner, decision-independent measure of PWL accuracy
for that reason; the gap settles into a small, consistently-shrinking
tail from `nSegments=10` onward.

## Task 5 — Documentation-only (no behavior change)

- **5a**: `energy_hub_incidence_matrix.m` now documents that its sign
  convention (+1 tail / -1 head, standard graph theory) is a different
  bookkeeping axis than the energy-hub literature's port-based
  convention (+1 input port / -1 output port) used by
  `energy_hub_coupling_matrix.m`. Both are correct for what they're used
  for; no behavior changed. Also added to `README.md` (Month 1 section).
- **5b**: `README.md` (Month 3 section) now states explicitly that
  day-ahead's reserve-margin headroom is a robustness *proxy*, not true
  robust optimization, and spells out what a full robust-MILP (YALMIP
  `robustify` + a solver like Gurobi, optimizing against an explicit
  uncertainty set with a genuine worst-case feasibility guarantee)
  would change, and why this codebase doesn't do that (deliberately
  `glpk`-only, no additional toolchain dependency).
- **5c**: `pwl_utils.m`'s `'fit'` mode gained an optional 5th
  `placement` argument: `'uniform'` (default, verified bit-for-bit
  identical to the pre-change behavior with no argument) and
  `'curvature'` (breakpoints concentrated by equal cumulative
  `|second derivative|`). Both are reported in Month 2's error table
  (`main_month2a_arbitrary_configuration_and_pwl.m`):

  | Component branch | MaxErr-uniform | MaxErr-curvature | RMSE-uniform | RMSE-curvature |
  |---|---|---|---|---|
  | Fuel cell electrical | 0.0309 | 0.0181 | 0.0144 | 0.0103 |
  | Fuel cell thermal | 0.0156 | 0.0145 | 0.0079 | 0.0087 |
  | PV array/inverter | 0.0059 | 0.0051 | 0.0021 | 0.0029 |
  | Electrolyzer | 0.0253 | 0.0281 | 0.0136 | 0.0151 |

  Honest finding: curvature placement is a max-error-oriented heuristic
  (equidistributing where the worst local error would occur) — it
  reduces MaxErr for 3 of 4 curves, but does **not** reliably improve
  RMSE (only the fuel-cell electrical curve improves on both metrics;
  the electrolyzer, whose curvature varies only mildly across its whole
  domain, gets slightly *worse* on both). `'uniform'` remains the
  project default for that reason and because its own error is already
  1-2 orders of magnitude below constant efficiency.

## Files touched (by task)

- **Task 1**: `dayahead_dispatch.m`, `multiscale_default_params.m`
- **Task 2**: `intraday_dispatch.m`, `realtime_balance.m`,
  `simulate_multiscale_day.m`
- **Task 3**: `simulate_multiscale_day.m`, `main_month4a_case_studies.m`
- **Task 4**: `main_month4c_pwl_segment_sweep.m` (new file)
- **Task 5**: `energy_hub_incidence_matrix.m`, `pwl_utils.m`,
  `main_month2a_arbitrary_configuration_and_pwl.m`, `README.md`

No file was reorganized, moved, renamed, merged, or split. No file
outside this list was modified.
