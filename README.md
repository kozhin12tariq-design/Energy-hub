# Energy Hub (Fuel Cell + PV + Battery + EV) — MATLAB/Octave

Seven modeling steps, matching the thesis roadmap's Month-1 through
Month-4 scope:

1. **Individual component models** (PV, Fuel Cell, Battery, EV,
   Electrolyzer) built with the incidence-and-coupling-matrix approach,
   each on its own small local graph.
2. **Graph theory hub assembly**: components are wired onto shared
   carrier buses (electricity, heat, hydrogen) into one global graph,
   capturing **bidirectional flow** (storage charge/discharge as two
   independent edges) and **MIMO conversion** (the fuel cell's single
   hydrogen input drives an electrical *and* a thermal output at once).
3. **Standardized coupling matrix, automatic for arbitrary
   configurations**: shared buses are found by naming convention (no
   per-hub wiring code), and `energy_hub_print_equations.m` prints the
   literal energy-flow equations generated from any edge list. Proven by
   building two structurally different hubs from the same component
   library with no solver changes.
4. **Piecewise Linearization (PWL) of variable efficiencies**: realistic
   nonlinear part-load efficiency curves (Fuel Cell, PV, Electrolyzer)
   are PWL-fitted and shown to track the true curve far more closely
   than a single constant efficiency — quantified, not just claimed.
5. **IEEE 33-bus distribution system integration**: energy hubs are sited
   as active nodes (net P injections) at three buses of the standard
   IEEE 33-bus radial feeder, and a backward-forward-sweep power flow
   solver evaluates the resulting voltage-profile and loss impact —
   including a deliberately adverse scenario, not only a flattering one.
6. **Multi-time-space scale optimization**: three coordinated LP dispatch
   levels (day-ahead hourly/robust-proxy, intraday 15-min rolling
   two-stage-stochastic, real-time 5-min fast balancing) with
   **generalized storage** — battery, EV fleet, building thermal mass,
   and district-heating pipe storage all sharing one state equation —
   threaded through a full simulated day via genuine LP/MILP solves
   (GLPK), not heuristics.
7. **Case studies + sensitivity analysis**: an ablation-style comparison
   (conventional baseline → day-ahead-only → no-robust-reserve → full
   proposed system) quantifying cost, CO2, and reliability improvements
   and attributing each to a specific modeling contribution, plus a
   sensitivity analysis on the robust-reserve parameter and on
   renewable/load forecast uncertainty (averaged over multiple random
   seeds, not a single lucky run).

Tested with Octave 8.4 (headless via `xvfb-run`); no toolboxes required
beyond core Octave's built-in `glpk` (LP/MILP solver, used by chapters 6-7).

## Modeling approach

Every component is a small directed graph: local nodes = its energy-carrier
ports, local edges = its conversion/storage branches. Two edge types cover
every case (`eh_edge.m`):

- `'input'` — exogenous branch, value fixed by one entry of the hub's
  input vector `P` (grid import, fuel, solar, storage discharge, ...).
- `'dependent'` — branch value = `eta_or_PWL(inflow(tail node))`, where
  `inflow` is read directly off the node-edge **incidence matrix** `A`
  (the edges whose head is that node) and `eta_or_PWL` is either a
  constant scalar efficiency/dispatch factor or a piecewise-linear curve
  (`pwl_fit_from_function.m`). This single rule is what makes every
  requested behavior fall out for free:
  - **MIMO**: a node can be the tail of *several* dependent edges (the
    fuel cell's `FC_out` node feeds both `Elec_Bus` and `Heat_Bus`), so
    one input drives multiple outputs simultaneously.
  - **Bidirectional flow**: storage devices sit on *two* directed edges
    between the bus and the storage cell (discharge = `input`, charge =
    `dependent` on a dispatch factor), not one signed variable — so
    charge/discharge can have different efficiencies and be evaluated
    independently.
  - **Variable efficiency**: the same rule accepts a PWL curve in place
    of a constant, with no change to the graph structure.

`energy_hub_assemble.m` merges an *arbitrary* list of components into
one global graph automatically: any endpoint name ending in `"_Bus"`
(e.g. `'Elec_Bus'`, `'H2_Bus'`) is recognized as a shared carrier bus
across every component that references it; every other name is
namespaced to its owning instance. Adding a new component type that
introduces a new carrier (e.g. `component_electrolyzer.m` adding
`'H2_Bus'`) requires no change to the assembler or to any existing
component — the concrete demonstration for "automatic generation of
energy flow equations for arbitrary configurations".

### Linear vs. piecewise-linear hubs

`energy_hub_coupling_matrix.m` builds **one** global matrix `C` such
that `L = C*P` everywhere — only valid if every dependent edge has a
constant Eta (it now explicitly refuses PWL edges with a clear error
pointing at the two functions below). For hubs with PWL branches:

- `energy_hub_evaluate_hub.m` — exact evaluation at one concrete `P`,
  resolving edges in dependency order (works for constant and PWL edges
  alike; the only requirement is no circular value dependency, true of
  every physically assembled hub graph).
- `energy_hub_linearize.m` — builds a **local** affine map
  `L =~ C_local*P + d_local` valid near one operating point `P0`, by
  replacing each PWL edge with the (slope, intercept) of its active
  breakpoint segment at `P0`. Reproduces the exact result at `P0`
  itself; the approximation error grows once `P` moves into a different
  segment than the one active at `P0` — demonstrated numerically in
  `main_pwl_hub.m`.

## IEEE 33-bus integration

`ieee33_data.m` hardcodes the standard Baran & Wu (1989) 33-bus radial
distribution test system (32 branches, R/X in Ohm, nominal bus loads in
kW/kVAr, `Vbase = 12.66 kV`) — the de facto benchmark feeder for
distribution power-flow studies. `distflow_bfs.m` is a backward-forward
sweep (ladder iterative) solver for radial networks: each iteration
computes bus current injections from the current voltage estimate,
accumulates branch currents leaf-to-root (backward sweep), then updates
voltages root-to-leaf (forward sweep), converging in single-digit
iterations for a well-conditioned feeder. **Validated** against the
widely-published benchmark for this exact system: this implementation
reproduces total losses of 202.68 kW and a minimum voltage of 0.9131 pu
at bus 18 in the base case — both match the literature values (~202.7
kW, ~0.9131 pu) essentially exactly.

`main_ieee33_hub.m` sites energy hubs (the same `energy_hub_example_hub.m`
model as before) as active nodes at three buses: replacing each bus's
fixed nominal load with the hub's actual net grid draw (`P_grid`), while
reactive power is left at the bus's nominal value (hub inverters assumed
near-unity power factor — this model does not track Q). Two scenarios
are deliberately favorable (solar-rich midday, including the system's
single largest load bus) and one is deliberately adverse (an EV-charging
depot at evening peak with no solar and a depleted battery, whose net
draw comes out *higher* than the original load) — an honest test of grid
impact, not a one-sided demonstration. The adverse bus is also re-run in
isolation (the other two hubs left at nominal load) to show its true
local effect is a voltage drop, separate from the network-wide
trunk-voltage benefit it ends up riding on when all three hubs run
together — a genuine emergent finding from shared-trunk network coupling,
not a scripted result.

## Multi-time-space scale optimization

Three genuine linear programs (solved with Octave's built-in `glpk`, not
heuristics), coordinated so each level starts from where the previous
one actually left the system:

- **Day-ahead** (`dayahead_dispatch.m`, hourly, 24-step horizon, solved
  once): minimizes 24h energy cost (grid import/export + fuel) subject
  to electrical/heat balance and the generalized-storage state equation
  for all four devices. **Robustness** is a reserve-margin proxy — the
  standard simplification when a full robust-MILP toolchain (e.g.
  YALMIP's `robustify` + Gurobi, as the roadmap specifies) isn't
  available: instead of optimizing against an adversarial uncertainty
  set, every hour must keep enough *unused* storage charge/discharge
  headroom to cover a fraction of that hour's load/solar forecast
  (`p.reserve.*`), so the plan isn't dispatched to the exact edge of what
  the day-ahead forecast alone would justify.
- **Intraday** (`intraday_dispatch.m`, 15-min, rolling horizon): a
  genuine **two-stage stochastic LP** re-solved every slot — stage 1 is
  the shared "here-and-now" decision for the current slot, stage 2 is a
  3-scenario (low/mid/high solar) recourse decision for the *next* slot,
  branching from the same stage-1 storage state (true non-anticipativity,
  not an expected-value deterministic proxy). Only stage 1 is ever
  committed; each new slot re-solves with updated forecasts, classic
  receding-horizon dispatch. A soft (L1, via slack variables) penalty
  keeps its storage trajectory close to the day-ahead plan — interpolated
  to 15-min resolution — without forcing an exact match.
- **Real-time** (`realtime_balance.m`, 5-min, fast): re-dispatches only
  the **electrical** carrier, and only the fastest-responding resources
  (grid interchange and the battery), against actual realized solar/load
  — matching real grid-operator practice, where sub-minute balancing
  draws on batteries and AGC-capable plant, not slow thermal assets. The
  fuel cell, heat pump, EV charging, and both thermal storages stay at
  intraday's committed setpoint; any heat-side mismatch is physically
  absorbed by the buildings'/pipes' own thermal inertia rather than
  needing an explicit fast correction, since thermal systems don't need
  sub-minute balancing the way electricity does.

**Generalized storage** (`generalized_storage_soc_update.m`): one state
equation, `SOC(t) = SOC(t-1) + [eta_ch*Pch - Pdis/eta_dis]*dt/Emax -
selfLoss*SOC(t-1)*dt`, used for all four devices via
`multiscale_default_params.m`'s physical reinterpretation:
  - **Battery / EV fleet**: the literal case (EV additionally masked by a
    plugged-in-hours availability schedule).
  - **Building thermal mass**: SOC 0↔1 maps to indoor temperature across
    the comfort band [Tmin,Tmax]; `Emax = C_th*(Tmax-Tmin)`; charging =
    heating beyond the minimum requirement (banking heat), self-loss =
    passive heat loss to ambient. A deliberately short thermal time
    constant (~7h) means it mostly can't hold charge from midday to
    evening peak — visible in the results as much shallower cycling than
    the other three devices, a physically realistic distinction, not an
    underused/broken component.
  - **District-heating pipe storage**: the same equations, larger
    capacity, slower power limits, better insulated (smaller self-loss)
    — it *can* hold charge across the day, and the optimizer uses it for
    exactly that (charges through midday solar, discharges through
    evening peak).

`main_multiscale_dispatch.m` runs one simulated day end-to-end (1
day-ahead solve + 96 intraday solves + 288 real-time solves, ~2.5s
total), threading the storage state through all three levels, and plots
the grid interchange at all three resolutions overlaid, all four
devices' SOC trajectories, and the real-time correction magnitude over
the day. Also fixed along the way: the real-time LP originally bounded
battery charge/discharge only by power rating, not by the resulting SOC
staying in bounds, and briefly pushed SOC just past its floor — now
constrained explicitly.

## Case studies and sensitivity analysis

`simulate_multiscale_day.m` refactors the day-ahead+intraday+real-time
orchestration out of `main_multiscale_dispatch.m` into a reusable
function (`opts.useIntraday` switches between the full closed loop and
an **open-loop** mode -- the day-ahead hourly setpoints held fixed and
executed against actual realized data with no adaptation at all;
`opts.reserveScale` multiplies the reserve-margin fractions, 0
disabling robustness entirely), so it can be re-run many times for
comparison and sweeps without duplicating the 385-solve loop.

### Case studies (`main_case_studies.m`)

Four cases, each removing exactly one modeling contribution from the
next so the improvement it buys can be attributed, not just observed in
aggregate:

| Case | What it has | Isolates |
|---|---|---|
| 1: Conventional | Grid electricity + gas boiler, no PV/FC/heat pump/storage at all (`simulate_conventional_baseline.m`) | The pre-energy-hub reference point |
| 2: Day-ahead only | Energy hub, day-ahead LP, **open loop** (no intraday/real-time) | Value of the rolling multi-timescale layers |
| 3: No robust reserve | Full closed loop, `reserveScale=0` | Value of the robust-reserve proxy |
| 4: Full proposed system | Everything as built | The complete proposed approach |

Reliability is checked (`reliability_check.m`) against ONE feeder
capacity shared by cases 2-4 (`p.reliability.feederCapMargin x` Case 4's
own day-ahead peak import — modeling a connection contracted exactly to
the submitted day-ahead schedule, deliberately tight enough that
coordination/robustness failures show up as real violations rather than
being absorbed by generous headroom) — a violation is any 5-min
interval where required import/export exceeds that capacity.

Representative result on the base scenario: **72% cost reduction, 60%
CO2 reduction** (Case 4 vs. Case 1); reliability violations go
0.11 kWh/0.25h (Case 2) → 0.54 kWh/0.42h (Case 3, worse than Case 2 —
closed-loop correction alone isn't enough without headroom to correct
*into*) → 0 (Case 4). One claim deliberately NOT made: peak grid import
is *higher* in Case 4 than Case 1, honestly reported rather than
glossed over — Case 4 serves strictly more (EV fleet charging, heat-pump
electrification of what was gas heat) and its cost-minimizing day-ahead
LP deliberately imports more than instantaneous need during cheap
overnight hours to pre-charge storage. Cost/emissions optimality and
peak-shaving are different objectives; this system was optimized for
the former; peak-shaving would need its own explicit objective term
(e.g. a demand charge) to also control the latter.

### Sensitivity analysis (`main_sensitivity_analysis.m`)

Two headline sweeps, each averaged over 3 random-scenario seeds (not a
single run), plus a small single-seed 2D grid for visualization:

1. **Reserve-margin sweep** (`reserveScale` in {0, 0.5, 1, 1.5, 2} at
   default uncertainty): reliability improves monotonically (violation
   hours fall to zero by 1.5x). The day-ahead **planned** cost rises
   monotonically with reserve, as expected — more headroom looks more
   expensive on paper — but the **actual realized** cost does not show
   that same rise: avoiding real-time corrections/violations appears to
   offset most or all of the day-ahead premium. These are genuinely
   different numbers with different trends; the script reports both
   rather than collapsing them into one "cost of robustness" figure.
2. **Uncertainty sweep** (forecast-noise scale in {0.5, 1, 1.5, 2, 3},
   with vs. without the reserve margin): unmet energy grows
   monotonically with uncertainty in both cases, while violation
   *hours* roughly plateaus in each — once the same few intervals are
   already over the capacity, more uncertainty mostly deepens those
   shortfalls rather than creating many new ones. The reserve margin
   (sized for the default uncertainty level) keeps unmet energy far
   below the no-reserve case at low-to-moderate uncertainty, but the gap
   narrows at 3x uncertainty — a margin calibrated for one uncertainty
   range degrades gracefully, not perfectly, once uncertainty exceeds
   what it was sized for.
3. A 4x4 reserve x uncertainty grid (violation hours) visualizes the
   interaction as a heatmap.

## Files

| File | Purpose |
|---|---|
| `matlab/eh_edge.m` | Edge-spec constructor (Eta = constant or PWL struct) used by every component and hub-level branch |
| `matlab/eh_describe_eta.m` | Human-readable label for a constant or PWL Eta |
| `matlab/components/component_pv.m` | PV array — unidirectional, SISO |
| `matlab/components/component_fuelcell.m` | Fuel cell — unidirectional, **MIMO** (1 fuel input -> elec + heat outputs) |
| `matlab/components/component_battery.m` | Battery Energy Storage — **bidirectional** (charge/discharge as independent edges) |
| `matlab/components/component_ev.m` | EV battery (V2G) — same bidirectional structure + mobility/V2G flags |
| `matlab/components/component_electrolyzer.m` | Electrolyzer (Power-to-Gas) — bus-dispatched load chained into a conversion edge; proves a new component/carrier needs no assembler changes |
| `matlab/energy_hub_assemble.m` | Graph-theory step: auto-detects shared buses by name, merges components into one global node/edge list |
| `matlab/energy_hub_incidence_matrix.m` | Builds the global incidence matrix `A` from any edge list |
| `matlab/energy_hub_coupling_matrix.m` | Derives the global `C` from `A` (constant-efficiency hubs only; refuses PWL edges) |
| `matlab/energy_hub_evaluate_hub.m` | Exact numeric evaluation of any hub (constant and/or PWL edges) at one input vector |
| `matlab/energy_hub_linearize.m` | Local affine coupling matrix (`C_local`, `d_local`) around one operating point, for PWL hubs |
| `matlab/energy_hub_print_equations.m` | Auto-prints the energy-flow equations generated from any edge list |
| `matlab/energy_hub_display_component.m` | Prints + returns a single component's own standalone local incidence matrix |
| `matlab/energy_hub_example_hub.m` | Builds the worked example hub (PV1+FC1+Batt1+EV1) for a given dispatch operating point; accepts PWL or constant PV/FC components |
| `matlab/pwl_fit_from_function.m` | Fits PWL breakpoints to a nonlinear part-load efficiency function |
| `matlab/pwl_evaluate.m` | Exact PWL curve evaluation (interpolation) |
| `matlab/pwl_local_affine.m` | Local (slope, intercept) of a PWL curve at one point |
| `matlab/energy_hub_default_params.m` | Component efficiencies/capacities/power limits |
| `matlab/energy_hub_plot_graph.m` | Auto-layout graph drawing (any topology; labels PWL edges) |
| `matlab/storage_soc_update.m` | State-of-charge update applying the storage device's own (dis)charge efficiency, kept outside the port-level coupling matrix |
| `matlab/print_labeled_matrix.m`, `matlab/print_labeled_vector.m` | Console-printing helpers |
| `matlab/ieee33_data.m` | Standard IEEE 33-bus radial distribution test system data (branches, loads, base voltage) |
| `matlab/distflow_bfs.m` | Backward-forward sweep power flow solver for radial feeders |
| `matlab/multiscale_default_params.m` | Community-scale params for ch. 6: generalized storage (Battery/EV/Building/Pipe), heat pump, economics, reserve fractions |
| `matlab/generalized_storage_soc_update.m` | The one state equation shared by all four storage devices |
| `matlab/forecast_profiles.m` | Day-ahead (smooth)/intraday (15-min, updated)/real-time (5-min, "true") forecast hierarchy with decreasing uncertainty |
| `matlab/dayahead_dispatch.m` | Day-ahead LP: 24h horizon, reserve-margin robustness proxy |
| `matlab/intraday_dispatch.m` | Intraday rolling two-stage stochastic LP: 15-min, 3-scenario recourse, day-ahead tracking |
| `matlab/realtime_balance.m` | Real-time fast balancing LP: 5-min, electrical-only, battery + grid |
| `matlab/main_energy_hub.m` | Component models + graph assembly demo (constant efficiencies) |
| `matlab/main_pwl_hub.m` | Automatic-equation-generation + PWL demo |
| `matlab/main_ieee33_hub.m` | Energy hubs as active nodes in the IEEE 33-bus system + power-flow impact |
| `matlab/main_multiscale_dispatch.m` | Runs all three dispatch levels + generalized storage over one simulated day |
| `matlab/simulate_multiscale_day.m` | Reusable simulation function (closed loop or open loop, scalable reserve) underlying the case studies/sensitivity analysis |
| `matlab/simulate_conventional_baseline.m` | Case 1: grid + gas boiler, no energy hub |
| `matlab/reliability_check.m` | Feeder-capacity violation metrics (unmet energy, violation hours) from a grid-interchange time series |
| `matlab/main_case_studies.m` | Ablation case studies: cost/CO2/reliability, conventional → day-ahead-only → no-reserve → full system |
| `matlab/main_sensitivity_analysis.m` | Reserve-margin and forecast-uncertainty sensitivity sweeps (multi-seed) + interaction heatmap |

## Running

```matlab
cd matlab
main_energy_hub             % component models + graph/incidence assembly (constant efficiencies)
main_pwl_hub                 % automatic equations for arbitrary configs + PWL variable efficiencies
main_ieee33_hub               % energy hubs as active nodes in the IEEE 33-bus system
main_multiscale_dispatch      % day-ahead / intraday / real-time coordinated LP dispatch + generalized storage
main_case_studies             % cost / CO2 / reliability case studies (ablation across 4 configurations)
main_sensitivity_analysis     % reserve-margin and forecast-uncertainty sensitivity sweeps
```

`main_pwl_hub.m` prints a quantified PWL-vs-constant-efficiency error
table (Fuel Cell, PV, Electrolyzer), assembles the worked hub with
PWL-fitted Fuel Cell/PV branches, auto-prints its equations, shows
`energy_hub_coupling_matrix.m` correctly refusing that PWL hub, exact
PWL evaluation vs. local linearization at increasing distance from an
operating point, then assembles a second, structurally different hub
(PV1+PV2+Electrolyzer, Power-to-Gas) with the same assembler and zero
topology-specific code.

## Scope note

Dispatch factors (`v`) and storage discharge inputs are free parameters
of the coupling matrix at this stage — nothing here enforces that a
device cannot be charging and discharging at once. That is an operating
*constraint* for whichever optimizer chooses `v` and `P` at each
timestep (a later stage), not something the graph/coupling-matrix model
itself is responsible for.
