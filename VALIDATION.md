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

---

# Follow-up session — three defects from independent verification

A later review (`claude_code_prompt_v3.md`) found three defects. Two
were **wrong explanatory prose printed next to correct numbers**; one
was scenario framing. No optimization model, MILP formulation, PWL
segment structure, fill-order binary, or solver call was touched.

## Protected numbers — re-verified after all three fixes

| Check | Value | Status |
|---|---|---|
| Case 1 Conventional | $176.37, 366.1 kgCO2, 45.6 kW peak | unchanged |
| Case 2 Day-ahead only | $50.61, 157.0 kgCO2, 105.1 kW, 0.11 kWh, 0.25 h | unchanged |
| Case 3 No robust reserve | $50.49, 147.9 kgCO2, 105.5 kW, 0.54 kWh, 0.42 h | unchanged |
| Case 4 Full proposed | $49.74, 147.9 kgCO2, 103.8 kW, 0.00 kWh, 0.00 h | unchanged |
| Case 5 realized-cost comparison | constant efficiency costs **1.47% more** than PWL | unchanged |
| IEEE 33-bus losses / min voltage | 202.677 kW / 0.9131 pu at bus 18 | unchanged |
| `ieee33_data.m` assertions | 3715 kW / 2300 kVAr | pass |
| Month 4b reserve + uncertainty sweeps | all rows | unchanged |
| Fill-order assertion, normal runs | silent | unchanged |
| Fill-order assertion, LP relaxation | fires: `PH2seg(2)=4.576272 > 0 while PH2seg(1)=4.576272 < w(1)=30` | still fires |
| All seven `main_month*.m` | run end-to-end | pass |

Every sweep value in `main_month4c_pwl_segment_sweep.m` (Planned,
Realized, Gap, and all four curve-fit error columns) is also identical
to the pre-fix run; only wall-clock solve times vary, as timing noise.

## Fix 1 — Case 5's explanation contradicted its own table

**What was wrong.** The printed paragraph claimed the
constant-efficiency row had *"a second, modeling-driven source of
planned-vs-realized divergence on top of that same forecast mismatch"* —
i.e. that it should show a **larger** planned-vs-actual gap. The table
printed immediately above it showed the opposite: constant efficiency
4.27%, PWL 10.15%. The numbers were right; the explanation was the bug.

**The corrected explanation.** The paragraph's implicit premise — *wrong
model ⇒ bigger gap* — is false. The planned-vs-actual gap is not a
measure of model quality: it mixes forecast error with modeling error,
and the modeling component carries a **sign**. It widens the gap only if
the planning model is *optimistic* about the fuel cell, and **narrows**
it if the model is *pessimistic*.

Here the constant-efficiency planning model is a single chord of slope
**0.3700**, while the true curve's marginal slopes over the segments the
fuel cell actually dispatches in are **0.4453 / 0.5078 / 0.4578** — all
above it. That model therefore systematically *under*-states its own
fuel cell: it plans a higher cost ($37.17 vs $34.68), reality comes in
better than planned, and that credit partially cancels the
forecast-driven overrun instead of adding to it. A pessimistic wrong
model can thus look *better* on this statistic than a correct one, which
is exactly why the gap cannot rank models and why the realized-cost
comparison — both variants evaluated against the one true curve — is the
correct isolating measure. Every slope quoted in the new prose is
computed from the fitted breakpoints, not hardcoded.

**New diagnostic.** An `Optimism` column was added to the Case 5 table:
the electricity the planning model believed its own committed fuel would
produce, minus what the true curve really produces from that same fuel,
per kW of fuel, fuel-weighted over the day. It is deliberately an
aggregate — a per-point chord ratio is distorted by near-zero dispatch
intervals, where dividing by a vanishing fuel value blows up (an early
per-point version reported a spurious +0.0359 for the PWL variant for
exactly this reason).

| Case 5 variant | Optimism | Gap(%) |
|---|---|---|
| PWL (correct model) | +0.0060 (neutral) | 10.15 — near-pure forecast error |
| Constant efficiency | −0.0897 (pessimistic) | 4.27 — pessimism offsets the overrun |

## Fix 2 — the `nSegments=2` gap outlier was underexplained

**What was wrong.** The sweep reports a **+24.80%** gap at
`nSegments=2`, worse than `nSegments=1`'s −4.36%, inside a table meant
to demonstrate convergence. The prior text explained this only
generically ("each nSegments value gives the MILP a genuinely different
feasible region") — directionally true, but it never identified why one
coarse model lands positive and the other negative.

**The corrected explanation.** It is the *same* optimism/pessimism
mechanism as Fix 1, with the opposite sign. What matters is not how
accurate a coarse model is, but whether it errs high or low where the
fuel cell actually operates:

- **n=1**: chord slope 0.3700, below the true marginal slopes in the
  dispatched range → **pessimistic** (Optimism −0.1018) → plans high,
  reality beats the plan → gap **negative** (−4.36%).
- **n=2**: a single slope 0.4775 spanning 0–75 kW, versus the true
  curve's own 0.4453 over the first 30 kW of that span. The true curve
  is convex there (verified: `y''>0` for `u<≈0.36`; at the midpoint the
  chord gives 17.906 kW against 17.156 kW true), so the chord sits
  **above** the curve in between → **optimistic** (Optimism +0.0058) →
  over-dispatches, reality under-delivers → gap **positive** (+24.80%).

Adding a segment improved *every* curve-fit metric yet made the gap far
worse, purely by flipping the sign of the modeling error. This turns two
apparent anomalies into one consistent effect, and the text now
cross-references Case 5.

**Sign is predictive; magnitude is not.** The sign of `Optimism` matches
the sign of `Gap(%)` in **all six rows**:

| nSegments | 1 | 2 | 5 | 10 | 20 | 36 |
|---|---|---|---|---|---|---|
| Optimism | −0.1018 | +0.0058 | −0.0025 | −0.0004 | −0.0002 | −0.0001 |
| Gap(%) | −4.36 | +24.80 | −0.12 | −0.02 | −0.01 | −0.00 |

Magnitude is explicitly *not* claimed to scale: n=1 has by far the
largest |Optimism| yet a small gap, n=2 the reverse. A shortfall must be
covered at the $0.10–$0.32/kWh import price while a surplus is only
worth the $0.05/kWh export price, so optimism is punished harder than
pessimism is rewarded, and the re-dispatch itself differs per row. The
`Optimism` column reuses the two vectors the realized-cost step already
computes, so it adds no computation and cannot perturb the table. The
existing (correct) point that the **curve-fit error columns** are the
decision-independent measure of PWL accuracy is retained.

## Fix 3 — hydrogen price reframed as two named, sourced scenarios

**What was wrong.** Under the default price the fuel cell never runs, so
Month 3's headline reported `FC fuel = 0` while Case 5 and the segment
sweep both overrode to $0.06 to force activity. The code was honest that
this was pre-existing economics, but it read as an arbitrary workaround
and left the obvious examiner question unanswered: if the central
contribution never engages in the base case, what is it contributing?

**The corrected framing.** The two prices are defensible endpoints of
real hydrogen economics, now named in `multiscale_default_params.m` and
quoted per kg as well as per kWh. Conversion uses hydrogen's lower
heating value, 120 MJ/kg = 33.3 kWh/kg (verified by arithmetic:
0.22 × 33.3 = $7.33/kg; 0.06 × 33.3 = $2.00/kg):

| Scenario | $/kWh | $/kg | Anchor |
|---|---|---|---|
| `H2_today` (default) | 0.22 | 7.33 | Clean hydrogen delivered today. DOE puts renewable-sourced hydrogen near $5/kg at the production gate; compression, storage, transport and dispensing put delivered cost above that. |
| `H2_doeTarget` | 0.06 | 2.00 | DOE interim 2026 clean-hydrogen target (Clean Hydrogen Electrolysis Program, BIL), en route to the Hydrogen Shot goal of $1/kg by 2031 ("1 1 1": $1 per 1 kg in 1 decade, launched June 2021). |

Both DOE figures were checked against energy.gov rather than asserted
from memory. `p.price_H2` still defaults to `H2_today`, so nothing moves.

**Result.** `main_month3_multiscale_dispatch.m` now runs the stack at
both prices, changing only `p.price_H2`, and prints them side by side:

| | H2_today | H2_doeTarget |
|---|---|---|
| Hydrogen price | $0.22/kWh ($7.33/kg) | $0.06/kWh ($2.00/kg) |
| Day-ahead FC fuel | 0 kWh | 339 kWh |
| Hours FC running (of 24) | 0 | 5 |
| Day-ahead grid import | 363 kWh | 143 kWh |
| Emissions | 147.9 kgCO2 | 106.6 kgCO2 |

At today's delivered cost the fuel cell is uneconomic against grid
import and the optimizer correctly leaves it off — the right economic
answer, not a broken component. At the DOE target it runs 5 h/day,
cutting day-ahead grid import 61% and emissions 28%. Critically it runs
at **37–55% of rated fuel input** — part load, never the rated point a
nameplate efficiency is calibrated to — which is precisely the regime
where a constant efficiency is least accurate and where the PWL/MILP
formulation contributes. The two scenarios together answer "what is the
PWL model for?": it is inert at today's prices because the component it
describes is inert, and becomes load-bearing exactly when hydrogen gets
cheap enough to dispatch.

## Files touched (by fix)

- **Fix 1**: `main_month4a_case_studies.m`
- **Fix 2**: `main_month4c_pwl_segment_sweep.m`
- **Fix 3**: `multiscale_default_params.m`,
  `main_month3_multiscale_dispatch.m`, `main_month4a_case_studies.m`,
  `main_month4c_pwl_segment_sweep.m`, `README.md`

Again, no file was reorganized, moved, renamed, merged, or split, and
no optimization model, MILP formulation, PWL segment structure,
fill-order binary, or solver call was changed.

---

# Fix 4 — hydrogen price-basis mismatch, and what it revealed

## What was wrong

The two hydrogen scenarios were quoted on **different cost bases**. The
comment block was precise that `H2_today` ($0.22/kWh = $7.33/kg) is a
**delivered** price, explicitly noting that DOE's ~$5/kg figure is at the
production gate and that delivery puts the real cost above it. But the
target scenario then silently switched basis: DOE's $2/kg-by-2026 figure
is a **production** target, not a delivered price.

Verified against energy.gov rather than assumed:

- The Bipartisan Infrastructure Law's Clean Hydrogen Electrolysis Program
  funds *"$2/kg clean hydrogen **from electrolysis** by 2026"* — a
  production-gate figure. The Hydrogen Shot's $1/kg by 2031 is likewise
  the cost of *producing* hydrogen.
- DOE tracks delivered cost separately and much higher: its **dispensed**
  hydrogen target for heavy-duty vehicles is **$7/kg by 2028**. (The
  brief for this fix described that as "below $7/kg"; the published
  figure is a target *of* $7/kg by 2028, and it is stated that way in the
  code.)

So the code compared *today's delivered price* against *a future
production-gate price* — apples to oranges, overstating the improvement.

## The corrected like-for-like price

Applying the file's own implied delivery markup consistently, derived in
code rather than hardcoded so the basis is auditable:

```
markup           = $7.33/kg delivered ÷ $5.00/kg production = 1.4652
DOE 2026 target  = $2.00/kg production × 1.4652 = $2.93/kg delivered
                 = $0.087912/kWh at 33.3 kWh/kg LHV
```

Rather than replace one scenario with another, the parameter file now
defines **three**, each with its basis stated: `H2_today` (delivered,
default), `H2_doeTargetDelivered` (delivered, like-for-like headline),
and `H2_doeTargetGate` (production, optimistic bound). Results are
reported as a bracketed range instead of a point estimate.

`H2_doeTargetGate` is kept at exactly `0.06`, so the segment sweep — which
uses it — is numerically unchanged under the new name.

**The qualitative finding survives the correction.** Day-ahead dispatch,
verified across the price range:

| Price | Basis | FC fuel | Hours active |
|---|---|---|---|
| $0.0600/kWh ($2.00/kg) | production gate (optimistic bound) | 339.2 kWh | 5 |
| **$0.0879/kWh ($2.93/kg)** | **delivered, like-for-like** | **138.2 kWh** | **2** |
| $0.1000/kWh ($3.33/kg) | — | 129.3 kWh | 2 |
| $0.1200/kWh ($4.00/kg) | — | 14.5 kWh | 1 |

The fuel cell is still economic, still at part load, still exercising the
PWL/MILP path. Part-load ranges were re-measured rather than carried
over: **40–52%** of rated fuel input at the delivered price and **37–55%**
at the gate price (the previously reported 37–55% is the gate figure only).

## The finding: the PWL benefit is utilization-dependent

Re-running the full Case 5 comparison at both target prices:

| Hydrogen price | FC fuel / hours | PWL realized | Constant realized | Constant vs. PWL |
|---|---|---|---|---|
| $2.93/kg delivered | 138.2 kWh / 2 h | $46.2724 | $46.3637 | **+0.20%** |
| $2.00/kg gate | 339.2 kWh / 5 h | $38.1960 | $38.7564 | **+1.47%** |

The PWL cost advantage is **strongly utilization-dependent** — 1.47% when
the fuel cell runs 339 kWh over 5 hours, 0.20% when it runs 138 kWh over
2 hours. This is physically sensible: a part-load model can only matter
in proportion to how much energy flows through the nonlinear device, and
2.5× more fuel flows at the gate price. But it means the previous single
headline number was quietly conditioned on the optimistic price basis.

This is now reported as a range in the output, in
`main_month4a_case_studies.m`'s narrative and header, and in `README.md`,
with the explicit statement that **+0.20% is a smaller claim than
+1.47%**. A result stated with its sensitivity is more defensible than a
best-case number waiting to be challenged.

**The cost-independent argument is the stronger one**, and is now stated
alongside: the PWL segments and fill-order binaries exist to keep the
dispatch *physically possible*, not to save money. Without the ordering
binaries the LP relaxation fills segment 2 while segment 1 is only
fractionally full (`PH2seg(2) > 0` at `PH2seg(1) = 4.576` of 30),
reporting more electricity per unit hydrogen than the device can produce.
That defect exists at **every** price, including ones where the cost
difference rounds to zero. A model that violates the machine it describes
is wrong regardless of what the error costs on a given day.

## Segment sweep — price renamed, numbers unchanged

The sweep moved from `H2_doeTarget` to `H2_doeTargetGate` (same 0.06). It
now states *why* the gate price is the right choice **there**: it is a
convergence study, and the gate price maximises fuel-cell throughput,
giving the clearest signal — legitimate for measuring convergence, but
not for a cost headline, which is why Case 5 reports both prices.
Confirmed unchanged (timing columns excluded, being machine noise):

| nSegments | 1 | 2 | 5 | 10 | 20 | 36 |
|---|---|---|---|---|---|---|
| MaxErrE | 9.1534 | 4.5050 | 0.9268 | 0.2488 | 0.0851 | 0.0262 |
| Planned($) | 37.1684 | 34.3998 | 34.6777 | 34.6155 | 34.6093 | 34.6071 |
| Realized($) | 35.5466 | 42.9298 | 34.6360 | 34.6089 | 34.6068 | 34.6061 |
| Gap(%) | −4.36 | +24.80 | −0.12 | −0.02 | −0.01 | −0.00 |
| Optimism | −0.1018 | +0.0058 | −0.0025 | −0.0004 | −0.0002 | −0.0001 |

## Protected values — re-verified after Fix 4

| Check | Value | Status |
|---|---|---|
| Cases 1–4 | $176.37 / $50.61 / $50.49 / $49.74, plus CO2, peak, unmetE, violHrs | unchanged |
| IEEE 33-bus | 202.677 kW / 0.9131 pu at bus 18 | unchanged |
| `ieee33_data.m` assertions | 3715 kW / 2300 kVAr | pass |
| Segment sweep, all columns | see table above | unchanged |
| Case 5 `Optimism` | PWL +0.0060, constant −0.0897 | unchanged |
| Sweep `Optimism` | n=1 −0.1018 (gap −4.36%), n=2 +0.0058 (gap +24.80%) | unchanged |
| `Optimism` explanations (both files) | — | unchanged |
| Fill-order, normal runs (both target prices) | silent | pass |
| Fill-order, LP relaxation | fires: `PH2seg(2)=4.576272 > 0 while PH2seg(1)=4.576272 < w(1)=30` | still fires |
| All seven `main_month*.m` | run end-to-end | pass |

## Files touched (Fix 4)

`multiscale_default_params.m`, `main_month3_multiscale_dispatch.m`,
`main_month4a_case_studies.m`, `main_month4c_pwl_segment_sweep.m`,
`README.md`, `VALIDATION.md`.

No file was reorganized, moved, renamed, merged, or split, and no
optimization model, MILP formulation, PWL segment structure, or
fill-order binary was changed.

---

# Fixes 5–8 — realism and framing

Four issues found while reviewing the full run output. Three are
presentation/honesty fixes; **Fix 6 is a genuine methodological weakness**
and is the only one that changed a reported number. No efficiency value,
device rating, price or emission factor was changed in any of them.

## Protected values — re-verified after all four

| Check | Value | Status |
|---|---|---|
| Cases 1–4 **cost / CO2 / peak** | $176.37 / $50.61 / $50.49 / $49.74; 366.1 / 157.0 / 147.9 / 147.9 kg; 45.6 / 105.1 / 105.5 / 103.8 kW | unchanged |
| Case 5 PWL benefit | 0.20% delivered / 1.47% gate | unchanged |
| Segment sweep, all columns | n=1 gap −4.36%, n=2 gap +24.80%, Optimism −0.1018 / +0.0058 | unchanged |
| IEEE 33-bus | 202.677 kW, 0.9131 pu at bus 18 | unchanged |
| `ieee33_data.m` assertions | 3715 kW / 2300 kVAr | pass |
| Fill-order, normal runs (both target prices) | silent | pass |
| Fill-order, LP relaxation | fires: `PH2seg(2)=4.576272 > 0 while PH2seg(1)=4.576272 < w(1)=30` | still fires |
| All seven `main_month*.m` | run end-to-end | pass |

Only `unmetE` and `violHrs` moved, and only in Fix 6 — by construction,
as shown below.

## Fix 5 — `eta_PV = 0.97` was labelled as something physically absurd

**What was wrong.** The Month 1 graph output read literally as *"a PV
array converts the solar resource at 100%, and the whole
solar→electricity chain runs at 97%"*:

```
e1: Solar_in -> PV_out    eta=1.000  PV1: solar resource -> PV array
e2: PV_out -> Elec_Bus    eta=0.970  PV1: PV array output -> elec bus
```

Real PV modules convert 15–22%, so this stops any reader with a PV
background immediately.

**The value is correct and unchanged.** `forecast_profiles.m` defines
`solar_DA = max(0, 50*sin(...))`, already the array's **DC electrical
output** (a ~50 kW-peak array), not irradiance. So 0.97 is correctly an
**inverter/DC-DC converter** efficiency applied to power that has already
been generated. Only the naming misrepresented the model boundary.

**Changed (naming and comments only):** node `Solar_in` → `PV_DC_in`;
edge descriptions now read "PV array DC output → inverter input" and
"inverter DC→AC → electrical bus (converter eff.)"; `eta_PV` comments in
both parameter files state it is the inverter efficiency and that
module-level solar→DC conversion (~15–22%) is upstream of the boundary
and embedded in the solar profile; `forecast_profiles.m` gains a MODEL
BOUNDARY note; `README.md` gains a matching note.

The input **label** `P_solar_<name>` was deliberately left alone — it is
string-matched in six call sites across Months 1–2, and the brief's own
instruction was not to break anything for the sake of a rename.

## Fix 6 — the reliability threshold was derived from the case it scored

**What was wrong.** `feederCap = feederCapMargin * C4.dayaheadPeakImport`
— Case 4's **own** day-ahead peak. Case 4 then scored 0.00 violations
while Cases 2 and 3 breached it. The metric on which the proposed system
wins was measured against a threshold the proposed system defined.
`main_month4b` did the same against its own nominal design point.

**Why this was low-risk, verified before and after.** `feeder_capacity.m`
is consumed **only** by `reliability_check.m`, after every case has been
simulated. It never enters `simulate_multiscale_day` or any dispatch
constraint, so it **cannot** move cost, CO2 or peak — only `unmetE` and
`violHrs`. Confirmed: Cases 1–4 cost/CO2/peak byte-identical; month4b
costs identical ($42.18→$45.06 planned, $49.86→$47.96 actual).

**New basis (default).** Sized the way a real connection is sized, from
connected load and nameplate ratings only:

```
cap = diversityFactor x (peak elec demand + EV charger
                         + battery charger + heat pump)
    = 0.85 x 123.0 kW = 104.55 kW
```

Every term is exogenous. The 0.85 diversity factor is justified by load
composition — few large controllable loads, so high coincidence — not by
the answer it produces. `'case4'` is retained for side-by-side comparison.

**Reliability under both bases:**

| Case | design `unmetE` | design `violHrs` | case4 `unmetE` | case4 `violHrs` |
|---|---|---|---|---|
| 2: Day-ahead only | 0.04 | 0.17 | 0.11 | 0.25 |
| 3: No robust reserve | 0.39 | 0.42 | 0.54 | 0.42 |
| 4: Full proposed | 0.00 | 0.00 | 0.00 | 0.00 |

**Does Case 4's advantage survive the independent threshold? YES** — 0.00
violation hours against 0.17 and 0.42.

**But the verdict is knife-edge, and the output says so.** The three
realized peaks (105.07 / 105.51 / 103.76 kW) lie within 1.75 kW, so Case
4 is the only clean case for caps in **[103.76, 105.07) kW** — a 1.31 kW
window, ~1.3% of the peak. Below 103.76 kW all three violate; at or above
105.51 kW none do. The output also flags that the design cap lands inside
that window, and that a lower diversity factor (0.75–0.80 → 92–98 kW)
would put all three in violation.

**What is robust is the ORDERING of unmet energy**, not the zero: Case 4
lowest and Case 3 highest at *every* swept threshold where anything
violates — including 90 and 95 kW, where the binary violation count stops
separating them entirely. That ranking is the defensible reliability
claim, and the script now says so.

## Fix 7 — building thermal storage is inert; the roadmap claims it as flexibility

**What was wrong.** Month 3 reported Building SOC 0.050–0.391 against
Pipe 0.050–0.938 without comment, while the roadmap deliverable claims
*both* building inertia and pipe storage as flexibility mechanisms. By
energy actually cycled — the honest metric, since a device can move once
and then sit still — the building contributes **0.26 kWh/day** against the
pipe's **72.38 kWh/day**, a factor of ~273.

**Diagnosis: displaced, not incapable.** The pipe dominates on every axis:

| Metric | Building | Pipe |
|---|---|---|
| Energy cycled (kWh/day) | 0.26 | 72.38 |
| Capacity (kWh) | 30.0 | 80.0 |
| Round-trip efficiency | 0.846 | 0.941 |
| Retention over 6 h | 0.377 | 0.783 |
| 6 h shift effectiveness | 0.319 | 0.736 |

Both sit on the same heat bus, so a cost-minimizing optimizer routes
essentially all thermal shifting through the better store. That is
correct behaviour, not a modelling failure.

**Proven by counterfactual, not asserted.** Disabling the pipe and
re-solving, the building immediately swings its full **0.050–0.950** range
and cycles **28.1 kWh/day**. Ruled out as causes: raising its
charge/discharge limit 10→20 kW moves the SOC range by 0.001 (power never
binds), and a comfort-band sweep (2/4/6/8/10 °C) shows even a 10 °C band
at 150 kWh — larger than the pipe — still cycles only ~2 kWh/day.
Capacity was never the constraint; competition was.

**Explicitly not done:** inflating the 30 kWh figure to make the
component look useful. It is physically reasoned (C_th 15 kWh/°C × a 2 °C
comfort band) and is stated as such in the output. The generalizable
finding — building thermal inertia is worth modelling when it is the
*principal* thermal store, not when it sits alongside a well-insulated
district network several times its size — is printed next to the SOC
ranges.

## Fix 8 — the 71.8% headline measures equipment, not modelling

**What was wrong.** Case 1 is grid plus a gas boiler with **no PV at
all**; Case 4 has ~412 kWh/day of free solar plus a battery, EV fleet and
heat pump. Most of the 71.8% cost / 59.6% CO2 reduction is the value of
*owning that equipment*, not the contribution of the energy-hub modelling
this thesis is about — any competently dispatched system with the same
hardware would capture most of it. The script was already explicit about
the peak-import increase and about Case 4 serving more load; it is now
equally explicit here.

**What is printed now**, directly beneath the two figures: what they
compare, that quoting them as a result of the modelling would be a
category error, and the numbers that *do* isolate this thesis's
contributions — all already computed, and appropriately smaller:

| Contribution | Isolated by | Value |
|---|---|---|
| Rolling intraday/real-time layers | Case 2 vs 4 | **+1.8%** |
| Robust reserve margin | Case 3 vs 4 | **+1.5%** |
| PWL vs constant efficiency | Case 5 | **0.20–1.47%** (utilization-dependent) |

`README.md` carries the same caveat, and its Month 4 reliability
paragraph — which still described the superseded Case-4-derived cap and
quoted pre-Fix-6 figures — was brought up to date at the same time.

## Files touched (Fixes 5–8)

- **Fix 5**: `hub_component.m`, `energy_hub_default_params.m`,
  `multiscale_default_params.m`, `forecast_profiles.m`, `README.md`
- **Fix 6**: `feeder_capacity.m` (new), `multiscale_default_params.m`,
  `main_month4a_case_studies.m`, `main_month4b_sensitivity_analysis.m`
- **Fix 7**: `main_month3_multiscale_dispatch.m`
- **Fix 8**: `main_month4a_case_studies.m`, `README.md`

No file was reorganized, moved, renamed, merged, or split; no
optimization model, MILP formulation, PWL segment structure or
fill-order binary was changed; and no efficiency, rating, price or
emission-factor value was changed.
