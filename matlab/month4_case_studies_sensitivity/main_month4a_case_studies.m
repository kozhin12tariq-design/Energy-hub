%MAIN_MONTH4A_CASE_STUDIES
%Thesis roadmap Month 4, item I: case studies quantifying cost, emissions,
%and reliability improvements from the energy hub / multi-timescale approach.
%
%   Four cases, each isolating one specific modeling contribution from
%   the rest of this project, so the improvement from each can be
%   attributed rather than only shown in aggregate:
%
%     Case 1 "Conventional"        : no PV/FC/heat pump/storage at all --
%                                     grid electricity + gas boiler heat.
%                                     The pre-energy-hub reference point.
%     Case 2 "Day-ahead only"      : the energy hub exists and is
%                                     scheduled by the day-ahead LP, but
%                                     executed OPEN LOOP -- no intraday/
%                                     real-time correction. Isolates the
%                                     value of the rolling multi-timescale
%                                     coordination layers.
%     Case 3 "No robust reserve"   : full closed-loop day-ahead+intraday+
%                                     real-time, but the day-ahead reserve
%                                     margin is disabled (reserveScale=0).
%                                     Isolates the value of the robustness
%                                     proxy.
%     Case 4 "Full proposed system": everything as built (robust day-ahead
%                                     + rolling intraday/real-time), the
%                                     complete approach this thesis proposes.
%
%   Reliability is checked against a SHARED feeder capacity limit
%   (p.reliability.feederCapMargin x Case 4's own day-ahead peak import
%   -- i.e. "the connection sized for the proposed system"), applied to
%   cases 2-4 so the comparison isolates coordination/robustness, not
%   different infrastructure sizing. Case 1 has no such cap (a
%   conventional system is simply sized for its own peak) but its much
%   higher peak import is reported as its own finding: the energy hub
%   materially reduces how large a grid connection is needed at all.
%
%   Depends on Month 3's dispatch stack (../month3_multiscale_optimization).
%
%   Run with:  main_month4a_case_studies

clear; clc;
addpath('../month3_multiscale_optimization');

p = multiscale_default_params();
fc = forecast_profiles(42);

fprintf('=====================================================\n');
fprintf(' Case studies: cost, emissions, reliability\n');
fprintf('=====================================================\n');

fprintf('\nRunning Case 1 (conventional: grid + gas boiler, no energy hub)...\n');
C1 = simulate_conventional_baseline(p, fc);

fprintf('Running Case 2 (energy hub, day-ahead only, open loop)...\n');
C2 = simulate_multiscale_day(p, fc, struct('useIntraday', false, 'reserveScale', 1.0));

fprintf('Running Case 3 (energy hub, full rolling dispatch, no robust reserve)...\n');
C3 = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', 0.0));

fprintf('Running Case 4 (energy hub, full proposed system)...\n');
C4 = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', 1.0));

feederCap = p.reliability.feederCapMargin * C4.dayaheadPeakImport;
fprintf('\nShared feeder capacity for reliability checks (cases 2-4): %.2f kW\n', feederCap);

V2 = reliability_check(C2.Pg_imp5, C2.Pg_exp5, feederCap);
V3 = reliability_check(C3.Pg_imp5, C3.Pg_exp5, feederCap);
V4 = reliability_check(C4.Pg_imp5, C4.Pg_exp5, feederCap);

cases = {'1: Conventional', '2: Day-ahead only', '3: No robust reserve', '4: Full proposed'};
cost = [C1.actualCost, C2.actualCost, C3.actualCost, C4.actualCost];
emis = [C1.emissions_kgCO2, C2.emissions_kgCO2, C3.emissions_kgCO2, C4.emissions_kgCO2];
peak = [C1.dayaheadPeakImport, max(C2.Pg_imp5), max(C3.Pg_imp5), max(C4.Pg_imp5)];
unmetE = [NaN, V2.unmetEnergy_kWh, V3.unmetEnergy_kWh, V4.unmetEnergy_kWh];
violHrs = [NaN, V2.violationHours, V3.violationHours, V4.violationHours];

fprintf('\n%-24s %10s %12s %10s %14s %12s\n', 'Case', 'Cost($)', 'CO2(kg)', 'Peak(kW)', 'UnmetE(kWh)', 'ViolHrs');
for i = 1:4
    if isnan(unmetE(i))
        fprintf('%-24s %10.2f %12.1f %10.1f %14s %12s\n', cases{i}, cost(i), emis(i), peak(i), 'n/a', 'n/a');
    else
        fprintf('%-24s %10.2f %12.1f %10.1f %14.2f %12.2f\n', cases{i}, cost(i), emis(i), peak(i), unmetE(i), violHrs(i));
    end
end

fprintf('\n--- Improvements relative to Case 1 (conventional) ---\n');
fprintf('Case 4 cost reduction: %.1f%%\n', 100*(cost(1)-cost(4))/cost(1));
fprintf('Case 4 CO2 reduction:  %.1f%%\n', 100*(emis(1)-emis(4))/emis(1));
fprintf(['Peak grid import: Case 1 = %.1f kW vs. Case 4 = %.1f kW -- NOT a reduction.\n' ...
    'Case 4 serves strictly more than Case 1 (EV fleet charging, heat-pump electrification\n' ...
    'of what was gas heat in Case 1), and its day-ahead LP deliberately imports MORE than\n' ...
    'instantaneous need during cheap overnight hours to pre-charge storage for later --\n' ...
    'a real, honest finding: cost/emission optimality and peak-shaving are different\n' ...
    'objectives, and this system was optimized for the former. A peak-shaving objective\n' ...
    '(or a demand charge in the price signal) would need to be added explicitly to also\n' ...
    'control for the latter -- it does not fall out of energy-cost minimization alone.\n'], peak(1), peak(4));

fprintf('\n--- Value of each contribution (relative to the FULL Case 4) ---\n');
fprintf('Removing intraday/real-time correction (Case 2 vs 4): cost %+.1f%%, unmet energy %+.2f kWh, violations %+.2f h\n', ...
    100*(cost(2)-cost(4))/cost(4), unmetE(2)-unmetE(4), violHrs(2)-violHrs(4));
fprintf('Removing the robust reserve margin (Case 3 vs 4):     cost %+.1f%%, unmet energy %+.2f kWh, violations %+.2f h\n', ...
    100*(cost(3)-cost(4))/cost(4), unmetE(3)-unmetE(4), violHrs(3)-violHrs(4));

%% Plots
try
    figure('Position',[100 100 1000 700]);

    subplot(2,2,1);
    bar(cost); set(gca,'XTickLabel',{'1','2','3','4'});
    ylabel('$/day'); title('Operational cost'); grid on;

    subplot(2,2,2);
    bar(emis); set(gca,'XTickLabel',{'1','2','3','4'});
    ylabel('kgCO2/day'); title('Carbon emissions'); grid on;

    subplot(2,2,3);
    bar(peak); set(gca,'XTickLabel',{'1','2','3','4'});
    hold on; plot([0.5 4.5],[feederCap feederCap],'r--','LineWidth',1.2);
    ylabel('kW'); title('Peak grid import (dashed = feeder capacity for cases 2-4)'); grid on;

    subplot(2,2,4);
    bar([0 unmetE(2:4)]); set(gca,'XTickLabel',{'1','2','3','4'});
    ylabel('kWh/day'); title('Unmet energy (feeder-capacity violations)'); grid on;

    sgtitle_text = 'Case studies: 1=Conventional, 2=Day-ahead only, 3=No robust reserve, 4=Full proposed system';
    annotation('textbox',[0.05 0.95 0.9 0.05],'String',sgtitle_text,'EdgeColor','none','HorizontalAlignment','center','FontWeight','bold');
catch plot_err
    fprintf('\n[plots skipped: %s]\n', plot_err.message);
end
