function [cap, label] = feeder_capacity(p, fc, basis, refPeak)
%FEEDER_CAPACITY Contracted feeder capacity used by the reliability metric.
%
%   [cap, label] = FEEDER_CAPACITY(p, fc, basis, refPeak)
%
%   Centralises HOW the reliability threshold is set, because the choice
%   is methodological rather than incidental: a threshold derived from
%   the proposed system's own dispatch scores that system against a line
%   it drew itself. Both bases are provided so the two can be compared.
%
%   basis (defaults to p.reliability.capBasis):
%     'design' -- sized the way a real grid connection is sized, from the
%         installation's CONNECTED LOAD and a diversity factor:
%             cap = diversityFactor x ( peak electrical demand
%                                       + EV charger rating
%                                       + battery charger rating
%                                       + heat pump electrical rating )
%         Every term is an exogenous input (a forecast profile or a
%         nameplate rating). No dispatch STRATEGY influences it, so no
%         case is measured against a threshold of its own making. This is
%         the honest default.
%     'case4' -- p.reliability.feederCapMargin x refPeak, where refPeak is
%         the FULL system's own day-ahead peak import. Self-favourable
%         and retained only for side-by-side comparison.
%
%   refPeak is required for 'case4' and ignored for 'design'.
%
%   Returns the capacity in kW and a short human-readable label naming
%   the basis, so printed tables can always say which threshold produced
%   them.
%
%   NOTE ON SCOPE: this value is consumed ONLY by reliability_check.m,
%   after every case has already been simulated. It never enters
%   simulate_multiscale_day.m or any dispatch constraint, so changing the
%   basis cannot alter any case's cost, CO2 or peak -- it can only move
%   unmetEnergy and violationHours.

    if nargin < 3 || isempty(basis); basis = p.reliability.capBasis; end
    if nargin < 4; refPeak = []; end

    switch basis
        case 'design'
            connectedLoad = max(fc.DA.Lelec) + p.EV.Pch_max ...
                          + p.Batt.Pch_max + p.HeatPump.Pmax;
            cap = p.reliability.diversityFactor * connectedLoad;
            label = sprintf('design (%.2f x %.1f kW connected load)', ...
                p.reliability.diversityFactor, connectedLoad);

        case 'case4'
            if isempty(refPeak)
                error('feeder_capacity:refPeak', ...
                    'basis ''case4'' requires refPeak (the reference case''s day-ahead peak).');
            end
            cap = p.reliability.feederCapMargin * refPeak;
            label = sprintf('case4 self-derived (%.2f x %.2f kW own peak)', ...
                p.reliability.feederCapMargin, refPeak);

        otherwise
            error('feeder_capacity:basis', ...
                'Unknown basis "%s" (use ''design'' or ''case4'').', basis);
    end
end
