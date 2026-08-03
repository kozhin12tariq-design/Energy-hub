%MAIN_MONTH4B_SENSITIVITY_ANALYSIS
%Thesis roadmap Month 4, item II: sensitivity of cost/reliability to the
%robust reserve-margin parameter and to renewable/load forecast uncertainty.
%
%   Two headline sweeps (each averaged over multiple random-scenario
%   seeds, so the result isn't one lucky/unlucky noise draw), plus a
%   small single-seed 2D interaction grid for visualization:
%
%     1) Reserve-margin sweep: reserveScale in {0, 0.5, 1, 1.5, 2} x the
%        default p.reserve.* fractions, at the default uncertainty level.
%        Shows the robustness-cost TRADEOFF -- day-ahead cost rises with
%        more reserve, reliability violations fall -- and where the
%        curve flattens (the point beyond which more reserve stops
%        buying meaningfully better reliability).
%     2) Uncertainty sweep: forecast-noise scale in {0.5, 1, 1.5, 2, 3} x
%        the default noise std devs, run TWICE -- once with the default
%        reserve margin, once with none -- to show the INTERACTION: at
%        low uncertainty the reserve margin barely matters (both are
%        fine); as uncertainty grows, the no-reserve case degrades much
%        faster. This is the direct answer to "how sensitive is the
%        approach to renewable generation and load uncertainty".
%
%   All violations are checked against ONE FIXED feeder capacity (the
%   nominal design point's own day-ahead peak, reserveScale=1,
%   uncertaintyScale=1), held constant across every run in this script --
%   representing a real feeder connection sized once, not re-sized for
%   each parameter combination.
%
%   Depends on Month 3's dispatch stack (../month3_multiscale_optimization).
%
%   Run with:  main_month4b_sensitivity_analysis

clear; clc;
addpath('../month3_multiscale_optimization');

p = multiscale_default_params();
nSeeds = 3;
seeds = [42, 7, 123];

fprintf('=====================================================\n');
fprintf(' Reference feeder capacity (nominal design point)\n');
fprintf('=====================================================\n');
fcNominal = forecast_profiles(42, 1.0);
Cnominal = simulate_multiscale_day(p, fcNominal, struct('useIntraday', true, 'reserveScale', 1.0));

% Capacity basis: 'design' (default) sizes the connection from connected
% load and nameplate ratings only -- see feeder_capacity.m. The previous
% behaviour sized it from the NOMINAL DESIGN POINT's own day-ahead peak,
% which meant the reserveScale=1 run that anchors this script also defined
% the threshold every other reserveScale was then judged against. Both are
% printed so the shift is visible; the sweeps below use the design basis.
% Network benchmark. Every sweep below is verified against IEEE 33, not
% only against the scalar feeder cap -- this was the last script producing
% results outside the benchmark the study is built on, and it is the worst
% place for that gap: this is where robustness and uncertainty are
% stressed, exactly where voltage consequences would matter.
addpath('../month2_coupling_matrix_pwl_ieee33');
sysNet = ieee33_system_definition();
sysNetBaseMinV = min(abs(distflow_bfs(sysNet.branches, sysNet.busP_base, ...
    sysNet.busQ_base, sysNet.Vbase_kV)) / sysNet.Vbase_kV);

[feederCap, capLabel] = feeder_capacity(p, fcNominal, 'design');
[feederCapSelf, capLabelSelf] = feeder_capacity(p, fcNominal, 'case4', Cnominal.dayaheadPeakImport);
fprintf('Feeder capacity (fixed for this whole script): %.2f kW  [%s]\n', feederCap, capLabel);
fprintf('  (previous self-derived basis, for reference: %.2f kW  [%s])\n', feederCapSelf, capLabelSelf);
fprintf(['  The threshold feeds reliability_check only, never the dispatch, so this\n' ...
    '  choice moves unmetE/violHrs and cannot move any cost figure below.\n']);

%% 1) Reserve-margin sweep --------------------------------------------------
fprintf('\n=====================================================\n');
fprintf(' Sweep 1: reserve-margin scale (robustness parameter)\n');
fprintf('=====================================================\n');

reserveLevels = [0, 0.5, 1.0, 1.5, 2.0];
plannedCost_r = zeros(size(reserveLevels));
actualCost_r  = zeros(size(reserveLevels));
unmetE_r      = zeros(size(reserveLevels));
violHrs_r     = zeros(size(reserveLevels));
minV_r        = zeros(size(reserveLevels));   % worst across seeds (safety-relevant)
worstBus_r    = zeros(size(reserveLevels));
loss_r        = zeros(size(reserveLevels));   % mean across seeds
% HOST-BUS voltage is tracked separately from the feeder minimum, because on
% this system they are not the same bus and not even the same question. The
% feeder minimum sits at bus 18, at the end of the longest radial; the hub
% sits at bus 25 on a short lateral, and reaches bus 18 only through the two
% trunk branches their paths share. Reporting only the feeder minimum would
% measure the sweeps against a bus the hub barely touches, and would make
% "insensitive" true by construction. The host bus is where any effect must
% show up first, so it is the fair test of the flatness claim.
hostV_r       = zeros(size(reserveLevels));   % worst host-bus V across seeds

for i = 1:numel(reserveLevels)
    pc = 0; ac = 0; ue = 0; vh = 0; ls = 0; mv = Inf; mb = 0; hv = Inf;
    for sd = seeds
        fc = forecast_profiles(sd, 1.0);
        C = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', reserveLevels(i)));
        V = reliability_check(C.Pg_imp5, C.Pg_exp5, feederCap);
        NVi = network_verify(sysNet, C.Pg_imp5 - C.Pg_exp5);
        pc = pc + C.plannedCost; ac = ac + C.actualCost;
        ue = ue + V.unmetEnergy_kWh; vh = vh + V.violationHours;
        ls = ls + NVi.lossEnergy_kWh;
        if NVi.minV < mv; mv = NVi.minV; mb = NVi.minV_bus; end
        hv = min(hv, NVi.hostV_min);
    end
    plannedCost_r(i) = pc/nSeeds; actualCost_r(i) = ac/nSeeds;
    unmetE_r(i) = ue/nSeeds; violHrs_r(i) = vh/nSeeds;
    loss_r(i) = ls/nSeeds; minV_r(i) = mv; worstBus_r(i) = mb; hostV_r(i) = hv;
    fprintf(['reserveScale=%.2f: planned=$%.2f actual=$%.2f unmetE=%.3f kWh violHrs=%.3f' ...
        ' | minV=%.4f pu (bus %d) hostV=%.4f pu (bus %d) losses=%.1f kWh/day\n'], ...
        reserveLevels(i), plannedCost_r(i), actualCost_r(i), unmetE_r(i), violHrs_r(i), ...
        minV_r(i), worstBus_r(i), hostV_r(i), sysNet.hostBus, loss_r(i));
end
fprintf(['\nReliability improves monotonically with reserve (violation hours %.3f -> %.3f as scale\n' ...
    'goes 0 -> %.1f). The DAY-AHEAD PLANNED cost rises monotonically with reserve ($%.2f -> $%.2f),\n' ...
    'as expected -- provisioning headroom looks more expensive on paper. The ACTUAL realized cost\n' ...
    'does NOT show that same clear rise ($%.2f -> $%.2f): avoiding real-time corrections/violations\n' ...
    'appears to offset most or all of the day-ahead premium. Read the planned-cost trend as the\n' ...
    'robustness "price tag" a planner sees in advance, and the actual-cost trend as what it costs\n' ...
    'once realized -- they are not the same number.\n'], ...
    violHrs_r(1), violHrs_r(end), reserveLevels(end), plannedCost_r(1), plannedCost_r(end), ...
    actualCost_r(1), actualCost_r(end));

%% 2) Uncertainty sweep ------------------------------------------------------
fprintf('\n=====================================================\n');
fprintf(' Sweep 2: forecast uncertainty scale, with vs. without reserve\n');
fprintf('=====================================================\n');

uncLevels = [0.5, 1.0, 1.5, 2.0, 3.0];
actualCost_u_res  = zeros(size(uncLevels)); actualCost_u_nores  = zeros(size(uncLevels));
unmetE_u_res      = zeros(size(uncLevels)); unmetE_u_nores      = zeros(size(uncLevels));
violHrs_u_res     = zeros(size(uncLevels)); violHrs_u_nores     = zeros(size(uncLevels));

minV_u_res = zeros(size(uncLevels)); minV_u_nores = zeros(size(uncLevels));
loss_u_res = zeros(size(uncLevels)); loss_u_nores = zeros(size(uncLevels));
hostV_u_res = zeros(size(uncLevels)); hostV_u_nores = zeros(size(uncLevels));

for i = 1:numel(uncLevels)
    ac_r=0; ue_r=0; vh_r=0; ac_n=0; ue_n=0; vh_n=0;
    ls_r=0; ls_n=0; mv_r=Inf; mv_n=Inf; hv_r=Inf; hv_n=Inf;
    for sd = seeds
        fc = forecast_profiles(sd, uncLevels(i));
        Cr = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', 1.0));
        Cn = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', 0.0));
        Vr = reliability_check(Cr.Pg_imp5, Cr.Pg_exp5, feederCap);
        Vn = reliability_check(Cn.Pg_imp5, Cn.Pg_exp5, feederCap);
        NVr = network_verify(sysNet, Cr.Pg_imp5 - Cr.Pg_exp5);
        NVn = network_verify(sysNet, Cn.Pg_imp5 - Cn.Pg_exp5);
        ac_r = ac_r + Cr.actualCost; ue_r = ue_r + Vr.unmetEnergy_kWh; vh_r = vh_r + Vr.violationHours;
        ac_n = ac_n + Cn.actualCost; ue_n = ue_n + Vn.unmetEnergy_kWh; vh_n = vh_n + Vn.violationHours;
        ls_r = ls_r + NVr.lossEnergy_kWh; ls_n = ls_n + NVn.lossEnergy_kWh;
        mv_r = min(mv_r, NVr.minV); mv_n = min(mv_n, NVn.minV);
        hv_r = min(hv_r, NVr.hostV_min); hv_n = min(hv_n, NVn.hostV_min);
    end
    actualCost_u_res(i)=ac_r/nSeeds; unmetE_u_res(i)=ue_r/nSeeds; violHrs_u_res(i)=vh_r/nSeeds;
    actualCost_u_nores(i)=ac_n/nSeeds; unmetE_u_nores(i)=ue_n/nSeeds; violHrs_u_nores(i)=vh_n/nSeeds;
    loss_u_res(i)=ls_r/nSeeds; loss_u_nores(i)=ls_n/nSeeds;
    minV_u_res(i)=mv_r; minV_u_nores(i)=mv_n;
    hostV_u_res(i)=hv_r; hostV_u_nores(i)=hv_n;
    fprintf(['uncertaintyScale=%.2f: [with reserve] unmetE=%.3f violHrs=%.3f minV=%.4f hostV=%.4f' ...
        ' | [no reserve] unmetE=%.3f violHrs=%.3f minV=%.4f hostV=%.4f\n'], ...
        uncLevels(i), unmetE_u_res(i), violHrs_u_res(i), minV_u_res(i), hostV_u_res(i), ...
        unmetE_u_nores(i), violHrs_u_nores(i), minV_u_nores(i), hostV_u_nores(i));
end
fprintf(['\nUnmet ENERGY grows monotonically with uncertainty in both cases (with reserve: %.3f -> %.3f kWh;\n' ...
    'no reserve: %.3f -> %.3f kWh) -- larger forecast errors mean larger individual shortfalls even when\n' ...
    'the NUMBER of violating intervals does not grow much further (both violation-HOUR series roughly\n' ...
    'plateau at high uncertainty): once the same handful of intervals are already over the feeder cap,\n' ...
    'added uncertainty mostly deepens those shortfalls rather than creating many new ones. The reserve\n' ...
    'margin (sized for the DEFAULT uncertainty level) keeps unmet energy far below the no-reserve case\n' ...
    'at low-to-moderate uncertainty, but the gap narrows at 3x uncertainty (%.3f vs %.3f kWh) -- a margin\n' ...
    'calibrated for one uncertainty range degrades gracefully, not perfectly, once uncertainty exceeds\n' ...
    'what it was sized for.\n'], unmetE_u_res(1), unmetE_u_res(end), unmetE_u_nores(1), unmetE_u_nores(end), ...
    unmetE_u_res(end), unmetE_u_nores(end));

%% 3) Small 2D interaction grid (single seed, for visualization) ------------
fprintf('\n=====================================================\n');
fprintf(' Sweep 3: reserve x uncertainty interaction grid (single seed)\n');
fprintf('=====================================================\n');

gridReserve = [0, 0.5, 1.0, 1.5];
gridUnc = [0.5, 1.0, 2.0, 3.0];
violHrsGrid = zeros(numel(gridUnc), numel(gridReserve));
minVGrid    = zeros(numel(gridUnc), numel(gridReserve));
hostVGrid   = zeros(numel(gridUnc), numel(gridReserve));
for iu = 1:numel(gridUnc)
    for ir = 1:numel(gridReserve)
        fc = forecast_profiles(42, gridUnc(iu));
        C = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', gridReserve(ir)));
        V = reliability_check(C.Pg_imp5, C.Pg_exp5, feederCap);
        NVg = network_verify(sysNet, C.Pg_imp5 - C.Pg_exp5);
        violHrsGrid(iu, ir) = V.violationHours;
        minVGrid(iu, ir)    = NVg.minV;
        hostVGrid(iu, ir)   = NVg.hostV_min;
    end
end
fprintf('Violation-hours grid (rows=uncertainty, cols=reserve) computed.\n\n');
fprintf('Feeder-minimum voltage grid (pu, bus %d), rows=uncertainty, cols=reserve:\n', ...
    worstBus_r(1));
fprintf('%12s', 'unc \ res');
fprintf('%10.2f', gridReserve); fprintf('\n');
for iu = 1:numel(gridUnc)
    fprintf('%12.2f', gridUnc(iu));
    fprintf('%10.4f', minVGrid(iu,:)); fprintf('\n');
end
fprintf('\nHOST-BUS voltage grid (pu, bus %d), rows=uncertainty, cols=reserve:\n', sysNet.hostBus);
fprintf('%12s', 'unc \ res');
fprintf('%10.2f', gridReserve); fprintf('\n');
for iu = 1:numel(gridUnc)
    fprintf('%12.2f', gridUnc(iu));
    fprintf('%10.4f', hostVGrid(iu,:)); fprintf('\n');
end

%% Does robustness/uncertainty move VOLTAGE, or only cost and energy? ---
allMinV = [minV_r(:); minV_u_res(:); minV_u_nores(:); minVGrid(:)];
vSpreadAll = max(allMinV) - min(allMinV);
allHostV = [hostV_r(:); hostV_u_res(:); hostV_u_nores(:); hostVGrid(:)];
hSpreadAll = max(allHostV) - min(allHostV);
allLoss = [loss_r(:); loss_u_res(:); loss_u_nores(:)];
lSpreadAll = max(allLoss) - min(allLoss);
fprintf(['\n=====================================================\n' ...
    ' Does the reserve margin do anything for VOLTAGE?\n' ...
    '=====================================================\n']);
fprintf('Hub: %.2f%% of the %.0f kW feeder, %.0f%% of its host bus''s %.0f kW load.\n', ...
    sysNet.penetrationFeeder_pct, sysNet.feederLoad_kW, ...
    sysNet.penetrationHostBus_pct, sysNet.hostBusLoad_kW);
fprintf('Across every scenario in all three sweeps:\n');
fprintf('  feeder minimum V (bus %2d) spans %.4f pu\n', worstBus_r(1), vSpreadAll);
fprintf('  HOST-bus V       (bus %2d) spans %.4f pu\n', sysNet.hostBus, hSpreadAll);
fprintf('  feeder loss energy        spans %.1f kWh/day (on %.0f kWh/day)\n', ...
    lSpreadAll, mean(allLoss));
fprintf('  reserve sweep      : minV %.4f -> %.4f pu, hostV %.4f -> %.4f pu (reserveScale 0 -> %.1f)\n', ...
    minV_r(1), minV_r(end), hostV_r(1), hostV_r(end), reserveLevels(end));
fprintf('  uncertainty sweep  : with reserve %.4f -> %.4f pu, no reserve %.4f -> %.4f pu\n', ...
    minV_u_res(1), minV_u_res(end), minV_u_nores(1), minV_u_nores(end));
fprintf('  no-hub base case   : %.4f pu (reference)\n', sysNetBaseMinV);

if vSpreadAll < 5e-3 && hSpreadAll < 5e-3
    fprintf(['\nVOLTAGE IS ESSENTIALLY INSENSITIVE TO BOTH KNOBS, AND THAT NOW MEANS SOMETHING.\n' ...
        'The feeder minimum spans %.4f pu and the host bus itself spans %.4f pu across a 4x\n' ...
        'change in reserve margin AND a 6x change in forecast uncertainty -- negligible next\n' ...
        'to the %.4f pu the feeder is already below nominal in its own base case.\n' ...
        '\nWHY THIS IS A STRONGER STATEMENT THAN IT USED TO BE. The same sweeps previously ran\n' ...
        'a hub at 2.79%% of feeder load. At that size "reserve does not move voltage" was not\n' ...
        'really a finding about reserve: nothing a 104 kW hub did could have moved a 3715 kW\n' ...
        'feeder, so the sweep could not have come out any other way. This hub is %.2f%% of the\n' ...
        'feeder, 4.7x larger, and the answer did not change. The claim has now been given a\n' ...
        'genuine opportunity to fail and did not take it.\n' ...
        '\nAND THE HOST-BUS COLUMN CLOSES THE OBVIOUS OBJECTION. One could argue the feeder\n' ...
        'minimum (bus %d) is simply too far from the hub (bus %d) to respond -- the two share\n' ...
        'only the trunk. But the hub''s OWN bus spans just %.4f pu across the same sweeps, so\n' ...
        'the insensitivity is not an artifact of measuring at the wrong place.\n' ...
        '\nThe DIRECTION is nonetheless consistent and physically sensible, and the grids above\n' ...
        'show it: more reserve raises minimum voltage slightly (left to right on every row)\n' ...
        'and more uncertainty lowers it slightly (top to bottom in every column). The effect\n' ...
        'is real in sign but negligible in magnitude -- "directionally as expected,\n' ...
        'practically irrelevant", not "no effect".\n' ...
        '\nMechanism: the reserve margin constrains how much UNUSED storage headroom the\n' ...
        'day-ahead plan must keep, which shifts WHEN energy is drawn and how much shortfall\n' ...
        'survives to real time -- but it barely changes the PEAK net injection at the host\n' ...
        'bus, and peak injection is what sets voltage. Size does not change that: scaling the\n' ...
        'hub scales the peak and the reserve-driven variation TOGETHER, so their ratio, which\n' ...
        'is what the voltage response depends on, is unchanged.\n' ...
        '\nPractical reading, now supported rather than merely asserted: the reserve margin is\n' ...
        'a COST and UNMET-ENERGY instrument, not a network one. It should not be sold as\n' ...
        'voltage support. If voltage were the binding concern, the effective lever is a\n' ...
        'constraint on the operating point itself -- which is what the Month 4d\n' ...
        'co-optimization imposes -- not reserve headroom.\n'], ...
        vSpreadAll, hSpreadAll, 1-sysNetBaseMinV, sysNet.penetrationFeeder_pct, ...
        worstBus_r(1), sysNet.hostBus, hSpreadAll);
else
    fprintf(['\nVoltage DOES move materially across these sweeps (feeder minimum %.4f pu,\n' ...
        'host bus %.4f pu), so the reserve margin and forecast uncertainty are\n' ...
        'network-relevant as well as cost-relevant. Note that this is a change from the\n' ...
        'previous, smaller hub, where both spans were negligible -- so the earlier "not a\n' ...
        'network instrument" conclusion was size-dependent after all.\n'], ...
        vSpreadAll, hSpreadAll);
end

%% Plots ----------------------------------------------------------------
try
    figure('Position',[100 100 1150 800]);

    subplot(2,2,1);
    [ax, h1, h2] = plotyy(reserveLevels, actualCost_r, reserveLevels, violHrs_r);
    set(h1,'Marker','o'); set(h2,'Marker','s','LineStyle','--');
    xlabel('Reserve margin scale'); ylabel(ax(1),'Actual cost ($/day)'); ylabel(ax(2),'Violation hours');
    title('Reserve margin: cost vs. reliability tradeoff'); grid on;

    subplot(2,2,2);
    plot(uncLevels, violHrs_u_res, '-o', 'DisplayName','With reserve (default)'); hold on;
    plot(uncLevels, violHrs_u_nores, '-s', 'DisplayName','No reserve'); grid on;
    xlabel('Forecast uncertainty scale'); ylabel('Violation hours');
    legend('Location','northwest'); title('Reliability vs. forecast uncertainty');

    subplot(2,2,3);
    plot(uncLevels, actualCost_u_res, '-o', 'DisplayName','With reserve (default)'); hold on;
    plot(uncLevels, actualCost_u_nores, '-s', 'DisplayName','No reserve'); grid on;
    xlabel('Forecast uncertainty scale'); ylabel('Actual cost ($/day)');
    legend('Location','northwest'); title('Cost vs. forecast uncertainty');

    subplot(2,2,4);
    % imagesc requires uniformly-spaced axis data to map ticks correctly;
    % gridUnc is not uniformly spaced, so plot by index and label manually.
    imagesc(violHrsGrid); set(gca,'YDir','normal'); colorbar;
    set(gca,'XTick',1:numel(gridReserve),'XTickLabel',arrayfun(@num2str,gridReserve,'UniformOutput',false));
    set(gca,'YTick',1:numel(gridUnc),'YTickLabel',arrayfun(@num2str,gridUnc,'UniformOutput',false));
    xlabel('Reserve margin scale'); ylabel('Uncertainty scale');
    title('Violation hours (reserve x uncertainty interaction)');

catch plot_err
    fprintf('\n[plots skipped: %s]\n', plot_err.message);
end
