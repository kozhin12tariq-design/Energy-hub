%MAIN_MONTH4H_RULE_BASED_BASELINE
%What the OPTIMIZATION is worth, as opposed to what the equipment is worth.
%
%   The 72.1%% headline compares the hub against Case 1, which owns no PV, no
%   battery, no EV fleet and no heat pump. Most of that gap is therefore the
%   value of buying the equipment, and this project says so wherever the
%   number appears. But that leaves the MODELLING contribution measured only
%   by the internal ablations, which are small and -- as Month 4e shows --
%   not uniformly significant.
%
%   The demanding comparator is the SAME HUB under simple heuristic control:
%   charge storage below the median import price, discharge above it, run the
%   fuel cell only when its marginal cost beats the grid or when the heat
%   balance forces it, no look-ahead and no optimization. rule_based_dispatch.m
%   holds the rules and the fairness argument. Both controllers face the same
%   ratings, the same SOC bands, the same storage state equation, the same
%   true fuel-cell curves and the same realized 5-minute profiles.
%
%   Whatever the optimizer beats that by is the value of the optimization,
%   and unlike the 72.1%% figure it cannot be explained by hardware.
%
%   REPORTED WITH CONFIDENCE INTERVALS, not as a point estimate, because
%   Month 4e established that single-draw differences in this system are not
%   safe to quote: paired draws across seeds and seasons, with the same
%   three-test treatment (t interval, bootstrap, sign test).
%
%   Run with:  main_month4h_rule_based_baseline

clear; clc;
addpath('../month3_multiscale_optimization');
addpath('../month2_coupling_matrix_pwl_ieee33');

p = multiscale_default_params();
fc0 = forecast_profiles(42);   % tariff reference for the closing note

nSeeds  = 10;
seasons = {'winter', 'shoulder', 'summer'};
nDraw   = nSeeds * numel(seasons);

fprintf('=====================================================\n');
fprintf(' Optimized dispatch vs. rule-based control (same hub)\n');
fprintf('=====================================================\n');
fprintf('%d draws = %d seeds x %d seasons, paired within draw.\n', ...
    nDraw, nSeeds, numel(seasons));
fflush(stdout);

dCost = zeros(nDraw,1); dCO2 = zeros(nDraw,1);
optCost = zeros(nDraw,1); rbCost = zeros(nDraw,1);
optPeak = zeros(nDraw,1); rbPeak = zeros(nDraw,1);
rbUnmetHeat = zeros(nDraw,1); rbDumpHeat = zeros(nDraw,1);
optExp = zeros(nDraw,1); rbExp = zeros(nDraw,1);
optImp = zeros(nDraw,1); rbImp = zeros(nDraw,1);
drawSeason = cell(nDraw,1);

i = 0; t0 = tic;
for sIdx = 1:numel(seasons)
    for sd = 1:nSeeds
        i = i + 1;
        drawSeason{i} = seasons{sIdx};
        fcD = forecast_profiles(sd, 1.0, [], seasons{sIdx});

        Copt = simulate_multiscale_day(p, fcD, struct('useIntraday', true, 'reserveScale', 1.0));
        Crb  = rule_based_dispatch(p, fcD);

        optCost(i) = Copt.actualCost;  rbCost(i) = Crb.actualCost;
        optPeak(i) = max(Copt.Pg_imp5); rbPeak(i) = max(Crb.Pg_imp5);
        rbUnmetHeat(i) = Crb.heatUnmet_kWh;
        rbDumpHeat(i)  = Crb.heatDumped_kWh;
        optExp(i) = sum(Copt.Pg_exp5)/12;  rbExp(i) = sum(Crb.Pg_exp5)/12;
        optImp(i) = sum(Copt.Pg_imp5)/12;  rbImp(i) = sum(Crb.Pg_imp5)/12;

        % Positive = the optimizer is cheaper, i.e. the claim's direction.
        dCost(i) = 100*(Crb.actualCost - Copt.actualCost) / Copt.actualCost;
        dCO2(i)  = 100*(Crb.emissions_kgCO2 - Copt.emissions_kgCO2) / Copt.emissions_kgCO2;
    end
end
fprintf('%d draws in %.0f s.\n', nDraw, toc(t0));

%% Did the heuristic actually serve the load? ---------------------------
% Asked FIRST, because a cost comparison against a controller that failed to
% meet demand is not a comparison at all.
fprintf('\n--- Feasibility check on the rule-based controller ---\n');
fprintf('%-40s %12.3f kWh\n', 'Worst unserved heat in any draw',  max(rbUnmetHeat));
fprintf('%-40s %12.3f kWh\n', 'Mean unserved heat per draw',      mean(rbUnmetHeat));
fprintf('%-40s %12.3f kWh\n', 'Worst dumped surplus heat',        max(rbDumpHeat));
if max(rbUnmetHeat) > 1e-6
    fprintf(['*** THE HEURISTIC LEAVES HEAT UNSERVED in at least one draw (worst %.3f kWh).\n' ...
        'The cost comparison below is therefore NOT like-for-like in those draws: the\n' ...
        'rule-based controller is partly cheap because it served less. Read the cost\n' ...
        'advantage as an UPPER bound on the optimizer''s true margin. ***\n'], max(rbUnmetHeat));
else
    fprintf(['The heuristic meets the heat balance in every draw, so the cost comparison\n' ...
        'below is like-for-like: both controllers serve the same demand and differ only\n' ...
        'in how they buy the energy to do it.\n']);
end

%% The comparison -------------------------------------------------------
stCost = paired_stats(dCost, true);
stCO2  = paired_stats(dCO2,  true);

fprintf('\n--- Optimized vs rule-based, all %d draws (paired) ---\n', nDraw);
fprintf('%-26s %9s %9s %9s %18s %8s\n', '', 'mean %', 'median %', 'sd', '95% CI (t)', 'sign+');
fprintf('%-26s %9.2f %9.2f %9.2f  [%+7.2f,%+7.2f] %4d/%-3d\n', 'Cost penalty of rules', ...
    stCost.mean, stCost.median, stCost.sd, stCost.ciLo, stCost.ciHi, stCost.nAgree, stCost.nNonZero);
fprintf('%-26s %9.2f %9.2f %9.2f  [%+7.2f,%+7.2f] %4d/%-3d\n', 'CO2 penalty of rules', ...
    stCO2.mean, stCO2.median, stCO2.sd, stCO2.ciLo, stCO2.ciHi, stCO2.nAgree, stCO2.nNonZero);
fprintf('\nCost verdict: %s\n', stCost.verdict);
fprintf('CO2  verdict: %s\n', stCO2.verdict);

% A MEAN OF PERCENTAGES IS THE WRONG POOLED STATISTIC HERE, and the spread
% above shows why: a summer day costs about a sixteenth of a winter day, so
% the same absolute dollar penalty becomes a percentage several times larger
% in summer and dominates the average. The cost-weighted aggregate below --
% total extra dollars over total optimized dollars -- is what a system
% operator would actually experience, and it is the figure to quote.
aggPct = 100*sum(rbCost - optCost)/sum(optCost);
fprintf(['\nCost-weighted aggregate over all %d draws: %+.2f%% ' ...
    '($%.2f extra on $%.2f).\n'], nDraw, aggPct, sum(rbCost-optCost), sum(optCost));
fprintf(['(The mean-of-percentages above is %+.2f%%, inflated because a summer day costs\n' ...
    ' ~1/%.0f of a winter day and the same dollar penalty is a much larger fraction of\n' ...
    ' it. Quote the weighted figure.)\n'], stCost.mean, ...
    mean(optCost(strcmp(drawSeason,'winter')))/mean(optCost(strcmp(drawSeason,'summer'))));

fprintf('\n--- By season ---\n');
fprintf('%-10s %10s %10s %10s %18s   %s\n', 'season', 'opt $', 'rules $', 'penalty %', '95% CI (t)', 'verdict');
stSea = cell(1, numel(seasons));
for sIdx = 1:numel(seasons)
    sel = strcmp(drawSeason, seasons{sIdx});
    stSea{sIdx} = paired_stats(dCost(sel), true);
    fprintf('%-10s %10.2f %10.2f %10.2f  [%+7.2f,%+7.2f]   %s\n', seasons{sIdx}, ...
        mean(optCost(sel)), mean(rbCost(sel)), stSea{sIdx}.mean, ...
        stSea{sIdx}.ciLo, stSea{sIdx}.ciHi, stSea{sIdx}.verdict);
end

fprintf('\n--- Peak grid import (kW), a metric neither controller optimizes ---\n');
fprintf('%-10s %14s %14s %12s\n', 'season', 'optimized', 'rule-based', 'change %');
for sIdx = 1:numel(seasons)
    sel = strcmp(drawSeason, seasons{sIdx});
    fprintf('%-10s %14.1f %14.1f %+12.1f\n', seasons{sIdx}, ...
        mean(optPeak(sel)), mean(rbPeak(sel)), ...
        100*(mean(rbPeak(sel)) - mean(optPeak(sel)))/mean(optPeak(sel)));
end

%% Where the gap actually comes from ------------------------------------
fprintf('\n--- Grid energy, and where the heuristic loses (kWh/day) ---\n');
fprintf('%-10s %10s %10s %10s %10s\n', 'season', 'opt imp', 'rule imp', 'opt exp', 'rule exp');
for sIdx = 1:numel(seasons)
    sel = strcmp(drawSeason, seasons{sIdx});
    fprintf('%-10s %10.0f %10.0f %10.0f %10.0f\n', seasons{sIdx}, ...
        mean(optImp(sel)), mean(rbImp(sel)), mean(optExp(sel)), mean(rbExp(sel)));
end
selSu = strcmp(drawSeason, 'summer');
fprintf(['\nTHE SUMMER FIGURE IS INFLATED BY ONE SPECIFIC WEAKNESS OF THE CHOSEN RULE, and\n' ...
    'saying which one matters more than the headline. The threshold is the daily MEDIAN\n' ...
    'import price, and on this tariff the midday hours sit exactly AT the median -- so\n' ...
    'they are neither "cheap" nor "expensive" and the rule does not charge storage from\n' ...
    'surplus PV at all. Measured: in summer the heuristic exports %.0f kWh/day against\n' ...
    'the optimizer''s %.0f, and imports %.0f kWh/day against %.0f. It sells PV at the\n' ...
    '$%.2f export price and buys it back overnight at $%.2f.\n' ...
    '\nA one-line improvement -- charge whenever there is surplus PV, regardless of price\n' ...
    '-- would close much of that summer gap. The %.1f%% summer penalty should therefore be\n' ...
    'read as a property of THIS rule set, not as the intrinsic value of optimization. The\n' ...
    'winter and shoulder figures (%.1f%% and %.1f%%), where storage is scheduled against\n' ...
    'genuine price and heat structure rather than against unexploited PV, are the more\n' ...
    'conservative and more defensible ones.\n'], ...
    mean(rbExp(selSu)), mean(optExp(selSu)), mean(rbImp(selSu)), mean(optImp(selSu)), ...
    0.05, 0.10, stSea{3}.mean, stSea{1}.mean, stSea{2}.mean);

%% What this establishes ------------------------------------------------
fprintf('\n=====================================================\n');
fprintf(' What the optimization is worth\n');
fprintf('=====================================================\n');
fprintf(['Over %d paired draws the heuristic controller costs %+.2f%% more than the\n' ...
    'optimized dispatch on a cost-weighted basis, and the optimizer was ahead in %d of\n' ...
    '%d draws individually.\n'], nDraw, aggPct, stCost.nAgree, stCost.nNonZero);
fprintf(['Per season the penalty is %+.1f%% (winter), %+.1f%% (shoulder), %+.1f%% (summer).\n'], ...
    stSea{1}.mean, stSea{2}.mean, stSea{3}.mean);

if aggPct > 0 && stCost.signSignificant
    fprintf(['\nTHIS IS THE STRONGEST MODELLING CLAIM THIS PROJECT CAN MAKE, and it is the\n' ...
        'right one to quote. It compares identical hardware on identical scenarios and\n' ...
        'differs ONLY in how the equipment is scheduled, so unlike the %.1f%% headline it\n' ...
        'cannot be explained away as the value of owning a battery. It is also larger and\n' ...
        'better resolved than the internal ablations in Month 4e.\n'], 72.1);
elseif stCost.mean > 0
    fprintf(['\nThe optimizer is ahead on average but the margin is NOT cleanly resolved\n' ...
        '(%s). That is a finding about the ceiling on optimization value in this system,\n' ...
        'not a presentational problem, and it should be quoted with the interval attached\n' ...
        'rather than as a point estimate.\n'], stCost.verdict);
else
    fprintf(['\n*** THE HEURISTIC IS NOT WORSE ON COST. *** That is the result. A simple\n' ...
        'threshold controller on this hub, on these scenarios, matches or beats the\n' ...
        'optimized dispatch, and the honest conclusion is that the optimization''s value\n' ...
        'here is not in operating cost. Any remaining case for it has to be made on the\n' ...
        'metrics it actually improves -- reported above -- not on cost.\n']);
end

fprintf(['\nWHAT THE HEURISTIC IS NOT PENALISED FOR, stated so the margin is not\n' ...
    'over-read: it is given the same equipment, the same realized profiles and the\n' ...
    'published tariff, and it is not charged for peak demand, for network impact, or\n' ...
    'for the reserve it fails to hold. On a tariff with a demand charge, or against the\n' ...
    'voltage floor Month 4d imposes, the gap would be different -- and this comparison\n' ...
    'does not measure that.\n' ...
    '\nAnd the heuristic is deliberately NOT handicapped on the two decisions that would\n' ...
    'make it look bad for the wrong reasons. Its fuel-cell test uses the marginal cost at\n' ...
    'the rated point, $%.3f/kWh electrical against a $%.2f-$%.2f tariff -- the same answer\n' ...
    'the optimizer reaches at today''s hydrogen price, so it loses nothing there. And its\n' ...
    'thermal-storage charging is capped at spare heat-pump capacity, so filling a store\n' ...
    'can never start the fuel cell; an earlier version without that cap burned hydrogen\n' ...
    'to charge thermal storage and made the optimizer look far better than it is.\n' ...
    'The remaining gap is storage SCHEDULING -- which is what the comparison is for.\n'], ...
    p.price_H2 / (pwl_utils('eval', p.PWL.bkpt_e.x, p.PWL.bkpt_e.y, p.PWL.FC_H2_max)/p.PWL.FC_H2_max), ...
    min(fc0.DA.priceImport), max(fc0.DA.priceImport));
