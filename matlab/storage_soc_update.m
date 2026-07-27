function SOC_next = storage_soc_update(SOC, P_ch, P_dis, eta_ch, eta_dis, Emax, dt)
%STORAGE_SOC_UPDATE State-of-charge update for a bidirectional storage branch.
%
%   SOC_next = STORAGE_SOC_UPDATE(SOC, P_ch, P_dis, eta_ch, eta_dis, Emax, dt)
%
%   Applies the physical round-trip efficiency that is deliberately kept
%   outside the port-level coupling matrix (see component_battery.m /
%   component_ev.m): P_ch, P_dis are bus-side (port) powers, eta_ch/
%   eta_dis convert them to actual stored-energy change.
%
%       E(t+1) = E(t) + eta_ch*P_ch*dt - (P_dis/eta_dis)*dt
%       SOC = E / Emax

    SOC_next = SOC + (eta_ch * P_ch - P_dis / eta_dis) * dt / Emax;
end
