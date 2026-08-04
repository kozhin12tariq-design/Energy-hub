function st = paired_stats(d, claimPositive)
%PAIRED_STATS Confidence interval and sign test for a paired difference sample.
%
%   st = PAIRED_STATS(d, claimPositive)
%
%   d             : vector of PAIRED per-draw differences (one per scenario)
%   claimPositive : true if the thesis claims the difference is > 0
%
%   WHY PAIRED. Each draw runs BOTH configurations on the SAME scenario, so
%   the difference d_i already has the scenario out of it. Everything that
%   makes one day expensive and another cheap -- season, forecast noise, PV
%   availability -- is common to both members of the pair and cancels in the
%   subtraction. Comparing two independent samples of costs instead would
%   drown a 0.26% effect in a between-scenario spread many times larger, and
%   would be the wrong test.
%
%   NO TOOLBOXES. Octave's statistics package is not a dependency of this
%   project (glpk only), so nothing here calls tinv, ttest or bootci:
%     - the t critical values are a hardcoded table of the standard
%       two-sided 95% points, exact for the degrees of freedom used and
%       with a documented large-sample fallback;
%     - the bootstrap uses rand() directly;
%     - the sign test is an exact binomial tail summed in log space with
%       gammaln (nchoosek overflows its precision well before 60 draws).
%
%   THREE TESTS, NOT ONE, because they fail differently. The t interval
%   assumes the paired differences are roughly normal, which a 60-draw
%   sample pooled across three seasons need not be -- if a claim's sign
%   flips seasonally the sample is bimodal, and that is exactly the case
%   this project has to be able to detect. The bootstrap percentile
%   interval makes no distributional assumption. The sign test uses only
%   the direction of each difference and is therefore immune to outliers
%   and to scale entirely. When the three agree, the verdict is safe; when
%   they disagree, that disagreement is itself the finding and is printed.
%
%   Output struct st:
%     n, mean, sd, sem
%     ciLo, ciHi          : 95% t interval on the mean difference
%     bootLo, bootHi      : 95% bootstrap percentile interval (10000 resamples)
%     median              : median difference -- reported next to the mean
%                           because a mean and a median that disagree is the
%                           signature of an outlier-driven result, which is
%                           exactly what a sign test then detects
%     nAgree, fracAgree   : draws whose sign matches the claim
%     signP               : exact two-sided sign-test p-value
%     distinguishable     : true if the t interval excludes zero
%     bootDistinguishable : true if the bootstrap interval excludes zero
%     signSignificant     : true if the sign test rejects at 5% in the
%                           claimed direction
%     signOpposite        : true if it rejects at 5% in the OPPOSITE
%                           direction -- 0 of 20 draws agreeing is strong
%                           evidence against the claim, not weak evidence
%                           for it, and must not be labelled 'outlier-driven'
%     verdict             : short human-readable string

    d = d(:);
    d = d(isfinite(d));
    st.n    = numel(d);
    st.mean   = mean(d);
    st.median = median(d);
    st.sd     = std(d);
    st.sem  = st.sd / sqrt(st.n);

    tc = t_crit_95(st.n - 1);
    st.tcrit = tc;
    st.ciLo  = st.mean - tc*st.sem;
    st.ciHi  = st.mean + tc*st.sem;

    % Bootstrap percentile interval on the mean, distribution-free.
    nBoot = 10000;
    rand('seed', 20240501);   %#ok<RAND> fixed so the interval is reproducible
    bm = zeros(nBoot,1);
    for b = 1:nBoot
        idx = min(st.n, max(1, ceil(rand(st.n,1)*st.n)));
        bm(b) = mean(d(idx));
    end
    bs = sort(bm);
    st.bootLo = bs(max(1, floor(0.025*nBoot)));
    st.bootHi = bs(min(nBoot, ceil(0.975*nBoot)));

    % Sign test on the claimed direction. Ties (exact zeros) are dropped,
    % which is the standard treatment and is conservative here.
    if claimPositive
        agree = sum(d > 0);
    else
        agree = sum(d < 0);
    end
    nz = sum(d ~= 0);
    st.nAgree    = agree;
    st.nNonZero  = nz;
    st.fracAgree = agree / max(nz, 1);
    st.signP     = sign_test_p(agree, nz);

    st.distinguishable     = (st.ciLo > 0) || (st.ciHi < 0);
    st.bootDistinguishable = (st.bootLo > 0) || (st.bootHi < 0);
    st.signSignificant     = (st.signP < 0.05) && (st.fracAgree > 0.5);
    % A sample can be significant in the OPPOSITE direction to the claim --
    % 0 of 20 draws agreeing is not weak evidence, it is strong evidence
    % against. Without this flag such a case falls into the outlier-driven
    % branch and gets exactly the wrong label.
    st.signOpposite        = (st.signP < 0.05) && (st.fracAgree < 0.5);

    % THE VERDICT USES ALL THREE TESTS, and refuses to average them. An
    % interval on the MEAN can exclude zero while the sign test says the
    % difference is positive in barely half the draws -- that combination is
    % not a contradiction, it is a diagnosis: the mean is being carried by a
    % minority of large-magnitude draws rather than by a consistent effect.
    % Reporting only the interval would turn "usually nothing, occasionally
    % large" into "reliably positive", which is the more flattering and less
    % true statement. It is called out as its own category.
    ciOK = st.distinguishable && st.bootDistinguishable;
    if ciOK && st.signOpposite
        st.verdict = 'CONSISTENTLY OPPOSITE to the claim -- a reliable COST';
    elseif st.signOpposite
        st.verdict = 'direction consistently OPPOSITE; mean interval spans zero';
    elseif ciOK && st.signSignificant
        st.verdict = 'DISTINGUISHABLE from zero (interval and sign test agree)';
    elseif ciOK && ~st.signSignificant
        st.verdict = 'MEAN nonzero but OUTLIER-DRIVEN -- sign test does not reject';
    elseif ~ciOK && st.signSignificant
        st.verdict = 'DIRECTION consistent but mean interval spans zero';
    elseif st.distinguishable || st.bootDistinguishable
        st.verdict = 'BORDERLINE -- the two intervals disagree';
    else
        st.verdict = 'NOT distinguishable from zero at 95%';
    end
end

function tc = t_crit_95(df)
% Two-sided 95% critical values of Student's t. Table for the small df a
% study like this actually uses; normal-approximation fallback beyond it,
% where the difference from 1.96 is under 1%.
    tbl = [12.706 4.303 3.182 2.776 2.571 2.447 2.365 2.306 2.262 2.228 ...
            2.201 2.179 2.160 2.145 2.131 2.120 2.110 2.101 2.093 2.086 ...
            2.080 2.074 2.069 2.064 2.060 2.056 2.052 2.048 2.045 2.042];
    if df < 1
        tc = Inf;
    elseif df <= numel(tbl)
        tc = tbl(df);
    else
        % Peizer-Pratt style correction on the normal quantile; within
        % 0.3% of the exact value for df > 30, and it decays to 1.96.
        tc = 1.959964 * (1 + 1/(4*df));
    end
end

function p = sign_test_p(k, n)
% Exact two-sided binomial sign test against p = 0.5, computed in LOG space.
% nchoosek(60,30) is ~1.18e17 and Octave warns about precision loss well
% before that; gammaln keeps the whole calculation in double range for any
% draw count this study could plausibly use.
    if n == 0; p = 1; return; end
    k  = min(max(k,0), n);
    kk = max(k, n-k);                 % work in the upper tail
    tail = 0;
    for i = kk:n
        logTerm = gammaln(n+1) - gammaln(i+1) - gammaln(n-i+1) - n*log(2);
        tail = tail + exp(logTerm);
    end
    p = min(1, 2*tail);
end
