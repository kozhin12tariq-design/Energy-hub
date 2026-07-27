function pwlStruct = pwl_fit_from_function(eta_func, Pmax, nSegments, name)
%PWL_FIT_FROM_FUNCTION Fit a PWL input/output curve to a nonlinear
%part-load efficiency function.
%
%   pwlStruct = PWL_FIT_FROM_FUNCTION(eta_func, Pmax, nSegments, name)
%
%   eta_func  : function handle, eta_func(u) = efficiency at load
%               fraction u in [0,1] (u = input_power / Pmax)
%   Pmax      : rated/maximum input power for this branch
%   nSegments : number of PWL segments (nSegments+1 breakpoints, uniformly
%               spaced in load fraction)
%   name      : label used when this curve is referenced in printed
%               equations (energy_hub_print_equations.m)
%
%   Returns a breakpoint struct usable directly as an eh_edge Eta value:
%       pwlStruct.type = 'pwl'
%       pwlStruct.x    = input breakpoints,  [0, x1, ..., x_nSegments]
%       pwlStruct.y    = output breakpoints, [0, y1, ..., y_nSegments]
%   with y_i = eta_func(u_i) * x_i, i.e. the curve always starts at the
%   origin (zero input -> zero output), matching every real converter.

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
end
