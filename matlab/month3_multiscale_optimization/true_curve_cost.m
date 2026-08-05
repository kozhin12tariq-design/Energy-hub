function [cost, corr] = true_curve_cost(pModel, fc, R, fcPWL)
%TRUE_CURVE_COST Realized cost with BOTH converters re-evaluated exactly.
%
%   [cost, corr] = TRUE_CURVE_COST(pModel, fc, R, fcPWL)
%
%   WHY BOTH, AND WHY THIS MATTERS MORE THAN IT LOOKS. realtime_balance
%   already re-evaluates the fuel cell's ELECTRICAL output through the true
%   curve whatever the planner believed, so a coarse electrical model is
%   priced honestly. Nothing does that for HEAT. The heat balance is an
%   equality settled at the day-ahead and intraday levels, and there is no
%   real-time heat corrector, so a planner whose thermal curve OVER-promises
%   simply schedules less fuel, delivers less heat than it thinks, and is
%   never charged for the difference.
%
%   That is not a small effect and it points the wrong way. The fuel cell's
%   thermal curve y(u) = (0.15u + 0.25u^1.7)*Pmax is convex, so a 1-segment
%   chord lies ABOVE it at part load -- the CONSTANT-efficiency model
%   over-promises heat, under-buys hydrogen, and looks cheaper than it is.
%   Comparing PWL against that uncorrected baseline would report PWL as a
%   reliable cost when what is actually being measured is an unpriced heat
%   shortfall in its comparator. This function closes that gap so every
%   configuration is priced against the same physics.
%
%   HOW THE SHORTFALL IS PRICED, and the convention is deliberately
%   conservative. Heat the plan promised but the true curves do not deliver
%   is made up by the HEAT PUMP at its own true marginal COP, drawing from
%   the grid -- the heat pump is the cheapest heat source in this hub, so
%   this is a LOWER bound on what the shortfall really costs. A coarse model
%   is therefore charged the least defensible amount for its error, and any
%   penalty that survives is not an artifact of the pricing convention.
%
%   SCOPE, as declared for the same correction in main_month4c: this prices
%   the consequence of a wrong curve. It does not re-run the schedule, so it
%   does not capture what the planner would have chosen had it known the
%   truth.
%
%   fcPWL : true if the planner used the full segmented fuel-cell curves,
%           false if it used the 1-segment fit (opts.usePWL in
%           simulate_multiscale_day). Required, because the fuel cell's
%           planning breakpoints are set by that option rather than by
%           pModel, and correcting against the wrong ones would measure
%           nothing.

    thisFile = mfilename('fullpath');
    addpath(fileparts(thisFile));
    addpath(fullfile(fileparts(thisFile), '..', 'month2_coupling_matrix_pwl_ieee33'));

    if isfield(fc, 'ambientC'); amb = fc.ambientC; else; amb = []; end
    hp  = heatpump_curve(pModel, amb);

    % ---- heat pump -----------------------------------------------------
    Php   = max(R.Php5(:), 0);
    uHP   = Php / pModel.HeatPump.Pmax;
    copTrue = hp.copRated * pModel.HeatPump.partLoad_func(max(uHP, 1e-9));
    if isfield(pModel.HeatPump, 'usePWL') && pModel.HeatPump.usePWL
        heatHPplanned = pwl_utils('eval', hp.bkpt.x, hp.bkpt.y, Php);
    else
        heatHPplanned = pModel.HeatPump.COP * Php;   % legacy constant model
        copTrue = max(copTrue, 1e-6);
    end
    dHeat = heatHPplanned - copTrue .* Php;          % >0 = over-promised

    % ---- fuel cell, thermal side ---------------------------------------
    PH2 = max(R.PH2_5(:), 0);
    if fcPWL
        bkT_plan = pModel.PWL.bkpt_th;
    else
        bkT_plan = pwl_utils('fit', pModel.PWL.eta_FC_th_func, pModel.PWL.FC_H2_max, 1, 'FC_heat_const');
    end
    heatFCplanned = pwl_utils('eval', bkT_plan.x, bkT_plan.y, PH2);
    uFC           = PH2 / pModel.PWL.FC_H2_max;
    heatFCtrue    = pModel.PWL.eta_FC_th_func(max(uFC, 1e-12)) .* PH2;
    dHeat = dHeat + (heatFCplanned - heatFCtrue);

    % ---- price the total heat shortfall through the heat pump -----------
    % THE COVERING COP IS NOT THE CURRENT MARGINAL COP, and getting this
    % wrong dominated an earlier version of this file. Covering a shortfall
    % means running the heat pump MORE, which moves it UP its part-load curve
    % toward the sweet spot -- so the efficiency that applies to the extra
    % heat is the one it would reach when ramped, not the cycling-dominated
    % value it happens to sit at now. Dividing by the latter blows up: at
    % u = 0.001 the true COP is ~0.002, and a 5 W modelling error priced
    % through it becomes 2.6 kW of imaginary grid import.
    %
    % That was not hypothetical. Measured on seed 7: in summer, 48 of 288
    % intervals sit at 0 < u < 0.02 and contributed 9.03 of the 12.87 kWh
    % total correction -- 70% of the entire correction came from intervals
    % where the heat pump was doing essentially nothing. On a ~$51 summer day
    % that is ~$2.70, roughly 5%, which is larger than every effect this
    % study is trying to measure and concentrated in exactly the season that
    % decides the gate.
    %
    % copRated is therefore a FLOOR on the covering efficiency. Note this is
    % conservative in BOTH directions and so cannot flatter either arm: for a
    % shortfall a higher COP means a smaller charge, and for a surplus it
    % means a smaller credit.
    copCover = max(copTrue, hp.copRated);
    dElec = dHeat ./ copCover;

    hourOf5 = ceil((1:288)/12)';
    pImp = fc.DA.priceImport(hourOf5); pExp = fc.DA.priceExport(hourOf5);
    net  = (R.Pg_imp5(:) - R.Pg_exp5(:)) + dElec;
    cost = sum(pImp.*max(net,0) - pExp.*max(-net,0) + pModel.price_H2*PH2) / 12;
    corr = cost - R.actualCost;
end
