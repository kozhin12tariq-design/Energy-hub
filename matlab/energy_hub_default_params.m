function p = energy_hub_default_params()
%ENERGY_HUB_DEFAULT_PARAMS Default technical parameters for the hub components.

    % Converter efficiencies
    p.eta_FC = 0.50;   % fuel cell electrical efficiency (H2 -> elec)
    p.eta_PV = 0.97;   % PV array + inverter efficiency (solar -> elec)

    % Battery energy storage (e.g. residential BESS)
    p.Batt.eta_ch  = 0.95;  % charging efficiency
    p.Batt.eta_dis = 0.95;  % discharging efficiency
    p.Batt.Emax    = 13.5;  % kWh, usable capacity
    p.Batt.SOCmin  = 0.10;  % fraction
    p.Batt.SOCmax  = 0.90;  % fraction
    p.Batt.SOC0    = 0.50;  % initial state of charge (fraction)
    p.Batt.Pch_max = 5.0;   % kW
    p.Batt.Pdis_max = 5.0;  % kW

    % Electric vehicle battery (V2G capable)
    p.EV.eta_ch  = 0.90;
    p.EV.eta_dis = 0.90;
    p.EV.Emax    = 60.0;    % kWh
    p.EV.SOCmin  = 0.20;
    p.EV.SOCmax  = 0.95;
    p.EV.SOC0    = 0.50;
    p.EV.Pch_max = 7.0;     % kW
    p.EV.Pdis_max = 7.0;    % kW, V2G discharge limit
end
