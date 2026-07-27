function [nodeNames, edges, nNodes, nInputs, outputEdgeIdx] = energy_hub_define_network(eta_FC, eta_PV, v)
%ENERGY_HUB_DEFINE_NETWORK Graph (node/edge) definition of the energy hub.
%
%   [nodeNames, edges, nNodes, nInputs, outputEdgeIdx] = ...
%       ENERGY_HUB_DEFINE_NETWORK(eta_FC, eta_PV, v)
%
%   Defines the energy hub (Fuel Cell + PV + Battery + EV) as a directed
%   graph: nodes are energy-carrier ports / converters / storage units /
%   loads, edges are directed power-flow branches between them.
%
%   Inputs
%     eta_FC : fuel cell electrical efficiency (H2 -> electricity)
%     eta_PV : PV/inverter efficiency (solar -> electricity)
%     v      : 1x3 dispatch (splitting) factors at the electrical bus,
%              v = [v_load, v_battery_charge, v_EV_charge], sum(v) = 1
%
%   Outputs
%     nodeNames     : 1x9 cell array of node labels
%     edges         : 1x10 struct array, one entry per directed edge with
%                       .From        tail node index
%                       .To          head node index
%                       .Type        'input' (independent/exogenous) or
%                                    'dependent' (determined by branch law)
%                       .Eta         branch efficiency / dispatch factor
%                       .InputIndex  index into the hub input vector P
%                                    (only for Type == 'input')
%                       .Label       human readable description
%     nNodes        : number of nodes (9)
%     nInputs       : number of independent hub inputs (5)
%     outputEdgeIdx : indices of the edges that represent the hub outputs
%                     L = [L_elec ; P_batt_charge ; P_EV_charge]
%
%   Node list (index : name)
%     1 : Grid_in     - electricity import port (source)
%     2 : H2_in       - hydrogen fuel port (source)
%     3 : Solar_in    - solar resource port (source)
%     4 : FuelCell    - fuel cell converter (H2 -> elec)
%     5 : PV          - PV array/inverter converter (solar -> elec)
%     6 : Bus         - electrical bus (internal junction)
%     7 : Battery     - battery energy storage
%     8 : EV          - electric vehicle battery (V2G capable)
%     9 : Elec_Load   - electric demand (sink)
%
%   Edge list (index : From -> To)
%     e1  : Grid_in  -> Bus       input,     P(1) = P_grid
%     e2  : H2_in    -> FuelCell  input,     P(2) = P_H2
%     e3  : FuelCell -> Bus       dependent, eta_FC * inflow(FuelCell)
%     e4  : Solar_in -> PV        input,     P(3) = P_solar
%     e5  : PV       -> Bus       dependent, eta_PV * inflow(PV)
%     e6  : Battery  -> Bus       input,     P(4) = P_batt_discharge
%     e7  : EV       -> Bus       input,     P(5) = P_EV_discharge (V2G)
%     e8  : Bus      -> Elec_Load dependent, v(1) * inflow(Bus)   [OUTPUT]
%     e9  : Bus      -> Battery   dependent, v(2) * inflow(Bus)   [OUTPUT]
%     e10 : Bus      -> EV        dependent, v(3) * inflow(Bus)   [OUTPUT]
%
%   "inflow(node)" means the sum of the flows on every edge that ends at
%   that node -- this is read directly off the incidence matrix by
%   energy_hub_coupling_matrix.m (rows where A(node,:) == -1).

    if nargin < 3 || isempty(v)
        v = [1 0 0];
    end
    if abs(sum(v) - 1) > 1e-9
        error('energy_hub_define_network:dispatch', ...
            'Dispatch factors v must sum to 1 (got sum = %.6f).', sum(v));
    end

    nodeNames = {'Grid_in','H2_in','Solar_in','FuelCell','PV', ...
                 'Bus','Battery','EV','Elec_Load'};
    nNodes  = numel(nodeNames);
    nInputs = 5;

    edges(1)  = mkedge(1, 6, 'input',     1,      1, 'Grid import -> Bus');
    edges(2)  = mkedge(2, 4, 'input',     1,      2, 'H2 fuel -> Fuel Cell');
    edges(3)  = mkedge(4, 6, 'dependent', eta_FC, [], 'Fuel Cell -> Bus (eta_FC)');
    edges(4)  = mkedge(3, 5, 'input',     1,      3, 'Solar -> PV');
    edges(5)  = mkedge(5, 6, 'dependent', eta_PV, [], 'PV -> Bus (eta_PV)');
    edges(6)  = mkedge(7, 6, 'input',     1,      4, 'Battery discharge -> Bus');
    edges(7)  = mkedge(8, 6, 'input',     1,      5, 'EV discharge (V2G) -> Bus');
    edges(8)  = mkedge(6, 9, 'dependent', v(1),   [], 'Bus -> Electric load (v1)');
    edges(9)  = mkedge(6, 7, 'dependent', v(2),   [], 'Bus -> Battery charge (v2)');
    edges(10) = mkedge(6, 8, 'dependent', v(3),   [], 'Bus -> EV charge (v3)');

    outputEdgeIdx = [8 9 10];
end

function e = mkedge(from, to, type, eta, inputIndex, label)
    e.From = from;
    e.To = to;
    e.Type = type;
    e.Eta = eta;
    e.InputIndex = inputIndex;
    e.Label = label;
end
