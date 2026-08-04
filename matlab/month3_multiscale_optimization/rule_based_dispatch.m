function res = rule_based_dispatch(p, fc)
%RULE_BASED_DISPATCH The same hub under simple heuristic control.
%
%   res = RULE_BASED_DISPATCH(p, fc)
%
%   WHY THIS EXISTS. Case 1 in main_month4a is "no hub at all", so the
%   headline saving against it measures the value of OWNING PV, a battery,
%   an EV fleet and a heat pump -- equipment, not modelling. That caveat is
%   stated everywhere it appears, but it leaves the modelling contribution
%   measured only by small ablations. The demanding comparator is the SAME
%   HUB, same ratings, same profiles, same physics, run by a controller a
%   competent engineer could build in an afternoon. Whatever the optimizer
%   beats THAT by is the value of the optimization.
%
%   THE RULES, and they are deliberately unsophisticated:
%     1. Take all available PV. It is free.
%     2. Price threshold: the median of the day's import tariff. "Cheap"
%        means below it, "expensive" above. No look-ahead beyond knowing
%        the published tariff, which any real operator has.
%     3. Electrical storage (battery, EV): charge at full rating when
%        cheap and there is SOC headroom; discharge at full rating when
%        expensive and there is charge to give. EV only while plugged in.
%     4. Thermal storage (building, pipe): the same rule on the heat side,
%        but charged only from SPARE HEAT-PUMP CAPACITY, so filling a store
%        can never by itself start the fuel cell.
%     5. Heat is served heat-pump-first, because it is the cheapest source
%        per kWh of heat while electricity is cheaper than hydrogen.
%     6. The fuel cell runs for exactly two reasons, checked in order:
%        (a) MUST-RUN -- the heat pump plus storage cannot cover the heat
%            balance, so the fuel cell covers the deficit. This is physics,
%            not economics, and no controller can decline it.
%        (b) ECONOMIC -- its marginal electrical cost, price_H2 divided by
%            the electrical efficiency at its rated point, is below the
%            current import price. At today's delivered hydrogen price this
%            test essentially never passes, which is the correct answer.
%     7. Whatever is left over is imported from or exported to the grid.
%
%   WHAT THE RULES DO NOT DO, which is the entire point: no look-ahead, no
%   forecast, no optimization, no coordination between carriers, no
%   awareness that charging now raises the peak later, and no network model.
%
%   FAIRNESS. The comparison is only meaningful if both controllers face the
%   same physics, so this function uses the same ratings, the same SOC
%   bands, the same storage state equation (storage_soc_update.m) and the
%   same TRUE piecewise-linear fuel-cell curves the optimized dispatch is
%   evaluated against. It runs on the same 5-minute realized profiles
%   (fc.RT), so neither controller gets a better forecast than the other --
%   the rule-based one simply does not use forecasts at all.
%
%   HONESTY ABOUT INFEASIBILITY. A rule-based controller can fail to meet
%   demand where an optimizer would not, and hiding that would flatter it.
%   Unserved heat and dumped surplus heat are tracked and returned rather
%   than silently absorbed; main_month4h reports them alongside cost, and a
%   cost comparison against a controller that failed to serve load is not a
%   like-for-like comparison.
%
%   Output struct res (fields chosen to match simulate_multiscale_day so the
%   two can be compared directly):
%     actualCost, emissions_kgCO2
%     Pg_imp5, Pg_exp5, PH2_5, SOCbatt5 (288x1)
%     heatUnmet_kWh, heatDumped_kWh
%     ID_SOC : per-device SOC trace, same field names as the optimized run

    thisFile = mfilename('fullpath');
    addpath(fileparts(thisFile));

    nT = 288;
    dt = 1/12;
    hourOf5 = ceil((1:nT)/12)';

    priceImp = fc.DA.priceImport(hourOf5);
    priceExp = fc.DA.priceExport(hourOf5);
    medPrice = median(fc.DA.priceImport);

    hpThermalMax = p.HeatPump.Pmax * p.HeatPump.COP;
    bkE = p.PWL.bkpt_e;  bkT = p.PWL.bkpt_th;

    % Marginal electrical cost of the fuel cell at its rated point. One
    % number, computed once -- a heuristic controller does not re-derive an
    % operating-point-dependent marginal cost every five minutes.
    etaE_rated = pwl_utils('eval', bkE.x, bkE.y, p.PWL.FC_H2_max) / p.PWL.FC_H2_max;
    fcMarginalCost = p.price_H2 / max(etaE_rated, 1e-6);

    SOC = struct('Batt', p.Batt.SOC0, 'EV', p.EV.SOC0, ...
                 'Building', p.Building.SOC0, 'Pipe', p.Pipe.SOC0);

    Pg_imp5 = zeros(nT,1); Pg_exp5 = zeros(nT,1); PH2_5 = zeros(nT,1);
    SOCbatt5 = zeros(nT,1);
    ID_SOC = struct('Batt', zeros(nT,1), 'EV', zeros(nT,1), ...
                    'Building', zeros(nT,1), 'Pipe', zeros(nT,1));
    heatUnmet = 0; heatDumped = 0;

    for t = 1:nT
        price  = priceImp(t);
        cheap  = price < medPrice;
        expens = price > medPrice;
        evOn   = ismember(hourOf5(t), p.EV.pluggedInHours);

        solar = p.eta_PV * fc.RT.solar(t);
        Lel   = fc.RT.Lelec(t);
        Lht   = fc.RT.Lheat(t);

        % ---- Rule 4: thermal storage, price-driven ---------------------
        % ...but charged ONLY from spare heat-pump capacity. Without this
        % limit the charging rule inflates the heat balance past what the
        % heat pump can serve and then rule 6a fires the FUEL CELL to make
        % up the difference -- i.e. the controller burns hydrogen at
        % $0.22/kWh purely to fill a thermal store. No competent engineer
        % would write that rule, and leaving it in would hand the optimizer
        % an unearned advantage in exactly the comparison this file exists
        % to make fair. The cap is a rule, not a look-ahead: it uses only
        % the current heat demand and the heat pump's rating.
        [bldCh, bldDis] = storage_rule(SOC.Building, p.Building, cheap, expens, dt);
        [pipCh, pipDis] = storage_rule(SOC.Pipe,     p.Pipe,     cheap, expens, dt);
        chargeBudget = max(0, hpThermalMax - Lht);
        wanted = bldCh + pipCh;
        if wanted > chargeBudget
            shrink = chargeBudget / wanted;
            bldCh = bldCh * shrink;
            pipCh = pipCh * shrink;
        end
        heatNeed = Lht + bldCh + pipCh - bldDis - pipDis;

        % ---- Rule 5: heat pump first -----------------------------------
        hpTh = min(max(heatNeed, 0), hpThermalMax);
        hpEl = hpTh / p.HeatPump.COP;
        deficit = max(heatNeed - hpTh, 0);

        % ---- Rule 6a: fuel cell must-run to close the heat balance -----
        PH2 = 0;
        if deficit > 1e-9
            PH2 = invert_pwl(bkT.x, bkT.y, deficit, p.PWL.FC_H2_max);
        end
        % ---- Rule 6b: fuel cell for electricity if it beats the grid ---
        if fcMarginalCost < price
            PH2 = p.PWL.FC_H2_max;
        end
        fcTh = pwl_utils('eval', bkT.x, bkT.y, PH2);
        fcEl = pwl_utils('eval', bkE.x, bkE.y, PH2);

        % Heat balance closes here, and any residual is recorded rather
        % than quietly dropped.
        heatSupplied = hpTh + fcTh;
        if heatSupplied > heatNeed + 1e-9
            surplus = heatSupplied - heatNeed;
            % Try to store the surplus before wasting it.
            room = min([p.Pipe.Pch_max - pipCh, ...
                        max(0, (p.Pipe.SOCmax - SOC.Pipe)) * p.Pipe.Emax / (p.Pipe.eta_ch*dt)]);
            take = max(0, min(surplus, room));
            pipCh = pipCh + take;
            heatDumped = heatDumped + (surplus - take)*dt;
        elseif heatSupplied < heatNeed - 1e-9
            heatUnmet = heatUnmet + (heatNeed - heatSupplied)*dt;
        end

        % ---- Rule 3: electrical storage, price-driven ------------------
        [batCh, batDis] = storage_rule(SOC.Batt, p.Batt, cheap, expens, dt);
        if evOn
            [evCh, evDis] = storage_rule(SOC.EV, p.EV, cheap, expens, dt);
        else
            evCh = 0; evDis = 0;
        end

        % ---- Rule 7: the grid takes the remainder ----------------------
        net = (Lel + hpEl + batCh + evCh) - (solar + fcEl + batDis + evDis);
        Pg_imp5(t) = max(net, 0);
        Pg_exp5(t) = max(-net, 0);
        PH2_5(t)   = PH2;

        SOC.Batt     = clampSOC(storage_soc_update(SOC.Batt,     batCh, batDis, p.Batt,     dt), p.Batt);
        SOC.EV       = clampSOC(storage_soc_update(SOC.EV,       evCh,  evDis,  p.EV,       dt), p.EV);
        SOC.Building = clampSOC(storage_soc_update(SOC.Building, bldCh, bldDis, p.Building, dt), p.Building);
        SOC.Pipe     = clampSOC(storage_soc_update(SOC.Pipe,     pipCh, pipDis, p.Pipe,     dt), p.Pipe);

        SOCbatt5(t)        = SOC.Batt;
        ID_SOC.Batt(t)     = SOC.Batt;
        ID_SOC.EV(t)       = SOC.EV;
        ID_SOC.Building(t) = SOC.Building;
        ID_SOC.Pipe(t)     = SOC.Pipe;
    end

    res.Pg_imp5  = Pg_imp5;
    res.Pg_exp5  = Pg_exp5;
    res.PH2_5    = PH2_5;
    res.SOCbatt5 = SOCbatt5;
    res.ID_SOC   = ID_SOC;
    res.actualCost = sum(priceImp.*Pg_imp5 - priceExp.*Pg_exp5 + p.price_H2*PH2_5) * dt;
    res.emissions_kgCO2 = sum((Pg_imp5 - Pg_exp5)*p.co2.gridFactor + PH2_5*p.co2.H2Factor) * dt;
    res.heatUnmet_kWh  = heatUnmet;
    res.heatDumped_kWh = heatDumped;
    res.fcMarginalCost = fcMarginalCost;
    res.medPrice       = medPrice;
end

function [pch, pdis] = storage_rule(soc, dev, cheap, expens, dt)
% Charge flat out when cheap, discharge flat out when expensive, always
% inside the usable SOC band. No look-ahead of any kind.
    pch = 0; pdis = 0;
    if cheap
        room = max(0, dev.SOCmax - soc) * dev.Emax / (dev.eta_ch * dt);
        pch  = min(dev.Pch_max, room);
    elseif expens
        avail = max(0, soc - dev.SOCmin) * dev.Emax * dev.eta_dis / dt;
        pdis  = min(dev.Pdis_max, avail);
    end
end

function soc = clampSOC(soc, dev)
% Guard against accumulating a few 1e-15 excursions over 288 steps.
    soc = min(max(soc, dev.SOCmin), dev.SOCmax);
end

function x = invert_pwl(xb, yb, yTarget, xMax)
% Smallest input giving at least yTarget on a monotone PWL curve, clamped
% to the device rating. Used to size the fuel cell against a heat deficit.
    yTarget = min(max(yTarget, 0), yb(end));
    x = interp1(yb(:), xb(:), yTarget, 'linear');
    if isnan(x); x = xMax; end
    x = min(max(x, 0), xMax);
end
