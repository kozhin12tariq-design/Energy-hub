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

    % ---- price the total heat shortfall at the heat pump's true COP ----
    % copTrue is ~0 when the heat pump is idle, which would divide by
    % nothing; fall back to its rated COP there, which is the value it would
    % run at if it were switched on to cover the gap.
    copCover = copTrue;
    copCover(Php <= 1e-9) = hp.copRated;
    dElec = dHeat ./ max(copCover, 1e-6);

    hourOf5 = ceil((1:288)/12)';
    pImp = fc.DA.priceImport(hourOf5); pExp = fc.DA.priceExport(hourOf5);
    net  = (R.Pg_imp5(:) - R.Pg_exp5(:)) + dElec;
    cost = sum(pImp.*max(net,0) - pExp.*max(-net,0) + pModel.price_H2*PH2) / 12;
    corr = cost - R.actualCost;
end
