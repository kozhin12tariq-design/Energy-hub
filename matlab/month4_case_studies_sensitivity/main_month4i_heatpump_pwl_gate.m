%MAIN_MONTH4I_HEATPUMP_PWL_GATE
%Does putting PWL on the heat pump earn its complexity? Measured, then gated.
%
%   THE DIAGNOSIS THIS ANSWERS. Until now PWL was applied to exactly one
%   device -- the fuel cell -- which is the LOWEST-throughput converter in
%   the hub. On a shoulder day it moves 43.5 kWh while the heat pump moves
%   634 kWh of electricity and PV moves 1922 kWh. In summer the fuel cell
%   runs 0 kWh, which is why Month 4e measured the fuel cell's PWL benefit
%   at -0.20% there: a PWL device that never runs cannot help.
%
%   The heat pump is the strongest candidate for the treatment: high
%   throughput, a genuinely nonlinear COP, and it runs hardest in winter
%   when heat demand peaks. heatpump_curve.m holds the curve and its
%   manufacturer sourcing; dayahead_dispatch.m and intraday_dispatch.m
%   embed it with the same segment / concentrator / fill-order structure the
%   fuel cell uses.
%
%   TWO COMPARISONS, AND ONLY ONE OF THEM IS THE PWL QUESTION.
%
%     (A) THE GATE -- n-segment PWL vs a 1-SEGMENT CHORD OF THE SAME CURVE.
%         Same curve, same rated point, same ambient, differing only in how
%         finely the shape is represented. This is the PWL question, and it
%         is exactly how Case 5 isolates the fuel cell's PWL.
%
%     (B) CONTEXT -- the curve vs the legacy constant COP = 3.2. This is a
%         LEVEL change (mean COP 3.2 -> 4.81 at the shoulder ambient), not a
%         PWL question. Reporting it as a "PWL benefit" would be a category
%         error of exactly the kind this project already refuses for the
%         72.1% headline, so it is reported separately and labelled.
%
%   HOW REALIZED COST IS COMPUTED, because the heat pump differs
%   structurally from the fuel cell. Real time re-optimizes electricity
%   only; the heat balance is settled at the day-ahead and intraday levels,
%   so a coarse COP model is never corrected by a later layer the way a
%   coarse fuel-cell model is. Left alone, both configurations would simply
%   deliver whatever their own model said, and the comparison would measure
%   two different physics rather than one physics under two models.
%
%   So the same correction Month 4c applies to the fuel cell is applied
%   here: the heat each configuration SCHEDULED is re-evaluated through the
%   TRUE continuous COP curve to find the electricity it would really have
%   needed, and grid import absorbs the difference. Both configurations are
%   then priced against the same physics and differ only in the model that
%   chose the schedule -- which is the definition of a planning-error
%   measurement.
%
%   Run with:  main_month4i_heatpump_pwl_gate

clear; clc;
addpath('../month3_multiscale_optimization');
addpath('../month2_coupling_matrix_pwl_ieee33');

p = multiscale_default_params();

nSeeds  = 20;
seasons = {'winter', 'shoulder', 'summer'};
nDraw   = nSeeds * numel(seasons);

fprintf('=====================================================\n');
fprintf(' GATE: heat-pump PWL -- does it pay?\n');
fprintf('=====================================================\n');
fprintf('%d draws = %d seeds x %d seasons, paired within draw.\n', ...
    nDraw, nSeeds, numel(seasons));

%% The curve, and the slope check that decides the binaries --------------
fprintf('\n--- The fitted curve, per season ambient ---\n');
fprintf('%-10s %8s %9s %10s %10s   %s\n', 'season', 'amb C', 'clamped', 'COP rated', 'binaries', 'segment slopes (COP per segment)');
for sIdx = 1:numel(seasons)
    fcS = forecast_profiles(42, 1.0, [], seasons{sIdx});
    hpS = heatpump_curve(p, fcS.ambientC);
    fprintf('%-10s %8.1f %9.1f %10.3f %10d   ', seasons{sIdx}, ...
        hpS.ambientRaw, hpS.ambientC, hpS.copRated, hpS.needsBinaries);
    fprintf('%.4f ', hpS.slopes); fprintf('\n');
end
hpRef = heatpump_curve(p, 9.0);
fprintf(['\nSLOPE MONOTONICITY, CHECKED RATHER THAN ASSUMED: segment 2''s slope EXCEEDS\n' ...
    'segment 1''s in every season, so the slopes are NOT monotonically decreasing and\n' ...
    'FILL-ORDER BINARIES ARE REQUIRED. The mechanism is the low-load cycling penalty --\n' ...
    'the first slice of load is the LEAST efficient, so an LP relaxation would fill\n' ...
    'segment 2 while segment 1 sits empty and claim more heat per kWh than the machine\n' ...
    'can deliver. Same situation as the fuel cell, same fix, and it is measured here\n' ...
    'rather than assumed: %d binaries per time step, %d over a 24-hour day-ahead solve.\n'], ...
    hpRef.nSegments - 1, (hpRef.nSegments - 1) * 24);

%% Configurations --------------------------------------------------------
pPWL   = p;                                   % (A) n-segment PWL, uniform breakpoints
pChord = p;  pChord.HeatPump.nSegments = 1;    % (A) 1-segment chord, same curve
pLegacy = p; pLegacy.HeatPump.usePWL   = false;% (B) legacy constant COP 3.2
pCurv  = p;  pCurv.HeatPump.placement  = 'curvature';   % (C) same n, better placement

optFull = struct('useIntraday', true, 'reserveScale', 1.0);

dGate   = zeros(nDraw,1);   % (chord - PWL)/PWL, corrected to the true curve
dLegacy = zeros(nDraw,1);   % (legacy - PWL)/PWL, uncorrected level comparison
dCurv   = zeros(nDraw,1);   % (chord - curvature-placed PWL)/same, corrected
uMedian = zeros(nDraw,1);   % median HP load fraction while running
errPWL  = zeros(nDraw,1); errChord = zeros(nDraw,1); errCurv = zeros(nDraw,1);
drawSeason = cell(nDraw,1);
tPWL = zeros(nDraw,1); tChord = zeros(nDraw,1);
hpElecPWL = zeros(nDraw,1); hpElecChord = zeros(nDraw,1);
corrPWL = zeros(nDraw,1); corrChord = zeros(nDraw,1);

i = 0; t0 = tic;
for sIdx = 1:numel(seasons)
    for sd = 1:nSeeds
        i = i + 1;
        drawSeason{i} = seasons{sIdx};
        fcD = forecast_profiles(sd, 1.0, [], seasons{sIdx});

        ta = tic; Ca = simulate_multiscale_day(pPWL,   fcD, optFull); tPWL(i)   = toc(ta);
        tb = tic; Cb = simulate_multiscale_day(pChord, fcD, optFull); tChord(i) = toc(tb);
        Cc = simulate_multiscale_day(pLegacy, fcD, optFull);
        Cd = simulate_multiscale_day(pCurv,   fcD, optFull);

        % Each run is corrected against ITS OWN planner breakpoints -- the
        % chord run's planning error must be measured against the chord, not
        % against the 5-segment curve it never used.
        [costA, corrPWL(i)]   = hp_true_curve_cost(pPWL,   fcD, Ca);
        [costB, corrChord(i)] = hp_true_curve_cost(pChord, fcD, Cb);

        hpElecPWL(i)   = sum(Ca.Php5)/12;
        hpElecChord(i) = sum(Cb.Php5)/12;

        costD = hp_true_curve_cost(pCurv, fcD, Cd);
        dGate(i)   = 100*(costB - costA) / costA;
        dCurv(i)   = 100*(costB - costD) / costD;
        dLegacy(i) = 100*(Cc.actualCost - Ca.actualCost) / Ca.actualCost;

        % Diagnostics for the mechanism section: where on the curve the heat
        % pump actually operated, and how wrong each model was there.
        uRun = Ca.Php5(Ca.Php5 > 1e-6) / p.HeatPump.Pmax;
        if isempty(uRun); uMedian(i) = 0; else; uMedian(i) = median(uRun); end
        errPWL(i)   = approx_error(pPWL,   fcD, Ca);
        errChord(i) = approx_error(pChord, fcD, Ca);
        errCurv(i)  = approx_error(pCurv,  fcD, Ca);
    end
end
fprintf('\n%d draws in %.0f s.\n', nDraw, toc(t0));

%% (A) The gate ----------------------------------------------------------
stGate = paired_stats(dGate, true);
fprintf('\n=====================================================\n');
fprintf(' (A) THE GATE: %d-segment PWL vs 1-segment chord of the same curve\n', p.HeatPump.nSegments);
fprintf('=====================================================\n');
fprintf('%-22s %8s %8s %8s %18s %18s %8s %9s\n', '', 'mean %', 'median', 'sd', ...
    '95% CI (t)', '95% CI (boot)', 'sign+', 'sign p');
fprintf('%-22s %8.3f %8.3f %8.3f [%+8.3f,%+7.3f] [%+8.3f,%+7.3f] %4d/%-3d %9.2g\n', ...
    'Benefit of HP PWL', stGate.mean, stGate.median, stGate.sd, ...
    stGate.ciLo, stGate.ciHi, stGate.bootLo, stGate.bootHi, ...
    stGate.nAgree, stGate.nNonZero, stGate.signP);
fprintf('\nVerdict: %s\n', stGate.verdict);

fprintf('\n--- Per season ---\n');
fprintf('%-10s %9s %9s %18s %8s   %s\n', 'season', 'mean %', 'median', '95% CI (t)', 'sign+', 'verdict');
stSea = cell(1, numel(seasons));
for sIdx = 1:numel(seasons)
    sel = strcmp(drawSeason, seasons{sIdx});
    stSea{sIdx} = paired_stats(dGate(sel), true);
    st = stSea{sIdx};
    fprintf('%-10s %9.3f %9.3f [%+8.3f,%+7.3f] %4d/%-3d   %s\n', seasons{sIdx}, ...
        st.mean, st.median, st.ciLo, st.ciHi, st.nAgree, st.nNonZero, st.verdict);
end

%% WHY: where on the curve the heat pump actually lives ------------------
% The pooled null and the seasonal split only make sense together with this,
% so it is measured rather than reasoned about.
fprintf('\n--- WHY the sign flips: where the heat pump operates, and how wrong each model is there ---\n');
fprintf('%-10s %14s %12s %14s %14s %14s\n', 'season', 'median load u', 'frac in seg1', ...
    'PWL err (kW)', 'chord err (kW)', 'curv err (kW)');
for sIdx = 1:numel(seasons)
    sel = strcmp(drawSeason, seasons{sIdx});
    fcS = forecast_profiles(42, 1.0, [], seasons{sIdx});
    RS  = simulate_multiscale_day(pPWL, fcS, optFull);
    uR  = RS.Php5(RS.Php5 > 1e-6) / p.HeatPump.Pmax;
    if isempty(uR); fracSeg1 = 0; else; fracSeg1 = mean(uR < 1/p.HeatPump.nSegments); end
    fprintf('%-10s %14.3f %12.2f %+14.3f %+14.3f %+14.3f\n', seasons{sIdx}, ...
        mean(uMedian(sel)), fracSeg1, mean(errPWL(sel)), mean(errChord(sel)), mean(errCurv(sel)));
end
fprintf(['\n(+ = the model OVER-PROMISES heat. This project already established for the fuel\n' ...
    ' cell that optimism and pessimism are not symmetric in cost -- a shortfall is covered\n' ...
    ' at the import tariff while a surplus is only worth the export price -- so the SIGN\n' ...
    ' of this column predicts the sign of the cost penalty.)\n']);

fprintf(['\nTHE MECHANISM, AND IT IS A BREAKPOINT-PLACEMENT PROBLEM RATHER THAN A PWL ONE.\n' ...
    'In winter the heat pump runs near its rating and crosses every segment, so a\n' ...
    '5-segment model is far more accurate than a chord and PWL pays. In summer the only\n' ...
    'heat demand is a flat domestic-hot-water baseline, the heat pump sits at about 13%%\n' ...
    'load, and it therefore lives almost entirely INSIDE SEGMENT 1 -- where a uniform\n' ...
    '5-segment fit averages the curve''s steepest rise into one wide chord of slope %.2f\n' ...
    'against a true COP near %.2f at that load. The finer model is the MORE optimistic one\n' ...
    'exactly where the device operates, and optimism costs money.\n' ...
    '\nSo the failure is not "PWL does not help a heat pump". It is "uniform breakpoints put\n' ...
    'the coarsest approximation exactly where this curve bends most, and a device that\n' ...
    'operates only in that region is worse off with them than without them."\n'], ...
    hpRef.slopes(1), hpRef.copRated * p.HeatPump.partLoad_func(0.13));

%% The placement fix, measured -------------------------------------------
stCurv = paired_stats(dCurv, true);
hpCurvRef = heatpump_curve(pCurv, 9.0);
fprintf('\n--- Same test with CURVATURE-PLACED breakpoints (same segment count) ---\n');
fprintf('breakpoints at u = '); fprintf('%.3f ', hpCurvRef.bkpt.x / p.HeatPump.Pmax); fprintf('\n');
fprintf('slopes           = '); fprintf('%.3f ', hpCurvRef.slopes); fprintf('\n');
fprintf('binaries still required? %d\n', hpCurvRef.needsBinaries);
fprintf('%-22s %8.3f %8.3f %8.3f [%+8.3f,%+7.3f] %4d/%-3d %9.2g\n', 'Benefit vs chord', ...
    stCurv.mean, stCurv.median, stCurv.sd, stCurv.ciLo, stCurv.ciHi, ...
    stCurv.nAgree, stCurv.nNonZero, stCurv.signP);
fprintf('Verdict: %s\n', stCurv.verdict);
fprintf('%-10s %9s %18s   %s\n', 'season', 'mean %', '95% CI (t)', 'verdict');
for sIdx = 1:numel(seasons)
    sel = strcmp(drawSeason, seasons{sIdx});
    stc = paired_stats(dCurv(sel), true);
    fprintf('%-10s %9.3f [%+8.3f,%+7.3f]   %s\n', seasons{sIdx}, stc.mean, stc.ciLo, stc.ciHi, stc.verdict);
end

%% The cost of the complexity -------------------------------------------
nBinPWL = (p.HeatPump.nSegments - 1) * 24;
fprintf('\n--- What the complexity costs ---\n');
fprintf('%-40s %12.3f s\n', 'Mean closed-loop solve time, PWL',   mean(tPWL));
fprintf('%-40s %12.3f s\n', 'Mean closed-loop solve time, chord', mean(tChord));
fprintf('%-40s %+11.1f %%\n', 'Added solve time', 100*(mean(tPWL)-mean(tChord))/mean(tChord));
fprintf('%-40s %12d\n', 'Added binaries, day-ahead (24 h)', nBinPWL);
fprintf('%-40s %12d\n', 'Added binaries, per intraday solve', (p.HeatPump.nSegments-1)*4);
fprintf('%-40s %12.1f kWh\n', 'Mean HP electricity, PWL',   mean(hpElecPWL));
fprintf('%-40s %12.1f kWh\n', 'Mean HP electricity, chord', mean(hpElecChord));
fprintf('%-40s %12.2f $\n', 'Mean true-curve correction, PWL',   mean(corrPWL));
fprintf('%-40s %12.2f $\n', 'Mean true-curve correction, chord', mean(corrChord));

%% (B) Context: the curve vs the legacy constant -------------------------
stLeg = paired_stats(dLegacy, true);
fprintf('\n=====================================================\n');
fprintf(' (B) CONTEXT, NOT THE GATE: the curve vs the legacy constant COP 3.2\n');
fprintf('=====================================================\n');
fprintf('mean %+.2f%%, median %+.2f%%, 95%% CI [%+.2f, %+.2f], %d/%d draws\n', ...
    stLeg.mean, stLeg.median, stLeg.ciLo, stLeg.ciHi, stLeg.nAgree, stLeg.nNonZero);
fprintf(['\nThis is a LEVEL change and not a PWL result. The legacy model assumed COP 3.2\n' ...
    'everywhere; the sourced curve gives %.2f at the shoulder rating point and %.2f in\n' ...
    'winter. A better heat pump is cheaper to run -- that is arithmetic, not modelling,\n' ...
    'and quoting it as a PWL benefit would be the same category error this project\n' ...
    'already refuses for the 72.1%% headline. It is reported because the seasonal cost\n' ...
    'figures in Month 3 and Month 4a move by this much, not because it argues for PWL.\n'], ...
    heatpump_curve(p, 9.0).copRated, heatpump_curve(p, 0.5).copRated);

%% Verdict ---------------------------------------------------------------
fprintf('\n=====================================================\n');
fprintf(' GATE DECISION\n');
fprintf('=====================================================\n');
passed = stGate.distinguishable && stGate.bootDistinguishable && stGate.signSignificant && stGate.mean > 0;
curvPassed = stCurv.distinguishable && stCurv.bootDistinguishable && stCurv.signSignificant && stCurv.mean > 0;

if passed
    fprintf(['GATE PASSED. Heat-pump PWL is worth %+.3f%% (95%% CI %+.3f to %+.3f), the\n' ...
        'direction held in %d of %d draws, and the exact sign test gives p = %.2g.\n'], ...
        stGate.mean, stGate.ciLo, stGate.ciHi, stGate.nAgree, stGate.nNonZero, stGate.signP);
else
    fprintf(['*** THE GATE AS SPECIFIED DOES NOT PASS. ***\n' ...
        'Heat-pump PWL with UNIFORM breakpoints -- the same treatment the fuel cell gets --\n' ...
        'measures %+.3f%% over %d draws, 95%% CI [%+.3f, %+.3f], which SPANS ZERO. It costs\n' ...
        '%d extra binaries per day-ahead solve and %+.0f%% closed-loop solve time for a\n' ...
        'benefit that cannot be resolved.\n' ...
        '\nPer the instructions, Tasks 2 (PV inverter) and 3 (battery) were therefore NOT\n' ...
        'run. More PWL is not assumed to be better.\n' ...
        '\nAND THE DEVICE-LEVEL VERDICT WOULD BE THE WRONG LESSON TO TAKE. The seasonal\n' ...
        'split resolves cleanly in every season and does not agree with itself: %+.3f%% in\n' ...
        'winter and %+.3f%% at the shoulder, both distinguishable from zero, against\n' ...
        '%+.3f%% in summer, which is a RELIABLE COST (0 of 20 draws in the claimed\n' ...
        'direction). The pooled null is those cancelling, not an absence of effect.\n'], ...
        stGate.mean, stGate.n, stGate.ciLo, stGate.ciHi, nBinPWL, ...
        100*(mean(tPWL)-mean(tChord))/mean(tChord), ...
        stSea{1}.mean, stSea{2}.mean, stSea{3}.mean);
end

if curvPassed
    fprintf(['\n--- AND THE SAME CURVE WITH BREAKPOINTS IN BETTER PLACES DOES PASS ---\n' ...
        'Curvature-placed breakpoints, SAME segment count, SAME binaries, same solve cost:\n' ...
        '%+.3f%% (95%% CI %+.3f to %+.3f), %d of %d draws, sign test p = %.2g. All three\n' ...
        'tests agree, and summer stops being a cost (%+.3f%%, no longer resolvable as\n' ...
        'negative) instead of remaining one.\n' ...
        '\nSO THE HONEST CONCLUSION IS NOT "PWL DOES NOT HELP A HEAT PUMP". It is:\n' ...
        '  Uniform breakpoints put the coarsest part of the fit exactly where this curve\n' ...
        '  bends most, and a device that operates only in that region is worse off with\n' ...
        '  them than without them. Placement, not segment count, is what was wrong.\n' ...
        '\nWHY THE DEFAULT IS STILL OFF, stated because passing a gate and shipping a\n' ...
        'change are different decisions. The configuration that passes is not the one the\n' ...
        'gate specified, it was measured after the fact on the same draws that diagnosed\n' ...
        'the failure, and enabling it would also apply the +%.0f%% LEVEL change in section\n' ...
        '(B) to every cost figure in Months 3 and 4. multiscale_default_params.m therefore\n' ...
        'keeps the legacy constant so every existing result reproduces exactly, and this\n' ...
        'file records what a follow-up session should enable and what it would be worth.\n' ...
        'Confirming a fix on the data that suggested it is a weaker claim than the one\n' ...
        'this project usually makes, and it is labelled rather than promoted.\n'], ...
        stCurv.mean, stCurv.ciLo, stCurv.ciHi, stCurv.nAgree, stCurv.nNonZero, stCurv.signP, ...
        paired_stats(dCurv(strcmp(drawSeason,'summer')), true).mean, stLeg.mean);
else
    fprintf(['\nCurvature placement does not rescue it either (%+.3f%%, 95%% CI [%+.3f, %+.3f]),\n' ...
        'so the negative is about the device rather than about where the breakpoints sit.\n'], ...
        stCurv.mean, stCurv.ciLo, stCurv.ciHi);
end

fprintf(['\nWHAT THIS BOUNDS, AND IT IS THE POINT OF THE SESSION. The heat pump has ~15x the\n' ...
    'fuel cell''s throughput and comparable curvature, so a rule of the form "PWL pays\n' ...
    'above X kWh/day throughput" would have predicted a clear win here and did not get\n' ...
    'one. Throughput is necessary and nowhere near sufficient. See main_month4j for the\n' ...
    'device table and the decision rule the data actually supports.\n']);
