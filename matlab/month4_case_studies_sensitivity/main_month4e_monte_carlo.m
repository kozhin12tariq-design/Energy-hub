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

clear; clc;
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

t0 = tic;
i = 0;
for sIdx = 1:numel(seasons)
    for sd = seeds
        i = i + 1;
        drawSeason{i} = seasons{sIdx};
        drawSeed(i)   = sd;

        fcD = forecast_profiles(sd, 1.0, [], seasons{sIdx});

        Cfull = simulate_multiscale_day(p,    fcD, optFull);
        Copen = simulate_multiscale_day(p,    fcD, optOpen);
        Cnore = simulate_multiscale_day(p,    fcD, optNoRes);
        Cpwl  = simulate_multiscale_day(pDel, fcD, optPWL);
        Ccon  = simulate_multiscale_day(pDel, fcD, optConst);

        dRolling(i) = 100*(Copen.actualCost - Cfull.actualCost) / Cfull.actualCost;
        dReserve(i) = 100*(Cnore.actualCost - Cfull.actualCost) / Cfull.actualCost;
        dPWL(i)     = 100*(Ccon.actualCost  - Cpwl.actualCost)  / Cpwl.actualCost;

        if mod(i, 10) == 0
            fprintf('  %d/%d draws done (%.0f s elapsed)\n', i, nDraw, toc(t0));
            fflush(stdout);
        end
    end
end
fprintf('All %d draws complete in %.0f s.\n', nDraw, toc(t0));

%% Pooled results -------------------------------------------------------
claims = {'PWL vs constant efficiency', 'Rolling layers (on vs off)', ...
          'Robust reserve (on vs off)'};
diffs  = {dPWL, dRolling, dReserve};
quoted = [0.26, 2.85, 2.62];   % the single-draw shoulder figures being tested

fprintf('\n=====================================================\n');
fprintf(' Pooled over all %d draws (paired, %% of baseline)\n', nDraw);
fprintf('=====================================================\n');
fprintf('%-30s %7s %7s %7s %7s %17s %8s %9s\n', 'Claim', 'quoted', 'mean', 'median', ...
    'sd', '95% CI (t)', 'sign+', 'signtest p');
S = cell(1, numel(claims));
for c = 1:numel(claims)
    S{c} = paired_stats(diffs{c}, true);
    fprintf('%-30s %7.2f %7.2f %7.2f %7.2f [%+7.2f,%+7.2f] %4d/%-3d %9.2g\n', ...
        claims{c}, quoted(c), S{c}.mean, S{c}.median, S{c}.sd, S{c}.ciLo, S{c}.ciHi, ...
        S{c}.nAgree, S{c}.nNonZero, S{c}.signP);
end

fprintf('\n%-30s %18s   %s\n', 'Claim', '95% CI (bootstrap)', 'verdict');
for c = 1:numel(claims)
    fprintf('%-30s  [%+7.2f,%+7.2f]   %s\n', claims{c}, ...
        S{c}.bootLo, S{c}.bootHi, S{c}.verdict);
end

%% Per-season breakdown -------------------------------------------------
% Pooling across seasons can hide a sign flip, and Month 4a found one, so
% the pooled row is never reported on its own here.
fprintf('\n=====================================================\n');
fprintf(' Same claims, split by season (%d draws each)\n', nSeeds);
fprintf('=====================================================\n');
Sseason = cell(numel(claims), numel(seasons));
for c = 1:numel(claims)
    fprintf('\n%s\n', claims{c});
    fprintf('%-12s %8s %8s %18s %8s   %s\n', 'season', 'mean', 'sd', '95% CI (t)', 'sign+', 'verdict');
    for sIdx = 1:numel(seasons)
        sel = strcmp(drawSeason, seasons{sIdx});
        Sseason{c,sIdx} = paired_stats(diffs{c}(sel), true);
        st = Sseason{c,sIdx};
        fprintf('%-12s %8.2f %8.2f  [%+7.2f,%+7.2f] %4d/%-3d   %s\n', ...
            seasons{sIdx}, st.mean, st.sd, st.ciLo, st.ciHi, ...
            st.nAgree, st.nNonZero, st.verdict);
    end
end

%% Verdicts -------------------------------------------------------------
fprintf('\n=====================================================\n');
fprintf(' What survives, and what does not\n');
fprintf('=====================================================\n');

for c = 1:numel(claims)
    st = S{c};
    fprintf('\n--- %s ---\n', claims{c});
    fprintf('Single-draw figure quoted elsewhere: %+.2f%%. Over %d draws: %+.2f%% ' , ...
        quoted(c), st.n, st.mean);
    fprintf('(95%% CI %+.2f to %+.2f).\n', st.ciLo, st.ciHi);
    if st.signOpposite && st.distinguishable
        fprintf(['*** THE EFFECT IS REAL AND POINTS THE WRONG WAY. *** The claimed direction\n' ...
            'held in only %d of %d draws (sign test p = %.2g, i.e. consistently OPPOSITE)\n' ...
            'and the 95%% interval [%+.2f, %+.2f] excludes zero on the negative side. This\n' ...
            'is not a failure to detect a benefit -- it is a measured COST, and it is\n' ...
            'reported as such.\n'], ...
            st.nAgree, st.nNonZero, st.signP, st.ciLo, st.ciHi);
    elseif st.distinguishable && st.bootDistinguishable && st.signSignificant
        fprintf(['STATISTICALLY DISTINGUISHABLE FROM ZERO. The interval excludes zero on both\n' ...
            'the t and the bootstrap test, the claimed direction held in %d of %d draws, and\n' ...
            'the exact sign test gives p = %.2g. All three tests agree; the claim survives.\n'], ...
            st.nAgree, st.nNonZero, st.signP);
    elseif st.distinguishable && st.bootDistinguishable
        fprintf(['*** THE MEAN IS NONZERO BUT THE EFFECT IS OUTLIER-DRIVEN, AND THE TWO TESTS\n' ...
            'DISAGREE FOR A REASON. *** The 95%% interval on the MEAN excludes zero\n' ...
            '[%+.2f, %+.2f], but the claimed direction held in only %d of %d draws and the\n' ...
            'exact sign test does NOT reject (p = %.2g) -- barely better than a coin flip.\n' ...
            'The mean (%+.2f%%) and the median (%+.2f%%) tell different stories, which is the\n' ...
            'signature: a minority of draws with large positive differences is carrying the\n' ...
            'average while the typical draw shows little or nothing.\n' ...
            '\nQuoting the mean alone would turn "usually nothing, occasionally large" into\n' ...
            '"reliably positive". The defensible statement is that this feature pays on\n' ...
            'AVERAGE ACROSS A YEAR-LIKE MIX OF CONDITIONS but cannot be relied on for any\n' ...
            'particular day, and the seasonal split below shows which conditions those are.\n'], ...
            st.ciLo, st.ciHi, st.nAgree, st.nNonZero, st.signP, st.mean, st.median);
    elseif st.signSignificant
        fprintf(['DIRECTION IS CONSISTENT BUT THE MEAN IS NOT RESOLVED. The claimed direction\n' ...
            'held in %d of %d draws (sign test p = %.2g), yet the 95%% interval on the mean\n' ...
            '[%+.2f, %+.2f] spans zero -- the effect is reliable in sign and small or noisy\n' ...
            'in magnitude.\n'], st.nAgree, st.nNonZero, st.signP, st.ciLo, st.ciHi);
    else
        fprintf(['*** NOT STATISTICALLY DISTINGUISHABLE FROM ZERO AT 95%%. ***\n' ...
            'The 95%% interval [%+.2f, %+.2f] SPANS ZERO. The claimed direction held in only\n' ...
            '%d of %d draws (sign test p = %.2g). On this evidence the benefit cannot be\n' ...
            'separated from scenario-to-scenario variation, and the point estimate quoted\n' ...
            'elsewhere should not be presented as an established effect.\n'], ...
            st.ciLo, st.ciHi, st.nAgree, st.nNonZero, st.signP);
    end
    % Season-level disagreement is reported explicitly wherever it exists,
    % because a pooled mean can be positive while a whole season is not.
    signs = zeros(1, numel(seasons));
    for sIdx = 1:numel(seasons)
        signs(sIdx) = Sseason{c,sIdx}.mean;
    end
    if any(signs > 0) && any(signs < 0)
        [~, negIdx] = min(signs);
        negSt = Sseason{c, negIdx};
        fprintf(['SEASONAL SIGN FLIP: mean %+.2f%% in winter, %+.2f%% at the shoulder, %+.2f%% in\n' ...
            'summer. The effect does not merely vary in size, it changes direction.\n'], signs);
        if negSt.distinguishable
            fprintf(['That flip is itself resolved: the %s interval [%+.2f, %+.2f] excludes zero,\n' ...
                'so this feature MEASURABLY COSTS money in that season rather than merely\n' ...
                'failing to pay. A pooled annual-style figure would net that against the\n' ...
                'seasons where it helps and report only the residue.\n'], ...
                seasons{negIdx}, negSt.ciLo, negSt.ciHi);
        else
            fprintf(['The negative season is not itself resolved (%s interval [%+.2f, %+.2f]\n' ...
                'spans zero), so the honest reading is "no benefit in that season" rather\n' ...
                'than "a cost".\n'], seasons{negIdx}, negSt.ciLo, negSt.ciHi);
        end
    end
end

fprintf(['\n=====================================================\n' ...
    ' Scope of these intervals -- read before quoting them\n' ...
    '=====================================================\n' ...
    'They quantify SCENARIO uncertainty: forecast noise and season, which is what the\n' ...
    'draws vary. They do NOT cover uncertainty in the model itself -- efficiency curves,\n' ...
    'prices, emission factors, network data and hub size are held fixed at their\n' ...
    'nominal values in every draw, so no interval here says anything about how wrong\n' ...
    'those inputs might be.\n' ...
    '\nTwo further limits worth stating: the three seasons are weighted equally, which\n' ...
    'is not how a year is distributed, so the pooled mean is not an annual mean; and\n' ...
    'realized cost carries roughly 1%% solver-vertex sensitivity of its own (documented\n' ...
    'in VALIDATION.md), which is comparable to some of the effects being measured and\n' ...
    'is part of what the intervals above are picking up.\n']);
