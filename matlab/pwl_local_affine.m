function [slope, intercept, segIdx] = pwl_local_affine(x_bkpt, y_bkpt, x0)
%PWL_LOCAL_AFFINE Local affine (slope, intercept) of a PWL curve at x0.
%
%   [slope, intercept, segIdx] = PWL_LOCAL_AFFINE(x_bkpt, y_bkpt, x0)
%
%   Finds which segment of the piecewise-linear curve contains x0 (x0 is
%   clamped into the breakpoint domain first) and returns that segment's
%   slope/intercept, i.e. y ~= slope*x + intercept for x near x0 while it
%   stays within the same segment. Used by energy_hub_linearize.m to
%   build a local coupling matrix around one operating point.

    n = numel(x_bkpt) - 1;
    x0c = min(max(x0, x_bkpt(1)), x_bkpt(end));
    segIdx = find(x0c <= x_bkpt(2:end), 1, 'first');
    if isempty(segIdx)
        segIdx = n;
    end
    x1 = x_bkpt(segIdx);   x2 = x_bkpt(segIdx+1);
    y1 = y_bkpt(segIdx);   y2 = y_bkpt(segIdx+1);
    slope = (y2 - y1) / (x2 - x1);
    intercept = y1 - slope * x1;
end
