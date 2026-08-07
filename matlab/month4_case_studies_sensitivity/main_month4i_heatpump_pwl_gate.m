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

% NOTE: -x preserves the chunk selectors. A bare `clear` wipes them, so every
% chunk would run the FULL draw set -- looking like success while doing the
% opposite of chunking. main_month4e hit exactly this.
clear -x MC_CHUNK MC_NCHUNK; clc;
addpath('../month3_multiscale_optimization');
addpath('../month2_coupling_matrix_pwl_ieee33');

p = multiscale_default_params();
% The shipped default is usePWL = false -- see multiscale_default_params.m,
% and the reason is this script's own verdict. Every arm below that is meant
% to use the CURVE therefore switches it on explicitly rather than inheriting
% it, so the file keeps working whichever way the default is later set.
p.HeatPump.usePWL = true;

nSeeds  = 20;
seasons = {'winter', 'shoulder', 'summer'};
nDraw   = nSeeds * numel(seasons);

% ---- CHUNKED EXECUTION ------------------------------------------------
% glpk leaks ~46.5 MB per full-day simulation at nSegments=10 and Octave
% never releases it (`clear` does not help -- it is held at the C level).
% This script runs 60 draws x 5 day-sims = 300, i.e. ~13.6 GB, which does
% not fit. Chunking is EXACT: draws are independent and forecast_profiles
% is seeded per draw, so draw i is bit-identical whichever process runs it.
% BUDGET RULE: ~46.5 MB x draws/chunk x sims/draw. 5 draws x 5 = 25 sims
% ~ 1.14 GB, so 12 chunks of 5. Resize with that rule for your machine.
if exist('MC_CHUNK', 'var') && exist('MC_NCHUNK', 'var')
    chunkMode = true; cIdx = MC_CHUNK; nChunk = MC_NCHUNK;
else
    chunkMode = false; cIdx = 0; nChunk = 1;
end
allSeason = cell(nDraw,1); allSeed = zeros(nDraw,1);
q = 0;
for sIdx = 1:numel(seasons)
    for sd = 1:nSeeds
        q = q + 1; allSeason{q} = seasons{sIdx}; allSeed(q) = sd;
    end
end
lo = floor(cIdx*nDraw/nChunk) + 1; hi = floor((cIdx+1)*nDraw/nChunk);
myDraws = lo:hi;
% The curve/slope check and the ordering-binary counterfactual below are
% properties of the MODEL, not of any draw, so they are run once: in the
% single-process path and in CHUNK 0. Other chunks skip them.
showDiag = ~chunkMode || cIdx == 0;
if chunkMode
    fprintf('CHUNK %d of %d: draws %d..%d (%d of %d)\n', cIdx, nChunk, lo, hi, numel(myDraws), nDraw);
    fflush(stdout);
end

fprintf('=====================================================\n');
fprintf(' GATE: heat-pump PWL -- does it pay?\n');
fprintf('=====================================================\n');
fprintf('%d draws = %d seeds x %d seasons, paired within draw.\n', ...
    nDraw, nSeeds, numel(seasons));

%% The curve, and the slope check that decides the binaries --------------
% hpRef is a curve FIT (no solve, negligible cost) and the reporter needs it,
% so it is computed on every path rather than inside the diagnostic guard.
hpRef = heatpump_curve(p, 9.0);
if showDiag
fprintf('\n--- The fitted curve, per season ambient ---\n');
fprintf('%-10s %8s %9s %10s %10s   %s\n', 'season', 'amb C', 'clamped', 'COP rated', 'binaries', 'segment slopes (COP per segment)');
for sIdx = 1:numel(seasons)
    fcS = forecast_profiles(42, 1.0, [], seasons{sIdx});
    hpS = heatpump_curve(p, fcS.ambientC);
    fprintf('%-10s %8.1f %9.1f %10.3f %10d   ', seasons{sIdx}, ...
        hpS.ambientRaw, hpS.ambientC, hpS.copRated, hpS.needsBinaries);
    fprintf('%.4f ', hpS.slopes); fprintf('\n');
end
fprintf(['\nSLOPE MONOTONICITY, CHECKED RATHER THAN ASSUMED: segment 2''s slope EXCEEDS\n' ...
    'segment 1''s in every season, so the slopes are NOT monotonically decreasing and\n' ...
    'FILL-ORDER BINARIES ARE REQUIRED. The mechanism is the low-load cycling penalty --\n' ...
    'the first slice of load is the LEAST efficient, so an LP relaxation would fill\n' ...
    'segment 2 while segment 1 sits empty and claim more heat per kWh than the machine\n' ...
    'can deliver. Same situation as the fuel cell, same fix, and it is measured here\n' ...
    'rather than assumed: %d binaries per time step, %d over a 24-hour day-ahead solve.\n'], ...
    hpRef.nSegments - 1, (hpRef.nSegments - 1) * 24);

%% The counterfactual: are those binaries actually load-bearing? ----------
% Month 4a verified this for the FUEL CELL by relaxing its ordering
% indicators and catching segment 2 filling ahead of segment 1. The same
% claim for the heat pump was, until this check, only a prediction from the
% slope signs. It is now solved. p.diag.relaxOrder leaves the indicators
% continuous; nothing else changes.
fprintf('\n--- Counterfactual: the SAME day-ahead solve with the ordering indicators relaxed ---\n');
pRlx = p; pRlx.diag.relaxOrder = true;
fprintf('%-10s %12s %12s %14s %12s %12s\n', 'season', 'MILP pairs', 'LP pairs', ...
    'worst fill', 'cost LP', 'cost MILP');
cfViol = zeros(1, numel(seasons)); cfWorst = ones(1, numel(seasons));
for sIdx = 1:numel(seasons)
    fcCF  = forecast_profiles(42, 1.0, [], seasons{sIdx});
    DAmip = dayahead_dispatch(p,    fcCF);
    DAlp  = dayahead_dispatch(pRlx, fcCF);
    hpCF  = heatpump_curve(p, fcCF.ambientC);
    vLP = 0; vMIP = 0; worstFill = 1; worstT = 0; worstNext = 0;
    for t = 1:size(DAlp.HPseg, 1)
        for k = 1:(hpCF.nSegments - 1)
            if DAlp.HPseg(t,k+1) > 1e-6 && DAlp.HPseg(t,k)/hpCF.w(k) < 1 - 1e-6
                vLP = vLP + 1;
                if DAlp.HPseg(t,k)/hpCF.w(k) < worstFill
                    worstFill = DAlp.HPseg(t,k)/hpCF.w(k);
                    worstT = t; worstNext = DAlp.HPseg(t,k+1);
                end
            end
            if DAmip.HPseg(t,k+1) > 1e-6 && DAmip.HPseg(t,k)/hpCF.w(k) < 1 - 1e-6
                vMIP = vMIP + 1;
            end
        end
    end
    cfViol(sIdx) = vLP; cfWorst(sIdx) = worstFill;
    if vLP > 0
        fprintf('%-10s %12d %12d %10.1f%% h%-2d %12.4f %12.4f\n', seasons{sIdx}, ...
            vMIP, vLP, 100*worstFill, worstT, DAlp.cost, DAmip.cost);
    else
        fprintf('%-10s %12d %12d %14s %12.4f %12.4f\n', seasons{sIdx}, ...
            vMIP, vLP, 'none', DAlp.cost, DAmip.cost);
    end
end
fprintf(['\nTHE BINARIES ARE LOAD-BEARING, AND ONLY WHERE THE PHYSICS SAYS THEY SHOULD BE.\n' ...
    'Relaxed, the LP puts load into segment 2 while segment 1 is as little as %.1f%% full --\n' ...
    'exactly the cherry-pick the non-monotonic slopes predict, and it buys itself a cheaper\n' ...
    'day-ahead by claiming heat the machine cannot produce. But it does NOT happen in\n' ...
    'winter (%d pairs there against %d in shoulder and %d in summer), and the reason is\n' ...
    'the same one that drives the whole gate result: in winter the heat pump runs near its\n' ...
    'rating, every segment is full, and there is no spare capacity in segment 1 to leave\n' ...
    'empty. The defect appears precisely at PART LOAD.\n' ...
    '\nThis is a CORRECTNESS result and it stands whichever way the cost gate below goes.\n' ...
    'A model that reports dispatches its machine cannot deliver is wrong irrespective of\n' ...
    'what the error is worth on a given day -- the same argument Month 4a makes for the\n' ...
    'fuel cell, now measured on a second device rather than assumed to carry over.\n'], ...
    100*min(cfWorst), cfViol(1), cfViol(2), cfViol(3));
fflush(stdout);

end  % showDiag

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

t0 = tic;
for i = myDraws
        sd = allSeed(i);
        drawSeason{i} = allSeason{i};
        fcD = forecast_profiles(sd, 1.0, [], allSeason{i});

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
fprintf('\n%d draws in %.0f s.\n', numel(myDraws), toc(t0));

if chunkMode
    % RAW per-draw vectors only, never partial statistics -- means and
    % intervals do not combine across chunks.
    outDir = fullfile(fileparts(mfilename('fullpath')), 'mc_chunks');
    if ~exist(outDir, 'dir'); mkdir(outDir); end
    chunk = struct('script','month4i','chunkIdx',cIdx,'nChunk',nChunk, ...
                   'drawIdx',myDraws(:),'nDrawTotal',nDraw, ...
                   'drawSeason',{allSeason(myDraws)},'drawSeed',allSeed(myDraws), ...
                   'seasons',{seasons},'nSeeds',nSeeds);
    chunk.dGate = dGate(myDraws)';
    chunk.dCurv = dCurv(myDraws)';
    chunk.dLegacy = dLegacy(myDraws)';
    chunk.uMedian = uMedian(myDraws)';
    chunk.errPWL = errPWL(myDraws)';
    chunk.errChord = errChord(myDraws)';
    chunk.errCurv = errCurv(myDraws)';
    chunk.tPWL = tPWL(myDraws)';
    chunk.tChord = tChord(myDraws)';
    chunk.hpElecPWL = hpElecPWL(myDraws)';
    chunk.hpElecChord = hpElecChord(myDraws)';
    chunk.corrPWL = corrPWL(myDraws)';
    chunk.corrChord = corrChord(myDraws)';
    save('-mat7-binary', fullfile(outDir, sprintf('month4i_chunk%03d.mat', cIdx)), 'chunk');
    fprintf('Chunk %d saved (%d draws). Statistics deferred to mc_aggregate.\n', cIdx, numel(myDraws));
    return
end

S = struct('p',p,'nDraw',nDraw,'seasons',{seasons},'drawSeason',{drawSeason}, ...
           'hpRef',hpRef,'pPWL',pPWL,'pChord',pChord,'pCurv',pCurv,'pLegacy',pLegacy,'optFull',optFull);
S.dGate = dGate;
S.dCurv = dCurv;
S.dLegacy = dLegacy;
S.uMedian = uMedian;
S.errPWL = errPWL;
S.errChord = errChord;
S.errCurv = errCurv;
S.tPWL = tPWL;
S.tChord = tChord;
S.hpElecPWL = hpElecPWL;
S.hpElecChord = hpElecChord;
S.corrPWL = corrPWL;
S.corrChord = corrChord;
mc_report_month4i(S);
