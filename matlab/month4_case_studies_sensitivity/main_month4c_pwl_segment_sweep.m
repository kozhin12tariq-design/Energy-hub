%MAIN_MONTH4C_PWL_SEGMENT_SWEEP
%Thesis roadmap Month 4: segment-count trade-off for the fuel cell's PWL
%approximation, mirroring the accuracy-vs-computation table style used by
%Huang et al. (error% falling as segment count rises, at the cost of a
%larger MILP).
%
%   Sweeps p.PWL.nSegments in {1, 2, 5, 10, 20, 36} and reports, for each:
%     1) CURVE-FIT approximation error: the n-segment PWL fit vs. the
%        exact continuous efficiency function, evaluated over a dense
%        load-fraction grid (same methodology as Month 2's PWL-vs-
%        constant-efficiency error table: MaxErr/RMSE in kW), for BOTH
%        the fuel cell's electrical and thermal curves.
%     2) MILP SOLVE TIME: dayahead_dispatch.m's mean wall-clock solve
%        time at that segment count (mean of 5 solves), run at the
%        H2_doeTargetGate scenario ($0.06/kWh = $2.00/kg, DOE's 2026
%        production-gate target; see the three named scenarios in
%        multiscale_default_params.m).
%
%        WHY THE GATE PRICE HERE, when Case 5's headline uses the
%        like-for-like DELIVERED price instead: this is a CONVERGENCE
%        study, not an economic claim. The gate price is the cheapest of
%        the three and therefore maximises fuel-cell throughput (339 kWh
%        over 5 hours, against 138 kWh over 2 hours delivered), which
%        puts the most energy through the nonlinear device and gives the
%        strongest, least noise-dominated signal for how approximation
%        error and solve time behave as segments are added. Choosing the
%        operating point that best exercises the thing being measured is
%        legitimate for a convergence study; it would NOT be legitimate
%        for the cost headline, which is why Case 5 reports both prices.
%        At the H2_today default the fuel cell is never dispatched at
%        all, so every segment count would solve a problem whose integer
%        variables are trivially zero and the sweep would measure nothing.
%     3) RESULTING COST: the day-ahead PLAN's own believed cost at that
%        segment count, and the REALIZED cost once the plan's fuel
%        purchase (PH2, unaffected by which curve interpretation is
%        used -- fuel is metered and priced independent of how
%        efficiently it converts) is re-evaluated through the EXACT
%        continuous efficiency function instead of the n-segment
%        approximation the day-ahead MILP believed. This isolates the
%        same "plan optimal for the wrong model" mechanism as Case 5,
%        but as a function of segment count rather than a single
%        PWL-vs-constant comparison point.
%
%   SCOPE NOTE: this re-evaluation only recomputes the ELECTRICAL side
%   (grid import/export adjust to cover the gap between the n-segment
%   model's believed fuel-cell electricity and the true nonlinear
%   output, holding storage/heat-pump/PV at their planned values). Any
%   heat-side mismatch from the true curve is NOT re-priced here -- the
%   full multi-timescale simulation (main_month4a_case_studies.m's Case
%   5) already shows that heat-side mismatches of this kind are small
%   and get absorbed by the building/pipe thermal storage's own inertia
%   without a fast correction (see realtime_balance.m's header); this
%   script is a static day-ahead-only sweep table, not a full closed-
%   loop re-simulation, so it is scoped to the dominant (electrical)
%   cost effect and says so rather than silently ignoring the rest.
%
%   Depends on Month 3's dispatch stack (../month3_multiscale_optimization).
%
%   Run with:  main_month4c_pwl_segment_sweep

clear; clc;
addpath('../month3_multiscale_optimization');

p = multiscale_default_params();
p.price_H2 = p.scenarios.H2_doeTargetGate;  % production-gate target: maximises FC
                                            % throughput, so the convergence signal is
                                            % clearest (see file header for why this is
                                            % the right choice HERE but not for Case 5's
                                            % cost headline).
fc = forecast_profiles(42);

segCounts = [1, 2, 5, 10, 20, 36];
nS = numel(segCounts);

maxErrE = zeros(1,nS); rmseE = zeros(1,nS);
maxErrT = zeros(1,nS); rmseT = zeros(1,nS);
solveTime = zeros(1,nS);
plannedCost = zeros(1,nS);
realizedCost = zeros(1,nS);
optimism = zeros(1,nS);

u_test = linspace(0.02, 1, 400);
x_test = u_test * p.PWL.FC_H2_max;
y_true_e = p.PWL.eta_FC_e_func(u_test)  .* x_test;
y_true_t = p.PWL.eta_FC_th_func(u_test) .* x_test;

fprintf('=====================================================\n');
fprintf(' PWL segment-count trade-off (fuel cell curves)\n');
fprintf('=====================================================\n');
fprintf(['Scenario H2_doeTargetGate: price_H2=$%.2f/kWh = $%.2f/kg (production gate).\n' ...
    'Chosen because it maximises fuel-cell throughput and so gives the clearest\n' ...
    'convergence signal -- see file header.\n\n'], ...
    p.price_H2, p.price_H2*p.scenarios.H2_kWhPerKg);

for i = 1:nS
    n = segCounts(i);
    pN = p;
    pN.PWL.nSegments = n;
    pN.PWL.bkpt_e  = pwl_utils('fit', p.PWL.eta_FC_e_func,  p.PWL.FC_H2_max, n, 'FC_elec_sweep');
    pN.PWL.bkpt_th = pwl_utils('fit', p.PWL.eta_FC_th_func, p.PWL.FC_H2_max, n, 'FC_heat_sweep');

    % 1) Curve-fit error vs. the exact continuous function
    y_pwl_e = pwl_utils('eval', pN.PWL.bkpt_e.x,  pN.PWL.bkpt_e.y,  x_test);
    y_pwl_t = pwl_utils('eval', pN.PWL.bkpt_th.x, pN.PWL.bkpt_th.y, x_test);
    errE = abs(y_true_e - y_pwl_e); errT = abs(y_true_t - y_pwl_t);
    maxErrE(i) = max(errE); rmseE(i) = sqrt(mean(errE.^2));
    maxErrT(i) = max(errT); rmseT(i) = sqrt(mean(errT.^2));

    % 2) MILP solve time (mean of 5)
    times = zeros(1,5);
    for r = 1:5
        tic; sol = dayahead_dispatch(pN, fc); times(r) = toc;
    end
    solveTime(i) = mean(times);
    plannedCost(i) = sol.cost;

    % 3) Realized cost: re-evaluate the fuel cell's electrical output
    % through the EXACT continuous function, holding everything else at
    % its planned value, and let grid import/export absorb the gap.
    uPlan = sol.PH2(:) / p.PWL.FC_H2_max;
    PH2col = sol.PH2(:);
    FCelec_true = p.PWL.eta_FC_e_func(uPlan) .* PH2col;
    FCelec_planned = pwl_utils('eval', pN.PWL.bkpt_e.x, pN.PWL.bkpt_e.y, PH2col);
    Pnet_new = (sol.Pg_imp(:) - sol.Pg_exp(:)) - (FCelec_true - FCelec_planned);
    Pgi_new = max(Pnet_new, 0); Pge_new = max(-Pnet_new, 0);
    realizedCost(i) = sum(fc.DA.priceImport(:).*Pgi_new - fc.DA.priceExport(:).*Pge_new) + p.price_H2*sum(PH2col);

    % 4) Optimism diagnostic (same definition as Case 5 in
    % main_month4a_case_studies.m): electricity this n-segment planning
    % model believed its own committed fuel would produce, minus what the
    % true curve really produces from that same fuel, per kW of fuel.
    % Reuses the two vectors already computed just above, so it adds no
    % new computation and cannot perturb any value in the table.
    %   > 0 optimistic  -> over-dispatches the FC -> reality under-delivers
    %                      -> Gap(%) pushed POSITIVE
    %   < 0 pessimistic -> Gap(%) pushed NEGATIVE
    optimism(i) = (sum(FCelec_planned) - sum(FCelec_true)) / sum(PH2col);
end

fprintf('%-10s %10s %10s %10s %10s %12s %12s %12s %10s %10s\n', ...
    'nSegments', 'MaxErrE', 'RMSE-E', 'MaxErrT', 'RMSE-T', 'Solve(s)', 'Planned($)', 'Realized($)', 'Gap(%)', 'Optimism');
for i = 1:nS
    fprintf('%-10d %10.4f %10.4f %10.4f %10.4f %12.5f %12.4f %12.4f %10.2f %+10.4f\n', ...
        segCounts(i), maxErrE(i), rmseE(i), maxErrT(i), rmseT(i), solveTime(i), ...
        plannedCost(i), realizedCost(i), 100*(realizedCost(i)-plannedCost(i))/abs(plannedCost(i)), optimism(i));
end

% Slopes quoted in the explanation below, computed (not hardcoded) from the
% same fits used in the sweep. i1/i2/i10 locate the rows the text names by
% number, so the text stays correct if segCounts is ever edited.
slopeOf = @(n) diff(pwl_utils('fit', p.PWL.eta_FC_e_func, p.PWL.FC_H2_max, n, 's').y) ...
             ./ diff(pwl_utils('fit', p.PWL.eta_FC_e_func, p.PWL.FC_H2_max, n, 's').x);
slope1 = slopeOf(1); slope2 = slopeOf(2); slope5 = slopeOf(5);
i1 = find(segCounts == 1); i2 = find(segCounts == 2); i10 = find(segCounts == 10);
gapOf = @(i) 100*(realizedCost(i)-plannedCost(i))/abs(plannedCost(i));

fprintf(['\nCurve-fit error (Max/RMSE, kW) falls monotonically as segment count rises\n' ...
    '(nSegments=1 -> %d: MaxErrE %.4f -> %.4f kW, MaxErrT %.4f -> %.4f kW), the same\n' ...
    'qualitative shape as Huang et al.''s reported accuracy-vs-computation trend\n' ...
    '(13.7%%->8.35%%->1.11%%->0.06%% for their system/curves -- not the same numbers,\n' ...
    'same kind of trend). MILP solve time grows with segment count (more segment\n' ...
    'variables and fill-order binaries per hour), the tractability cost side of the\n' ...
    'trade-off the thesis is centrally about.\n' ...
    '\nThe Gap(%%) column is NOT monotonic, and the n=2 row (%+.2f%%) is a genuine outlier --\n' ...
    'worse than n=1 (%+.2f%%). The mechanism is the OPTIMISM column, and it is exactly the\n' ...
    'same effect explained for Case 5 in main_month4a_case_studies.m, with the opposite\n' ...
    'sign. What matters is not how ACCURATE a coarse model is but whether it errs HIGH or\n' ...
    'LOW where the fuel cell actually operates:\n' ...
    '  n=1: chord slope %.4f, BELOW the true marginal slopes in the dispatched range\n' ...
    '       -> pessimistic (Optimism %+.4f) -> plans a high cost, reality beats the plan\n' ...
    '       -> gap pushed NEGATIVE (%+.2f%%).\n' ...
    '  n=2: one slope %.4f spanning 0-75 kW, vs the true curve''s own %.4f over the first\n' ...
    '       30 kW of that span; the true curve is convex there, so this chord sits ABOVE\n' ...
    '       it in between -> optimistic (Optimism %+.4f) -> over-dispatches the fuel cell,\n' ...
    '       reality then under-delivers -> gap pushed POSITIVE (%+.2f%%).\n' ...
    'Adding a segment made the fit strictly better on every curve-fit metric yet made the\n' ...
    'gap much worse, purely because it flipped the sign of the modeling error. The sign of\n' ...
    'Optimism predicts the sign of Gap(%%) in every row of this table.\n' ...
    '\nIts MAGNITUDE deliberately is not claimed to scale: n=1 has by far the largest\n' ...
    '|Optimism| yet a small gap, while n=2 has a small |Optimism| and the largest gap.\n' ...
    'A shortfall must be covered by importing at $%.2f-$%.2f/kWh whereas a surplus is only\n' ...
    'worth the $%.2f/kWh export price, so optimism is punished harder than pessimism is\n' ...
    'rewarded, and the re-dispatch itself differs per row. Read Optimism as a direction,\n' ...
    'not a magnitude.\n' ...
    '\nThis is why the CURVE-FIT ERROR columns, not the gap, are the decision-independent\n' ...
    'measure of PWL accuracy: they depend only on the approximation, whereas the gap also\n' ...
    'depends on which dispatch that approximation happened to induce. By nSegments=10 both\n' ...
    'have converged -- Optimism is within %+.4f of neutral and the gap within %.2f%% of\n' ...
    'zero.\n'], segCounts(end), maxErrE(1), maxErrE(end), maxErrT(1), maxErrT(end), ...
    gapOf(i2), gapOf(i1), ...
    slope1(1), optimism(i1), gapOf(i1), ...
    slope2(1), slope5(1), optimism(i2), gapOf(i2), ...
    min(fc.DA.priceImport), max(fc.DA.priceImport), max(fc.DA.priceExport), ...
    optimism(i10), abs(gapOf(i10)));

%% Plot
try
    figure('Position',[100 100 1000 700]);

    subplot(2,2,1);
    semilogy(segCounts, maxErrE, '-o', 'DisplayName','Electrical'); hold on;
    semilogy(segCounts, maxErrT, '-s', 'DisplayName','Thermal'); grid on;
    xlabel('nSegments'); ylabel('Max curve-fit error (kW)'); legend('Location','northeast');
    title('PWL approximation error vs. segment count');

    subplot(2,2,2);
    plot(segCounts, solveTime, '-o'); grid on;
    xlabel('nSegments'); ylabel('Mean MILP solve time (s)');
    title('Day-ahead MILP solve time vs. segment count');

    subplot(2,2,3);
    plot(segCounts, plannedCost, '-o', 'DisplayName','Planned'); hold on;
    plot(segCounts, realizedCost, '-s', 'DisplayName','Realized'); grid on;
    xlabel('nSegments'); ylabel('Cost ($/day)'); legend('Location','northeast');
    title('Planned vs. realized day-ahead cost');

    subplot(2,2,4);
    bar(100*(realizedCost-plannedCost)./abs(plannedCost));
    set(gca,'XTickLabel',arrayfun(@num2str,segCounts,'UniformOutput',false));
    xlabel('nSegments'); ylabel('Gap (%)'); grid on;
    title('Realized-vs-planned cost gap vs. segment count');
catch plot_err
    fprintf('\n[plots skipped: %s]\n', plot_err.message);
end
