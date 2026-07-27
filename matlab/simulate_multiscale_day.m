function res = simulate_multiscale_day(p, fc, opts)
%SIMULATE_MULTISCALE_DAY Run one simulated day through the dispatch stack.
%
%   res = SIMULATE_MULTISCALE_DAY(p, fc, opts)
%
%   Refactored out of main_multiscale_dispatch.m so the same simulation
%   can be re-run many times with different settings for the case-study
%   and sensitivity-analysis chapters, instead of duplicating the
%   385-solve orchestration loop.
%
%   opts (all optional, defaults reproduce main_multiscale_dispatch.m):
%     useIntraday  : true  (default) -> full day-ahead + rolling
%                    intraday(15-min) + real-time(5-min) closed loop.
%                    false -> OPEN LOOP: only the day-ahead LP is
%                    solved; its hourly setpoints are held FIXED and
%                    repeated across each hour's twelve 5-min sub-steps,
%                    executed against the ACTUAL realized fc.RT data
%                    with no adaptation at all. Solar use is capped at
%                    min(day-ahead's planned use, actual availability)
%                    -- a "dumb" system that also never opportunistically
%                    uses extra available solar. Grid import/export is
%                    whatever balance requires (uncapped at solve time;
%                    reliability_check.m applies a capacity limit
%                    afterward). This isolates the value of the
%                    intraday/real-time coordination layers.
%     reserveScale : 1 (default) multiplies p.reserve.* before calling
%                    dayahead_dispatch.m -- 0 disables the robust-margin
%                    proxy entirely.
%
%   Output res:
%     DA                 : day-ahead solution (dayahead_dispatch.m output)
%     Pg_imp5, Pg_exp5    : 288x1 actual 5-min grid interchange (kW)
%     PH2_5               : 288x1 actual 5-min fuel cell fuel use (kW)
%     SOCbatt5            : 288x1 battery SOC trajectory
%     ID_SOC (Batt/EV/Building/Pipe, 96x1 for closed loop; interpolated
%             day-ahead trajectory for open loop) and their bound checks
%     plannedCost, actualCost : $ over the day
%     emissions_kgCO2     : total CO2 (net grid import*gridFactor + H2*H2Factor)
%     dayaheadPeakImport  : max(DA.Pg_imp), used as the reliability capacity reference

    if nargin < 3; opts = struct(); end
    if ~isfield(opts,'useIntraday'); opts.useIntraday = true; end
    if ~isfield(opts,'reserveScale'); opts.reserveScale = 1.0; end

    pScaled = p;
    pScaled.reserve.elecLoadFrac = p.reserve.elecLoadFrac * opts.reserveScale;
    pScaled.reserve.solarFrac    = p.reserve.solarFrac    * opts.reserveScale;
    pScaled.reserve.heatLoadFrac = p.reserve.heatLoadFrac * opts.reserveScale;

    DA = dayahead_dispatch(pScaled, fc);
    if DA.status ~= 0
        error('simulate_multiscale_day:dayahead', 'Day-ahead LP did not solve to optimality (status=%d).', DA.status);
    end

    hourOf5 = ceil((1:288)/12)';
    priceImport5v = fc.DA.priceImport(hourOf5);
    priceExport5v = fc.DA.priceExport(hourOf5);

    if opts.useIntraday
        res = simulate_closed_loop(pScaled, fc, DA);
    else
        res = simulate_open_loop(pScaled, fc, DA, hourOf5);
    end

    res.DA = DA;
    res.plannedCost = DA.cost;
    res.actualCost = sum(priceImport5v.*res.Pg_imp5 - priceExport5v.*res.Pg_exp5 + p.price_H2*res.PH2_5) * (1/12);
    res.emissions_kgCO2 = sum((res.Pg_imp5 - res.Pg_exp5)*p.co2.gridFactor + res.PH2_5*p.co2.H2Factor) * (1/12);
    res.dayaheadPeakImport = max(DA.Pg_imp);
end

function res = simulate_closed_loop(p, fc, DA)
    socRef15 = struct();
    hourGrid = [0; fc.hours];
    socRef15.Batt     = interp1(hourGrid, [p.Batt.SOC0;     DA.SOCbatt'], (1:96)'*0.25, 'linear');
    socRef15.EV       = interp1(hourGrid, [p.EV.SOC0;       DA.SOCev'],   (1:96)'*0.25, 'linear');
    socRef15.Building = interp1(hourGrid, [p.Building.SOC0; DA.SOCbld'],  (1:96)'*0.25, 'linear');
    socRef15.Pipe     = interp1(hourGrid, [p.Pipe.SOC0;     DA.SOCpipe'], (1:96)'*0.25, 'linear');

    SOCstate.Batt = p.Batt.SOC0; SOCstate.EV = p.EV.SOC0;
    SOCstate.Building = p.Building.SOC0; SOCstate.Pipe = p.Pipe.SOC0;

    scenMult = [0.6, 1.0, 1.4];
    scenProb = [0.25; 0.5; 0.25];
    trackWeight = 30;

    Pg_imp5 = zeros(288,1); Pg_exp5 = zeros(288,1); PH2_5 = zeros(288,1);
    SOCbatt5 = zeros(288,1);
    ID_SOC = struct('Batt',zeros(96,1),'EV',zeros(96,1),'Building',zeros(96,1),'Pipe',zeros(96,1));
    RT_imbalance = zeros(288,1);

    for k = 1:96
        hourOfK = ceil(k/4);
        evNow = ismember(hourOfK, p.EV.pluggedInHours);
        kNext = min(k+1, 96);
        hourOfNext = ceil(kNext/4);
        evNext = ismember(hourOfNext, p.EV.pluggedInHours);

        fcNow.solar = fc.ID.solar(k); fcNow.Lelec = fc.ID.Lelec(k); fcNow.Lheat = fc.ID.Lheat(k);
        fcNow.priceImport = fc.DA.priceImport(hourOfK); fcNow.priceExport = fc.DA.priceExport(hourOfK);

        fcNextScen = struct('solar',{},'Lelec',{},'Lheat',{},'priceImport',{},'priceExport',{});
        for s = 1:3
            fcNextScen(s).solar = fc.ID.solar(kNext) * scenMult(s);
            fcNextScen(s).Lelec = fc.ID.Lelec(kNext);
            fcNextScen(s).Lheat = fc.ID.Lheat(kNext);
            fcNextScen(s).priceImport = fc.DA.priceImport(hourOfNext);
            fcNextScen(s).priceExport = fc.DA.priceExport(hourOfNext);
        end

        socRefNow.Batt = socRef15.Batt(k); socRefNow.EV = socRef15.EV(k);
        socRefNow.Building = socRef15.Building(k); socRefNow.Pipe = socRef15.Pipe(k);

        [committed, SOCafterID] = intraday_dispatch(p, SOCstate, evNow, evNext, ...
            fcNow, fcNextScen, scenProb, socRefNow, trackWeight);

        ID_SOC.Batt(k) = SOCafterID.Batt; ID_SOC.EV(k) = SOCafterID.EV;
        ID_SOC.Building(k) = SOCafterID.Building; ID_SOC.Pipe(k) = SOCafterID.Pipe;

        SOCbatt5loop = SOCstate.Batt;
        for j = 1:3
            m = (k-1)*3 + j;
            priceImport5 = fc.DA.priceImport(hourOfK); priceExport5 = fc.DA.priceExport(hourOfK);
            [actual, SOCbatt5loop, infoRT] = realtime_balance(p, SOCbatt5loop, committed, ...
                fc.RT.solar(m), fc.RT.Lelec(m), priceImport5, priceExport5);
            Pg_imp5(m) = actual.Pg_imp; Pg_exp5(m) = actual.Pg_exp; PH2_5(m) = actual.PH2;
            SOCbatt5(m) = SOCbatt5loop;
            RT_imbalance(m) = infoRT.imbalanceCorrected_kW;
        end

        SOCstate.Batt = SOCbatt5loop;
        SOCstate.EV = SOCafterID.EV;
        SOCstate.Building = SOCafterID.Building;
        SOCstate.Pipe = SOCafterID.Pipe;
    end

    res.Pg_imp5 = Pg_imp5; res.Pg_exp5 = Pg_exp5; res.PH2_5 = PH2_5;
    res.SOCbatt5 = SOCbatt5;
    res.ID_SOC = ID_SOC;
    res.RT_imbalance = RT_imbalance;
    res.mode = 'closed_loop';
end

function res = simulate_open_loop(p, fc, DA, hourOf5)
    Pg_imp5 = zeros(288,1); Pg_exp5 = zeros(288,1); PH2_5 = zeros(288,1);
    SOCbatt5 = zeros(288,1);
    ID_SOC = struct('Batt',zeros(96,1),'EV',zeros(96,1),'Building',zeros(96,1),'Pipe',zeros(96,1));

    SOC.Batt = p.Batt.SOC0; SOC.EV = p.EV.SOC0; SOC.Building = p.Building.SOC0; SOC.Pipe = p.Pipe.SOC0;
    dt = 1/12;

    for m = 1:288
        h = hourOf5(m);
        Ps_m = min(DA.Ps(h), fc.RT.solar(m));
        PH2_5(m) = DA.PH2(h);

        fixedElec = p.eta_PV*Ps_m + p.eta_FC_e*DA.PH2(h) - DA.Php(h) ...
            + DA.Pbatt_dis(h) - DA.Pbatt_ch(h) + DA.Pev_dis(h) - DA.Pev_ch(h);
        Pnet = fc.RT.Lelec(m) - fixedElec;
        Pg_imp5(m) = max(Pnet, 0);
        Pg_exp5(m) = max(-Pnet, 0);

        SOC.Batt = generalized_storage_soc_update(SOC.Batt, DA.Pbatt_ch(h), DA.Pbatt_dis(h), p.Batt, dt);
        SOC.EV   = generalized_storage_soc_update(SOC.EV,   DA.Pev_ch(h),   DA.Pev_dis(h),   p.EV, dt);
        SOC.Building = generalized_storage_soc_update(SOC.Building, DA.Pbld_ch(h), DA.Pbld_dis(h), p.Building, dt);
        SOC.Pipe = generalized_storage_soc_update(SOC.Pipe, DA.Ppipe_ch(h), DA.Ppipe_dis(h), p.Pipe, dt);
        SOCbatt5(m) = SOC.Batt;
        if mod(m,3) == 0
            k = m/3;
            ID_SOC.Batt(k) = SOC.Batt; ID_SOC.EV(k) = SOC.EV;
            ID_SOC.Building(k) = SOC.Building; ID_SOC.Pipe(k) = SOC.Pipe;
        end
    end

    res.Pg_imp5 = Pg_imp5; res.Pg_exp5 = Pg_exp5; res.PH2_5 = PH2_5;
    res.SOCbatt5 = SOCbatt5;
    res.ID_SOC = ID_SOC;
    res.RT_imbalance = zeros(288,1); % no correction layer exists in open loop
    res.mode = 'open_loop';
end
