function comp = component_battery(name, v_ch)
%COMPONENT_BATTERY Individual component model: Battery Energy Storage (BES).
%
%   comp = COMPONENT_BATTERY(name, v_ch)
%
%   Mathematical model
%     Local graph (bidirectional -- two independent directed edges
%     between the storage cell and the electrical bus, not one signed
%     variable, so charge and discharge can carry different
%     efficiencies and be bounded independently):
%         Cell --(input P_dis)------> Elec_Bus     (discharge)
%         Elec_Bus --(dependent v_ch)--> Cell       (charge)
%     Local nodes:  n1 = Cell, n2 = Elec_Bus
%     Local edges:  e1 = (n1,n2) input,  e2 = (n2,n1) dependent
%     Local incidence matrix (rows n1,n2; cols e1,e2):
%         A_batt = [-1   1 ;
%                    1  -1 ]
%
%   Port-level coupling law
%     P_dis (discharge) is an exogenous hub input (a dispatch decision,
%     like grid import); P_ch (charge) = v_ch * inflow(Elec_Bus), i.e.
%     the fraction v_ch of whatever reaches the electrical bus that is
%     routed into the battery (same dispatch-factor mechanism used to
%     split the bus among load / battery-charge / EV-charge).
%
%   Storage state (physical round-trip efficiency)
%     P_dis and P_ch above are bus-side (port) powers. The battery's own
%     charge/discharge efficiencies (eta_ch, eta_dis) relate those port
%     powers to the internal stored energy and are intentionally kept
%     OUTSIDE the port-level coupling matrix, applied by
%     storage_soc_update.m:
%         E(t+1) = E(t) + eta_ch*P_ch*dt - (P_dis/eta_dis)*dt
%
%   v_ch is the dispatch factor for this instance's charge edge (one
%   entry of the electrical bus's dispatch vector, e.g. v_elec(2));
%   pass the value that applies at the operating point being evaluated.

    comp.name = name;
    comp.edges = { ...
        eh_edge('Cell', 'Elec_Bus', 'input', 1, ['P_' name '_dis'], ...
            [name ': battery discharge -> electrical bus (exogenous input)']), ...
        eh_edge('Elec_Bus', 'Cell', 'dependent', v_ch, ['P_' name '_ch'], ...
            [name ': electrical bus -> battery charge (dispatch v_ch = ' num2str(v_ch) ')']) ...
    };
end
