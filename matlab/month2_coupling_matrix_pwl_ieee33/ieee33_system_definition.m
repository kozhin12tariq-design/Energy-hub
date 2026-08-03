function sys = ieee33_system_definition(hostBus, hubScale)
%IEEE33_SYSTEM_DEFINITION The canonical study system: ONE hub inside IEEE 33.
%
%   sys = IEEE33_SYSTEM_DEFINITION(hostBus, hubScale)
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
%   REACTIVE POWER: this struct describes the NETWORK, not the dispatch,
%   and it carries the host bus's nominal Q. The hub itself is no longer
%   unity-power-factor -- the dispatch layers carry a reactive decision
%   variable bounded by an IEEE 1547 Category B capability and an
%   apparent-power polygon (see multiscale_default_params.m's p.Inverter
%   block) -- so callers pass the dispatched Q into network_verify.m as its
%   fourth argument, which subtracts it from busQ at the host bus. A caller
%   that omits it is verifying a unity-power-factor hub and gets the
%   pessimistic voltage answer.
%
%   SCALE, AND WHY THE HUB WAS EVENTUALLY SCALED UP. An earlier version of
%   this file hosted a ~104 kW hub at bus 18 and argued explicitly against
%   scaling it: at 2.79% of the 3715 kW feeder the hub was feeder-wide
%   marginal, but it was 115% of bus 18's own 90 kW load, so its LOCAL
%   effect (a ~0.009 pu swing at its host bus) was plainly measurable, and
%   scaling would have moved the Case 1-4 regression anchors.
%
%   That reasoning was sound for the local questions and wrong for the
%   feeder-wide ones. Month 4c's "PWL segment count does not change grid
%   outcomes" and Month 4b's "reserve margin does not move voltage" were
%   both measured on that 2.79% hub, and at that size neither sweep COULD
%   have come out differently -- they were reporting the hub's size, not
%   the mechanism each was nominally studying. Preserving regression
%   anchors is not a good enough reason to leave two headline findings
%   resting on an untestable configuration.
%
%   So the hub now sits at BUS 25 and its ratings are scaled by
%   hub_sizing().scale = L(25)/L(18) = 420/90 = 4.6667. That factor is
%   derived from the two buses' nominal loads, not chosen: it keeps the
%   hub's size relative to its HOST exactly what it was (peak import
%   stays 115.3% of host-bus load) and changes only its size relative to
%   the FEEDER (2.79% -> 13.0%). hub_sizing.m gives the full derivation,
%   including why the do-no-harm voltage floor caps hub import at the host
%   bus's nominal load regardless of that bus's voltage sensitivity, which
%   is what makes bus 18 structurally incapable of hosting a
%   feeder-relevant hub.
%
%   WHAT THAT COSTS, stated because it is a real loss. Bus 18 is the
%   electrically WEAKEST bus in the base case (0.9131 pu, the benchmark's
%   own minimum) and was the most demanding place to site an active node.
%   Bus 25 sits at 0.9694 pu, comfortably above the 0.95 limit, so the hub
%   no longer stresses the feeder's worst point. The feeder minimum is
%   still bus 18 and the hub still cannot repair it. Passing hostBus = 18
%   restores the old siting at any scale, and Month 2b continues to
%   evaluate bus 18, 25 and 33 side by side.
%
%   Default host bus and default scale both come from hub_sizing().
%
%   Input
%     hostBus  : bus index 2..33 to site the single hub at
%                (default hub_sizing().hostBus = 25)
%     hubScale : hub size multiplier, only used to report penetration
%                (default hub_sizing().scale = 4.6667). Pass 1.0 together
%                with hostBus = 18 to reproduce the earlier study system.
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

    thisFile = mfilename('fullpath');
    addpath(fullfile(fileparts(thisFile), '..', 'month3_multiscale_optimization'));

    hs = hub_sizing();
    if nargin < 1 || isempty(hostBus);  hostBus  = hs.hostBus; end
    if nargin < 2 || isempty(hubScale); hubScale = hs.scale;   end

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
    sys.hubScale   = hubScale;
    sys.p          = multiscale_default_params(hubScale);

    % Reference peak import for the penetration summary. Fixed in
    % hub_sizing.m rather than re-simulated so this function stays cheap and
    % side-effect free; network_verify.m reports the ACTUAL per-timestep
    % injections.
    sys.hubPeakImport_kW = hubScale * hs.refPeakImport_kW;

    sys.feederLoad_kW  = sum(busP_base);
    sys.hostBusLoad_kW = busP_base(hostBus);
    sys.penetrationFeeder_pct  = 100 * sys.hubPeakImport_kW / sys.feederLoad_kW;
    sys.penetrationHostBus_pct = 100 * sys.hubPeakImport_kW / sys.hostBusLoad_kW;
end
