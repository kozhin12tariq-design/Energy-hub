# Energy Hub (Fuel Cell + PV + Battery + EV) — MATLAB/Octave

Four modeling steps, matching the thesis roadmap's Month-1 and Month-2
(items I–II) scope:

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

Tested with Octave 8.4 (headless via `xvfb-run`); no toolboxes required.

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
| `matlab/main_energy_hub.m` | Component models + graph assembly demo (constant efficiencies) |
| `matlab/main_pwl_hub.m` | Automatic-equation-generation + PWL demo |
| `matlab/main_ieee33_hub.m` | Energy hubs as active nodes in the IEEE 33-bus system + power-flow impact |

## Running

```matlab
cd matlab
main_energy_hub   % component models + graph/incidence assembly (constant efficiencies)
main_pwl_hub      % automatic equations for arbitrary configs + PWL variable efficiencies
main_ieee33_hub   % energy hubs as active nodes in the IEEE 33-bus system
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
