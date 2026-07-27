# Energy Hub — Matrix Modeling and Multi-Time-Space Scale Optimization

MATLAB/Octave implementation of the full thesis roadmap: a multi-carrier
energy hub (PV, Fuel Cell, Battery, EV, Electrolyzer, Heat Pump) modeled
with the incidence-and-coupling-matrix method, integrated into the IEEE
33-bus distribution system, and dispatched with a three-level (day-ahead
/ intraday / real-time) optimization framework — evaluated with case
studies and a sensitivity analysis.

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
   claimed. Since a single global `C` cannot represent a piecewise-linear
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

Three genuine linear programs (Octave's built-in `glpk`, not
heuristics), coordinated so each level starts from where the previous
one actually left the system:

- **Day-ahead** (`dayahead_dispatch.m`, hourly, 24-step horizon, solved
  once): minimizes 24h energy cost subject to electrical/heat balance
  and the generalized-storage state equation for all four devices.
  **Robustness** is a reserve-margin proxy — every hour must keep enough
  *unused* storage charge/discharge headroom to cover a fraction of that
  hour's load/solar forecast — the standard simplification when a full
  robust-MILP toolchain (YALMIP + Gurobi) isn't available.
- **Intraday** (`intraday_dispatch.m`, 15-min, rolling horizon): a
  genuine **two-stage stochastic LP** re-solved every slot — stage 1 is
  the shared "here-and-now" decision, stage 2 is a 3-scenario (low/mid/
  high solar) recourse decision for the *next* slot, branching from the
  same stage-1 storage state (true non-anticipativity). Only stage 1 is
  ever committed — classic receding-horizon dispatch. A soft penalty
  keeps its storage trajectory close to the (15-min-interpolated)
  day-ahead plan without forcing an exact match.
- **Real-time** (`realtime_balance.m`, 5-min, fast): re-dispatches only
  the **electrical** carrier, only the fastest resources (grid + battery)
  — matching real grid-operator practice. The fuel cell, heat pump, EV
  charging, and both thermal storages stay at intraday's committed
  setpoint; heat-side mismatch is physically absorbed by the buildings'/
  pipes' own thermal inertia, which doesn't need sub-minute balancing
  the way electricity does.

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
day-ahead solve + 96 intraday solves + 288 real-time solves, ~2.5s
total, via the reusable `simulate_multiscale_day.m`) and plots the grid
interchange at all three resolutions overlaid, all four devices' SOC
trajectories, and the real-time correction magnitude over the day.

## Month 4 — Case studies and sensitivity analysis

`month4_case_studies_sensitivity/` (depends on Month 3)

`simulate_multiscale_day.m` (in Month 3) takes an `opts` struct
(`useIntraday` switches full closed-loop vs. **open-loop** — day-ahead
setpoints held fixed and executed against actual data with no
adaptation; `reserveScale` multiplies the reserve-margin fractions, 0
disabling robustness) so it can be re-run for comparison and sweeps
without duplicating the 385-solve orchestration loop.

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

Reliability (`reliability_check.m`) is checked against ONE feeder
capacity shared by cases 2-4 (contracted exactly to Case 4's own
day-ahead peak import — deliberately tight, so coordination/robustness
failures show up as real violations, not absorbed by generous headroom).

Representative result: **72% cost reduction, 60% CO2 reduction** (Case 4
vs. Case 1); reliability violations go 0.11 kWh/0.25h (Case 2) → 0.54
kWh/0.42h (Case 3, *worse* than Case 2 — closed-loop correction alone
isn't enough without headroom to correct *into*) → 0 (Case 4). One claim
deliberately NOT made: peak grid import is *higher* in Case 4 than Case
1 — honestly reported rather than glossed over, since Case 4 serves
strictly more (EV fleet charging, heat-pump electrification of what was
gas heat) and its cost-minimizing LP deliberately imports more than
instantaneous need during cheap hours to pre-charge storage.
Cost/emissions optimality and peak-shaving are different objectives;
peak-shaving would need its own explicit objective term (e.g. a demand
charge) to also control the latter.

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
3. A 4x4 reserve x uncertainty grid (violation hours) visualizes the
   interaction as a heatmap.

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
