%MAIN_MONTH2B_IEEE33_GRID_INTEGRATION
%Thesis roadmap Month 2, item III: integrate the Energy Hub model as
%active nodes within the standard IEEE 33-bus distribution test system,
%and evaluate power flow interactions.
%
%   Two parts:
%     1) Validate the backward-forward-sweep power flow solver
%        (distflow_bfs.m) against the widely-published benchmark result
%        for this exact test system (min voltage ~0.9131 pu at bus 18,
%        total losses ~202.7 kW) -- so the "before" picture is trustworthy.
%     2) Site energy hubs (built with the same component/graph machinery
%        as Month 1) at three buses, replacing each bus's fixed nominal
%        load with the hub's actual net grid draw (P_grid) -- one
%        favorable scenario (solar-rich midday, hub mostly self-supplies
%        its local demand), one on the largest load bus in the system,
%        and one adverse scenario (evening peak, no solar, EV charging
%        adds demand) so the comparison is honest, not just the
%        flattering case. Re-run the power flow and report the
%        voltage-profile and loss impact.
%
%   Depends on Month 1's component/graph engine (../month1_component_graph_models).
%
%   Run with:  main_month2b_ieee33_grid_integration

clear; clc;
addpath('../month1_component_graph_models');
addpath('../month1_component_graph_models/components');

%% 1) Base case + validation --------------------------------------------
fprintf('=====================================================\n');
fprintf(' IEEE 33-bus base case (no hubs) + solver validation\n');
fprintf('=====================================================\n');

[branches, busP_base, busQ_base, Vbase_kV] = ieee33_data();
[V_base, ~, Ploss_base, Qloss_base] = distflow_bfs(branches, busP_base, busQ_base, Vbase_kV);
Vmag_base = abs(V_base) / Vbase_kV;
[minV_base, minBus_base] = min(Vmag_base);

fprintf('Total feeder load: %.0f kW, %.0f kVAr\n', sum(busP_base), sum(busQ_base));
fprintf('Total losses:       P = %.3f kW, Q = %.3f kVAr\n', Ploss_base, Qloss_base);
fprintf('Minimum voltage:    %.4f pu at bus %d\n', minV_base, minBus_base);
fprintf(['Published benchmark for this exact system (Baran & Wu 33-bus): ' ...
    'losses ~202.7 kW, min voltage ~0.9131 pu at bus 18 -- match: %d\n'], ...
    abs(Ploss_base - 202.7) < 0.1 && minBus_base == 18 && abs(minV_base - 0.9131) < 1e-3);

%% 2) Energy hubs as active nodes ----------------------------------------
fprintf('\n=====================================================\n');
fprintf(' Siting energy hubs as active nodes\n');
fprintf('=====================================================\n');

p = energy_hub_default_params();

% Each scenario: [P_grid, P_H2, P_solar, P_batt_dis, P_EV_dis], v_elec.
% P_grid is the hub's chosen net draw from the feeder -- this becomes the
% new bus injection, replacing the bus's original fixed load. Reactive
% power is left at the bus's nominal value (hub inverters assumed to run
% near unity power factor -- this model does not track Q).
% Bus 33's scenario is deliberately adverse: an EV charging depot at
% evening peak, no solar, battery already depleted -- net grid draw
% comes out HIGHER than the original nominal load, to show that
% flexibility is not automatically beneficial to the grid if uncoordinated.
scenarios = struct( ...
    'bus',    {18,                          25,                                          33}, ...
    'label',  {'Bus 18: solar-rich midday', 'Bus 25: solar-rich midday (largest load)', 'Bus 33: evening peak, EV depot charging, no solar, battery depleted'}, ...
    'P',      {[15;20;70;5;0],              [100;60;250;20;0],                           [85;5;0;0;0]}, ...
    'v_elec', {[0.85,0.10,0.05],            [0.90,0.07,0.03],                            [0.55,0.00,0.45]} ...
);

busP_hub = busP_base;
busQ_hub = busQ_base;

for s = 1:numel(scenarios)
    sc = scenarios(s);
    [nodeNames_sc, edges_sc, nInputs_sc, ~, outIdx_sc, outputLabels_sc] = energy_hub_example_hub(p, sc.v_elec, 1.0);
    C_sc = energy_hub_coupling_matrix(edges_sc, numel(nodeNames_sc), nInputs_sc, outIdx_sc);
    L_sc = C_sc * sc.P;

    P_grid_new = sc.P(1);
    L_elec = L_sc(strcmp(outputLabels_sc, 'L_elec'));

    fprintf('\n%s\n', sc.label);
    fprintf('  P_grid=%.1f, P_H2=%.1f, P_solar=%.1f, P_batt_dis=%.1f, P_EV_dis=%.1f kW\n', sc.P);
    fprintf('  -> hub-served local demand L_elec = %.2f kW (bus''s original nominal load = %.0f kW)\n', ...
        L_elec, busP_base(sc.bus));
    fprintf('  -> new bus injection: P = %.1f kW (was %.0f kW), Q unchanged at %.0f kVAr\n', ...
        P_grid_new, busP_base(sc.bus), busQ_base(sc.bus));

    busP_hub(sc.bus) = P_grid_new;
end

%% 3) Isolate bus 33's adverse scenario (no confounding from buses 18/25) --
% Bus 33 shares its upstream trunk (buses 1-6) with the two beneficial
% hub sites, so running all three together could hide a genuinely
% adverse LOCAL effect behind upstream trunk-voltage gains from the
% other two. Run bus 33's scenario alone against the base case first to
% see its true local impact, uncontaminated by the other sites.
busP_bus33_only = busP_base;
busP_bus33_only(33) = busP_hub(33);
[V_33only] = distflow_bfs(branches, busP_bus33_only, busQ_base, Vbase_kV);
Vmag_33only = abs(V_33only) / Vbase_kV;
fprintf('\n--- Bus 33''s scenario in isolation (buses 18, 25 left at nominal load) ---\n');
fprintf('  V(33): base = %.4f pu, with only the bus-33 hub = %.4f pu (%+.4f pu)\n', ...
    Vmag_base(33), Vmag_33only(33), Vmag_33only(33) - Vmag_base(33));
fprintf('  Confirms the locally adverse effect (EV depot demand > original load): voltage drops\n');
fprintf('  when isolated. Whether that survives once ALL THREE hubs run together -- see below --\n');
fprintf('  depends on what else is happening on the shared upstream trunk (buses 1-6).\n');

%% 4) Re-run power flow with all hubs active -------------------------------
fprintf('\n=====================================================\n');
fprintf(' Power flow with all three energy hubs active together\n');
fprintf('=====================================================\n');

[V_hub, ~, Ploss_hub, Qloss_hub] = distflow_bfs(branches, busP_hub, busQ_hub, Vbase_kV);
Vmag_hub = abs(V_hub) / Vbase_kV;
[minV_hub, minBus_hub] = min(Vmag_hub);

fprintf('Total feeder load: %.1f kW, %.1f kVAr (was %.0f kW, %.0f kVAr)\n', ...
    sum(busP_hub), sum(busQ_hub), sum(busP_base), sum(busQ_base));
fprintf('Total losses:       P = %.3f kW (was %.3f kW, %+.3f kW, %+.1f%%)\n', ...
    Ploss_hub, Ploss_base, Ploss_hub - Ploss_base, 100*(Ploss_hub-Ploss_base)/Ploss_base);
fprintf('Minimum voltage:    %.4f pu at bus %d (was %.4f pu at bus %d)\n', ...
    minV_hub, minBus_hub, minV_base, minBus_base);
fprintf('\nV(33) with all three hubs = %.4f pu (%+.4f pu vs. base) -- despite bus 33''s OWN\n', ...
    Vmag_hub(33), Vmag_hub(33) - Vmag_base(33));
fprintf('injection increasing, the net effect here is still slightly positive: buses 18 and 25''s\n');
fprintf('large reductions lower the current on the shared upstream trunk (buses 1-6), raising the\n');
fprintf('trunk voltage that bus 33''s own lateral branches off from, by more than its local increase\n');
fprintf('costs it. Power-flow interactions in a shared-trunk network are network-wide, not purely\n');
fprintf('local -- exactly what siting hubs "as active nodes" is meant to let you evaluate.\n');

fprintf('\nPer-bus voltage change at the active-node buses and their neighbors:\n');
fprintf('%6s %10s %10s %10s\n', 'Bus', 'V_base(pu)', 'V_hub(pu)', 'Delta(pu)');
reportBuses = unique([1, 6, 17, 18, 23, 24, 25, 26, 31, 32, 33]);
for b = reportBuses
    fprintf('%6d %10.4f %10.4f %+10.4f\n', b, Vmag_base(b), Vmag_hub(b), Vmag_hub(b)-Vmag_base(b));
end

%% 5) Plot voltage profile comparison --------------------------------------
try
    figure('Position', [100 100 900 500]);
    plot(1:33, Vmag_base, '-o', 'LineWidth', 1.5, 'DisplayName', 'Base case (no hubs)'); hold on;
    plot(1:33, Vmag_hub, '-s', 'LineWidth', 1.5, 'DisplayName', 'With energy hubs');
    plot([1 33], [0.95 0.95], '--', 'Color', [0.6 0.6 0.6], 'DisplayName', 'Typical 0.95 pu limit');
    xlabel('Bus index'); ylabel('Voltage magnitude (pu)');
    title('IEEE 33-bus voltage profile: base case vs. energy hubs as active nodes');
    legend('Location', 'southwest'); grid on;
    xlim([1 33]);
catch plot_err
    fprintf('\n[plot skipped: %s]\n', plot_err.message);
end
