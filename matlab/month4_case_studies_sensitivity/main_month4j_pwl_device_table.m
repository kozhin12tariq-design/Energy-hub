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
%   heat pump, at a covering COP FLOORED AT ITS RATED VALUE -- not at its
%   current marginal COP, which was a second defect and a larger one. See
%   true_curve_cost.m: covering a shortfall means running the pump MORE,
%   which moves it up its part-load curve, so the cycling-dominated COP it
%   happens to sit at is not the efficiency that applies to the extra heat.
%   Dividing by that turned a 5 W modelling error at u = 0.001 into 2.6 kW
%   of imaginary import, and 70% of the whole summer correction came from
%   intervals where the heat pump was doing essentially nothing.
%
%   Run with:  main_month4j_pwl_device_table

% NOTE: -x preserves the chunk selectors. A bare `clear` wipes them, so every
% chunk would run the FULL draw set -- looking like success while doing the
% opposite of chunking. main_month4e hit exactly this defect.
clear -x MC_CHUNK MC_NCHUNK; clc;
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

% ---- CHUNKED EXECUTION ------------------------------------------------
% THE HEAVIEST OF THE THREE MONTE CARLO SCRIPTS. glpk leaks ~46.5 MB per
% full-day simulation at nSegments=10 and Octave never releases it (`clear`
% does not help -- it is held at the C level). This script runs
%   2 price cases x 60 draws x 4 configs = 480 day-sims ~ 21.8 GB,
% about 60% more than main_month4e. Chunking is EXACT: draws are
% independent and forecast_profiles is seeded per draw.
%
% BUDGET RULE: ~46.5 MB x draws/chunk x sims/draw. Here sims/draw = 8
% (2 prices x 4 configs), so 3 draws/chunk = 24 sims ~ 1.1 GB -> 20 chunks.
%
% PARTITION OVER DRAWS ONLY -- never over price cases or configurations.
% Every chunk computes ALL price cases and ALL configs for its slice, because
% the marginal-contribution tables compare configs WITHIN the same draw.
% Splitting across configs would destroy that pairing while still producing
% plausible-looking output, which is the worst kind of wrong.
if exist('MC_CHUNK', 'var') && exist('MC_NCHUNK', 'var')
    chunkMode = true; cIdx = MC_CHUNK; nChunk = MC_NCHUNK;
else
    chunkMode = false; cIdx = 0; nChunk = 1;
end
allSeason = cell(nDraw,1); allSeed = zeros(nDraw,1);
q = 0;
for sIdx0 = 1:numel(seasons)
    for sd0 = 1:nSeeds
        q = q + 1; allSeason{q} = seasons{sIdx0}; allSeed(q) = sd0;
    end
end
lo = floor(cIdx*nDraw/nChunk) + 1; hi = floor((cIdx+1)*nDraw/nChunk);
myDraws = lo:hi;
if chunkMode
    fprintf('CHUNK %d of %d: draws %d..%d (%d of %d), all %d price cases x configs\n', ...
            cIdx, nChunk, lo, hi, numel(myDraws), nDraw, numel(priceCases));
    fflush(stdout);
end

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
% Throughput is accumulated for BOTH devices on the SAME 60-draw basis. An
% earlier version compared a single-day heat-pump figure against a 60-draw
% fuel-cell mean, which is not a comparison.
fcThruP = zeros(1, numel(priceCases));
hpThruP = zeros(1, numel(priceCases));
% Per-draw throughput, so chunks can be averaged correctly by the aggregator
% instead of each carrying a partial running mean.
fcThruD = zeros(nDraw, numel(priceCases));
hpThruD = zeros(nDraw, numel(priceCases));

t0 = tic;
for ip = 1:numel(priceCases)
    cost = zeros(nDraw, nCfg); co2 = zeros(nDraw, nCfg); tsolve = zeros(nDraw, nCfg);
    for i = myDraws
            sd = allSeed(i);
            drawSeason{i} = allSeason{i};
            fcD = forecast_profiles(sd, 1.0, [], allSeason{i});
            for c = 1:nCfg
                pc = cfg(c).params; pc.price_H2 = priceCases(ip).price;
                o = struct('useIntraday', true, 'reserveScale', 1.0, 'usePWL', cfg(c).fcPWL);
                tt = tic;
                R  = simulate_multiscale_day(pc, fcD, o);
                tsolve(i,c) = toc(tt);
                cost(i,c)   = true_curve_cost(pc, fcD, R, cfg(c).fcPWL);
                co2(i,c)    = R.emissions_kgCO2;
                if c == nCfg
                    fcThruD(i,ip) = sum(R.PH2_5)/12;
                    hpThruD(i,ip) = sum(R.Php5)/12;
                end
            end
        fprintf('  price %d, draw %d done (%.0f s elapsed)\n', ip, i, toc(t0));
        fflush(stdout);
    end
    costP{ip} = cost; co2P{ip} = co2; tsolveP{ip} = tsolve;
end
fcThruP = sum(fcThruD, 1) / nDraw;   % completed only in single-process mode
hpThruP = sum(hpThruD, 1) / nDraw;

if chunkMode
    % Full cost/co2/tsolve ROWS for this chunk's draws, per price case --
    % not differences. The per-device and marginal tables need per-config
    % values. Stored as one flat vector per (price, config, quantity) so the
    % aggregator's generic per-draw collection reassembles them without
    % needing to know this script's shape.
    outDir = fullfile(fileparts(mfilename('fullpath')), 'mc_chunks');
    if ~exist(outDir, 'dir'); mkdir(outDir); end
    chunk = struct('script','month4j','chunkIdx',cIdx,'nChunk',nChunk, ...
                   'drawIdx',myDraws(:),'nDrawTotal',nDraw, ...
                   'drawSeason',{allSeason(myDraws)},'drawSeed',allSeed(myDraws), ...
                   'seasons',{seasons},'nSeeds',nSeeds,'nCfg',nCfg, ...
                   'nPrice',numel(priceCases));
    for ip = 1:numel(priceCases)
        for c = 1:nCfg
            chunk.(sprintf('cost_p%d_c%d',   ip, c)) = costP{ip}(myDraws, c);
            chunk.(sprintf('co2_p%d_c%d',    ip, c)) = co2P{ip}(myDraws, c);
            chunk.(sprintf('tsolve_p%d_c%d', ip, c)) = tsolveP{ip}(myDraws, c);
        end
        chunk.(sprintf('fcThru_p%d', ip)) = fcThruD(myDraws, ip);
        chunk.(sprintf('hpThru_p%d', ip)) = hpThruD(myDraws, ip);
    end
    save('-mat7-binary', fullfile(outDir, sprintf('month4j_chunk%03d.mat', cIdx)), 'chunk');
    fprintf('Chunk %d saved (%d draws x %d prices x %d configs). Statistics deferred.\n', ...
            cIdx, numel(myDraws), numel(priceCases), nCfg);
    return
end

S = struct('p',p,'nDraw',nDraw,'nCfg',nCfg,'cfg',cfg,'priceCases',priceCases, ...
           'seasons',{seasons},'drawSeason',{drawSeason},'costP',{costP}, ...
           'co2P',{co2P},'tsolveP',{tsolveP},'fcThruP',fcThruP,'hpThruP',hpThruP, ...
           'pHPon',pHPon,'pHPoff',pHPoff);
mc_report_month4j(S);
