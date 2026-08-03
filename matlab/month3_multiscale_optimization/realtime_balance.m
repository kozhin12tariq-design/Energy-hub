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
%   sub-minute balancing the way electricity does. (There is no
%   heat-side balance row in this file at all, so the PWL fuel cell
%   change below has nothing else to touch.)
%
%   FUEL CELL PWL EVALUATION (not PWL/MILP): `reference.PH2` is already
%   a fixed number by the time real-time runs (intraday's committed
%   total fuel input, decided by dayahead/intraday's own segment+binary
%   MILP) -- it is not re-optimized here, only converted back to the
%   electricity it actually produces. The segment-splitter/binary
%   machinery in dayahead_dispatch.m/intraday_dispatch.m exists to solve
%   an OPTIMIZATION over an unknown PH2; here PH2 is already known, so
%   the exact nonlinear curve value is obtained directly via
%   pwl_utils('eval', ...) (linear interpolation between the same fitted
%   breakpoints) instead of the old flat p.eta_FC_e multiplier, with no
%   need for segment variables or ordering binaries.
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
    % Reactive power and the network constraint are opt-in here exactly as
    % in the slower layers. Real time is the LAST place the schedule can be
    % altered, so if it is network-blind the voltage compliance the
    % day-ahead plan was solved for can be undone in the final 5 minutes.
    useQ   = isfield(p, 'Inverter');
    useNet = isfield(p, 'network') && isfield(p.network, 'enabled') && p.network.enabled;
    % Vsl is a single non-negative slack on the voltage floor. Real time
    % MUST balance the actual load with almost no degrees of freedom (fuel
    % cell, heat pump and EV are held at the intraday setpoint), so a HARD
    % voltage floor here is genuinely infeasible whenever realized demand
    % exceeds what the floor permits -- verified: glpk returns status 10.
    % A real controller cannot refuse to serve load either; it does its
    % best and accepts the excursion. The floor is therefore SOFT at this
    % level, with a penalty large enough to dominate energy cost so it is
    % respected whenever it CAN be, and the residual violation is
    % reported rather than hidden by an infeasible solve.
    % Optional variables are appended dynamically -- hardcoding their
    % indices breaks as soon as one of the two options is off.
    nextIdx = 14;
    if useQ;   IDX.Qh = nextIdx; IDX.Qa = nextIdx+1; nextIdx = nextIdx+2; end
    if useNet; IDX.Vsl = nextIdx;                    nextIdx = nextIdx+1; end
    nVar = nextIdx - 1;
    vPenalty = 1e4;   % $ per unit of (row-normalised) voltage shortfall

    lb = zeros(nVar,1);
    ub = zeros(nVar,1);
    ub(IDX.Pgi) = GRID_CAP; ub(IDX.Pge) = GRID_CAP;
    ub(IDX.Ps)  = actualSolarAvail;
    ub(IDX.Bch) = p.Batt.Pch_max; ub(IDX.Bdis) = p.Batt.Pdis_max;
    ub(IDX.sGiP:IDX.sBdN) = Inf;
    if useQ
        lb(IDX.Qh) = -p.Inverter.Q_max;
        ub(IDX.Qh) =  p.Inverter.Q_max;
        ub(IDX.Qa) =  p.Inverter.Q_max;
    end

    c = zeros(nVar,1);
    c(IDX.Pgi) = priceImport*dt;
    c(IDX.Pge) = -priceExport*dt;
    c([IDX.sGiP IDX.sGiN IDX.sGeP IDX.sGeN IDX.sBcP IDX.sBcN IDX.sBdP IDX.sBdN]) = trackWeight;
    if useQ; c(IDX.Qa) = p.Inverter.Qcost*dt; end
    if useNet; c(IDX.Vsl) = vPenalty; ub(IDX.Vsl) = Inf; end

    fcElec = pwl_utils('eval', p.PWL.bkpt_e.x, p.PWL.bkpt_e.y, reference.PH2);
    fixedElec = fcElec - reference.Php + reference.Pev_dis - reference.Pev_ch;

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

    % Inverter apparent-power polygon, |Q| definition and (opt-in) the
    % LinDistFlow voltage floor. Appended as extra 'U' rows so the fixed
    % 7-row block above is untouched.
    if useQ
        Npoly = p.Inverter.nPolygonSides;
        rhsS  = p.Inverter.S_max * cos(pi/Npoly);
        for kk = 1:Npoly
            th = 2*pi*(kk-1)/Npoly;
            % sin(pi)=1.22e-16 in floating point, not 0. Left in place it
            % gives glpk a ~1e16 coefficient ratio and spurious "no primal
            % feasible solution" errors -- see dayahead_dispatch.m.
            cth = cos(th); if abs(cth) < 1e-12; cth = 0; end
            sth = sin(th); if abs(sth) < 1e-12; sth = 0; end
            rr = zeros(1,nVar);
            rr([IDX.Pgi IDX.Pge IDX.Qh]) = [cth -cth sth];
            A(end+1,:) = rr; b(end+1) = rhsS; ctype(end+1) = 'U';
        end
        rr = zeros(1,nVar); rr([IDX.Qh IDX.Qa]) = [ 1 -1];
        A(end+1,:) = rr; b(end+1) = 0; ctype(end+1) = 'U';
        rr = zeros(1,nVar); rr([IDX.Qh IDX.Qa]) = [-1 -1];
        A(end+1,:) = rr; b(end+1) = 0; ctype(end+1) = 'U';
    end
    if useNet
        hasB = useQ && isfield(p.network,'b') && ~isempty(p.network.b);
        for bi = 1:numel(p.network.buses)
            % ROW SCALING IS NOT COSMETIC HERE. Voltage sensitivities are
            % O(1e-5) pu/kW while the power-balance rows are O(1), so an
            % unscaled voltage row leaves the constraint matrix with a
            % condition number around 1e7. glpk then returns "no primal
            % feasible solution" on problems that are plainly feasible --
            % observed as a scattered, non-monotone failure pattern that
            % looked like infeasibility but was purely numerical.
            % Normalising each row to unit largest coefficient (an exact
            % rescaling, same feasible set) removes it.
            aRow = -p.network.a(bi);
            bRow = 0;
            if hasB; bRow = p.network.b(bi); end
            sc = max(abs([aRow bRow]));
            if sc <= 0; sc = 1; end
            rr = zeros(1,nVar);
            rr([IDX.Pgi IDX.Pge]) = [aRow -aRow] / sc;
            if hasB; rr(IDX.Qh) = bRow / sc; end
            rr(IDX.Vsl) = -1;      % soft: slack absorbs an unavoidable shortfall
            A(end+1,:) = rr;
            b(end+1) = (p.network.C(bi) - p.network.Vfloor(bi)) / sc;
            ctype(end+1) = 'U';
        end
    end

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
    if useQ; actual.Qh = x(IDX.Qh); else; actual.Qh = 0; end
    if useNet; info.vShortfall_pu = x(IDX.Vsl); else; info.vShortfall_pu = 0; end
    actual.PH2 = reference.PH2; actual.Php = reference.Php;
    actual.Pev_ch = reference.Pev_ch; actual.Pev_dis = reference.Pev_dis;
    actual.Pbld_ch = reference.Pbld_ch; actual.Pbld_dis = reference.Pbld_dis;
    actual.Ppipe_ch = reference.Ppipe_ch; actual.Ppipe_dis = reference.Ppipe_dis;

    info.imbalanceCorrected_kW = (actual.Pg_imp - actual.Pg_exp) - (reference.Pg_imp - reference.Pg_exp);

    SOCbattNext = storage_soc_update(SOCbattNow, actual.Pbatt_ch, actual.Pbatt_dis, p.Batt, dt);
end
