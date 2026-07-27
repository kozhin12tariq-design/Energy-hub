function [actual, SOCbattNext, info] = realtime_balance(p, SOCbattNow, reference, actualSolarAvail, actualLelec, priceImport, priceExport)
%REALTIME_BALANCE Fast 5-minute correction against actual realized conditions.
%
%   [actual, SOCbattNext, info] = REALTIME_BALANCE(p, SOCbattNow, reference, ...
%       actualSolarAvail, actualLelec, priceImport, priceExport)
%
%   Real-time balancing only re-dispatches the ELECTRICAL carrier, and
%   only the fast-responding resources (grid interchange and the
%   battery) -- matching real grid-operator practice, where sub-minute
%   balancing draws on batteries/AGC-capable plant, not on slower
%   assets. The fuel cell, heat pump, EV charging, and both generalized
%   thermal storages are held at intraday's committed setpoint (`reference`);
%   any heat-side mismatch between the committed plan and the actual
%   5-minute heat demand is physically absorbed by the buildings' and
%   pipe network's own thermal inertia rather than requiring an
%   explicit fast heat correction -- thermal systems do not need
%   sub-minute balancing the way electricity does.
%
%   Minimizes actual energy cost plus a heavy penalty (via L1 slacks)
%   for deviating grid/battery dispatch away from the intraday reference
%   -- a small, fast correction, not a full re-optimization.
%
%   Inputs
%     p                : multiscale_default_params() struct
%     SOCbattNow        : current battery SOC (scalar)
%     reference         : struct, intraday's committed setpoint for this
%                         15-min slot (same fields as intraday_dispatch's
%                         `committed` output)
%     actualSolarAvail, actualLelec : actual realized values for this
%                         5-minute sub-step
%     priceImport, priceExport      : $/kWh for this sub-step
%
%   Outputs
%     actual      : struct (Pg_imp, Pg_exp, Ps, Pbatt_ch, Pbatt_dis, plus
%                   the held-fixed PH2/Php/Pev_*/Pbld_*/Ppipe_* copied
%                   through from `reference`) -- the dispatch actually
%                   executed this 5-minute step
%     SOCbattNext : battery SOC after this step
%     info        : status, cost, imbalance corrected (kW)

    dt = 1/12; % 5 minutes
    GRID_CAP = 1000;
    trackWeight = 50;

    % variables: [Pg_imp Pg_exp Ps Pbatt_ch Pbatt_dis  slackGi+ slackGi- slackGe+ slackGe- slackBc+ slackBc- slackBd+ slackBd-]
    IDX = struct('Pgi',1,'Pge',2,'Ps',3,'Bch',4,'Bdis',5, ...
                  'sGiP',6,'sGiN',7,'sGeP',8,'sGeN',9,'sBcP',10,'sBcN',11,'sBdP',12,'sBdN',13);
    nVar = 13;

    lb = zeros(nVar,1);
    ub = zeros(nVar,1);
    ub(IDX.Pgi) = GRID_CAP; ub(IDX.Pge) = GRID_CAP;
    ub(IDX.Ps)  = actualSolarAvail;
    ub(IDX.Bch) = p.Batt.Pch_max; ub(IDX.Bdis) = p.Batt.Pdis_max;
    ub(IDX.sGiP:IDX.sBdN) = Inf;

    c = zeros(nVar,1);
    c(IDX.Pgi) = priceImport*dt;
    c(IDX.Pge) = -priceExport*dt;
    c([IDX.sGiP IDX.sGiN IDX.sGeP IDX.sGeN IDX.sBcP IDX.sBcN IDX.sBdP IDX.sBdN]) = trackWeight;

    fixedElec = p.eta_FC_e*reference.PH2 - reference.Php + reference.Pev_dis - reference.Pev_ch;

    A = zeros(7, nVar); b = zeros(7,1); ctype = repmat('S',7,1);
    % elec balance: eta_PV*Ps + Pgi - Pge + Pbdis - Pbch + fixedElec = actualLelec
    A(1,[IDX.Ps IDX.Pgi IDX.Pge IDX.Bdis IDX.Bch]) = [p.eta_PV 1 -1 1 -1];
    b(1) = actualLelec - fixedElec;
    % tracking slack definitions: var - ref = sPos - sNeg
    A(2,[IDX.Pgi IDX.sGiP IDX.sGiN]) = [1 -1 1]; b(2) = reference.Pg_imp;
    A(3,[IDX.Pge IDX.sGeP IDX.sGeN]) = [1 -1 1]; b(3) = reference.Pg_exp;
    A(4,[IDX.Bch IDX.sBcP IDX.sBcN]) = [1 -1 1]; b(4) = reference.Pbatt_ch;
    A(5,[IDX.Bdis IDX.sBdP IDX.sBdN]) = [1 -1 1]; b(5) = reference.Pbatt_dis;

    % Battery SOC must stay within bounds after this step -- Pch/Pdis are
    % otherwise only limited by POWER rating, which is not enough on its
    % own to guarantee the resulting SOC stays feasible.
    coefCh = p.Batt.eta_ch*dt/p.Batt.Emax;
    coefDis = dt/(p.Batt.eta_dis*p.Batt.Emax);
    baseSOC = SOCbattNow*(1 - p.Batt.selfLoss*dt);
    ctype(6) = 'U'; % coefCh*Pch - coefDis*Pdis <= SOCmax - baseSOC
    A(6,[IDX.Bch IDX.Bdis]) = [coefCh -coefDis];
    b(6) = p.Batt.SOCmax - baseSOC;
    ctype(7) = 'U'; % -(coefCh*Pch - coefDis*Pdis) <= -(SOCmin - baseSOC)
    A(7,[IDX.Bch IDX.Bdis]) = [-coefCh coefDis];
    b(7) = baseSOC - p.Batt.SOCmin;

    vartype = repmat('C', nVar, 1);
    param.msglev = 0;
    [x, fval, status] = glpk(c, A, b, lb, ub, ctype, vartype, 1, param);

    info.status = status;
    info.cost = fval;

    if status ~= 0
        error('realtime_balance:infeasible', 'glpk returned status %d (not optimal).', status);
    end

    actual.Pg_imp = x(IDX.Pgi);
    actual.Pg_exp = x(IDX.Pge);
    actual.Ps     = x(IDX.Ps);
    actual.Pbatt_ch  = x(IDX.Bch);
    actual.Pbatt_dis = x(IDX.Bdis);
    actual.PH2 = reference.PH2; actual.Php = reference.Php;
    actual.Pev_ch = reference.Pev_ch; actual.Pev_dis = reference.Pev_dis;
    actual.Pbld_ch = reference.Pbld_ch; actual.Pbld_dis = reference.Pbld_dis;
    actual.Ppipe_ch = reference.Ppipe_ch; actual.Ppipe_dis = reference.Ppipe_dis;

    info.imbalanceCorrected_kW = (actual.Pg_imp - actual.Pg_exp) - (reference.Pg_imp - reference.Pg_exp);

    SOCbattNext = generalized_storage_soc_update(SOCbattNow, actual.Pbatt_ch, actual.Pbatt_dis, p.Batt, dt);
end
