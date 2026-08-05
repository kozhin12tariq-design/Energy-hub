function fc = forecast_profiles(seed, uncertaintyScale, hubScale, season)
%FORECAST_PROFILES Day-ahead / intraday / real-time forecast hierarchy.
%
%   fc = FORECAST_PROFILES(seed, uncertaintyScale, hubScale, season)
%
%   Generates one self-consistent 24-hour scenario at three resolutions
%   with decreasing uncertainty, matching the three dispatch levels:
%     - Day-ahead (hourly, 24 points): smooth, idealized forecast curves
%       with NO noise -- what you'd plan a day in advance from a
%       weather/load forecast, deliberately the least accurate relative
%       to what actually happens.
%     - "True" realized values (5-minute, 288 points): the actual
%       ground truth, built as the day-ahead curve plus persistent
%       autocorrelated noise (cloud transients on solar, load
%       fluctuations), i.e. what real-time dispatch must balance against.
%     - Intraday updated forecast (15-minute, 96 points): the 15-min
%       average of the true profile plus a SMALLER residual noise term,
%       i.e. an imperfect but much-improved near-term forecast.
%
%   seed             : RNG seed for reproducibility (same seed -> same scenario)
%   uncertaintyScale : multiplies every noise std dev (default 1 = the
%                      base scenario used throughout this repo); used by
%                      main_sensitivity_analysis.m to sweep forecast-error
%                      severity without changing anything else about the
%                      scenario.
%   hubScale         : multiplies the three POWER profiles (solar, Lelec,
%                      Lheat) so the local demand and PV array match the
%                      hub's equipment ratings. Defaults to
%                      hub_sizing().scale, the SAME value
%                      multiscale_default_params.m applies to those
%                      ratings -- both read it from hub_sizing.m so the
%                      two cannot drift apart. Pass 1.0 to reproduce the
%                      pre-re-siting profiles exactly. Prices and noise
%                      statistics are NOT scaled: a price is intensive,
%                      and the noise is multiplicative (a fraction of the
%                      profile), so a bigger hub sees proportionally
%                      bigger absolute forecast errors automatically, with
%                      the same relative uncertainty.
%   season           : 'winter' | 'shoulder' (default) | 'summer'. Scales
%                      and reshapes the three profiles for the season; see
%                      season_profile_factors.m, which documents where every
%                      factor comes from and labels each as sourced,
%                      geometric or assumed. 'shoulder' reproduces the
%                      pre-seasonal profiles EXACTLY, so every result
%                      published before seasons existed remains reachable
%                      unchanged under that label.
%
%   WHY SEASONS MATTER HERE MORE THAN IN A SINGLE-CARRIER STUDY: heat demand
%   peaks when PV output is at its minimum, so a single averaged day cancels
%   the two carriers against each other and hides the coupling the thesis is
%   about. The seasonal cases are not decoration; they are the only way to
%   see whether a conclusion drawn on one day generalises.
%
%   MODEL BOUNDARY -- WHAT `solar` IS: the `solar` series is the PV
%   array's AVAILABLE DC ELECTRICAL OUTPUT in kW (a 50*hubScale kW-peak
%   array; 50 kW at hubScale = 1, 233 kW at the default 4.6667),
%   NOT irradiance in W/m^2. Module-level conversion of sunlight to DC
%   power (~15-22% for real silicon modules) is upstream of this model
%   and is already baked into these numbers. That is why the dispatch
%   applies p.eta_PV = 0.97 to it: 0.97 is the INVERTER/converter
%   efficiency downstream of the array, not a solar-to-electricity
%   efficiency.
%
%   Output struct fc, all power in kW, price in $/kWh:
%     hours (24x1), slots15 (96x1), slots5 (288x1)
%     DA.solar, DA.Lelec, DA.Lheat, DA.priceImport, DA.priceExport   (24x1)
%     ID.solar, ID.Lelec, ID.Lheat                                   (96x1)
%     RT.solar, RT.Lelec, RT.Lheat                                   (288x1)

    if nargin < 1 || isempty(seed); seed = 42; end
    if nargin < 2 || isempty(uncertaintyScale); uncertaintyScale = 1.0; end
    if nargin < 3 || isempty(hubScale)
        thisFile = mfilename('fullpath');
        addpath(fileparts(thisFile));
        hs = hub_sizing();
        hubScale = hs.scale;
    end
    if nargin < 4 || isempty(season); season = 'shoulder'; end
    sf = season_profile_factors(season);
    rand('seed', seed); %#ok<RAND> -- Octave-compatible seeding
    randn('seed', seed); %#ok<RAND>

    hours = (1:24)';
    slots15 = (1:96)';    % 15-min slots across the day
    slots5  = (1:288)';   % 5-min slots across the day

    % ---- Day-ahead (hourly, smooth/idealized) --------------------------
    % 50 = array DC peak in kW (already-generated electrical power), not
    % irradiance -- see the MODEL BOUNDARY note in the header above.
    %
    % The three curves are built at hubScale = 1 and multiplied by hubScale
    % as the LAST step, so scaling is provably shape-preserving: every
    % ratio between the curves, every peak hour, and the 5 kW overnight
    % heat floor all move together. (Writing 50*hubScale inline and
    % forgetting the max(...,5) floor would silently flatten the heat
    % profile at large hubScale -- doing it in one place makes that
    % impossible.)
    % PV: half-sine across the season's own daylight window. At 'shoulder'
    % sunrise/sunset/peak are 6/19/1.0 and this is character-for-character
    % the original expression.
    solar_DA = max(0, 50*sf.pvPeakFactor*sin(pi*(hours-sf.sunrise)/sf.dayLength_h));
    solar_DA(hours < sf.sunrise | hours > sf.sunset) = 0;

    % Electrical demand: BDEW H0 seasonal magnitude, morning peak fixed at
    % 08:00 (work/school routine), evening peak following sunset (lighting
    % and occupancy). At 'shoulder' the evening peak is hour 19 and the
    % factor is 1.0, reproducing the original curve exactly.
    Lelec_DA = sf.elecFactor * ( 20 ...
             + 15*exp(-((hours-8).^2)/8) ...
             + 25*exp(-((hours-sf.eveningPeakHour).^2)/8) );

    % Heat: a constant domestic-hot-water baseline that does NOT scale, plus
    % a space-heating component scaled by degree days. Summer therefore
    % collapses to DHW alone. At 'shoulder' heatFactor = 1 and this returns
    % the original curve unchanged.
    heatShoulder = 15 + 12*exp(-((hours-7).^2)/6) + 14*exp(-((hours-21).^2)/10) - 5*exp(-((hours-13).^2)/20);
    heatShoulder = max(heatShoulder, 5);
    Lheat_DA = sf.dhw_kW + sf.heatFactor * (heatShoulder - sf.dhw_kW);

    solar_DA = hubScale * solar_DA;
    Lelec_DA = hubScale * Lelec_DA;
    Lheat_DA = hubScale * Lheat_DA;

    priceImport_DA = 0.18*ones(24,1);
    priceImport_DA(hours>=1 & hours<=6) = 0.10;
    priceImport_DA(hours>=17 & hours<=21) = 0.32;
    priceExport_DA = 0.05*ones(24,1);

    % ---- "True" realized values (5-min, hourly curve + AR(1) noise) ---
    t5_hours = (slots5 - 0.5) * (5/60);  % hour-of-day at the midpoint of each 5-min slot
    solar_shape = interp1(hours, solar_DA, t5_hours, 'linear', 'extrap');
    Lelec_shape = interp1(hours, Lelec_DA, t5_hours, 'linear', 'extrap');
    Lheat_shape = interp1(hours, Lheat_DA, t5_hours, 'linear', 'extrap');

    solar_noise = ar1_noise(288, 0.85, 0.10*uncertaintyScale);   % slow-varying multiplicative cloud transients
    Lelec_noise = ar1_noise(288, 0.7, 0.06*uncertaintyScale);
    Lheat_noise = ar1_noise(288, 0.7, 0.05*uncertaintyScale);

    solar_RT = max(0, solar_shape .* (1 + solar_noise));
    solar_RT(solar_shape <= 0) = 0;
    Lelec_RT = max(0, Lelec_shape .* (1 + Lelec_noise));
    Lheat_RT = max(0, Lheat_shape .* (1 + Lheat_noise));

    % ---- Intraday updated forecast (15-min avg of true + smaller noise) -
    solar_ID = zeros(96,1); Lelec_ID = zeros(96,1); Lheat_ID = zeros(96,1);
    for k = 1:96
        idx5 = (3*(k-1)+1):(3*k);
        solar_ID(k) = mean(solar_RT(idx5));
        Lelec_ID(k) = mean(Lelec_RT(idx5));
        Lheat_ID(k) = mean(Lheat_RT(idx5));
    end
    solar_ID = max(0, solar_ID .* (1 + ar1_noise(96, 0.6, 0.04*uncertaintyScale)));
    Lelec_ID = max(0, Lelec_ID .* (1 + ar1_noise(96, 0.5, 0.03*uncertaintyScale)));
    Lheat_ID = max(0, Lheat_ID .* (1 + ar1_noise(96, 0.5, 0.03*uncertaintyScale)));

    fc.hubScale = hubScale;   % recorded so any consumer can tell what size it holds
    fc.season   = sf.name;    % ditto for which season it holds
    fc.ambientC = sf.ambientC;  % drives heatpump_curve.m; same number that
                                % sets the degree-day heat factor above
    fc.seasonFactors = sf;
    fc.hours = hours; fc.slots15 = slots15; fc.slots5 = slots5;
    fc.DA.solar = solar_DA; fc.DA.Lelec = Lelec_DA; fc.DA.Lheat = Lheat_DA;
    fc.DA.priceImport = priceImport_DA; fc.DA.priceExport = priceExport_DA;
    fc.ID.solar = solar_ID; fc.ID.Lelec = Lelec_ID; fc.ID.Lheat = Lheat_ID;
    fc.RT.solar = solar_RT; fc.RT.Lelec = Lelec_RT; fc.RT.Lheat = Lheat_RT;
end

function n = ar1_noise(N, phi, sigma)
% Zero-mean AR(1) noise sequence: n(k) = phi*n(k-1) + eps, eps~N(0,sigma^2*(1-phi^2))
% (variance-normalized so the stationary std of n is approximately sigma).
    n = zeros(N,1);
    innovStd = sigma * sqrt(1 - phi^2);
    for k = 2:N
        n(k) = phi*n(k-1) + innovStd*randn();
    end
end
