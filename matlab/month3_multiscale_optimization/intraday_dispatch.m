function [committed, SOCnext, info] = intraday_dispatch(p, SOCnow, evAvailNow, evAvailNext, fcNow, fcNextScenarios, scenProb, socRefNow, trackWeight)
%INTRADAY_DISPATCH Rolling two-stage stochastic LP, 15-minute resolution.
%
%   [committed, SOCnext, info] = INTRADAY_DISPATCH(p, SOCnow, evAvailNow, ...
%       evAvailNext, fcNow, fcNextScenarios, scenProb, socRefNow, trackWeight)
%
%   Solves ONE small two-stage stochastic LP over a 30-minute look-ahead
%   (the current 15-min slot, "here-and-now", plus the next slot under
%   several PV/load scenarios), and returns only the current slot's
%   decision -- classic rolling/receding-horizon dispatch: called again
%   at the next 15-min slot with the actually-realized state, never
%   executing more than the first stage of any single solve.
%
%   Stage 1 (this slot, shared/non-anticipative): dispatch variables
%   using the best current ("intraday") forecast for THIS slot.
%   Stage 2 (next slot, one variable set per scenario): recourse
%   decisions that may differ per scenario, each branching from the
%   SAME stage-1 storage state -- this is what makes it a genuine
%   stochastic program rather than a deterministic expected-value LP:
%   the stage-1 decision is chosen knowing it must leave every scenario
%   feasible, not just the average one.
%
%   Coordination with day-ahead: `socRefNow` is the day-ahead SOC
%   trajectory interpolated to this slot; a soft (L1, via slack
%   variables) penalty keeps the intraday storage trajectory close to
%   the day-ahead plan without forcing an exact match, so intraday can
%   still exploit better near-term information.
%
%   Inputs
%     p               : multiscale_default_params() struct
%     SOCnow           : struct with fields Batt, EV, Building, Pipe (current SOC)
%     evAvailNow/Next   : EV plugged-in flags for this slot / next slot
%     fcNow             : struct with fields solar, Lelec, Lheat, priceImport,
%                         priceExport for THIS slot (scalars)
%     fcNextScenarios   : Nscen x 1 struct array, same fields, for the NEXT
%                         slot under each scenario
%     scenProb          : Nscen x 1 probabilities (sum to 1)
%     socRefNow         : struct (Batt,EV,Building,Pipe) day-ahead SOC
%                         reference for this slot
%     trackWeight       : penalty weight ($ per unit SOC deviation) on
%                         the day-ahead tracking term
%
%   Outputs
%     committed : struct with the stage-1 dispatch (Pg_imp, Pg_exp, PH2,
%                 Php, Ps, Pbatt_ch, Pbatt_dis, Pev_ch, Pev_dis,
%                 Pbld_ch, Pbld_dis, Ppipe_ch, Ppipe_dis) for this slot
%     SOCnext   : struct, storage state at the end of this slot
%     info      : status, cost

    dt = 0.25; % 15 minutes
    Nscen = numel(fcNextScenarios);

    NV = 17;
    OFF = struct('Pgi',1,'Pge',2,'PH2',3,'Ps',4, ...
                  'Bch',5,'Bdis',6,'Ech',7,'Edis',8, ...
                  'Lch',9,'Ldis',10,'Pch',11,'Pdis',12, ...
                  'SB',13,'SE',14,'SL',15,'SP',16, 'Php',17);
    ix = @(block, off) block*NV + off;   % block 0 = stage1, 1..Nscen = stage2 scenarios
    nCore = (1+Nscen)*NV;
    slackOff = struct('B',1,'E',2,'L',3,'P',4); % 4 devices x (pos,neg) = 8 slacks
    ixSlack = @(dev, sign) nCore + (slackOff.(dev)-1)*2 + sign; % sign: 1=pos,2=neg
    nVar = nCore + 8;

    FC_H2_max = 150; GRID_CAP = 1000;

    lb = zeros(nVar,1); ub = zeros(nVar,1);
    blocks_fc = [fcNow; fcNextScenarios(:)];
    blocks_evAvail = [evAvailNow; repmat(evAvailNext, Nscen, 1)];
    for blk = 0:Nscen
        fcb = blocks_fc(blk+1); evb = blocks_evAvail(blk+1);
        ub(ix(blk,OFF.Pgi))  = GRID_CAP;
        ub(ix(blk,OFF.Pge))  = GRID_CAP;
        ub(ix(blk,OFF.PH2))  = FC_H2_max;
        ub(ix(blk,OFF.Ps))   = fcb.solar;
        ub(ix(blk,OFF.Bch))  = p.Batt.Pch_max;
        ub(ix(blk,OFF.Bdis)) = p.Batt.Pdis_max;
        ub(ix(blk,OFF.Ech))  = p.EV.Pch_max * evb;
        ub(ix(blk,OFF.Edis)) = p.EV.Pdis_max * evb;
        ub(ix(blk,OFF.Lch))  = p.Building.Pch_max;
        ub(ix(blk,OFF.Ldis)) = p.Building.Pdis_max;
        ub(ix(blk,OFF.Pch))  = p.Pipe.Pch_max;
        ub(ix(blk,OFF.Pdis)) = p.Pipe.Pdis_max;
        ub(ix(blk,OFF.Php))  = p.HeatPump.Pmax;
        lb(ix(blk,OFF.SB)) = p.Batt.SOCmin;     ub(ix(blk,OFF.SB)) = p.Batt.SOCmax;
        lb(ix(blk,OFF.SE)) = p.EV.SOCmin;       ub(ix(blk,OFF.SE)) = p.EV.SOCmax;
        lb(ix(blk,OFF.SL)) = p.Building.SOCmin; ub(ix(blk,OFF.SL)) = p.Building.SOCmax;
        lb(ix(blk,OFF.SP)) = p.Pipe.SOCmin;     ub(ix(blk,OFF.SP)) = p.Pipe.SOCmax;
    end
    ub(nCore+1 : nVar) = Inf; % slacks

    c = zeros(nVar,1);
    c(ix(0,OFF.Pgi)) =  fcNow.priceImport*dt;
    c(ix(0,OFF.Pge)) = -fcNow.priceExport*dt;
    c(ix(0,OFF.PH2)) =  p.price_H2*dt;
    for s = 1:Nscen
        fcs = fcNextScenarios(s);
        c(ix(s,OFF.Pgi)) = scenProb(s) * fcs.priceImport*dt;
        c(ix(s,OFF.Pge)) = -scenProb(s) * fcs.priceExport*dt;
        c(ix(s,OFF.PH2)) = scenProb(s) * p.price_H2*dt;
    end
    for dv = {'B','E','L','P'}
        c(ixSlack(dv{1},1)) = trackWeight;
        c(ixSlack(dv{1},2)) = trackWeight;
    end

    rows = {}; bvals = []; ctypeList = '';
    function add_row(coefs_idx, coefs_val, type, bval)
        r = zeros(1, nVar);
        r(coefs_idx) = coefs_val;
        rows{end+1} = r; %#ok<AGROW>
        bvals(end+1) = bval; %#ok<AGROW>
        ctypeList(end+1) = type; %#ok<AGROW>
    end

    % Stage-1 balances (this slot)
    add_row([ix(0,OFF.Ps) ix(0,OFF.PH2) ix(0,OFF.Php) ix(0,OFF.Pgi) ix(0,OFF.Pge) ix(0,OFF.Bdis) ix(0,OFF.Bch) ix(0,OFF.Edis) ix(0,OFF.Ech)], ...
        [p.eta_PV p.eta_FC_e -1 1 -1 1 -1 1 -1], 'S', fcNow.Lelec);
    add_row([ix(0,OFF.PH2) ix(0,OFF.Php) ix(0,OFF.Ldis) ix(0,OFF.Lch) ix(0,OFF.Pdis) ix(0,OFF.Pch)], ...
        [p.eta_FC_th p.HeatPump.COP 1 -1 1 -1], 'S', fcNow.Lheat);

    % Stage-1 SOC recursions (from the GIVEN current state SOCnow)
    add_soc(ix(0,OFF.SB), ix(0,OFF.Bch), ix(0,OFF.Bdis), [], [], p.Batt, dt, SOCnow.Batt);
    add_soc(ix(0,OFF.SE), ix(0,OFF.Ech), ix(0,OFF.Edis), [], [], p.EV, dt, SOCnow.EV);
    add_soc(ix(0,OFF.SL), ix(0,OFF.Lch), ix(0,OFF.Ldis), [], [], p.Building, dt, SOCnow.Building);
    add_soc(ix(0,OFF.SP), ix(0,OFF.Pch), ix(0,OFF.Pdis), [], [], p.Pipe, dt, SOCnow.Pipe);

    % Day-ahead tracking slacks: SOC(stage1) - ref = slackPos - slackNeg
    add_row([ix(0,OFF.SB) ixSlack('B',1) ixSlack('B',2)], [1 -1 1], 'S', socRefNow.Batt);
    add_row([ix(0,OFF.SE) ixSlack('E',1) ixSlack('E',2)], [1 -1 1], 'S', socRefNow.EV);
    add_row([ix(0,OFF.SL) ixSlack('L',1) ixSlack('L',2)], [1 -1 1], 'S', socRefNow.Building);
    add_row([ix(0,OFF.SP) ixSlack('P',1) ixSlack('P',2)], [1 -1 1], 'S', socRefNow.Pipe);

    % Stage-2 balances + SOC recursions (per scenario, branching from stage-1 SOC)
    for s = 1:Nscen
        fcs = fcNextScenarios(s);
        add_row([ix(s,OFF.Ps) ix(s,OFF.PH2) ix(s,OFF.Php) ix(s,OFF.Pgi) ix(s,OFF.Pge) ix(s,OFF.Bdis) ix(s,OFF.Bch) ix(s,OFF.Edis) ix(s,OFF.Ech)], ...
            [p.eta_PV p.eta_FC_e -1 1 -1 1 -1 1 -1], 'S', fcs.Lelec);
        add_row([ix(s,OFF.PH2) ix(s,OFF.Php) ix(s,OFF.Ldis) ix(s,OFF.Lch) ix(s,OFF.Pdis) ix(s,OFF.Pch)], ...
            [p.eta_FC_th p.HeatPump.COP 1 -1 1 -1], 'S', fcs.Lheat);

        add_soc(ix(s,OFF.SB), ix(s,OFF.Bch), ix(s,OFF.Bdis), ix(0,OFF.SB), 1, p.Batt, dt, []);
        add_soc(ix(s,OFF.SE), ix(s,OFF.Ech), ix(s,OFF.Edis), ix(0,OFF.SE), 1, p.EV, dt, []);
        add_soc(ix(s,OFF.SL), ix(s,OFF.Lch), ix(s,OFF.Ldis), ix(0,OFF.SL), 1, p.Building, dt, []);
        add_soc(ix(s,OFF.SP), ix(s,OFF.Pch), ix(s,OFF.Pdis), ix(0,OFF.SP), 1, p.Pipe, dt, []);
    end

    A = cell2mat(rows(:));
    b = bvals(:);
    ctype = ctypeList(:);
    vartype = repmat('C', nVar, 1);

    param.msglev = 0;
    [x, fval, status] = glpk(c, A, b, lb, ub, ctype, vartype, 1, param);

    info.status = status;
    info.cost = fval;

    if status ~= 0
        error('intraday_dispatch:infeasible', 'glpk returned status %d (not optimal).', status);
    end

    committed.Pg_imp = x(ix(0,OFF.Pgi));
    committed.Pg_exp = x(ix(0,OFF.Pge));
    committed.PH2    = x(ix(0,OFF.PH2));
    committed.Php    = x(ix(0,OFF.Php));
    committed.Ps     = x(ix(0,OFF.Ps));
    committed.Pbatt_ch  = x(ix(0,OFF.Bch));  committed.Pbatt_dis  = x(ix(0,OFF.Bdis));
    committed.Pev_ch    = x(ix(0,OFF.Ech));  committed.Pev_dis    = x(ix(0,OFF.Edis));
    committed.Pbld_ch   = x(ix(0,OFF.Lch));  committed.Pbld_dis   = x(ix(0,OFF.Ldis));
    committed.Ppipe_ch  = x(ix(0,OFF.Pch));  committed.Ppipe_dis  = x(ix(0,OFF.Pdis));

    SOCnext.Batt     = x(ix(0,OFF.SB));
    SOCnext.EV       = x(ix(0,OFF.SE));
    SOCnext.Building = x(ix(0,OFF.SL));
    SOCnext.Pipe     = x(ix(0,OFF.SP));

    function add_soc(socIdx, chIdx, disIdx, prevSocIdx, prevCoef, dev, dtLocal, socPrevConst)
        coefsI = [socIdx, chIdx, disIdx];
        coefsV = [1, -dev.eta_ch*dtLocal/dev.Emax, dtLocal/(dev.eta_dis*dev.Emax)];
        if isempty(prevSocIdx)
            add_row(coefsI, coefsV, 'S', (1 - dev.selfLoss*dtLocal) * socPrevConst);
        else
            coefsI = [coefsI, prevSocIdx];
            coefsV = [coefsV, -(1 - dev.selfLoss*dtLocal) * prevCoef];
            add_row(coefsI, coefsV, 'S', 0);
        end
    end
end
