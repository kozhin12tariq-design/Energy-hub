function eff = hub_efficiency(p, fc, res)
%HUB_EFFICIENCY Whole-hub energy conversion efficiency over a dispatched day.
%
%   eff = HUB_EFFICIENCY(p, fc, res)
%
%   WHY THIS EXISTS. The thesis brief requires the model to be assessed on
%   operational cost, carbon reduction, resilience AND EFFICIENCY. The first
%   three were reported; efficiency was not computed anywhere. Every
%   ingredient already existed -- PWL conversion curves, storage round-trip
%   efficiencies, heat-pump COP, feeder losses -- but no ratio of the form
%   useful-output / total-input was ever formed. This closes that gap.
%
%   IT COMPUTES ONLY. It reads a completed dispatch and forms ratios; it
%   solves nothing, changes nothing, and no dispatch reads it back.
%
%   ------------------------------------------------------------------
%   THE BOUNDARY, STATED EXPLICITLY BECAUSE THE NUMBER IS MEANINGLESS
%   WITHOUT IT.
%
%   PV is counted as DC ENERGY BEFORE THE INVERTER, and only the part
%   actually used (res.Ps5 is post-curtailment). Counting it as AC after the
%   inverter would move the inverter's own losses outside the boundary and
%   flatter the hub by construction. The inverter is part of the hub, so it
%   is charged for its losses. Curtailed sunlight is NOT an input: it was
%   never converted to anything.
%
%   HYDROGEN is counted as its chemical energy input (kW of fuel), which is
%   what p.PWL.FC_H2_max and the eta_FC_* curves are defined against.
%
%   STORAGE IS NOT SILENTLY IGNORED. Over one day the four stores do not
%   return to their starting SOC, and the gap is large enough to matter --
%   the battery alone can drain 40% of a 466 kWh capacity. The NET ENERGY
%   RELEASED by storage (E_start - E_end, summed over Batt, EV, Building,
%   Pipe) is therefore carried as an explicit INPUT term. It is signed: when
%   the stores end fuller than they began, the term is negative and reduces
%   available input, which is the correct accounting for energy parked
%   rather than delivered.
%
%   GRID EXPORT is treated as USEFUL OUTPUT, not as negative input. Exported
%   electricity serves load somewhere; charging the hub for producing it
%   would understate a design whose point is to export surplus PV. The net
%   convention is reported alongside as etaHubNet so a reader who prefers it
%   can have it, and the two are labelled rather than blended.
%
%   ------------------------------------------------------------------
%   THE HEAT PUMP MAKES 100% THE WRONG CEILING, AND THIS IS NOT A BUG.
%
%   A heat pump does not create heat, it MOVES it: at COP 4 it delivers four
%   units of heat for one unit of electricity, the other three lifted from
%   ambient air. Ambient heat is free and is not purchased, so a hub with a
%   heat pump can and should show a purchased-energy efficiency ABOVE 100%.
%   Reporting a number capped at 100% would require pretending the ambient
%   source does not exist.
%
%   Both are therefore reported and they answer different questions:
%
%     etaHub       = useful out / PURCHASED in   -- can exceed 100%.
%                    "How much delivered energy per unit of energy bought?"
%                    This is the one that belongs beside cost and carbon,
%                    because it is measured against what was paid for.
%
%     etaHubThermo = useful out / (purchased + ambient heat lifted)
%                    -- bounded by 100% by the first law. This is the one
%                    that must close, and it is the balance check.
%
%   Ambient heat lifted = HP heat delivered - HP electricity consumed.
%
%   ------------------------------------------------------------------
%   PHYSICS USES THE TRUE CONTINUOUS CURVES, not the planner's PWL fit. What
%   the machine actually converted is a property of the machine, not of the
%   model that scheduled it, so eta_FC_e_func / eta_FC_th_func and the heat
%   pump's true COP are used throughout. A coarse planning model shows up in
%   this metric only through the dispatch it chose -- which is the whole
%   point of measuring it.
%
%   Output struct eff:
%     etaHub, etaHubNet, etaHubThermo : the three ratios (fractions)
%     usefulOut_kWh                   : Lelec + Lheat + export
%     loadServed_kWh                  : Lelec + Lheat only
%     inPurchased_kWh                 : import + H2 + PV(DC) + storage release
%     inGrid_kWh, inH2_kWh, inPV_kWh  : the components
%     storageRelease_kWh              : signed, + = stores drained
%     ambientHeat_kWh                 : heat lifted from ambient by the HP
%     lossResidual_kWh                : input - output, i.e. losses by closure
%     lossAccounted_kWh               : losses summed device by device
%     balanceResidual_kWh             : lossResidual - lossAccounted. THE
%                                       CHECK. Near zero means the balance
%                                       closes and the ratio means something.
%     heatSurplus_kWh                 : converter heat produced minus heat
%                                       demand. Diagnostic, NOT a balance term.
%     thermStoreDrain_kWh             : energy the thermal stores lost over
%                                       the day, nearly all of it leakage.
%     renewableFraction               : PV(DC) / purchased input

    thisFile = mfilename('fullpath');
    addpath(fileparts(thisFile));
    addpath(fullfile(fileparts(thisFile), '..', 'month2_coupling_matrix_pwl_ieee33'));

    dt = 1/12;                        % hours per 5-minute interval

    % ---- useful output -------------------------------------------------
    eLelec = sum(fc.RT.Lelec(:)) * dt;
    eLheat = sum(fc.RT.Lheat(:)) * dt;
    eExp   = sum(res.Pg_exp5(:))  * dt;
    eff.loadServed_kWh = eLelec + eLheat;
    eff.usefulOut_kWh  = eLelec + eLheat + eExp;

    % ---- purchased / harvested input -----------------------------------
    eImp = sum(res.Pg_imp5(:)) * dt;
    eH2  = sum(max(res.PH2_5(:), 0)) * dt;
    % The conventional baseline burns gas in a boiler instead of running a
    % fuel cell and a heat pump. Its fuel is an input on exactly the same
    % footing as hydrogen, which is what makes the two comparable at all.
    if isfield(res, 'gas5'); eGas = sum(max(res.gas5(:), 0)) * dt; else; eGas = 0; end
    if isfield(res, 'Ps5'); ePV = sum(max(res.Ps5(:), 0)) * dt; else; ePV = 0; end

    stores = {'Batt', 'EV', 'Building', 'Pipe'};
    rel = 0;
    for i = 1:numel(stores)
        s = stores{i};
        if isfield(res, 'SOC0') && isfield(res.SOC0, s)
            rel = rel + (res.SOC0.(s) - res.SOCend.(s)) * p.(s).Emax;
        end
    end
    eff.storageRelease_kWh = rel;

    eff.inGrid_kWh = eImp; eff.inH2_kWh = eH2; eff.inPV_kWh = ePV;
    eff.inGas_kWh = eGas;
    eff.inPurchased_kWh = eImp + eH2 + ePV + eGas + rel;

    % ---- what each converter actually did, on the TRUE curves ----------
    PH2 = max(res.PH2_5(:), 0);
    uFC = PH2 / p.PWL.FC_H2_max;
    eFCe = sum(p.PWL.eta_FC_e_func(max(uFC, 1e-12))  .* PH2) * dt;
    eFCh = sum(p.PWL.eta_FC_th_func(max(uFC, 1e-12)) .* PH2) * dt;

    if isfield(res, 'Php5'); Php = max(res.Php5(:), 0); else; Php = zeros(288,1); end
    if isfield(p.HeatPump, 'usePWL') && p.HeatPump.usePWL
        if isfield(fc, 'ambientC'); amb = fc.ambientC; else; amb = []; end
        hp = heatpump_curve(p, amb);
        copTrue = hp.copRated * p.HeatPump.partLoad_func(max(Php / p.HeatPump.Pmax, 1e-9));
    else
        copTrue = p.HeatPump.COP * ones(size(Php));
    end
    eHPelec = sum(Php) * dt;
    eHPheat = sum(copTrue .* Php) * dt;
    eff.ambientHeat_kWh = eHPheat - eHPelec;      % lifted, not purchased

    % ---- the three ratios ----------------------------------------------
    eff.etaHub       = eff.usefulOut_kWh / max(eff.inPurchased_kWh, eps);
    eff.etaHubNet    = eff.loadServed_kWh / ...
                       max(eImp - eExp + eH2 + ePV + eGas + rel, eps);
    eff.etaHubThermo = eff.usefulOut_kWh / ...
                       max(eff.inPurchased_kWh + eff.ambientHeat_kWh, eps);

    % ---- the balance check ---------------------------------------------
    % Residual losses by closure, against losses accounted device by device.
    % These are computed by genuinely different routes: the first from the
    % boundary flows, the second from each converter's own curve. Agreement
    % is evidence the boundary is drawn consistently; disagreement would mean
    % the ratio above is measuring bookkeeping rather than physics.
    eff.lossResidual_kWh = (eff.inPurchased_kWh + eff.ambientHeat_kWh) - eff.usefulOut_kWh;

    lossPV  = (1 - p.eta_PV) * ePV;                    % inverter
    lossFC  = eH2 - eFCe - eFCh;                       % fuel cell, both outputs
    lossBoiler = (1 - p.Boiler.eta) * eGas;            % conventional case only
    [lossSto, lossSelf] = storage_losses(p, res, stores);
    eff.lossAccounted_kWh = lossPV + lossFC + lossSto + lossSelf + lossBoiler;
    eff.lossBoiler_kWh = lossBoiler;
    eff.lossPV_kWh = lossPV; eff.lossFC_kWh = lossFC;
    eff.lossStorage_kWh = lossSto; eff.lossSelfDischarge_kWh = lossSelf;

    eff.balanceResidual_kWh = eff.lossResidual_kWh - eff.lossAccounted_kWh;

    % THERMAL-NODE DIAGNOSTIC, deliberately NOT added to the balance. An
    % earlier version treated the surplus at the heat node as a separate
    % "dumped heat" term and subtracted it, which DOUBLE-COUNTED: the
    % thermal stores drain over the day, and almost all of that drain is
    % self-discharge leakage already charged in lossSelfDischarge_kWh. The
    % balance closes on the four loss terms alone, so nothing further is
    % subtracted and this is reported as an observation instead.
    thermRelease = 0;
    for i = 1:numel(stores)
        s = stores{i};
        if any(strcmp(s, {'Building', 'Pipe'})) && isfield(res, 'SOC0')
            thermRelease = thermRelease + (res.SOC0.(s) - res.SOCend.(s)) * p.(s).Emax;
        end
    end
    eff.heatSupplied_kWh    = eFCh + eHPheat + p.Boiler.eta * eGas;
    eff.heatSurplus_kWh     = eff.heatSupplied_kWh - eLheat;
    eff.thermStoreDrain_kWh = thermRelease;

    eff.renewableFraction = ePV / max(eff.inPurchased_kWh, eps);
end

function [L, S] = storage_losses(p, res, stores)
%STORAGE_LOSSES Round-trip AND self-discharge losses from the SOC trajectory.
%   Each SOC step is a charge or a discharge; the round-trip loss is the
%   shortfall against a lossless move. Self-discharge is separate and is NOT
%   negligible here -- the building thermal mass leaks at selfLoss = 0.15 per
%   hour, which over a day is a large term, and omitting it was the single
%   biggest gap in the first version of this balance.
%
%   selfLoss is a PER-HOUR rate: the dispatch applies (1 - selfLoss*dt) to
%   the previous SOC (see intraday_dispatch.m), so the energy lost in a step
%   is selfLoss * dt * SOC_prev * Emax. dt is 0.25 h on the intraday grid.
%
%   Uses res.ID_SOC, the trajectory actually executed. Returns zeros if it is
%   unavailable rather than guessing, and the balance residual then reports
%   the gap honestly instead of hiding it.
    L = 0; S = 0;
    if ~isfield(res, 'ID_SOC'); return; end
    dtID = 0.25;
    for i = 1:numel(stores)
        s = stores{i};
        if ~isfield(res.ID_SOC, s); continue; end
        traj = [res.SOC0.(s); res.ID_SOC.(s)(:)] * p.(s).Emax;
        d = diff(traj);
        up = d(d > 0); dn = -d(d < 0);
        L = L + sum(up) * (1/p.(s).eta_ch - 1) + sum(dn) * (1/p.(s).eta_dis - 1);
        S = S + sum(traj(1:end-1)) * p.(s).selfLoss * dtID;
    end
end
