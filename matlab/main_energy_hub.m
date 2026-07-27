%MAIN_ENERGY_HUB Fuel Cell + PV + Battery + EV energy hub: component models
%and graph-theoretic (incidence-matrix) hub assembly.
%
%   This script covers exactly two modeling steps:
%     1) Individual component models (PV, Fuel Cell, Battery, EV) built
%        with the incidence-and-coupling-matrix approach, each shown
%        standalone with its own local incidence matrix.
%     2) A graph-theory hub assembly (energy_hub_assemble.m) that wires
%        the components onto shared carrier buses (electricity, heat)
%        and derives the hub's global coupling matrix from the global
%        incidence matrix -- demonstrating bidirectional flow (battery/
%        EV charge vs. discharge are independent edges) and MIMO
%        conversion (the fuel cell's single hydrogen input drives both
%        an electrical and a thermal output simultaneously).
%
%   Run with:  main_energy_hub

clear; clc;
addpath('components');

p = energy_hub_default_params();

%% 1) Individual component models -------------------------------------
% Each component is defined on its own local graph; here every one is
% displayed standalone (own nodes, own incidence matrix) before anything
% is wired into the hub.
fprintf('=====================================================\n');
fprintf(' STEP 1: Individual component models (incidence matrix)\n');
fprintf('=====================================================\n');

v_elec_probe = [1 0 0]; % placeholder dispatch factors, only used for standalone display
comp_pv_demo    = component_pv('PV1', p.eta_PV);
comp_fc_demo    = component_fuelcell('FC1', p.eta_FC_e, p.eta_FC_th);
comp_batt_demo  = component_battery('Batt1', v_elec_probe(2));
comp_ev_demo    = component_ev('EV1', v_elec_probe(3), true, true);

energy_hub_display_component(comp_pv_demo);
energy_hub_display_component(comp_fc_demo);
energy_hub_display_component(comp_batt_demo);
energy_hub_display_component(comp_ev_demo);

fprintf('\nNote: the Fuel Cell''s local incidence matrix has ONE inflow\n');
fprintf('column (H2) feeding TWO outflow rows (Elec_Bus, Heat_Bus) at\n');
fprintf('node FC_out -- a 1-input/2-output (MIMO) conversion branch.\n');
fprintf('The Battery/EV local incidence matrices have two independent\n');
fprintf('directed edges between the same two nodes (bidirectional flow).\n');

%% 2) Graph-theory hub assembly -----------------------------------------
fprintf('\n=====================================================\n');
fprintf(' STEP 2: Graph assembly (shared buses + incidence matrix)\n');
fprintf('=====================================================\n');

v_elec = [0.70, 0.20, 0.10];  % [load, battery charge, EV charge], sum = 1
v_heat = 1.0;                 % single heat load, all of Heat_Bus goes to it

[nodeNames, edges, nInputs, inputLabels, outputEdgeIdx, outputLabels] = ...
    energy_hub_example_hub(p, v_elec, v_heat);

fprintf('\nGlobal nodes (%d):\n', numel(nodeNames));
for i = 1:numel(nodeNames)
    fprintf('  %2d: %s\n', i, nodeNames{i});
end

fprintf('\nGlobal edges (%d):\n', numel(edges));
for k = 1:numel(edges)
    fprintf('  e%-2d %-14s -> %-14s  %-9s eta=%.3f  [%s] %s\n', k, ...
        nodeNames{edges(k).From}, nodeNames{edges(k).To}, edges(k).Type, ...
        edges(k).Eta, edges(k).Component, edges(k).Label);
end

A = energy_hub_incidence_matrix(edges, numel(nodeNames));
fprintf('\nGlobal incidence matrix A (%d nodes x %d edges):\n', size(A,1), size(A,2));
disp(A);

fprintf('Hub inputs  P (%d): %s\n', nInputs, strjoin(inputLabels, ', '));
fprintf('Hub outputs L (%d): %s\n', numel(outputLabels), strjoin(outputLabels, ', '));

C = energy_hub_coupling_matrix(edges, numel(nodeNames), nInputs, outputEdgeIdx);
fprintf('\nGlobal coupling matrix C, L = C*P:\n');
print_labeled_matrix(C, outputLabels, inputLabels);

%% 3) MIMO check: one fuel input, two simultaneous outputs ---------------
iH2 = find(strcmp(inputLabels, 'P_H2_FC1'));
iLelec = find(strcmp(outputLabels, 'L_elec'));
iLheat = find(strcmp(outputLabels, 'L_heat'));
fprintf('\nMIMO check: column "P_H2_FC1" of C has TWO nonzero rows:\n');
fprintf('  dL_elec/dP_H2_FC1 = %.4f (= v_elec1 * eta_FC_e = %.2f * %.2f)\n', ...
    C(iLelec, iH2), v_elec(1), p.eta_FC_e);
fprintf('  dL_heat/dP_H2_FC1 = %.4f (= v_heat1 * eta_FC_th = %.2f * %.2f)\n', ...
    C(iLheat, iH2), v_heat, p.eta_FC_th);

%% 4) Bidirectional check: two operating points with storage flows reversed
% Note on scope: at this modeling stage (component + graph/incidence
% matrix), the dispatch factors v and the storage discharge inputs P_dis
% are independent free parameters of the coupling matrix -- nothing here
% stops a caller from setting a nonzero charge dispatch AND a nonzero
% discharge input for the same device at once. Forbidding that
% (charge/discharge complementarity) is an operating CONSTRAINT that
% belongs to the optimizer that chooses v and P at each timestep (a later
% stage, e.g. the Month-3 multi-timescale dispatch), not to the graph
% model itself. The two points below are each built with a physically
% consistent dispatch (a device's own charge share is zero whenever it is
% the one discharging) to keep the illustration clean.

fprintf('\n--- Operating point A: Battery discharging, EV charging ---\n');
v_elec_A = [0.70, 0.00, 0.30];   % Batt1 charge share = 0 (it is discharging)
[~, edges_A, ~, inputLabels_A, outIdx_A, outputLabels_A] = ...
    energy_hub_example_hub(p, v_elec_A, v_heat);
C_A = energy_hub_coupling_matrix(edges_A, numel(nodeNames), nInputs, outIdx_A);
P_A = zeros(nInputs,1);
P_A(strcmp(inputLabels_A,'P_grid'))      = 1.0;
P_A(strcmp(inputLabels_A,'P_H2_FC1'))    = 1.0;
P_A(strcmp(inputLabels_A,'P_solar_PV1')) = 2.0;
P_A(strcmp(inputLabels_A,'P_Batt1_dis')) = 1.5;
P_A(strcmp(inputLabels_A,'P_EV1_dis'))   = 0.0;
L_A = C_A * P_A;
print_labeled_vector('P', P_A, inputLabels_A);
print_labeled_vector('L', L_A, outputLabels_A);

fprintf('\n--- Operating point B: Battery charging (PV surplus), EV discharging (V2G) ---\n');
v_elec_B = [0.50, 0.50, 0.00];   % EV1 charge share = 0 (it is discharging); sums to 1
[~, edges_B, ~, inputLabels_B, outIdx_B, outputLabels_B] = ...
    energy_hub_example_hub(p, v_elec_B, v_heat);
C_B = energy_hub_coupling_matrix(edges_B, numel(nodeNames), nInputs, outIdx_B);
P_B = zeros(nInputs,1);
P_B(strcmp(inputLabels_B,'P_grid'))      = 0.0;
P_B(strcmp(inputLabels_B,'P_H2_FC1'))    = 0.0;
P_B(strcmp(inputLabels_B,'P_solar_PV1')) = 6.0;
P_B(strcmp(inputLabels_B,'P_Batt1_dis')) = 0.0;
P_B(strcmp(inputLabels_B,'P_EV1_dis'))   = 1.0;
L_B = C_B * P_B;
print_labeled_vector('P', P_B, inputLabels_B);
print_labeled_vector('L', L_B, outputLabels_B);

fprintf('\n(Battery: discharging in A (P_Batt1_dis=%.2f, P_Batt1_ch=%.2f) vs.\n', ...
    P_A(strcmp(inputLabels_A,'P_Batt1_dis')), L_A(strcmp(outputLabels_A,'P_Batt1_ch')));
fprintf(' charging in B (P_Batt1_dis=%.2f, P_Batt1_ch=%.2f). EV: charging in A\n', ...
    P_B(strcmp(inputLabels_B,'P_Batt1_dis')), L_B(strcmp(outputLabels_B,'P_Batt1_ch')));
fprintf(' (P_EV1_ch=%.2f) vs. V2G discharging in B (P_EV1_dis=%.2f). Both\n', ...
    L_A(strcmp(outputLabels_A,'P_EV1_ch')), P_B(strcmp(inputLabels_B,'P_EV1_dis')));
fprintf(' directions are carried by two independent edges per device (see\n');
fprintf(' component_battery.m / component_ev.m), not by a signed variable.)\n');

%% 5) Energy-balance validation (per carrier, both operating points) -----
for lbl = {'A','B'}
    tag = lbl{1};
    if strcmp(tag,'A'); Pv=P_A; Lv=L_A; il=inputLabels_A; ol=outputLabels_A; else; Pv=P_B; Lv=L_B; il=inputLabels_B; ol=outputLabels_B; end
    Pg  = Pv(strcmp(il,'P_grid'));
    PH2 = Pv(strcmp(il,'P_H2_FC1'));
    Ps  = Pv(strcmp(il,'P_solar_PV1'));
    Pbd = Pv(strcmp(il,'P_Batt1_dis'));
    Ped = Pv(strcmp(il,'P_EV1_dis'));
    elecBusIn  = Pg + p.eta_FC_e*PH2 + p.eta_PV*Ps + Pbd + Ped;
    elecBusOut = Lv(strcmp(ol,'L_elec')) + Lv(strcmp(ol,'P_Batt1_ch')) + Lv(strcmp(ol,'P_EV1_ch'));
    heatBusIn  = p.eta_FC_th * PH2;
    heatBusOut = Lv(strcmp(ol,'L_heat'));
    fprintf('\n--- Energy balance check (operating point %s) ---\n', tag);
    fprintf('  Electrical bus: in = %.4f kW, out = %.4f kW (match: %d)\n', ...
        elecBusIn, elecBusOut, abs(elecBusIn-elecBusOut) < 1e-9);
    fprintf('  Heat bus:       in = %.4f kW, out = %.4f kW (match: %d)\n', ...
        heatBusIn, heatBusOut, abs(heatBusIn-heatBusOut) < 1e-9);
end

%% 6) Plot ------------------------------------------------------------------
try
    energy_hub_plot_graph(nodeNames, edges);
catch plot_err
    fprintf('\n[plot skipped: %s]\n', plot_err.message);
end
