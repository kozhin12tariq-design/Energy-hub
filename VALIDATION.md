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

---

# Architectural unification — one hub, everything inside IEEE 33

Five tasks unifying the two previously disconnected integrations (Month
2b: hub on IEEE 33 but static and, wrongly, tripled; Month 3/4: hub
dispatched multi-scale but against a scalar cap with no network at all).

## ONLY ONE HUB EXISTS — confirmed

`main_month2b_ieee33_grid_integration.m` previously built one `busP_hub`
vector, assigned `busP_hub(sc.bus)` for buses 18, 25 **and** 33 in a
loop, then solved a single DistFlow with all three substituted — three
coexisting hubs. Fixed: each siting now starts from the pristine base
case, substitutes **one** bus, and solves alone. Grep confirms exactly
one bus is substituted per power-flow solve, in every file
(`busP_this(sc.bus)` in Month 2b, `busP(sys.hostBus)` in
`network_verify.m`). The now-meaningless "all three together" section and
its trunk-interaction narrative were removed — with one hub that
interaction cannot arise, and the script says so.

## Regression anchors — re-verified after all five tasks

| Check | Value | Status |
|---|---|---|
| IEEE 33 base (no hub) | 202.677 kW, 0.9131 pu at bus 18 | unchanged |
| `ieee33_data` assertions | 3715 kW / 2300 kVAr | pass |
| Cases 1–4 cost / CO2 / peak | $176.37/$50.61/$50.49/$49.74; 366.1/157.0/147.9/147.9 kg; 45.6/105.1/105.5/103.8 kW | unchanged |
| Case 5 PWL benefit | 0.20% delivered / 1.47% gate | unchanged |
| Curve-fit sweep | n=1 gap −4.36%, n=2 +24.80%, Optimism −0.1018 / +0.0058 | unchanged |
| Fill-order binaries | silent normally; still fire under LP relaxation (`PH2seg(2)=4.576272 > 0 while PH2seg(1)=4.576272 < w(1)=30`) | pass |
| All 8 `main_month*.m` | run end-to-end, Octave 8.4 headless, `glpk` only | pass |

Tasks 2–4 are post-hoc verification and cannot alter any dispatch. Task 5
adds an **opt-in** `p.network` block; absent it the day-ahead model is
bit-identical (default cost still 43.027729), so Cases 1–4 are untouched
by it too.

## Task 1 — one system definition, one hub

New `ieee33_system_definition.m` returns the canonical study system: the
IEEE 33 network, the ONE hub's host bus (default 18), its parameter set,
and the penetration summary.

**Scale decision, and why the hub was not scaled up.** Peak import 103.8
kW against a 3715 kW feeder is 2.79% feeder-wide, where a "no violations"
verdict would be trivial. Of the two offered remedies I took
siting-for-local-sensitivity rather than rating scale-up, because scaling
ratings changes the dispatch and moves the Case 1–4 anchors that Tasks
2–4 depend on. It is unnecessary: the hub's peak import is **115% of bus
18's own load** (173% at bus 33) and it measurably swings V(18) between
0.9120 pu (peak import) and 0.9213 pu (peak export) against 0.9131 pu
base. Penetration is reported both ways everywhere.

**Gate:** base case 202.677 kW / 0.9131 pu at bus 18; `ieee33_data`
assertions pass; exactly one bus substituted per solve.

Also corrected a claim its own numbers did not support: the script said
bus 18 gains "the most voltage headroom per kW displaced" while printing
+0.0059 pu for **both** bus 18 and bus 25. True but invisible — the gains
come from 75 kW and 320 kW displaced respectively. A pu/kW column now
makes it explicit (7.92e-05 vs 1.85e-05, **4.3×**), and the text says bus
25 is better for losses while bus 18 is better for voltage support per kW.

## Task 2 — network verification of every dispatch

New `network_verify.m` replays a completed 5-minute dispatch through the
exact backward-forward sweep. Post-hoc by necessity: `distflow_bfs` is
iterative and nonlinear and cannot sit inside a MILP. Unity power factor
documented as a stated limitation making voltages optimistic.

**Gate passed exactly:** feeding the host bus its own nominal load
reproduces **202.677 kW and 0.9131 pu at bus 18**, confirming the
substitution.

`network_verify` computes the no-hub base case itself so no caller can
quote an absolute without the reference — which matters: **21 of 33 IEEE
33 buses already sit below 0.95 pu in the published base case, 24 h/day,
with no hub present**. The raw "24.00 hours below limit" is a property of
the benchmark, not a hub-caused violation, and Month 3 says so.

The deltas that do attribute something to the hub are two-sided:

| | base (no hub) | with hub | delta |
|---|---|---|---|
| Minimum voltage | 0.9131 pu | 0.9120 pu | **−0.0011** |
| Host-bus voltage, mean | 0.9131 pu | 0.9190 pu | **+0.0059** |
| Feeder loss energy | 4864.3 kWh/day | 4615.9 kWh/day | **−248.4 (−5.1%)** |

Averaged over the day the hub helps the network; **at the one moment the
network is most stressed it does not**, because at peak import it draws
115% of the load it displaced. Cost of verification: 1.84 s for 288 power
flows.

## Task 3 — case studies with network consequences

All six cases (1–4 plus the Case 5 PWL/constant-efficiency pair) replayed
through the exact power flow.

| Case | min V (pu) | losses kWh/day | vs base |
|---|---|---|---|
| base: no hub | 0.9131 | 4864.3 | — |
| 1: Conventional | 0.9166 | 4654.4 | −209.8 |
| 2: Day-ahead only | 0.9119 | 4619.3 | −245.0 |
| 3: No robust reserve | 0.9118 | 4615.9 | −248.3 |
| 4: Full proposed | 0.9120 | 4615.9 | −248.4 |
| 5a: PWL (delivered) | 0.9124 | 4600.1 | −264.1 |
| 5b: Const-eff (deliv.) | 0.9120 | 4599.4 | −264.8 |

**Finding 1 — the cheapest dispatch is not the best for the network.**
Case 4 is cheapest *and* lowest-loss, but the best minimum voltage is
Case 1's 0.9166 pu against Case 4's 0.9120 (a 0.0046 pu gap). Reported as
"better on one network measure and worse on the other" rather than
selecting the flattering metric.

**Finding 2 — modelling error does not propagate into grid error.** PWL
vs constant efficiency differ by 0.0004 pu and 0.7 kWh/day — practically
indistinguishable — while differing 0.20–1.47% in cost. On this profile
PWL fidelity is a cost-accuracy question, not a grid-accuracy one.

**Gate:** Cases 1–4 cost/CO2/peak byte-identical.

## Task 4 — PWL segmentation study inside IEEE 33

| nSegments | min V (pu) | losses kWh/day | MILP (s) | MILP+PF (s) |
|---|---|---|---|---|
| base | 0.9131 | 4864.3 | — | — |
| 1 | 0.9156 | 4586.3 | 0.040 | 0.208 |
| 2 | 0.9173 | 4587.7 | 0.042 | 0.206 |
| 5 | 0.9173 | 4585.3 | 0.107 | 0.264 |
| 10 | 0.9173 | 4585.7 | 0.163 | 0.319 |
| 20 | 0.9173 | 4585.6 | 0.444 | 0.600 |
| 36 | 0.9173 | 4585.4 | 1.156 | 1.314 |

**The answer is the insensitive one, and it is reported.** Across a
36-fold change in PWL fidelity, minimum voltage moves **0.0017 pu** (n=2
through n=36 are identical) and loss energy **2.4 kWh/day**, while
curve-fit error falls by a factor of 349 and the realized-cost gap swings
from −4.36% to −0.00%.

Mechanism: segmentation changes how much hydrogen the fuel cell burns and
how it is costed, but the resulting change in net grid injection is small
next to the load, PV and battery flows that dominate it — and voltage
responds to the net injection, not to how it was decided.

Consequence stated directly: **a grid-focused study can use coarse PWL,
even n=1, and get essentially the right network answer.** Fine
segmentation earns its keep on cost accuracy, exactly where n=1 and n=2
are badly wrong. Accuracy in one metric does not imply accuracy in the
other.

True computational cost reported: verification adds 0.155–0.168 s, so at
n=36 the full benchmarked study is 1.314 s against 1.156 s for the MILP
alone (+14%).

## Task 5 — LinDistFlow co-optimization

New `lindistflow_sensitivity.m` plus an **opt-in** `p.network` block in
`dayahead_dispatch.m`. With one controllable injection on a radial feeder
each bus voltage is exactly affine in hub import, `V_j(I) = C_j + a_j·I`
— verified against a full LinDistFlow solve to **1e-16 pu** — so the
constraint set enters the MILP with no new variables.

**The 0.95 pu limit is infeasible, and this was checked before
assuming.** Reaching it needs the hub to *export* 352 kW at bus 18 and
1946 kW at bus 33, against ~15 kW of actual export capability. The
co-optimization instead imposes **do no harm**: no bus below its no-hub
voltage.

| | Verify-only | Co-optimized |
|---|---|---|
| Day-ahead cost | $43.0277 | $43.0306 (+0.01%) |
| Peak grid import | 104.19 kW | 90.00 kW |
| Exact min voltage | 0.9120 pu | 0.9131 pu |
| Do-no-harm (exact solver) | **NO** | **YES** |

Cost premium $0.0028/day; the cap binds in 1 of 24 hours.

**LinDistFlow is optimistic** — +0.0056 pu at the host bus (24/24 hours),
0.0064 pu on the base case, high at 32 of 33 buses. It does not bite here
for a specific reason, stated rather than glossed: the do-no-harm floor
sits at the same operating point in both models (import = the nominal
load replaced), so both return their own base-case voltage there and the
error cancels at the binding point. A hard 0.92 pu floor would expose the
full margin and need tightening.

**Honest scope.** One injection + radial topology + no dispatchable Q
make the 32-row constraint set collapse **exactly** to a single scalar
cap ("import ≤ the 90 kW nominal load replaced"). The apparatus is
genuine and would generalize to several interacting hubs, dispatchable
reactive power or meshed topology, but on this system it buys nothing a
well-chosen import cap could not.

## Files added / touched

- **New**: `ieee33_system_definition.m`, `network_verify.m`,
  `lindistflow_sensitivity.m`, `main_month4d_lindistflow_cooptimization.m`
- **Task 1**: `main_month2b_ieee33_grid_integration.m`
- **Task 2**: `main_month3_multiscale_dispatch.m`
- **Task 3**: `main_month4a_case_studies.m`
- **Task 4**: `main_month4c_pwl_segment_sweep.m`
- **Task 5**: `dayahead_dispatch.m` (opt-in network block only)
- **Docs**: `README.md`, `VALIDATION.md`

No folder was moved, renamed, merged or split; no efficiency, rating,
price or emission factor changed; the PWL fill-order binaries are
untouched; and no existing validation was deleted.

---

# Audit fixes + extending the segmentation study to 150

Four tasks: close the last gap outside the IEEE 33 benchmark, scope and
then empirically test the co-optimization claim, push the segment sweep
to where tractability actually breaks, and two clarity fixes.

## Regression anchors — re-verified after all four tasks

| Check | Value | Status |
|---|---|---|
| IEEE 33 base (no hub) | 202.677 kW, 0.9131 pu at bus 18 | unchanged |
| `ieee33_data` assertions | 3715 kW / 2300 kVAr | pass |
| Case 5 PWL benefit | 0.20% delivered / 1.47% gate | unchanged |
| Sweep n=1, n=2 | gap −4.36% / +24.80%, Optimism −0.1018 / +0.0058 | unchanged |
| Month 3 network deltas | min V 0.9120 pu, losses −248.4 kWh/day | unchanged |
| Fill-order binaries | silent normally; still fire under LP relaxation | pass |
| Exactly one hub | 3 bus-substitution sites, one bus each | pass |
| All 8 `main_month*.m` | run end-to-end | pass |

## Task 1 — the sensitivity analysis joins the benchmark

`main_month4b_sensitivity_analysis.m` contained **zero** references to
`network_verify` or `distflow` — the last script producing results
outside the benchmark, and the worst place for that gap, since this is
where robustness and uncertainty are stressed.

All three sweeps now report min voltage, worst bus and feeder losses.
Minimum voltage is the **worst across seeds** (for a limit, the worst
case is what matters); losses are averaged like the other energy columns.

**Answer to the question the task posed: uncertainty and reserve margin
move cost and unmet energy, NOT voltage.**

| Sweep | min V range |
|---|---|
| Reserve 0 → 2.0 | 0.9117 → 0.9122 pu |
| Uncertainty 0.5 → 3.0 (with reserve) | 0.9119 → 0.9115 pu |
| Uncertainty 0.5 → 3.0 (no reserve) | 0.9118 → 0.9115 pu |
| **Whole scenario space** | **0.0007 pu total spread** |

Negligible against the 0.0869 pu the feeder is already below nominal in
its own base case. The *direction* is consistent — the printed grid shows
minimum voltage rising left-to-right with reserve and falling
top-to-bottom with uncertainty on every row and column — so the reported
claim is "directionally as expected, practically irrelevant", not "no
effect". Mechanism: the reserve margin changes *when* energy is drawn and
how much shortfall survives to real time, but barely changes the *peak*
net injection, and peak injection sets minimum voltage. The reserve
margin is a cost/energy instrument, not voltage support.

**Gate:** every cost figure unchanged (planned $42.18/$42.60/$43.03/
$43.77/$45.06; actual $49.86/$49.48/$49.10/$48.18/$47.96), all unmetE and
violHrs identical. Runtime ~4.3 min (61 added 288-step verifications).

## Task 2 — the co-optimization claim is day-ahead only, and fails downstream

**2a — scoped.** Verified the gap is real: `p.network` has 7 references in
`dayahead_dispatch.m` and **zero** in `intraday_dispatch.m` and
`realtime_balance.m`. Every printed do-no-harm conclusion now says it
holds for the day-ahead schedule and that the rolling layers are
network-blind.

**2b — then tested, and it does not survive.** The co-optimized plan was
run through the full closed loop and its realized 5-minute injections
checked against the exact power flow, over 3 seeds × 3 uncertainty
levels — one benign scenario proves nothing here.

| seed | unc | DA cap | realized peak | min V | holds |
|---|---|---|---|---|---|
| 42 | 1.0 | 90.00 | 89.55 | 0.9131 | yes |
| 42 | 2.0 | 90.00 | 91.15 | 0.9130 | **no** |
| 42 | 3.0 | 90.00 | 93.13 | 0.9128 | **no** |
| 7 | 1.0 | 90.00 | 88.50 | 0.9132 | yes |
| 7 | 2.0 | 90.00 | 87.60 | 0.9133 | yes |
| 7 | 3.0 | 90.00 | 87.88 | 0.9133 | yes |
| 123 | 1.0 | 90.00 | 90.37 | 0.9131 | **no** |
| 123 | 2.0 | 90.00 | 93.53 | 0.9128 | **no** |
| 123 | 3.0 | 90.00 | 97.45 | 0.9125 | **no** |

**Held in 4 of 9.** The day-ahead cap is respected exactly every time,
but the realized peak reaches **97.45 kW (8.3% over)** and minimum
voltage falls up to **0.0006 pu below** the floor the constraint exists
to protect. Failures concentrate at higher uncertainty and on seeds whose
realized peak already sat near the cap — exactly what the mechanism
predicts, since intraday and real-time correct against actual conditions
with no voltage model in them.

**Consequence:** constraining only the day-ahead layer is insufficient;
do-no-harm is a property of the *plan*, not the delivered dispatch.
Extending `p.network` into intraday/real-time was deliberately not done —
the instruction was to establish empirically whether it is needed. It is.

## Task 3 — segmentation sweep extended to 150; the wall is found

Extended to `{1,2,5,10,20,36,50,75,100,150}`. New rows:

| n | MaxErrE (kW) | Planned ($) | Realized ($) | min V (pu) | losses kWh | MILP (s) | MILP+PF (s) |
|---|---|---|---|---|---|---|---|
| 50 | 0.0111 | 34.6062 | 34.6058 | 0.9173 | 4585.4 | 2.91 | 3.13 |
| 75 | 0.0061 | 34.6058 | 34.6056 | 0.9173 | 4585.5 | 11.02 | 11.23 |
| 100 | 0.0030 | 34.6057 | 34.6056 | 0.9173 | 4585.5 | 17.36 | 17.69 |
| 150 | 0.0013 | 34.6055 | 34.6055 | 0.9173 | 4585.5 | **156.69** | 156.93 |

**The wall:** n=100 → n=150 costs roughly **8–9× the time for 1.5× the
segments**, and ~112× the n=36 baseline. n=150 completes inside the 300 s
budget so it is reported as a number, but it is unambiguously where
tractability degrades.

Mechanism, not just observation: the binary count grows strictly linearly
(3576 fill-order binaries at n=150 = 24 h × 149), so a linear-cost solver
would show a linear trend. Branch-and-bound does not — as segments narrow
each binary controls a thinner slice of fuel, the LP relaxation becomes a
weaker guide to the integer optimum, and `glpk` explores
disproportionately more nodes. Cost per *segment* is roughly constant;
cost per *solve* is not.

Note the network columns are **flat from n=2 onward** (0.9173 pu, ~4585
kWh/day), reinforcing the previous session's finding that segmentation is
a cost-accuracy lever, not a grid one.

**Practical band for this system: n=10 to n=36.** Below 10 the cost error
is material; above ~36 curve-fit error is already under 0.03 kW on a 150
kW device and solve time climbs for accuracy that changes no reported
number. Huang et al.'s 30–70 band is explicitly *not* reproduced — the
output says so.

Infrastructure: 300 s per-solve budget (over-budget counts reported as a
result, not dropped); mean-of-5 timing retained where a single solve is
under 2 s so pre-existing rows keep their methodology, single sample
above, with a `samples` column stating which.

**Corrected mid-draft:** a first version asserted the n=50/n=75 timings
were "near-equal noise" — true of one run, false of the next. Every count
above n=36 is a single timed solve, so the mid-range ordering is not
stable between runs; the text now says exactly that and rests the
conclusion only on the n=100 → n=150 step, which dwarfs any contention.

**Gate:** rows n = 1, 2, 5, 10, 20, 36 byte-identical in every column
except wall-clock time.

## Task 4 — two clarity fixes

**4a — dead parameters removed.** `multiscale_default_params.m` still
defined `p.eta_FC_e = 0.45` / `p.eta_FC_th = 0.35` with a comment saying
they were unused. The comment was insufficient: a reader could reasonably
take 0.45 to be the operative efficiency. Verified nothing reads them
(the only Month 3/4 references were comment text), then **deleted** — the
preferred option — leaving an explicit note that their absence is
deliberate and that fuel-cell conversion is defined only by the PWL
curves, whose true marginal efficiency varies with load
(0.4453/0.5078/0.4578 over the segments actually used).

Month 1/2's separate `energy_hub_default_params.m` keeps its own scalars
and was deliberately **not** touched: they are read by `hub_component.m`,
`energy_hub_example_hub.m` and `main_month1...`, driving the
constant-efficiency coupling-matrix demos. Deleting those would have
broken Months 1–2.

**4b — Case 1's best voltage explained.** The network table shows the
do-nothing baseline with the best minimum voltage (0.9166 pu). Added the
mechanism: Case 1 serves heat with a gas boiler, so the only electricity
it draws at bus 18 is its own electrical load — no heat pump, no EV
charging, no battery pre-charging in cheap hours. Every hub case
electrifies heat and adds controllable load, drawing more peak current
down the long radial to the weakest bus, and minimum voltage is set by
peak current. Case 1 wins on voltage by doing less and pays 255% more in
cost and 147% more in CO2 for it.

## Files touched

- **Task 1**: `main_month4b_sensitivity_analysis.m`
- **Task 2**: `main_month4d_lindistflow_cooptimization.m`
- **Task 3**: `main_month4c_pwl_segment_sweep.m`
- **Task 4**: `multiscale_default_params.m`, `main_month4a_case_studies.m`
- **Docs**: `README.md`, `VALIDATION.md`

No folder moved, renamed, merged or split; no efficiency, rating, price
or emission factor changed (the Task 4a deletion removed unused
definitions, not values in use); fill-order binaries untouched; no
existing validation deleted.

---

# Reactive power, full-stack network constraints, and hub sizing

Three modelling upgrades, one commit each. Tasks 1 and 3 legitimately move
dispatch, cost and voltage results; every changed number is given with a
before/after and a mechanism. Task 2 changes only what the rolling layers
are allowed to do.

## Regression anchors — re-verified after all three tasks

| Check | Value | Status |
|---|---|---|
| IEEE 33 base (no hub) | 202.677 kW, 0.9131 pu at bus 18 | unchanged |
| `ieee33_data` assertions | 3715 kW / 2300 kVAr | pass |
| Curve-fit columns, n=1…150 | MaxErrE 9.1534 → 0.0013 kW at `hubScale = 1` | unchanged |
| Fill-order binaries | silent normally; still fire under LP relaxation | pass |
| Exactly one hub | one bus substituted per solve, everywhere | pass |
| Month 1, Month 2a output | byte-identical to before this session | pass |
| All 8 `main_month*.m` | run end-to-end | pass |

Everything below at `hubScale = 1, hostBus = 18` reproduces the
pre-session numbers exactly; the configuration is still reachable as
`multiscale_default_params(1.0)` + `forecast_profiles(42, 1.0, 1.0)` +
`ieee33_system_definition(18, 1.0)`.

---

## Task 1 — reactive power dispatch

The hub was modelled at unity power factor. That is not conservative, it
is unrealistic: it removes the only mechanism by which the hub could
support voltage, and it was the root cause of several negative findings.

**Added** (`multiscale_default_params.m`): `p.Inverter` with
`P_design_kW = 123·k` (non-coincident connected load, the same basis
`feeder_capacity.m` uses), `oversize = 1.15` (the smallest sensible margin
above the algebraic minimum `S ≥ P/√(1−0.44²) = 1.114·P`),
`QmaxFrac = 0.44` — **IEEE Std 1547-2018 Clause 5.2, Category B**, which
requires a DER to inject *and absorb* at least 44% of nameplate apparent
power (0.90 pf at rated P). Verified against the clause rather than
assumed. Category A's asymmetric 44%/25% was rejected as the wrong
category for a DER expected to provide voltage support.

**Linearization.** `P² + Q² ≤ S²` is a circle and cannot enter a MILP. It
is a regular 12-sided polygon **inscribed** in that circle, so the model
lies strictly inside the true limit and slightly *under*-uses the
inverter — the safe direction. Worst-case shortfall `1 − cos(π/12) = 3.4%`.

**Q reaches the network.** `network_verify.m` takes an optional fourth
argument and subtracts the dispatched Q from `busQ` at the host bus; every
caller passes it. `lindistflow_sensitivity.m` gained `b_j = −ΣX/(1000·V²)`
alongside `a_j`.

### Bugs found and fixed while doing this

| Bug | Symptom | Fix |
|---|---|---|
| **Q pinned at −Q_max** | With no cost and no active voltage constraint the optimizer is *indifferent* to Q; `glpk` returned an arbitrary vertex — full absorption in all 24 hours, which would have silently **degraded** voltage in every verify-only result | 1e−4 $/kvarh tie-breaker toward unity pf. Justified physically (reactive conduction loss) and normatively (IEEE 1547's default mode is constant pf at unity). Total effect on daily cost: **$0.000000** |
| **Sign error on the Q coefficient** | Wrote `−b_j` in the ≤-form row; Q went *negative* (−27.86 kvar) and voltage got *worse* (0.9101 vs 0.9120 pu) | `C_j` already carries the host bus's nominal reactive load, so an injection subtracts from it: `V_j = C_j + a_j·P − b_j·Q`, and the ≤-form coefficient is `+b_j` |
| **`vixQ` defined before `vix`** | Anonymous functions capture at definition time | Moved after |

### Does LinDistFlow still degenerate to a scalar cap? **No — and here is the measurement**

This was the explicit question. Under unity power factor every bus voltage
is affine and monotone in hub import, so all 32 per-bus rows were scalar
multiples of one another and the set collapsed exactly to `import ≤ L_host`.
That was an artifact of having no Q, not a property of the network.

With Q the row is `V_j = C_j + a_j·P − b_j·Q`, and the ratio `b_j/a_j` is
the X/R ratio of the branches bus *j* shares with the hub's path:

| Host bus | `b_j/a_j` range | distinct values | rows colinear? |
|---|---|---|---|
| 18 (previous) | 0.5093 – 0.8571 | 16 | **NO** |
| 25 (current) | 0.5094 – 0.7125 | **5** | **NO** |

Non-degenerate at both sitings, but **thinner at bus 25**, and that is
reported rather than glossed: from a short lateral, all 29 buses outside
it share exactly the same two trunk branches. Five independent directions
is not one, but 29 of the 32 rows are duplicates — a property of radial
topology and hub placement, not of the method.

### Before / after (at `hubScale = 1`, so this isolates Task 1)

| Quantity | Unity pf | With Q |
|---|---|---|
| Peak Q injected | 0.00 kvar | 27.86 kvar |
| Peak active import | 104.19 kW | **104.19 kW** (unchanged) |
| Exact min voltage | 0.9120 pu | **0.9138 pu** |
| No-hub reference | 0.9131 pu | 0.9131 pu |
| Day-ahead cost | $43.0277 | $43.0305 (+0.01%) |

The hub holds the floor **without curtailing active power** — the finding
the whole task existed to produce. Reactive support removes the hub's
voltage *penalty*; it does not turn a small hub into feeder-wide voltage
regulation, and that limit is printed alongside.

---

## Task 2 — network constraints at intraday and real time

`p.network` was read by `dayahead_dispatch.m` alone. The plan was
compliant and the rolling layers walked away from it: closed-loop
do-no-harm held in **4 of 9** scenarios, realized peak 97.45 kW against a
90.00 kW cap. Both `intraday_dispatch.m` and `realtime_balance.m` now
carry the voltage rows and their own inverter polygon and Q variable.

**Result at `hubScale = 1`, host bus 18: 9 of 9**, across 3 seeds × 3
uncertainty levels, under the exact power flow after intraday and
real-time correction. Cost premium **$0.0049/day (+0.009%)**. (Task 3
re-sites the hub and this test reads differently there — see Task 3's
section, which gives the magnitude rather than only the boolean.)

**Mechanism, and it is not "more constraints".** Realized peak became
101.7–109.6 kW — *higher* than the 90 kW the old day-ahead-only cap forced
— because compliance is achieved with reactive power instead of by
curtailing import. Reactive injection scaled with the disturbance, ~23 kvar
at nominal uncertainty rising to ~38 kvar at 3×.

### Three bugs found

1. **A hard real-time voltage floor is genuinely infeasible.** Real time
   must balance actual load with the fuel cell, heat pump and EV already
   fixed at intraday setpoints; when demand exceeds what the floor permits
   there is no feasible point and `glpk` returns status 10. A real
   controller cannot refuse to serve load either. The real-time floor is
   therefore **soft** (heavily penalised slack) and the residual is
   reported rather than the run dying. Day-ahead and intraday keep hard
   floors — they have the freedom to honour them.
2. **`IDX.Vsl` hardcoded to 16** while `nVar = 14` when reactive power is
   off — out-of-bounds whenever the network was enabled without the
   inverter. Optional variable indices are now assigned dynamically.
3. **A floating-point conditioning trap, found from `glpk`'s own
   diagnostic rather than guessed.** `sin(pi)` evaluates to 1.22e−16, not
   0, so the polygon rows carried a coefficient of 1e−16 beside
   coefficients of 1. `glpk` reported `min|aij|/max|aij| = 8.2e15`, its
   scaling could not recover, and it declared *"LP HAS NO PRIMAL FEASIBLE
   SOLUTION"* on plainly feasible problems — a scattered, non-monotone
   failure pattern (**22 of 78** test points) that looked like
   infeasibility and was not. Negligible trig terms are now zeroed in all
   three dispatch files; failures went **22 → 0**. Row normalisation of the
   voltage constraints was added at the same time.

### Side-finding: realized cost carries ~1% solver-vertex sensitivity

Cases 3 and 4 realized cost moved ($50.49 → $49.99, $49.74 → $49.21) even
though **Q is exactly 0.0000 kvar** in the default configuration and
day-ahead cost is bit-identical at 43.027729. Cause: the 12 polygon rows,
which never bind (net P peaks at 103.88 kW against a 136.63 kW limit),
change *which* of several cost-equivalent vertices `glpk` returns in the
degenerate intraday/real-time LPs. Verified by construction — `S_max` huge
reproduces the pre-Task-1 value exactly; `Q_max = 0` with finite `S_max`
does not. Consistent across seeds (−1.06%, −0.94%, −1.56%).

**Every realized-cost figure in this project should be read with roughly
1% tolerance**, because the intraday and real-time LPs are degenerate and
realized cost is not what they optimize.

---

## Task 3 — hub sizing

### The problem, stated precisely

At 2.79% of feeder load the hub could not move any feeder-wide quantity.
Two headline findings — *"PWL segment count does not change grid
outcomes"* (4c) and *"reserve margin does not move voltage"* (4b) — were
measured on that hub, so **neither sweep could have come out any other
way**. They were reporting the hub's size, not the mechanism each claimed
to study.

### The choice: option (b), re-site to bus 25 and scale

Option (a) — size the hub against bus 18 — is where it already was
(104 kW peak = 115% of that bus's 90 kW load), so it would have left both
findings exactly as untestable as before.

**Why the host bus decides the size.** The do-no-harm floor for a hub at
bus *h* is, per monitored bus *j*,
`C_j + a_j·P − b_j·Q ≥ C_j + a_j·L_h`, and dividing by `a_j` (negative)
gives

```
P  ≤  L_h + (b_j/a_j)·Q
```

The sensitivities **cancel**. The largest import a hub may draw without
harming any bus is set by `L_h` — the nominal load of the bus it replaces
— and by nothing else. Voltage sensitivity decides how much a kW *matters*;
it does not decide how many kW are *allowed*. Bus 18 can therefore never
host a feeder-relevant hub.

| Bus | `a_h` (pu/kW) | `L_h` (kW) | `|a_h|·L_h` (pu) |
|---|---|---|---|
| 18 | −6.90e−05 | 90 | 0.0062 |
| 25 | −1.77e−05 | 420 | **0.0074** |
| 32 | −3.93e−05 | 210 | 0.0083 |

Near-identical **local** authority from very different sizes; utterly
different feeder-wide. Bus 32 edges both out but sits on the same lateral
as bus 33, which Month 2b uses as its deliberately adverse siting; bus 25
is the feeder's largest single load and the bus the siting study already
identified as best for losses.

**The scale factor is derived, not chosen**:
`hub_sizing().scale = L(25)/L(18) = 420/90 = 4.6667`. The hub's size
*relative to its host* is unchanged (peak import stays 115.3% of host-bus
load, the do-no-harm cap binds by the same relative margin); only its size
*relative to the feeder* moves. One variable, and it is the one the sweeps
could not resolve.

**What was scaled** (extensive only): `PWL.FC_H2_max`, `HeatPump.Pmax`,
`Inverter.P_design_kW` (hence `S_max`, `Q_max`), `Emax`/`Pch_max`/`Pdis_max`
for battery, EV, building and pipe, and the `solar`/`Lelec`/`Lheat`
profiles. **What was not**: every efficiency, every efficiency curve, every
SOC band, every self-discharge rate, every price, every emission factor,
every reserve fraction, the diversity factor, `eta_PV`, `COP`, `Qcost`.

Scaling `FC_H2_max` leaves the curves untouched by construction:
`pwl_utils('fit')` samples η at load *fractions*, so every breakpoint
coordinate scales and every segment **slope** is bit-identical
(max |Δslope| = 1.1e−16 across all five segments).

### Verified: the model is exactly homogeneous of degree 1 in hub size

With no network constraint active, multiplying every rating and profile by
*k* multiplies every power, energy and cost by *k* exactly:

| Quantity | `hubScale = 1` | `hubScale = 4.6667` | ratio (expect 4.666667) |
|---|---|---|---|
| Planned cost | 43.027729 | 200.796081 | 4.66666700 |
| Realized cost | 49.207270 | 229.633941 | 4.66666700 |
| CO2 | 148.0364 | 690.8365 | 4.66666700 |
| Day-ahead peak import | 104.1882 | 486.2115 | 4.66666700 |
| Realized peak import | 103.8826 | 484.7853 | 4.66666700 |
| Fuel-cell fuel | 111.9574 | 522.4681 | 4.66666700 |

**This is the control that makes the study interpretable**: any difference
the re-siting produces is attributable to the *network*, because nothing
else in the model responds to size at all.

### Penetration, before and after

| | Before | After |
|---|---|---|
| Host bus | 18 | 25 |
| Host-bus load | 90 kW | 420 kW |
| Hub peak import | 103.8 kW | **484.2 kW** |
| **% of 3715 kW feeder** | **2.79%** | **13.03%** |
| **% of host-bus load** | **115.3%** | **115.3%** (by construction) |
| Base voltage at host bus | 0.9131 pu (feeder minimum) | 0.9694 pu |

### Two bugs the re-sizing exposed

Both were **latent before this session** and are fixed at the source.

**1. The EV state-of-charge bound was unenforceable while the fleet was
away.** At the larger size the intraday optimizer found it worthwhile to
run the EV fleet to exactly `SOCmin = 0.20` in the last plugged-in slot of
the morning — legal. One slot later the fleet departs, `Pch` and `Pdis` are
both bounded to zero, self-discharge takes the state to 0.19990, and
`glpk` reported *"PROBLEM HAS NO PRIMAL FEASIBLE SOLUTION"*: a decision
feasible at step *k* made step *k+1* infeasible.

The bug is not the size. `SOCmin` is an **operational** limit and an
operational limit can only be honoured by an action; while the fleet is
away the SOC row contains no decision variable at all, so imposing the
band there does not constrain a choice, it asserts that self-discharge does
not happen. `ev_soc_bounds.m` now returns the physical `[0, 1]` while the
fleet is away and the usable band while it is plugged in. Cost of the
relaxation, quantified: over the whole 11-hour absence free decay removes
2.2% of the state, so a vehicle departing at the 20% floor returns at
about 19.6% — the bound is loosened by at most ~0.4 percentage points, only
while nothing can be done about it, and `Pdis` is zero throughout.

**2. `sqrt()` of a negative zero made an entire cost calculation complex.**
This one silently corrupted a reported finding, so it gets the full
account.

The electrical efficiency curve is `η(u) = 0.30 + 0.35·√u − 0.28·u²`. A
MILP solver routinely returns `−1.19e−13` for a variable that is really
zero, so `u` can be very slightly negative and **one** such element makes
the whole output array complex. Octave's `max(X, 0)` on a complex array
does not compare real parts — it compares **magnitudes**. So the standard
idiom for splitting a net exchange,

```matlab
Pimp = max(Pnet, 0);   Pexp = max(-Pnet, 0);
```

returned `Pimp = −1.29` for `Pnet = −1.29 + 0i`, because `|−1.29| > |0|`.
A 4.4 kWh export was priced as a 4.4 kWh import at the evening tariff. No
error, no warning — just a plausible-looking wrong number, and it appeared
only when the LP happened to return a *negative* zero rather than a
positive one, which is why it surfaced when the hub was re-sized and not
before.

**Consequence: the "nSegments = 2 outlier" is withdrawn.**

| n | Gap(%) as reported | Gap(%) corrected | Optimism |
|---|---|---|---|
| 1 | −4.36 | −4.36 | −0.1018 |
| **2** | **+24.80** | **+1.45** | +0.0058 |
| 5 | −0.12 | −0.12 | −0.0025 |
| 10 | −0.02 | −0.02 | −0.0004 |

23.35 of those 24.80 percentage points were arithmetic. The row was
reported for several sessions as "a genuine outlier — worse than n=1",
with an explanatory section built on top of it. It was not an outlier:
`|gap|` now falls **monotonically** with segment count. What survives is
the part that was actually load-bearing — **the sign of Optimism still
predicts the sign of Gap in every row**. Fixed at the source in
`fc_true_output.m`, which clamps the fuel vector at zero (a fuel cell
cannot consume negative fuel) so no downstream quantity can be complex.

The correction applies at **both** hub sizes; it is a bug fix, not a size
effect.

### Did the flat findings become visible? **No — and that is the result**

This is what Task 3 existed to determine, and the instruction was to say so
if they stayed flat.

**Month 4b — reserve and uncertainty vs. voltage:**

| Measure | Before (2.79% hub) | After (13.03% hub) |
|---|---|---|
| Feeder-minimum V span, all 3 sweeps | 0.0007 pu | **0.0002 pu** |
| Host-bus V span, all 3 sweeps | not measured | **0.0007 pu** |
| Feeder loss-energy span | not measured (added this session) | 1.8 kWh/day (on 4516) |

A 4.7× larger hub produced a *smaller* feeder-minimum span, because the bus
that can host a big hub is electrically far from the bus that sets the
feeder minimum. **Host-bus voltage was added to close that objection** —
the hub's own bus spans 0.0007 pu across the same sweeps, so the
insensitivity is not an artifact of measuring at the wrong place. The
direction remains consistent and physically sensible (more reserve raises
voltage on every grid row, more uncertainty lowers it down every column):
"directionally as expected, practically irrelevant", not "no effect".

**Month 4c — PWL fidelity vs. grid outcomes:**

| Measure | Before | After |
|---|---|---|
| Min-V span across n=1…150 | 0.0017 pu | **0.0004 pu** |
| Loss-energy span | 2.4 kWh/day | 2.9 kWh/day |
| Curve-fit error range | 9.1534 → 0.0013 kW | 42.7160 → 0.0061 kW |

Same conclusion, now with teeth: PWL fidelity is a **cost-accuracy**
instrument, not a network one. Previously that was guaranteed by the hub's
size; now it is a finding.

**And a third claim survived a real test.** Month 4d's "a 0.95 pu floor
everywhere is structurally infeasible" needed the hub to export 352 kW
(bus 18) / 1946 kW (bus 33) at the old siting against ~15 kW of capability.
At the new siting it needs 7942 kW / 7066 kW against 551 kW — still an
order of magnitude short.

### What legitimately moved, with mechanisms

| Quantity | Before | After | Mechanism |
|---|---|---|---|
| Case 1 cost / CO2 | $176.37 / 366.1 kg | $823.08 / 1708.5 kg | pure 4.667× scaling |
| Case 4 cost / CO2 | $49.21 / 148.0 kg | $229.63 / 690.8 kg | pure 4.667× scaling |
| Case 4 vs Case 1 saving | 72.1% | **72.1%** | ratio, scale-invariant |
| Feeder capacity (design) | 104.55 kW | 487.90 kW | 0.85 × scaled connected load |
| Case 4 realized peak | 103.88 kW | 484.79 kW | pure scaling |
| Feeder loss reduction vs. no hub | −248.3 kWh/day (5.1%) | **−348.8 kWh/day (7.2%)** | the hub displaces a 420 kW load carried by trunk branches that serve the whole feeder, not a 90 kW load at the end of one radial |
| Min voltage with hub | 0.9120 pu (at host bus 18) | 0.9128 pu (at bus **18**, hub at **25**) | the hub now degrades a bus on a *different lateral*, reached only through shared trunk impedance — an effect the old configuration structurally could not show, since host bus and worst bus were the same node |
| Host-bus V, mean vs. base | +0.0059 pu | +0.0064 pu | |
| Peak Q used (day-ahead, floor active) | 27.86 kvar | 129.98 kvar | 4.7× the kvar buys 0.0003 pu instead of 0.0018 pu: bus 25's `b` is 4.5× weaker, so the extra reactive power almost exactly cancels the weaker lever — the same trade `hub_sizing.m` describes from the other side |
| Case 5 PWL benefit | 0.57% / 1.66% | **0.26% / 1.47%** (delivered / gate) | the ~1% vertex sensitivity documented under Task 2 |
| Closed-loop do-no-harm | 9 of 9 | **0 of 9 at a 1e−9 pu tolerance**, worst shortfall **2.89e−06 pu** | see below |
| n=150 MILP solve time | 169.1 s | 30.1 / 36.3 / 61.7 s on three repeats | *identical* MILP structure, different numbers — branch-and-bound instance sensitivity, plus 2× run-to-run variance on the very same instance; see below |

### The two results that need more than a row

**Do-no-harm went from 9 of 9 to 0 of 9, and the magnitude is the whole
story.** The worst shortfall across all nine scenarios is **2.89e−06 pu**
— about 37× `distflow_bfs`'s own 7.9e−08 pu convergence floor, so
resolvable rather than noise, but **2208× smaller than LinDistFlow's own
6.38e−03 pu base-case error**.

*Why it flipped.* At bus 18 the hub sat **on** the binding bus: the floor
and the achieved operating point were evaluated at the same node with the
same large linearization bias, the bias cancelled, and a comfortable
+7e−04 pu true margin was left. At bus 25 the binding bus is still 18, on a
different lateral, reached only through two shared trunk branches —
`dV(18)/dP = −3.65e−06 pu/kW`, twenty times weaker. The constraint no
longer clamps the schedule comfortably *inside* the floor; it clamps it
almost exactly *on* it, and the quadratic term LinDistFlow drops then lands
a few parts per million on the wrong side.

*The tolerance has deliberately not been widened.* The 1e−9 pu test was
always far tighter than the model's own accuracy; what changed is that the
margin is no longer large enough to hide that. The scripts now print the
**signed margin** next to the boolean, because the boolean alone hides the
constraint's entire effect: verify-only misses the floor by 2.79e−04 pu and
co-optimized by 1.32e−06 pu, so the constraint removes **99.5%** of the
harm. The honest statement is *"the floor is held to within 3e−06 pu"* —
not "held", and not "failed". **A guarantee stated in LinDistFlow terms
cannot be tighter than LinDistFlow**, and the re-sizing is what finally made
that visible.

**The tractability wall is not where a single timed solve says it is.**
Two independent sources of variance, both measured:

- *Across instances*: n=150 took **169.1 s** before the re-sizing and
  **30.1 s** after — same variables, same rows, same 3576 fill-order
  binaries, only different numbers in them.
- *Across runs of the identical instance*: three executions of the unchanged
  script returned **30.1 s, 36.3 s and 61.7 s** at n=150 — a 2× spread from
  machine state alone, which lands directly on the number because every
  count above n=36 is a single timed solve.

The superlinear shape reproduces every time and is the result. The specific
second count is not, and quoting "149.7 s at n=150" (as `README.md`
previously did) overstates what one timed solve can establish. Both the
script and the README now report the shape and the variance instead.

### Scale-dependent constants that had to be fixed

Three quantities were "effectively unbounded placeholders" or penalty
weights that did **not** scale, and would have silently become real
constraints — or silently weakened — as the hub grew. All now scale via
`hub_scale_of(p)`:

| Constant | Where | Why it must scale |
|---|---|---|
| `GRID_CAP = 1000` | all three dispatch files | a placeholder that does not scale stops being a placeholder at some size |
| `vPenalty = 1e4` | `realtime_balance.m` | competes against energy-cost terms that are proportional to hub size |
| `trackWeight = 30` | `simulate_multiscale_day.m` | multiplies a *dimensionless* SOC against cost terms that scale, so a bigger hub would silently track its own plan more loosely |

Scaling them is what makes the homogeneity check above come out exact, and
therefore what makes the re-siting a controlled comparison rather than a
confounded one.

### Narrative corrections forced by the move

Stale text that its own numbers contradicted, found by reading the output:

- Month 3 said losses fall because of "less current on the long radial to
  bus 18" — the hub is no longer on that radial. Rewritten to the actual
  mechanism (trunk branches serving the whole feeder) and extended with the
  remote-bus degradation finding.
- Month 3 said "worst moment leaves bus *25*" while printing bus 18 as the
  worst bus. Now uses the measured bus.
- Month 3's "raising the building's limit from 47 to 20 kW" — a hardcoded
  scale-1 counterfactual against a scaled rating. Now expressed as a
  factor, with the homogeneity result as the justification for why a
  factor-based counterfactual transfers exactly.
- Month 4a's reliability threshold sweep used a hardcoded `[90 95 100 106
  110]` kW list that sat entirely below every case's peak after scaling.
  Now expressed as fractions of the design capacity, so it brackets the
  peaks at any hub size.
- Month 4a quoted "Case 5 (0.20%–1.47%)" as a literal in two places — a
  number that had already gone stale under Task 2 before this session
  touched it. Both now read the computed values; the one in the header
  comment was removed entirely rather than re-pinned.
- Month 4d's closing paragraph still claimed the constraint "collapses to a
  scalar" and was "enforced only on the day-ahead layer" — both fixed by
  Tasks 1 and 2, and both left contradicting the corrected sections above
  them. Rewritten with what actually remains.
- `README.md`'s Month 4c/4d sections still described the pre-reactive-power
  model throughout (4 of 9, day-ahead only, scalar cap). Rewritten.

## Files touched

- **Task 1**: `multiscale_default_params.m`, `dayahead_dispatch.m`,
  `network_verify.m`, `lindistflow_sensitivity.m`,
  `main_month3_multiscale_dispatch.m`, `main_month4d...m`
- **Task 2**: `intraday_dispatch.m`, `realtime_balance.m`,
  `simulate_multiscale_day.m`, `main_month4d...m`
- **Task 3**: new `hub_sizing.m`, `hub_scale_of.m`, `ev_soc_bounds.m`,
  `fc_true_output.m`; `multiscale_default_params.m`, `forecast_profiles.m`,
  `ieee33_system_definition.m`, all three dispatch files,
  `simulate_multiscale_day.m`, `main_month2b...m`, `main_month3...m`,
  `main_month4a...m`, `main_month4b...m`, `main_month4c...m`,
  `main_month4d...m`
- **Docs**: `README.md`, `VALIDATION.md`

No folder moved, renamed, merged or split. Exactly one hub throughout. No
efficiency, efficiency curve, price or emission factor changed by any of
the three tasks. No existing finding removed, softened or buried — one was
**withdrawn as a bug** (the n=2 outlier), with the arithmetic that caused
it documented in full.

---

# Seasonal realism, statistical confidence, and clearer comparisons

Five tasks. Tasks 1 and 2 carry most of the value and both are complete;
Tasks 3–5 are complete as well.

## Regression anchors — re-verified after all five tasks

| Check | Value | Status |
|---|---|---|
| IEEE 33 base case (no hub) | 202.677 kW, 0.9131 pu at bus 18 | unchanged |
| `ieee33_data` assertions | 3715 kW / 2300 kVAr | pass |
| Curve-fit columns n=1…150 | MaxErrE 42.7160 → 0.0061 kW | unchanged |
| Segment-sweep gaps n=1 / n=2 | −4.36% / +1.45% | unchanged |
| Fill-order binaries | silent normally; still fire under LP relaxation | pass |
| LinDistFlow degeneracy check | still reports **NO** | pass |
| `'shoulder'` reproduces the old profiles | max \|Δ\| = **0.000e+00** on solar, Lelec, Lheat | exact |
| Shoulder Case 1–4 costs | 823.08 / 236.19 / 235.66 / 229.63 | unchanged |
| Exactly one hub | one bus substituted per solve, everywhere | pass |
| All `main_month*.m` | run end-to-end (now 12 scripts) | pass |

---

## Task 1 — seasonal scenarios

### Sourcing, labelled per number

`season_profile_factors.m` tags every factor `[SOURCED]`, `[GEOMETRY]` or
`[ASSUMED]`, because a reader is entitled to know which is which.

| Quantity | Basis | winter / shoulder / summer |
|---|---|---|
| Seasons, representative days | **[SOURCED]** BDEW/VDEW SLP seasons | 15 Jan / 15 Apr / 15 Jul |
| Electrical demand | **[SOURCED]** BDEW H0 dynamisation polynomial `f(t) = −3.92e−10·t⁴ + 3.20e−7·t³ − 7.02e−5·t² + 2.10e−3·t + 1.24`, normalised to the shoulder day | 1.2451 / 1.0000 / 0.7785 |
| Day length | **[GEOMETRY]** 52.13°N, Cooper's declination | 7.99 / 13.64 / 16.06 h |
| PV peak | **[ASSUMED]** yields (22 / 112 / 128 kWh/kWp·month) + geometry, peak from `E = P·(2/π)·L` | 0.3091 / 1.0000 / 0.8952 |
| Space heating | **[SOURCED]** VDI 3807/2067 degree-day method; **[ASSUMED]** monthly means 0.5 / 9.0 / 18.5 °C | 1.7727 / 1.0000 / 0.0000 |

`f(105) = 1.009` — the transition day sits almost exactly at the annual
mean, so anchoring the shoulder there costs nothing. The shoulder daylight
window is held at the original 13.00 h against the geometric 13.64 h; the
0.64 h discrepancy is carried openly rather than smoothed.

The **summer PV peak is 10% below April's while summer energy is 11%
above** — at this latitude the extra yield is day length, not midday power.
That is correct and is flagged in the file so it is not read as an error.

### Per-season results (Case 4, full proposed system)

| | winter | shoulder | summer |
|---|---|---|---|
| PV available (kWh) | 369 | 1922 | 2139 |
| Electrical demand (kWh) | 3954 | 3174 | 2462 |
| Heat demand (kWh) | 3261 | 2083 | 560 |
| Realized cost ($) | 843.18 | 229.63 | 51.00 |
| Emissions (kgCO₂) | 1599.0 | 690.8 | 109.6 |
| Fuel-cell fuel (kWh) | **1552.6** | 43.5 | 0.0 |
| Peak grid import (kW) | 513.3 | 484.8 | 259.4 |
| Exact min voltage (pu) | 0.9127 | 0.9128 | 0.9138 |
| Feeder losses (kWh/day) | 4579.0 | 4515.4 | 4461.1 |
| Case 4 vs Case 1 saving | **21.0%** | **72.1%** | **90.4%** |

Storage cycled per device (kWh/day charged):

| Device | winter | shoulder | summer |
|---|---|---|---|
| Battery | 211.11 | 471.83 | 373.33 |
| EV | 422.54 | 423.32 | 207.23 |
| **Building thermal** | **55.73** | **1.24** | 0.00 |
| Pipe network | 427.72 | 337.76 | 224.94 |

### The building-storage question, answered

**It contributes in winter — and it does not take over.** Both halves are
reported because the flattering half alone would be an overclaim.

- 1.24 → **55.73 kWh/day** (45×); share of pipe throughput 0.37% → **13.0%**.
- The pipe still cycles **7.7× more** in the season most favourable to the
  building, and leads in **all three** seasons.
- Therefore *"each mechanism dominates in a different season"* is **not
  supported and is not claimed**. The statement is: **the displacement
  finding holds in every season; what changes seasonally is only whether the
  displaced device is negligible or merely secondary.**
- Winter counterfactual: with the pipe disabled the building cycles
  **164.96 kWh/day** over its full 0.050–0.950 band, 3× what it does with
  the pipe present. Displacement, not incapacity — confirmed in the season
  that most favours it.

The existing shoulder-day displacement analysis is untouched; it is now
labelled season-specific rather than deleted or weakened.

### Three claims that do not generalise

1. **The fuel cell is must-run in winter.** 43.5 kWh of fuel at the
   shoulder, **1552.6 kWh in winter at the same $7.33/kg price**. Winter
   heat demand 3261 kWh/day; heat-pump ceiling 37.3 kW × COP 3.2 × 24 h =
   **2867 kWh**; storage shifts heat but does not create it, so ~394 kWh
   cannot come from the heat pump. `multiscale_default_params.m` states the
   heat pump exists precisely so the fuel cell is *not* must-run — that
   reasoning holds at the shoulder and **fails in winter**.
2. **The 72.1% headline is a shoulder figure** (21.0 / 72.1 / 90.4%).
3. **The ablations change sign in winter** — see below.

### The ablation reversal, with the mechanism measured

| Ablation vs Case 4 (cost %) | winter | shoulder | summer |
|---|---|---|---|
| Case 2 (no rolling layers) | **−2.68** | +2.85 | +13.42 |
| Case 3 (no robust reserve) | **−0.84** | +2.62 | +6.28 |

The obvious explanation is **false and the table says so**: unmet energy is
0.00 kWh in every winter case, so all three cases meet the same demand.

Measured mechanism — **fuel substitution**:

- closed loop burns **+167.2 kWh** more hydrogen (**+$36.78**) and saves
  **$14.21** of grid cost → net **+$22.57/day**;
- the rolling layers commit more fuel cell than the day-ahead plan in *both*
  seasons (winter 1385 planned → 1553 realized; shoulder 0 → 44) because
  each 15-minute solve sees one slot ahead;
- whether that pays depends on **heat-pump saturation**: **24 of 24** hours
  at rating in winter (fuel cell is the marginal *heat* source, so the extra
  hydrogen displaces little grid electricity) versus **9 of 24** at the
  shoulder (extra output is *electrical* substitution in expensive hours,
  and pays);
- the closed loop is still **cleaner** (−25.8 kgCO₂/day), so this is a
  cost-versus-carbon trade a single-objective ablation scores as a loss.

Indicated fix (longer intraday horizon, or the day-ahead heat schedule as a
harder winter constraint) is **not implemented** — the defect was measured,
not repaired.

---

## Task 2 — statistical confidence

`main_month4e_monte_carlo.m` + `paired_stats.m`.

**Protocol:** 60 draws = 20 seeds × 3 seasons. Paired within draw (both
configurations on the same scenario), differences as a percentage of their
own baseline. Three tests: 95% t interval, 95% bootstrap percentile
interval (10 000 resamples), exact sign test. **No toolboxes** — t critical
values tabulated, bootstrap from `rand`, sign test summed in log space with
`gammaln` (`nchoosek` loses precision well before n = 60).

### Pooled

| Claim | quoted | mean | median | sd | 95% CI (t) | bootstrap | sign+ | sign p |
|---|---|---|---|---|---|---|---|---|
| PWL vs constant efficiency | 0.26 | **+1.42** | +0.99 | 1.64 | [+1.00, +1.84] | [+1.01, +1.84] | 44/60 | 3.9e−4 |
| Rolling layers on/off | 2.85 | **+3.06** | +1.39 | 7.34 | [+1.20, +4.93] | [+1.28, +4.94] | 33/60 | 0.52 |
| Robust reserve on/off | 2.62 | **+1.63** | +2.08 | 1.84 | [+1.17, +2.10] | [+1.17, +2.10] | 39/60 | 0.027 |

### Which claims are distinguishable from zero

- **PWL vs constant efficiency — YES.** All three tests agree. The pooled
  effect is *larger* than the 0.26% single-draw figure quoted elsewhere,
  because that figure came from the shoulder day where the fuel cell barely
  runs.
- **Robust reserve — YES.** All three tests agree (p = 0.027).
- **Rolling layers — NO, not in the sense the phrasing implies.** The
  interval on the *mean* excludes zero, but the direction held in only
  **33 of 60** draws and the sign test does **not** reject (p = 0.52).
  Mean +3.06% against median +1.39% is the signature of a minority of large
  positive draws carrying the average. `paired_stats` reports this as its
  own verdict category — *"MEAN nonzero but OUTLIER-DRIVEN"* — rather than
  averaging the tests into a false "significant".

### Every claim changes sign by season, and three flips are resolved

| Claim | winter | shoulder | summer |
|---|---|---|---|
| PWL vs constant | +3.52 [+3.23,+3.80] | +0.93 [+0.69,+1.17] | **−0.20 [−0.34,−0.05] reliable cost** |
| Rolling layers | **−3.77 [−4.28,−3.25] reliable cost** | +1.38 [+0.33,+2.43] outlier-driven | +11.58 [+8.92,+14.25] |
| Robust reserve | **−0.60 [−0.68,−0.53] reliable cost** | +2.50 [+2.26,+2.74] | +3.01 [+2.32,+3.70] |

A 0/20 sign count is strong evidence **against** a claim, not weak evidence
for it. An earlier version of `paired_stats` routed that case into the
outlier-driven branch and labelled a reliable cost as an unresolved
benefit; `signOpposite` now catches it and prints
*"CONSISTENTLY OPPOSITE to the claim — a reliable COST"*.

**Scope:** these intervals cover scenario uncertainty (forecast noise,
season) only. Efficiency curves, prices, emission factors, network data and
hub size are fixed in every draw. Seasons are weighted equally, so the
pooled mean is not an annual mean, and realized cost carries ~1%
solver-vertex sensitivity of its own that the intervals partly absorb.

---

## Task 3 — the bus 18 vs bus 25 siting comparison

`main_month4f_siting_comparison.m`, one siting at a time, each against the
clean base case.

| | bus 18 | bus 25 |
|---|---|---|
| Host-bus nominal load | 90 kW | 420 kW |
| Penetration feeder / host | 2.79% / 115.3% | 13.03% / 115.3% |
| dV/dP at host | −6.902e−05 pu/kW | −1.766e−05 pu/kW |
| dV/dQ at host | −5.704e−05 pu/kvar | −1.258e−05 pu/kvar |
| Inverter reactive limit | 62.2 kvar | 290.4 kvar |
| Peak Q dispatched | 27.86 kvar | 129.98 kvar |
| Min V, unity pf | 0.9120 pu | 0.9128 pu |
| Min V, with Q | 0.9138 pu | 0.9131 pu |
| **Reactive support achieved** | **0.0018 pu** | **0.0003 pu** |
| Margin vs floor, with Q | +6.60e−04 pu | −1.32e−06 pu |
| Day-ahead cost | $43.0305 | $200.8091 |
| Loss reduction vs no hub | 251.1 kWh/day | 352.6 kWh/day |
| Closed-loop compliance | **9/9** | **0/9** |
| Worst closed-loop shortfall | 0.00e+00 pu | 2.89e−06 pu |

**The mechanism, stated as a result: siting determines whether a hub can
support voltage, and the two halves nearly cancel.** Bus 18 is 4.5× more
responsive per kvar; bus 25 hosts 4.7× more inverter. Full-output reactive
authority `Q_max × |dV/dQ|` is **0.00355 pu at bus 18 and 0.00365 pu at bus
25 — ratio 0.97**. On a radial feeder the two properties are inversely
related *by construction*: weak buses are weak because they sit at the end
of long thin laterals serving small loads.

**The compliance flip is reported with its magnitude.** 2.89e−06 pu against
a feeder already 0.0869 pu below nominal and a LinDistFlow model whose own
base-case error (6.38e−03 pu) is **2208× larger**. At bus 18 the hub sits
*on* the binding bus so the linearization bias cancels on both sides; at
bus 25 the binding bus is still 18, on a different lateral, so the
constraint clamps the schedule almost exactly *on* the floor. The tolerance
was **not** widened to make bus 25 pass.

---

## Task 4 — voltage heatmap

`main_month4g_voltage_heatmap.m`. `network_verify` now returns `Vfield`
(nBus × nSteps) and `Vbase_field`; both were already computed, so this costs
one array and no extra power flows.

Two figures — absolute voltage with the 0.95 pu contour, and the difference
against the no-hub base on a diverging scale with the zero contour — plus a
text rendering, because the repository is normally run headless.

| Measure | Value |
|---|---|
| Lowest voltage anywhere/anytime | 0.9131 pu, bus 18, 05:47 |
| Largest improvement vs no hub | +0.0090 pu, bus 25, 18:17 |
| Largest degradation vs no hub | **1.25e−06 pu** |
| Share of field improved / degraded | 93.7% / 3.3% |

**"Degrades 3.3% of the field" is true and nearly meaningless**, and the
script says so: the worst degradation is four orders of magnitude below the
0.0869 pu the feeder already sits below nominal.

**The spatial pattern is not distance from the hub.** Mean lift over the day:

| Group | mean ΔV |
|---|---|
| Buses 23–25 (hub's own lateral) | +0.00444 pu |
| Buses 4–18, 26–33 (share branches 1-2 and 2-3) | +0.00143 pu |
| Buses 19–22 (branch at bus 2, share only 1-2) | +0.00021 pu |
| Bus 1 (slack) | +0.00000 pu |

Bus 18 — the **furthest** bus from the hub — gains **6.9×** more than bus 19,
which is much nearer in hop count. What sets the lift is the series
impedance a bus *shares* with the hub's path, exactly as the LinDistFlow
sensitivity `a_j` says, here reproduced by the **exact nonlinear solver**
rather than asserted by the linear one.

---

## Task 5 — rule-based control baseline

`rule_based_dispatch.m` + `main_month4h_rule_based_baseline.m`. Same hub,
same ratings, same SOC bands, same storage state equation, same true
fuel-cell curves, same realized 5-minute profiles. Rules: charge below the
median import price, discharge above it, heat-pump-first, fuel cell only
when its rated marginal cost beats the grid or the heat balance forces it,
no look-ahead.

**Feasibility checked first:** unserved heat is 0.000 kWh in every draw, so
the cost comparison is like-for-like.

| | winter | shoulder | summer | pooled |
|---|---|---|---|---|
| Optimized ($) | 863.86 | 235.92 | 51.47 | — |
| Rule-based ($) | 1049.70 | 316.80 | 147.45 | — |
| **Penalty (%)** | **+21.5** | **+34.5** | **+189.7** | — |
| 95% CI | [+20.9, +22.2] | [+30.9, +38.1] | [+169.1, +210.4] | — |
| **Cost-weighted aggregate** | | | | **+31.50%** |
| Draws won by the optimizer | | | | **30/30** |

**This is the strongest modelling claim the project can make**, because
identical hardware on identical scenarios differs only in scheduling — it
cannot be explained away as the value of owning a battery, and it is far
better resolved than the Month 4e ablations.

Three honest qualifications:

1. **The pooled mean-of-percentages (+81.9%) is the wrong statistic** and is
   labelled as such: a summer day costs ~1/17 of a winter day, so the same
   dollar penalty is a far larger fraction of it. The cost-weighted
   aggregate (+31.5%) is what an operator would experience.
2. **The summer figure is inflated by one specific weakness of the chosen
   rule**, measured rather than asserted: midday hours sit *exactly at* the
   median tariff, so the rule never charges from surplus PV. In summer the
   heuristic exports 1329 kWh/day against the optimizer's 313 and imports
   1760 against 594 — it sells PV at $0.05 and buys it back at $0.10. A
   one-line improvement would close much of that, so **winter (+21.5%) and
   shoulder (+34.5%) are the conservative, defensible figures.**
3. **A defect in the baseline was found and fixed.** The first version let
   thermal-storage charging inflate the heat balance past the heat pump's
   capacity, which fired the *fuel cell* to fill a thermal store — burning
   hydrogen at $0.22/kWh for storage. That reported a +136% optimizer
   margin. No competent engineer would write that rule, and an unfairly
   weak baseline flatters the thesis, so charging is now capped at spare
   heat-pump capacity and the margin fell to +31.5%.

The heuristic is also **not** charged for peak demand, network impact, or
the reserve it fails to hold. On a demand-charge tariff or against the
Month 4d voltage floor the gap would differ, and this comparison does not
measure that. Peak import is a metric neither controller optimizes: the
heuristic is 4% *lower* in winter and shoulder and 73% *higher* in summer.

## Files touched

- **Task 1**: new `season_profile_factors.m`; `forecast_profiles.m`,
  `main_month3_multiscale_dispatch.m`, `main_month4a_case_studies.m`
- **Task 2**: new `main_month4e_monte_carlo.m`, `paired_stats.m`
- **Task 3**: new `main_month4f_siting_comparison.m`
- **Task 4**: new `main_month4g_voltage_heatmap.m`; `network_verify.m`
- **Task 5**: new `rule_based_dispatch.m`, `main_month4h_rule_based_baseline.m`
- **Docs**: `README.md`, `VALIDATION.md`

No folder moved, renamed, merged or split. Exactly one hub throughout. No
Sankey diagrams. No existing finding removed or softened — three were
narrowed to shoulder-season scope with the seasonal evidence attached, and
one baseline defect was fixed with the before/after margin recorded.

---

# Per-device PWL: extending it beyond the fuel cell, and measuring whether it pays

Four tasks, structured as a **gate**: Task 1 puts PWL on the heat pump and
measures it; Tasks 2 and 3 were to follow *only if* Task 1's benefit was
statistically distinguishable from zero. It was not. **Tasks 2 and 3 were
therefore not run**, which is the instructed behaviour and also the useful
one — it bounds the technique instead of extending it on faith.

## Regression anchors — re-verified after the session

| Check | Value | Status |
|---|---|---|
| IEEE 33 base case (no hub) | 202.677 kW, 0.9131 pu at bus 18 | unchanged |
| `ieee33_data` assertions | 3715 kW / 2300 kVAr | pass |
| Fuel-cell curve-fit columns n=1…150 | MaxErrE 42.7160 → 0.0061 kW | unchanged |
| Fuel-cell segment slopes (n=5) | 0.4453 0.5078 0.4578 0.3245 0.1146 | unchanged |
| Fill-order binaries, fuel cell | silent normally; still fire under LP relaxation | pass |
| Fill-order binaries, heat pump | silent normally; **newly measured** under LP relaxation | pass — see below |
| Day-ahead cost with HP PWL **off** | 200.796066487 — bit-identical to the pre-session code under `git stash` | exact |
| Seasonal realized costs with HP PWL off | 843.1808 / 229.6339 / 51.0029 | unchanged |
| Monte Carlo protocol | 60 draws = 20 seeds × 3 seasons, paired | unchanged |
| Exactly one hub | one bus substituted per solve, everywhere | pass |
| No new device | electrolyzer still Month 2a-only, absent from dispatch | pass |
| All `main_month*.m` | run end-to-end (now 14 scripts) | pass |

The bit-identity row is the one that matters most. Every device given a PWL
model below reproduces the **existing** results exactly when its PWL is
disabled, and that was checked by stashing the working tree and diffing the
numbers, not by inspection.

---

## Task 1 — heat-pump COP as a PWL curve

### The diagnosis that motivated it

PWL had been applied to exactly one device, and it was the **lowest**-throughput
converter in the hub:

| Device | Shoulder-day throughput | Had PWL? |
|---|---|---|
| Fuel cell | 43.5 kWh | yes |
| Heat pump | 634 kWh electrical | no |
| PV | 1922 kWh | no |

That is why Month 4e measured the fuel cell's PWL benefit at **−0.20% in
summer**, where the fuel cell moves 0 kWh. If throughput is what makes PWL
pay, the heat pump should be the best case available.

### The curve, sourced and labelled per number

`heatpump_curve.m`.

| Element | Basis | Value |
|---|---|---|
| Ambient dependence | **[SOURCED]** Stiebel Eltron WPL 25 ACS rating points at W35 flow: A−7 → 2.98, A2 → 4.14, A7 → 4.82 | `COP_rated(T) = 3.8926 + 0.1311·T`, reproducing all three to within 0.01 |
| Range | **[REFUSED]** extrapolation beyond the characterised −7…+7 °C | ambient **clamped** |
| Part-load shape | **[ASSUMED]**, declared not sourced — EN 14825 part-load tables for this unit were unreachable | `f(u) = (1.25 − 0.25u)(1 − e^{−u/0.08})` |

The refusal has a consequence and it is stated rather than hidden: a summer
ambient of 18.5 °C would give COP 6.3 by extrapolation, which the datasheet
does not support, and summer heat demand here is domestic hot water, which
needs a **higher** flow temperature than W35 and would therefore have a
**lower** COP, not a higher one. So ambient is clamped, shoulder and summer
share the A7 curve, and the seasonal coupling this produces is a **winter
penalty** — the physically real part — rather than a summer bonus, which
would not be.

The part-load shape is anchored at `f(1) = 1`, so the rating point is the
manufacturer's number and not a fitted one. Peak is +15% at u ≈ 0.3; the
low-load penalty is −42% at u = 0.05, from compressor cycling.

### Slope monotonicity — checked numerically, not assumed

| Season | Ambient (raw → clamped) | COP rated | Segment slopes (n = 5) |
|---|---|---|---|
| winter | 0.5 → 0.5 | 3.958 | 4.3599 **4.6825** 4.0123 3.5688 3.1672 |
| shoulder | 9.0 → 7.0 | 4.810 | 5.2985 **5.6906** 4.8761 4.3371 3.8491 |
| summer | 18.5 → 7.0 | 4.810 | 5.2985 **5.6906** 4.8761 4.3371 3.8491 |

Segment 2's slope **exceeds** segment 1's in every season, so the slopes are
**not** monotonically decreasing and **fill-order binaries are required**. The
mechanism is the low-load cycling penalty: the first slice of load is the
*least* efficient, so an LP relaxation would fill segment 2 while segment 1
sits empty and claim more heat per kWh than the machine can deliver. Same
situation as the fuel cell, same fix — but `hp.needsBinaries` carries the
verdict from a numerical test, and the dispatch files act on that flag rather
than adding binaries by reflex.

Cost of the binaries: **4 per time step, 96 over a 24-hour day-ahead solve**,
16 per intraday solve.

### Are those binaries load-bearing? Measured, not carried over

Month 4a verified this for the **fuel cell** by relaxing its ordering
indicators and catching segment 2 filling ahead of segment 1. For the heat
pump the same claim was, until this session, only a prediction from the slope
signs. `p.diag.relaxOrder` (a diagnostic flag, default off, guarded by
`isfield` so it cannot touch any existing result) leaves the indicators
continuous and nothing else changes:

| Season | MILP out-of-order pairs | LP out-of-order pairs | worst fill of segment 1 | cost LP | cost MILP |
|---|---|---|---|---|---|
| winter | 0 | **0** | none | 653.2369 | 653.2369 |
| shoulder | 0 | **3** | 2.9% (h2) | 170.8524 | 170.8560 |
| summer | 0 | **6** | 26.6% (h8) | 31.5694 | 31.6267 |

The relaxation puts load into segment 2 while segment 1 is as little as **2.9%
full** — exactly the cherry-pick the non-monotonic slopes predict — and buys
itself a cheaper day-ahead by claiming heat the machine cannot produce.

It does **not** happen in winter, and the reason is the same one that drives
the whole gate result: in winter the heat pump runs near its rating, every
segment is full, and there is no spare capacity in segment 1 to leave empty.
**The defect appears precisely at part load.** That is worth recording as a
measured seasonal contrast rather than a blanket "the binaries always fire",
which would have been the easier and wronger claim.

This is a **correctness** result and it stands whichever way the cost gate
below goes.

Applied at all three dispatch levels: day-ahead (`dayahead_dispatch.m`),
intraday (`intraday_dispatch.m` via a shared `add_heat_row` helper so both
stages cannot drift), and real-time — where the LP is electrical-only, so the
heat pump enters through the setpoint it inherits, now recorded as `res.Php5`.

### A defect in the measuring instrument, found and fixed before the gate was read

Both PWL arms have to be priced against the same physics or the comparison
measures two different heat pumps. `hp_true_curve_cost.m` does that: it takes
the electricity the schedule committed, converts it to heat through the
breakpoints the *planner* used, converts back through the *true* continuous
COP, and lets grid import absorb the difference.

The first version divided that heat shortfall by the heat pump's **current
marginal COP**. That is wrong, and wrong in a way that mattered. Covering a
shortfall means running the pump *more*, which moves it **up** its part-load
curve toward the sweet spot — so the efficiency that applies to the extra heat
is the one it reaches when ramped, not the cycling-dominated value it happens
to sit at. At `u = 0.001` the true COP is ≈ 0.002, so a **5 W** modelling
error priced through it becomes **2.6 kW** of imaginary grid import.

This was not hypothetical, and it was not small. Measured on seed 7:

| Season | intervals with heat pump on | intervals at 0 < *u* < 0.02 | \|Δelec\| from those intervals | total \|Δelec\| |
|---|---|---|---|---|
| winter | 288 | 0 | 0.000 kWh | 0.707 kWh |
| shoulder | 243 | 6 | 1.246 kWh | 2.447 kWh |
| summer | 162 | **48** | **9.034 kWh** | 12.874 kWh |

**In summer, 70% of the entire correction came from intervals where the heat
pump was doing essentially nothing** — about $2.70 on a ~$51 day, roughly 5%.
That is larger than every effect this session set out to measure, and it was
concentrated in exactly the season that decides the gate.

The fix floors the covering COP at the rated value. It is conservative in
**both** directions and therefore cannot flatter either arm: for a shortfall a
higher COP means a smaller charge, for a surplus a smaller credit. After the
fix the corrections are fractions of a dollar (winter −0.13, shoulder −0.15,
summer +0.37 on seed 7) instead of dominated by numerical noise.

**Every gate and table number below was produced after this fix.** The figures
carried in an earlier draft of these notes came from the defective convention
and have been re-measured rather than patched.

### The gate — 60 draws, paired, PWL vs a 1-segment chord of the same curve


The comparison is **PWL against a chord of the identical curve**, not against
the legacy constant. That isolates the segmentation from the curve.

| | mean % | median | sd | 95% CI (t) | 95% CI (boot) | sign+ | sign p |
|---|---|---|---|---|---|---|---|
| Benefit of HP PWL | **−0.063** | 0.213 | 1.138 | **[−0.352, +0.226]** | [−0.353, +0.217] | 40/60 | 0.013 |

**Verdict: direction consistent but the mean interval spans zero. GATE NOT PASSED.**

Per season, and this is where the pooled null comes from:

| Season | mean % | median | 95% CI (t) | sign+ | verdict |
|---|---|---|---|---|---|
| winter | +0.244 | 0.218 | [+0.203, +0.285] | 20/20 | distinguishable from zero |
| shoulder | +0.985 | 0.881 | [+0.782, +1.188] | 20/20 | distinguishable from zero |
| summer | **−1.419** | −1.267 | [−1.792, −1.045] | **0/20** | **consistently opposite — a reliable cost** |

The pooled null is not noise. It is **two resolved effects cancelling**, and
reporting only the pooled figure would hide that.

### Why the sign flips — measured, not guessed

| Season | median load *u* | frac in seg 1 | PWL err (kW) | chord err (kW) | curvature-placed err (kW) |
|---|---|---|---|---|---|
| winter | 0.970 | 0.00 | −0.143 | −2.664 | −1.551 |
| shoulder | 0.508 | 0.01 | −0.270 | −9.371 | −3.440 |
| summer | 0.124 | **0.70** | **+1.461** | −2.213 | −0.695 |

`+` means the model **over-promises** heat. This project already established
for the fuel cell that optimism and pessimism are not symmetric in cost — a
shortfall is covered at the import tariff while a surplus is only worth the
export price — so the **sign** of that column predicts the sign of the cost
penalty, and it does.

In winter the heat pump runs near its rating and crosses every segment, so
5 segments beat a chord and PWL pays. In summer the only heat demand is a flat
domestic-hot-water baseline, the pump sits at ~13% load, and it lives almost
entirely **inside segment 1** — where a uniform 5-segment fit averages the
curve's steepest rise into one wide chord of slope 5.30 against a true COP near
4.70 there. **The finer model is the more optimistic one exactly where the
device operates**, and optimism costs money.

So the failure is not "PWL does not help a heat pump". It is "uniform
breakpoints put the coarsest approximation exactly where this curve bends most,
and a device that operates only in that region is worse off with them than
without them."

### The indicated fix was tested — and it does *not* work. A retraction.

Same segment count, `'curvature'` placement (already implemented in Month 2a,
no new fitting code):

```
breakpoints at u = 0.000 0.014 0.034 0.071 0.337 1.000
slopes           = 0.976 2.863 4.795 6.067 4.447
binaries still required: yes
```

Four of five breakpoints fall below u = 0.34, and on the **approximation** side
it does exactly what it should: the summer error moves from **+1.461 kW
(optimistic)** to **−0.695 kW (pessimistic)**.

On **cost** it does not:

| | mean % | 95% CI (t) | sign+ | sign p | verdict |
|---|---|---|---|---|---|
| Curvature-placed vs chord | **−0.137** | **[−0.580, +0.307]** | 40/60 | 0.013 | **spans zero** |
| — winter | +0.068 | [+0.065, +0.071] | | | resolved |
| — shoulder | +1.733 | [+1.532, +1.934] | | | resolved |
| — summer | **−2.211** | [−2.682, −1.739] | 0/20 | | **reliable cost** |

**An earlier version of this study reported this configuration as +0.700%
[+0.394, +1.005], resolved on all three tests, and called it the fix that turns
the gate positive. That was measured with the defective covering-COP
convention, whose error fell almost entirely on summer. Corrected, the claim
does not hold and is withdrawn.** Curvature placement is now *worse* in summer
(−2.211%) than uniform placement (−1.419%).

**What survives is more interesting than what was withdrawn.** Curvature
placement is genuinely the better *fit* — it cuts the low-load over-promise and
flips the error to the safe side — and it is still the worse *cost*. Those two
coming apart is the useful finding: **a fit closer to the true curve does not
automatically buy a cheaper dispatch**, so any argument for PWL that reasons
from approximation error alone is incomplete. This project's own Month 4a
"Optimism" column made the same point about the Gap(%) column, and it reappears
here on a second device.

**One bound on that comparison, stated because it cuts toward this
conclusion.** `true_curve_cost` credits surplus heat at the same COP at which it
charges a shortfall, so a systematically **pessimistic** fit earns a systematic
credit. The chord is the most pessimistic model here and it wins in summer, so
part of that margin is the pricing convention rather than the physics. It is
left **as measured rather than re-tuned** — adjusting a convention after seeing
which arm it favours is precisely the move this session exists to avoid. The
gate verdict does not rest on it either way: **the gate spans zero under both
the defective and the corrected convention.**

### What the complexity costs

| Quantity | Value |
|---|---|
| Mean closed-loop solve time, PWL | 2.790 / 2.808 s |
| Mean closed-loop solve time, chord | 2.407 / 2.427 s |
| **Added solve time** | **+15.9% / +15.7%** |
| Added binaries, day-ahead (24 h) | 96 |
| Added binaries, per intraday solve | 16 |
| Mean HP electricity, PWL / chord | 432.7 / 455.4 kWh |
| Mean true-curve correction, PWL / chord | +0.04 / −1.98 $ |

Two figures per row are two independent solo runs. The cost statistics
reproduce **exactly** across them (−0.063% pooled, −0.137% curvature-placed,
every per-season figure identical); only wall-clock timing moves, by about
0.2 percentage points. Quote the solve-time cost as **≈+16%**, not to a
third decimal.

### Context that is *not* the gate

Curve vs the legacy constant COP 3.2: **+17.21%**, 95% CI [+15.21, +19.21],
60/60 draws. This is a **level** change, not a PWL result — the legacy model
assumed 3.2 everywhere while the sourced curve gives 4.81 at the shoulder
rating point and 3.96 in winter. A better heat pump is cheaper to run; that is
arithmetic. Quoting it as a PWL benefit would be the same category error this
project already refuses for the 72.1% headline. It is recorded because the
Month 3 and Month 4a seasonal cost figures move by this much when the curve is
enabled — which is why `p.HeatPump.usePWL` **defaults to false**, so every
pre-existing number in the repository still reproduces.

---

## Tasks 2 and 3 — deliberately not run

Task 2 (PV inverter PWL) and Task 3 (battery round-trip PWL) were gated on
Task 1 resolving positive. It did not. Per the session instructions — *"If the
benefit is not statistically distinguishable from zero, stop and report that.
Do not proceed to Tasks 2–3 on the assumption that more PWL is better"* —
neither was implemented.

This is worth stating plainly rather than as an omission. The heat pump moves
**8.4× the fuel cell's energy** at today's price and has a genuinely nonlinear
COP; it is the strongest candidate the hub contains. Neither uniform nor
curvature-placed breakpoints buy a resolvable improvement there. The prior that
"more PWL is better" is not supported, and building two more instances of it
would have produced two more unmeasured model complications rather than
evidence.

Note the gate would have failed on the corrected numbers **more** cleanly than
on the defective ones in one respect: the earlier convention made curvature
placement look like a rescue (+0.700%, resolved), which is the result that would
most plausibly have justified pressing on to Tasks 2 and 3. Corrected, that
rescue disappears. The decision not to proceed is better supported after the fix
than before it.


---

## Task 4 — the comparison table, and the decision rule it supports

`main_month4j_pwl_device_table.m`. Four configurations × **two hydrogen
prices** × 60 draws. "Constant efficiency" means a **1-segment fit of the same
curve**, never a different number, so every row shares the same physics and
differs only in how finely that physics is represented. Realized cost is
corrected to the true continuous curves in every row, on **both** the
electrical and the thermal side.

### Why the thermal correction is not cosmetic

`realtime_balance` already re-prices the fuel cell's *electricity* honestly.
Nothing re-priced **heat**. The heat balance is an equality settled at the
day-ahead and intraday levels with no real-time heat corrector, so a planner
whose thermal curve over-promises simply schedules less fuel, delivers less
heat than it believes, and is never charged for the difference.

The fuel cell's thermal curve `y(u) = (0.15u + 0.25u^1.7)·Pmax` is **convex**,
so a 1-segment chord lies *above* it at part load: the constant-efficiency
comparator over-promises heat, under-buys hydrogen, and looks cheaper than it
is. An earlier version of this table omitted the correction and reported
**every** PWL configuration as a reliable cost at today's hydrogen price. What
it was measuring was an unpriced heat shortfall in its own comparator.
`true_curve_cost.m` closes that, pricing the shortfall through the heat pump at
a covering COP floored at its rated value (see the covering-COP defect above).

### Price case 1 — H2 today ($7.33/kg), fuel cell 52 kWh/day, must-run

| Configuration | Cost ($/d) | CO2 (kg) | Solve (s) | Binaries | Benefit % | 95% CI | Resolved? |
|---|---|---|---|---|---|---|---|
| All constant efficiency | 311.44 | 791.9 | 2.108 | 0 | — ref — | — | — |
| + fuel cell PWL only | 313.74 | 791.3 | 2.440 | 96 | **−0.594** | [−0.711, −0.478] | **YES, but NEGATIVE** |
| + heat pump PWL only | 311.23 | 782.3 | 2.443 | 96 | −0.234 | [−0.484, +0.016] | no |
| All PWL | 312.76 | 782.1 | 2.818 | 192 | **−0.659** | [−0.909, −0.409] | **YES, but NEGATIVE** |
| + PV inverter PWL | NOT RUN | | | | | | gate not passed |
| + battery PWL | NOT RUN | | | | | | gate not passed |

Per season:

| Configuration | winter | shoulder | summer |
|---|---|---|---|
| + fuel cell PWL only | −0.752 [−0.94, −0.56] | −0.759 [−0.93, −0.59] | −0.272 [−0.48, −0.06] |
| + heat pump PWL only | +0.014 [−0.06, +0.09] | +0.612 [+0.42, +0.80] | −1.327 [−1.73, −0.92] |
| All PWL | −0.509 [−0.69, −0.32] | +0.219 [−0.05, +0.48] | −1.688 [−2.04, −1.33] |

### Price case 2 — H2 DOE delivered target ($2.93/kg), fuel cell 1846 kWh/day, economic

| Configuration | Cost ($/d) | CO2 (kg) | Solve (s) | Binaries | Benefit % | 95% CI | Resolved? |
|---|---|---|---|---|---|---|---|
| All constant efficiency | 286.25 | 751.3 | 2.095 | 0 | — ref — | — | — |
| + fuel cell PWL only | 274.56 | 664.7 | 2.579 | 96 | **+2.309** | [+1.681, +2.937] | **YES** |
| + heat pump PWL only | 283.77 | 732.8 | 2.491 | 96 | +0.331 | [−0.040, +0.701] | no |
| All PWL | 271.69 | 655.7 | 3.462 | 192 | **+2.975** | [+2.135, +3.815] | **YES** |

Per season:

| Configuration | winter | shoulder | summer |
|---|---|---|---|
| + fuel cell PWL only | +5.518 [+5.30, +5.73] | +1.647 [+1.41, +1.88] | −0.238 [−0.53, +0.05] |
| + heat pump PWL only | +0.809 [+0.75, +0.87] | +1.699 [+1.51, +1.88] | −1.515 [−1.89, −1.14] |
| All PWL | +6.489 [+6.27, +6.71] | +3.688 [+3.45, +3.92] | −1.252 [−1.75, −0.75] |

### Marginal contribution of each device

Price case 1:

| Marginal step | mean % | median | 95% CI (t) | sign+ | verdict |
|---|---|---|---|---|---|
| fuel cell PWL, added to all-constant | −0.594 | −0.598 | [−0.711, −0.478] | 6/60 | consistently opposite — a reliable **cost** |
| heat pump PWL, added to fuel-cell PWL | −0.062 | +0.214 | [−0.352, +0.227] | 40/60 | direction consistent, interval spans zero |
| heat pump PWL, added to all-constant | −0.234 | +0.013 | [−0.484, +0.016] | 30/60 | not distinguishable |
| fuel cell PWL, added to heat-pump PWL | −0.426 | −0.370 | [−0.534, −0.317] | 6/60 | consistently opposite — a reliable **cost** |

Price case 2:

| Marginal step | mean % | median | 95% CI (t) | sign+ | verdict |
|---|---|---|---|---|---|
| fuel cell PWL, added to all-constant | +2.309 | +1.534 | [+1.681, +2.937] | 48/60 | distinguishable |
| heat pump PWL, added to fuel-cell PWL | +0.637 | +0.933 | [+0.293, +0.981] | 42/60 | distinguishable |
| heat pump PWL, added to all-constant | +0.331 | +0.852 | [−0.040, +0.701] | 40/60 | direction consistent, interval spans zero |
| fuel cell PWL, added to heat-pump PWL | +2.619 | +1.924 | [+2.033, +3.204] | 52/60 | distinguishable |

The heat pump's marginal contribution **changes sign with the price regime**
and resolves in only one of four places (+0.637% when added on top of fuel-cell
PWL at the target price). That is the same verdict the gate reached, reproduced
on a different comparison.

### The decision rule — and what this data does not establish

Ranked by throughput × curvature, lowest first:

| cell | thru × curv | benefit % | resolved? |
|---|---|---|---|
| FC @today | 55 | −0.594 | yes |
| HP @target | 109 | +0.331 | no (spans zero) |
| HP @today | 166 | −0.234 | no (spans zero) |
| FC @target | 1961 | +2.309 | yes |

**Monotone in benefit across all four cells? NO.** An earlier draft of this
file claimed the product ordered the cases correctly; the corrected numbers say
otherwise, and the ranking is printed so the failure is visible rather than
asserted away. The heat pump's two cells run the wrong way round each other —
its product **falls** 166 → 109 while its benefit **rises** −0.234% → +0.331%.

The honest reading is narrower. **Only two of the four cells resolve**, and
both are the fuel cell's: the lowest product gives a resolved negative and the
highest a resolved positive, with both heat-pump cells unresolved in between.
That is *consistent* with the product mattering, and it is two points — far too
thin to call an ordering law. The non-monotonicity sits entirely inside the
unresolved pair, so it does not refute the hypothesis either. **It is not
settled by this data**, and reporting it as settled would be exactly the error
this session exists to avoid.

Two things the data *does* settle:

1. **Throughput is not a property of a device.** The heat pump moves *less*
   energy when hydrogen gets *cheaper* — 433 → 286 kWh/day — because at
   $2.93/kg the fuel cell runs hard and its waste heat covers demand the pump
   would otherwise serve. Two devices, one heat load; throughput is set by the
   price regime. That alone disqualifies throughput as a design-time screening
   rule, independently of any confounding.
2. **The same device, same curve, same segment count and same binaries shows a
   resolved positive or a resolved negative PWL benefit depending only on the
   price regime it is dispatched under.** So "we applied PWL" is not by itself a
   statement about anything — which is the claim this session set out to test.

What point 2 **cannot** do is separate throughput from dispatch freedom. The
fuel cell's two rows differ only in hydrogen price, and that single change
raises throughput 36× *and* flips the device from must-run to economically
dispatched. **Perfectly confounded, and no experiment in this session separates
them.** Separating them would need a run that raises throughput while keeping
the device must-run — a larger winter heat deficit at today's price would do
it. That is recorded here as the missing experiment rather than papered over.

**The four conditions, all necessary:**

1. **Throughput × curvature.** A *screen, not a score* — necessary, but shown
   above not to rank the cells monotonically.
2. **Scheduling freedom.** The optimizer must be able to *choose* the operating
   point. Stated as a condition, **not** as a proven one: this data cannot
   separate it from condition 1.
3. **Operating range.** The device must move across several segments. One
   parked inside a single segment gets nothing from the other four, and if that
   segment is the coarsest part of the fit it is actively worse off.
4. **Error direction.** The fit must err *pessimistically* where the device
   operates — the same asymmetry Month 4a established for the fuel cell,
   reappearing on a second device, which is what makes it a mechanism rather
   than a coincidence.

Conditions 3 and 4 are about **breakpoint placement, not segment count**.

### Reconciling with Month 4e

**At the shipped `nSegments = 10`**, Month 4e measures the fuel cell's PWL
benefit at **+0.94% pooled** (median +0.28%, CI [+0.47, +1.42], 32/60, sign
*p* = 0.7); this table gives **+2.6%** for the same comparison. An earlier
version of this passage cited **+1.42%**, which is the **n = 5** value — it
compared this table's n = 10 result against Month 4e's n = 5 result. Corrected.

**The verdicts differ, and that matters more than the gap.** Month 4e's figure
is **outlier-driven** at n = 10 (32/60 is a coin flip; the sign test does not
reject) while this table's is **resolved** at 54/60. One is a consistent
effect; the other is a mean carried by a minority of draws.

The thermal correction still explains the *direction* and is not reshaped to
fit: Month 4e does not charge its constant-efficiency comparator for the heat
that comparator over-promises, so 4e understates the benefit and this table,
which does charge it, reports a larger one. **What the correction does not
explain is the difference in consistency** — a thermal-accounting difference
shifts a magnitude, it does not turn 54/60 into 32/60. That part is left
unexplained rather than attributed to the correction.
The difference is the **thermal correction** described above, which Month 4e
did not apply — its constant-efficiency comparator over-promised heat and was
not charged for it. Both numbers are positive and resolved; this one is the
more complete accounting.

### What the table does not settle

It measures **cost**, under one tariff structure, on three representative days,
at one hub size. It says nothing about whether PWL is needed for
**feasibility** — and that argument is independent and stronger, measured for
both devices above.

## Files touched

- **Task 1**: new `heatpump_curve.m`, `hp_true_curve_cost.m`, `true_curve_cost.m`,
  `approx_error.m`; `multiscale_default_params.m`, `dayahead_dispatch.m`
  (HP segments + the `p.diag.relaxOrder` diagnostic), `intraday_dispatch.m`,
  `simulate_multiscale_day.m` (`res.Php5`), `forecast_profiles.m`,
  `season_profile_factors.m`, `rule_based_dispatch.m`
- **Task 1 gate**: new `main_month4i_heatpump_pwl_gate.m`
- **Tasks 2–3**: nothing — the gate did not pass
- **Task 4**: new `main_month4j_pwl_device_table.m`
- **Docs**: `README.md`, `VALIDATION.md`

No folder moved, renamed, merged or split. Exactly one hub throughout. No new
device — the electrolyzer remains a Month 2a demonstration and is absent from
the dispatch hub.

## Claims withdrawn this session

Recorded explicitly, because both were reported confidently before being
re-measured, and a reader of an earlier draft is entitled to know which way
they went.

| Withdrawn claim | Replaced by |
|---|---|
| Curvature placement rescues the gate: **+0.700%** [+0.394, +1.005], resolved | **−0.137%** [−0.580, +0.307], spans zero; *worse* than uniform in summer (−2.211% vs −1.419%) |
| Throughput × curvature **orders** the cases correctly | It does **not** order the four cells; only 2 of 4 resolve, and the unresolved pair runs backwards |
| The two devices have **comparable curvature** | The heat pump is **2.8× flatter** (0.38 vs 1.06) |
| The heat pump has **~15×** the fuel cell's throughput | **8.4×**, measured on a common 60-draw basis |

Both of the first two were artifacts of the covering-COP defect or of a
mixed-basis comparison, not of the physics. The gate verdict itself — **not
passed** — held under both the defective and the corrected convention, which is
why the decision to skip Tasks 2 and 3 stands. In fact it stands *more* firmly
after the fix: the defective numbers were the ones that made a rescue look
available.

---

# Segment count 5 → 10: the headline PWL claim no longer resolves

Commit `bd2605f` moved the default PWL segment count from 5 to 10 for both
devices, justified by the realized-cost gap converging at n = 10 (−0.02%,
against −0.12% at n = 5). This section is the re-measurement that commit
promised.

## The most important thing this change did

**The headline claim "PWL beats constant efficiency" lost its resolved
status.** It is now mean-nonzero but outlier-driven — the sign test does not
reject.

| | n = 5 | n = 10 |
|---|---|---|
| Pooled mean | +1.42% | **+0.87%** |
| 95% CI (t) | [+1.00, +1.84] | [+0.38, +1.36] |
| 95% CI (bootstrap) | [+1.01, +1.84] | [+0.39, +1.36] |
| Draws in claimed direction | **44/60** | **32/60** |
| Sign test *p* | **0.00039** | **0.7** |
| **Verdict** | **DISTINGUISHABLE from zero** | **MEAN nonzero but OUTLIER-DRIVEN** |

Both intervals still exclude zero. What collapses is the **sign test**:
32 of 60 draws is what you would get from a coin. The mean is carried by a
minority of draws with large positive differences rather than by a consistent
effect, which is exactly the pattern `paired_stats.m` exists to catch and the
same verdict the rolling-layer ablation has always carried.

**This is not a technicality and it is not being presented as one.** A benefit
that resolves at one segment count and does not resolve at another is a real
property of the method: the measured value of PWL is **sensitive to the
resolution of the PWL**. The thesis should say so. A number quoted at n = 5 and
silently contradicted at n = 10 would not survive examination.

## Where the effect went — per season

| Season | n = 5 | n = 10 | verdict change |
|---|---|---|---|
| winter | +3.52% [+3.23, +3.80], 20/20 | +3.38% [+3.08, +3.67], 20/20 | none — still resolved |
| shoulder | +0.93% [+0.69, +1.17], 19/20 | **+0.18% [−0.08, +0.44], 12/20** | **RESOLVED → NOT distinguishable** |
| summer | −0.20% [−0.34, −0.05], 5/20 | **−0.94% [−1.11, −0.78], 0/20** | still a reliable cost, **4.7× larger** |

Two seasons moved and they moved in the same direction: **against PWL**.
Shoulder fell from a resolved +0.93% to a null, and summer's reliable cost grew
from −0.20% to −0.94%. Winter is untouched. The pooled null is those three
disagreeing more sharply than before, not an absence of effect.

## The mechanism

The n = 10 fit resolves the curve's steep initial rise instead of averaging it
away. Measured in `bd2605f`: the rise above segment 1 grows from **0.0625 to
0.0749** on the fuel cell and from **0.32 to 1.80** on the heat pump. A finer
grid makes the model *more* accurate and its non-concavity *sharper*.

That cuts both ways, and here it cuts against the cost result:

1. **Where the fuel cell does not run, nothing changes.** At the shipped
   hydrogen price the day-ahead cost is **bit-identical** at n = 5 and n = 10 in
   shoulder (200.796066487) and summer, because the fuel cell never starts. The
   segment count cannot matter where the device is off.
2. **Where it runs, the finer model plans better and realizes worse.** Month 4a
   Case 5: planned cost 161.8294 → 161.5391 (closer to truth), Optimism +0.0060
   → +0.0019 (better calibrated), realized cost 178.3350 → **179.6020**, gap
   10.20% → **11.18%**.

So the comparator moved. Constant efficiency is a fixed reference; what changed
is that the PWL arm's *own* realized cost rose. A better-calibrated plan is less
optimistic, commits less fuel-cell output, and buys less of the cheap
electricity that produced the margin at n = 5 — while the real-time layer, which
re-prices the fuel cell against the true continuous curve regardless of what the
planner believed, gives back nothing for the improved planning accuracy.

**This is the same lesson v10 established on the heat pump, reappearing on the
fuel cell by a different route: a fit closer to the true curve does not
automatically buy a cheaper dispatch.** Month 4c already documents the general
form of it — `Gap(%)` is not a measure of model quality — and this is now the
second independent confirmation.

## Solve time and memory — the sweep's timing column badly understates both

The segment sweep's own `Solve(s)` column shows 0.147 s at n = 5 and 0.236 s at
n = 10, implying the change costs **+0.089 s** per day-ahead solve. **That is
the wrong number to quote**, and the reason is structural: the sweep measures
**one configuration**, and it is not the hard case.

Measured directly, across price regimes and seasons:

| Price | Season | n = 5 | n = 10 | ratio |
|---|---|---|---|---|
| today | winter | 0.249 s | 1.140 s | 4.6× |
| today | shoulder | 0.083 s | 0.128 s | 1.5× |
| today | summer | 0.081 s | 0.117 s | 1.4× |
| **doeTarget** | **winter** | **0.269 s** | **3.713 s** | **13.8×** |
| doeTarget | shoulder | 0.091 s | 0.125 s | 1.4× |
| doeTarget | summer | 0.076 s | 0.108 s | 1.4× |

**The mechanism is whether the MILP has to search.** Where the fuel cell does
not run, the extra fill-order binaries are trivially fixed at zero and the cost
is ~1.4× — the model is bigger but not harder. Where the fuel cell runs at
*part load*, the branch-and-bound tree has to resolve which of 10 segments is
active in each of 24 hours instead of which of 5, and the cost is **+3.4 s per
day-ahead solve**, roughly **40× the sweep's figure**.

Quote the **range**, not the single configuration: **1.4× where the fuel cell is
idle, up to 13.8× where it runs at part load.**

### Memory is the harder limit, and it was hit

At n = 5 this project routinely ran three scripts concurrently on a 16 GB
machine. At n = 10 that layout **OOM-kills**: `main_month4i` was killed at
**8.6 GB RSS**, and `main_month4j` followed. Four OOM kills were recorded before
the runs were re-serialised.

The growth is **not** in the day-ahead solve — that stays cheap even with both
devices' PWL enabled (0.413 s, winter, 432 binaries). It is in the **intraday
two-stage stochastic MILP**, where the scenario structure multiplies the segment
variables, and it accumulates across draws within a script.

This is a scheduling consequence rather than a model defect, and it was fixed by
running sequentially rather than by touching the model. But it belongs in the
record: **n = 10 costs memory as well as time, and the margin on a 16 GB machine
is now thin.** A study that quotes only the +0.089 s figure would leave a reader
unprepared for a job that dies at 8.6 GB.


---

# Efficiency: the fourth assessment criterion, and the conventional case wins it

The thesis brief requires assessment on cost, carbon, resilience **and
efficiency**. The first three were reported; efficiency was computed nowhere.
`hub_efficiency.m` closes that. It computes only — it reads completed
dispatches and forms ratios, solves nothing, and **every pre-existing number is
bit-identical** (verified by `git stash` diff on closed- and open-loop cost,
CO2 and peak across all three seasons).

## The headline: two efficiency numbers disagree about who wins, and both are right

| Case | Cost($) | CO2(kg) | η_hub purchased (%) | η first-law (%) |
|---|---|---|---|---|
| 1: Conventional | 823.08 | 1708.5 | 95.7 | **95.7** |
| 2: Day-ahead only | 236.19 | 732.7 | 122.2 | 92.2 |
| 3: No robust reserve | 236.24 | 691.1 | 121.0 | 92.3 |
| 4: Full proposed | 230.80 | 691.4 | **121.1** | 92.3 |

**On purchased energy the hub wins by a wide margin (121.1% vs 95.7%). On
first-law energy the conventional case is more efficient (95.7% vs 92.3%), and
that is reported plainly rather than buried.**

Above 100% is not an error. A heat pump does not create heat, it *moves* it: at
COP 3.2 it delivers heat it never bought, lifted from ambient air. A
purchased-energy ratio must therefore be allowed to exceed 100%, or it would
require pretending the ambient source does not exist. `etaHubThermo` charges the
hub for that ambient heat and is first-law bounded.

**The mechanism is conversion count.** The conventional case has two short
paths: grid electricity straight to load, and gas through one boiler at 90%.
The hub interposes a PV inverter, a fuel cell, four storage devices with
round-trip losses, and — the largest single term — **storage self-discharge of
178 kWh/day**, most of it the building thermal mass leaking at 15%/hour. Every
extra conversion costs first-law efficiency. **The hub buys its cost and carbon
reductions with thermodynamic efficiency**, and that trade is invisible unless
both numbers are printed.

This sits beside the existing result that the conventional case has the best
minimum voltage, and it is legitimate for the same reason: a hub that does more
things has more places to lose energy.

## The expected seasonal mechanism was wrong

The prior was that efficiency should peak in winter, where the codebase has
already established the fuel cell is **must-run for heat** and its byproduct
heat is fully used. Measured:

| | winter | shoulder | summer |
|---|---|---|---|
| η_hub, purchased (%) | 119.0 | **121.1** | 99.0 |
| η_hub, first-law (%) | 90.5 | 92.3 | 90.1 |
| Renewable fraction (%) | 5.6 | 41.2 | 61.2 |
| Feeder efficiency (%) | 95.1 | 95.2 | 95.2 |
| Fuel-cell fuel (kWh) | 1556.3 | 49.5 | 0.0 |

**Winter is not the peak — the shoulder is**, and the shoulder runs the fuel
cell for 49.5 kWh of fuel against winter's 1556.3.

**The fuel cell dilutes the average even when its heat is fully used.** Its two
outputs together recover roughly 75% of the hydrogen (~45% electrical + ~30%
thermal on these curves). The heat pump delivers heat at COP 3.2, i.e. ~320%
against purchased electricity. **Any hour the fuel cell displaces the heat pump
lowers the hub average**, byproduct heat notwithstanding — and winter is exactly
when the heat pump saturates and the fuel cell takes over. Byproduct heat makes
the fuel cell far better than a *boiler*; it does not make it better than the
*heat pump* it is displacing.

Summer is lowest (99.0%) for the opposite reason: heat demand is a small
hot-water baseline, so the heat pump — the only device that returns more energy
than it consumes — barely runs, and the hub reduces to PV plus grid.

## PWL changes the plan, not the realized efficiency

Cases 2, 3 and 4 span 121.0–122.2% purchased and 92.2–92.3% first-law. The
control-layer differences that move cost by several percent move **first-law
efficiency by 0.1 percentage points**. This is consistent with the standing
finding that better curve fitting does not automatically buy a better dispatch:
the layers change *when* energy flows, not how efficiently it converts.

## Definition, boundary, and the balance check

- **PV** counted as **DC before the inverter**, post-curtailment only. Counting
  it as AC would move the inverter's losses outside the boundary and flatter the
  hub by construction. Curtailed sunlight is not an input.
- **Hydrogen and gas** counted as chemical energy input.
- **Storage** is not ignored: the four stores do not return to their starting
  SOC, so the **net energy released** (E_start − E_end) is an explicit signed
  input term. The battery alone drains 40% of a 466 kWh capacity.
- **Grid export** is useful output, not negative input. `etaHubNet` reports the
  netting convention alongside, labelled rather than blended.
- **Physics uses the true continuous curves**, not the planner's PWL fit.

**Balance residual**, computed as boundary-closure losses minus losses summed
device by device (two genuinely different routes):

| | winter | shoulder | summer | Case 1 |
|---|---|---|---|---|
| Residual (kWh/day) | −68.99 | −23.72 | −2.04 | **0.000** |
| As % of input | 1.1% | 0.5% | 0.06% | 0.0% |

The conventional case closes **exactly**, which is the strongest check
available: it has no storage, no PV and no heat pump, so every term is
independently known. The hub cases close to ~1% or better, the residual coming
from storage trajectory sampling at 15 minutes against 5-minute flows.

**One error found and fixed during construction.** The first version added a
separate "dumped heat" term to the balance, which **double-counted**: the
thermal stores drain 231 kWh/day, and nearly all of it is self-discharge leakage
already charged in the self-discharge term. The balance closes on the four loss
terms alone. The thermal-node surplus is retained as a labelled diagnostic, not
as a balance term.

---

# Building thermal self-discharge: derived, and the premise for changing it was wrong

`p.Building.selfLoss` was `0.15`/h, uncited. It is now **0.1426**/h, derived
from the model's own energy balance. **The value barely moved, and the reason
matters more than the change.**

## What the state variable is

Building SOC is the thermal energy stored in the fabric **relative to the lower
comfort bound**. `selfLoss` is the passive decay of that stored excess back
toward the bound, governed by τ = C_th/UA. Without that definition
"self-discharge" for a building is ambiguous and uncheckable.

## The derivation

| Quantity | Value |
|---|---|
| C_th = Emax / band = 140.0 / 2 °C | 70.00 kWh/°C |
| Winter peak heat demand | 237.59 kW |
| less DHW baseline (summer heat, no space heating) | 27.52 kW |
| **Fabric loss** | **210.07 kW** |
| at ΔT = 20 °C room − 0.5 °C winter ambient | 19.5 °C |
| **UA** = 210.07 / 19.5 | **10.77 kW/°C** |
| **τ** = C_th / UA | **6.50 h** |
| **selfLoss** = 1 − exp(−1/τ) | **0.1426**/h |

## The claimed inconsistency does not exist

The brief argued the building "leaks at roughly twice the rate its own heat
demand implies", from a winter peak heat demand of ~136 kW giving τ ≈ 13 h.
**The model's actual winter peak heat demand is 237.59 kW.** With the correct
figure, τ = 6.50 h — against the old value's effective 6.54 h under the discrete
`(1 − selfLoss·Δt)` update. **They agree to 0.6%.**

The old value was *uncited*, not *wrong*. It is replaced so the number is
traceable, not because it was in error.

## The real problem is a different parameter, and it is out of scope

τ ≈ 6.5 h remains far below ISO 13790 / EN ISO 52016, which give ~20–30 h for
even **very light** construction. But reaching τ = 20 h at this C_th requires
UA = 3.50 kW/°C — a fabric peak of **68.2 kW against the 210.1 kW this model's
own heat profile demands, a factor of 3.1**.

So the pair (C_th, UA) describes a building with **far too little thermal mass
for its heat loss**. The mis-specified quantity is **C_th** — `Emax` = 30 kWh
per hub-unit, i.e. 15 kWh/°C — not `selfLoss`. Forcing `selfLoss` to a
literature τ while leaving `Emax` alone would **replace a self-consistent
parameter set with an inconsistent one**: the building would leak more slowly
than its own heat demand says it can. `Emax` is outside this change's scope and
is flagged here as what a future revision should address.

## The pipe: reviewed, retained, and the ordering explained

`p.Pipe.selfLoss = 0.04` (τ ≈ 24.9 h) remains **uncited and is labelled as
assumed** — a network heat-loss figure for a matching pipe diameter, burial
depth and soil conductivity was not reachable from this environment. It is left
unchanged because no sourced basis was found to change it *to*.

The building leaking ~4× faster than the pipe network is **not** an error: it is
ΔT. The fabric sits against outdoor air at ΔT ≈ 19.5 °C in winter; buried
district-heating pipes sit in soil far warmer than the air above it, so their
driving temperature difference — and therefore their fractional decay rate — is
several times smaller at the same insulation standard.

## Before/after — everything that depends on it

| Quantity | selfLoss 0.15 | selfLoss 0.1426 | moved? |
|---|---|---|---|
| Winter realized cost | 843.36 | 842.29 | −0.13% |
| Shoulder realized cost | 230.80 | 230.72 | −0.03% |
| Summer realized cost | 51.00 | 50.96 | −0.08% |
| Case 4 cost / CO2 / peak | 230.80 / 691.4 / 484.8 | 230.72 / 691.1 / 484.8 | negligible |
| Case 1 η purchased / first-law | 95.7 / 95.7 | 95.7 / 95.7 | **unchanged** |
| Case 4 η purchased / first-law | 121.1 / 92.3 | 121.1 / 92.3 | **unchanged** |
| Building cycling, shoulder | 1.24 kWh/day | **1.16 kWh/day** | still marginal |
| Building cycling, winter | — | 55.40 kWh/day | — |
| Pipe cycling, shoulder | 337.76 | 337.70 | unchanged |
| Balance residual, winter | −68.99 | −69.20 | closes |

## The three dependent findings all survive

1. **"The conventional case wins on first-law efficiency"** — unchanged at
   **95.7% vs 92.3%**. Self-discharge remains the largest single first-law loss.
2. **The displacement finding survives, in a stronger form.** The building still
   cycles **1.16 kWh/day** at the shoulder against the pipe's 337.70. It was
   fair to ask whether that was an artifact of an unjustified decay rate; it is
   not, because the rate is now derived from the model's own heat balance and
   the result barely moved.
3. **The winter counterfactual** is unaffected in kind — the building cycles
   55.40 kWh/day in winter under normal dispatch, so the capability is real and
   displaced rather than absent.

**No claim is withdrawn this time.** That is itself worth recording: the
challenge was legitimate and specific, it was tested against the model's own
numbers rather than deflected, and the parameter came out very close to where it
started for a reason that can now be checked by a reader.

---

# Chunked Monte Carlo execution: a toolchain limit, fixed exactly

The three Monte Carlo scripts could not complete at `nSegments = 10`. The cause
is a **memory leak in `glpk`'s integer solve**, not a modelling defect, and the
fix changes **how** the draws are executed, never **what** is computed.

## The leak, measured

| Test | Result |
|---|---|
| `dayahead_dispatch` × 60 | 52 MB, **flat — no leak** |
| `intraday_dispatch` × 200 | 65 → 112 MB, ~0.31 MB/call, linear |
| `simulate_multiscale_day` × 5 | 99 → 145 → 192 → 239 → **285 MB**, **~46.5 MB/day-sim, linear** |

Reproduced independently here, with `clear` between every call — the growth is
identical. The memory is held **at the C level, outside Octave's variable
space**, so `clear` cannot reach it and **only process exit releases it**.

**The failure scales with day-sim count, not problem difficulty.** `main_month4a`
runs 12 day-sims (~0.6 GB) and is fine; `main_month4e` runs 60 draws × 5
configurations = **300 day-sims ≈ 14 GB** and is not. This was survivable at
`nSegments = 5` (96 binaries/device/day) and is not at 10 (216).

## Why chunking is exact, not an approximation

The draws are independent and `forecast_profiles(seed, ...)` is seeded **per
draw**, so draw *i* is bit-identical regardless of which process computes it.
Partitioning is done over the **draw index** — the full ordered (season × seed)
list is built first, then sliced — so the union of chunks is exactly the
original 60-draw set in the original order.

Chunk files carry **raw per-draw differences only, never partial statistics**:
means and confidence intervals do not combine, so storing them would invite
someone to average them later and get a wrong answer. `paired_stats` runs once,
in `mc_aggregate`, on all draws at once.

The statistics block was **extracted verbatim** into `mc_report_month4e.m` and is
called by both paths, so identical output is guaranteed **by construction**
rather than by two implementations happening to agree.

## The acceptance test — passed

6 draws (2 seeds × 3 seasons), single process vs 3 chunks of 2, aggregated:

```
*** IDENTICAL -- byte-for-byte across the entire report ***
```

| Claim | mean | median | sd | 95% CI (t) | sign+ | p |
|---|---|---|---|---|---|---|
| PWL vs constant efficiency | 0.71 | 0.01 | 1.79 | [−1.16, +2.59] | 3/6 | 1 |
| Rolling layers | 0.66 | −1.59 | 6.18 | [−5.82, +7.15] | 2/6 | 0.69 |
| Robust reserve | 1.06 | 1.21 | 1.51 | [−0.52, +2.65] | 4/6 | 0.69 |

Every printed statistic matches to full precision, and the per-draw vectors
match element-by-element (a `diff` over the whole report section is empty).

## Completeness is enforced, and the guard was tested

Deleting one chunk and re-aggregating:

```
error: Chunk set is NOT complete -- refusing to report statistics.
  expected 6 draws, found 4 unique-or-not
  missing draw indices: [3 4]
  duplicated draw indices: []
```

A silently short Monte Carlo would understate every confidence interval in the
thesis, so this is an **error, not a warning**.

## One defect found and fixed during implementation

The script begins `clear; clc;`, which **silently wiped the chunk selectors** —
so every chunk ran the *full* draw set and printed statistics. That would have
looked like success while doing the exact opposite of chunking, and the
aggregator would then have seen 3 duplicate copies of all 6 draws. It is now
`clear -x MC_CHUNK MC_NCHUNK`, and the completeness check would have caught the
duplication regardless.

## Chunk-size budget rule

**~46.5 MB × (draws per chunk) × (configs per draw).** For `main_month4e` at 5
draws/chunk × 5 configs = 25 day-sims ≈ **1.2 GB**. 60 draws → 12 chunks.
`main_month4j` runs more configurations per draw and needs a smaller chunk.

---

# Chunking `main_month4i`: equivalence holds on every statistic

The `main_month4e` pattern applied to the heat-pump gate. Same design: chunk
selection via `MC_CHUNK`/`MC_NCHUNK`, partition over the **ordered draw index**,
raw per-draw vectors saved (never partial statistics), and the reporting block
extracted verbatim into `mc_report_month4i.m` so both paths print from one
implementation.

**Budget:** 60 draws × 5 day-sims = 300 ≈ 13.6 GB unchunked. At 5 draws/chunk
(25 day-sims ≈ 1.14 GB), 12 chunks.

## The acceptance test — and an honest qualification

6 draws single-process vs 3 chunks of 2, aggregated. The full diff is **8 lines,
and every one of them is a wall-clock measurement**:

```
< Mean closed-loop solve time, PWL                4.403 s
> Mean closed-loop solve time, PWL                4.347 s
< Added solve time                               +32.1 %
> Added solve time                               +31.0 %
```

With those excluded: **ALL STATISTICS IDENTICAL.**

**This is a weaker claim than the one made for `main_month4e`, and the
difference is stated rather than glossed.** 4e is byte-for-byte identical
because it reports no timings. 4i reports `tic`/`toc` wall-clock, which is
*measured*, not *computed*, and cannot be reproducible across processes on a
shared machine. Every computed quantity — the gate mean, both intervals, the
sign test, all per-season rows, the mechanism table, the curvature-placement
comparison — matches exactly. Claiming byte-identity for 4i would be false.

## Two defects found while applying the pattern

1. **The loop-close replacement silently missed** (`approx_error(pCurv, fcD, Ca)`
   where the patch expected `Cd`), leaving one `end` too many and a parse error.
   Caught immediately by the run rather than by inspection.
2. **The aggregator hard-coded month4e's three vectors** (`dPWL`, `dRolling`,
   `dReserve`), so it errored on any script carrying a different set. It now
   collects per-draw vectors generically, with those three treated as optional.

## Model-level diagnostics run once, not per chunk

The curve/slope check and the ordering-binary counterfactual are properties of
the **model**, not of any draw. They run in the single-process path and in
**chunk 0** only; other chunks skip them via `showDiag`. `hpRef` is a curve fit
with no solve, so it is computed on every path — the reporter needs it.

---

# The heat-pump gate at n = 10: the mean flips sign, the verdict does not

`main_month4i` had **never completed** at `nSegments = 10` — it OOM-killed at
8.6 GB. Chunked into 12 processes of 5 draws it runs to completion. This is the
first result at the shipped segment count.

## Memory ceiling held, and slightly exceeded the prediction

| | predicted | measured |
|---|---|---|
| Peak RSS per chunk | ~1.14 GB | **1.40–1.45 GB** |
| Wall clock per chunk | — | 93–142 s |
| **Total, 12 chunks** | — | **~22 min** |

Every chunk exited 0. The measured peak is ~25% above the budget rule's
estimate, so the rule is optimistic — worth stating, since a reader sizing
chunks for a smaller machine should allow headroom rather than take
46.5 MB × sims as a ceiling.

## The gate — still does not pass

| | n = 5 | n = 10 |
|---|---|---|
| Pooled mean | −0.063% | **+0.207%** |
| 95% CI (t) | [−0.352, +0.226] | [−0.177, +0.591] |
| 95% CI (bootstrap) | [−0.353, +0.217] | [−0.175, +0.579] |
| Sign test | 40/60, p = 0.013 | **40/60, p = 0.013** |
| **Verdict** | spans zero | **spans zero** |

**The pooled mean changes sign — from −0.063% to +0.207% — and the verdict does
not change.** Both intervals still span zero at both segment counts, and the
sign test is identical (40 of 60, p = 0.013) to three decimal places.

That combination is worth stating precisely, because it is easy to misread in
either direction. A sign flip in a point estimate sounds like a reversal; it is
not one here, because the estimate was never distinguishable from zero at either
segment count. **The honest summary is that refining the segment count did not
rescue the heat-pump gate, and Tasks 2 and 3 of the v10 session — PV inverter
and battery PWL — remain correctly unrun.**

Per season, all three verdicts unchanged:

| Season | n = 5 | n = 10 | verdict |
|---|---|---|---|
| winter | +0.244% | +0.250% | resolved, both |
| shoulder | +0.985% | **+1.892%** | resolved, both — nearly doubled |
| summer | −1.419% | −1.522% | reliable cost, both |

## Curvature placement gets worse, not better

| | n = 5 | n = 10 |
|---|---|---|
| Curvature vs chord | −0.137% [−0.580, +0.307] | **−0.460% [−0.803, −0.117]** |
| Verdict | spans zero | **mean nonzero but outlier-driven** (36/60, p = 0.16) |
| summer | −2.211% | **−2.127%**, reliable cost |

At n = 10 the curvature-placed interval no longer spans zero — it sits entirely
**negative**. The sign test does not reject (36/60, p = 0.16), so the verdict is
outlier-driven rather than a resolved cost, but the direction is now
unambiguous: **curvature placement is worse than uniform at this segment count.**

The mechanism is visible in the breakpoints. At n = 10 the curvature fit places
seven of ten breakpoints below u = 0.071 — `0.000 0.007 0.014 0.023 0.034 0.049
0.071 0.171 0.337 0.619 1.000` — concentrating almost all resolution in a band
the heat pump barely occupies outside summer, and leaving the 0.34–1.00 range
spanned by two wide segments. More segments made the placement heuristic's
existing bias worse rather than better.

**This does not change the v10 conclusion; it strengthens it.** The curvature
"fix" was already withdrawn after the covering-COP correction. At n = 10 it is
not merely unresolved but pointing the wrong way.

---

# The per-device PWL table at n = 10: two verdicts lost, one sign flip gained

`main_month4j` had **never completed** at `nSegments = 10` — 480 day-sims ≈
21.8 GB unchunked. Run as 20 chunks of 3 draws it completes in **42 minutes**,
peak **1255–1311 MB per chunk** against a predicted ~1.1 GB. All 20 exited 0 and
the aggregator confirmed 60 draws, complete and in order.

## Lead: two claims lost their resolved status

| Claim | n = 5 | n = 10 | verdict changed? |
|---|---|---|---|
| **All PWL @ today price** | −0.659% [−0.909, −0.409] **YES, but NEGATIVE** | **−0.428% [−0.761, −0.094] → no** | **YES — resolved cost became unresolved** |
| **Heat-pump marginal @ target** | +0.637% [+0.293, +0.981] **DISTINGUISHABLE** | **+0.320% [−0.121, +0.760] → spans zero** | **YES — resolved benefit became unresolved** |
| All PWL @ target price | +2.975% [+2.14, +3.82] YES | +2.958% [+2.08, +3.84] YES | no |
| Fuel-cell PWL @ today | −0.594% [−0.71, −0.48] YES, but NEGATIVE | −0.630% [−0.74, −0.52] YES, but NEGATIVE | no |
| Fuel-cell PWL @ target | +2.309% [+1.68, +2.94] YES | +2.615% [+2.00, +3.23] YES | no |
| Heat-pump PWL @ today | −0.234% [−0.48, +0.02] no | −0.385% [−0.65, −0.12] no | no |
| Heat-pump PWL @ target | +0.331% [−0.04, +0.70] no | +0.274% [−0.10, +0.65] no | no |

**Both changes go the same way: a claim that resolved at n = 5 does not resolve
at n = 10.** This is the third independent instance of the same pattern —
Month 4e's headline PWL claim went DISTINGUISHABLE → OUTLIER-DRIVEN, and now
two more here. The fuel cell's own claims are the ones that survive; **every
claim that involves the heat pump has now failed to resolve at the finer
segment count.**

Note the heat-pump-only row at today's price: its *interval* moved to exclude
zero (−0.653 to −0.117) while its *verdict* stayed "no", because the sign test
is 35/60 and does not reject. That is the outlier-driven pattern
`paired_stats` exists to catch, and it is why the interval alone is not the
verdict.

## One result moved the other way, and it is a sign flip

| Fuel-cell PWL @ target, **summer** | n = 5 | n = 10 |
|---|---|---|
| Benefit | −0.238% [−0.525, +0.049] | **+0.285% [+0.068, +0.503]** |
| Reading | unresolved cost | **resolved benefit** |

At n = 5 the fuel cell's summer PWL was an unresolved cost; at n = 10 it is a
resolved *benefit*. Summer is the season where the fuel cell barely runs at
today's price, but at the DOE target it does run, and the finer fit is worth
something there.

## Full pooled tables

**Price case 1 — H2 today ($7.33/kg), fuel cell 53 kWh/day, must-run**

| Configuration | Cost($/d) | CO2(kg) | Solve(s) | Binaries | Benefit% | 95% CI | Resolved? |
|---|---|---|---|---|---|---|---|
| All constant efficiency | 311.54 | 792.1 | 3.100 | 0 | — ref — | — | — |
| + fuel cell PWL only | 313.95 | 791.3 | 4.050 | 216 | **−0.630** | [−0.739, −0.520] | YES, but NEGATIVE |
| + heat pump PWL only | 311.05 | 783.3 | 4.188 | 216 | −0.385 | [−0.653, −0.117] | no |
| All PWL | 312.39 | 782.7 | 5.497 | 432 | −0.428 | [−0.761, −0.094] | no |

**Price case 2 — DOE target ($2.93/kg), fuel cell 1704 kWh/day, economic**

| Configuration | Cost($/d) | CO2(kg) | Solve(s) | Binaries | Benefit% | 95% CI | Resolved? |
|---|---|---|---|---|---|---|---|
| All constant efficiency | 286.47 | 751.9 | 3.104 | 0 | — ref — | — | — |
| + fuel cell PWL only | 274.10 | 673.1 | 5.421 | 216 | **+2.615** | [+2.001, +3.228] | YES |
| + heat pump PWL only | 284.00 | 733.5 | 4.242 | 216 | +0.274 | [−0.100, +0.647] | no |
| All PWL | 271.76 | 663.3 | 11.113 | 432 | **+2.958** | [+2.078, +3.838] | YES |

Marginal contributions at the target price:

| Marginal step | mean % | 95% CI (t) | sign+ | verdict |
|---|---|---|---|---|
| fuel cell PWL, added to all-constant | +2.615 | [+2.001, +3.228] | 54/60 | distinguishable |
| heat pump PWL, added to fuel-cell PWL | **+0.320** | **[−0.121, +0.760]** | 40/60 | **spans zero** |
| heat pump PWL, added to all-constant | +0.274 | [−0.100, +0.647] | 40/60 | spans zero |
| fuel cell PWL, added to heat-pump PWL | +2.657 | [+2.060, +3.253] | 54/60 | distinguishable |

**Solve time is the other cost of n = 10.** The all-PWL configuration at the
target price takes **11.113 s** per closed-loop day against 3.104 s for
all-constant — 3.6×, for a benefit that is real (+2.958%) but carried entirely
by the fuel cell.

## What this settles about the decision rule

The v10 decision rule said PWL pays where throughput × curvature is large **and**
the optimizer chooses the operating point. At n = 10 that reading is unchanged
and slightly sharpened: **every resolved PWL benefit in this table belongs to
the fuel cell at the price where it is economically dispatched.** The heat pump
resolves nowhere, at either price, at either segment count, on any of the four
marginal steps. Refining the model did not change which device earns its
complexity — it removed two of the weaker claims that had previously looked
resolved.

---

# Two diagnostics on the heat-pump gate: one mechanism found, one hypothesis refuted

Diagnostic only. No model behaviour, parameter or statistic was changed, and no
reported figure moved — `p.PWL.nSegments` and `p.HeatPump.nSegments` are both
still 10, verified after the session.

## Item A — the identical sign test was NOT structural. The comparison was confounded.

The proposed explanation was that the same 40 draws favour PWL at both segment
counts, making 40/60 and p = 0.013 identical by construction. **That is not what
the data shows, and the reason matters more than the hypothesis.**

Regenerating the n = 5 gate with the **current** parameter set and comparing
per-draw against n = 10:

| | n = 5 (regenerated) | n = 10 |
|---|---|---|
| Draws favouring PWL | **31/60** | **40/60** |
| Mean | **−0.331%** | +0.207% |
| Sign differs on | **9 of 60 draws** | |
| Direction of every flip | **− → + (9), + → − (0)** | |
| Correlation of per-draw `dGate` | **0.697** | |

So the sign pattern is **not** invariant to segment count — nine draws change
sign, all in the same direction — and the regenerated n = 5 sign count is
**31/60, not the 40/60 in the reported figure.**

**The historical n = 5 gate figure (−0.063%, 40/60, p = 0.013) and the n = 10
figure were produced by different parameter sets.** `bd2605f` changed the
segment count 5 → 10; **`9bf7dd3`, four commits later, changed
`p.Building.selfLoss` from 0.15 to the derived 0.1426.** The n = 5 numbers
predate that change; the n = 10 numbers postdate it. The two differ in *two*
things, not one.

**That is the real explanation of the "coincidence": it is not a coincidence
and it is not structural — it is an artifact of comparing across a parameter
change.** With parameters held fixed, moving 5 → 10 shifts the mean from
−0.331% to +0.207% and the sign count from 31/60 to 40/60. The identical 40/60
in the two published figures is an accident of the confound.

**This does not invalidate either published figure** — each is correct for the
parameter set that produced it, and the gate verdict (spans zero) is the same
in every version measured. What it invalidates is reading the *pair* as a clean
segment-count comparison. Any future n = 5 vs n = 10 statement on this gate
should quote the regenerated n = 5 value of −0.331% [31/60], not the historical
−0.063%.

## Item B — shoulder doubled because it is the only season that traverses the curve

Confirmed, with the decisive quantity: **how many PWL segments the dispatch
actually occupies.**

| Season | median *u* | IQR width | range | segments occupied, n=5 | n=10 | gate change |
|---|---|---|---|---|---|---|
| winter | 0.919 | 0.165 | 0.549–1.000 | 3 of 5 | **5 of 10** | +0.006 (static) |
| shoulder | 0.525 | 0.249 | 0.163–0.927 | **5 of 5** | **9 of 10** | **+0.907 (doubled)** |
| summer | 0.257 | 0.298 | 0.000–0.470 | 3 of 5 | 5 of 10 | −0.103 |

**Winter is pinned near rating** — median load 0.919, interquartile range
0.833–0.998, never below 0.549. It occupies only the top half of the curve, so
additional segments subdivide territory the dispatch never visits. This is the
already-documented winter saturation of the deliberately undersized heat pump,
appearing directly as segment occupancy.

**Shoulder traverses almost the entire curve** — 0.163 to 0.927, occupying 9 of
10 segments. Going 5 → 10 gains it **+4 occupied segments** against winter's
+2, and the new ones lie in mid-range territory the dispatch actually uses.
That is where finer COP resolution can pay, and it is the only season where it
did.

Summer is the counter-case that keeps the rule honest: it has the **widest
range** but sits at the bottom of the curve where a uniform fit is at its most
optimistic, so its benefit is negative at both segment counts. **Range alone
does not predict the benefit; occupancy of territory the fit represents *well*
does.**


---

# Reference run: all three Monte Carlo scripts complete at n = 10

Recorded as the reference measurement. All three ran to completion, chunked, at
the shipped `nSegments = 10`.

| Result | Value |
|---|---|
| 4e — PWL vs constant, pooled | **+0.94%**, median +0.28%, CI [+0.47, +1.42], 32/60, p = 0.7, **outlier-driven** |
| 4e — Rolling layers, pooled | +2.86%, CI [+0.97, +4.76], 32/60, p = 0.7, outlier-driven |
| 4e — Robust reserve, pooled | +1.56%, CI [+1.09, +2.02], 40/60, p = 0.013, **distinguishable** |
| 4i — heat-pump gate | +0.206%, CI [−0.178, +0.591], 40/60 — **gate does not pass** |
| 4j — All PWL @ target | **+3.007% [+2.123, +3.890]**, CO2 751.9 → 663.1 |
| 4j — FC PWL @ today | −0.630% [−0.739, −0.520] |

**Runtime, measured: 4j took 87.6 minutes** across 20 chunks — against the
30–45 min this repository previously estimated. The estimate was wrong and is
corrected to **~90 minutes** here, in `README.md` and in the driver header.

## Small differences between machines are the documented solver sensitivity

An earlier run of the same scripts on a different machine gave pooled PWL
**+0.87%** against **+0.94%**, and robust reserve **+1.63%** against **+1.56%**.
These are **not an inconsistency.** They sit inside the **~1% solver-vertex
sensitivity in realized cost** this project has documented since v8: `glpk` may
return a different optimal vertex among ties, and the resulting dispatch differs
slightly at identical cost. Every verdict is identical across the two sets —
outlier-driven stays outlier-driven, distinguishable stays distinguishable, and
the gate spans zero in both. A reader comparing the two sets should expect
agreement to about a percentage point on means, and exact agreement on verdicts.
