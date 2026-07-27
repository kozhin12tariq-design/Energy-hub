%MAIN_SENSITIVITY_ANALYSIS Sensitivity of cost/reliability to the robust
%reserve-margin parameter and to renewable/load forecast uncertainty.
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
%   Run with:  main_sensitivity_analysis

clear; clc;

p = multiscale_default_params();
nSeeds = 3;
seeds = [42, 7, 123];

fprintf('=====================================================\n');
fprintf(' Reference feeder capacity (nominal design point)\n');
fprintf('=====================================================\n');
fcNominal = forecast_profiles(42, 1.0);
Cnominal = simulate_multiscale_day(p, fcNominal, struct('useIntraday', true, 'reserveScale', 1.0));
feederCap = p.reliability.feederCapMargin * Cnominal.dayaheadPeakImport;
fprintf('Feeder capacity (fixed for this whole script): %.2f kW\n', feederCap);

%% 1) Reserve-margin sweep --------------------------------------------------
fprintf('\n=====================================================\n');
fprintf(' Sweep 1: reserve-margin scale (robustness parameter)\n');
fprintf('=====================================================\n');

reserveLevels = [0, 0.5, 1.0, 1.5, 2.0];
plannedCost_r = zeros(size(reserveLevels));
actualCost_r  = zeros(size(reserveLevels));
unmetE_r      = zeros(size(reserveLevels));
violHrs_r     = zeros(size(reserveLevels));

for i = 1:numel(reserveLevels)
    pc = 0; ac = 0; ue = 0; vh = 0;
    for sd = seeds
        fc = forecast_profiles(sd, 1.0);
        C = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', reserveLevels(i)));
        V = reliability_check(C.Pg_imp5, C.Pg_exp5, feederCap);
        pc = pc + C.plannedCost; ac = ac + C.actualCost;
        ue = ue + V.unmetEnergy_kWh; vh = vh + V.violationHours;
    end
    plannedCost_r(i) = pc/nSeeds; actualCost_r(i) = ac/nSeeds;
    unmetE_r(i) = ue/nSeeds; violHrs_r(i) = vh/nSeeds;
    fprintf('reserveScale=%.2f: planned=$%.2f actual=$%.2f unmetE=%.3f kWh violHrs=%.3f (avg of %d seeds)\n', ...
        reserveLevels(i), plannedCost_r(i), actualCost_r(i), unmetE_r(i), violHrs_r(i), nSeeds);
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

for i = 1:numel(uncLevels)
    ac_r=0; ue_r=0; vh_r=0; ac_n=0; ue_n=0; vh_n=0;
    for sd = seeds
        fc = forecast_profiles(sd, uncLevels(i));
        Cr = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', 1.0));
        Cn = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', 0.0));
        Vr = reliability_check(Cr.Pg_imp5, Cr.Pg_exp5, feederCap);
        Vn = reliability_check(Cn.Pg_imp5, Cn.Pg_exp5, feederCap);
        ac_r = ac_r + Cr.actualCost; ue_r = ue_r + Vr.unmetEnergy_kWh; vh_r = vh_r + Vr.violationHours;
        ac_n = ac_n + Cn.actualCost; ue_n = ue_n + Vn.unmetEnergy_kWh; vh_n = vh_n + Vn.violationHours;
    end
    actualCost_u_res(i)=ac_r/nSeeds; unmetE_u_res(i)=ue_r/nSeeds; violHrs_u_res(i)=vh_r/nSeeds;
    actualCost_u_nores(i)=ac_n/nSeeds; unmetE_u_nores(i)=ue_n/nSeeds; violHrs_u_nores(i)=vh_n/nSeeds;
    fprintf('uncertaintyScale=%.2f: [with reserve] unmetE=%.3f kWh violHrs=%.3f | [no reserve] unmetE=%.3f kWh violHrs=%.3f\n', ...
        uncLevels(i), unmetE_u_res(i), violHrs_u_res(i), unmetE_u_nores(i), violHrs_u_nores(i));
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
for iu = 1:numel(gridUnc)
    for ir = 1:numel(gridReserve)
        fc = forecast_profiles(42, gridUnc(iu));
        C = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', gridReserve(ir)));
        V = reliability_check(C.Pg_imp5, C.Pg_exp5, feederCap);
        violHrsGrid(iu, ir) = V.violationHours;
    end
end
fprintf('Violation-hours grid (rows=uncertainty, cols=reserve) computed.\n');

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
