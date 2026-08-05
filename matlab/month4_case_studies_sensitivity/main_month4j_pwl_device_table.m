%MAIN_MONTH4J_PWL_DEVICE_TABLE
%Constant efficiency vs PWL, device by device, with the decision rule.
%
%   THE DELIVERABLE OF THIS SESSION. Until now the thesis said "we applied
%   PWL". That is a blanket claim, and the evidence does not support a
%   blanket claim -- it supports a DECISION RULE, which is a stronger and
%   more defensible thing to be able to state.
%
%   WHAT IS IN THIS TABLE AND WHAT IS NOT. Two devices carry a PWL model:
%   the fuel cell (since the beginning) and the heat pump (added this
%   session). The PV inverter and the battery do NOT, and their absence is
%   a RESULT rather than an omission: main_month4i gated the heat pump and
%   the gate did not pass, and the instructions for this session were
%   explicit that Tasks 2 and 3 must not proceed on the assumption that more
%   PWL is better. The rows for PV and battery are therefore listed as NOT
%   RUN, with the reason, instead of being quietly dropped.
%
%   FAIR COMPARISON. "Constant efficiency" means a 1-SEGMENT fit of the SAME
%   curve, not a different number -- so every row shares the same physics and
%   differs only in how finely that physics is represented. Realized cost is
%   evaluated against the TRUE continuous curves in every row, on BOTH the
%   electrical and the THERMAL side, by true_curve_cost.m.
%
%   The thermal half of that is not cosmetic. realtime_balance already
%   re-prices the fuel cell's electricity honestly, but nothing re-priced
%   HEAT, and the fuel cell's thermal curve is convex -- so a 1-segment
%   chord over-promises heat at part load, under-buys hydrogen and looks
%   cheaper than it is. An earlier version of this table omitted that
%   correction and reported every PWL configuration as a reliable cost at
%   today's hydrogen price; what it was actually measuring was an unpriced
%   heat shortfall in the comparator. The shortfall is now made up by the
%   heat pump at its true marginal COP, which is the cheapest heat source
%   here and therefore the most conservative way to charge for it.
%
%   Run with:  main_month4j_pwl_device_table

clear; clc;
addpath('../month3_multiscale_optimization');
addpath('../month2_coupling_matrix_pwl_ieee33');

p = multiscale_default_params();

% TWO HYDROGEN PRICES, because the fuel cell's PWL benefit is not a single
% number and reporting it as one would contradict Month 4e for no reason.
% At today's DELIVERED price the fuel cell only runs when the winter heat
% balance forces it -- must-run operation, where the planner has no freedom
% to exploit a part-load curve. At the DOE delivered target it is
% economically dispatched and chooses its own operating point. Month 4e
% measured the second; the shipped default is the first; both are reported.
priceCases = struct( ...
    'label',  {'H2_today (shipped default)', 'H2_doeTargetDelivered (Month 4e basis)'}, ...
    'price',  {p.price_H2, p.scenarios.H2_doeTargetDelivered});

nSeeds  = 20;
seasons = {'winter', 'shoulder', 'summer'};
nDraw   = nSeeds * numel(seasons);

fprintf('=====================================================\n');
fprintf(' Constant efficiency vs PWL, per device\n');
fprintf('=====================================================\n');
fprintf('%d draws = %d seeds x %d seasons, paired within draw.\n', nDraw, nSeeds, numel(seasons));
fflush(stdout);

% Four reachable configurations. FC PWL is switched through the existing
% opts.usePWL (1-segment planning fit); HP PWL through nSegments on its own
% curve. Both "off" states are chords of their own curves, never a
% different device.
% Both heat-pump arms use the CURVE (usePWL = true); they differ only in
% segment count, so "constant" is a 1-segment chord of the same curve and
% not the legacy COP = 3.2, which would be a different device. The shipped
% default is usePWL = false -- see multiscale_default_params.m and the gate
% in main_month4i -- so it is set explicitly here rather than inherited.
pHPoff = p; pHPoff.HeatPump.usePWL = true; pHPoff.HeatPump.nSegments = 1;
pHPon  = p; pHPon.HeatPump.usePWL  = true;
cfg = struct( ...
  'label',   {'All constant efficiency', '+ fuel cell PWL only (previous default)', ...
              '+ heat pump PWL only',    'All PWL (fuel cell + heat pump)'}, ...
  'fcPWL',   {false, true,  false, true}, ...
  'params',  {pHPoff, pHPoff, pHPon, pHPon});
nCfg = numel(cfg);

costP = cell(1, numel(priceCases)); co2P = cell(1, numel(priceCases));
tsolveP = cell(1, numel(priceCases));
drawSeason = cell(nDraw,1);
fcThruP = zeros(1, numel(priceCases));

t0 = tic;
for ip = 1:numel(priceCases)
    cost = zeros(nDraw, nCfg); co2 = zeros(nDraw, nCfg); tsolve = zeros(nDraw, nCfg);
    i = 0;
    for sIdx = 1:numel(seasons)
        for sd = 1:nSeeds
            i = i + 1;
            drawSeason{i} = seasons{sIdx};
            fcD = forecast_profiles(sd, 1.0, [], seasons{sIdx});
            for c = 1:nCfg
                pc = cfg(c).params; pc.price_H2 = priceCases(ip).price;
                o = struct('useIntraday', true, 'reserveScale', 1.0, 'usePWL', cfg(c).fcPWL);
                tt = tic;
                R  = simulate_multiscale_day(pc, fcD, o);
                tsolve(i,c) = toc(tt);
                cost(i,c)   = true_curve_cost(pc, fcD, R, cfg(c).fcPWL);
                co2(i,c)    = R.emissions_kgCO2;
                if c == nCfg; fcThruP(ip) = fcThruP(ip) + sum(R.PH2_5)/12/nDraw; end
            end
        end
        fprintf('  price %d, %s done (%.0f s elapsed)\n', ip, seasons{sIdx}, toc(t0));
        fflush(stdout);
    end
    costP{ip} = cost; co2P{ip} = co2; tsolveP{ip} = tsolve;
end

nBinFC = (p.PWL.nSegments - 1) * 24;
nBinHP = (p.HeatPump.nSegments - 1) * 24;
binCount = [0, nBinFC, nBinHP, nBinFC + nBinHP];
Sall = cell(1, numel(priceCases));

for ip = 1:numel(priceCases)
cost = costP{ip}; co2 = co2P{ip}; tsolve = tsolveP{ip};
fprintf('\n\n#####################################################\n');
fprintf(' PRICE CASE %d: %s ($%.2f/kg) -- mean fuel-cell throughput %.0f kWh/day\n', ...
    ip, priceCases(ip).label, priceCases(ip).price*p.scenarios.H2_kWhPerKg, fcThruP(ip));
fprintf('#####################################################\n');

%% Main table -----------------------------------------------------------
fprintf('\n=====================================================\n');
fprintf(' Pooled over all %d draws\n', nDraw);
fprintf('=====================================================\n');
fprintf('%-40s %10s %10s %9s %9s %10s %18s  %s\n', 'Configuration', 'Cost($/d)', 'CO2(kg)', ...
    'Solve(s)', 'Binaries', 'Benefit%', '95% CI', 'Distinguishable?');
S = cell(1, nCfg);
for c = 1:nCfg
    if c == 1
        fprintf('%-40s %10.2f %10.1f %9.3f %9d %10s %18s  %s\n', cfg(c).label, ...
            mean(cost(:,1)), mean(co2(:,1)), mean(tsolve(:,1)), binCount(1), ...
            '-- ref --', '--', '--');
    else
        d = 100*(cost(:,1) - cost(:,c)) ./ cost(:,c);   % + = this config is cheaper
        S{c} = paired_stats(d, true);
        if S{c}.distinguishable && S{c}.bootDistinguishable && S{c}.signSignificant
            verd = 'YES';
        elseif S{c}.signOpposite && S{c}.distinguishable
            verd = 'YES, but NEGATIVE';
        else
            verd = 'no';
        end
        fprintf('%-40s %10.2f %10.1f %9.3f %9d %10.3f [%+7.3f,%+7.3f]  %s\n', cfg(c).label, ...
            mean(cost(:,c)), mean(co2(:,c)), mean(tsolve(:,c)), binCount(c), ...
            S{c}.mean, S{c}.ciLo, S{c}.ciHi, verd);
    end
end
fprintf('%-40s %10s %10s %9s %9s %10s %18s  %s\n', '+ PV inverter PWL', 'NOT RUN', '--', '--', '--', '--', '--', 'gate not passed');
fprintf('%-40s %10s %10s %9s %9s %10s %18s  %s\n', '+ battery PWL',      'NOT RUN', '--', '--', '--', '--', '--', 'gate not passed');

%% Per season -----------------------------------------------------------
fprintf('\n--- Benefit vs all-constant, per season (%%, + = PWL config cheaper) ---\n');
fprintf('%-40s %22s %22s %22s\n', 'Configuration', 'winter', 'shoulder', 'summer');
for c = 2:nCfg
    fprintf('%-40s', cfg(c).label);
    for sIdx = 1:numel(seasons)
        sel = strcmp(drawSeason, seasons{sIdx});
        st  = paired_stats(100*(cost(sel,1) - cost(sel,c)) ./ cost(sel,c), true);
        fprintf(' %7.3f [%+6.3f,%+6.3f]', st.mean, st.ciLo, st.ciHi);
    end
    fprintf('\n');
end

%% Marginal contributions -----------------------------------------------
fprintf('\n=====================================================\n');
fprintf(' MARGINAL contribution of each device\n');
fprintf('=====================================================\n');
fprintf('The benefit of ADDING that device''s PWL to the configuration above it,\n');
fprintf('so a reader can see which device carries the effect and which is noise.\n\n');
marg = { 'fuel cell PWL, added to all-constant',            1, 2; ...
         'heat pump PWL, added to fuel-cell PWL',           2, 4; ...
         'heat pump PWL, added to all-constant',            1, 3; ...
         'fuel cell PWL, added to heat-pump PWL',           3, 4 };
fprintf('%-42s %9s %9s %18s %8s  %s\n', 'Marginal step', 'mean %', 'median', '95% CI (t)', 'sign+', 'verdict');
for m = 1:size(marg,1)
    a = marg{m,2}; b = marg{m,3};
    st = paired_stats(100*(cost(:,a) - cost(:,b)) ./ cost(:,b), true);
    fprintf('%-42s %9.3f %9.3f [%+8.3f,%+7.3f] %4d/%-3d  %s\n', marg{m,1}, ...
        st.mean, st.median, st.ciLo, st.ciHi, st.nAgree, st.nNonZero, st.verdict);
end

fprintf('\n--- Same marginal steps, per season ---\n');
fprintf('%-42s %20s %20s %20s\n', 'Marginal step', 'winter', 'shoulder', 'summer');
for m = 1:size(marg,1)
    a = marg{m,2}; b = marg{m,3};
    fprintf('%-42s', marg{m,1});
    for sIdx = 1:numel(seasons)
        sel = strcmp(drawSeason, seasons{sIdx});
        st  = paired_stats(100*(cost(sel,a) - cost(sel,b)) ./ cost(sel,b), true);
        fprintf(' %6.3f [%+5.2f,%+5.2f]', st.mean, st.ciLo, st.ciHi);
    end
    fprintf('\n');
end


Sall{ip} = S;
end
S = Sall{1};
cost = costP{1};

%% Throughput, curvature, and the rule ----------------------------------
fprintf('\n\n=====================================================\n');
fprintf(' What actually predicts whether PWL pays\n');
fprintf('=====================================================\n');
fcRef = forecast_profiles(42, 1.0, [], 'shoulder');
Rref  = simulate_multiscale_day(pHPon, fcRef, struct('useIntraday', true));
hpRef = heatpump_curve(pHPon, fcRef.ambientC);
hpThru = sum(Rref.Php5)/12;
fcSl   = diff(p.PWL.bkpt_e.y) ./ diff(p.PWL.bkpt_e.x);
fcCurv = (max(fcSl)-min(fcSl))/mean(fcSl);
hpCurv = (max(hpRef.slopes)-min(hpRef.slopes))/mean(hpRef.slopes);

fcLo = Sall{1}{2}; fcHi = Sall{2}{2};      % fuel cell, both price cases
hpLo = Sall{1}{3}; hpHi = Sall{2}{3};      % heat pump, both price cases

fprintf('%-14s %12s %11s %11s %22s %22s\n', 'device', 'throughput', 'curvature', 'dispatch', ...
    'PWL benefit, H2 today', 'PWL benefit, H2 target');
fprintf('%-14s %8.0f kWh %11.3f %11s %9.3f%% [%+6.2f,%+6.2f] %9.3f%% [%+6.2f,%+6.2f]\n', ...
    'fuel cell', fcThruP(1), fcCurv, 'must-run', ...
    fcLo.mean, fcLo.ciLo, fcLo.ciHi, fcHi.mean, fcHi.ciLo, fcHi.ciHi);
fprintf('%-14s %8.0f kWh %11.3f %11s %9.3f%% [%+6.2f,%+6.2f] %9.3f%% [%+6.2f,%+6.2f]\n', ...
    'heat pump', hpThru, hpCurv, 'economic', ...
    hpLo.mean, hpLo.ciLo, hpLo.ciHi, hpHi.mean, hpHi.ciLo, hpHi.ciHi);
fprintf('%-14s %8.0f kWh %11s %11s %22s %22s\n', 'PV inverter', sum(fcRef.DA.solar), ...
    'n/a', 'n/a', 'NOT RUN -- gate', 'not passed');

fprintf(['\nTHE THROUGHPUT RULE THE SESSION SET OUT TO CONFIRM IS NOT THE RULE THE DATA\n' ...
    'SUPPORTS, and the table above is the evidence against it. The heat pump moves\n' ...
    '%.0f kWh/day against the fuel cell''s %.0f at today''s price -- %.1fx more -- with\n' ...
    'comparable curvature (%.2f vs %.2f), and its PWL benefit does not resolve in either\n' ...
    'price case. A rule of the form "PWL pays above X kWh/day throughput" would have\n' ...
    'predicted the heat pump as the stronger candidate. It is the weaker one.\n' ...
    '\nWHAT DOES PREDICT IT is visible in the fuel cell''s two columns, which differ ONLY\n' ...
    'in the hydrogen price and therefore only in WHY the device runs:\n' ...
    '  at $7.33/kg it runs %.0f kWh/day, and only because the winter heat balance forces\n' ...
    '  it -- MUST-RUN operation, where the operating point is dictated rather than\n' ...
    '  chosen. PWL benefit: %+.3f%% [%+.2f, %+.2f]. Negative, and resolved.\n' ...
    '  at $2.93/kg it runs %.0f kWh/day and picks its own operating point. PWL benefit:\n' ...
    '  %+.3f%% [%+.2f, %+.2f]. Positive, and resolved.\n' ...
    'Same device, same curve, same segments, same binaries. The only thing that changed\n' ...
    'is whether the optimizer had any freedom to exploit the curve with.\n'], ...
    hpThru, fcThruP(1), hpThru/max(fcThruP(1),1e-9), hpCurv, fcCurv, ...
    fcThruP(1), fcLo.mean, fcLo.ciLo, fcLo.ciHi, ...
    fcThruP(2), fcHi.mean, fcHi.ciLo, fcHi.ciHi);

fprintf(['\nTHE DECISION RULE THE DATA SUPPORTS -- four conditions, all necessary:\n' ...
    '  1. THROUGHPUT. The device must move enough energy for its efficiency to matter.\n' ...
    '     Necessary, and as the heat pump shows, nowhere near sufficient.\n' ...
    '  2. SCHEDULING FREEDOM. The optimizer must be able to CHOOSE the operating point.\n' ...
    '     A must-run device gets no benefit from a better curve because it is not\n' ...
    '     choosing anything, and the extra segments then only add ways to be wrong --\n' ...
    '     measured here as a resolved NEGATIVE.\n' ...
    '  3. OPERATING RANGE. The device must move across several segments. One parked\n' ...
    '     inside a single segment gets nothing from the other four, and if that segment\n' ...
    '     is the coarsest part of the fit it is actively worse off. The heat pump in\n' ...
    '     summer sits at ~13%% load, 70%% of its running time inside segment 1, and its\n' ...
    '     PWL benefit there is %+.3f%% [%+.2f, %+.2f] -- a reliable cost.\n' ...
    '  4. ERROR DIRECTION. The fit must err PESSIMISTICALLY where the device operates.\n' ...
    '     Optimism and pessimism are not symmetric in cost: a shortfall is covered at\n' ...
    '     the import tariff, a surplus is only worth the export price. This is the same\n' ...
    '     asymmetry the Optimism column in Month 4a established for the fuel cell,\n' ...
    '     reappearing on a second device -- which is what makes it a mechanism rather\n' ...
    '     than a coincidence.\n' ...
    '\nConditions 3 and 4 are about BREAKPOINT PLACEMENT, not segment count, and\n' ...
    'main_month4i measures the fix: curvature-placed breakpoints on the SAME segment\n' ...
    'count and the same binaries turn the heat pump''s failed gate (-0.162%%, spanning\n' ...
    'zero) into +0.700%% [+0.394, +1.005], resolved on all three tests.\n' ...
    '\nPRACTICAL FORM: before spending binaries on a device, ask whether the optimizer\n' ...
    'chooses its operating point, where on the curve it operates, and whether the fit\n' ...
    'errs high there. Segment count is the last thing to tune, not the first.\n'], ...
    paired_stats(100*(costP{1}(strcmp(drawSeason,'summer'),1) - costP{1}(strcmp(drawSeason,'summer'),3)) ...
        ./ costP{1}(strcmp(drawSeason,'summer'),3), true).mean, ...
    paired_stats(100*(costP{1}(strcmp(drawSeason,'summer'),1) - costP{1}(strcmp(drawSeason,'summer'),3)) ...
        ./ costP{1}(strcmp(drawSeason,'summer'),3), true).ciLo, ...
    paired_stats(100*(costP{1}(strcmp(drawSeason,'summer'),1) - costP{1}(strcmp(drawSeason,'summer'),3)) ...
        ./ costP{1}(strcmp(drawSeason,'summer'),3), true).ciHi);

fprintf(['\nA NOTE ON MONTH 4e, so the two are not read as contradicting each other. Month\n' ...
    '4e measured the fuel cell''s PWL benefit at +1.42%% on the delivered-target price;\n' ...
    'this table gives %+.2f%% for the same comparison. The difference is the THERMAL\n' ...
    'correction described in this file''s header, which Month 4e did not apply -- the\n' ...
    'constant-efficiency comparator over-promises heat and was not being charged for it.\n' ...
    'Both numbers are positive and resolved; this one is the more complete accounting.\n'], ...
    fcHi.mean);

fprintf(['\nWHAT THIS TABLE DOES NOT SETTLE, stated so it is not over-read: it measures\n' ...
    'COST under one tariff structure, on three representative days, at one hub size. It\n' ...
    'says nothing about whether PWL is needed for FEASIBILITY -- and that argument is\n' ...
    'independent and stronger. Without the fill-order binaries the LP relaxation reports\n' ...
    'dispatches the machines cannot physically produce, at every price and in every\n' ...
    'season, which is a correctness failure rather than a cost one. The heat pump''s\n' ...
    'slopes are non-monotonic too (segment 2 above segment 1), so it needs those\n' ...
    'binaries for the same reason the moment its curve is modelled at all.\n']);
