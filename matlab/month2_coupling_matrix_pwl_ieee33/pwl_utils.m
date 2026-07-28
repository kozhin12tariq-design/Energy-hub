function varargout = pwl_utils(mode, varargin)
%PWL_UTILS Piecewise-linearization toolkit (thesis roadmap Month 2, item II).
%
%   One dispatcher for the three PWL operations used throughout this
%   project instead of one file each:
%
%   pwlStruct = PWL_UTILS('fit', eta_func, Pmax, nSegments, name, placement)
%     Fits a PWL input/output curve to a nonlinear part-load efficiency
%     function.
%       eta_func  : function handle, eta_func(u) = efficiency at load
%                   fraction u in [0,1] (u = input_power / Pmax)
%       Pmax      : rated/maximum input power for this branch
%       nSegments : number of PWL segments (nSegments+1 breakpoints)
%       name      : label used when this curve is referenced in printed
%                   equations (energy_hub_print_equations.m)
%       placement : (optional) 'uniform' (default) -- breakpoints
%                   uniformly spaced in load fraction u, exactly as
%                   before this argument existed (same numbers, bit for
%                   bit -- this default must never change). 'curvature'
%                   -- breakpoints concentrated where the output curve's
%                   |second derivative| is largest (estimated on a fine
%                   grid, breakpoints placed at equal cumulative-
%                   curvature intervals), giving more resolution where
%                   the curve bends most and less where it is closer to
%                   linear, for the same segment count.
%     Returns a breakpoint struct usable directly as an eh_edge Eta value:
%       pwlStruct.type      = 'pwl'
%       pwlStruct.x         = input breakpoints,  [0, x1, ..., x_nSegments]
%       pwlStruct.y         = output breakpoints, [0, y1, ..., y_nSegments]
%       pwlStruct.placement = the placement mode used ('uniform'/'curvature')
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
            placement = 'uniform';
            if numel(varargin) >= 5
                placement = varargin{5};
            end
            switch placement
                case 'uniform'
                    u = linspace(0, 1, nSegments + 1);
                case 'curvature'
                    u = curvature_breakpoints(eta_func, nSegments);
                otherwise
                    error('pwl_utils:placement', ...
                        'Unknown placement "%s" (use ''uniform'' or ''curvature'').', placement);
            end
            x = u * Pmax;
            y = zeros(size(x));
            for i = 2:numel(x)
                y(i) = eta_func(u(i)) * x(i);
            end
            pwlStruct.type = 'pwl';
            pwlStruct.x = x;
            pwlStruct.y = y;
            pwlStruct.name = name;
            pwlStruct.placement = placement;
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

function u = curvature_breakpoints(eta_func, nSegments)
%CURVATURE_BREAKPOINTS Load-fraction breakpoints concentrated by |y''(u)|.
%   y(u) = eta_func(u)*u is the output curve as a fraction of Pmax (Pmax
%   itself is a constant scale factor and does not affect WHERE curvature
%   concentrates, so it is left out here). |d^2y/du^2| is estimated by
%   central finite differences on a fine uniform grid, then breakpoints
%   are placed at equal intervals of the CUMULATIVE curvature (a
%   trapezoidal running sum) rather than equal intervals of u itself --
%   this is the standard "equidistribute the error measure" construction,
%   putting more breakpoints where the curve bends most.
    N = 2000;
    uf = linspace(0, 1, N);
    yf = eta_func(uf) .* uf;
    h = uf(2) - uf(1);
    d2 = zeros(1, N);
    d2(2:end-1) = (yf(3:end) - 2*yf(2:end-1) + yf(1:end-2)) / h^2;
    d2(1) = d2(2); d2(end) = d2(end-1);
    curv = abs(d2);

    if sum(curv) < 1e-9
        u = linspace(0, 1, nSegments + 1); % flat curve: no basis to concentrate anywhere
        return;
    end

    cumMass = [0, cumsum((curv(1:end-1) + curv(2:end))/2 * h)];
    cumMass = cumMass / cumMass(end);
    targets = linspace(0, 1, nSegments + 1);
    u = interp1(cumMass, uf, targets, 'linear');
    u(1) = 0; u(end) = 1;
end
