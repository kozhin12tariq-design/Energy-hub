function p = multiscale_default_params()
%MULTISCALE_DEFAULT_PARAMS Parameters for the multi-timescale dispatch chapter.
%
%   p = MULTISCALE_DEFAULT_PARAMS()
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

    p.eta_FC_e  = 0.45;
    p.eta_FC_th = 0.35;
    p.eta_PV    = 0.97;
    % NOTE: p.eta_FC_e/p.eta_FC_th above are no longer used by the fuel
    % cell's electrical/heat balance rows in dayahead_dispatch.m /
    % intraday_dispatch.m -- those now use the segmented PWL curves in
    % p.PWL (below), fit from p.PWL.eta_FC_e_func/eta_FC_th_func. The two
    % scalars are kept only because other (unrelated) parts of the
    % codebase may still reference them for documentation/back-reference
    % purposes; they play no role in the fuel cell's dispatch physics
    % from this file onward.

    % ---------------------------------------------------------------
    % PWL (piecewise-linear) part-load efficiency model for the fuel
    % cell, embedded directly into the day-ahead/intraday MILP dispatch
    % (not just a standalone Month-2 demonstration). See
    % dayahead_dispatch.m for how the segment/ordering-binary structure
    % is built from these breakpoints.
    %
    % Both curves are S-shaped / non-concave (verified numerically: FC
    % electrical slopes at nSegments=5 are 0.4453, 0.5078, 0.4578,
    % 0.3245, 0.1146 -- segment 2's slope EXCEEDS segment 1's, so a
    % plain LP relaxation would cherry-pick segment 2 while leaving
    % segment 1 empty, reporting more electricity than the fuel cell can
    % physically produce at that fuel level. Fill-order binary variables
    % (u_1..u_{s-1} per time step) are therefore mandatory, not optional:
    % PH2_seg(k+1) <= w(k+1)*u_k and PH2_seg(k) >= w(k)*u_k forces
    % segment k+1 to stay empty until segment k is completely full.
    p.PWL.nSegments = 5;      % breakpoints per curve = nSegments+1
    p.PWL.FC_H2_max = 150;    % kW fuel, rated/maximum H2 input (shared
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
    p.HeatPump.COP  = 3.2;
    p.HeatPump.Pmax = 8.0;   % kW electrical (deliberately undersized relative
                              % to peak heat demand, so it cannot single-
                              % handedly cover every hour -- thermal storage
                              % and the fuel cell keep a genuine role)

    % Battery Energy Storage
    p.Batt.eta_ch    = 0.95;
    p.Batt.eta_dis   = 0.95;
    p.Batt.Emax      = 100.0;  % kWh
    p.Batt.SOCmin    = 0.10;
    p.Batt.SOCmax    = 0.90;
    p.Batt.SOC0      = 0.50;
    p.Batt.Pch_max   = 30.0;   % kW
    p.Batt.Pdis_max  = 30.0;   % kW
    p.Batt.selfLoss  = 0.002;  % per hour, negligible self-discharge

    % EV fleet / depot (aggregate of several vehicles), V2G capable
    p.EV.eta_ch   = 0.90;
    p.EV.eta_dis  = 0.90;
    p.EV.Emax     = 200.0;     % kWh
    p.EV.SOCmin   = 0.20;
    p.EV.SOCmax   = 0.95;
    p.EV.SOC0     = 0.50;
    p.EV.Pch_max  = 40.0;      % kW
    p.EV.Pdis_max = 40.0;      % kW
    p.EV.selfLoss = 0.002;
    % Plugged-in hours (evening/overnight, away during the working day)
    p.EV.pluggedInHours = [1 2 3 4 5 6 7 19 20 21 22 23 24];

    % Generalized storage #1: building thermal mass (serves Heat_Bus)
    p.Building.eta_ch   = 0.92;
    p.Building.eta_dis  = 0.92;
    p.Building.Emax     = 30.0;   % kWh equivalent = C_th(15 kWh/C) * (Tmax-Tmin=2C)
    p.Building.SOCmin   = 0.05;
    p.Building.SOCmax   = 0.95;
    p.Building.SOC0     = 0.50;
    p.Building.Pch_max  = 10.0;   % kW, extra heating modulation available
    p.Building.Pdis_max = 10.0;   % kW, heating reduction while coasting
    p.Building.selfLoss = 0.15;   % per hour (~7h thermal time constant)

    % Generalized storage #2: district-heating pipe/network thermal
    % storage (serves Heat_Bus) -- larger, slower, better insulated
    p.Pipe.eta_ch   = 0.97;
    p.Pipe.eta_dis  = 0.97;
    p.Pipe.Emax     = 80.0;   % kWh
    p.Pipe.SOCmin   = 0.05;
    p.Pipe.SOCmax   = 0.95;
    p.Pipe.SOC0     = 0.50;
    p.Pipe.Pch_max  = 20.0;   % kW
    p.Pipe.Pdis_max = 20.0;   % kW
    p.Pipe.selfLoss = 0.04;   % per hour (~25h time constant, well insulated)

    % Economics -- H2 priced as a mid-merit/peaking resource: cheaper than
    % peak grid import, more expensive than off-peak/shoulder, so the
    % optimizer actually has to trade off sources instead of running the
    % fuel cell as baseload 24/7.
    p.price_H2 = 0.22;  % $/kWh fuel

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
    % (main_case_studies.m / reliability_check.m), expressed as a
    % multiple of the FULL system's (Case 4) day-ahead peak import.
    % margin=1.0 models a capacity contracted EXACTLY to the submitted
    % day-ahead schedule with no slack -- a realistic demand-charge /
    % capacity-market scenario, and deliberately tight enough that
    % coordination and robustness failures (Cases 2-3) show up as actual
    % violations rather than being absorbed by generous headroom.
    p.reliability.feederCapMargin = 1.0;
end
