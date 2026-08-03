function sol = dayahead_dispatch(p, fc)
%DAYAHEAD_DISPATCH Day-ahead robust-proxy MILP schedule (hourly, 24h horizon).
%
%   sol = DAYAHEAD_DISPATCH(p, fc)
%
%   Solves ONE mixed-integer program over the 24 hourly slots of `fc.DA`,
%   minimizing energy cost (grid import - export revenue + fuel) subject
%   to electrical/heat balance, the generalized-storage state equation
%   for all four devices (see storage_soc_update.m), a RESERVE-MARGIN
%   robustness proxy (unused storage headroom sized to a fraction of
%   that hour's forecast -- the standard simplified substitute for a
%   full robust-MILP when a YALMIP+Gurobi toolchain isn't available),
%   and a PIECEWISE-LINEAR fuel cell.
%
%   FUEL CELL PWL/MILP EMBEDDING (this is the thesis's central claim,
%   not a side demonstration): the fuel cell's electrical and thermal
%   part-load efficiency curves (p.PWL.bkpt_e / p.PWL.bkpt_th, fit in
%   multiscale_default_params.m) are BOTH non-concave/S-shaped. A
%   standard multi-segment PWL relaxation (segment variables PH2_seg(k)
%   in [0, w_k], concentrated by sum_k PH2_seg(k) = PH2_total) is only
%   valid for a CONCAVE curve being maximized (or convex being
%   minimized): the LP would then naturally fill segments in slope
%   order because that's cost-optimal anyway. Here it is not -- e.g. the
%   electrical curve's segment 2 has a HIGHER slope (0.51) than segment
%   1 (0.45), so a plain LP relaxation cherry-picks segment 2 while
%   leaving segment 1 empty, reporting more electricity than the fuel
%   cell can physically produce at that fuel level (verified: see
%   VALIDATION.md). Fill-order binaries u_1..u_{s-1} per hour fix this:
%       PH2_seg(k+1) <= w(k+1)*u_k   and   PH2_seg(k) >= w(k)*u_k
%   force segment k+1 to stay at zero until segment k is COMPLETELY
%   full. This makes the problem a genuine MILP (not the pure LP the
%   day-ahead dispatch used to be) -- exactly what the thesis's central
%   claim requires: PWL representation of nonlinear part-load
%   efficiency with MILP tractability, embedded in the actual dispatch
%   optimization, not only demonstrated standalone in Month 2.
%
%   PV keeps a constant efficiency (p.eta_PV) in this file; only the
%   fuel cell (electrical AND thermal outputs, both driven by the same
%   H2 input/segments) is PWL/MILP in this thesis's scope.
%
%   Inputs
%     p  : multiscale_default_params() struct (uses p.PWL.*)
%     fc : forecast_profiles() struct (uses fc.DA and fc.hours)
%
%   Output sol (all time series 24x1, aligned with fc.hours):
%     Pg_imp, Pg_exp, PH2 (= total fuel across all segments), Ps,
%     Pbatt_ch, Pbatt_dis, Pev_ch, Pev_dis, Pbld_ch, Pbld_dis, Ppipe_ch, Ppipe_dis,
%     SOCbatt, SOCev, SOCbld, SOCpipe   (end-of-hour state of charge)
%     PH2seg (24 x nSegments, per-segment fuel split, for inspection/debugging)
%     cost   : total 24h cost ($)
%     status : glpk status (0 = optimal)

    nT = 24;
    dt = 1.0;
    s = p.PWL.nSegments;
    bkE = p.PWL.bkpt_e; bkT = p.PWL.bkpt_th;
    w = diff(bkE.x);                 % 1 x s segment widths (identical for both curves: same x breakpoints)
    slopeE = diff(bkE.y) ./ w;       % 1 x s electrical slope per segment
    slopeT = diff(bkT.y) ./ w;       % 1 x s thermal slope per segment

    % Variables per hour: 16 fixed + PH2total(1) + PH2seg(1..s) + u(1..s-1)
    % Reactive power is an optional extra decision variable per hour. When
    % p.Inverter is present the hub's grid-facing inverter can inject
    % (Qh>0) or absorb (Qh<0) reactive power within its apparent-power
    % circle, which is the only mechanism by which the hub can support
    % voltage. Absent p.Inverter the model is exactly as before.
    % Qh is free-signed; Qabs is an auxiliary >= |Qh| carrying the small
    % unity-power-factor tie-breaker cost (see multiscale_default_params.m).
    useQ = isfield(p, 'Inverter');
    nQ = useQ * 2;

    NV = 16 + 1 + s + (s-1) + nQ;
    OFF = struct('Pgi',1,'Pge',2,'Ps',3, ...
                  'Bch',4,'Bdis',5,'Ech',6,'Edis',7, ...
                  'Lch',8,'Ldis',9,'Pch',10,'Pdis',11, ...
                  'SB',12,'SE',13,'SL',14,'SP',15,'Php',16,'PH2tot',17);
    segBase = 17; uBase = 17 + s;
    qOff  = 17 + s + (s-1) + 1;         % Qh   within the hour block
    qaOff = qOff + 1;                    % Qabs within the hour block
    nVar = NV*nT;
    vix    = @(t,off) (t-1)*NV + off;
    vixSeg = @(t,k)    vix(t, segBase+k);
    vixU   = @(t,k)     vix(t, uBase+k);
    vixQ   = @(t)       vix(t, qOff);
    vixQa  = @(t)       vix(t, qaOff);

    evAvail = ismember(fc.hours, p.EV.pluggedInHours);

    %% Bounds
    lb = zeros(nVar,1); ub = zeros(nVar,1);
    GRID_CAP = 1000;
    for t = 1:nT
        ub(vix(t,OFF.Pgi))  = GRID_CAP;
        ub(vix(t,OFF.Pge))  = GRID_CAP;
        ub(vix(t,OFF.Ps))   = fc.DA.solar(t);
        ub(vix(t,OFF.Bch))  = p.Batt.Pch_max;
        ub(vix(t,OFF.Bdis)) = p.Batt.Pdis_max;
        ub(vix(t,OFF.Ech))  = p.EV.Pch_max * evAvail(t);
        ub(vix(t,OFF.Edis)) = p.EV.Pdis_max * evAvail(t);
        ub(vix(t,OFF.Lch))  = p.Building.Pch_max;
        ub(vix(t,OFF.Ldis)) = p.Building.Pdis_max;
        ub(vix(t,OFF.Pch))  = p.Pipe.Pch_max;
        ub(vix(t,OFF.Pdis)) = p.Pipe.Pdis_max;
        ub(vix(t,OFF.Php))  = p.HeatPump.Pmax;
        ub(vix(t,OFF.PH2tot)) = p.PWL.FC_H2_max;
        lb(vix(t,OFF.SB)) = p.Batt.SOCmin;     ub(vix(t,OFF.SB)) = p.Batt.SOCmax;
        lb(vix(t,OFF.SE)) = p.EV.SOCmin;       ub(vix(t,OFF.SE)) = p.EV.SOCmax;
        lb(vix(t,OFF.SL)) = p.Building.SOCmin; ub(vix(t,OFF.SL)) = p.Building.SOCmax;
        lb(vix(t,OFF.SP)) = p.Pipe.SOCmin;     ub(vix(t,OFF.SP)) = p.Pipe.SOCmax;
        for k = 1:s
            ub(vixSeg(t,k)) = w(k);
        end
        for k = 1:(s-1)
            ub(vixU(t,k)) = 1;
        end
        if useQ
            % IEEE 1547-2018 Cl. 5.2 Category B: +/- 44% of nameplate S.
            lb(vixQ(t)) = -p.Inverter.Q_max;
            ub(vixQ(t)) =  p.Inverter.Q_max;
            ub(vixQa(t)) = p.Inverter.Q_max;   % Qabs >= |Qh|, lb 0 by default
        end
    end

    %% Objective (fuel cost proportional to TOTAL hydrogen, meaning unchanged)
    c = zeros(nVar,1);
    for t = 1:nT
        c(vix(t,OFF.Pgi))    =  fc.DA.priceImport(t) * dt;
        c(vix(t,OFF.Pge))    = -fc.DA.priceExport(t) * dt;
        c(vix(t,OFF.PH2tot)) =  p.price_H2 * dt;
        if useQ
            c(vixQa(t)) = p.Inverter.Qcost * dt;   % unity-pf tie-breaker
        end
    end

    %% Equality constraints: elec balance, heat balance, concentrator, 4x SOC recursion
    nEq = nT*7;
    Aeq = zeros(nEq, nVar); beq = zeros(nEq,1);
    row = 0;
    for t = 1:nT
        row = row+1; % electrical balance (fuel cell contributes sum_k slopeE(k)*PH2seg(k))
        Aeq(row, vix(t,OFF.Ps))   = p.eta_PV;
        for k = 1:s
            Aeq(row, vixSeg(t,k)) = slopeE(k);
        end
        Aeq(row, vix(t,OFF.Pgi))  = 1;
        Aeq(row, vix(t,OFF.Pge))  = -1;
        Aeq(row, vix(t,OFF.Bdis)) = 1;
        Aeq(row, vix(t,OFF.Bch))  = -1;
        Aeq(row, vix(t,OFF.Edis)) = 1;
        Aeq(row, vix(t,OFF.Ech))  = -1;
        Aeq(row, vix(t,OFF.Php))  = -1;
        beq(row) = fc.DA.Lelec(t);

        row = row+1; % heat balance (fuel cell contributes sum_k slopeT(k)*PH2seg(k))
        for k = 1:s
            Aeq(row, vixSeg(t,k)) = slopeT(k);
        end
        Aeq(row, vix(t,OFF.Php))  = p.HeatPump.COP;
        Aeq(row, vix(t,OFF.Ldis)) = 1;
        Aeq(row, vix(t,OFF.Lch))  = -1;
        Aeq(row, vix(t,OFF.Pdis)) = 1;
        Aeq(row, vix(t,OFF.Pch))  = -1;
        beq(row) = fc.DA.Lheat(t);

        row = row+1; % concentrator: sum_k PH2seg(k) = PH2tot
        for k = 1:s
            Aeq(row, vixSeg(t,k)) = 1;
        end
        Aeq(row, vix(t,OFF.PH2tot)) = -1;
        beq(row) = 0;

        [row, Aeq, beq] = soc_row(row, Aeq, beq, t, vix, OFF.SB, OFF.Bch, OFF.Bdis, p.Batt, dt);
        [row, Aeq, beq] = soc_row(row, Aeq, beq, t, vix, OFF.SE, OFF.Ech, OFF.Edis, p.EV, dt);
        [row, Aeq, beq] = soc_row(row, Aeq, beq, t, vix, OFF.SL, OFF.Lch, OFF.Ldis, p.Building, dt);
        [row, Aeq, beq] = soc_row(row, Aeq, beq, t, vix, OFF.SP, OFF.Pch, OFF.Pdis, p.Pipe, dt);
    end

    %% Inequality constraints: reserve margin (4/hr) + PWL fill-order (2*(s-1)/hr)
    %  + OPTIONAL LinDistFlow voltage rows (see below).
    %
    % NETWORK CO-OPTIMIZATION (opt-in, default OFF). If p.network is
    % present and enabled, one linear voltage row per monitored bus per
    % hour is added, letting the IEEE 33 network CONSTRAIN the schedule
    % instead of merely being verified afterwards. Under LinDistFlow with
    % exactly ONE controllable injection every bus voltage is affine in
    % the hub's net import I(t) = Pgi(t) - Pge(t):
    %       V_j(t) = C_j + a_j * I(t),   a_j < 0
    % so requiring V_j(t) >= Vfloor_j becomes, in the EXISTING grid
    % variables and with no new ones:
    %       (-a_j)*Pgi(t) - (-a_j)*Pge(t) <= C_j - Vfloor_j
    % Absent p.network this block adds nothing and the model is
    % bit-identical to the network-free version used by Cases 1-4.
    useNet = isfield(p, 'network') && isfield(p.network, 'enabled') && p.network.enabled;
    if useNet
        netBuses  = p.network.buses(:)';        % buses to monitor
        netC      = p.network.C(:);             % intercepts (pu)
        netA      = p.network.a(:);             % sensitivities (pu/kW)
        netFloor  = p.network.Vfloor(:);        % per-bus floor (pu)
        if isfield(p.network, 'b'); netB = p.network.b(:); else; netB = []; end
        nNetRows  = nT * numel(netBuses);
    else
        netBuses = []; netB = []; nNetRows = 0;
    end

    % Apparent-power limit P^2 + Q^2 <= S^2, linearized as a regular
    % polygon INSCRIBED in that circle so the model stays a MILP:
    %     P*cos(th_k) + Q*sin(th_k) <= S*cos(pi/N),  th_k = 2*pi*k/N
    % Inscribed (not circumscribed) means every feasible point is genuinely
    % inside the inverter's real limit -- the model slightly under-uses the
    % hardware rather than over-promising. P here is the net grid exchange
    % Pgi - Pge, so both import and export directions are covered by
    % sweeping th_k around the full circle.
    if useQ
        Npoly = p.Inverter.nPolygonSides;
        polyTh  = 2*pi*(0:Npoly-1)/Npoly;
        polyRhs = p.Inverter.S_max * cos(pi/Npoly);
        nPolyRows = nT * (Npoly + 2);   % polygon + two |Qh| rows
    else
        Npoly = 0; nPolyRows = 0;
    end

    nIneq = nT*(4 + 2*(s-1)) + nNetRows + nPolyRows;
    Aub = zeros(nIneq, nVar); bub = zeros(nIneq,1);
    row = 0;
    for t = 1:nT
        elecUp   = p.reserve.elecLoadFrac*fc.DA.Lelec(t) + p.reserve.solarFrac*fc.DA.solar(t);
        elecDown = elecUp;
        heatUp   = p.reserve.heatLoadFrac*fc.DA.Lheat(t);
        heatDown = heatUp;

        row = row+1; % elec reserve up: Bdis+Edis <= capacity - required
        Aub(row, vix(t,OFF.Bdis)) = 1; Aub(row, vix(t,OFF.Edis)) = 1;
        bub(row) = max(0, p.Batt.Pdis_max + p.EV.Pdis_max*evAvail(t) - elecUp);

        row = row+1; % elec reserve down
        Aub(row, vix(t,OFF.Bch)) = 1; Aub(row, vix(t,OFF.Ech)) = 1;
        bub(row) = max(0, p.Batt.Pch_max + p.EV.Pch_max*evAvail(t) - elecDown);

        row = row+1; % thermal reserve up
        Aub(row, vix(t,OFF.Ldis)) = 1; Aub(row, vix(t,OFF.Pdis)) = 1;
        bub(row) = max(0, p.Building.Pdis_max + p.Pipe.Pdis_max - heatUp);

        row = row+1; % thermal reserve down
        Aub(row, vix(t,OFF.Lch)) = 1; Aub(row, vix(t,OFF.Pch)) = 1;
        bub(row) = max(0, p.Building.Pch_max + p.Pipe.Pch_max - heatDown);

        % PWL fill-order: segment k+1 empty until segment k is completely full
        for k = 1:(s-1)
            row = row+1; % PH2seg(k+1) - w(k+1)*u_k <= 0
            Aub(row, vixSeg(t,k+1)) = 1; Aub(row, vixU(t,k)) = -w(k+1);
            bub(row) = 0;

            row = row+1; % -PH2seg(k) + w(k)*u_k <= 0   (i.e. PH2seg(k) >= w(k)*u_k)
            Aub(row, vixSeg(t,k)) = -1; Aub(row, vixU(t,k)) = w(k);
            bub(row) = 0;
        end

        % LinDistFlow voltage floor at each monitored bus (opt-in).
        % With reactive power the row becomes V_j = C_j + a_j*P + b_j*Q,
        % and because b_j/a_j = (sum X)/(sum R) over each bus's shared path
        % varies from bus to bus, these rows are NO LONGER colinear -- the
        % constraint set does genuine multi-bus work instead of collapsing
        % to a single scalar import cap.
        for bi = 1:numel(netBuses)
            row = row+1;
            Aub(row, vix(t,OFF.Pgi)) = -netA(bi);
            Aub(row, vix(t,OFF.Pge)) =  netA(bi);
            % V_j = C_j + a_j*P - b_j*Qh. C_j already carries the host bus's
            % NOMINAL reactive load, and a Q injection subtracts from that
            % load, hence the minus sign on b_j in the voltage expression.
            % Rearranged to <= form the Qh coefficient is therefore +b_j:
            %     -a_j*P + b_j*Qh <= C_j - Vfloor
            if useQ && ~isempty(netB)
                Aub(row, vixQ(t)) = netB(bi);
            end
            bub(row) = netC(bi) - netFloor(bi);
        end

        % Inverter apparent-power polygon.
        for k = 1:Npoly
            row = row+1;
            Aub(row, vix(t,OFF.Pgi)) =  cos(polyTh(k));
            Aub(row, vix(t,OFF.Pge)) = -cos(polyTh(k));
            Aub(row, vixQ(t))        =  sin(polyTh(k));
            bub(row) = polyRhs;
        end
        if useQ
            % Qabs >= |Qh|, so the tie-breaker prices reactive magnitude
            % regardless of direction.
            row = row+1;  Aub(row, vixQ(t)) =  1; Aub(row, vixQa(t)) = -1; bub(row) = 0;
            row = row+1;  Aub(row, vixQ(t)) = -1; Aub(row, vixQa(t)) = -1; bub(row) = 0;
        end
    end

    A = [Aeq; Aub];
    b = [beq; bub];
    ctype = [repmat('S',nEq,1); repmat('U',nIneq,1)];
    vartype = repmat('C', nVar, 1);
    for t = 1:nT
        for k = 1:(s-1)
            vartype(vixU(t,k)) = 'I';
        end
    end

    param.msglev = 0;
    [x, fval, status] = glpk(c, A, b, lb, ub, ctype, vartype, 1, param);

    sol.status = status;
    sol.cost = fval;
    sol.Pg_imp = x(arrayfun(@(t) vix(t,OFF.Pgi), 1:nT))';
    sol.Pg_exp = x(arrayfun(@(t) vix(t,OFF.Pge), 1:nT))';
    sol.PH2    = x(arrayfun(@(t) vix(t,OFF.PH2tot), 1:nT))';
    sol.Ps     = x(arrayfun(@(t) vix(t,OFF.Ps),  1:nT))';
    sol.Pbatt_ch  = x(arrayfun(@(t) vix(t,OFF.Bch),  1:nT))';
    sol.Pbatt_dis = x(arrayfun(@(t) vix(t,OFF.Bdis), 1:nT))';
    sol.Pev_ch    = x(arrayfun(@(t) vix(t,OFF.Ech),  1:nT))';
    sol.Pev_dis   = x(arrayfun(@(t) vix(t,OFF.Edis), 1:nT))';
    sol.Pbld_ch   = x(arrayfun(@(t) vix(t,OFF.Lch),  1:nT))';
    sol.Pbld_dis  = x(arrayfun(@(t) vix(t,OFF.Ldis), 1:nT))';
    sol.Ppipe_ch  = x(arrayfun(@(t) vix(t,OFF.Pch),  1:nT))';
    sol.Ppipe_dis = x(arrayfun(@(t) vix(t,OFF.Pdis), 1:nT))';
    sol.SOCbatt = x(arrayfun(@(t) vix(t,OFF.SB), 1:nT))';
    sol.SOCev   = x(arrayfun(@(t) vix(t,OFF.SE), 1:nT))';
    sol.SOCbld  = x(arrayfun(@(t) vix(t,OFF.SL), 1:nT))';
    sol.SOCpipe = x(arrayfun(@(t) vix(t,OFF.SP), 1:nT))';
    sol.Php     = x(arrayfun(@(t) vix(t,OFF.Php), 1:nT))';
    if useQ
        sol.Qh = x(arrayfun(@(t) vixQ(t), 1:nT))';   % kvar, + = injecting
    else
        sol.Qh = zeros(1, nT);
    end

    sol.PH2seg = zeros(nT, s);
    for t = 1:nT
        for k = 1:s
            sol.PH2seg(t,k) = x(vixSeg(t,k));
        end
    end

    % Verification gate: segment fill order must be physically valid --
    % no PH2seg(k+1) > 0 while PH2seg(k) is not completely full. A
    % violation here means the MILP formulation itself has a bug (this
    % should be impossible if it solved to optimality), so it is an
    % assertion (hard error), not a soft warning.
    if status == 0
        tol = 1e-6;
        for t = 1:nT
            for k = 1:(s-1)
                if sol.PH2seg(t,k+1) > tol && sol.PH2seg(t,k) < w(k) - 1e-4
                    error('dayahead_dispatch:fillorder', ...
                        ['Segment fill-order violated at hour %d: PH2seg(%d)=%.6f > 0 ' ...
                         'while PH2seg(%d)=%.6f < w(%d)=%.6f (not full).'], ...
                        t, k+1, sol.PH2seg(t,k+1), k, sol.PH2seg(t,k), k, w(k));
                end
            end
        end
    end
end

function [row, Aeq, beq] = soc_row(row, Aeq, beq, t, vix, socOff, chOff, disOff, dev, dt)
    row = row+1;
    Aeq(row, vix(t,socOff)) = 1;
    Aeq(row, vix(t,chOff))  = -dev.eta_ch*dt/dev.Emax;
    Aeq(row, vix(t,disOff)) = dt/(dev.eta_dis*dev.Emax);
    if t == 1
        beq(row) = (1 - dev.selfLoss*dt) * dev.SOC0;
    else
        Aeq(row, vix(t-1,socOff)) = -(1 - dev.selfLoss*dt);
        beq(row) = 0;
    end
end
