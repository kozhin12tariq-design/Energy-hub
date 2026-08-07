function mc_aggregate(scriptName)
%MC_AGGREGATE Combine chunked Monte Carlo results and run the full statistics.
%
%   mc_aggregate('month4e')
%
%   WHY CHUNKING IS NEEDED AT ALL, stated because it is a toolchain
%   constraint and not a modelling one. glpk leaks memory on every integer
%   solve and Octave's interface does not release it. Measured on this
%   repository at nSegments = 10:
%
%     dayahead_dispatch      x 60   52 MB, FLAT -- no leak
%     intraday_dispatch      x 200  65 -> 112 MB, ~0.31 MB/call, linear
%     simulate_multiscale_day x 5   99 -> 285 MB, ~46.5 MB/day-sim, linear
%
%   `clear` does not help -- verified, the growth is identical with `clear`
%   between every call, because the memory is held at the C level outside
%   Octave's variable space. ONLY PROCESS EXIT RELEASES IT. main_month4e
%   runs 60 draws x 5 configurations = 300 day-sims ~ 14 GB, which does not
%   fit; the failure is driven by the NUMBER OF DAY-SIMS, not by problem
%   difficulty, which is why main_month4a (12 day-sims, ~0.6 GB) is fine.
%
%   CHUNKING IS EXACT, NOT AN APPROXIMATION. The draws are independent and
%   forecast_profiles(seed, ...) is seeded per draw, so draw i is
%   bit-identical regardless of which process computes it. Partitioning is
%   done over the DRAW INDEX, so the union of chunks is exactly the original
%   ordered draw set. Chunk files carry RAW per-draw differences only --
%   never partial statistics, because means and confidence intervals do not
%   combine -- and paired_stats runs once here, on all draws at once.
%
%   COMPLETENESS IS ENFORCED, LOUDLY. A silently short Monte Carlo would
%   understate every confidence interval in the thesis, which is far worse
%   than no result, so a missing or duplicated draw is an error and not a
%   warning.
%
%   Chunk size: at ~46.5 MB per day-sim, 5 draws (25 day-sims) peaks near
%   1.2 GB. Scale for your own machine with that rule.

    if nargin < 1 || isempty(scriptName); scriptName = 'month4e'; end
    here = fileparts(mfilename('fullpath'));
    addpath(here);
    outDir = fullfile(here, 'mc_chunks');

    files = dir(fullfile(outDir, sprintf('%s_chunk*.mat', scriptName)));
    if isempty(files)
        error('mc_aggregate:noChunks', ...
              'No chunk files found in %s for "%s". Run the chunked job first.', ...
              outDir, scriptName);
    end

    idxAll = []; pwl = []; roll = []; res = []; seasonAll = {}; seedAll = [];
    % Scripts other than month4e carry a different set of per-draw vectors.
    % They are collected generically so adding a script needs no new plumbing
    % here beyond a registry entry below.
    extra = struct();
    skip = {'script','chunkIdx','nChunk','drawIdx','nDrawTotal','drawSeason', ...
            'drawSeed','seasons','nSeeds','dPWL','dRolling','dReserve'};
    nDrawTotal = []; seasons = {}; nSeeds = [];
    for f = 1:numel(files)
        S = load(fullfile(outDir, files(f).name));
        c = S.chunk;
        if isempty(nDrawTotal)
            nDrawTotal = c.nDrawTotal; seasons = c.seasons; nSeeds = c.nSeeds;
        elseif nDrawTotal ~= c.nDrawTotal
            error('mc_aggregate:inconsistent', ...
                  'Chunk %s expects %d total draws, earlier chunks expect %d.', ...
                  files(f).name, c.nDrawTotal, nDrawTotal);
        end
        idxAll    = [idxAll;    c.drawIdx(:)];
        % month4e's three named vectors; other scripts carry their own set,
        % picked up generically below.
        if isfield(c, 'dPWL');     pwl  = [pwl;  c.dPWL(:)];     end
        if isfield(c, 'dRolling'); roll = [roll; c.dRolling(:)]; end
        if isfield(c, 'dReserve'); res  = [res;  c.dReserve(:)]; end
        seasonAll = [seasonAll; c.drawSeason(:)];
        seedAll   = [seedAll;   c.drawSeed(:)];
        for v = fieldnames(c)'
            if any(strcmp(v{1}, skip)); continue; end
            if ~isfield(extra, v{1}); extra.(v{1}) = []; end
            extra.(v{1}) = [extra.(v{1}); c.(v{1})(:)];
        end
    end

    % ---- completeness: every draw exactly once, no gaps, no duplicates ----
    [sorted, order] = sort(idxAll);
    expected = (1:nDrawTotal)';
    if numel(sorted) ~= nDrawTotal || any(sorted ~= expected)
        missing = setdiff(expected, sorted);
        dup     = sorted(find(diff(sorted) == 0));
        error('mc_aggregate:incomplete', ...
             ['Chunk set is NOT complete -- refusing to report statistics.\n' ...
              '  expected %d draws, found %d unique-or-not\n' ...
              '  missing draw indices: %s\n' ...
              '  duplicated draw indices: %s\n' ...
              'A short Monte Carlo understates every confidence interval, so this\n' ...
              'is an error rather than a warning. Re-run the missing chunks.'], ...
              nDrawTotal, numel(sorted), mat2str(missing(:)'), mat2str(unique(dup(:))'));
    end

    % ---- reassemble in draw-index order ----------------------------------
    if ~isempty(pwl);  dPWL     = pwl(order)';  else; dPWL = [];     end
    if ~isempty(roll); dRolling = roll(order)'; else; dRolling = []; end
    if ~isempty(res);  dReserve = res(order)';  else; dReserve = []; end
    drawSeason = seasonAll(order);

    fprintf(['Aggregated %d chunk files -> %d draws, complete and in order.\n' ...
             'Chunking is exact: draws are independent and seeded per draw index.\n'], ...
             numel(files), nDrawTotal);

    switch scriptName
        case 'month4e'
            mc_report_month4e(dPWL, dRolling, dReserve, drawSeason, seasons, nSeeds);
        case 'month4i'
            % p and hpRef are deterministic properties of the model, not of
            % any draw, so they are rebuilt here exactly as the script builds
            % them rather than shipped in every chunk file.
            addpath(fullfile(here, '..', 'month3_multiscale_optimization'));
            p = multiscale_default_params(); p.HeatPump.usePWL = true;
            % The four parameter variants and optFull are deterministic
            % configurations, rebuilt here exactly as the script builds them.
            pPWL = p; pChord = p; pChord.HeatPump.nSegments = 1;
            pLegacy = p; pLegacy.HeatPump.usePWL = false;
            pCurv = p; pCurv.HeatPump.placement = 'curvature';
            S = struct('p', p, 'nDraw', nDrawTotal, 'seasons', {seasons}, ...
                       'drawSeason', {drawSeason}, 'hpRef', heatpump_curve(p, 9.0), ...
                       'pPWL', pPWL, 'pChord', pChord, 'pCurv', pCurv, ...
                       'pLegacy', pLegacy, ...
                       'optFull', struct('useIntraday', true, 'reserveScale', 1.0));
            for v = fieldnames(extra)'
                S.(v{1}) = extra.(v{1})(order)';
            end
            mc_report_month4i(S);
        case 'month4j'
            % Completeness is checked PER PRICE CASE as well as per draw: a
            % chunk that computed only one price case must be rejected, not
            % silently averaged into the other.
            addpath(fullfile(here, '..', 'month3_multiscale_optimization'));
            p = multiscale_default_params();
            priceCases = struct( ...
                'label', {'H2_today (shipped default)', 'H2_doeTargetDelivered (Month 4e basis)'}, ...
                'price', {p.price_H2, p.scenarios.H2_doeTargetDelivered});
            pHPoff = p; pHPoff.HeatPump.usePWL = true; pHPoff.HeatPump.nSegments = 1;
            pHPon  = p; pHPon.HeatPump.usePWL  = true;
            cfg = struct( ...
              'label', {'All constant efficiency', '+ fuel cell PWL only (previous default)', ...
                        '+ heat pump PWL only',    'All PWL (fuel cell + heat pump)'}, ...
              'fcPWL', {false, true, false, true}, ...
              'params', {pHPoff, pHPoff, pHPon, pHPon});
            nCfg = numel(cfg); nPrice = numel(priceCases);
            costP = cell(1,nPrice); co2P = cell(1,nPrice); tsolveP = cell(1,nPrice);
            fcThruP = zeros(1,nPrice); hpThruP = zeros(1,nPrice);
            for ip = 1:nPrice
                costP{ip} = zeros(nDrawTotal,nCfg);
                co2P{ip} = zeros(nDrawTotal,nCfg);
                tsolveP{ip} = zeros(nDrawTotal,nCfg);
                for c = 1:nCfg
                    for nm = {sprintf('cost_p%d_c%d',ip,c), sprintf('co2_p%d_c%d',ip,c), ...
                              sprintf('tsolve_p%d_c%d',ip,c)}
                        if ~isfield(extra, nm{1})
                            error('mc_aggregate:missingPriceCase', ...
                                 ['Chunk set is missing "%s" -- refusing to report.\n' ...
                                  'Every chunk must compute ALL %d price cases and ALL %d\n' ...
                                  'configs for its draws, because the marginal tables compare\n' ...
                                  'configs WITHIN a draw. A partial chunk would silently break\n' ...
                                  'that pairing while still producing plausible output.'], ...
                                  nm{1}, nPrice, nCfg);
                        end
                    end
                    costP{ip}(:,c)   = extra.(sprintf('cost_p%d_c%d',ip,c))(order);
                    co2P{ip}(:,c)    = extra.(sprintf('co2_p%d_c%d',ip,c))(order);
                    tsolveP{ip}(:,c) = extra.(sprintf('tsolve_p%d_c%d',ip,c))(order);
                end
                fcThruP(ip) = sum(extra.(sprintf('fcThru_p%d',ip))) / nDrawTotal;
                hpThruP(ip) = sum(extra.(sprintf('hpThru_p%d',ip))) / nDrawTotal;
            end
            S = struct('p',p,'nDraw',nDrawTotal,'nCfg',nCfg,'cfg',cfg, ...
                       'priceCases',priceCases,'seasons',{seasons}, ...
                       'drawSeason',{drawSeason},'costP',{costP},'co2P',{co2P}, ...
                       'tsolveP',{tsolveP},'fcThruP',fcThruP,'hpThruP',hpThruP, ...
                       'pHPon',pHPon,'pHPoff',pHPoff);
            mc_report_month4j(S);
        otherwise
            error('mc_aggregate:unknownScript', ...
                  'No reporter registered for "%s".', scriptName);
    end
end
