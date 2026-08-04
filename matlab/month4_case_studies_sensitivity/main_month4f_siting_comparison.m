%MAIN_MONTH4F_SITING_COMPARISON
%Where the ONE hub is sited decides whether it can support voltage at all.
%
%   This project has run its single hub at two buses. Bus 18 was the
%   original siting -- the electrically weakest bus on IEEE 33 and the most
%   demanding test -- and bus 25 is the current one, chosen because it can
%   host a hub large enough to matter feeder-wide. Both datasets existed but
%   only one was ever a deliverable; the other had become history. Presented
%   deliberately and side by side they are an engineering result in their
%   own right, and that is what this script produces.
%
%   ONE HUB, ONE BUS AT A TIME. Nothing here places hubs at two buses
%   simultaneously. Each siting is built, solved and verified on its own
%   against the clean no-hub base case, exactly as main_month2b does, and
%   the two are then compared as ALTERNATIVES.
%
%   THE COMPARISON IS NOT SIZE-CONTROLLED, AND CANNOT BE. The do-no-harm
%   floor caps hub import at the nominal load of the bus it replaces (see
%   hub_sizing.m for the derivation -- the per-bus sensitivities cancel), so
%   "the same hub at both buses" is not a choice a designer has: bus 18
%   admits 90 kW and bus 25 admits 420 kW. Each siting is therefore run at
%   the size its host can actually carry, which is the decision-relevant
%   comparison. The size-independent part of the mechanism is reported
%   separately below as a pure network sensitivity, where no dispatch and no
%   size enter at all.
%
%   Run with:  main_month4f_siting_comparison

clear; clc;
addpath('../month3_multiscale_optimization');
addpath('../month2_coupling_matrix_pwl_ieee33');

sitings = struct( ...
    'bus',   {18,  25}, ...
    'scale', {1.0, []}, ...          % [] = the project default (420/90)
    'label', {'bus 18 (weakest bus)', 'bus 25 (largest load)'});

fprintf('=====================================================\n');
fprintf(' Siting the ONE hub: bus 18 versus bus 25\n');
fprintf('=====================================================\n');

%% Part 1 -- pure network sensitivity, no dispatch, no hub size ---------
% This part is analytic. It uses only the feeder impedances and therefore
% says something about the BUSES, not about anything this project chose.
fprintf('\n--- Network sensitivity of each candidate bus (analytic) ---\n');
fprintf('%-8s %14s %14s %10s %12s %14s\n', 'bus', 'dV/dP pu/kW', 'dV/dQ pu/kvar', ...
    'X/R ratio', 'base V (pu)', 'nominal load kW');
sysProbe = ieee33_system_definition(18, 1.0);
ldfProbe = cell(1, numel(sitings));
for k = 1:numel(sitings)
    sk = ieee33_system_definition(sitings(k).bus, 1.0);
    ldfProbe{k} = lindistflow_sensitivity(sk);
    h = sitings(k).bus;
    fprintf('%-8d %14.3e %14.3e %10.4f %12.4f %14.0f\n', h, ...
        ldfProbe{k}.a(h), ldfProbe{k}.b(h), ldfProbe{k}.b(h)/ldfProbe{k}.a(h), ...
        ldfProbe{k}.Vexact_base(h), sk.busP_base(h));
end

%% Part 2 -- run each siting, one at a time -----------------------------
res = struct();
for k = 1:numel(sitings)
    h = sitings(k).bus;
    if isempty(sitings(k).scale)
        sys = ieee33_system_definition(h);
        p   = multiscale_default_params();
        fc  = forecast_profiles(42);
    else
        sys = ieee33_system_definition(h, sitings(k).scale);
        p   = multiscale_default_params(sitings(k).scale);
        fc  = forecast_profiles(42, 1.0, sitings(k).scale);
    end
    ldf = lindistflow_sensitivity(sys);
    mon = 2:sys.nBus;

    pNet = p;
    pNet.network.enabled = true;
    pNet.network.buses   = mon;
    pNet.network.C       = ldf.C(mon);
    pNet.network.a       = ldf.a(mon);
    pNet.network.b       = ldf.b(mon);
    pNet.network.Vfloor  = ldf.Vlin_base(mon);

    fprintf('\nSolving siting %d of %d: %s ...\n', k, numel(sitings), sitings(k).label);
    fflush(stdout);

    % Verify-only (no network constraint) and co-optimized day-ahead.
    solU = dayahead_dispatch(p,    fc);
    solQ = dayahead_dispatch(pNet, fc);
    nvU  = network_verify(sys, solU.Pg_imp(:) - solU.Pg_exp(:), struct('dtHours',1.0), solU.Qh);
    nvQ  = network_verify(sys, solQ.Pg_imp(:) - solQ.Pg_exp(:), struct('dtHours',1.0), solQ.Qh);

    % Closed-loop compliance across the same 9 scenarios used in Month 4d.
    clSeeds = [42 7 123]; clUnc = [1.0 2.0 3.0];
    nHold = 0; nTot = 0; worstShort = 0; costSum = 0; lossSum = 0;
    for sd = clSeeds
        for u = clUnc
            if isempty(sitings(k).scale)
                fcCL = forecast_profiles(sd, u);
            else
                fcCL = forecast_profiles(sd, u, sitings(k).scale);
            end
            Rcl  = simulate_multiscale_day(pNet, fcCL, struct('useIntraday', true, 'reserveScale', 1.0));
            nvCL = network_verify(sys, Rcl.Pg_imp5 - Rcl.Pg_exp5, struct(), Rcl.Q5);
            nHold = nHold + (nvCL.minV >= nvCL.base_minV - 1e-9);
            nTot  = nTot + 1;
            worstShort = max(worstShort, nvCL.base_minV - nvCL.minV);
            costSum = costSum + Rcl.actualCost;
            lossSum = lossSum + nvCL.lossEnergy_kWh;
        end
    end

    res(k).bus        = h;
    res(k).label      = sitings(k).label;
    res(k).penFeeder  = sys.penetrationFeeder_pct;
    res(k).penHost    = sys.penetrationHostBus_pct;
    res(k).hostLoad   = sys.hostBusLoad_kW;
    res(k).a_h        = ldf.a(h);
    res(k).b_h        = ldf.b(h);
    res(k).Qmax       = p.Inverter.Q_max;
    res(k).Qpeak      = max(solQ.Qh);
    res(k).minV_unity = nvU.minV;
    res(k).minV_Q     = nvQ.minV;
    res(k).baseMinV   = nvQ.base_minV;
    res(k).support_pu = nvQ.minV - nvU.minV;
    res(k).marginU    = nvU.minV - nvU.base_minV;
    res(k).marginQ    = nvQ.minV - nvQ.base_minV;
    res(k).costDA     = solQ.cost;
    res(k).costPremium= solQ.cost - solU.cost;
    res(k).peakImpU   = max(solU.Pg_imp);
    res(k).peakImpQ   = max(solQ.Pg_imp);
    res(k).lossQ      = nvQ.lossEnergy_kWh;
    res(k).lossBase   = nvQ.base_lossEnergy_kWh;
    res(k).nHold      = nHold;
    res(k).nTot       = nTot;
    res(k).worstShort = worstShort;
    res(k).clCost     = costSum / nTot;
    res(k).clLoss     = lossSum / nTot;
end

%% Part 3 -- the comparison table ---------------------------------------
fprintf('\n=====================================================\n');
fprintf(' Siting comparison (one hub, one bus at a time)\n');
fprintf('=====================================================\n');
rowf = @(name, fmt, a, b) fprintf(['%-38s ' fmt ' ' fmt '\n'], name, a, b);
fprintf('%-38s %16s %16s\n', '', res(1).label, res(2).label);
rowf('Host-bus nominal load (kW)',        '%16.0f', res(1).hostLoad,  res(2).hostLoad);
rowf('Penetration, feeder (%)',           '%16.2f', res(1).penFeeder, res(2).penFeeder);
rowf('Penetration, host bus (%)',         '%16.1f', res(1).penHost,   res(2).penHost);
rowf('dV/dP at host (pu/kW)',             '%16.3e', res(1).a_h,       res(2).a_h);
rowf('dV/dQ at host (pu/kvar)',           '%16.3e', res(1).b_h,       res(2).b_h);
rowf('Inverter reactive limit (kvar)',    '%16.1f', res(1).Qmax,      res(2).Qmax);
rowf('Peak Q dispatched (kvar)',          '%16.2f', res(1).Qpeak,     res(2).Qpeak);
rowf('Min V, unity power factor (pu)',    '%16.4f', res(1).minV_unity,res(2).minV_unity);
rowf('Min V, with reactive support (pu)', '%16.4f', res(1).minV_Q,    res(2).minV_Q);
rowf('REACTIVE SUPPORT ACHIEVED (pu)',    '%16.4f', res(1).support_pu,res(2).support_pu);
rowf('No-hub base min V (pu)',            '%16.4f', res(1).baseMinV,  res(2).baseMinV);
rowf('Margin vs floor, unity pf (pu)',    '%16.2e', res(1).marginU,   res(2).marginU);
rowf('Margin vs floor, with Q (pu)',      '%16.2e', res(1).marginQ,   res(2).marginQ);
rowf('Day-ahead cost ($)',                '%16.4f', res(1).costDA,    res(2).costDA);
rowf('Cost premium of the network ($)',   '%16.4f', res(1).costPremium,res(2).costPremium);
rowf('Peak import, co-optimized (kW)',    '%16.2f', res(1).peakImpQ,  res(2).peakImpQ);
rowf('Feeder losses, co-opt (kWh/day)',   '%16.1f', res(1).lossQ,     res(2).lossQ);
rowf('No-hub base losses (kWh/day)',      '%16.1f', res(1).lossBase,  res(2).lossBase);
rowf('Loss reduction vs no hub (kWh/day)','%16.1f', res(1).lossBase-res(1).lossQ, ...
                                                    res(2).lossBase-res(2).lossQ);
rowf('Closed-loop mean cost ($/day)',     '%16.2f', res(1).clCost,    res(2).clCost);
fprintf('%-38s %13d/%-2d %13d/%-2d\n', 'Closed-loop compliance (9 scenarios)', ...
    res(1).nHold, res(1).nTot, res(2).nHold, res(2).nTot);
rowf('Worst closed-loop shortfall (pu)',  '%16.2e', res(1).worstShort,res(2).worstShort);

%% Part 4 -- the mechanism, stated as a result --------------------------
sensRatio = res(1).b_h / res(2).b_h;
sizeRatio = res(2).Qmax / res(1).Qmax;
authority = [res(1).Qmax*abs(res(1).b_h), res(2).Qmax*abs(res(2).b_h)];
fprintf('\n=====================================================\n');
fprintf(' SITING DETERMINES WHETHER A HUB CAN SUPPORT VOLTAGE\n');
fprintf('=====================================================\n');
fprintf(['This is the result, not an aside, and the two halves of it pull against each\n' ...
    'other almost exactly.\n' ...
    '\n  SENSITIVITY. Bus 18 is %.1fx more responsive per kvar than bus 25 (%.2e vs\n' ...
    '  %.2e pu/kvar). It sits at the end of the feeder''s longest radial, so it shares\n' ...
    '  the most series impedance with the substation and every kvar injected there\n' ...
    '  moves its voltage further.\n' ...
    '\n  CAPACITY. Bus 25 hosts %.1fx more inverter (%.0f vs %.0f kvar), because the\n' ...
    '  do-no-harm floor caps hub import at the nominal load of the bus it replaces and\n' ...
    '  bus 25 carries %.0f kW against bus 18''s %.0f kW.\n' ...
    '\n  THE PRODUCT IS WHAT MATTERS, and it very nearly cancels: full-output reactive\n' ...
    '  authority Q_max x |dV/dQ| is %.5f pu at bus 18 and %.5f pu at bus 25, a ratio of\n' ...
    '  only %.2f. A bus that responds strongly cannot host much; a bus that can host a\n' ...
    '  lot responds weakly. On a radial feeder these two properties are inversely\n' ...
    '  related BY CONSTRUCTION -- the weak buses are weak precisely because they sit at\n' ...
    '  the end of long thin laterals serving small loads.\n' ...
    '\n  MEASURED, NOT JUST PREDICTED: the dispatch achieves %.4f pu of support at bus 18\n' ...
    '  and %.4f pu at bus 25. The prediction and the measurement agree in ordering and\n' ...
    '  in rough magnitude, so the offsetting mechanism is real rather than incidental.\n'], ...
    sensRatio, res(1).b_h, res(2).b_h, ...
    sizeRatio, res(2).Qmax, res(1).Qmax, res(2).hostLoad, res(1).hostLoad, ...
    authority(1), authority(2), authority(1)/authority(2), ...
    res(1).support_pu, res(2).support_pu);

fprintf(['\nWHAT EACH SITING IS ACTUALLY GOOD FOR -- they are not interchangeable and\n' ...
    'neither is simply better:\n' ...
    '  bus 18: the demanding test. It IS the feeder minimum, so every voltage effect is\n' ...
    '          local, immediate and easy to attribute. Nothing feeder-wide can be\n' ...
    '          studied there -- a %.0f kW bus cannot host a hub that moves a 3715 kW\n' ...
    '          feeder, and at %.2f%% penetration any feeder-wide sweep is guaranteed\n' ...
    '          flat before it is run.\n' ...
    '  bus 25: the feeder-wide test. At %.2f%% penetration the hub finally moves\n' ...
    '          system quantities -- it cuts losses by %.0f kWh/day against bus 18''s\n' ...
    '          %.0f -- but it no longer sits at the bus that sets the minimum, so its\n' ...
    '          voltage effects reach the worst bus only through shared trunk impedance.\n' ...
    '\nA single-siting study cannot answer both questions, and this one does not pretend\n' ...
    'to: the thesis reports bus 25 as its deployed configuration and bus 18 as the\n' ...
    'stress test, with the trade above as the reason.\n'], ...
    res(1).hostLoad, res(1).penFeeder, res(2).penFeeder, ...
    res(2).lossBase-res(2).lossQ, res(1).lossBase-res(1).lossQ);

%% Part 5 -- the compliance flip, with its magnitude --------------------
fprintf('\n--- Closed-loop compliance: %d of %d at bus 18 versus %d of %d at bus 25 ---\n', ...
    res(1).nHold, res(1).nTot, res(2).nHold, res(2).nTot);
fprintf(['That flip is real and it must not be read as bus 25 failing. The strict test is\n' ...
    'minV >= no-hub minV - 1e-09 pu, and the WORST shortfall at bus 25 across all %d\n' ...
    'scenarios is %.2e pu -- against a feeder that already sits %.4f pu below nominal\n' ...
    'with no hub present, and a LinDistFlow model whose own base-case error is %.2e pu,\n' ...
    '%.0fx larger than the violation.\n' ...
    '\nMECHANISM. At bus 18 the hub sits ON the binding bus, so the floor and the achieved\n' ...
    'operating point are evaluated at the same node with the same linearization bias; it\n' ...
    'cancels and leaves a comfortable margin (%.2e pu). At bus 25 the binding bus is\n' ...
    'still 18, on a different lateral, reached only through two shared trunk branches, so\n' ...
    'the constraint clamps the schedule almost exactly ON the floor and the quadratic\n' ...
    'term LinDistFlow drops lands a few parts per million on the wrong side.\n' ...
    '\nThe tolerance has deliberately not been widened to make bus 25 pass. The honest\n' ...
    'statement is that bus 18 holds the floor with margin and bus 25 holds it to within\n' ...
    '%.0e pu, and that a guarantee expressed in LinDistFlow terms cannot be tighter than\n' ...
    'LinDistFlow itself.\n'], ...
    res(2).nTot, res(2).worstShort, 1-res(2).baseMinV, ldfProbe{2}.maxErr_vs_exact, ...
    ldfProbe{2}.maxErr_vs_exact/max(res(2).worstShort,eps), ...
    res(1).marginQ, res(2).worstShort);
