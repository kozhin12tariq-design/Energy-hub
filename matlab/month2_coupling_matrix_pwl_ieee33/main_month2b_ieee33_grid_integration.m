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
%     2) SITING SENSITIVITY OF ONE HUB. This thesis models exactly ONE
%        energy hub containing all technologies. The three cases below
%        are ALTERNATIVE SITINGS of that single hub -- bus 18, then bus
%        25, then bus 33 -- each evaluated ON ITS OWN against the clean
%        base case. They are never active simultaneously, and there is
%        never more than one hub in the system.
%
%        (An earlier version of this script substituted all three buses
%        into one power flow and solved it once, which silently modelled
%        THREE coexisting hubs and is not what the thesis studies. That
%        is fixed here; the useful comparison is preserved, including the
%        deliberately adverse bus-33 case, but each siting now stands
%        alone.)
%
%        The hub replaces its host bus's fixed nominal load with its own
%        net grid draw (P_grid). The three sitings are: a solar-rich
%        midday case at the electrically weakest bus, the same at the
%        largest load bus, and an adverse evening-peak case (no solar,
%        EV depot charging, battery depleted) so the comparison is
%        honest rather than only flattering.
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

%% 2) The single hub as an active node: three alternative sitings --------
fprintf('\n=====================================================\n');
fprintf(' Siting the ONE energy hub as an active node\n');
fprintf('=====================================================\n');

sys = ieee33_system_definition();   % canonical one-hub study system
fprintf(['Study system: ONE energy hub (PV + fuel cell + battery + EV + heat pump),\n' ...
    'default host bus %d. Hub peak import %.1f kW = %.2f%% of the %.0f kW feeder load\n' ...
    'and %.0f%% of that host bus''s own %.0f kW load. Reported both ways so the scale is\n' ...
    'never quoted one-sidedly.\n' ...
    '\nTHIS SCRIPT IS WHERE THAT DEFAULT COMES FROM. The siting comparison below is run\n' ...
    'on a FIXED hub (Month 1/2 parameters, three hand-set operating points) precisely so\n' ...
    'that the buses, not the hub, are what varies. It is the evidence behind two\n' ...
    'decisions taken in hub_sizing.m: bus %d hosts the study hub because it carries the\n' ...
    'feeder''s largest single load and so admits the largest hub, and bus 18 remains the\n' ...
    'most voltage-sensitive point per kW. Those are different questions with different\n' ...
    'answers, which is the point of the pu/kW column further down.\n'], ...
    sys.hostBus, sys.hubPeakImport_kW, sys.penetrationFeeder_pct, sys.feederLoad_kW, ...
    sys.penetrationHostBus_pct, sys.hostBusLoad_kW, sys.hostBus);

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
    'label',  {'SITING A -- hub at bus 18: solar-rich midday (weakest bus)', 'SITING B -- hub at bus 25: solar-rich midday (largest load bus)', 'SITING C -- hub at bus 33: evening peak, EV depot charging, no solar, battery depleted (adverse)'}, ...
    'P',      {[15;20;70;5;0],              [100;60;250;20;0],                           [85;5;0;0;0]}, ...
    'v_elec', {[0.85,0.10,0.05],            [0.90,0.07,0.03],                            [0.55,0.00,0.45]} ...
);

fprintf('\nONE HUB, THREE ALTERNATIVE SITINGS. Each row below is the SAME single hub\n');
fprintf('placed at a different bus and solved on its own against the clean base case.\n');
fprintf('The three are never active at the same time -- there is only ever one hub.\n');

Vmag_sit  = zeros(numel(scenarios), numel(busP_base));
Ploss_sit = zeros(1, numel(scenarios));
minV_sit  = zeros(1, numel(scenarios));
minBus_sit = zeros(1, numel(scenarios));

for s = 1:numel(scenarios)
    sc = scenarios(s);
    [nodeNames_sc, edges_sc, nInputs_sc, ~, outIdx_sc, outputLabels_sc] = energy_hub_example_hub(p, sc.v_elec, 1.0);
    C_sc = energy_hub_coupling_matrix(edges_sc, numel(nodeNames_sc), nInputs_sc, outIdx_sc);
    L_sc = C_sc * sc.P;

    P_grid_new = sc.P(1);
    L_elec = L_sc(strcmp(outputLabels_sc, 'L_elec'));

    % ONE hub: start from the pristine base case every time, substitute a
    % SINGLE bus, solve. No siting ever sees another siting's hub.
    busP_this = busP_base;
    busP_this(sc.bus) = P_grid_new;
    [V_this, ~, Ploss_this] = distflow_bfs(branches, busP_this, busQ_base, Vbase_kV);
    Vmag_this = abs(V_this) / Vbase_kV;
    [mv, mb] = min(Vmag_this);

    Vmag_sit(s,:) = Vmag_this;
    Ploss_sit(s)  = Ploss_this;
    minV_sit(s)   = mv;
    minBus_sit(s) = mb;

    fprintf('\n%s\n', sc.label);
    fprintf('  P_grid=%.1f, P_H2=%.1f, P_solar=%.1f, P_batt_dis=%.1f, P_EV_dis=%.1f kW\n', sc.P);
    fprintf('  -> hub-served local demand L_elec = %.2f kW (bus''s original nominal load = %.0f kW)\n', ...
        L_elec, busP_base(sc.bus));
    fprintf('  -> bus %d injection: P = %.1f kW (was %.0f kW), Q unchanged at %.0f kVAr\n', ...
        sc.bus, P_grid_new, busP_base(sc.bus), busQ_base(sc.bus));
    fprintf('  -> losses %.3f kW (base %.3f, %+.3f kW, %+.1f%%);  min V %.4f pu at bus %d (base %.4f at %d)\n', ...
        Ploss_this, Ploss_base, Ploss_this-Ploss_base, 100*(Ploss_this-Ploss_base)/Ploss_base, ...
        mv, mb, minV_base, minBus_base);
    fprintf('  -> V at its OWN host bus %d: %.4f pu (base %.4f, %+.4f pu)\n', ...
        sc.bus, Vmag_this(sc.bus), Vmag_base(sc.bus), Vmag_this(sc.bus)-Vmag_base(sc.bus));
end

%% 3) Siting comparison ----------------------------------------------------
fprintf('\n=====================================================\n');
fprintf(' Siting comparison (one hub at a time, each vs. base)\n');
fprintf('=====================================================\n');
fprintf('%-10s %10s %11s %11s %11s %11s %13s\n', 'Siting', 'HostBus V', 'dV(host)', ...
    'kW displ.', 'pu/kW', 'Losses kW', 'dLosses kW');
sensPerKW = zeros(1, numel(scenarios));
for s = 1:numel(scenarios)
    b = scenarios(s).bus;
    kWdisp = busP_base(b) - scenarios(s).P(1);          % load displaced at the host bus
    dV = Vmag_sit(s,b) - Vmag_base(b);
    sensPerKW(s) = dV / kWdisp;
    fprintf('bus %-6d %10.4f %+11.4f %11.0f %11.2e %11.3f %+13.3f\n', b, ...
        Vmag_sit(s,b), dV, kWdisp, sensPerKW(s), Ploss_sit(s), Ploss_sit(s)-Ploss_base);
end

fprintf(['\nThe bus-33 siting is the deliberately adverse one and behaves as intended: an EV\n' ...
    'depot charging at evening peak with no solar draws MORE than the nominal load it\n' ...
    'replaces, so its host-bus voltage falls (%+.4f pu) and feeder losses rise (%+.3f kW).\n' ...
    'Flexibility is not automatically good for the grid if it is uncoordinated.\n' ...
    '\nThe two solar-rich sitings both raise their host-bus voltage and cut losses, and the\n' ...
    'bus-25 siting helps most in ABSOLUTE terms (%+.3f kW of losses) because it displaces\n' ...
    'the largest single load on the feeder (%.0f kW). But the two happen to give the same\n' ...
    'host-bus voltage gain (%+.4f pu) from very different amounts of displaced load, so\n' ...
    'read the pu/kW column, not the raw dV: bus 18 returns %.2e pu per kW displaced\n' ...
    'against bus 25''s %.2e, i.e. it is %.1fx more voltage-sensitive because it is the\n' ...
    'electrically weakest point on the feeder. Bus 25 is the better siting for LOSSES,\n' ...
    'bus 18 the better siting for VOLTAGE SUPPORT per kW -- they are different questions\n' ...
    'and the same number does not answer both.\n' ...
    '\nThese are three answers to "where should the one hub go?", not a picture of three\n' ...
    'hubs cooperating. Any trunk-sharing interaction between sitings is deliberately NOT\n' ...
    'reported here, because with one hub in the system it cannot arise.\n'], ...
    Vmag_sit(3,33)-Vmag_base(33), Ploss_sit(3)-Ploss_base, ...
    Ploss_sit(2)-Ploss_base, busP_base(25), Vmag_sit(1,18)-Vmag_base(18), ...
    sensPerKW(1), sensPerKW(2), sensPerKW(1)/sensPerKW(2));

fprintf('\nPer-bus voltage, base vs. each siting (host buses and neighbours):\n');
fprintf('%6s %11s %11s %11s %11s\n', 'Bus', 'V_base', 'hub@18', 'hub@25', 'hub@33');
reportBuses = unique([1, 6, 17, 18, 23, 24, 25, 26, 31, 32, 33]);
for b = reportBuses
    fprintf('%6d %11.4f %11.4f %11.4f %11.4f\n', b, Vmag_base(b), ...
        Vmag_sit(1,b), Vmag_sit(2,b), Vmag_sit(3,b));
end

% Kept for the plot below: the single best-case siting (bus 25).
Vmag_hub = Vmag_sit(2,:);

%% 5) Plot voltage profile comparison --------------------------------------
try
    figure('Position', [100 100 900 500]);
    plot(1:33, Vmag_base, '-o', 'LineWidth', 1.5, 'DisplayName', 'Base case (no hub)'); hold on;
    plot(1:33, Vmag_sit(1,:), '-s', 'LineWidth', 1.2, 'DisplayName', 'One hub sited at bus 18');
    plot(1:33, Vmag_sit(2,:), '-^', 'LineWidth', 1.2, 'DisplayName', 'One hub sited at bus 25');
    plot(1:33, Vmag_sit(3,:), '-v', 'LineWidth', 1.2, 'DisplayName', 'One hub sited at bus 33 (adverse)');
    plot([1 33], [0.95 0.95], '--', 'Color', [0.6 0.6 0.6], 'DisplayName', 'Typical 0.95 pu limit');
    xlabel('Bus index'); ylabel('Voltage magnitude (pu)');
    title('IEEE 33-bus voltage profile: one hub, three alternative sitings');
    legend('Location', 'southwest'); grid on;
    xlim([1 33]);
catch plot_err
    fprintf('\n[plot skipped: %s]\n', plot_err.message);
end
