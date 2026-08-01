# Energy Hub — Matrix Modeling and Multi-Time-Space Scale Optimization

MATLAB/Octave implementation of the full thesis roadmap: a multi-carrier
energy hub (PV, Fuel Cell, Battery, EV, Electrolyzer, Heat Pump) modeled
with the incidence-and-coupling-matrix method, integrated into the IEEE
33-bus distribution system, and dispatched with a three-level (day-ahead
/ intraday / real-time) optimization framework — evaluated with case
studies and a sensitivity analysis.

## One hub, benchmarked on IEEE 33

Two things define the scope of this study:

**Exactly one energy hub.** The thesis models a *single* hub containing
the full technology set — PV, fuel cell, battery, EV fleet, heat pump,
building and pipe thermal storage — on shared electrical and heat buses
with grid import/export. There is never more than one hub anywhere in the
codebase. Where several buses are examined (`main_month2b...`), they are
**alternative sitings of that one hub**, each solved on its own against
the clean base case, never coexisting. `ieee33_system_definition.m` is
the single source of truth for what the study system is.

**IEEE 33 is the benchmark for every result.** Dispatch is no longer
reported from a network-free abstraction: every case study, scenario and
PWL segmentation run is replayed through the exact IEEE 33 power flow and
reports bus voltages and feeder losses alongside cost, CO2 and fuel. Two
modes exist:

| Mode | File | What it does |
|---|---|---|
| **Verify-only** (default) | `network_verify.m` | Replays a completed dispatch through the exact backward-forward sweep. `distflow_bfs` is iterative and nonlinear, so it cannot sit inside a MILP — this *verifies* a schedule, it does not *constrain* one. |
| **Co-optimized** | `lindistflow_sensitivity.m` + `p.network` in `dayahead_dispatch.m`, driven by `main_month4d...` | Embeds a linearized DistFlow voltage model in the **day-ahead** MILP so the network constrains the schedule while it is chosen. Opt-in; absent `p.network` the model is bit-identical to the network-free one. **Day-ahead only** — see the closed-loop caveat below. |

Every script now reports network consequences, including the sensitivity
analysis (`main_month4b...`), which was the last one judging results by
the scalar feeder cap alone.

**Scale, stated honestly.** The hub's peak import is ~104 kW against a
3715 kW feeder — **2.79% feeder-wide**, but **115% of its host bus's own
90 kW load** (173% at bus 33). It is locally dominant and feeder-wide
marginal, and both figures are reported everywhere so the caveat travels
with the data. Ratings were deliberately *not* scaled up: doing so would
change the dispatch and move the Case 1–4 regression anchors, and it is
unnecessary because the local effect is already measurable (the hub swings
V(18) between 0.9120 and 0.9213 pu against a 0.9131 pu base).

**The code is organized into four folders, one per roadmap month**, each
with its own runnable script(s). Nothing else at the top level.

```
matlab/
  month1_component_graph_models/        Month 1: component models + graph theory
  month2_coupling_matrix_pwl_ieee33/     Month 2: coupling matrix automation + PWL + IEEE 33-bus
  month3_multiscale_optimization/        Month 3: day-ahead / intraday / real-time dispatch
  month4_case_studies_sensitivity/       Month 4: case studies + sensitivity analysis
```

Tested with Octave 8.4 (headless via `xvfb-run`); Month 3–4 need core
Octave's built-in `glpk` (LP/MILP solver) — no other toolboxes required.
Months 3–4 are numerically self-contained (their own LP dispatch does not
reuse Month 1–2's graph engine); Month 2 depends on Month 1's component/
graph engine via `addpath('../month1_component_graph_models')`.

## How to run each month

```matlab
cd matlab/month1_component_graph_models
main_month1_components_and_graph_theory

cd ../month2_coupling_matrix_pwl_ieee33
main_month2a_arbitrary_configuration_and_pwl
main_month2b_ieee33_grid_integration

cd ../month3_multiscale_optimization
main_month3_multiscale_dispatch

cd ../month4_case_studies_sensitivity
main_month4a_case_studies
main_month4b_sensitivity_analysis
main_month4c_pwl_segment_sweep
main_month4d_lindistflow_cooptimization
```

Each script is self-contained (`clear; clc;` + whatever `addpath` it
needs) and prints/plots everything described below.

---

## Month 1 — Component models + graph theory

`month1_component_graph_models/`

1. **Individual component models** (PV, Fuel Cell, Battery, EV,
   Electrolyzer), built with the incidence-and-coupling-matrix approach.
   All five live in **one dispatcher file**, `components/hub_component.m`
   (`hub_component('pv', name, eta)`, `hub_component('battery', name,
   v_ch)`, etc.) — each case is a short, self-contained local graph, and
   the dispatcher pattern replaces what used to be five near-identical
   files with one place to see and compare them.
2. **Graph theory hub assembly** (`energy_hub_assemble.m`): components
   are wired onto shared carrier buses (electricity, heat) into one
   global graph, capturing **bidirectional flow** (storage charge/
   discharge as two independent edges, not a signed variable) and
   **MIMO conversion** (the fuel cell's single hydrogen input drives an
   electrical *and* a thermal output at once).

Every component is a small directed graph: local nodes = its
energy-carrier ports, local edges = its conversion/storage branches
(`eh_edge.m`). One rule covers every case: a `'dependent'` edge's value
= `eta_or_PWL(inflow(tail node))`, where `inflow` is read directly off
the node-edge **incidence matrix** (`energy_hub_incidence_matrix.m`).
`energy_hub_assemble.m` merges an *arbitrary* list of components
automatically: any endpoint name ending in `"_Bus"` is a shared carrier
bus across every component that references it; everything else is
namespaced to its owning instance.

**PV model boundary note**: the PV component starts at the array's **DC
electrical output**, not at the solar resource. Its node is `PV_DC_in`
and `eta_PV = 0.97` is the **inverter / DC-DC converter** efficiency
applied to already-generated DC power. Module-level conversion of
irradiance to DC (~15–22% for real silicon modules) is *upstream* of this
model boundary and is embedded in the driving profile —
`forecast_profiles.m`'s `solar` series is the array's available DC output
in kW (a ~50 kW-peak array), not irradiance. Read as a
sunlight-to-electricity efficiency, 0.97 would be physically impossible;
as a power-electronics efficiency it is ordinary. The value is correct —
only its labelling was previously ambiguous.

**Sign convention note**: `energy_hub_incidence_matrix.m` uses the
standard graph-theory convention (+1 at an edge's tail node, -1 at its
head node). The energy-hub literature's own "coupling matrix"
convention (`energy_hub_coupling_matrix.m`, `P_out = C*P_in`) instead
signs by port role (+1 input port, -1 output port), a different
bookkeeping axis that doesn't in general agree edge-by-edge with the
tail/head signs here. Both are correct for what each is used for; this
is a documented difference, not a bug, and no behavior depends on it.

Run `main_month1_components_and_graph_theory.m` to see: each
component's own standalone local incidence matrix
(`energy_hub_display_component.m`), the assembled global incidence
matrix and coupling matrix `C` (`L = C*P`, `energy_hub_coupling_matrix.m`),
a numeric MIMO check (one column of `C` has two nonzero rows), two
operating points with storage running in opposite directions with exact
energy-balance validation, and a graph plot (`energy_hub_plot_graph.m`).

## Month 2 — Coupling matrix automation, PWL, and IEEE 33-bus integration

`month2_coupling_matrix_pwl_ieee33/` (depends on Month 1)

3. **Standardized coupling matrix, automatic for arbitrary
   configurations**: shared buses are found by naming convention (no
   per-hub wiring code), and `energy_hub_print_equations.m` prints the
   literal energy-flow equations generated from any edge list — proven
   by building two structurally different hubs from the same component
   library with no solver changes (`main_month2a...`, "Hub configuration
   1" vs. "Hub configuration 2").
4. **Piecewise Linearization (PWL) of variable efficiencies**
   (`pwl_utils.m` — one dispatcher for fit/eval/local-affine, replacing
   three files): realistic nonlinear part-load efficiency curves (Fuel
   Cell, PV, Electrolyzer) are PWL-fitted and shown to track the true
   curve one to two orders of magnitude more closely than a single
   constant efficiency — quantified in a printed error table, not just
   claimed. `pwl_utils('fit', ...)` takes an optional breakpoint-
   placement argument: `'uniform'` (default, used everywhere in this
   project) spaces breakpoints evenly in load fraction; `'curvature'`
   concentrates them by equal cumulative |second derivative| instead.
   Curvature placement is a max-error-oriented heuristic — it reduces
   MaxErr for 3 of the 4 example curves (all but the electrolyzer, whose
   curve is close to a plain quadratic with only mildly-varying
   curvature) but does **not** reliably improve RMSE, which only
   improves for the fuel-cell electrical curve — an honest, quantified
   trade-off (`main_month2a...`'s "Breakpoint placement" table), not a
   universally-better alternative default. Since a single global `C`
   cannot represent a piecewise-linear
   hub, `energy_hub_coupling_matrix.m` explicitly refuses PWL edges;
   `energy_hub_evaluate_hub.m` (exact evaluation at one operating point)
   and `energy_hub_linearize.m` (local affine map, valid near one
   operating point, degrading once the true point crosses into a
   different PWL segment) take over instead.
5. **IEEE 33-bus distribution system integration**
   (`ieee33_data.m` + `distflow_bfs.m`, run via `main_month2b...`):
   the standard Baran & Wu 33-bus radial feeder, solved with a
   backward-forward-sweep power flow — **validated** against the
   widely-published benchmark for this exact system (this
   implementation reproduces 202.68 kW total losses and 0.9131 pu
   minimum voltage at bus 18, matching literature essentially exactly).
   Energy hubs are sited as active nodes (net P injections) at three
   buses: two favorable scenarios and one **deliberately adverse** one
   (an EV depot charging at evening peak draws more than the original
   load), so the grid-impact comparison is honest, not one-sided. The
   adverse bus is also re-run in isolation to show its true local effect
   is a voltage drop that gets offset, once all three hubs run together,
   by upstream trunk-voltage gains from the other two — a genuine
   emergent finding from shared-trunk network coupling, not scripted.

## Month 3 — Multi-time-space scale optimization

`month3_multiscale_optimization/` (self-contained)

Three optimization levels (Octave's built-in `glpk`), coordinated so
each level starts from where the previous one actually left the system:

- **Day-ahead** (`dayahead_dispatch.m`, hourly, 24-step horizon, solved
  once): minimizes 24h energy cost subject to electrical/heat balance
  and the generalized-storage state equation for all four devices. The
  fuel cell is a genuine **PWL/MILP embedding**, not a standalone Month-2
  demo: its electrical and thermal part-load efficiency curves are both
  non-concave/S-shaped, so a plain LP relaxation would cherry-pick a
  higher-slope segment while leaving a lower one empty (verified
  numerically — see `VALIDATION.md`). Fill-order binary variables
  (`u_1..u_(s-1)` per hour) force segments to fill in order, making
  day-ahead a genuine MILP; `p.PWL.nSegments` (default 5,
  `multiscale_default_params.m`) controls fidelity, and `nSegments=1`
  provably collapses back to the old constant-efficiency LP (bit-exact
  match, verified). **Robustness** is a reserve-margin proxy — every
  hour must keep enough *unused* storage charge/discharge headroom to
  cover a fraction of that hour's load/solar forecast — the standard
  simplification when a full robust-MILP toolchain isn't available. A
  genuine robust-MILP (e.g. via YALMIP's `robustify` + a solver like
  Gurobi that handles the resulting semi-infinite/robust-counterpart
  constraints) would instead optimize against an explicit uncertainty
  set (box/polyhedral/budget) for solar and load, guaranteeing
  feasibility for *every* realization in that set rather than just
  reserving headroom sized to a fraction of the forecast — a real
  worst-case guarantee instead of a proxy for one. That would need a
  solver this codebase deliberately doesn't depend on (Octave's `glpk`
  only), so the reserve-margin proxy is a documented, honest
  substitute, not a claim of true robustness.
- **Intraday** (`intraday_dispatch.m`, 15-min, rolling horizon): a
  genuine **two-stage stochastic MILP** re-solved every slot — stage 1 is
  the shared "here-and-now" decision, stage 2 is a 3-scenario (low/mid/
  high solar) recourse decision for the *next* slot, branching from the
  same stage-1 storage state (true non-anticipativity). The same
  fuel-cell PWL/MILP segment+binary structure as day-ahead is applied
  independently in every block (stage 1 and each scenario), since each
  makes its own fuel cell decision. Only stage 1 is ever committed —
  classic receding-horizon dispatch. A soft penalty keeps its storage
  trajectory close to the (15-min-interpolated) day-ahead plan without
  forcing an exact match.
- **Real-time** (`realtime_balance.m`, 5-min, fast): re-dispatches only
  the **electrical** carrier, only the fastest resources (grid + battery)
  — matching real grid-operator practice. The fuel cell, heat pump, EV
  charging, and both thermal storages stay at intraday's committed
  setpoint; heat-side mismatch is physically absorbed by the buildings'/
  pipes' own thermal inertia, which doesn't need sub-minute balancing
  the way electricity does. The fuel cell's committed fuel is already a
  fixed number here (not re-optimized), so it's converted to electricity
  via an exact PWL curve lookup (`pwl_utils('eval', ...)`), not the
  segment/binary machinery day-ahead/intraday need for the optimization
  itself.

### Three hydrogen-price scenarios (production gate vs. delivered)

Hydrogen cost is the single parameter that decides whether the fuel cell
runs at all, so it is treated as a deliberate scenario axis
(`p.scenarios` in `multiscale_default_params.m`) rather than one fixed
number. Every point is anchored to a published figure, converted at
hydrogen's lower heating value of 120 MJ/kg = 33.3 kWh/kg.

**The basis distinction matters.** DOE's headline hydrogen targets are
*production* targets: the Bipartisan Infrastructure Law's Clean Hydrogen
Electrolysis Program funds "$2/kg clean hydrogen **from electrolysis** by
2026", and the Hydrogen Shot's $1/kg by 2031 is likewise the cost of
*producing* hydrogen. Neither includes compression, storage, transport or
dispensing. DOE tracks delivered cost separately and with much larger
numbers — its **dispensed** target for heavy-duty vehicles is $7/kg by
2028, several times the production target for the same era. A fuel cell
in a building pays a *delivered* price, so comparing today's delivered
cost against a future production-gate cost would silently switch basis
and overstate the improvement. Hence three scenarios, not two:

| Scenario | $/kWh fuel | $/kg | Basis | Role |
|---|---|---|---|---|
| `H2_today` (default) | 0.22 | 7.33 | delivered | Clean hydrogen delivered today. DOE puts renewable-sourced hydrogen near $5/kg at the production gate; delivery puts the delivered cost above that. |
| `H2_doeTargetDelivered` | 0.0879 | 2.93 | delivered | **Like-for-like headline.** DOE's $2/kg 2026 production target carried to the meter with this project's own implied delivery markup (7.33 ÷ 5.00 = 1.465×, derived in code, not hardcoded). |
| `H2_doeTargetGate` | 0.06 | 2.00 | production | **Optimistic bound.** The same target at the gate, unmodified — i.e. a fuel cell that pays nothing for delivery. |

`main_month3_multiscale_dispatch.m` runs the full stack at **all three**,
changing only `p.price_H2`, and prints them side by side so the result is
a bracketed range rather than a point estimate. At today's delivered cost
the fuel cell is uneconomic against grid import and the optimizer
correctly never starts it (`FC fuel = 0` — the right economic answer, not
a broken component). At the like-for-like delivered target it runs 2
hours a day (138 kWh fuel), cutting day-ahead grid import 22% and
emissions 10%; at the optimistic gate price, 5 hours (339 kWh), cutting
import 61% and emissions 28%.

In **both** target columns it runs at part load — 40–52% of rated fuel
input delivered, 37–55% at the gate — never at the rated point a single
nameplate efficiency is calibrated to. That is the regime where a
constant efficiency is least accurate and where the PWL/MILP formulation
contributes. The PWL model is inert at today's prices because the
component it describes is inert, and becomes load-bearing exactly when
hydrogen gets cheap enough to dispatch.

Month 4's segment sweep runs at `H2_doeTargetGate` for a stated reason:
it is a *convergence* study, and the gate price maximises fuel-cell
throughput, giving the clearest signal. That is legitimate for measuring
convergence but would not be for a cost headline — which is why Case 5
reports both target prices.

**Generalized storage** (`storage_soc_update.m`): one state equation,
`SOC(t) = SOC(t-1) + [eta_ch*Pch - Pdis/eta_dis]*dt/Emax -
selfLoss*SOC(t-1)*dt`, used for all four devices via
`multiscale_default_params.m`'s physical reinterpretation:
- **Battery / EV fleet**: the literal case (EV masked by a plugged-in-
  hours availability schedule).
- **Building thermal mass**: SOC 0↔1 maps to indoor temperature across
  the comfort band; a short thermal time constant (~7h) means it mostly
  can't hold charge from midday to evening peak — visibly much shallower
  cycling than the other three devices in the plots, a physically
  realistic distinction, not an underused component.
- **District-heating pipe storage**: same equations, larger capacity,
  slower, better insulated — it *can* hold charge across the day, and
  the optimizer uses it for exactly that.

`main_month3_multiscale_dispatch.m` runs one simulated day end-to-end (1
day-ahead solve + 96 intraday solves + 288 real-time solves, via the
reusable `simulate_multiscale_day.m`) and plots the grid interchange at
all three resolutions overlaid, all four devices' SOC trajectories, and
the real-time correction magnitude over the day. Solve time is
machine-dependent; see `VALIDATION.md` for the before/after measurement
of embedding the fuel cell's PWL/MILP structure into day-ahead and
intraday (Tasks 1-2 of that log).

## Month 4 — Case studies and sensitivity analysis

`month4_case_studies_sensitivity/` (depends on Month 3)

`simulate_multiscale_day.m` (in Month 3) takes an `opts` struct
(`useIntraday` switches full closed-loop vs. **open-loop** — day-ahead
setpoints held fixed and executed against actual data with no
adaptation; `reserveScale` multiplies the reserve-margin fractions, 0
disabling robustness; `usePWL`, default `true`, switches the fuel
cell's PLANNING model between the true PWL curve and a single constant
efficiency — the physical/realized side always uses the true curve
regardless, since the fuel cell doesn't know what the planner assumed)
so it can be re-run for comparison and sweeps without duplicating the
385-solve orchestration loop.

### Case studies (`main_month4a_case_studies.m`)

Four cases, each removing exactly one modeling contribution from the
next so the improvement it buys can be attributed, not just observed in
aggregate:

| Case | What it has | Isolates |
|---|---|---|
| 1: Conventional | Grid electricity + gas boiler, no PV/FC/heat pump/storage at all | The pre-energy-hub reference point |
| 2: Day-ahead only | Energy hub, day-ahead LP, **open loop** (no intraday/real-time) | Value of the rolling multi-timescale layers |
| 3: No robust reserve | Full closed loop, `reserveScale=0` | Value of the robust-reserve proxy |
| 4: Full proposed system | Everything as built | The complete proposed approach |
| 5: Constant efficiency | Case-4-style closed loop, but day-ahead/intraday PLAN with a constant fuel-cell efficiency instead of PWL (`usePWL=false`); the physical realization still uses the true curve | The value of PWL itself, not a coordination/robustness layer — reported separately, not part of the 1→4 progression |

Case 5 runs at **both** DOE target prices (see [Three hydrogen-price
scenarios](#three-hydrogen-price-scenarios-production-gate-vs-delivered)
above), because those are the scenarios in which the fuel cell is
economic at all; at the `H2_today` default it never dispatches, so the
comparison would weigh 0 fuel against 0 fuel. Cases 1-4 keep the default.

**The PWL cost benefit is utilization-dependent, and is reported as a
range rather than a single number.** Comparing realized cost (both
variants evaluated against the one true curve, isolating the modeling
choice from forecast noise), constant efficiency costs:

| Hydrogen price | FC fuel dispatched | Constant efficiency vs. PWL |
|---|---|---|
| $2.93/kg delivered (like-for-like) | 138 kWh / 2 h | **+0.20%** |
| $2.00/kg gate (optimistic bound) | 339 kWh / 5 h | **+1.47%** |

The mechanism is straightforward: a part-load model can only matter in
proportion to how much energy actually flows through the nonlinear
device, and 2.5× more fuel flows at the gate price. Quoting +1.47% alone
would be quietly conditioned on the more optimistic cost basis, so both
are given — on the like-for-like basis the cost benefit is real but
modest. (Same direction as Huang et al.'s reported 13.7% for a
constant-efficiency baseline, though different system/curves/price
levels — not a claim of matching their number.)

**The argument that does not depend on cost is the stronger one.** The
PWL segments and fill-order binaries exist to keep the dispatch
*physically possible*, not to save money. Without the ordering binaries
the LP relaxation fills segment 2 while segment 1 is only fractionally
full (verified counterfactual: `PH2seg(2) > 0` at `PH2seg(1) = 4.576` of
30), reporting more electricity per unit hydrogen than the device can
produce. That defect exists at *every* price, including ones where the
cost difference rounds to zero. See `main_month4c_pwl_segment_sweep.m`
(below) for how the gap and the underlying curve-fit error behave as
`p.PWL.nSegments` varies.

Reliability (`reliability_check.m`) is checked against ONE feeder
capacity shared by cases 2-4. **How that threshold is set is a
methodological choice, so it is an explicit switch** (`feeder_capacity.m`,
`p.reliability.capBasis`):

- `'design'` (**default**) — sized the way a real connection is sized,
  from connected load and nameplate ratings only: `diversityFactor ×
  (peak elec demand + EV charger + battery charger + heat pump)` =
  0.85 × 123.0 = **104.55 kW**. Every term is exogenous; no dispatch
  strategy enters it.
- `'case4'` — the earlier basis (Case 4's own day-ahead peak, 104.19 kW),
  retained only for comparison. It is self-favourable: it measures the
  proposed system against a line the proposed system draws.

The threshold feeds `reliability_check` only, *after* every case is
solved — it never enters the dispatch, so it cannot move cost, CO2 or
peak, only `unmetE`/`violHrs`. Both bases are printed side by side.

**Case 4's reliability advantage does survive the independent
threshold** (0.00 violation hours vs 0.17 and 0.42) — but the script
reports how narrow that is rather than leaving it to be discovered. The
three realized peaks lie within 1.75 kW, so Case 4 is the only clean case
for caps in **[103.76, 105.07) kW** — a 1.31 kW window, ~1.3% of the
peak. Tighter and all three violate; looser and none do. What *is* robust
is the **ordering of unmet energy**: Case 4 lowest and Case 3 highest at
every swept threshold where anything violates at all. That ranking, not
the zero, is the defensible reliability claim.

Headline result: **72% cost reduction, 60% CO2 reduction** (Case 4 vs.
Case 1) — but see the caveat below on what that measures. Two claims
deliberately NOT made:

- **Peak grid import is *higher* in Case 4 than Case 1**, reported rather
  than glossed over: Case 4 serves strictly more (EV charging, heat-pump
  electrification of what was gas heat) and its cost-minimizing dispatch
  deliberately imports more during cheap hours to pre-charge storage.
  Cost/emissions optimality and peak-shaving are different objectives;
  peak-shaving needs its own objective term (e.g. a demand charge).
- **The 72%/60% figures measure the equipment, not the modelling.**
  Case 1 has no PV at all; Case 4 has ~412 kWh/day of free solar. Most of
  that gap is the value of *owning* PV, a battery, an EV fleet and a heat
  pump — any competently dispatched system with the same hardware would
  capture most of it. The figures should never be quoted without stating
  what they compare. The numbers that isolate *this thesis's* modelling
  contributions are the ablations, and they are appropriately smaller:
  **+1.8%** for the rolling intraday/real-time layers (Case 2 vs 4),
  **+1.5%** for the robust reserve margin (Case 3 vs 4), and
  **0.20–1.47%** for PWL vs constant efficiency (Case 5,
  utilization-dependent). Those are the defensible modelling claims.

### Network consequences on IEEE 33

Every case is replayed through the exact power flow. Two findings the
cost table alone would have missed, both reported rather than smoothed:

- **The cheapest dispatch is not the best one for the network.** Case 4
  is cheapest ($49.74) *and* has the lowest feeder losses (4615.9
  kWh/day), but the best **minimum voltage** belongs to Case 1, the
  conventional no-hub baseline (0.9166 pu vs Case 4's 0.9120). Case 4's
  cost-minimising schedule concentrates EV and battery charging into
  cheap hours, and nothing in its objective knows bus 18 is the
  electrically weakest point on the feeder. Better on losses, worse at
  the feeder's weakest moment — which is exactly the trade-off
  benchmarking on IEEE 33 rather than on a scalar import cap exists to
  expose.
- **Modelling error does not propagate into grid error here.** PWL vs
  constant efficiency differ by 0.0004 pu in minimum voltage and 0.7
  kWh/day in losses — practically indistinguishable — while differing by
  0.20–1.47% in cost. On this profile PWL fidelity is a *cost* accuracy
  question, not a grid accuracy one.

One caveat that must travel with any voltage number from this study:
**21 of 33 IEEE 33 buses already sit below 0.95 pu in the published base
case**, all day, with no hub present. The "hours below 0.95 pu" column
therefore reads 24.00 for every case *including the no-hub base*, and
measures the benchmark feeder rather than anything this thesis does. Read
minimum voltage and the loss delta instead.

### Sensitivity analysis (`main_month4b_sensitivity_analysis.m`)

Two headline sweeps, each averaged over 3 random-scenario seeds, plus a
small single-seed 2D grid for visualization:

1. **Reserve-margin sweep** (`reserveScale` in {0, 0.5, 1, 1.5, 2}):
   reliability improves monotonically to zero violations. The day-ahead
   **planned** cost rises monotonically with reserve, as expected — but
   the **actual realized** cost does not show that same rise: avoiding
   real-time corrections/violations appears to offset most or all of the
   day-ahead premium. Two genuinely different trends, reported
   separately rather than collapsed into one "cost of robustness" figure.
2. **Uncertainty sweep** (forecast-noise scale in {0.5, 1, 1.5, 2, 3},
   with vs. without reserve): unmet energy grows monotonically with
   uncertainty in both cases, while violation *hours* roughly plateaus —
   once the same few intervals are already over capacity, more
   uncertainty mostly deepens those shortfalls rather than creating many
   new ones. The reserve margin keeps unmet energy far below the
   no-reserve case at low-to-moderate uncertainty, but the gap narrows
   at 3x — a margin calibrated for one range degrades gracefully, not
   perfectly, beyond it.
3. A 4x4 reserve x uncertainty grid (violation hours **and minimum
   voltage**) visualizes the interaction as a heatmap.

**All three sweeps are now verified against IEEE 33**, and the answer is
a clean negative result: **forecast uncertainty and reserve margin move
cost and unmet energy, not voltage.** Across every scenario in all three
sweeps minimum voltage spans just **0.0007 pu** (0.9115–0.9122) —
negligible next to the 0.0869 pu the feeder is already below nominal in
its own base case. The direction is consistent (more reserve raises
voltage slightly on every grid row, more uncertainty lowers it slightly
down every column), so the honest statement is "directionally as
expected, practically irrelevant", not "no effect". Mechanism: the
reserve margin changes *when* energy is drawn and how much shortfall
survives to real time, but barely changes the *peak* net injection — and
peak injection is what sets minimum voltage. The reserve margin is a
cost/energy instrument and should not be sold as voltage support.

### PWL segment-count trade-off (`main_month4c_pwl_segment_sweep.m`)

Sweeps `p.PWL.nSegments` in `{1, 2, 5, 10, 20, 36, 50, 75, 100, 150}` for
the fuel cell curves, reporting curve-fit approximation error (Max/RMSE
vs. the exact continuous efficiency function — same methodology as Month
2's error table), day-ahead MILP solve time, and planned-vs-realized cost —
mirroring the accuracy-vs-computation trade-off style used by Huang et
al. (not a claim of matching their specific numbers). Curve-fit error
falls monotonically with segment count and MILP solve time grows with
it (more segment/binary variables per hour) — the two sides of the
trade-off the thesis is centrally about. The realized-vs-planned cost
gap is *not* monotonic (each segment count gives the MILP a genuinely
different feasible region, so it makes a genuinely different fuel
dispatch decision, not just a more accurate evaluation of one fixed
plan) — reported honestly rather than smoothed into a cleaner-looking
curve; see `VALIDATION.md` for the full table.

**The tractability wall is found, which is the point of extending to
150.** The thesis claims high-fidelity PWL *while retaining MILP
tractability*, and a sweep stopping at 36 never tested the second half of
that claim. Solve time runs 1.3 s (n=36) → 3.0 s (n=50) → 10.4 s (n=75) →
17.8 s (n=100) → **149.7 s (n=150)**: roughly 8× the time for 1.5× the
segments on the last step, and 112× the n=36 baseline. The binary count
grows strictly linearly (3576 fill-order binaries at n=150), so this is
not "more binaries" — as segments narrow, each binary controls a thinner
slice of fuel, the LP relaxation becomes a weaker guide to the integer
optimum, and `glpk` explores disproportionately more nodes. A 300 s
per-solve budget records an over-budget count as a *result* rather than
dropping the row.

**Practical band for this system: roughly n=10 to n=36.** Below 10 the
cost error is material (n=1 and n=2 are wrong by −4.36% and +24.80%);
above ~36 curve-fit error is already under 0.03 kW on a 150 kW device and
solve time climbs steeply for accuracy that changes no reported number.
Huang et al. report 30–70 on their system; this one sits lower — *not* a
reproduction of their result (different system, curves, prices and
solver), only the same shape of trade-off.

### Co-optimization: LinDistFlow inside the MILP (`main_month4d...`)

Verification cannot change a schedule — it can only report after the fact
that the dispatch was network-unfriendly, which is what Month 3 found.
This closes the loop by embedding a linearized DistFlow voltage model in
the day-ahead MILP.

**The 0.95 pu limit is infeasible on this system, and the script asks
before assuming.** Reaching it would need the hub to *export* 352 kW at
bus 18 and 1946 kW at bus 33, against an actual export capability near 15
kW — infeasible by one to two orders of magnitude. So the co-optimization
imposes an achievable and more meaningful floor: **do no harm**, no bus
driven below its no-hub voltage.

| | Verify-only | Co-optimized |
|---|---|---|
| Day-ahead cost | $43.0277 | $43.0306 (**+0.01%**) |
| Peak grid import | 104.19 kW | 90.00 kW |
| Exact min voltage | 0.9120 pu | 0.9131 pu |
| Do-no-harm (exact solver) | **NO** | **YES** |

Respecting the network costs $0.0028/day here, because the cap binds in
only 1 of 24 hours.

**But the guarantee is day-ahead only, and it does not survive the
rolling layers.** `p.network` is read by `dayahead_dispatch.m` alone;
`intraday_dispatch.m` and `realtime_balance.m` are network-blind. Running
the co-optimized plan through the **full closed loop** across 3 seeds ×
3 uncertainty levels, do-no-harm held in only **4 of 9** scenarios: the
day-ahead cap is respected exactly (90.00 kW planned every time) but the
realized 5-minute peak reaches **97.45 kW**, 8.3% above it, and minimum
voltage falls up to 0.0006 pu below the floor the constraint exists to
protect. Failures concentrate at higher uncertainty, exactly as the
mechanism predicts — intraday and real-time correct against actual
conditions with no voltage model, and larger forecast error means larger
uncorrected excursions. **Constraining only the day-ahead layer is
insufficient**; the do-no-harm result is a property of the *plan*, not of
the delivered dispatch. Extending the constraint into all three
timescales is the indicated next step, and this test is what establishes
that it is needed.

**Two honest limitations.** First, LinDistFlow is **optimistic** — it
reads 0.0064 pu high on the base case and high at 32 of 33 buses, because
dropping the quadratic loss term removes part of the voltage drop. It
happens not to bite here only because the do-no-harm floor sits at the
same operating point in both models, so the error cancels at the binding
point; a hard 0.92 pu floor would expose the full margin. Second, with
**one** injection on a **radial** feeder and no dispatchable reactive
power, every bus voltage is monotone in hub import, so the 32-row
LinDistFlow constraint set **collapses exactly to a single scalar cap**
("import ≤ the 90 kW nominal load it replaced"). The apparatus is genuine
and would generalize to several interacting hubs, dispatchable Q or
meshed topology — but on this system it buys nothing a well-chosen import
cap could not, and that is stated rather than hidden behind the
machinery.

## Scope notes

- Dispatch factors (`v`) and storage discharge inputs are free
  parameters of the Month 1-2 coupling matrix — nothing there enforces
  that a device cannot be charging and discharging at once. That's an
  operating *constraint* for whichever optimizer chooses `v` and `P`
  (Month 3), not something the graph/coupling-matrix model itself is
  responsible for.
- Real bugs caught and fixed during development (kept here since they
  show what was actually verified, not just claimed): a heat pump had to
  be added in Month 3 because the fuel cell was initially the *only*
  heat source, making it must-run regardless of price and masking the
  entire grid-import cost tradeoff; the real-time LP originally bounded
  battery power only by rating, not by the resulting SOC staying in
  bounds; the Month 4 case-study reliability margin was originally too
  generous (1.3x) to show any contrast between cases.
