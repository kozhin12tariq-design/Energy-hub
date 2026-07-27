%MAIN_MULTISCALE_DISPATCH Multi-time-space scale optimization for a
%distributed integrated energy system.
%
%   Coordinates three dispatch levels over one simulated day:
%     1) Day-ahead (hourly, 24 steps): LP with a reserve-margin
%        robustness proxy, run ONCE at the start of the day.
%     2) Intraday (15-min, 96 steps): rolling two-stage stochastic LP,
%        re-solved every slot using an updated forecast, tracking the
%        day-ahead plan with a soft penalty while adapting to better
%        near-term information.
%     3) Real-time (5-min, 288 steps): fast electrical-only balancing LP
%        against ACTUAL realized solar/load, correcting the small
%        remaining mismatch primarily with the battery.
%
%   Generalized storage (battery, EV, building thermal mass, district-
%   heating pipe storage) is coordinated across all three levels via one
%   shared state that is threaded through the whole simulation: each
%   level starts from where the previous one actually left the system,
%   not from its own plan.
%
%   Run with:  main_multiscale_dispatch

clear; clc;

p = multiscale_default_params();
fc = forecast_profiles(42);

%% 1) Day-ahead ------------------------------------------------------------
fprintf('=====================================================\n');
fprintf(' Level 1: Day-ahead robust-proxy schedule (hourly)\n');
fprintf('=====================================================\n');

DA = dayahead_dispatch(p, fc);
fprintf('status=%d, planned 24h cost = $%.2f\n', DA.status, DA.cost);
fprintf('Energy mix (kWh): solar=%.0f, FC fuel=%.0f, heat pump elec=%.0f, grid import=%.0f, grid export=%.0f\n', ...
    sum(DA.Ps), sum(DA.PH2), sum(DA.Php), sum(DA.Pg_imp), sum(DA.Pg_exp));

% Day-ahead SOC reference, interpolated to 15-min resolution, for
% intraday's tracking penalty (hour 0 = each device's initial SOC0).
socRef15 = struct();
hourGrid = [0; fc.hours];
socRef15.Batt     = interp1(hourGrid, [p.Batt.SOC0;     DA.SOCbatt'], (1:96)'*0.25, 'linear');
socRef15.EV       = interp1(hourGrid, [p.EV.SOC0;       DA.SOCev'],   (1:96)'*0.25, 'linear');
socRef15.Building = interp1(hourGrid, [p.Building.SOC0; DA.SOCbld'],  (1:96)'*0.25, 'linear');
socRef15.Pipe     = interp1(hourGrid, [p.Pipe.SOC0;     DA.SOCpipe'], (1:96)'*0.25, 'linear');

%% 2)+3) Rolling intraday + real-time ---------------------------------------
fprintf('\n=====================================================\n');
fprintf(' Levels 2+3: Intraday (15-min) + real-time (5-min) rolling dispatch\n');
fprintf('=====================================================\n');

SOCstate.Batt = p.Batt.SOC0; SOCstate.EV = p.EV.SOC0;
SOCstate.Building = p.Building.SOC0; SOCstate.Pipe = p.Pipe.SOC0;

scenMult = [0.6, 1.0, 1.4];  % low/mid/high solar scenario multipliers
scenProb = [0.25; 0.5; 0.25];
trackWeight = 30;

fields = {'Pg_imp','Pg_exp','PH2','Php','Ps','Pbatt_ch','Pbatt_dis', ...
          'Pev_ch','Pev_dis','Pbld_ch','Pbld_dis','Ppipe_ch','Ppipe_dis'};
ID_committed = struct(); RT_actual = struct();
for fn = fields
    ID_committed.(fn{1}) = zeros(96,1);
    RT_actual.(fn{1}) = zeros(288,1);
end
ID_SOC = struct('Batt',zeros(96,1),'EV',zeros(96,1),'Building',zeros(96,1),'Pipe',zeros(96,1));
RT_SOCbatt = zeros(288,1);
RT_imbalance = zeros(288,1);
ID_cost = zeros(96,1);

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

    [committed, SOCafterID, infoID] = intraday_dispatch(p, SOCstate, evNow, evNext, ...
        fcNow, fcNextScen, scenProb, socRefNow, trackWeight);

    for fn = fields
        ID_committed.(fn{1})(k) = committed.(fn{1});
    end
    ID_SOC.Batt(k) = SOCafterID.Batt; ID_SOC.EV(k) = SOCafterID.EV;
    ID_SOC.Building(k) = SOCafterID.Building; ID_SOC.Pipe(k) = SOCafterID.Pipe;
    ID_cost(k) = fcNow.priceImport*committed.Pg_imp*0.25 - fcNow.priceExport*committed.Pg_exp*0.25 + p.price_H2*committed.PH2*0.25;

    % Real-time: 3x 5-min sub-steps within this 15-min slot, correcting
    % against the actually realized solar/load.
    SOCbatt5 = SOCstate.Batt;
    for j = 1:3
        m = (k-1)*3 + j;
        priceImport5 = fc.DA.priceImport(hourOfK); priceExport5 = fc.DA.priceExport(hourOfK);
        [actual, SOCbatt5, infoRT] = realtime_balance(p, SOCbatt5, committed, ...
            fc.RT.solar(m), fc.RT.Lelec(m), priceImport5, priceExport5);
        for fn = fields
            RT_actual.(fn{1})(m) = actual.(fn{1});
        end
        RT_SOCbatt(m) = SOCbatt5;
        RT_imbalance(m) = infoRT.imbalanceCorrected_kW;
    end

    % Thread state forward: battery from real-time's actual outcome;
    % EV/Building/Pipe (not touched by real-time) from intraday's plan.
    SOCstate.Batt = SOCbatt5;
    SOCstate.EV = SOCafterID.EV;
    SOCstate.Building = SOCafterID.Building;
    SOCstate.Pipe = SOCafterID.Pipe;
end

fprintf('All 96 intraday slots and 288 real-time sub-steps solved to optimality.\n');

%% 4) Summary ---------------------------------------------------------------
hourOf5 = ceil((1:288)/12)';
priceImport5v = fc.DA.priceImport(hourOf5);
priceExport5v = fc.DA.priceExport(hourOf5);
actualCost = sum(priceImport5v.*RT_actual.Pg_imp - priceExport5v.*RT_actual.Pg_exp + p.price_H2*RT_actual.PH2) * (1/12);

fprintf('\n=====================================================\n');
fprintf(' Summary\n');
fprintf('=====================================================\n');
fprintf('Day-ahead planned cost:                 $%.2f\n', DA.cost);
fprintf('Intraday planned cost (sum of commits):  $%.2f\n', sum(ID_cost));
fprintf('Actual realized cost (after real-time):  $%.2f\n', actualCost);
fprintf('Mean |real-time imbalance corrected|:     %.3f kW (max %.3f kW)\n', ...
    mean(abs(RT_imbalance)), max(abs(RT_imbalance)));
fprintf('Battery SOC range across the day: %.3f - %.3f (bounds [%.2f, %.2f])\n', ...
    min(RT_SOCbatt), max(RT_SOCbatt), p.Batt.SOCmin, p.Batt.SOCmax);
fprintf('Building thermal SOC range:       %.3f - %.3f (bounds [%.2f, %.2f])\n', ...
    min(ID_SOC.Building), max(ID_SOC.Building), p.Building.SOCmin, p.Building.SOCmax);
fprintf('Pipe thermal SOC range:            %.3f - %.3f (bounds [%.2f, %.2f])\n', ...
    min(ID_SOC.Pipe), max(ID_SOC.Pipe), p.Pipe.SOCmin, p.Pipe.SOCmax);

%% 5) Plots -------------------------------------------------------------
try
    tHours = (1:288)/12;

    figure('Position',[100 100 1100 800]);
    subplot(3,1,1);
    plot(fc.hours, DA.Pg_imp - DA.Pg_exp, '-o', 'DisplayName','Day-ahead plan'); hold on;
    plot((1:96)/4, ID_committed.Pg_imp - ID_committed.Pg_exp, '-', 'DisplayName','Intraday committed');
    plot(tHours, RT_actual.Pg_imp - RT_actual.Pg_exp, '-', 'LineWidth',1, 'DisplayName','Real-time actual');
    ylabel('Net grid import (kW)'); legend('Location','northeast'); grid on;
    title('Grid interchange across the three dispatch levels');

    subplot(3,1,2);
    plot(tHours, RT_SOCbatt, 'DisplayName','Battery'); hold on;
    plot((1:96)/4, ID_SOC.EV, 'DisplayName','EV fleet');
    plot((1:96)/4, ID_SOC.Building, 'DisplayName','Building thermal mass');
    plot((1:96)/4, ID_SOC.Pipe, 'DisplayName','Pipe thermal storage');
    ylabel('SOC (0-1)'); xlabel('Hour of day'); legend('Location','northeast'); grid on;
    title('Generalized storage state of charge (all four devices, one shared state equation)');

    subplot(3,1,3);
    bar(tHours, RT_imbalance);
    ylabel('kW'); xlabel('Hour of day'); grid on;
    title('Real-time correction magnitude (deviation of actual grid flow from intraday commitment)');

catch plot_err
    fprintf('\n[plots skipped: %s]\n', plot_err.message);
end
