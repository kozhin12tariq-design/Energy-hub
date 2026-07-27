function comp = hub_component(type, name, varargin)
%HUB_COMPONENT Individual component models, built with the incidence-and-
%coupling-matrix approach (thesis roadmap Month 1, item II).
%
%   comp = HUB_COMPONENT(type, name, ...)
%
%   One dispatcher for every component type in this project instead of
%   one file each -- each TYPE below is a short, self-contained local
%   graph (nodes = its energy-carrier ports, edges = its conversion/
%   storage branches, built from eh_edge.m), exactly as before; only the
%   call site changed from e.g. component_pv(name,eta) to
%   hub_component('pv',name,eta).
%
%   type = 'pv' : comp = HUB_COMPONENT('pv', name, eta_PV)
%     Unidirectional, SISO converter.
%     Local graph:  Solar_in --(input P_solar)--> PV_out --(eta_PV)--> Elec_Bus
%     Local incidence matrix (rows Solar_in,PV_out; cols e1,e2):
%         A_PV = [ 1  0 ; -1  1 ]
%     Constitutive law: P_elec = eta_PV * P_solar.
%
%   type = 'fuelcell' : comp = HUB_COMPONENT('fuelcell', name, eta_e, eta_th)
%     Unidirectional, MIMO (1-in/2-out) converter -- one hydrogen input
%     drives an electrical AND a thermal output simultaneously.
%     Local graph:
%         H2_in --(input P_H2)--> FC_out --(eta_e)--> Elec_Bus
%                                         --(eta_th)-> Heat_Bus
%     Local incidence matrix (rows H2_in,FC_out; cols e1,e2,e3):
%         A_FC = [ 1  0  0 ; -1  1  1 ]
%     Constitutive law: [P_elec; P_heat] = [eta_e; eta_th] * P_H2.
%     eta_e, eta_th: typical PEMFC/SOFC-CHP efficiencies (e.g. 0.45/0.35);
%     with both numeric, eta_e+eta_th must not exceed 1. Either may
%     instead be a PWL breakpoint struct (pwl_utils.m 'fit') for a
%     variable/part-load efficiency curve.
%
%   type = 'battery' : comp = HUB_COMPONENT('battery', name, v_ch)
%     Bidirectional storage -- TWO independent directed edges (not one
%     signed variable), so charge/discharge can have different
%     efficiencies and be bounded independently:
%         Cell --(input P_dis)------> Elec_Bus     (discharge)
%         Elec_Bus --(dependent v_ch)--> Cell       (charge)
%     P_dis is an exogenous hub input (a dispatch decision, like grid
%     import); P_ch = v_ch * inflow(Elec_Bus) (the dispatch/split
%     mechanism shared with load and other storage). The battery's own
%     round-trip efficiency (eta_ch/eta_dis) is intentionally kept
%     OUTSIDE this port-level model and applied by storage_soc_update.m:
%         E(t+1) = E(t) + eta_ch*P_ch*dt - (P_dis/eta_dis)*dt
%
%   type = 'ev' : comp = HUB_COMPONENT('ev', name, v_ch, plugged_in, v2g_enabled)
%     Structurally identical to 'battery' (an EV battery IS a storage
%     device) plus two physical qualifiers a stationary battery does not
%     have: plugged_in (mobility -- caller must also zero P_EV_dis/v_ch
%     upstream when false) and v2g_enabled (vehicle-to-grid allowed).
%     Defaults: plugged_in=true, v2g_enabled=true.
%
%   type = 'electrolyzer' : comp = HUB_COMPONENT('electrolyzer', name, v_ch, eta_H2)
%     Power-to-Gas: unlike PV/fuel cell (exogenous resource), the
%     electrolyzer is a LOAD on the electrical bus like a battery's
%     charge branch, chained into a conversion edge:
%         Elec_Bus --(dependent v_ch)--> Conv_in --(eta_H2)--> H2_Bus
%     Constitutive law: P_H2 = eta_H2 * (v_ch * inflow(Elec_Bus)).
%     Demonstrates that energy_hub_assemble.m handles an entirely new
%     component type and carrier bus ('H2_Bus') with zero changes to the
%     assembler or any other component.
%
%   `name` must be a unique instance identifier (e.g. 'PV1') so several
%   instances of the same type can coexist in one hub without node
%   clashes (energy_hub_assemble.m namespaces every non-bus node to it).

    switch type
        case 'pv'
            eta_PV = varargin{1};
            comp.name = name;
            comp.edges = { ...
                eh_edge('Solar_in', 'PV_out', 'input', 1, ['P_solar_' name], ...
                    [name ': solar resource -> PV array (exogenous input)']), ...
                eh_edge('PV_out', 'Elec_Bus', 'dependent', eta_PV, '', ...
                    [name ': PV array output -> electrical bus (eta_PV = ' describe_eta(eta_PV) ')']) ...
            };

        case 'fuelcell'
            eta_e = varargin{1}; eta_th = varargin{2};
            if isnumeric(eta_e) && isnumeric(eta_th) && eta_e + eta_th > 1
                error('hub_component:efficiency', ...
                    'eta_e + eta_th must not exceed 1 (got %.3f).', eta_e + eta_th);
            end
            comp.name = name;
            comp.edges = { ...
                eh_edge('H2_in', 'FC_out', 'input', 1, ['P_H2_' name], ...
                    [name ': hydrogen fuel -> fuel cell (exogenous input)']), ...
                eh_edge('FC_out', 'Elec_Bus', 'dependent', eta_e, '', ...
                    [name ': FC electrical output -> electrical bus (eta_e = ' describe_eta(eta_e) ')']), ...
                eh_edge('FC_out', 'Heat_Bus', 'dependent', eta_th, '', ...
                    [name ': FC recovered heat -> heat bus (eta_th = ' describe_eta(eta_th) ') [MIMO branch]']) ...
            };

        case 'battery'
            v_ch = varargin{1};
            comp.name = name;
            comp.edges = { ...
                eh_edge('Cell', 'Elec_Bus', 'input', 1, ['P_' name '_dis'], ...
                    [name ': battery discharge -> electrical bus (exogenous input)']), ...
                eh_edge('Elec_Bus', 'Cell', 'dependent', v_ch, ['P_' name '_ch'], ...
                    [name ': electrical bus -> battery charge (dispatch v_ch = ' num2str(v_ch) ')']) ...
            };

        case 'ev'
            v_ch = varargin{1};
            plugged_in = true; v2g_enabled = true;
            if numel(varargin) >= 2 && ~isempty(varargin{2}); plugged_in = varargin{2}; end
            if numel(varargin) >= 3 && ~isempty(varargin{3}); v2g_enabled = varargin{3}; end
            if ~plugged_in
                v_ch = 0;
            end
            dischargeLabel = [name ': EV V2G discharge -> electrical bus (exogenous input)'];
            if ~plugged_in
                dischargeLabel = [name ': EV V2G discharge -> electrical bus (unavailable: not plugged in)'];
            elseif ~v2g_enabled
                dischargeLabel = [name ': EV V2G discharge -> electrical bus (disabled for this session)'];
            end
            comp.name = name;
            comp.plugged_in = plugged_in;
            comp.v2g_enabled = v2g_enabled;
            comp.edges = { ...
                eh_edge('Cell', 'Elec_Bus', 'input', 1, ['P_' name '_dis'], dischargeLabel), ...
                eh_edge('Elec_Bus', 'Cell', 'dependent', v_ch, ['P_' name '_ch'], ...
                    [name ': electrical bus -> EV charge (dispatch v_ch = ' num2str(v_ch) ')']) ...
            };

        case 'electrolyzer'
            v_ch = varargin{1}; eta_H2 = varargin{2};
            comp.name = name;
            comp.edges = { ...
                eh_edge('Elec_Bus', 'Conv_in', 'dependent', v_ch, '', ...
                    [name ': electrical bus -> electrolyzer (dispatch v_ch = ' num2str(v_ch) ')']), ...
                eh_edge('Conv_in', 'H2_Bus', 'dependent', eta_H2, '', ...
                    [name ': electrolyzer output -> hydrogen bus (eta_H2 = ' describe_eta(eta_H2) ')']) ...
            };

        otherwise
            error('hub_component:type', 'Unknown component type "%s".', type);
    end
end

function s = describe_eta(eta)
% Human-readable label for a constant or PWL Eta (see eh_edge.m / pwl_utils.m).
    if isnumeric(eta)
        s = num2str(eta);
    elseif isstruct(eta) && isfield(eta, 'type') && strcmp(eta.type, 'pwl')
        s = sprintf('PWL "%s", %d segments, 0..%.3g kW', eta.name, numel(eta.x)-1, eta.x(end));
    else
        s = '<unrecognized Eta>';
    end
end
