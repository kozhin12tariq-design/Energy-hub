function comp = component_ev(name, v_ch, plugged_in, v2g_enabled)
%COMPONENT_EV Individual component model: Electric Vehicle battery (V2G).
%
%   comp = COMPONENT_EV(name, v_ch, plugged_in, v2g_enabled)
%
%   Structurally identical bidirectional storage branch to
%   component_battery.m (see that file for the local incidence matrix
%   and port-level coupling law) -- an EV battery IS a storage device --
%   but modeled as its own component because it carries two extra
%   physical qualifiers a stationary battery does not:
%     plugged_in  : logical, whether the EV is connected to the hub bus
%                   at this operating point (mobility constraint). When
%                   false, both edges of this component must be held at
%                   zero by the caller (this function only builds the
%                   graph branches; availability is enforced on the flow
%                   values, e.g. by zeroing P_EV_dis and v_ch upstream).
%     v2g_enabled : logical, whether vehicle-to-grid discharge is allowed
%                   for this instance/session.
%
%   Local graph:
%       Cell --(input P_dis)------> Elec_Bus     (V2G discharge)
%       Elec_Bus --(dependent v_ch)--> Cell        (charge)
%
%   As with the battery, v_ch is the dispatch factor for this instance's
%   charge edge (e.g. v_elec(3)) at the operating point being evaluated,
%   and the EV's own eta_ch/eta_dis are applied outside the port-level
%   coupling matrix by storage_soc_update.m.

    if nargin < 3 || isempty(plugged_in);  plugged_in = true;  end
    if nargin < 4 || isempty(v2g_enabled); v2g_enabled = true; end

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
end
