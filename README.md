# Energy Hub (Fuel Cell + PV + Battery + EV) — MATLAB/Octave

Energy hub model built with the classical **coupling matrix method**
(Geidl & Andersson), then **reformulated as a node/edge incidence-matrix
graph problem**, so the coupling matrix `C` in `L = C*P` is *derived*
from the hub's graph topology instead of being written by hand.

Tested with Octave 8.4 (headless via `xvfb-run`); no toolboxes required.

## Model

**Ports**

- Inputs `P = [P_grid; P_H2; P_solar; P_batt_discharge; P_EV_discharge]`
- Outputs `L = [L_elec; P_batt_charge; P_EV_charge]`

**Graph** (`matlab/energy_hub_define_network.m`)

9 nodes: `Grid_in, H2_in, Solar_in, FuelCell, PV, Bus, Battery, EV, Elec_Load`

10 directed edges: grid/H2/solar/battery-discharge/EV-discharge feed the
`Bus` node (5 independent/exogenous edges); `FuelCell -> Bus` and
`PV -> Bus` are dependent edges scaled by `eta_FC` / `eta_PV`; `Bus ->
Elec_Load`, `Bus -> Battery`, `Bus -> EV` are dependent edges scaled by
dispatch (splitting) factors `v = [v1 v2 v3]`, `sum(v) = 1`.

**Incidence matrix** (`matlab/energy_hub_incidence_matrix.m`)

Standard node-edge incidence matrix `A` (9x10): `A(i,k) = +1` if edge `k`
leaves node `i`, `-1` if it enters node `i`.

**Coupling matrix from the incidence matrix**
(`matlab/energy_hub_coupling_matrix.m`)

Every edge becomes one linear equation in the edge-flow vector `f`:
independent edges fix `f(k) = P(...)`; dependent edges enforce
`f(k) = Eta(k) * inflow(From(k))`, where `inflow(node)` is read directly
off `A` as the edges with `A(node,:) == -1`. Stacking gives `M*f = N*P`,
and the outputs are a fixed selection `L = S*f`, so

```
C = S * (M \ N)
```

`matlab/energy_hub_coupling_matrix_classic.m` contains the same hub's
hand-derived closed form (`C = v' * [1, eta_FC, eta_PV, 1, 1]`) purely to
cross-check the graph-derived result — `main_energy_hub.m` asserts the
two are numerically identical.

## Files

| File | Purpose |
|---|---|
| `matlab/energy_hub_define_network.m` | Node/edge graph definition |
| `matlab/energy_hub_incidence_matrix.m` | Builds `A` from the edge list |
| `matlab/energy_hub_coupling_matrix.m` | Derives `C` from `A` (incidence-matrix method) |
| `matlab/energy_hub_coupling_matrix_classic.m` | Closed-form `C` for validation |
| `matlab/energy_hub_default_params.m` | Component parameters (efficiencies, capacities, power limits) |
| `matlab/energy_hub_plot_graph.m` | Draws the node/edge graph |
| `matlab/main_energy_hub.m` | Runs everything: prints `A`, validates `C`, evaluates one operating point, then a 24 h rule-based dispatch demo with battery/EV state of charge |

## Running

```matlab
cd matlab
main_energy_hub
```

The 24-hour dispatch loop in `main_energy_hub.m` uses a simple
priority-order heuristic (PV -> storage -> fuel cell -> grid) purely to
exercise the model over time — it is a placeholder, not an optimizer.
