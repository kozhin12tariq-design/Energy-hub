function y = pwl_evaluate(x_bkpt, y_bkpt, x)
%PWL_EVALUATE Evaluate a piecewise-linear curve at given input value(s).
%
%   y = PWL_EVALUATE(x_bkpt, y_bkpt, x)
%
%   x_bkpt, y_bkpt : breakpoints of the PWL curve (ascending x_bkpt)
%   x              : scalar or vector of input values (out-of-domain
%                     values are clamped to [x_bkpt(1), x_bkpt(end)],
%                     since hub inputs are physically bounded by rated
%                     component power anyway)
%
%   This is the EXACT piecewise-linear model value (used for simulation/
%   validation), as opposed to energy_hub_linearize.m which returns a
%   single local affine piece valid only near one operating point.

    xc = min(max(x, x_bkpt(1)), x_bkpt(end));
    y = interp1(x_bkpt, y_bkpt, xc, 'linear');
end
