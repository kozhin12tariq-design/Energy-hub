%MAIN_MONTH2A_ARBITRARY_CONFIGURATION_AND_PWL
%Thesis roadmap Month 2, items I-II: standardized coupling matrix for
%arbitrary configurations + piecewise-linearized (PWL) variable
%efficiencies.
%
%   This script covers exactly two modeling steps:
%     1) Automatic generation of energy-flow equations for an ARBITRARY
%        hub configuration: energy_hub_assemble.m auto-detects shared
%        carrier buses by name, and energy_hub_print_equations.m prints
%        the literal equations it derives from any edge list. Proven
%        concretely by building two structurally different hubs from the
%        same component library with zero solver changes.
%     2) Piecewise Linearization (PWL) of variable conversion
%        efficiencies: constant-efficiency models (eta = one number)
%        cause large errors away from the rated operating point; PWL
%        breakpoints track a realistic nonlinear part-load efficiency
%        curve far more closely. Quantified below for the Fuel Cell, PV,
%        and Electrolyzer, then wired into the full hub graph.
%
%   Depends on Month 1's component/graph engine (../month1_component_graph_models).
%
%   Run with:  main_month2a_arbitrary_configuration_and_pwl

clear; clc;
addpath('../month1_component_graph_models');
addpath('../month1_component_graph_models/components');

p = energy_hub_default_params();

%% =====================================================================
%  STEP A: PWL fit quality vs. constant-efficiency baseline
%  =====================================================================
fprintf('=====================================================\n');
fprintf(' PWL fit vs. constant-efficiency baseline\n');
fprintf('=====================================================\n');

nSeg = 5;

% Realistic nonlinear part-load efficiency curves, eta(u) for load
% fraction u = P_in/P_rated in [0,1]:
%  - Fuel cell electrical: "hump" shape (low at both very low load --
%    parasitic/balance-of-plant losses dominate -- and at high load --
%    stack polarization losses dominate -- peaking at part load), the
%    textbook motivation for PWL over a single constant efficiency.
%  - Fuel cell thermal: recoverable heat fraction rises with load.
%  - PV/inverter: classic "Euro efficiency" curve, low at very low load,
%    peak around mid load, slight roll-off at full load.
%  - Electrolyzer: efficiency falls as load (current density) rises.
eta_FC_e_true = @(u) 0.30 + 0.35*sqrt(u) - 0.28*u.^2;
eta_FC_th_true = @(u) 0.15 + 0.25*u.^0.7;
eta_PV_true    = @(u) 0.90 + 0.14*sqrt(u) - 0.09*u;
eta_H2_true    = @(u) 0.78 - 0.10*u - 0.08*u.^2;

curves = { ...
    struct('name','FC1_elec',  'func',eta_FC_e_true,  'Pmax',5, 'label','Fuel cell electrical (H2->elec)'), ...
    struct('name','FC1_heat',  'func',eta_FC_th_true, 'Pmax',5, 'label','Fuel cell thermal    (H2->heat)'), ...
    struct('name','PV1',       'func',eta_PV_true,    'Pmax',6, 'label','PV array/inverter    (solar->elec)'), ...
    struct('name','ELY1',      'func',eta_H2_true,    'Pmax',8, 'label','Electrolyzer          (elec->H2)') ...
};

pwlOf = struct();
fprintf('\n%-38s %10s %10s %10s %8s\n', 'Component branch', 'MaxErr', 'MaxErr', 'RMSE', 'RMSE');
fprintf('%-38s %10s %10s %10s %8s\n', '', 'const[kW]', 'PWL[kW]', 'const', 'PWL');
for i = 1:numel(curves)
    cv = curves{i};
    bkpt = pwl_utils('fit', cv.func, cv.Pmax, nSeg, cv.name);
    pwlOf.(cv.name) = bkpt;

    u_test = linspace(0.02, 1, 400);
    x_test = u_test * cv.Pmax;
    y_true = cv.func(u_test) .* x_test;
    eta_const = cv.func(1.0);
    y_const = eta_const * x_test;
    y_pwl = pwl_utils('eval', bkpt.x, bkpt.y, x_test);

    errConst = abs(y_true - y_const);
    errPwl = abs(y_true - y_pwl);
    fprintf('%-38s %10.4f %10.4f %10.4f %8.4f\n', cv.label, ...
        max(errConst), max(errPwl), sqrt(mean(errConst.^2)), sqrt(mean(errPwl.^2)));
end
fprintf('\n(const = single "nameplate" efficiency at u=1, the traditional\n');
fprintf(' constant-efficiency heuristic; PWL = %d-segment fit. PWL error is\n', nSeg);
fprintf(' one to two orders of magnitude smaller across the whole range.)\n');

%% =====================================================================
%  STEP B: Full hub with PWL-fitted Fuel Cell + PV
%  =====================================================================
fprintf('\n=====================================================\n');
fprintf(' Hub configuration 1: PV1 + FC1 (PWL) + Batt1 + EV1\n');
fprintf('=====================================================\n');

pv1_pwl = hub_component('pv', 'PV1', pwlOf.('PV1'));
fc1_pwl = hub_component('fuelcell', 'FC1', pwlOf.('FC1_elec'), pwlOf.('FC1_heat'));

v_elec = [0.70, 0.20, 0.10];
v_heat = 1.0;
[nodeNames1, edges1, nInputs1, inputLabels1, outIdx1, outputLabels1] = ...
    energy_hub_example_hub(p, v_elec, v_heat, true, pv1_pwl, fc1_pwl);

energy_hub_print_equations(nodeNames1, edges1, inputLabels1, outputLabels1, outIdx1);

fprintf('\nNote: e4 (fuel cell electrical) and e5 (fuel cell thermal) and e2\n');
fprintf('(PV) now show as PWL_<name>(...) instead of a fixed multiplier --\n');
fprintf('this hub is piecewise-linear, so energy_hub_coupling_matrix.m would\n');
fprintf('correctly refuse it (try/catch demo below); use\n');
fprintf('energy_hub_evaluate_hub.m / energy_hub_linearize.m instead.\n');

try
    energy_hub_coupling_matrix(edges1, numel(nodeNames1), nInputs1, outIdx1);
catch pwlGuardErr
    fprintf('\nenergy_hub_coupling_matrix.m correctly refused this PWL hub:\n  %s\n', ...
        pwlGuardErr.message);
end

iH2 = strcmp(inputLabels1, 'P_H2_FC1');
iSolar = strcmp(inputLabels1, 'P_solar_PV1');
iGrid = strcmp(inputLabels1, 'P_grid');
iBd = strcmp(inputLabels1, 'P_Batt1_dis');
iEd = strcmp(inputLabels1, 'P_EV1_dis');

fprintf('\n--- Exact PWL evaluation at two fuel-cell load points ---\n');
for PH2val = [1.0, 4.5]
    P0 = zeros(nInputs1,1);
    P0(iGrid)=0.5; P0(iH2)=PH2val; P0(iSolar)=2.0; P0(iBd)=0; P0(iEd)=0;
    f0 = energy_hub_evaluate_hub(edges1, numel(nodeNames1), nInputs1, P0);
    Lelec = f0(outIdx1(strcmp(outputLabels1,'L_elec')));
    Lheat = f0(outIdx1(strcmp(outputLabels1,'L_heat')));
    fprintf('  P_H2_FC1=%.2f kW (load fraction u=%.2f): L_elec=%.4f kW, L_heat=%.4f kW\n', ...
        PH2val, PH2val/5, Lelec, Lheat);
end

fprintf('\n--- Local linearization vs. exact PWL, moving away from P0 ---\n');
P0 = zeros(nInputs1,1);
P0(iGrid)=0.5; P0(iH2)=1.0; P0(iSolar)=2.0; P0(iBd)=0; P0(iEd)=0;
[C_local, d_local, f0] = energy_hub_linearize(edges1, numel(nodeNames1), nInputs1, outIdx1, P0);
L0_lin = C_local*P0 + d_local;
L0_exact = f0(outIdx1);
fprintf('  At P0 itself: local-affine L = [%s], exact PWL L = [%s] (match: %d)\n', ...
    sprintf('%.4f ', L0_lin), sprintf('%.4f ', L0_exact), all(abs(L0_lin-L0_exact) < 1e-9));

for delta = [0.2, 1.0, 3.5]
    P1 = P0; P1(iH2) = P0(iH2) + delta;
    L1_lin = C_local*P1 + d_local;
    f1 = energy_hub_evaluate_hub(edges1, numel(nodeNames1), nInputs1, P1);
    L1_exact = f1(outIdx1);
    iLelec = strcmp(outputLabels1,'L_elec');
    fprintf('  P_H2_FC1 = %.2f kW (+%.1f from P0): local-linear L_elec=%.4f, exact L_elec=%.4f, error=%.4f kW\n', ...
        P1(iH2), delta, L1_lin(iLelec), L1_exact(iLelec), abs(L1_lin(iLelec)-L1_exact(iLelec)));
end
fprintf('\n(Error grows once P_H2_FC1 leaves the segment active at P0 -- exactly\n');
fprintf(' why PWL uses several local pieces instead of one constant eta: each\n');
fprintf(' piece only needs to be accurate over its own short interval.)\n');

%% =====================================================================
%  STEP C: A structurally DIFFERENT hub, same assembler, zero code changes
%  =====================================================================
fprintf('\n=====================================================\n');
fprintf(' Hub configuration 2: PV1 + PV2 + Electrolyzer1 (Power-to-Gas)\n');
fprintf('=====================================================\n');

pv2_curve = pwlOf.('PV1');
pv2_curve.name = 'PV2'; % same fitted curve shape, but its own label in printed equations
pv2_pwl = hub_component('pv', 'PV2', pv2_curve);

% Electrolyzer is the sole consumer on Elec_Bus in this configuration
% (all PV output is routed to Power-to-Gas), so its dispatch share = 1,
% exactly like the single-load Heat_Bus case in hub configuration 1.
ely1_pwl = hub_component('electrolyzer', 'ELY1', 1.0, pwlOf.('ELY1'));

components2 = {pv1_pwl, pv2_pwl, ely1_pwl};

extraEdges2 = { ...
    eh_edge('H2_Bus', 'H2_Product', 'dependent', 1.0, 'L_H2', 'Hydrogen bus -> exported product') ...
};

[nodeNames2, edges2, nInputs2, inputLabels2, outIdx2, outputLabels2] = ...
    energy_hub_assemble(components2, extraEdges2);

fprintf('\nGlobal nodes (%d): %s\n', numel(nodeNames2), strjoin(nodeNames2, ', '));
energy_hub_print_equations(nodeNames2, edges2, inputLabels2, outputLabels2, outIdx2);

P2 = zeros(nInputs2,1);
P2(strcmp(inputLabels2,'P_solar_PV1')) = 4.0;
P2(strcmp(inputLabels2,'P_solar_PV2')) = 3.0;
f2 = energy_hub_evaluate_hub(edges2, numel(nodeNames2), nInputs2, P2);
fprintf('\nExample: P_solar_PV1=4.0, P_solar_PV2=3.0 kW (all routed to electrolysis)\n');
fprintf('  -> L_H2 = %.4f kW (%d nodes, %d edges -- built by the SAME\n', ...
    f2(outIdx2(strcmp(outputLabels2,'L_H2'))), numel(nodeNames2), numel(edges2));
fprintf('     energy_hub_assemble.m / energy_hub_evaluate_hub.m as configuration 1,\n');
fprintf('     with no component-count-specific or topology-specific code.)\n');

try
    energy_hub_plot_graph(nodeNames1, edges1);
    energy_hub_plot_graph(nodeNames2, edges2);
catch plot_err
    fprintf('\n[plots skipped: %s]\n', plot_err.message);
end
