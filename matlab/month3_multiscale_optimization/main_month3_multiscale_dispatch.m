%MAIN_MONTH3_MULTISCALE_DISPATCH
%Thesis roadmap Month 3: multi-time-space scale optimization for a
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
%   shared state threaded through the whole simulation
%   (simulate_multiscale_day.m): each level starts from where the
%   previous one actually left the system, not from its own plan. This
%   script is a thin driver around that function (also reused by Month
%   4's case studies/sensitivity analysis) plus its own printing/plots.
%
%   Run with:  main_month3_multiscale_dispatch

clear; clc;

p = multiscale_default_params();
fc = forecast_profiles(42);

fprintf('=====================================================\n');
fprintf(' Level 1: Day-ahead robust-proxy schedule (hourly)\n');
fprintf('=====================================================\n');

res = simulate_multiscale_day(p, fc, struct('useIntraday', true, 'reserveScale', 1.0));
DA = res.DA;

fprintf('status=%d, planned 24h cost = $%.2f\n', DA.status, DA.cost);
fprintf('Energy mix (kWh): solar=%.0f, FC fuel=%.0f, heat pump elec=%.0f, grid import=%.0f, grid export=%.0f\n', ...
    sum(DA.Ps), sum(DA.PH2), sum(DA.Php), sum(DA.Pg_imp), sum(DA.Pg_exp));

fprintf('\n=====================================================\n');
fprintf(' Levels 2+3: Intraday (15-min) + real-time (5-min) rolling dispatch\n');
fprintf('=====================================================\n');
fprintf('All 96 intraday slots and 288 real-time sub-steps solved to optimality.\n');

idCost = sum(fc.DA.priceImport(ceil((1:96)/4)).*res.ID_Pg_imp*0.25 ...
    - fc.DA.priceExport(ceil((1:96)/4)).*res.ID_Pg_exp*0.25 + p.price_H2*res.ID_PH2*0.25);

fprintf('\n=====================================================\n');
fprintf(' Summary\n');
fprintf('=====================================================\n');
fprintf('Day-ahead planned cost:                 $%.2f\n', res.plannedCost);
fprintf('Intraday planned cost (sum of commits):  $%.2f\n', idCost);
fprintf('Actual realized cost (after real-time):  $%.2f\n', res.actualCost);
fprintf('Mean |real-time imbalance corrected|:     %.3f kW (max %.3f kW)\n', ...
    mean(abs(res.RT_imbalance)), max(abs(res.RT_imbalance)));
fprintf('Battery SOC range across the day: %.3f - %.3f (bounds [%.2f, %.2f])\n', ...
    min(res.SOCbatt5), max(res.SOCbatt5), p.Batt.SOCmin, p.Batt.SOCmax);
fprintf('Building thermal SOC range:       %.3f - %.3f (bounds [%.2f, %.2f])\n', ...
    min(res.ID_SOC.Building), max(res.ID_SOC.Building), p.Building.SOCmin, p.Building.SOCmax);
fprintf('Pipe thermal SOC range:            %.3f - %.3f (bounds [%.2f, %.2f])\n', ...
    min(res.ID_SOC.Pipe), max(res.ID_SOC.Pipe), p.Pipe.SOCmin, p.Pipe.SOCmax);

%% Plots -------------------------------------------------------------
try
    tHours = (1:288)/12;

    figure('Position',[100 100 1100 800]);
    subplot(3,1,1);
    plot(fc.hours, DA.Pg_imp - DA.Pg_exp, '-o', 'DisplayName','Day-ahead plan'); hold on;
    plot((1:96)/4, res.ID_Pg_imp - res.ID_Pg_exp, '-', 'DisplayName','Intraday committed');
    plot(tHours, res.Pg_imp5 - res.Pg_exp5, '-', 'LineWidth',1, 'DisplayName','Real-time actual');
    ylabel('Net grid import (kW)'); legend('Location','northeast'); grid on;
    title('Grid interchange across the three dispatch levels');

    subplot(3,1,2);
    plot(tHours, res.SOCbatt5, 'DisplayName','Battery'); hold on;
    plot((1:96)/4, res.ID_SOC.EV, 'DisplayName','EV fleet');
    plot((1:96)/4, res.ID_SOC.Building, 'DisplayName','Building thermal mass');
    plot((1:96)/4, res.ID_SOC.Pipe, 'DisplayName','Pipe thermal storage');
    ylabel('SOC (0-1)'); xlabel('Hour of day'); legend('Location','northeast'); grid on;
    title('Generalized storage state of charge (all four devices, one shared state equation)');

    subplot(3,1,3);
    bar(tHours, res.RT_imbalance);
    ylabel('kW'); xlabel('Hour of day'); grid on;
    title('Real-time correction magnitude (deviation of actual grid flow from intraday commitment)');

catch plot_err
    fprintf('\n[plots skipped: %s]\n', plot_err.message);
end
