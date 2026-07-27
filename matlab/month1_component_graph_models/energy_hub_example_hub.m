function [nodeNames, edges, nInputs, inputLabels, outputEdgeIdx, outputLabels] = ...
    energy_hub_example_hub(p, v_elec, v_heat, ev_plugged_in, pvComponent, fcComponent)
%ENERGY_HUB_EXAMPLE_HUB Build the PV1+FC1+Batt1+EV1 example hub for a given
%dispatch operating point (v_elec, v_heat).
%
%   Factored out so different operating points (e.g. "battery
%   discharging" vs. "battery charging") can each assemble their own
%   consistent hub without duplicating the component/edge wiring.
%
%   pvComponent, fcComponent (optional) let a caller substitute PWL-fitted
%   PV/Fuel-Cell components (see main_month2a_arbitrary_configuration_and_pwl.m)
%   instead of the default constant-efficiency ones built from `p`; leave
%   empty to use defaults.

    if nargin < 4 || isempty(ev_plugged_in)
        ev_plugged_in = true;
    end
    if nargin < 5 || isempty(pvComponent)
        pvComponent = hub_component('pv', 'PV1', p.eta_PV);
    end
    if nargin < 6 || isempty(fcComponent)
        fcComponent = hub_component('fuelcell', 'FC1', p.eta_FC_e, p.eta_FC_th);
    end

    if abs(sum(v_elec) - 1) > 1e-9
        error('energy_hub_example_hub:dispatch', ...
            'v_elec (electrical bus dispatch factors) must sum to 1, got sum = %.6f.', sum(v_elec));
    end
    if abs(sum(v_heat) - 1) > 1e-9
        error('energy_hub_example_hub:dispatch', ...
            'v_heat (heat bus dispatch factors) must sum to 1, got sum = %.6f.', sum(v_heat));
    end

    components = { ...
        pvComponent, ...
        fcComponent, ...
        hub_component('battery', 'Batt1', v_elec(2)), ...
        hub_component('ev', 'EV1', v_elec(3), ev_plugged_in, true) ...
    };

    extraEdges = { ...
        eh_edge('Grid_in', 'Elec_Bus', 'input', 1, 'P_grid', 'Grid import -> electrical bus'), ...
        eh_edge('Elec_Bus', 'Elec_Load', 'dependent', v_elec(1), 'L_elec', ...
            sprintf('Electrical bus -> electric load (dispatch v_elec1 = %.2f)', v_elec(1))), ...
        eh_edge('Heat_Bus', 'Heat_Load', 'dependent', v_heat, 'L_heat', ...
            sprintf('Heat bus -> heat load (dispatch v_heat1 = %.2f)', v_heat)) ...
    };

    [nodeNames, edges, nInputs, inputLabels, outputEdgeIdx, outputLabels] = ...
        energy_hub_assemble(components, extraEdges);
end
