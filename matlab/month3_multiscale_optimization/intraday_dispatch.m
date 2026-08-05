function [committed, SOCnext, info] = intraday_dispatch(p, SOCnow, evAvailNow, evAvailNext, fcNow, fcNextScenarios, scenProb, socRefNow, trackWeight)
%INTRADAY_DISPATCH Rolling two-stage stochastic MILP, 15-minute resolution.
%
%   [committed, SOCnext, info] = INTRADAY_DISPATCH(p, SOCnow, evAvailNow, ...
%       evAvailNext, fcNow, fcNextScenarios, scenProb, socRefNow, trackWeight)
%
%   Solves ONE small two-stage stochastic program over a 30-minute look-ahead
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
%   FUEL CELL PWL/MILP EMBEDDING: same segment-splitter + concentrator +
%   fill-order-binary structure as dayahead_dispatch.m (see that file's
%   header for the full derivation), applied independently to EVERY
%   block -- stage 1 and each of the Nscen stage-2 scenarios -- since
%   each block makes its own fuel cell dispatch decision. PV keeps a
%   constant efficiency (p.eta_PV) here too; only the fuel cell is
%   PWL/MILP. This makes the intraday re-solve a genuine MILP rather
%   than the pure LP it used to be.
%
%   Coordination with day-ahead: `socRefNow` is the day-ahead SOC
%   trajectory interpolated to this slot; a soft (L1, via slack
%   variables) penalty keeps the intraday storage trajectory close to
%   the day-ahead plan without forcing an exact match, so intraday can
%   still exploit better near-term information.
%
%   Inputs
%     p               : multiscale_default_params() struct (uses p.PWL.*)
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
%     committed : struct with the stage-1 dispatch (Pg_imp, Pg_exp, PH2
%                 [= segment total], PH2seg [1 x nSegments, diagnostic],
%                 Php, Ps, Pbatt_ch, Pbatt_dis, Pev_ch, Pev_dis,
%                 Pbld_ch, Pbld_dis, Ppipe_ch, Ppipe_dis) for this slot
%     SOCnext   : struct, storage state at the end of this slot
%     info      : status, cost

    dt = 0.25; % 15 minutes
    Nscen = numel(fcNextScenarios);

    s = p.PWL.nSegments;
    bkE = p.PWL.bkpt_e; bkT = p.PWL.bkpt_th;
    w = diff(bkE.x);              % 1 x s segment widths (shared by both curves)
    slopeE = diff(bkE.y) ./ w;    % 1 x s electrical slope per segment
    slopeT = diff(bkT.y) ./ w;    % 1 x s thermal slope per segment

    % Per-block variables: 16 fixed + PH2total(1) + PH2seg(1..s) + u(1..s-1)
    % Reactive power + network constraint, opt-in exactly as in
    % dayahead_dispatch.m. Without these the intraday layer is
    % network-blind and can undo the day-ahead plan's voltage compliance.
    useQ = isfield(p, 'Inverter');
    nQ   = useQ * 2;                      % Qh and Qabs per block
    useNet = isfield(p, 'network') && isfield(p.network, 'enabled') && p.network.enabled;

    % Heat-pump PWL, same structure and the same opt-in switch as the
    % day-ahead layer. The curve depends on the day's ambient temperature,
    % which the caller passes through fcNow.ambientC (simulate_multiscale_day
    % copies it from the forecast); absent it, heatpump_curve defaults to the
    % shoulder ambient.
    useHP = isfield(p.HeatPump, 'usePWL') && p.HeatPump.usePWL;
    if useHP
        if isfield(fcNow, 'ambientC'); ambHP = fcNow.ambientC; else; ambHP = []; end
        hp     = heatpump_curve(p, ambHP);
        sHP    = hp.nSegments;
        wHP    = hp.w;
        copSeg = hp.slopes;
        nHPu   = hp.needsBinaries * (sHP - 1);
    else
        sHP = 0; wHP = []; copSeg = []; nHPu = 0;
    end

    NV = 16 + 1 + s + (s-1) + nQ + sHP + nHPu;
    OFF = struct('Pgi',1,'Pge',2,'Ps',3, ...
                  'Bch',4,'Bdis',5,'Ech',6,'Edis',7, ...
                  'Lch',8,'Ldis',9,'Pch',10,'Pdis',11, ...
                  'SB',12,'SE',13,'SL',14,'SP',15,'Php',16,'PH2tot',17);
    segBase = 17; uBase = 17 + s;
    qOff  = 17 + s + (s-1) + 1;
    qaOff = qOff + 1;
    hpSegBase = 17 + s + (s-1) + nQ;
    hpUBase   = hpSegBase + sHP;
    ix    = @(block, off) block*NV + off;   % block 0 = stage1, 1..Nscen = stage2 scenarios
    ixSeg = @(block, k)   ix(block, segBase+k);
    ixU   = @(block, k)   ix(block, uBase+k);
    ixQ   = @(block)      ix(block, qOff);
    ixQa  = @(block)      ix(block, qaOff);
    ixHP  = @(block, k)   ix(block, hpSegBase+k);
    ixHPu = @(block, k)   ix(block, hpUBase+k);
    nCore = (1+Nscen)*NV;
    slackOff = struct('B',1,'E',2,'L',3,'P',4); % 4 devices x (pos,neg) = 8 slacks
    ixSlack = @(dev, sign) nCore + (slackOff.(dev)-1)*2 + sign; % sign: 1=pos,2=neg
    nVar = nCore + 8;

    % Nominally-unbounded grid exchange; scales with the hub so it stays a
    % placeholder instead of becoming a silent import limit (hub_scale_of.m).
    GRID_CAP = 1000 * hub_scale_of(p);

    lb = zeros(nVar,1); ub = zeros(nVar,1);
    blocks_fc = [fcNow; fcNextScenarios(:)];
    blocks_evAvail = [evAvailNow; repmat(evAvailNext, Nscen, 1)];
    for blk = 0:Nscen
        fcb = blocks_fc(blk+1); evb = blocks_evAvail(blk+1);
        ub(ix(blk,OFF.Pgi))  = GRID_CAP;
        ub(ix(blk,OFF.Pge))  = GRID_CAP;
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
        for k = 1:sHP;  ub(ixHP(blk,k))  = wHP(k); end
        for k = 1:nHPu; ub(ixHPu(blk,k)) = 1;      end
        if useQ
            lb(ixQ(blk))  = -p.Inverter.Q_max;
            ub(ixQ(blk))  =  p.Inverter.Q_max;
            ub(ixQa(blk)) =  p.Inverter.Q_max;
        end
        ub(ix(blk,OFF.PH2tot)) = bkE.x(end);
        lb(ix(blk,OFF.SB)) = p.Batt.SOCmin;     ub(ix(blk,OFF.SB)) = p.Batt.SOCmax;
        lb(ix(blk,OFF.SL)) = p.Building.SOCmin; ub(ix(blk,OFF.SL)) = p.Building.SOCmax;
        lb(ix(blk,OFF.SP)) = p.Pipe.SOCmin;     ub(ix(blk,OFF.SP)) = p.Pipe.SOCmax;
        % EV: the usable band applies only while the fleet is plugged in.
        % Away from the charger its SOC is pure decay with no decision in
        % it, and imposing SOCmin there makes the MILP infeasible the
        % moment the previous slot leaves the state on the bound. See
        % ev_soc_bounds.m for the full account.
        [lb(ix(blk,OFF.SE)), ub(ix(blk,OFF.SE))] = ev_soc_bounds(p, evb);
        for k = 1:s
            ub(ixSeg(blk,k)) = w(k);
        end
        for k = 1:(s-1)
            ub(ixU(blk,k)) = 1;
        end
    end
    ub(nCore+1 : nVar) = Inf; % slacks

    c = zeros(nVar,1);
    c(ix(0,OFF.Pgi))    =  fcNow.priceImport*dt;
    c(ix(0,OFF.Pge))    = -fcNow.priceExport*dt;
    c(ix(0,OFF.PH2tot)) =  p.price_H2*dt;
    for s_ = 1:Nscen
        fcs = fcNextScenarios(s_);
        c(ix(s_,OFF.Pgi))    = scenProb(s_) * fcs.priceImport*dt;
        c(ix(s_,OFF.Pge))    = -scenProb(s_) * fcs.priceExport*dt;
        c(ix(s_,OFF.PH2tot)) = scenProb(s_) * p.price_H2*dt;
    end
    for dv = {'B','E','L','P'}
        c(ixSlack(dv{1},1)) = trackWeight;
        c(ixSlack(dv{1},2)) = trackWeight;
    end
    if useQ
        c(ixQa(0)) = p.Inverter.Qcost*dt;      % unity-pf tie-breaker
        for s_ = 1:Nscen
            c(ixQa(s_)) = scenProb(s_) * p.Inverter.Qcost*dt;
        end
    end

    rows = {}; bvals = []; ctypeList = '';
    function add_row(coefs_idx, coefs_val, type, bval)
        r = zeros(1, nVar);
        r(coefs_idx) = coefs_val;
        rows{end+1} = r; %#ok<AGROW>
        bvals(end+1) = bval; %#ok<AGROW>
        ctypeList(end+1) = type; %#ok<AGROW>
    end

    % Inverter apparent-power polygon, |Q| definition, and (opt-in) the
    % LinDistFlow voltage floor -- applied to EVERY block so the committed
    % stage-1 decision and every stage-2 recourse both respect the feeder.
    function add_inverter_and_network(blk)
        if useQ
            Npoly = p.Inverter.nPolygonSides;
            rhs   = p.Inverter.S_max * cos(pi/Npoly);
            for kk = 1:Npoly
                th = 2*pi*(kk-1)/Npoly;
                cth = cos(th); if abs(cth) < 1e-12; cth = 0; end
                sth = sin(th); if abs(sth) < 1e-12; sth = 0; end
                add_row([ix(blk,OFF.Pgi) ix(blk,OFF.Pge) ixQ(blk)], ...
                        [cth -cth sth], 'U', rhs);
            end
            add_row([ixQ(blk) ixQa(blk)], [ 1 -1], 'U', 0);
            add_row([ixQ(blk) ixQa(blk)], [-1 -1], 'U', 0);
        end
        if useNet
            nb = numel(p.network.buses);
            hasB = isfield(p.network,'b') && ~isempty(p.network.b);
            for bi = 1:nb
                if useQ && hasB
                    add_row([ix(blk,OFF.Pgi) ix(blk,OFF.Pge) ixQ(blk)], ...
                        [-p.network.a(bi) p.network.a(bi) p.network.b(bi)], ...
                        'U', p.network.C(bi) - p.network.Vfloor(bi));
                else
                    add_row([ix(blk,OFF.Pgi) ix(blk,OFF.Pge)], ...
                        [-p.network.a(bi) p.network.a(bi)], ...
                        'U', p.network.C(bi) - p.network.Vfloor(bi));
                end
            end
        end
    end

    % Stage-1 balances (this slot); fuel cell contributes sum_k slope*PH2seg(k)
    seg0 = arrayfun(@(k) ixSeg(0,k), 1:s);
    add_row([ix(0,OFF.Ps) seg0 ix(0,OFF.Php) ix(0,OFF.Pgi) ix(0,OFF.Pge) ix(0,OFF.Bdis) ix(0,OFF.Bch) ix(0,OFF.Edis) ix(0,OFF.Ech)], ...
        [p.eta_PV slopeE -1 1 -1 1 -1 1 -1], 'S', fcNow.Lelec);
    add_heat_row(0, seg0, fcNow.Lheat);
    add_row([seg0 ix(0,OFF.PH2tot)], [ones(1,s) -1], 'S', 0); % concentrator
    add_fillorder(0, seg0);
    add_inverter_and_network(0);

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
    for sc = 1:Nscen
        fcs = fcNextScenarios(sc);
        segS = arrayfun(@(k) ixSeg(sc,k), 1:s);
        add_row([ix(sc,OFF.Ps) segS ix(sc,OFF.Php) ix(sc,OFF.Pgi) ix(sc,OFF.Pge) ix(sc,OFF.Bdis) ix(sc,OFF.Bch) ix(sc,OFF.Edis) ix(sc,OFF.Ech)], ...
            [p.eta_PV slopeE -1 1 -1 1 -1 1 -1], 'S', fcs.Lelec);
        add_heat_row(sc, segS, fcs.Lheat);
        add_row([segS ix(sc,OFF.PH2tot)], [ones(1,s) -1], 'S', 0); % concentrator
        add_fillorder(sc, segS);
        add_inverter_and_network(sc);

        add_soc(ix(sc,OFF.SB), ix(sc,OFF.Bch), ix(sc,OFF.Bdis), ix(0,OFF.SB), 1, p.Batt, dt, []);
        add_soc(ix(sc,OFF.SE), ix(sc,OFF.Ech), ix(sc,OFF.Edis), ix(0,OFF.SE), 1, p.EV, dt, []);
        add_soc(ix(sc,OFF.SL), ix(sc,OFF.Lch), ix(sc,OFF.Ldis), ix(0,OFF.SL), 1, p.Building, dt, []);
        add_soc(ix(sc,OFF.SP), ix(sc,OFF.Pch), ix(sc,OFF.Pdis), ix(0,OFF.SP), 1, p.Pipe, dt, []);
    end

    A = cell2mat(rows(:));
    b = bvals(:);
    ctype = ctypeList(:);
    vartype = repmat('C', nVar, 1);
    for blk = 0:Nscen
        for k = 1:(s-1)
            vartype(ixU(blk,k)) = 'I';
        end
        for k = 1:nHPu
            vartype(ixHPu(blk,k)) = 'I';
        end
    end

    param.msglev = 0;
    [x, fval, status] = glpk(c, A, b, lb, ub, ctype, vartype, 1, param);

    info.status = status;
    info.cost = fval;

    if status ~= 0
        error('intraday_dispatch:infeasible', 'glpk returned status %d (not optimal).', status);
    end

    committed.Pg_imp = x(ix(0,OFF.Pgi));
    committed.Pg_exp = x(ix(0,OFF.Pge));
    committed.PH2    = x(ix(0,OFF.PH2tot));
    committed.PH2seg = x(seg0)';
    committed.Php    = x(ix(0,OFF.Php));
    if useQ; committed.Qh = x(ixQ(0)); else; committed.Qh = 0; end
    committed.Ps     = x(ix(0,OFF.Ps));
    committed.Pbatt_ch  = x(ix(0,OFF.Bch));  committed.Pbatt_dis  = x(ix(0,OFF.Bdis));
    committed.Pev_ch    = x(ix(0,OFF.Ech));  committed.Pev_dis    = x(ix(0,OFF.Edis));
    committed.Pbld_ch   = x(ix(0,OFF.Lch));  committed.Pbld_dis   = x(ix(0,OFF.Ldis));
    committed.Ppipe_ch  = x(ix(0,OFF.Pch));  committed.Ppipe_dis  = x(ix(0,OFF.Pdis));

    SOCnext.Batt     = x(ix(0,OFF.SB));
    SOCnext.EV       = x(ix(0,OFF.SE));
    SOCnext.Building = x(ix(0,OFF.SL));
    SOCnext.Pipe     = x(ix(0,OFF.SP));

    % Verification gate (mirrors dayahead_dispatch.m): segment fill order
    % must be physically valid in every block (stage 1 + every scenario).
    tol = 1e-6;
    for blk = 0:Nscen
        segvals = x(arrayfun(@(k) ixSeg(blk,k), 1:s));
        for k = 1:(s-1)
            if segvals(k+1) > tol && segvals(k) < w(k) - 1e-4
                error('intraday_dispatch:fillorder', ...
                    ['Segment fill-order violated in block %d: PH2seg(%d)=%.6f > 0 ' ...
                     'while PH2seg(%d)=%.6f < w(%d)=%.6f (not full).'], ...
                    blk, k+1, segvals(k+1), k, segvals(k), k, w(k));
            end
        end
    end

    % Heat balance for one block. With the heat-pump PWL on, the single
    % COP*Php term becomes sum_k COP_k*Php_seg(k) plus a concentrator tying
    % the segments to the total, and (if the slopes require it) fill-order
    % binaries. Identical treatment to the fuel cell in the same row.
    function add_heat_row(blk, segIdx, Lheat)
        if useHP
            hpIdx = arrayfun(@(k) ixHP(blk,k), 1:sHP);
            add_row([segIdx hpIdx ix(blk,OFF.Ldis) ix(blk,OFF.Lch) ix(blk,OFF.Pdis) ix(blk,OFF.Pch)], ...
                    [slopeT copSeg 1 -1 1 -1], 'S', Lheat);
            add_row([hpIdx ix(blk,OFF.Php)], [ones(1,sHP) -1], 'S', 0);   % concentrator
            for k = 1:nHPu
                add_row([ixHP(blk,k+1) ixHPu(blk,k)], [1 -wHP(k+1)], 'U', 0);
                add_row([ixHP(blk,k)   ixHPu(blk,k)], [-1 wHP(k)],   'U', 0);
            end
        else
            add_row([segIdx ix(blk,OFF.Php) ix(blk,OFF.Ldis) ix(blk,OFF.Lch) ix(blk,OFF.Pdis) ix(blk,OFF.Pch)], ...
                    [slopeT p.HeatPump.COP 1 -1 1 -1], 'S', Lheat);
        end
    end

    function add_fillorder(blk, segIdx)
        for k = 1:(s-1)
            add_row([segIdx(k+1) ixU(blk,k)], [1 -w(k+1)], 'U', 0);
            add_row([segIdx(k)   ixU(blk,k)], [-1 w(k)],   'U', 0);
        end
    end

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
