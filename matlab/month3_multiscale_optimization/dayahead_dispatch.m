function sol = dayahead_dispatch(p, fc)
%DAYAHEAD_DISPATCH Day-ahead robust-proxy LP schedule (hourly, 24h horizon).
%
%   sol = DAYAHEAD_DISPATCH(p, fc)
%
%   Solves ONE linear program over the 24 hourly slots of `fc.DA`,
%   minimizing energy cost (grid import - export revenue + fuel) subject
%   to electrical/heat balance, the generalized-storage state equation
%   for all four devices (see storage_soc_update.m), and a
%   RESERVE-MARGIN robustness proxy: at every hour, storage must keep
%   enough UNUSED charge/discharge headroom to cover a fraction of that
%   hour's load/solar forecast (p.reserve.*), so the schedule isn't
%   dispatched to the very edge of what the day-ahead forecast alone
%   would justify. This is the standard simplified substitute for a full
%   robust-MILP (e.g. YALMIP's `robustify` + Gurobi) when that toolchain
%   isn't available: instead of optimizing against an adversarial
%   uncertainty set, it reserves capacity sized to the SAME uncertainty
%   band a robust formulation would use.
%
%   No binary/complementarity variables are used (pure LP): the
%   cost-minimizing objective already discourages simultaneous charge
%   and discharge of the same device, since that only wastes energy to
%   round-trip losses for no benefit.
%
%   Inputs
%     p  : multiscale_default_params() struct
%     fc : forecast_profiles() struct (uses fc.DA and fc.hours)
%
%   Output sol (all time series 24x1, aligned with fc.hours):
%     Pg_imp, Pg_exp, PH2, Ps,
%     Pbatt_ch, Pbatt_dis, Pev_ch, Pev_dis, Pbld_ch, Pbld_dis, Ppipe_ch, Ppipe_dis,
%     SOCbatt, SOCev, SOCbld, SOCpipe   (end-of-hour state of charge)
%     cost   : total 24h cost ($)
%     status : glpk status (0 = optimal)

    nT = 24;
    dt = 1.0;
    NV = 17; % variables per hour, see offsets below
    OFF = struct('Pgi',1,'Pge',2,'PH2',3,'Ps',4, ...
                  'Bch',5,'Bdis',6,'Ech',7,'Edis',8, ...
                  'Lch',9,'Ldis',10,'Pch',11,'Pdis',12, ...
                  'SB',13,'SE',14,'SL',15,'SP',16, 'Php',17);
    nVar = NV*nT;
    vix = @(t,off) (t-1)*NV + off;

    evAvail = ismember(fc.hours, p.EV.pluggedInHours);

    %% Bounds
    lb = zeros(nVar,1); ub = zeros(nVar,1);
    FC_H2_max = 150;
    GRID_CAP = 1000;
    for t = 1:nT
        ub(vix(t,OFF.Pgi))  = GRID_CAP;
        ub(vix(t,OFF.Pge))  = GRID_CAP;
        ub(vix(t,OFF.PH2))  = FC_H2_max;
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
        lb(vix(t,OFF.SB)) = p.Batt.SOCmin;     ub(vix(t,OFF.SB)) = p.Batt.SOCmax;
        lb(vix(t,OFF.SE)) = p.EV.SOCmin;       ub(vix(t,OFF.SE)) = p.EV.SOCmax;
        lb(vix(t,OFF.SL)) = p.Building.SOCmin; ub(vix(t,OFF.SL)) = p.Building.SOCmax;
        lb(vix(t,OFF.SP)) = p.Pipe.SOCmin;     ub(vix(t,OFF.SP)) = p.Pipe.SOCmax;
    end

    %% Objective
    c = zeros(nVar,1);
    for t = 1:nT
        c(vix(t,OFF.Pgi)) =  fc.DA.priceImport(t) * dt;
        c(vix(t,OFF.Pge)) = -fc.DA.priceExport(t) * dt;
        c(vix(t,OFF.PH2)) =  p.price_H2 * dt;
    end

    %% Equality constraints: elec balance, heat balance, 4x SOC recursion
    nEq = nT*6;
    Aeq = zeros(nEq, nVar); beq = zeros(nEq,1);
    row = 0;
    for t = 1:nT
        row = row+1; % electrical balance
        Aeq(row, vix(t,OFF.Ps))   = p.eta_PV;
        Aeq(row, vix(t,OFF.PH2))  = p.eta_FC_e;
        Aeq(row, vix(t,OFF.Pgi))  = 1;
        Aeq(row, vix(t,OFF.Pge))  = -1;
        Aeq(row, vix(t,OFF.Bdis)) = 1;
        Aeq(row, vix(t,OFF.Bch))  = -1;
        Aeq(row, vix(t,OFF.Edis)) = 1;
        Aeq(row, vix(t,OFF.Ech))  = -1;
        Aeq(row, vix(t,OFF.Php))  = -1;
        beq(row) = fc.DA.Lelec(t);

        row = row+1; % heat balance
        Aeq(row, vix(t,OFF.PH2))  = p.eta_FC_th;
        Aeq(row, vix(t,OFF.Php))  = p.HeatPump.COP;
        Aeq(row, vix(t,OFF.Ldis)) = 1;
        Aeq(row, vix(t,OFF.Lch))  = -1;
        Aeq(row, vix(t,OFF.Pdis)) = 1;
        Aeq(row, vix(t,OFF.Pch))  = -1;
        beq(row) = fc.DA.Lheat(t);

        [row, Aeq, beq] = soc_row(row, Aeq, beq, t, vix, OFF.SB, OFF.Bch, OFF.Bdis, p.Batt, dt);
        [row, Aeq, beq] = soc_row(row, Aeq, beq, t, vix, OFF.SE, OFF.Ech, OFF.Edis, p.EV, dt);
        [row, Aeq, beq] = soc_row(row, Aeq, beq, t, vix, OFF.SL, OFF.Lch, OFF.Ldis, p.Building, dt);
        [row, Aeq, beq] = soc_row(row, Aeq, beq, t, vix, OFF.SP, OFF.Pch, OFF.Pdis, p.Pipe, dt);
    end

    %% Inequality (reserve margin) constraints
    nIneq = nT*4;
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
    end

    A = [Aeq; Aub];
    b = [beq; bub];
    ctype = [repmat('S',nEq,1); repmat('U',nIneq,1)];
    vartype = repmat('C', nVar, 1);

    param.msglev = 0;
    [x, fval, status] = glpk(c, A, b, lb, ub, ctype, vartype, 1, param);

    sol.status = status;
    sol.cost = fval;
    sol.Pg_imp = x(arrayfun(@(t) vix(t,OFF.Pgi), 1:nT))';
    sol.Pg_exp = x(arrayfun(@(t) vix(t,OFF.Pge), 1:nT))';
    sol.PH2    = x(arrayfun(@(t) vix(t,OFF.PH2), 1:nT))';
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
