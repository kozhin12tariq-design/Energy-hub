function hp = heatpump_curve(p, ambientC, placement)
%HEATPUMP_CURVE Load- and ambient-dependent heat-pump COP, fitted as PWL.
%
%   hp = HEATPUMP_CURVE(p, ambientC, placement)
%
%   Until now the heat pump was a single constant, p.HeatPump.COP = 3.2,
%   while it moved roughly 15x more energy on a shoulder day than the fuel
%   cell the PWL machinery was built for. This file supplies the curve; the
%   dispatch files embed it with the same segment / concentrator /
%   fill-order structure the fuel cell already uses, and
%   main_month4i_pwl_device_sweep.m measures whether that pays.
%
%   ------------------------------------------------------------------
%   THE AMBIENT DEPENDENCE IS SOURCED. Manufacturer rating points for the
%   Stiebel Eltron WPL 25 ACS air-to-water heat pump, at 35 C flow
%   temperature (the underfloor-heating rating condition):
%
%       A-7/W35 : COP = 2.98
%       A 2/W35 : COP = 4.14
%       A 7/W35 : COP = 4.82
%
%   Those three points are very nearly collinear in ambient temperature, so
%   a least-squares line reproduces them to within 0.01:
%
%       COP_rated(T) = 3.8926 + 0.1311 * T        (T in degrees C)
%       check: T=-7 -> 2.975,  T=+2 -> 4.155,  T=+7 -> 4.810
%
%   EXTRAPOLATION IS REFUSED, and this matters for summer. The datasheet
%   characterises -7 to +7 C; a summer ambient of 18.5 C would give a COP of
%   6.3 by extrapolation, which the data does not support, and summer heat
%   demand here is domestic hot water, which needs a HIGHER flow temperature
%   than W35 and would therefore have a LOWER COP, not a higher one.
%   Modelling flow temperature properly is a second dimension this study
%   does not have, so ambient is CLAMPED to the characterised range. The
%   consequence is stated plainly: shoulder and summer share the same COP
%   curve (the A7 value), and only winter is genuinely different. The
%   seasonal coupling this produces is therefore a winter penalty, which is
%   the physically real part, rather than a summer bonus, which would not be.
%
%   THE PART-LOAD SHAPE IS AN ASSUMPTION, LABELLED AS ONE. EN 14825 rates
%   heat pumps at part load precisely because inverter-driven units are more
%   efficient there -- heat exchangers are sized for full load, so at 30-50%
%   load the same surface area serves less heat and approach temperatures
%   fall. Below roughly 15% load that reverses: the compressor cycles, and
%   start-up and defrost losses dominate. The declared EN 14825 part-load
%   COP table for this specific unit was not reachable from this
%   environment, so the shape is DECLARED rather than sourced:
%
%       f(u) = (1.25 - 0.25*u) * (1 - exp(-u/0.08))
%
%       f(0.05) = 0.575   cycling-dominated
%       f(0.15) = 1.027
%       f(0.30) = 1.147   the part-load sweet spot
%       f(0.50) = 1.123
%       f(1.00) = 1.000   the rating point, by construction
%
%   The peak is a 15% gain at part load and the low-load penalty is 42%.
%   Both are within the range EN 14825 exists to capture, and the function
%   is anchored at f(1) = 1 so the rated point is exactly the manufacturer's
%   number rather than a fitted one.
%
%   COP(u, T) = COP_rated(T) * f(u), and the PWL fit uses the SAME
%   pwl_utils('fit', ...) path as the fuel cell -- no new fitting code.
%
%   SLOPE MONOTONICITY, CHECKED NUMERICALLY RATHER THAN ASSUMED. The
%   segment slopes of the thermal-output curve at nSegments = 5 are
%
%       winter  (A0.5): 4.360  4.683  4.012  3.569  3.167
%       shoulder (A7) : 5.299  5.691  4.876  4.337  3.849
%
%   Segment 2's slope EXCEEDS segment 1's in both, because the cycling
%   penalty makes the first slice of load the least efficient. The slopes
%   are therefore NOT monotonically decreasing and FILL-ORDER BINARIES ARE
%   REQUIRED -- exactly the same situation as the fuel cell, and for the
%   same reason: without them an LP relaxation fills segment 2 while
%   segment 1 is empty and reports more heat per kWh of electricity than
%   the machine can deliver. hp.needsBinaries carries that verdict and the
%   dispatch files act on it rather than adding binaries by reflex.
%
%   Input
%     p        : parameter struct (uses p.HeatPump.Pmax, .nSegments, and the
%                two function handles installed by multiscale_default_params)
%     ambientC : ambient air temperature in C for the day being solved.
%                forecast_profiles supplies fc.ambientC per season; callers
%                that have no season default to the shoulder value.
%
%   Output struct hp:
%     bkpt          : pwl_utils breakpoint struct (x = electrical kW,
%                     y = thermal kW)
%     w             : 1 x n segment widths (electrical kW)
%     slopes        : 1 x n thermal kW per electrical kW, i.e. per-segment COP
%     nSegments     : n
%     ambientC      : the CLAMPED ambient actually used
%     ambientRaw    : what was requested, before clamping
%     copRated      : COP_rated at the clamped ambient
%     needsBinaries : true if the slopes are not monotonically decreasing
%     meanCOP       : energy-weighted COP over the full range, for reporting
%     placement     : 'uniform' (default) or 'curvature' -- where the
%                     breakpoints sit. See the note below.
%
%   BREAKPOINT PLACEMENT MATTERS MORE THAN SEGMENT COUNT HERE, and the gate
%   in main_month4i is what showed it. With UNIFORM breakpoints the first
%   segment spans u = 0 to 0.2, averaging the curve's steepest rise into one
%   wide chord whose slope (5.30) badly OVER-states the true COP at u ~ 0.1
%   (4.20). A heat pump serving only a domestic-hot-water baseline lives
%   almost entirely inside that first segment, so a finer uniform PWL is
%   worse there than a plain chord. pwl_utils' 'curvature' placement, which
%   this project already implemented in Month 2a, concentrates breakpoints
%   where the second derivative is largest and puts four of five below
%   u = 0.34; the worst over-promise in the low-load band falls from
%   +4.85 kW to +0.32 kW and the mean error changes sign to the safe
%   (pessimistic) direction.

    thisFile = mfilename('fullpath');
    addpath(fullfile(fileparts(thisFile), '..', 'month2_coupling_matrix_pwl_ieee33'));

    if nargin < 2 || isempty(ambientC); ambientC = 9.0; end   % shoulder default
    if nargin < 3 || isempty(placement)
        if isfield(p.HeatPump, 'placement'); placement = p.HeatPump.placement;
        else; placement = 'uniform'; end
    end

    hp.ambientRaw = ambientC;
    hp.ambientC   = min(max(ambientC, p.HeatPump.ambientMinC), p.HeatPump.ambientMaxC);
    hp.copRated   = p.HeatPump.copRated_func(hp.ambientC);

    n = p.HeatPump.nSegments;
    copFunc = @(u) hp.copRated * p.HeatPump.partLoad_func(u);

    hp.bkpt      = pwl_utils('fit', copFunc, p.HeatPump.Pmax, n, 'HP_COP', placement);
    hp.placement = placement;
    hp.nSegments = n;
    hp.w         = diff(hp.bkpt.x);
    hp.slopes    = diff(hp.bkpt.y) ./ hp.w;

    % A tolerance rather than a bare comparison: two slopes that differ in
    % the 12th decimal are equal for this purpose and should not drag in
    % binaries.
    hp.needsBinaries = any(diff(hp.slopes) > 1e-9);
    hp.meanCOP       = hp.bkpt.y(end) / hp.bkpt.x(end);
end
