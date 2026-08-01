function sys = ieee33_system_definition(hostBus)
%IEEE33_SYSTEM_DEFINITION The canonical study system: ONE hub inside IEEE 33.
%
%   sys = IEEE33_SYSTEM_DEFINITION(hostBus)
%
%   Single source of truth for what this thesis studies, shared by every
%   month from here on: the IEEE 33-bus benchmark feeder, plus EXACTLY
%   ONE energy hub sited at exactly one bus.
%
%   ONE HUB. NOT SEVERAL. The thesis models a single energy hub
%   containing the full technology set -- PV, fuel cell, battery, EV
%   fleet, heat pump, building/pipe thermal storage -- on shared
%   electrical and heat buses with grid import/export. There is never
%   more than one hub anywhere in the study. Where several buses are
%   examined (main_month2b_ieee33_grid_integration.m), they are
%   ALTERNATIVE SITINGS of that one hub, evaluated one at a time against
%   the clean base case, never coexisting.
%
%   COUPLING CONVENTION: the hub REPLACES its host bus's nominal load.
%   busP(hostBus) becomes the hub's net grid draw (positive = importing
%   from the feeder, negative = exporting), so that bus stops being a
%   passive load and becomes an active, controllable node. This is the
%   same substitution Month 2b has always used. Note the consequence,
%   stated plainly: the hub's own electrical demand (20-45 kW) is not the
%   same as the nominal load it displaces, so total feeder load changes
%   when the hub is sited. That is inherent to replacing a passive load
%   with a different, active installation, not an error.
%
%   REACTIVE POWER: the hub is modelled at unity power factor and the
%   host bus keeps its nominal Q. Voltage results are therefore
%   OPTIMISTIC relative to a hub that also exchanges reactive power --
%   see network_verify.m's header.
%
%   SCALE, AND WHY THE HUB IS NOT SCALED UP. Measured on this system:
%   the hub's peak net import is ~104 kW against a 3715 kW feeder, i.e.
%   only ~2.8% feeder-wide. Judged feeder-wide alone, a hub this size
%   could not move the network and a "no violations" verdict would be
%   trivial. Two responses were available: scale the hub's ratings up, or
%   site it where it is LOCALLY significant and report local effects.
%
%   This file takes the second. The hub's peak import is 115% of bus 18's
%   nominal load and 173% of bus 33's -- at its host bus it is not a
%   marginal addition, it IS the load. Measured effect at bus 18: the
%   hub swings that bus between 0.9120 pu (peak import) and 0.9213 pu
%   (peak export) against a 0.9131 pu base, a ~0.009 pu local swing that
%   is plainly visible. Scaling the ratings was deliberately NOT done
%   because it would change the dispatch and move the Case 1-4 cost/CO2/
%   peak results that serve as this project's regression anchors; the
%   local effect is already measurable without paying that price. The
%   honest limitation stands and is reported by every caller: this hub
%   is locally significant and feeder-wide marginal.
%
%   Default host bus is 18 -- the electrically weakest bus in the base
%   case (0.9131 pu, the benchmark's own minimum), hence the most
%   sensitive place to site an active node and the most demanding test.
%
%   Input
%     hostBus : bus index 2..33 to site the single hub at (default 18)
%
%   Output struct sys:
%     branches, busP_base, busQ_base, Vbase_kV : IEEE 33 network, unchanged
%     hostBus              : the ONE bus hosting the ONE hub
%     p                    : hub parameter set (multiscale_default_params)
%     nBus                 : 33
%     feederLoad_kW        : sum(busP_base) = 3715
%     hostBusLoad_kW       : busP_base(hostBus)
%     penetrationFeeder_pct, penetrationHostBus_pct : hub peak import as a
%         percentage of each, so the scale caveat travels with the data
%     hubPeakImport_kW     : reference peak used for those percentages

    if nargin < 1 || isempty(hostBus); hostBus = 18; end

    thisFile = mfilename('fullpath');
    addpath(fullfile(fileparts(thisFile), '..', 'month3_multiscale_optimization'));

    [branches, busP_base, busQ_base, Vbase_kV] = ieee33_data();
    nBus = numel(busP_base);

    if ~isscalar(hostBus) || hostBus < 2 || hostBus > nBus || hostBus ~= fix(hostBus)
        error('ieee33_system_definition:hostBus', ...
            'hostBus must be a single bus index in 2..%d (bus 1 is the slack/substation).', nBus);
    end

    sys.branches   = branches;
    sys.busP_base  = busP_base;
    sys.busQ_base  = busQ_base;
    sys.Vbase_kV   = Vbase_kV;
    sys.nBus       = nBus;
    sys.hostBus    = hostBus;
    sys.p          = multiscale_default_params();

    % Reference peak import for the penetration summary. Fixed here rather
    % than re-simulated so this function stays cheap and side-effect free;
    % network_verify.m reports the ACTUAL per-timestep injections.
    sys.hubPeakImport_kW = 103.76;

    sys.feederLoad_kW  = sum(busP_base);
    sys.hostBusLoad_kW = busP_base(hostBus);
    sys.penetrationFeeder_pct  = 100 * sys.hubPeakImport_kW / sys.feederLoad_kW;
    sys.penetrationHostBus_pct = 100 * sys.hubPeakImport_kW / sys.hostBusLoad_kW;
end
