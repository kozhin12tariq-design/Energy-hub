%MAIN_MONTH4D_LINDISTFLOW_COOPTIMIZATION
%Task 5: let the IEEE 33 network CONSTRAIN the dispatch, not merely check it.
%
%   Tasks 2-4 verify a completed dispatch against the exact power flow.
%   Verification cannot change a schedule -- it can only report that the
%   schedule was network-unfriendly after the fact, which is exactly what
%   Month 3 found (at peak import the hub drives its host bus BELOW the
%   no-hub base case). This script closes that loop by embedding a
%   linearized DistFlow (LinDistFlow) voltage model directly in the
%   day-ahead MILP, so the optimizer must respect the feeder while it
%   chooses the schedule.
%
%   WHY LINDISTFLOW AND NOT THE EXACT SOLVER: distflow_bfs is an iterative
%   nonlinear fixed-point solve and cannot appear inside a MILP.
%   LinDistFlow drops the quadratic loss term, leaving a linear
%   voltage-drop relation that glpk can handle alongside the PWL
%   fill-order binaries -- the combined problem is still a MILP.
%
%   THE SINGLE-HUB COLLAPSE, stated up front because it is the honest
%   headline of this task: with exactly ONE controllable injection on a
%   RADIAL feeder, every bus voltage is affine and MONOTONE DECREASING in
%   that hub's net import. The full per-bus LinDistFlow constraint set
%   therefore reduces exactly to a single scalar cap on hub import. The
%   machinery below is genuine LinDistFlow and would generalize to several
%   controllable injections or dispatchable reactive power, but on THIS
%   system it buys nothing a well-chosen import cap could not. That is a
%   structural result about the study, not a bug, and it is reported
%   rather than hidden behind the apparatus.
%
%   Run with:  main_month4d_lindistflow_cooptimization

clear; clc;
addpath('../month3_multiscale_optimization');
addpath('../month2_coupling_matrix_pwl_ieee33');

sys = ieee33_system_definition();
p   = multiscale_default_params();
fc  = forecast_profiles(42);
ldf = lindistflow_sensitivity(sys);
h   = sys.hostBus;

fprintf('=====================================================\n');
fprintf(' LinDistFlow co-optimization: the ONE hub inside IEEE 33\n');
fprintf('=====================================================\n');
fprintf('Host bus %d. LinDistFlow validated against the exact backward-forward sweep\n', h);
fprintf('on the base case: max error %.4f pu, and it reads HIGH at %d of %d buses.\n', ...
    ldf.maxErr_vs_exact, ldf.optimisticBuses, sys.nBus);
fprintf(['LinDistFlow is therefore OPTIMISTIC -- dropping the quadratic loss term removes\n' ...
    'part of the voltage drop. Any schedule it certifies must be re-checked against the\n' ...
    'exact solver, which this script does below.\n']);

%% Is the standard 0.95 pu limit even reachable? ------------------------
fprintf('\n--- Can the hub hold 0.95 pu? (asked before assuming, not after) ---\n');
needed = zeros(sys.nBus,1);
for j = 2:sys.nBus
    needed(j) = (0.95 - ldf.C(j)) / ldf.a(j);   % hub import giving exactly 0.95 pu
end
worstBuses = [18 17 33 32];
fprintf('%6s %12s %14s %16s\n', 'bus', 'C_j (pu)', 'a_j (pu/kW)', 'import for 0.95');
for j = worstBuses
    fprintf('%6d %12.4f %14.3e %13.0f kW\n', j, ldf.C(j), ldf.a(j), needed(j));
end
fprintf(['\nThe hub would have to EXPORT %.0f kW to lift bus %d to 0.95 pu, and %.0f kW to\n' ...
    'lift bus 33. Its actual export capability is about 15 kW. A 0.95 pu floor at every\n' ...
    'bus is therefore INFEASIBLE by one to two orders of magnitude -- not marginally, but\n' ...
    'structurally: this is a 2.79%%-penetration hub on a feeder whose far end already sits\n' ...
    'at %.4f pu with no hub present. No dispatch of this hub can repair a feeder-wide\n' ...
    'undervoltage, and imposing 0.95 would simply make the MILP infeasible.\n' ...
    '\nSo the co-optimization below imposes an achievable and more meaningful floor:\n' ...
    'DO NO HARM -- no bus may be driven below the voltage it would have WITHOUT the hub.\n' ...
    'That directly targets the defect Month 3''s verification exposed.\n'], ...
    -needed(18), 18, -needed(33), ldf.Vexact_base(18));

%% Co-optimized day-ahead dispatch --------------------------------------
monBuses = 2:sys.nBus;
pNet = p;
pNet.network.enabled = true;
pNet.network.buses   = monBuses;
pNet.network.C       = ldf.C(monBuses);
pNet.network.a       = ldf.a(monBuses);
pNet.network.Vfloor  = ldf.Vlin_base(monBuses);   % do-no-harm, same (LinDF) model

tic; solBase = dayahead_dispatch(p,    fc); tBase = toc;
tic; solNet  = dayahead_dispatch(pNet, fc); tNet  = toc;

fprintf('\n--- Verify-only vs. co-optimized day-ahead schedule ---\n');
fprintf('%-30s %14s %14s\n', '', 'verify-only', 'co-optimized');
fprintf('%-30s %14.4f %14.4f\n', 'Day-ahead cost ($)',      solBase.cost, solNet.cost);
fprintf('%-30s %14.2f %14.2f\n', 'Peak grid import (kW)',   max(solBase.Pg_imp), max(solNet.Pg_imp));
fprintf('%-30s %14.1f %14.1f\n', 'Total grid import (kWh)', sum(solBase.Pg_imp), sum(solNet.Pg_imp));
fprintf('%-30s %14.5f %14.5f\n', 'MILP solve time (s)',     tBase, tNet);
fprintf('%-30s %14d %14d\n',     'glpk status',             solBase.status, solNet.status);

costPremium = solNet.cost - solBase.cost;
fprintf('\nCost premium of respecting the network: $%.4f/day (%+.2f%%).\n', ...
    costPremium, 100*costPremium/abs(solBase.cost));

%% Exact-power-flow validation of both schedules ------------------------
netBase = solBase.Pg_imp(:) - solBase.Pg_exp(:);
netCo   = solNet.Pg_imp(:)  - solNet.Pg_exp(:);
nvBase = network_verify(sys, netBase, struct('dtHours', 1.0));
nvCo   = network_verify(sys, netCo,   struct('dtHours', 1.0));

% What LinDistFlow PREDICTED for the co-optimized schedule, at the host bus.
VpredCo = ldf.C(h) + ldf.a(h)*netCo(:);   % column, matching Vexact_host below

fprintf('\n--- Exact power-flow check of both schedules (distflow_bfs) ---\n');
fprintf('%-34s %14s %14s\n', '', 'verify-only', 'co-optimized');
fprintf('%-34s %14.4f %14.4f\n', 'Exact min voltage (pu)',   nvBase.minV, nvCo.minV);
fprintf('%-34s %14d %14d\n',     'Worst bus',                nvBase.minV_bus, nvCo.minV_bus);
fprintf('%-34s %14.4f %14.4f\n', 'Exact host-bus min V (pu)',nvBase.hostV_min, nvCo.hostV_min);
fprintf('%-34s %14.1f %14.1f\n', 'Feeder losses (kWh/day)',  nvBase.lossEnergy_kWh, nvCo.lossEnergy_kWh);
fprintf('%-34s %14.4f %14s\n',   'No-hub base min V (pu)',   nvBase.base_minV, '(reference)');

doNoHarmBase = nvBase.minV >= nvBase.base_minV - 1e-9;
doNoHarmCo   = nvCo.minV   >= nvCo.base_minV   - 1e-9;
if doNoHarmBase; sBase = 'YES'; else; sBase = 'NO'; end
if doNoHarmCo;   sCo   = 'YES'; else; sCo   = 'NO'; end
fprintf('\nDo-no-harm satisfied under the EXACT solver?  verify-only: %s   co-optimized: %s\n', ...
    sBase, sCo);

%% LinDistFlow vs exact: is the linearization optimistic here? ----------
Vexact_host = zeros(numel(netCo),1);
for t = 1:numel(netCo)
    bp = sys.busP_base; bp(h) = netCo(t);
    Vt = abs(distflow_bfs(sys.branches, bp, sys.busQ_base, sys.Vbase_kV)) / sys.Vbase_kV;
    Vexact_host(t) = Vt(h);
end
vErr = VpredCo - Vexact_host;
fprintf('\n--- LinDistFlow prediction error on the co-optimized schedule (host bus %d) ---\n', h);
fprintf('mean %+.4f pu, max %+.4f pu, min %+.4f pu; LinDistFlow reads high in %d of %d hours.\n', ...
    mean(vErr), max(vErr), min(vErr), sum(vErr > 0), numel(vErr));
fprintf(['\nLinDistFlow reads about %+.4f pu high at this bus, consistent with the %.4f pu\n' ...
    'base-case error. Normally that optimism is dangerous -- a schedule the linear model\n' ...
    'certifies as legal can be marginally illegal under the exact solver.\n' ...
    '\nHERE IT DOES NOT BITE, and the reason is worth stating precisely rather than\n' ...
    'asserting the generic caveat. The do-no-harm floor is defined at the SAME operating\n' ...
    'point in both models: "hub import <= the nominal load it replaced". At exactly that\n' ...
    'import the host bus carries exactly its original load, so BOTH models return exactly\n' ...
    'their own base-case voltage, and the linearization error cancels at the binding\n' ...
    'point. The exact solver confirms it: the co-optimized schedule reaches %.4f pu\n' ...
    'against a %.4f pu no-hub reference -- do-no-harm holds exactly, not approximately.\n' ...
    '\nThat cancellation is a property of THIS floor, not a general guarantee. A floor set\n' ...
    'anywhere other than the linearization''s reference point (say a hard 0.92 pu) would\n' ...
    'expose the full %.4f pu optimism, and would need the floor tightened by roughly that\n' ...
    'margin before it could be trusted.\n'], ...
    mean(vErr), ldf.maxErr_vs_exact, nvCo.minV, nvCo.base_minV, ldf.maxErr_vs_exact);

%% What the network constraint actually did -----------------------------
capImplied = sys.busP_base(h);
fprintf('\n--- What the constraint reduced to, and what it changed ---\n');
fprintf(['With one hub on a radial feeder, every a_j < 0, so "no bus below its no-hub\n' ...
    'voltage" is equivalent to "hub import <= the %0.0f kW nominal load it replaced".\n' ...
    'All %d per-bus rows collapse to that single cap -- confirmed by the schedules:\n' ...
    'verify-only peaks at %.2f kW (above the cap, hence the voltage dip Month 3 found),\n' ...
    'co-optimized peaks at %.2f kW (exactly at it).\n'], ...
    capImplied, numel(monBuses), max(solBase.Pg_imp), max(solNet.Pg_imp));

hrsBinding = sum(netCo > capImplied - 1e-6);
fprintf(['The cap binds in %d of 24 hours. The optimizer responds by shifting import out of\n' ...
    'those hours -- total import changes from %.1f to %.1f kWh -- and pays $%.4f/day for it.\n'], ...
    hrsBinding, sum(solBase.Pg_imp), sum(solNet.Pg_imp), costPremium);

fprintf(['\nHONEST SCOPE OF THIS RESULT. The LinDistFlow apparatus is genuine and general,\n' ...
    'but on this system it is heavier than the problem requires: one injection, radial\n' ...
    'topology and no dispatchable reactive power together make the network constraint\n' ...
    'collapse to a scalar. It would earn its keep with several controllable hubs (whose\n' ...
    'injections interact through shared trunk impedance), with dispatchable Q, or with\n' ...
    'meshed topology -- none of which this single-hub study has. Reporting that plainly\n' ...
    'is more useful than presenting a 32-row constraint set as though it were doing work\n' ...
    'a one-line bound could not.\n']);
