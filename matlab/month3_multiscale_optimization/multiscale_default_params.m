function p = multiscale_default_params(hubScale)
%MULTISCALE_DEFAULT_PARAMS Parameters for the multi-timescale dispatch chapter.
%
%   p = MULTISCALE_DEFAULT_PARAMS()
%   p = MULTISCALE_DEFAULT_PARAMS(hubScale)
%
%   HUB SIZE. Every EXTENSIVE rating below (kW, kWh, kVA) is written as a
%   base value multiplied by p.sizing.hubScale, which defaults to
%   hub_sizing().scale = 4.6667. The base values are the ones this file
%   carried before the hub was re-sited from bus 18 to bus 25, so passing
%   hubScale = 1.0 reproduces the earlier parameter set exactly, number for
%   number. hub_sizing.m explains where 4.6667 comes from and why nothing
%   INTENSIVE (efficiency, price, emission factor, SOC band, self-discharge
%   rate, reserve fraction, diversity factor) is scaled with it.
%
%   Calls addpath() for '../month2_coupling_matrix_pwl_ieee33' so
%   pwl_utils.m (a reusable utility function, not a script) is reachable
%   regardless of which Month 3/4 script is the entry point. This is the
%   ONLY dependency Month 3 has on Month 2: the nonlinear efficiency
%   CURVE DEFINITIONS below are copied in directly (not imported from
%   main_month2a's script) so Month 3 never depends on a Month 2 demo
%   script, only on the small fit/eval toolbox.
%
%   A separate parameter set from energy_hub_default_params.m (used by
%   the earlier component/graph/PWL/IEEE33 chapters, whose example
%   numbers are already tuned and validated) sized for a small
%   community/feeder-level "distributed integrated energy system" --
%   large enough that day-ahead/intraday/real-time coordination and
%   storage flexibility are meaningfully visible.
%
%   GENERALIZED STORAGE: four devices share one mathematical model
%   (see storage_soc_update.m):
%       SOC(t) = SOC(t-1) + [eta_ch*Pch(t) - Pdis(t)/eta_dis]*dt/Emax
%                          - selfLoss*SOC(t-1)*dt
%   with 0 <= SOC <= 1 (SOCmin/SOCmax further restrict the usable band)
%   and 0 <= Pch <= Pch_max, 0 <= Pdis <= Pdis_max. Battery and EV are
%   the literal case; the two "generalized" storage devices reuse the
%   exact same equations with a physical reinterpretation:
%     - Building thermal mass: SOC 0..1 maps onto indoor temperature
%       across the comfort band [Tmin,Tmax] (SOC=0 <-> Tmin, SOC=1 <->
%       Tmax); "charging" = heating beyond the minimum requirement
%       (banking heat), "discharging" = coasting on stored heat;
%       Emax = C_th * (Tmax-Tmin) is the equivalent energy capacity of
%       the building's own thermal mass; selfLoss represents passive
%       heat loss to ambient pulling the temperature back down.
%     - District-heating pipe storage: SOC 0..1 maps onto the thermal
%       energy carried by the pipe network's own fluid mass above its
%       baseline return temperature; same equations, larger capacity,
%       slower power limits, better-insulated (smaller selfLoss).

    thisFile = mfilename('fullpath');
    addpath(fullfile(fileparts(thisFile), '..', 'month2_coupling_matrix_pwl_ieee33'));

    p.sizing = hub_sizing();
    if nargin >= 1 && ~isempty(hubScale)
        p.sizing.hubScale = hubScale;     % explicit override (validation/regression)
    else
        p.sizing.hubScale = p.sizing.scale;
    end
    k = p.sizing.hubScale;   % shorthand: multiplies EXTENSIVE ratings only

    % NOTE: there is deliberately NO p.eta_FC_e / p.eta_FC_th here. Earlier
    % versions defined scalar fuel-cell efficiencies (0.45 / 0.35) that the
    % PWL work superseded; they were left in place with a comment saying so,
    % which was a trap -- a reader could reasonably take 0.45 to be the
    % operative electrical efficiency when nothing in the dispatch reads it.
    % They are removed. The fuel cell's electrical and thermal conversion is
    % defined ONLY by the segmented PWL curves in p.PWL below, and the true
    % marginal efficiency varies with load (0.4079/0.4828/0.5089/0.5067 over
    % the first segments at the current nSegments=10), which is the entire
    % point of the PWL model. Month 1/2's separate
    % energy_hub_default_params.m still defines its own scalar values and is
    % unaffected: those drive the constant-efficiency coupling-matrix demos,
    % which are a different (and deliberately simpler) model.

    % PV INVERTER / DC-DC CONVERTER efficiency -- NOT a solar-to-electricity
    % efficiency. It multiplies fc.*.solar, which forecast_profiles.m defines
    % as the PV array's available DC ELECTRICAL output in kW (a ~50 kW-peak
    % array), not irradiance. Module-level conversion of sunlight to DC power
    % (~15-22% for real silicon modules) sits UPSTREAM of this model boundary
    % and is already embedded in that profile. 0.97 is an ordinary
    % power-electronics efficiency; read as sunlight->electricity it would be
    % physically impossible, so the boundary matters.
    p.eta_PV    = 0.97;  % PV inverter/converter efficiency (DC array out -> AC elec)

    % ---------------------------------------------------------------
    % PWL (piecewise-linear) part-load efficiency model for the fuel
    % cell, embedded directly into the day-ahead/intraday MILP dispatch
    % (not just a standalone Month-2 demonstration). See
    % dayahead_dispatch.m for how the segment/ordering-binary structure
    % is built from these breakpoints.
    %
    % Both curves are S-shaped / non-concave (verified numerically at the
    % CURRENT segment count, not carried over from an older one: FC
    % electrical slopes at nSegments=10 are 0.4079, 0.4828, 0.5089,
    % 0.5067, 0.4812, 0.4344, 0.3676, 0.2814, 0.1764, 0.0528 -- segments
    % 2 and 3 rise ABOVE segment 1, so a plain LP relaxation would
    % cherry-pick them while leaving segment 1 empty, reporting more
    % electricity than the fuel cell can physically produce at that fuel
    % level. Fill-order binary variables (u_1..u_{s-1} per time step) are
    % therefore mandatory, not optional:
    % PH2_seg(k+1) <= w(k+1)*u_k and PH2_seg(k) >= w(k)*u_k forces
    % segment k+1 to stay empty until segment k is completely full.
    % (At nSegments=5 the slopes were 0.4453, 0.5078, 0.4578, 0.3245,
    % 0.1146. The peak is SHARPER at 10 -- the rise from segment 1 is
    % 0.0749 against 0.0625 -- because a finer grid resolves the curve's
    % steep initial rise instead of averaging it away, so refining the
    % model makes the binaries MORE necessary rather than less.)
    %
    % SCALING THE FUEL CELL DOES NOT DISTURB THE CURVES. pwl_utils('fit')
    % samples eta at load FRACTIONS u = 0..1 and returns breakpoints
    % x = u*Pmax, y = eta(u)*x, so multiplying FC_H2_max by k multiplies
    % every breakpoint coordinate by k and leaves every segment SLOPE --
    % i.e. every efficiency -- bit-identical. The non-concavity that makes
    % the fill-order binaries mandatory is a property of eta(u) and is
    % unaffected by hub size.
    % SEGMENT COUNT, CHOSEN AT THE POINT WHERE THE REALIZED-COST GAP
    % CONVERGES, not by preference. main_month4c sweeps n over
    % {1,2,5,10,20,36,50,75,100,150} and reports the gap between planned
    % and realized cost:
    %
    %   n=1  gap -4.36%    n=10 gap -0.02%     <- converged
    %   n=2  gap +1.45%    n=20 gap -0.01%
    %   n=5  gap -0.12%    n=36 gap -0.00%
    %
    % 5 is the first count that is not WRONG; 10 is the first at which the
    % cost gap has converged, and it is the bottom of the practical band
    % (n=10 to n=36) that main_month4c already identified. The cost is
    % +0.089 s per day-ahead MILP solve (0.147 -> 0.236 s in the sweep's
    % own timing column) and 216 fill-order binaries per device per
    % 24-hour solve instead of 96. Above ~36 the curve-fit error keeps
    % falling while no reported dispatch number moves, and solve time
    % grows superlinearly, so more is not better either.
    p.PWL.nSegments = 10;     % breakpoints per curve = nSegments+1
    p.PWL.FC_H2_max = 150 * k;  % kW fuel, rated/maximum H2 input (shared
                              % Pmax for both curves and the PH2_total bound)
    p.PWL.eta_FC_e_func  = @(u) 0.30 + 0.35*sqrt(u) - 0.28*u.^2;
    p.PWL.eta_FC_th_func = @(u) 0.15 + 0.25*u.^0.7;
    p.PWL.bkpt_e  = pwl_utils('fit', p.PWL.eta_FC_e_func,  p.PWL.FC_H2_max, p.PWL.nSegments, 'FC_elec');
    p.PWL.bkpt_th = pwl_utils('fit', p.PWL.eta_FC_th_func, p.PWL.FC_H2_max, p.PWL.nSegments, 'FC_heat');

    % Heat pump: the fuel cell is not the ONLY heat source -- without an
    % electricity-to-heat alternative, total heat demand would dictate a
    % minimum fuel cell run level regardless of price (its byproduct
    % electricity would then flood the electrical balance too), removing
    % the genuine multi-source economic tradeoff a sector-coupled system
    % is supposed to exhibit. COP = heat output / electrical input.
    p.HeatPump.COP  = 3.2;   % LEGACY constant, used only when usePWL = false
    %
    % LOAD- AND AMBIENT-DEPENDENT COP. The constant above modelled the
    % highest-throughput converter in the hub -- roughly 15x the fuel cell's
    % energy on a shoulder day -- with one number, while the PWL machinery
    % was applied only to the fuel cell. heatpump_curve.m holds the curve,
    % its manufacturer sourcing (Stiebel Eltron WPL 25 ACS, A-7/A2/A7 at
    % W35), the declared part-load shape, and the numerical slope check that
    % decides whether fill-order binaries are required.
    %
    % THREE MODES, and the distinction matters for the measurement:
    %   usePWL = false            -> the legacy constant 3.2. Reproduces
    %                                every pre-existing result EXACTLY.
    %   usePWL = true, nSeg = 1   -> a one-segment chord of the SAME curve,
    %                                i.e. a constant COP equal to the
    %                                full-load value at that ambient.
    %   usePWL = true, nSeg = n   -> the n-segment PWL.
    % The PWL question is the SECOND against the THIRD -- same curve, same
    % level, differing only in shape. Comparing the third against the legacy
    % constant would measure a level change (3.2 -> ~4.8) and report it as a
    % PWL benefit, which it is not. This mirrors exactly how Case 5 isolates
    % the fuel cell's PWL with a 1-segment fit of its own curve.
    % DEFAULT IS OFF, AND THE GATE IS WHY. main_month4i measures the
    % n-segment PWL against a 1-segment chord of the same curve over 60
    % paired draws: pooled -0.063% with a 95% interval of [-0.352, +0.226],
    % i.e. indistinguishable from zero, against a cost of 96 extra binaries
    % per day-ahead solve and +16% closed-loop solve time. Curvature-placed
    % breakpoints do not rescue it either (-0.137%, [-0.580, +0.307]). By this
    % project's own decision rule that is not worth shipping, so the
    % default keeps the legacy constant and every pre-existing result
    % reproduces exactly. The curve and its measurement remain available --
    % set usePWL = true to enable them -- and the seasonal breakdown is the
    % interesting part: PWL pays in winter and at the shoulder and is a
    % RELIABLE COST in summer, because the heat pump then serves only a
    % hot-water baseline and sits inside segment 1 where a uniform fit is
    % at its most optimistic.
    % The gate figures quoted above were measured at nSegments = 5. This
    % moves to 10 WITH the fuel cell -- both devices together, because a
    % mixed default would make every downstream comparison ambiguous about
    % which device's resolution produced a difference. The gate is re-run at
    % 10 and the before/after is in VALIDATION.md; the slope check is
    % re-verified rather than assumed, and hp.needsBinaries still returns
    % true in every season (the rise from segment 1 is LARGER at 10, 1.80
    % against 0.32 at the shoulder, because a finer grid resolves the
    % low-load cycling penalty instead of averaging it away).
    p.HeatPump.usePWL      = false;
    p.HeatPump.nSegments   = 10;
    p.HeatPump.copRated_func = @(T) 3.8926 + 0.1311*T;   % LS line through the datasheet
    p.HeatPump.partLoad_func = @(u) (1.25 - 0.25*u) .* (1 - exp(-u/0.08));
    % Breakpoint placement. 'uniform' matches the fuel cell's treatment and
    % is the default so the two devices are compared like with like;
    % 'curvature' concentrates breakpoints where the curve bends most and is
    % measured against it in main_month4i.
    p.HeatPump.placement   = 'uniform';
    p.HeatPump.ambientMinC = -7.0;   % datasheet range; extrapolation refused
    p.HeatPump.ambientMaxC =  7.0;
    p.HeatPump.Pmax = 8.0 * k;  % kW electrical (deliberately undersized relative
                              % to peak heat demand, so it cannot single-
                              % handedly cover every hour -- thermal storage
                              % and the fuel cell keep a genuine role)

    % ---------------------------------------------------------------
    % GRID-FACING INVERTER: apparent-power rating and reactive capability.
    %
    % Until now the hub was modelled at unity power factor -- it had no Q
    % variable at all. That is not a conservative assumption, it is an
    % unrealistic one: real PV, battery and fuel-cell inverters exchange
    % reactive power, and modelling them without it removes the only
    % mechanism by which the hub could support voltage.
    %
    % SIZING BASIS. The grid-facing inverter must carry the hub's peak net
    % active exchange. Taken as the NON-COINCIDENT connected load, the same
    % basis feeder_capacity.m uses for the connection itself:
    %     45 kW peak electrical demand (forecast_profiles.m)
    %   + 40 kW EV charger      (p.EV.Pch_max)
    %   + 30 kW battery charger (p.Batt.Pch_max)
    %   +  8 kW heat pump       (p.HeatPump.Pmax)
    %   = 123 kW
    % all at hubScale = 1, and multiplied by hubScale like every other
    % rating -- the four terms it sums are themselves scaled, so writing it
    % as 123*k keeps the inverter consistent with the equipment behind it.
    % Actual peak import is lower (~104 kW at hubScale = 1), so in practice
    % the inverter usually has MORE reactive headroom than the sizing case
    % implies -- stated so the capability is not silently overstated.
    %
    % OVERSIZING FACTOR, and why it is 1.15 rather than a round guess:
    % delivering the IEEE 1547 Category B reactive capability (0.44 S) at
    % the same time as rated active power requires
    %     S >= P / sqrt(1 - 0.44^2) = 1.114 * P.
    % 1.15 is the smallest sensible margin above that algebraic minimum,
    % so the rating is set by the standard's own requirement rather than
    % chosen to produce a result.
    p.Inverter.P_design_kW   = 123.0 * k;
    p.Inverter.oversize      = 1.15;
    p.Inverter.S_max         = p.Inverter.oversize * p.Inverter.P_design_kW;  % kVA
    %
    % REACTIVE LIMIT -- IEEE Std 1547-2018, Clause 5.2 (reactive power
    % capability), Category B: the DER shall be capable of INJECTING and
    % ABSORBING at least 44% of its nameplate apparent power rating. The
    % 44% figure corresponds to 0.90 power factor at rated active power.
    % (Category A requires 44% injection but only 25% absorption; Category
    % B is the symmetric one and is what applies to DER expected to provide
    % voltage support.) Verified against the standard's published clause
    % summaries rather than assumed.
    p.Inverter.QmaxFrac = 0.44;
    p.Inverter.Q_max    = p.Inverter.QmaxFrac * p.Inverter.S_max;   % kvar, both directions
    %
    % Apparent-power limit P^2 + Q^2 <= S^2 is a CIRCLE and cannot enter a
    % MILP. It is linearized as a regular polygon inscribed in that circle
    % (see dayahead_dispatch.m). An inscribed polygon lies strictly inside
    % the true limit, so the model slightly UNDER-uses the inverter -- the
    % safe direction. With 12 sides the worst-case shortfall is
    % 1 - cos(pi/12) = 3.4% of rated apparent power.
    p.Inverter.nPolygonSides = 12;
    %
    % Q CARRIES A DELIBERATELY TINY PRICE, AND HERE IS WHY IT IS NOT A
    % TUNING KNOB. Reactive power has no energy cost, so with no voltage
    % constraint active the optimizer is INDIFFERENT to Q -- every value is
    % equally optimal and glpk returns an arbitrary vertex (observed: Q
    % pinned at exactly -Q_max -- -62.24 kvar at the hub size then in use,
    % i.e. full absorption -- in all 24 hours, which would
    % have silently DEGRADED voltage in every verify-only result). A model
    % whose network output depends on solver tie-breaking is not
    % reporting physics.
    %
    % The tie is broken toward Q = 0, which is both physically and
    % normatively right: reactive current causes real (if small) inverter
    % conduction loss, and IEEE 1547-2018's DEFAULT operating mode is
    % constant power factor at unity -- a compliant inverter supplies Q
    % when there is a reason to, not by default. The coefficient below is
    % sized to be a tie-breaker ONLY; its total effect on daily cost is
    % printed by main_month3 so the reader can confirm it is not doing
    % real work. When a voltage constraint IS active, the network benefit
    % dominates this term by orders of magnitude and Q moves freely.
    %
    % NOT scaled with hub size: it is a PRICE ($/kvarh), and the reactive
    % energy it multiplies scales with the hub anyway, so the term keeps
    % the same relative weight against the (also-scaling) energy cost
    % without any adjustment. Scaling it would change the tie-break
    % strength, which is exactly what must not happen.
    p.Inverter.Qcost = 1e-4;   % $/kvarh, tie-breaker toward unity power factor

    % Battery Energy Storage
    % (Emax/Pch_max/Pdis_max are EXTENSIVE and scale with hub size;
    %  efficiencies, the SOC band and self-discharge are INTENSIVE and do not.)
    p.Batt.eta_ch    = 0.95;
    p.Batt.eta_dis   = 0.95;
    p.Batt.Emax      = 100.0 * k;  % kWh
    p.Batt.SOCmin    = 0.10;
    p.Batt.SOCmax    = 0.90;
    p.Batt.SOC0      = 0.50;
    p.Batt.Pch_max   = 30.0 * k;   % kW
    p.Batt.Pdis_max  = 30.0 * k;   % kW
    p.Batt.selfLoss  = 0.002;  % per hour, negligible self-discharge

    % EV fleet / depot (aggregate of several vehicles), V2G capable
    p.EV.eta_ch   = 0.90;
    p.EV.eta_dis  = 0.90;
    p.EV.Emax     = 200.0 * k;     % kWh
    p.EV.SOCmin   = 0.20;
    p.EV.SOCmax   = 0.95;
    p.EV.SOC0     = 0.50;
    p.EV.Pch_max  = 40.0 * k;      % kW
    p.EV.Pdis_max = 40.0 * k;      % kW
    p.EV.selfLoss = 0.002;
    % Plugged-in hours (evening/overnight, away during the working day)
    p.EV.pluggedInHours = [1 2 3 4 5 6 7 19 20 21 22 23 24];

    % Generalized storage #1: building thermal mass (serves Heat_Bus)
    p.Building.eta_ch   = 0.92;
    p.Building.eta_dis  = 0.92;
    p.Building.Emax     = 30.0 * k;  % kWh equivalent = C_th(15 kWh/C) * (Tmax-Tmin=2C)
                                     % -- a bigger hub is a bigger building, so the
                                     % thermal capacitance C_th scales, not the 2 C
                                     % comfort band (which is a comfort standard)
    p.Building.SOCmin   = 0.05;
    p.Building.SOCmax   = 0.95;
    p.Building.SOC0     = 0.50;
    p.Building.Pch_max  = 10.0 * k;  % kW, extra heating modulation available
    p.Building.Pdis_max = 10.0 * k;  % kW, heating reduction while coasting
    p.Building.selfLoss = 0.15;   % per hour (~7h thermal time constant)

    % Generalized storage #2: district-heating pipe/network thermal
    % storage (serves Heat_Bus) -- larger, slower, better insulated
    p.Pipe.eta_ch   = 0.97;
    p.Pipe.eta_dis  = 0.97;
    p.Pipe.Emax     = 80.0 * k;   % kWh
    p.Pipe.SOCmin   = 0.05;
    p.Pipe.SOCmax   = 0.95;
    p.Pipe.SOC0     = 0.50;
    p.Pipe.Pch_max  = 20.0 * k;   % kW
    p.Pipe.Pdis_max = 20.0 * k;   % kW
    p.Pipe.selfLoss = 0.04;   % per hour (~25h time constant, well insulated)

    % Economics -- THREE NAMED HYDROGEN-PRICE SCENARIOS.
    %
    % Hydrogen cost is the single parameter that decides whether the fuel
    % cell runs at all, and it is currently changing fast, so this project
    % treats it as a deliberate scenario axis rather than one fixed
    % number. Every point is anchored to a published figure and quoted per
    % kg as well as per kWh, because the hydrogen literature prices in
    % $/kg while this dispatch model works in $/kWh of fuel energy.
    % Conversion uses hydrogen's LOWER heating value, 120 MJ/kg =
    % 33.3 kWh/kg.
    %
    % PRODUCTION GATE vs. DELIVERED -- the distinction that makes three
    % scenarios necessary rather than two. DOE's headline hydrogen cost
    % targets are PRODUCTION targets: the Bipartisan Infrastructure Law's
    % Clean Hydrogen Electrolysis Program funds "$2/kg clean hydrogen from
    % electrolysis by 2026", and the Hydrogen Shot's $1/kg by 2031 is
    % likewise the cost of PRODUCING hydrogen. Neither includes
    % compression, storage, transport or dispensing. DOE tracks delivered
    % cost separately and with much larger numbers -- its dispensed-cost
    % target for heavy-duty vehicles is $7/kg by 2028, i.e. several times
    % the production target for the same era. A fuel cell in a building
    % pays a DELIVERED price, so comparing today's delivered cost against
    % a future production-gate cost would overstate the improvement by
    % silently switching basis mid-comparison. Hence:
    %
    %   H2_today $0.22/kWh = $7.33/kg -- DELIVERED to an end user today.
    %       DOE puts hydrogen produced from renewable energy at roughly
    %       $5/kg at the production gate; delivery/compression/dispensing
    %       put the delivered cost meaningfully above that.
    %   H2_doeTargetDelivered $2.93/kg -- the LIKE-FOR-LIKE target, and
    %       the one to compare against H2_today. It is DOE's $2/kg 2026
    %       production target carried to the meter using this file's own
    %       implied delivery markup ($7.33 delivered / $5.00 production =
    %       1.465x), derived in code below so the basis is auditable
    %       rather than a magic constant. This assumes stationary delivery
    %       costs scale like today's; DOE's $7/kg vehicle-dispensing
    %       target covers a different, costlier pathway (700-bar fuelling
    %       stations), so it is not the right analogue for a building.
    %   H2_doeTargetGate $0.06/kWh = $2.00/kg -- DOE's 2026 production
    %       target AT THE GATE, used unmodified. This is an OPTIMISTIC
    %       BOUND, not a like-for-like comparison: it is what a fuel cell
    %       would pay only if delivery were free. Reported alongside the
    %       delivered figure so results are bracketed by a range instead
    %       of resting on a point estimate.
    %
    % The result is a genuine sensitivity finding rather than a tuning
    % knob: at today's delivered cost the fuel cell is uneconomic against
    % grid import and the optimizer never starts it
    % (main_month3_multiscale_dispatch.m reports FC fuel = 0), while at
    % both target prices it becomes economic and runs at PART LOAD --
    % exactly the regime where the PWL/MILP part-load model earns its
    % keep. How MUCH it earns depends on how hard the fuel cell runs; see
    % Case 5 in main_month4a_case_studies.m, which reports the PWL cost
    % benefit at both target prices rather than a single number.
    p.scenarios.H2_kWhPerKg = 33.3;   % hydrogen LHV, for $/kWh <-> $/kg
    p.scenarios.H2_today    = 0.22;   % $/kWh DELIVERED (= $7.33/kg)
    p.scenarios.H2_doeTargetGate = 0.06;  % $/kWh PRODUCTION GATE (= $2.00/kg)

    % Delivery markup implied by this file's own two delivered/production
    % figures for TODAY, then applied to the gate target to put it on the
    % same delivered basis as H2_today. Derived, not hardcoded, so the
    % assumption is visible and auditable.
    p.scenarios.H2_prodToday_perKg = 5.00;   % DOE, renewable H2 at the production gate
    p.scenarios.H2_deliveryMarkup  = ...
        (p.scenarios.H2_today * p.scenarios.H2_kWhPerKg) / p.scenarios.H2_prodToday_perKg;
    p.scenarios.H2_doeTargetDelivered = ...
        p.scenarios.H2_doeTargetGate * p.scenarios.H2_deliveryMarkup;  % ~0.0879 $/kWh = $2.93/kg

    % Default = today's price, so every existing result (Cases 1-4, the
    % sensitivity sweeps) is unchanged by the introduction of the
    % scenario names above.
    p.price_H2 = p.scenarios.H2_today;  % $/kWh fuel

    % Reserve-margin robustness proxy for day-ahead scheduling: required
    % headroom as a fraction of that hour's forecast, must be covered by
    % UNUSED storage charge/discharge capability (see dayahead_dispatch.m).
    p.reserve.elecLoadFrac  = 0.10;
    p.reserve.solarFrac     = 0.15;
    p.reserve.heatLoadFrac  = 0.15;

    % Carbon intensity, for the case-study emissions comparison
    % (main_case_studies.m). Grid factor is a typical national-average
    % grid mix; H2 reflects a low-carbon (e.g. partly electrolytic)
    % supply, well below grid average but not zero.
    p.co2.gridFactor = 0.40;  % kgCO2/kWh electricity (net import - export)
    p.co2.H2Factor   = 0.15;  % kgCO2/kWh H2 fuel

    % Conventional baseline (Case 1 in main_case_studies.m): no PV/FC/heat
    % pump/storage at all -- electricity 100% from grid, heat from a
    % simple gas boiler. Represents the "before energy hub" reference
    % point the whole thesis is measured against.
    p.Boiler.eta      = 0.90;   % thermal efficiency
    p.Boiler.priceGas = 0.08;   % $/kWh fuel
    p.Boiler.co2Gas   = 0.20;   % kgCO2/kWh fuel (natural gas combustion)

    % Reliability check: assumed contracted feeder import/export capacity
    % (main_month4a/4b + reliability_check.m). HOW THIS THRESHOLD IS SET
    % MATTERS METHODOLOGICALLY, so it is an explicit switch rather than a
    % hardcoded rule:
    %
    %   'design' (DEFAULT) -- capacity sized the way a real connection is
    %       sized: from the installation's own CONNECTED LOAD and a
    %       diversity factor, both exogenous inputs. Nothing about any
    %       dispatch STRATEGY enters it, so no case is scored against a
    %       threshold it defined. This is the honest basis and is the
    %       default.
    %   'case4' -- the previous behaviour: feederCapMargin x Case 4's own
    %       day-ahead peak import. Retained ONLY so the two can be
    %       compared side by side, because it is self-favourable: it
    %       measures the proposed system against a line the proposed
    %       system draws. main_month4a prints both.
    %
    % Design basis = diversityFactor x (peak electrical demand + EV
    % charger + battery charger + heat pump nameplate ratings). The
    % non-coincident sum is what the connection must physically be able
    % to serve; the diversity factor is standard LV practice recognising
    % that not every load peaks simultaneously. 0.85 is a mid-to-high
    % value appropriate here because this hub aggregates only a FEW LARGE
    % controllable loads (one EV depot, one battery, one heat pump)
    % rather than many small independent ones -- coincidence is high when
    % there is little to average over. The factor is justified by the
    % load composition, not chosen to produce a particular reliability
    % result; main_month4a additionally sweeps the threshold so its
    % sensitivity is visible rather than assumed away.
    p.reliability.capBasis        = 'design';
    p.reliability.diversityFactor = 0.85;
    p.reliability.feederCapMargin = 1.0;   % used only by the 'case4' basis
end
