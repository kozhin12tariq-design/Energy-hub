# Energy Hub (Fuel Cell + PV + Battery + EV) — MATLAB/Octave

Two modeling steps, matching the thesis roadmap's Month-1 scope:

1. **Individual component models** (PV, Fuel Cell, Battery, EV) built with
   the incidence-and-coupling-matrix approach, each on its own small
   local graph.
2. **Graph theory hub assembly**: the components are wired onto shared
   carrier buses (electricity, heat) into one global graph, and the
   hub's coupling matrix `L = C*P` is *derived* from the global
   incidence matrix — capturing **bidirectional flow** (storage
   charge/discharge as two independent edges) and **MIMO conversion**
   (the fuel cell's single hydrogen input drives both an electrical and
   a thermal output at once).

Tested with Octave 8.4 (headless via `xvfb-run`); no toolboxes required.

## Modeling approach

Every component is a small directed graph: local nodes = its energy-carrier
ports, local edges = its conversion/storage branches. Two edge types cover
every case (`eh_edge.m`):

- `'input'` — exogenous branch, value fixed by one entry of the hub's
  input vector `P` (grid import, fuel, solar, storage discharge, ...).
- `'dependent'` — branch value = `eta * inflow(tail node)`, where
  `inflow` is read directly off the node-edge **incidence matrix** `A`
  (the edges whose head is that node). This single rule is what makes
  both requested behaviors fall out for free:
  - **MIMO**: if a node is the tail of *several* dependent edges (the
    fuel cell's `FC_out` node feeds both `Elec_Bus` and `Heat_Bus`),
    one input drives multiple outputs simultaneously.
  - **Bidirectional flow**: storage devices sit on *two* directed edges
    between the bus and the storage cell (discharge = `input`, charge =
    `dependent` on a dispatch factor), not on one signed variable — so
    charge/discharge can have different efficiencies and be evaluated
    independently.

`energy_hub_assemble.m` is the graph-theory step: it merges every
component's local edges into one global graph, identifying any endpoint
name that matches a declared shared bus (e.g. `'Elec_Bus'`) as the same
global node across components, and privately namespacing every other
name to its owning component instance. `energy_hub_incidence_matrix.m`
and `energy_hub_coupling_matrix.m` are completely generic — unchanged by
adding components, buses, or MIMO/bidirectional branches — because every
edge becomes one equation (`M*f = N*P`), stacked and solved once
(`C = S*(M\N)`).

## Files

| File | Purpose |
|---|---|
| `matlab/eh_edge.m` | Edge-spec constructor used by every component and by hub-level (grid/load) branches |
| `matlab/components/component_pv.m` | PV array — unidirectional, SISO |
| `matlab/components/component_fuelcell.m` | Fuel cell — unidirectional, **MIMO** (1 fuel input -> elec + heat outputs) |
| `matlab/components/component_battery.m` | Battery Energy Storage — **bidirectional** (charge/discharge as independent edges) |
| `matlab/components/component_ev.m` | EV battery (V2G) — same bidirectional structure + mobility/V2G flags |
| `matlab/energy_hub_assemble.m` | Graph-theory step: merges components onto shared buses into one global node/edge list |
| `matlab/energy_hub_incidence_matrix.m` | Builds the global incidence matrix `A` from any edge list |
| `matlab/energy_hub_coupling_matrix.m` | Derives `C` from `A` (generic; unchanged by topology) |
| `matlab/energy_hub_display_component.m` | Prints + returns a single component's own standalone local incidence matrix |
| `matlab/energy_hub_example_hub.m` | Builds the worked example hub (PV1+FC1+Batt1+EV1) for a given dispatch operating point |
| `matlab/energy_hub_default_params.m` | Component efficiencies/capacities/power limits |
| `matlab/energy_hub_plot_graph.m` | Auto-layout graph drawing (any topology, not hardcoded) |
| `matlab/storage_soc_update.m` | State-of-charge update applying the storage device's own (dis)charge efficiency, kept outside the port-level coupling matrix |
| `matlab/print_labeled_matrix.m`, `matlab/print_labeled_vector.m` | Console-printing helpers |
| `matlab/main_energy_hub.m` | Runs both steps end to end with the worked example |

## Running

```matlab
cd matlab
main_energy_hub
```

Prints each component's standalone local incidence matrix, assembles the
full hub, prints the global incidence matrix `A` and coupling matrix
`C`, verifies the MIMO fuel-cell derivatives and per-carrier energy
balance numerically, evaluates two operating points with the storage
devices in opposite flow directions, and plots the hub graph.

## Scope note

Dispatch factors (`v`) and storage discharge inputs are free parameters
of the coupling matrix at this stage — nothing here enforces that a
device cannot be charging and discharging at once. That is an operating
*constraint* for whichever optimizer chooses `v` and `P` at each
timestep (a later stage), not something the graph/coupling-matrix model
itself is responsible for.
