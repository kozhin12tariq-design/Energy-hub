function [cost, corr] = hp_true_curve_cost(p, fc, R)
%HP_TRUE_CURVE_COST Realized cost with the heat pump re-evaluated exactly.
%
%   [cost, corr] = HP_TRUE_CURVE_COST(p, fc, R)
%
%   WHY THIS IS NEEDED, and why the heat pump differs from the fuel cell.
%   Real time re-optimizes electricity only; the heat balance is settled at
%   the day-ahead and intraday levels, so a coarse COP model is never
%   corrected by a later layer the way a coarse fuel-cell model is. Left
%   alone, a 1-segment and a 5-segment heat-pump model would each simply
%   deliver whatever their own model claimed, and comparing their costs
%   would measure two different physics rather than one physics under two
%   models.
%
%   So the same correction main_month4c applies to the fuel cell is applied
%   here: the electricity the schedule committed is converted to heat
%   through the breakpoints the PLANNER used, then back to electricity
%   through the TRUE continuous COP curve, and grid import absorbs the
%   difference. Both configurations are then priced against the same
%   physics and differ only in the model that chose the schedule -- which
%   is what a planning-error measurement means.
%
%   SCOPE, stated because it bounds the result: this corrects the
%   ELECTRICAL consequence of a wrong COP. It does not re-run the schedule,
%   so it does not capture the second-order effect of the planner having
%   chosen different storage or fuel-cell decisions had it known the true
%   curve. That is the same scope main_month4c declares for the fuel cell.
%
%   R must carry Php5 and the usual 5-minute series from
%   simulate_multiscale_day. corr is the resulting correction in $/day.

    thisFile = mfilename('fullpath');
    addpath(fileparts(thisFile));
    addpath(fullfile(fileparts(thisFile), '..', 'month2_coupling_matrix_pwl_ieee33'));

    if isfield(fc, 'ambientC'); amb = fc.ambientC; else; amb = []; end
    hp  = heatpump_curve(p, amb);
    Php = max(R.Php5(:), 0);

    % Heat the planner believed it was getting, from its own breakpoints.
    heatPlanned = pwl_utils('eval', hp.bkpt.x, hp.bkpt.y, Php);

    % Heat the TRUE continuous curve actually delivers from that same input.
    u        = Php / p.HeatPump.Pmax;
    copTrue  = hp.copRated * p.HeatPump.partLoad_func(max(u, 1e-9));
    heatTrue = copTrue .* Php;

    % Shortfall converted back to electricity and absorbed by grid import.
    % The covering COP is FLOORED at the rated value for the reason set out
    % at length in true_curve_cost.m: covering a shortfall means running the
    % pump MORE, which moves it up its part-load curve, so the cycling-
    % dominated COP it currently sits at is not the efficiency that applies
    % to the extra heat. Dividing by that instead turns a 5 W modelling error
    % at u = 0.001 into 2.6 kW of imaginary import, and measurement showed
    % 70% of the whole summer correction coming from such intervals.
    copCover = max(copTrue, hp.copRated);
    dElec = (heatPlanned - heatTrue) ./ copCover;

    hourOf5 = ceil((1:288)/12)';
    pImp = fc.DA.priceImport(hourOf5); pExp = fc.DA.priceExport(hourOf5);
    net  = (R.Pg_imp5(:) - R.Pg_exp5(:)) + dElec;
    cost = sum(pImp.*max(net,0) - pExp.*max(-net,0) + p.price_H2*R.PH2_5(:)) / 12;
    corr = cost - R.actualCost;
end
