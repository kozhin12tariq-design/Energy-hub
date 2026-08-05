function e = approx_error(pModel, fc, R)
%APPROX_ERROR Mean heat-approximation error of a heat-pump model, in kW.
%
%   e = APPROX_ERROR(pModel, fc, R)
%
%   Evaluates pModel's heat-pump breakpoints against the TRUE continuous COP
%   curve at the load points the schedule R actually visited, and returns the
%   mean signed error in kW of heat.
%
%   SIGN CONVENTION AND WHY IT IS THE POINT: positive means the model
%   OVER-PROMISES -- it claims more heat per kWh than the machine delivers.
%   This project has already established, for the fuel cell, that optimism
%   and pessimism are not symmetric in cost: a shortfall must be covered by
%   importing at the retail tariff while a surplus is only worth the export
%   price. A model that errs high is therefore punished harder than one that
%   errs low by the same margin, so the SIGN of this number predicts the sign
%   of the cost penalty, exactly as the Optimism column does in Month 4a.

    thisFile = mfilename('fullpath');
    addpath(fileparts(thisFile));
    addpath(fullfile(fileparts(thisFile), '..', 'month2_coupling_matrix_pwl_ieee33'));

    if isfield(fc, 'ambientC'); amb = fc.ambientC; else; amb = []; end
    hpM = heatpump_curve(pModel, amb);
    x   = R.Php5(R.Php5 > 1e-6);
    if isempty(x); e = 0; return; end
    trueY = hpM.copRated * pModel.HeatPump.partLoad_func(max(x/pModel.HeatPump.Pmax, 1e-9)) .* x;
    e = mean(pwl_utils('eval', hpM.bkpt.x, hpM.bkpt.y, x) - trueY);
end
