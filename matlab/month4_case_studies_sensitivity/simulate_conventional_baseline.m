function res = simulate_conventional_baseline(p, fc)
%SIMULATE_CONVENTIONAL_BASELINE Case 1: no energy hub at all.
%
%   res = SIMULATE_CONVENTIONAL_BASELINE(p, fc)
%
%   The "before" reference point: no PV, no fuel cell, no heat pump, no
%   storage of any kind. All electricity from the grid, all heat from a
%   simple gas boiler (p.Boiler.*) -- no optimization possible or needed
%   since there is nothing to schedule. Used by main_case_studies.m as
%   the baseline every other case is measured against.
%
%   Output res: Pg_imp5, Pg_exp5 (=0), PH2_5 (=0), gas5 (288x1 each),
%   actualCost, emissions_kgCO2, dayaheadPeakImport (=max 5-min import,
%   the "no self-generation" case has no separate day-ahead plan).

    Pg_imp5 = fc.RT.Lelec;
    Pg_exp5 = zeros(288,1);
    gas5 = fc.RT.Lheat / p.Boiler.eta;
    PH2_5 = zeros(288,1);

    hourOf5 = ceil((1:288)/12)';
    priceImport5v = fc.DA.priceImport(hourOf5);

    res.Pg_imp5 = Pg_imp5; res.Pg_exp5 = Pg_exp5; res.PH2_5 = PH2_5; res.gas5 = gas5;
    res.actualCost = sum(priceImport5v.*Pg_imp5 + p.Boiler.priceGas*gas5) * (1/12);
    res.emissions_kgCO2 = sum(Pg_imp5*p.co2.gridFactor + gas5*p.Boiler.co2Gas) * (1/12);
    res.plannedCost = res.actualCost; % no plan/actual distinction -- nothing is scheduled
    res.dayaheadPeakImport = max(Pg_imp5);
    res.mode = 'conventional';
end
