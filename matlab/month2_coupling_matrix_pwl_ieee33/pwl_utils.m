function varargout = pwl_utils(mode, varargin)
%PWL_UTILS Piecewise-linearization toolkit (thesis roadmap Month 2, item II).
%
%   One dispatcher for the three PWL operations used throughout this
%   project instead of one file each:
%
%   pwlStruct = PWL_UTILS('fit', eta_func, Pmax, nSegments, name)
%     Fits a PWL input/output curve to a nonlinear part-load efficiency
%     function.
%       eta_func  : function handle, eta_func(u) = efficiency at load
%                   fraction u in [0,1] (u = input_power / Pmax)
%       Pmax      : rated/maximum input power for this branch
%       nSegments : number of PWL segments (nSegments+1 breakpoints,
%                   uniformly spaced in load fraction)
%       name      : label used when this curve is referenced in printed
%                   equations (energy_hub_print_equations.m)
%     Returns a breakpoint struct usable directly as an eh_edge Eta value:
%       pwlStruct.type = 'pwl'
%       pwlStruct.x    = input breakpoints,  [0, x1, ..., x_nSegments]
%       pwlStruct.y    = output breakpoints, [0, y1, ..., y_nSegments]
%     with y_i = eta_func(u_i) * x_i, i.e. the curve always starts at the
%     origin (zero input -> zero output), matching every real converter.
%
%   y = PWL_UTILS('eval', x_bkpt, y_bkpt, x)
%     Evaluates the PWL curve at scalar or vector input x (linear
%     interpolation; out-of-domain values clamped to [x_bkpt(1),
%     x_bkpt(end)], since hub inputs are physically bounded by rated
%     component power anyway). This is the EXACT piecewise-linear model
%     value (used for simulation/validation), as opposed to 'local_affine'
%     below, which returns a single local linear piece valid only near
%     one operating point.
%
%   [slope, intercept, segIdx] = PWL_UTILS('local_affine', x_bkpt, y_bkpt, x0)
%     Finds which segment of the curve contains x0 (clamped into the
%     breakpoint domain first) and returns that segment's slope/
%     intercept, i.e. y ~= slope*x + intercept for x near x0 while it
%     stays within the same segment. Used by energy_hub_linearize.m to
%     build a local coupling matrix around one operating point.

    switch mode
        case 'fit'
            [eta_func, Pmax, nSegments, name] = varargin{1:4};
            u = linspace(0, 1, nSegments + 1);
            x = u * Pmax;
            y = zeros(size(x));
            for i = 2:numel(x)
                y(i) = eta_func(u(i)) * x(i);
            end
            pwlStruct.type = 'pwl';
            pwlStruct.x = x;
            pwlStruct.y = y;
            pwlStruct.name = name;
            varargout{1} = pwlStruct;

        case 'eval'
            [x_bkpt, y_bkpt, x] = varargin{1:3};
            xc = min(max(x, x_bkpt(1)), x_bkpt(end));
            varargout{1} = interp1(x_bkpt, y_bkpt, xc, 'linear');

        case 'local_affine'
            [x_bkpt, y_bkpt, x0] = varargin{1:3};
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
            varargout{1} = slope; varargout{2} = intercept; varargout{3} = segIdx;

        otherwise
            error('pwl_utils:mode', 'Unknown mode "%s" (use ''fit'', ''eval'', or ''local_affine'').', mode);
    end
end
