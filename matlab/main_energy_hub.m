%MAIN_ENERGY_HUB Fuel Cell + PV + Battery + EV energy hub demo.
%
%   Builds the hub as a node/edge graph, derives the coupling matrix two
%   ways (from the incidence matrix, and from the classical closed-form
%   expression) and checks they agree, evaluates one example operating
%   point, then runs a simple 24-hour rule-based dispatch to show the
%   framework being used over time with battery and EV state of charge.
%
%   Run with:  main_energy_hub

clear; clc;

%% 1) Parameters and network definition -----------------------------------
p = energy_hub_default_params();

v_example = [0.70, 0.20, 0.10];   % dispatch factors: [load, batt charge, EV charge]

[nodeNames, edges, nNodes, nInputs, outIdx] = ...
    energy_hub_define_network(p.eta_FC, p.eta_PV, v_example);

fprintf('Energy hub nodes (%d):\n', nNodes);
for i = 1:nNodes
    fprintf('  %d: %s\n', i, nodeNames{i});
end
fprintf('\nEnergy hub edges (%d):\n', numel(edges));
for k = 1:numel(edges)
    fprintf('  e%-2d %-9s -> %-9s  type=%-9s eta=%.3f  (%s)\n', k, ...
        nodeNames{edges(k).From}, nodeNames{edges(k).To}, ...
        edges(k).Type, edges(k).Eta, edges(k).Label);
end

%% 2) Incidence matrix -----------------------------------------------------
A = energy_hub_incidence_matrix(edges, nNodes);
fprintf('\nIncidence matrix A (%d nodes x %d edges):\n', size(A,1), size(A,2));
disp(A);

%% 3) Coupling matrix: incidence-matrix method vs classical method --------
[C_incidence, ~, M, N] = energy_hub_coupling_matrix(edges, nNodes, nInputs, outIdx);
C_classic = energy_hub_coupling_matrix_classic(p.eta_FC, p.eta_PV, v_example);

fprintf('\nCoupling matrix from incidence-matrix reformulation, C = S*(M\\N):\n');
disp(C_incidence);
fprintf('Coupling matrix from classical closed form, C = v''*eta_row:\n');
disp(C_classic);

err = norm(C_incidence - C_classic, 'fro');
fprintf('Frobenius norm of the difference between the two methods: %.3e\n', err);
if err < 1e-9
    fprintf('=> incidence-matrix reformulation matches the classical coupling matrix.\n');
else
    warning('Coupling matrices do not match - check the network definition.');
end

%% 4) Example single operating point ---------------------------------------
% P = [P_grid; P_H2; P_solar; P_batt_discharge; P_EV_discharge]
P = [2.0; 1.0; 3.0; 0.5; 0.0];
L = C_incidence * P;

fprintf('\nExample operating point:\n');
fprintf('  P_grid = %.2f kW, P_H2 = %.2f kW, P_solar = %.2f kW, P_batt_dis = %.2f kW, P_EV_dis = %.2f kW\n', P);
fprintf('  -> L_elec = %.3f kW, P_batt_charge = %.3f kW, P_EV_charge = %.3f kW\n', L);
fprintf('  Bus power in  = %.3f kW\n', P(1) + p.eta_FC*P(2) + p.eta_PV*P(3) + P(4) + P(5));
fprintf('  Bus power out = %.3f kW (sum of L, must match bus power in)\n', sum(L));

%% 5) 24-hour illustrative rule-based dispatch ------------------------------
% NOTE: this is a simple priority-order heuristic to exercise the model
% over time (PV -> battery/EV -> fuel cell -> grid), not an optimizer.
hours = (1:24)';
P_solar_avail = max(0, 6.0 * sin(pi * (hours - 6) / 13));
P_solar_avail(hours < 6 | hours > 19) = 0;
L_demand = 1.5 + 2.0*exp(-((hours-19).^2)/8) + 1.0*exp(-((hours-8).^2)/4);
EV_plugged = (hours >= 19) | (hours <= 7);
FC_Pmax = 3.0;

SOC_batt = zeros(24,1); SOC_EV = zeros(24,1);
soc_b = p.Batt.SOC0; soc_e = p.EV.SOC0;

hist = struct('P_grid',zeros(24,1),'P_H2',zeros(24,1),'P_solar',zeros(24,1), ...
    'P_batt_dis',zeros(24,1),'P_EV_dis',zeros(24,1),'L_elec',zeros(24,1), ...
    'P_batt_ch',zeros(24,1),'P_EV_ch',zeros(24,1));

for t = 1:24
    Ld = L_demand(t);
    ac_pv = p.eta_PV * P_solar_avail(t);

    Pg = 0; PH2 = 0; Ps = P_solar_avail(t); Pbd = 0; Ped = 0;
    Pbc_target = 0; Pec_target = 0;

    if ac_pv >= Ld
        surplus = ac_pv - Ld;
        room_batt = max(0, (p.Batt.SOCmax - soc_b) * p.Batt.Emax / p.Batt.eta_ch);
        Pbc_target = min([surplus, p.Batt.Pch_max, room_batt]);
        surplus = surplus - Pbc_target;
        if EV_plugged(t)
            room_ev = max(0, (p.EV.SOCmax - soc_e) * p.EV.Emax / p.EV.eta_ch);
            Pec_target = min([surplus, p.EV.Pch_max, room_ev]);
            surplus = surplus - Pec_target;
        end
        % remaining surplus (if any) is curtailed: clip solar input used
        Ps = P_solar_avail(t) - surplus / max(p.eta_PV, eps);
        Ps = max(Ps, 0);
    else
        deficit = Ld - ac_pv;
        avail_batt = max(0, (soc_b - p.Batt.SOCmin) * p.Batt.Emax * p.Batt.eta_dis);
        Pbd = min([deficit, p.Batt.Pdis_max, avail_batt]);
        deficit = deficit - Pbd;
        if EV_plugged(t) && deficit > 0
            avail_ev = max(0, (soc_e - p.EV.SOCmin) * p.EV.Emax * p.EV.eta_dis);
            Ped = min([deficit, p.EV.Pdis_max, avail_ev]);
            deficit = deficit - Ped;
        end
        if deficit > 0
            PH2 = min(deficit, FC_Pmax) / p.eta_FC;
            deficit = deficit - min(deficit, FC_Pmax);
        end
        if deficit > 0
            Pg = deficit; % grid covers the rest
        end
    end

    bus_total = Pg + p.eta_FC*PH2 + p.eta_PV*Ps + Pbd + Ped;
    if bus_total > 1e-9
        v_t = [Ld, Pbc_target, Pec_target] / bus_total;
    else
        v_t = [1 0 0];
    end
    v_t = v_t / sum(v_t); % guard against rounding drift

    [~, edges_t, ~, ~, outIdx_t] = energy_hub_define_network(p.eta_FC, p.eta_PV, v_t);
    C_t = energy_hub_coupling_matrix(edges_t, nNodes, nInputs, outIdx_t);
    P_t = [Pg; PH2; Ps; Pbd; Ped];
    L_t = C_t * P_t;

    soc_b = soc_b + (p.Batt.eta_ch * L_t(2) - Pbd / p.Batt.eta_dis) * 1 / p.Batt.Emax;
    soc_e = soc_e + (p.EV.eta_ch   * L_t(3) - Ped / p.EV.eta_dis)   * 1 / p.EV.Emax;
    soc_b = min(max(soc_b, p.Batt.SOCmin), p.Batt.SOCmax);
    soc_e = min(max(soc_e, p.EV.SOCmin),  p.EV.SOCmax);
    SOC_batt(t) = soc_b; SOC_EV(t) = soc_e;

    hist.P_grid(t)=Pg; hist.P_H2(t)=PH2; hist.P_solar(t)=Ps;
    hist.P_batt_dis(t)=Pbd; hist.P_EV_dis(t)=Ped;
    hist.L_elec(t)=L_t(1); hist.P_batt_ch(t)=L_t(2); hist.P_EV_ch(t)=L_t(3);
end

fprintf('\n24-hour dispatch summary:\n');
fprintf(' hr  Pgrid  PH2  Psolar Pbdis PEVdis | Lelec Pbch PEVch | SOCbatt SOCEV\n');
for t = 1:24
    fprintf('%3d  %5.2f %5.2f %5.2f %5.2f %5.2f | %5.2f %5.2f %5.2f | %6.2f %6.2f\n', ...
        t, hist.P_grid(t), hist.P_H2(t), hist.P_solar(t), hist.P_batt_dis(t), hist.P_EV_dis(t), ...
        hist.L_elec(t), hist.P_batt_ch(t), hist.P_EV_ch(t), SOC_batt(t), SOC_EV(t));
end

%% 6) Plots ------------------------------------------------------------------
try
    energy_hub_plot_graph(nodeNames, edges);

    figure;
    subplot(2,1,1);
    area(hours, [hist.P_grid, hist.P_H2, hist.P_solar, hist.P_batt_dis, hist.P_EV_dis]);
    hold on; plot(hours, L_demand, 'k--', 'LineWidth', 1.5);
    legend('Grid','Fuel Cell','PV','Battery dis.','EV dis. (V2G)','Load demand', 'Location','bestoutside');
    xlabel('Hour'); ylabel('Power (kW)'); title('Energy hub inputs vs electric load');
    grid on;

    subplot(2,1,2);
    plot(hours, SOC_batt*100, '-o', hours, SOC_EV*100, '-s', 'LineWidth', 1.5);
    legend('Battery SOC','EV SOC','Location','bestoutside');
    xlabel('Hour'); ylabel('SOC (%)'); title('Storage state of charge');
    grid on;
catch plot_err
    fprintf('\n[plots skipped: %s]\n', plot_err.message);
end
