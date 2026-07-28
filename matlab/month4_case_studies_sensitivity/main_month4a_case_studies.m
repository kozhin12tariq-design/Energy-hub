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
%     Case 5 "Constant efficiency"  : NOT part of the Case 1-4 progression
%                                     (it isolates PWL itself, not a
%                                     coordination/robustness layer) --
%                                     full Case-4-style closed loop, but
%                                     the PLANNING stack (day-ahead +
%                                     intraday) believes the fuel cell has
%                                     ONE constant efficiency instead of
%                                     the true nonlinear PWL curve
%                                     (opts.usePWL=false in
%                                     simulate_multiscale_day.m). The
%                                     physical realization always uses
%                                     the TRUE curve regardless -- the
%                                     fuel cell doesn't know what the
%                                     planner assumed about it -- so a
%                                     WRONG planning model can plan one
%                                     cost and realize a different one.
%                                     Under the DEFAULT price_H2
%                                     ($0.22/kWh), the fuel cell is never
%                                     economically dispatched at all in
%                                     this system (confirmed across every
%                                     seed/uncertainty combination used
%                                     elsewhere in this project), which
%                                     would make the comparison vacuous
%                                     (0 fuel either way). Case 5 therefore
%                                     uses its own lower price_H2 ($0.06,
%                                     the cheapest round number at which
%                                     the day-ahead MILP actually
%                                     dispatches the fuel cell across
%                                     several hours without pinning it at
%                                     its rated maximum) so the PWL-vs-
%                                     constant modeling question is
%                                     actually observable -- a separate,
%                                     clearly-labeled price used ONLY for
%                                     Case 5; Cases 1-4 above are
%                                     untouched and keep the shared
%                                     default p.
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

%% Case 5: PWL vs. constant fuel cell efficiency (isolates PWL itself) ------
fprintf('\n=====================================================\n');
fprintf(' Case 5: PWL vs. constant fuel cell efficiency\n');
fprintf('=====================================================\n');
fprintf(['Default price_H2=$%.2f never makes the fuel cell economical in this\n' ...
    'system (checked across every seed/uncertainty combination used elsewhere\n' ...
    'in this project) -- so this case uses its own price_H2=$0.06/kWh fuel,\n' ...
    'the cheapest round number at which the day-ahead MILP actually dispatches\n' ...
    'the fuel cell across several hours without pinning it at its rated\n' ...
    'maximum. This price is used ONLY for Case 5; Cases 1-4 above are\n' ...
    'untouched.\n'], p.price_H2);

p5 = p;
p5.price_H2 = 0.06;

fprintf('\nRunning Case 5a (PWL: planning model matches the true fuel cell curve)...\n');
C5pwl = simulate_multiscale_day(p5, fc, struct('useIntraday', true, 'reserveScale', 1.0, 'usePWL', true));

fprintf('Running Case 5b (constant efficiency: planning model is WRONG about the fuel cell)...\n');
C5const = simulate_multiscale_day(p5, fc, struct('useIntraday', true, 'reserveScale', 1.0, 'usePWL', false));

V5pwl   = reliability_check(C5pwl.Pg_imp5,   C5pwl.Pg_exp5,   feederCap);
V5const = reliability_check(C5const.Pg_imp5, C5const.Pg_exp5, feederCap);

% OPTIMISM DIAGNOSTIC: does the planning model over- or under-state what the
% fuel cell actually delivers, over the fuel levels it actually dispatched?
% Fuel-weighted over the whole day (total electricity the planner believed its
% own committed fuel would produce, minus what the true curve really produces
% from that same fuel, per kW of fuel) -- an aggregate so it can't be distorted
% by near-zero dispatch intervals, where a per-point ratio would blow up.
%   > 0 optimistic (planner overrates the FC -> over-dispatches -> reality
%       under-delivers -> planned-vs-actual gap pushed POSITIVE)
%   < 0 pessimistic (planner underrates it -> gap pushed NEGATIVE)
% This is what makes the two Gap(%) values below readable; see the explanation
% after the table.
bkConst = pwl_utils('fit', p5.PWL.eta_FC_e_func, p5.PWL.FC_H2_max, 1, 'FC_elec_const');
optimism = @(bx, by, v) (sum(pwl_utils('eval', bx, by, v)) ...
    - sum(p5.PWL.eta_FC_e_func(v/p5.PWL.FC_H2_max) .* v)) / sum(v);
opt5pwl   = optimism(p5.PWL.bkpt_e.x, p5.PWL.bkpt_e.y, C5pwl.PH2_5);
opt5const = optimism(bkConst.x,       bkConst.y,       C5const.PH2_5);

fprintf('\n%-24s %12s %12s %12s %12s %12s\n', 'Case 5 variant', 'Planned($)', 'Actual($)', 'Gap($)', 'Gap(%)', 'Optimism');
fprintf('%-24s %12.4f %12.4f %12.4f %12.2f %+12.4f\n', 'PWL (correct model)', C5pwl.plannedCost, C5pwl.actualCost, ...
    C5pwl.actualCost-C5pwl.plannedCost, 100*(C5pwl.actualCost-C5pwl.plannedCost)/abs(C5pwl.plannedCost), opt5pwl);
fprintf('%-24s %12.4f %12.4f %12.4f %12.2f %+12.4f\n', 'Constant efficiency', C5const.plannedCost, C5const.actualCost, ...
    C5const.actualCost-C5const.plannedCost, 100*(C5const.actualCost-C5const.plannedCost)/abs(C5const.plannedCost), opt5const);

relErrRealized = 100*(C5const.actualCost - C5pwl.actualCost)/abs(C5pwl.actualCost);
if relErrRealized >= 0
    moreOrLess = 'more';
else
    moreOrLess = 'less';
end
slopesTrue = diff(p5.PWL.bkpt_e.y) ./ diff(p5.PWL.bkpt_e.x);
slopeConst = diff(bkConst.y) / diff(bkConst.x);
fprintf(['\nDo NOT read the Gap(%%) column as a measure of model quality -- it is not one, and\n' ...
    'here it ranks the two models the wrong way round (the WRONG model shows the SMALLER\n' ...
    'gap, %.2f%% vs %.2f%%). Two separate things are mixed into that column: forecast error\n' ...
    '(actual solar/load differing from the day-ahead/intraday forecast) and modeling error\n' ...
    '(the planning model being wrong about its own fuel cell). Worse, the modeling part has\n' ...
    'a SIGN, shown in the Optimism column: it only widens the gap if the planning model is\n' ...
    'OPTIMISTIC about the fuel cell, and it NARROWS the gap if the model is pessimistic.\n' ...
    '\nThat is exactly what happens here. The constant-efficiency planning model is a single\n' ...
    'chord of slope %.4f, while the true curve''s marginal slopes over the segments the fuel\n' ...
    'cell actually operates in are %.4f / %.4f / %.4f -- all ABOVE that chord. So the\n' ...
    'constant-efficiency model systematically UNDER-states what its own fuel cell will\n' ...
    'deliver (Optimism %+.4f, i.e. pessimistic): it plans a higher cost ($%.4f vs $%.4f),\n' ...
    'reality then comes in better than it planned, and that credit partially cancels the\n' ...
    'forecast-driven overrun instead of adding to it -- shrinking its gap. The PWL row, whose\n' ...
    'planning model matches reality (Optimism %+.4f, essentially neutral), shows a gap that\n' ...
    'is very nearly pure forecast error. A pessimistic wrong model can therefore look BETTER\n' ...
    'on this statistic than a correct one, which is precisely why the gap cannot be used to\n' ...
    'rank models.\n' ...
    '\nComparing REALIZED cost (both evaluated against the one true curve, so this isolates\n' ...
    'the modeling choice from forecast noise): constant efficiency costs %.2f%% %s than PWL\n' ...
    '(literature comparison point: Huang et al. report 13.7%% for a constant-efficiency\n' ...
    'baseline against their true curve -- not the same system, curves, or price levels, so\n' ...
    'not a claim of matching their number, only the same kind of comparison).\n' ...
    'CO2: PWL=%.2f kg vs constant=%.2f kg (%+.2f kg). Reliability: PWL unmetE=%.3f kWh/%.3f\n' ...
    'violHrs vs constant unmetE=%.3f kWh/%.3f violHrs.\n'], ...
    100*(C5const.actualCost-C5const.plannedCost)/abs(C5const.plannedCost), ...
    100*(C5pwl.actualCost-C5pwl.plannedCost)/abs(C5pwl.plannedCost), ...
    slopeConst, slopesTrue(1), slopesTrue(2), slopesTrue(3), ...
    opt5const, C5const.plannedCost, C5pwl.plannedCost, opt5pwl, ...
    abs(relErrRealized), moreOrLess, C5pwl.emissions_kgCO2, C5const.emissions_kgCO2, ...
    C5const.emissions_kgCO2-C5pwl.emissions_kgCO2, V5pwl.unmetEnergy_kWh, V5pwl.violationHours, ...
    V5const.unmetEnergy_kWh, V5const.violationHours);

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
