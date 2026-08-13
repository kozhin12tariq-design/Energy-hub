%MAIN_MONTH4K_MC_FIGURES
%Monte Carlo results with confidence intervals -- PLOTS ONLY, no simulation.
%
%   READS the saved chunk files under mc_chunks/ and plots. It runs NO
%   simulation and writes NO chunk file, so it cannot disturb a completed
%   Monte Carlo. Populate mc_chunks/ first with run_chunked.sh.
%
%   WHY THIS SCRIPT EXISTS SEPARATELY. The 60-draw runs take hours and leak
%   memory through glpk (see mc_aggregate.m), so re-running them to redraw a
%   figure is not acceptable. Chunk files carry the raw per-draw differences;
%   statistics and figures both regenerate from them in seconds.
%
%   THE OBLIGATION THESE PANELS CARRY. This project's central discipline has
%   been distinguishing a RESOLVED result from an OUTLIER-DRIVEN one -- a
%   mean carried by a minority of draws while the sign test refuses to
%   reject. A bar chart that renders +2.86% outlier-driven identically to
%   +2.63% resolved would undo that. So every bar is drawn with:
%     - solid fill + solid error bar  = resolved (interval AND sign test)
%     - hollow fill + dashed error bar = NOT resolved
%     - a "p=..." tag wherever the sign test disagrees with the interval
%   and a zero line on every panel.
%
%   Run with:  main_month4k_mc_figures

clear; clc;
here = fileparts(mfilename('fullpath'));
addpath(here);
addpath(fullfile(here, '..', 'month3_multiscale_optimization'));
outDir = fullfile(here, 'mc_chunks');

fprintf('=====================================================\n');
fprintf(' Monte Carlo figures (reads saved chunks, runs nothing)\n');
fprintf('=====================================================\n');

%% Loading, with mc_aggregate's completeness guard ----------------------
% Same guard, same reason: a silently short Monte Carlo understates every
% confidence interval, which is worse than no figure at all.
function [ok, d, msg] = load_chunks(outDir, tag)
    ok = false; d = struct(); msg = '';
    files = dir(fullfile(outDir, sprintf('%s_chunk*.mat', tag)));
    if isempty(files)
        msg = sprintf(['no chunk files for "%s" in %s\n' ...
            '  -> run the chunked Monte Carlo first: see run_chunked.sh\n' ...
            '     e.g.  ./run_chunked.sh %s'], tag, outDir, tag);
        return
    end
    idx = []; nTot = []; seasons = {}; ex = struct();
    skip = {'script','chunkIdx','nChunk','drawIdx','nDrawTotal','drawSeason', ...
            'drawSeed','seasons','nSeeds','nCfg','nPrice'};
    seasonAll = {};
    for f = 1:numel(files)
        S = load(fullfile(outDir, files(f).name)); c = S.chunk;
        if isempty(nTot); nTot = c.nDrawTotal; seasons = c.seasons; end
        idx = [idx; c.drawIdx(:)];
        seasonAll = [seasonAll; c.drawSeason(:)];
        for v = fieldnames(c)'
            if any(strcmp(v{1}, skip)); continue; end
            if ~isfield(ex, v{1}); ex.(v{1}) = []; end
            ex.(v{1}) = [ex.(v{1}); c.(v{1})(:)];
        end
    end
    [sorted, order] = sort(idx);
    if numel(sorted) ~= nTot || any(sorted ~= (1:nTot)')
        missing = setdiff((1:nTot)', sorted);
        msg = sprintf(['chunk set for "%s" is INCOMPLETE -- refusing to plot.\n' ...
            '  expected %d draws, found %d\n  missing: %s\n' ...
            '  -> a short Monte Carlo understates every interval. Re-run the\n' ...
            '     missing chunks with run_chunked.sh before plotting.'], ...
            tag, nTot, numel(sorted), mat2str(missing(:)'));
        return
    end
    for v = fieldnames(ex)'; ex.(v{1}) = ex.(v{1})(order); end
    d = ex; d.nDraw = nTot; d.seasons = {seasons};
    d.drawSeason = {seasonAll(order)};
    ok = true;
end

% Draw one bar + interval, styled by whether the result is resolved.
function draw_bar(x, st)
    if st.distinguishable && st.signSignificant
        bar(x, st.mean, 0.6, 'FaceColor', [0.00 0.45 0.74]);
    else
        bar(x, st.mean, 0.6, 'FaceColor', [1 1 1], 'EdgeColor', [0.5 0.5 0.5], 'LineWidth', 1.2);
    end
    lo = st.mean - st.ciLo; hi = st.ciHi - st.mean;
    if st.distinguishable && st.signSignificant
        errorbar(x, st.mean, lo, hi, 'k', 'LineStyle','none', 'LineWidth', 1.4);
    else
        errorbar(x, st.mean, lo, hi, 'Color', [0.5 0.5 0.5], 'LineStyle','none', 'LineWidth', 1.0);
    end
end

anyPlotted = false;

%% Panel set 1 -- Month 4e ablations -------------------------------------
[ok4e, d4e, msg] = load_chunks(outDir, 'month4e');
if ~ok4e
    fprintf('\n[month4e figure skipped]\n  %s\n', msg);
else
    try
        claims = {'PWL vs constant', 'Rolling layers', 'Robust reserve'};
        vecs = {d4e.dPWL, d4e.dRolling, d4e.dReserve};
        ss = d4e.seasons{1}; dsn = d4e.drawSeason{1};
        figure('Position',[100 100 1250 520]);
        for c = 1:3
            subplot(1,3,c); hold on;
            st = paired_stats(vecs{c}, true);
            draw_bar(1, st);
            for q = 1:numel(ss)
                sel = strcmp(dsn, ss{q});
                draw_bar(1+q, paired_stats(vecs{c}(sel), true));
            end
            plot([0.4 4.6], [0 0], 'k-', 'LineWidth', 1);
            hold off; grid on;
            set(gca, 'XTick', 1:4, 'XTickLabel', [{'pooled'} ss(:)']);
            xlabel('Draw set'); ylabel('Benefit (% of baseline)');
            title(sprintf('%s\npooled %+.2f%%, %d/%d, p=%.2g', claims{c}, ...
                  st.mean, st.nAgree, st.nNonZero, st.signP));
        end
        fprintf(['\nPanel set 1 (Month 4e). SOLID bars resolve on BOTH the interval and the\n' ...
            'sign test; HOLLOW bars do not. The pooled PWL and rolling-layer bars are\n' ...
            'hollow because their sign counts are coin flips -- the mean is carried by a\n' ...
            'minority of draws. That distinction is the point of the figure.\n']);
        anyPlotted = true;
    catch e
        fprintf('\n[month4e figure skipped: %s]\n', e.message);
    end
end

%% Panel set 2 -- Month 4i heat-pump gate --------------------------------
[ok4i, d4i, msg] = load_chunks(outDir, 'month4i');
if ~ok4i
    fprintf('\n[month4i figure skipped]\n  %s\n', msg);
else
    try
        ss = d4i.seasons{1}; dsn = d4i.drawSeason{1};
        figure('Position',[130 130 720 520]); hold on;
        st = paired_stats(d4i.dGate, true); draw_bar(1, st);
        for q = 1:numel(ss)
            draw_bar(1+q, paired_stats(d4i.dGate(strcmp(dsn, ss{q})), true));
        end
        plot([0.4 4.6], [0 0], 'k-', 'LineWidth', 1);
        hold off; grid on;
        set(gca, 'XTick', 1:4, 'XTickLabel', [{'pooled'} ss(:)']);
        xlabel('Draw set'); ylabel('Gate benefit (% of baseline)');
        title(sprintf(['Heat-pump PWL gate: %d-segment PWL vs 1-segment chord\n' ...
              'pooled %+.3f%% [%+.3f, %+.3f] -- GATE DOES NOT PASS'], ...
              10, st.mean, st.ciLo, st.ciHi));
        anyPlotted = true;
    catch e
        fprintf('\n[month4i figure skipped: %s]\n', e.message);
    end
end

%% Panel set 3 -- Month 4j, same device, two price regimes ---------------
[ok4j, d4j, msg] = load_chunks(outDir, 'month4j');
if ~ok4j
    fprintf('\n[month4j figure skipped]\n  %s\n', msg);
else
    try
        % Benefit of config c against config 1 (all-constant), per price case.
        lbl = {'FC PWL only', 'HP PWL only', 'All PWL'};
        figure('Position',[160 160 900 520]); hold on;
        xt = []; xl = {};
        for ip = 1:2
            for c = 2:4
                base = d4j.(sprintf('cost_p%d_c1', ip));
                this = d4j.(sprintf('cost_p%d_c%d', ip, c));
                st = paired_stats(100*(base - this)./this, true);
                x = (ip-1)*3.5 + (c-1);
                draw_bar(x, st);
                xt(end+1) = x; xl{end+1} = lbl{c-1};
            end
        end
        plot([0 8], [0 0], 'k-', 'LineWidth', 1);
        text(2, -0.9, 'H2 today', 'HorizontalAlignment','center', 'FontWeight','bold');
        text(5.5, -0.9, 'H2 DOE target', 'HorizontalAlignment','center', 'FontWeight','bold');
        hold off; grid on;
        set(gca, 'XTick', xt, 'XTickLabel', xl); xlim([0 8]);
        xlabel('Configuration, by hydrogen price regime');
        ylabel('Benefit vs all-constant (% of baseline)');
        title(['Same device, same curve, same binaries -- resolved NEGATIVE at today''s price' char(10) ...
               'and resolved POSITIVE at the DOE target. Price regime, not the model, decides.']);
        fprintf(['\nPanel set 3 (Month 4j) is the most important statistical figure here: the\n' ...
            'fuel cell''s PWL benefit changes SIGN with the hydrogen price alone, resolved\n' ...
            'in both directions. "We applied PWL" is therefore not a statement about\n' ...
            'anything on its own.\n']);
        anyPlotted = true;
    catch e
        fprintf('\n[month4j figure skipped: %s]\n', e.message);
    end
end

if ~anyPlotted
    fprintf(['\nNo figures produced. mc_chunks/ is empty or incomplete.\n' ...
        'This script only READS chunk files -- it never runs a simulation and never\n' ...
        'writes a chunk, so it cannot repair a missing set. Populate it first:\n' ...
        '    cd %s && ./run_chunked.sh month4e\n' ...
        '    ./run_chunked.sh month4i\n    ./run_chunked.sh month4j\n'], here);
end
