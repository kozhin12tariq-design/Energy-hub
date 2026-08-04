function sf = season_profile_factors(season)
%SEASON_PROFILE_FACTORS Seasonal scaling of the demand and PV profiles.
%
%   sf = SEASON_PROFILE_FACTORS(season)   season = 'winter'|'shoulder'|'summer'
%
%   Every result in this project used to come from ONE generic 24-hour day.
%   For a MULTI-CARRIER system that is the largest remaining realism gap,
%   because the carriers move in OPPOSITE directions across the year: heat
%   demand peaks when PV output is at its minimum, and a single averaged day
%   hides exactly the coupling the thesis is about. This file supplies the
%   seasonal factors; forecast_profiles.m applies them.
%
%   'shoulder' REPRODUCES THE PREVIOUS PROFILES EXACTLY -- every factor is
%   1.0 and the daylight window is the file's original 06:00-19:00. Every
%   result published before seasons existed is therefore still reachable,
%   unchanged, under that label.
%
%   ------------------------------------------------------------------
%   WHERE EACH NUMBER COMES FROM. Three categories, labelled, because they
%   carry different weight and a reader is entitled to know which is which:
%     [SOURCED]   a published standard or figure, quoted below
%     [GEOMETRY]  exact astronomy or arithmetic, no citation needed
%     [ASSUMED]   a stated assumption -- could not be sourced in this
%                 environment, so it is declared rather than dressed up
%
%   REPRESENTATIVE DAYS [SOURCED]. The three seasons are the BDEW/VDEW
%   standard-load-profile seasons used by German distribution utilities:
%       winter      1 Nov - 20 Mar
%       transition  21 Mar - 14 May and 15 Sep - 31 Oct   ("shoulder" here)
%       summer      15 May - 14 Sep
%   One representative day is taken near the middle of each: 15 January
%   (day 15), 15 April (day 105), 15 July (day 196).
%
%   ELECTRICAL DEMAND [SOURCED]. The BDEW/VDEW H0 household profile carries
%   an official DYNAMISATION FUNCTION, a 4th-order polynomial in the day of
%   the year that modulates annual consumption:
%
%       f(t) = -3.92e-10*t^4 + 3.20e-7*t^3 - 7.02e-5*t^2 + 2.10e-3*t + 1.24
%
%   Evaluated at the three representative days and NORMALISED TO THE
%   SHOULDER DAY (so shoulder is exactly 1.000 and nothing pre-existing
%   moves):
%       f(15) = 1.256765,  f(105) = 1.009337,  f(196) = 0.785739
%       winter 1.2451   shoulder 1.0000   summer 0.7785
%   Note f(105) = 1.009, i.e. the transition day sits almost exactly at the
%   annual mean. That is a property of the published curve, not a choice,
%   and it is why anchoring on the shoulder day costs nothing.
%
%   NO SUMMER COOLING IS MODELLED, and that is a decision with consequences.
%   Residential air-conditioning penetration in Germany is low, and the H0
%   dynamisation above -- which is measured German household behaviour --
%   already reflects that by putting summer BELOW the annual mean. A study
%   in a cooling-dominated climate would need the opposite sign here and
%   would reach different conclusions about summer.
%
%   EVENING PEAK HOUR [GEOMETRY, generalising the existing profile]. The
%   pre-existing curve places its evening demand peak at hour 19 -- which is
%   exactly its own sunset hour. That coincidence is promoted to a rule
%   rather than a new invention: the evening lighting/occupancy peak follows
%   sunset. Winter therefore peaks at 16.50 and summer at 20.53. The MORNING
%   peak stays at 08:00 in every season, because it is set by work and
%   school routine rather than by daylight.
%
%   DAY LENGTH [GEOMETRY]. Magdeburg, 52.13 deg N. Declination from Cooper's
%   equation, delta = 23.45*sin(360*(284+n)/365); day length
%   L = (2/15)*acos(-tan(phi)*tan(delta)) hours:
%       15 Jan  delta = -21.27 deg  L =  7.99 h
%       15 Apr  delta =  +9.42 deg  L = 13.64 h
%       15 Jul  delta = +21.52 deg  L = 16.06 h
%   The daylight window is centred on 12:30 in every season, because the
%   pre-existing 06:00-19:00 window is centred there.
%
%   ONE DISCREPANCY, STATED RATHER THAN SMOOTHED: the shoulder window is
%   kept at the original 13.00 h so nothing pre-existing changes, while the
%   geometry gives 13.64 h for 15 April. The 0.64 h difference is carried
%   openly; it makes the shoulder day slightly shorter than mid-April
%   actually is, which if anything understates shoulder PV.
%
%   PV PEAK AMPLITUDE [ASSUMED yield, GEOMETRY elsewhere]. The peak is not
%   set directly. Daily PV ENERGY is set from monthly specific yield, day
%   length comes from the geometry above, and the peak of the half-sine
%   falls out of E = P_peak * (2/pi) * L. Assumed monthly specific yields
%   for central Germany at roughly this latitude, optimally inclined:
%       January 22, April 112, July 128 kWh/kWp/month
%   These are DECLARED ASSUMPTIONS: PVGIS and the monthly-yield tables were
%   unreachable from this environment, so they are stated as figures of the
%   right order rather than presented as sourced. They are consistent with
%   the one published seasonality figure that was reachable -- that German
%   PV output between peak-month June and weakest-month December differs by
%   "a factor of up to 10"; the assumed set gives 8.2, inside that bound.
%   Resulting peak factors relative to the shoulder day:
%       winter 0.3091   shoulder 1.0000   summer 0.8952
%
%   READ THAT SUMMER FIGURE CAREFULLY, because it is counter-intuitive and
%   it is not a mistake: the summer PEAK is about 10% BELOW the April peak,
%   while summer daily ENERGY is 11% ABOVE it. At 52 deg N the extra summer
%   yield comes almost entirely from a 2.4-hour-longer day, not from a
%   higher midday output. Anyone expecting "summer PV is much bigger" should
%   look at the energy row, not the peak row.
%
%   HEAT DEMAND [SOURCED method, ASSUMED temperatures]. Degree-day method
%   per VDI 3807 / VDI 2067 as used in Germany: room temperature 20 C,
%   heating limit 15 C, so a day contributes (20 - T_mean) degree-days when
%   T_mean < 15 C and nothing otherwise. Assumed long-term monthly mean
%   temperatures for Magdeburg (declared, not sourced): January 0.5 C,
%   April 9.0 C, July 18.5 C. Degree-days per day 19.5 / 11.0 / 0.0, hence
%       winter 1.7727   shoulder 1.0000   summer 0.0000
%   applied to the SPACE-HEATING part only.
%
%   The split between space heating and domestic hot water is taken from the
%   pre-existing curve's own structure: it is floored at 5 kW, i.e. its
%   author already declared 5 kW to be the irreducible heat demand. That
%   5 kW is treated as the DHW baseline and is NOT scaled; everything above
%   it is space heating and is. Summer therefore comes out as a flat 5 kW
%   DHW load with no space heating at all, which is the intended behaviour.
%   DHW is held constant across seasons -- real DHW rises modestly in winter
%   because mains water is colder, and ignoring that slightly understates
%   winter heat. Stated, not hidden.
%
%   EV AVAILABILITY: DELIBERATELY NOT VARIED. p.EV.pluggedInHours models a
%   commuting pattern (away during the working day, plugged in evening and
%   overnight), and commuting hours are not strongly seasonal. Varying them
%   would add an unsourced degree of freedom that could move results without
%   any evidence behind it, so it is left alone and said so.
%
%   PRICES: NOT VARIED EITHER. Real day-ahead prices are seasonal, but this
%   project uses a fixed three-tier tariff, and moving prices per season
%   would confound "the seasons changed the physics" with "the seasons
%   changed the tariff". The seasonal comparison is therefore at constant
%   prices by construction.
%
%   Output struct sf:
%     name          : the season string, echoed back
%     dayOfYear     : representative day
%     elecFactor    : multiplies the whole electrical demand curve
%     heatFactor    : multiplies the SPACE-HEATING part of the heat curve
%     dhw_kW        : unscaled domestic-hot-water baseline (5 kW at hubScale 1)
%     pvPeakFactor  : multiplies the PV peak
%     sunrise, sunset, dayLength_h : daylight window (hours, decimal)
%     eveningPeakHour              : hour of the electrical evening peak

    if nargin < 1 || isempty(season); season = 'shoulder'; end
    season = lower(strtrim(season));

    switch season
        case 'winter'
            sf.dayOfYear    = 15;
            sf.elecFactor   = 1.2451;
            sf.heatFactor   = 1.7727;
            sf.pvPeakFactor = 0.3091;
            sf.dayLength_h  = 7.9949;
        case 'shoulder'
            % Every factor exactly 1 and the original 13-hour window: this
            % case must reproduce the pre-seasonal profiles bit for bit.
            sf.dayOfYear    = 105;
            sf.elecFactor   = 1.0;
            sf.heatFactor   = 1.0;
            sf.pvPeakFactor = 1.0;
            sf.dayLength_h  = 13.0;
        case 'summer'
            sf.dayOfYear    = 196;
            sf.elecFactor   = 0.7785;
            sf.heatFactor   = 0.0;
            sf.pvPeakFactor = 0.8952;
            sf.dayLength_h  = 16.0619;
        otherwise
            error('season_profile_factors:season', ...
                'Unknown season "%s" (use ''winter'', ''shoulder'' or ''summer'').', season);
    end

    sf.name   = season;
    sf.dhw_kW = 5.0;    % at hubScale = 1; forecast_profiles scales it with the rest

    % Daylight window centred on 12:30, matching the original 06:00-19:00.
    solarNoon  = 12.5;
    sf.sunrise = solarNoon - sf.dayLength_h/2;
    sf.sunset  = solarNoon + sf.dayLength_h/2;

    % The original profile put its evening electrical peak exactly at its own
    % sunset hour; that rule is retained rather than re-invented per season.
    sf.eveningPeakHour = sf.sunset;
end
