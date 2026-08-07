%MAIN_MONTH4E_MONTE_CARLO
%Confidence intervals on the claims this thesis actually makes.
%
%   Three numbers carry the modelling argument of this project, and until
%   now every one of them was a SINGLE-DRAW POINT ESTIMATE from one seed on
%   one day:
%     - PWL vs constant fuel-cell efficiency  ~0.26% on the delivered price
%     - rolling intraday/real-time layers     ~+2.9%
%     - robust reserve margin                 ~+2.6%
%
%   A reader is entitled to ask whether a 0.26% difference is
%   distinguishable from scenario noise at all. This script answers that
%   rather than asserting it.
%
%   PROTOCOL
%     draws       : nSeeds x 3 seasons, default 20 x 3 = 60 independent
%                   scenarios. Both the forecast seed and the season vary,
%                   so the sample spans the range of conditions the hub
%                   actually meets rather than re-sampling noise on one day.
%     pairing     : every comparison runs BOTH configurations on the SAME
%                   draw and differences them per draw. The scenario is
%                   then common to both members of the pair and cancels
%                   exactly. Unpaired comparison of two cost samples would
%                   be dominated by the ~16x spread between winter and
%                   summer costs and could not resolve a sub-1% effect --
%                   pairing is not a refinement here, it is the only test
%                   with any power.
%     metric      : each difference is expressed as a PERCENTAGE of its own
%                   baseline, because absolute dollars are not comparable
%                   across seasons (a winter day costs 16x a summer day, so
%                   an absolute-dollar mean would simply be a winter mean).
%     statistics  : paired_stats.m -- 95% t interval, 95% bootstrap
%                   percentile interval, and an exact sign test. Three
%                   tests because they fail differently; a claim whose sign
%                   flips seasonally gives a bimodal sample that the t
%                   interval alone would mis-handle.
%
%   REPORTING RULE FOLLOWED HERE: if an interval spans zero, that is stated
%   directly and prominently. A benefit that cannot be distinguished from
%   noise is a finding about the method's limits, and burying it would
%   undermine every other number in the thesis.
%
%   Runtime: about 5 solves per draw at roughly 2 s each, so ~10 minutes at
%   the default 60 draws. Set nSeeds below to trade runtime for power --
%   but reduce the number of COMPARISONS before reducing draws, because
%   statistical power comes from draws.
%
%   Run with:  main_month4e_monte_carlo

% NOTE: -x preserves the chunk selectors. A bare `clear` here silently wiped
% them, so every chunk ran the FULL draw set and reported statistics -- which
% would have looked like success while doing the opposite of chunking.
clear -x MC_CHUNK MC_NCHUNK; clc;
addpath('../month3_multiscale_optimization');
addpath('../month2_coupling_matrix_pwl_ieee33');

p = multiscale_default_params();

nSeeds   = 20;
seeds    = 1:nSeeds;
seasons  = {'winter', 'shoulder', 'summer'};
nDraw    = nSeeds * numel(seasons);

fprintf('=====================================================\n');
fprintf(' Monte Carlo confidence intervals on the headline claims\n');
fprintf('=====================================================\n');
fprintf('%d draws = %d seeds x %d seasons. Paired within draw.\n', ...
    nDraw, nSeeds, numel(seasons));
fprintf('PWL comparison is run at the LIKE-FOR-LIKE delivered hydrogen price\n');
fprintf('($%.2f/kg), the basis the 0.26%% headline was quoted on.\n', ...
    p.scenarios.H2_doeTargetDelivered * p.scenarios.H2_kWhPerKg);
fflush(stdout);

pDel = p;
pDel.price_H2 = p.scenarios.H2_doeTargetDelivered;

% Per-draw paired differences, all in percent of the relevant baseline.
dPWL     = zeros(nDraw,1);   % (constant-efficiency cost - PWL cost) / PWL cost
dRolling = zeros(nDraw,1);   % (open-loop cost      - full cost) / full cost
dReserve = zeros(nDraw,1);   % (no-reserve cost     - full cost) / full cost
drawSeason = cell(nDraw,1);
drawSeed   = zeros(nDraw,1);

optFull  = struct('useIntraday', true,  'reserveScale', 1.0);
optOpen  = struct('useIntraday', false, 'reserveScale', 1.0);
optNoRes = struct('useIntraday', true,  'reserveScale', 0.0);
optPWL   = struct('useIntraday', true,  'reserveScale', 1.0, 'usePWL', true);
optConst = struct('useIntraday', true,  'reserveScale', 1.0, 'usePWL', false);

% ---- CHUNKED EXECUTION ------------------------------------------------
% WHY THIS EXISTS, and it is a toolchain constraint rather than a modelling
% one. glpk leaks memory on every integer solve and Octave's interface does
% not release it; measured on this repository at nSegments = 10, a full-day
% simulation costs ~46.5 MB that is never returned, LINEARLY, and `clear`
% does not help because the memory is held at the C level outside Octave's
% variable space. Only process exit releases it. This script runs
% 60 draws x 5 configurations = 300 day-sims, i.e. ~14 GB, which does not
% fit. Splitting the draws across separate processes fixes it because the
% draws are INDEPENDENT: forecast_profiles(sd, ...) is seeded per draw, so
% draw i is bit-identical regardless of which process computes it.
%
% Set MC_CHUNK (0-based) and MC_NCHUNK to run a slice and save raw
% per-draw differences; leave them unset for the original single-process
% behaviour, which is unchanged. Statistics are NOT computed in chunk mode:
% they belong to mc_aggregate, which sees every draw.
if exist('MC_CHUNK', 'var') && exist('MC_NCHUNK', 'var')
    chunkMode = true; cIdx = MC_CHUNK; nChunk = MC_NCHUNK;
else
    chunkMode = false; cIdx = 0; nChunk = 1;
end

% Build the FULL ordered draw list first, then slice it. Partitioning over
% the draw index rather than over seasons or seeds separately is what
% guarantees the union of chunks is exactly the current 60-draw set in the
% current order.
allSeason = cell(nDraw,1); allSeed = zeros(nDraw,1);
q = 0;
for sIdx = 1:numel(seasons)
    for sd = seeds
        q = q + 1; allSeason{q} = seasons{sIdx}; allSeed(q) = sd;
    end
end
lo = floor(cIdx*nDraw/nChunk) + 1;
hi = floor((cIdx+1)*nDraw/nChunk);
myDraws = lo:hi;
if chunkMode
    fprintf('CHUNK %d of %d: draws %d..%d (%d of %d)\n', ...
            cIdx, nChunk, lo, hi, numel(myDraws), nDraw);
    fflush(stdout);
end

t0 = tic;
for i = myDraws
        sd = allSeed(i);
        drawSeason{i} = allSeason{i};
        drawSeed(i)   = sd;

        fcD = forecast_profiles(sd, 1.0, [], allSeason{i});

        Cfull = simulate_multiscale_day(p,    fcD, optFull);
        Copen = simulate_multiscale_day(p,    fcD, optOpen);
        Cnore = simulate_multiscale_day(p,    fcD, optNoRes);
        Cpwl  = simulate_multiscale_day(pDel, fcD, optPWL);
        Ccon  = simulate_multiscale_day(pDel, fcD, optConst);

        dRolling(i) = 100*(Copen.actualCost - Cfull.actualCost) / Cfull.actualCost;
        dReserve(i) = 100*(Cnore.actualCost - Cfull.actualCost) / Cfull.actualCost;
        dPWL(i)     = 100*(Ccon.actualCost  - Cpwl.actualCost)  / Cpwl.actualCost;

        fprintf('  draw %d/%d done (%.0f s elapsed)\n', i, nDraw, toc(t0));
        fflush(stdout);
end
fprintf('%d draws complete in %.0f s.\n', numel(myDraws), toc(t0));

if chunkMode
    % RAW DIFFERENCES ONLY, never partial statistics. Means and confidence
    % intervals do not combine across chunks, so saving them would be an
    % invitation to average them later and get a wrong answer.
    outDir = fullfile(fileparts(mfilename('fullpath')), 'mc_chunks');
    if ~exist(outDir, 'dir'); mkdir(outDir); end
    chunk = struct('script', 'month4e', 'chunkIdx', cIdx, 'nChunk', nChunk, ...
                   'drawIdx', myDraws(:), 'nDrawTotal', nDraw, ...
                   'drawSeason', {allSeason(myDraws)}, 'drawSeed', allSeed(myDraws), ...
                   'dPWL', dPWL(myDraws)', 'dRolling', dRolling(myDraws)', ...
                   'dReserve', dReserve(myDraws)', 'seasons', {seasons}, 'nSeeds', nSeeds);
    save('-mat7-binary', fullfile(outDir, sprintf('month4e_chunk%03d.mat', cIdx)), 'chunk');
    fprintf('Chunk %d saved (%d draws). Statistics deferred to mc_aggregate.\n', cIdx, numel(myDraws));
    return
end


mc_report_month4e(dPWL, dRolling, dReserve, drawSeason, seasons, nSeeds);
