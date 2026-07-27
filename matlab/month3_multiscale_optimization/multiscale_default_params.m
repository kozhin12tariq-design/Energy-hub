function p = multiscale_default_params()
%MULTISCALE_DEFAULT_PARAMS Parameters for the multi-timescale dispatch chapter.
%
%   p = MULTISCALE_DEFAULT_PARAMS()
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

    p.eta_FC_e  = 0.45;
    p.eta_FC_th = 0.35;
    p.eta_PV    = 0.97;

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
