function nv = network_verify(sys, netInjection_kW, opts, netQ_kvar)
%NETWORK_VERIFY Exact IEEE 33 power-flow check of a completed dispatch.
%
%   nv = NETWORK_VERIFY(sys, netInjection_kW, opts)
%
%   Takes a dispatch that has ALREADY been solved and asks what the
%   network actually experienced while it ran. For each timestep the
%   single hub's net grid draw replaces its host bus's nominal load and
%   the exact backward-forward-sweep power flow (distflow_bfs.m) is
%   solved, giving true bus voltages and feeder losses rather than the
%   scalar feeder-capacity proxy the dispatch itself uses.
%
%   WHY POST-HOC AND NOT INSIDE THE MILP. distflow_bfs is an iterative
%   nonlinear solver, so it cannot appear inside a MILP -- glpk needs
%   linear constraints. This function therefore VERIFIES a dispatch; it
%   does not CONSTRAIN one. The dispatch was free to choose a schedule
%   the network dislikes, and this is where that shows up. Embedding a
%   LINEARIZED network model so the grid can actually constrain the
%   schedule is a separate, harder step (LinDistFlow co-optimization).
%
%   ONE HUB. The substitution touches exactly one bus, sys.hostBus. There
%   is never more than one hub in the study.
%
%   REACTIVE POWER. The hub's grid-facing inverter now dispatches reactive
%   power (dayahead_dispatch.m), within its apparent-power circle and the
%   IEEE 1547-2018 Category B limit of +/-44% of nameplate S. Pass the
%   hub's Q series as the 4th argument and the host bus's reactive load is
%   adjusted by it at each timestep: a Q INJECTION (positive) reduces the
%   net reactive draw at that bus and raises local voltage; absorption
%   lowers it. This is the mechanism by which the hub can support voltage
%   at all, and it was absent from every earlier result in this project.
%
%   Omit the 4th argument and the hub is treated at unity power factor
%   exactly as before, so older comparisons remain reproducible. Which
%   mode produced a given number matters: unity-power-factor voltages are
%   the no-support case, not a bound.
%
%   Inputs
%     sys             : ieee33_system_definition() struct (network + host bus)
%     netInjection_kW : Nx1 hub net grid draw per timestep (positive =
%                       importing from the feeder, negative = exporting).
%                       Typically res.Pg_imp5 - res.Pg_exp5 (288 5-min steps).
%     opts (optional)
%       .vLimit    : undervoltage limit in pu (default 0.95)
%       .dtHours   : hours per timestep (default 1/12, i.e. 5 minutes)
%       .stride    : evaluate every k-th timestep (default 1). The power
%                    flow is the expensive part; stride>1 trades
%                    resolution for speed and is reported when used.
%
%   Output struct nv:
%     minV, minV_bus, minV_step : worst voltage over the whole day, where and when
%     maxV                      : highest voltage seen (overvoltage check)
%     hoursBelowLimit           : hours with any bus under opts.vLimit
%     nStepsBelowLimit          : number of evaluated steps with a violation
%     worstBusCount             : 33x1 count of how often each bus was the weakest
%     losses_kW                 : evaluated-step feeder losses (kW)
%     peakLoss_kW, meanLoss_kW  : over the day
%     lossEnergy_kWh            : energy lost to feeder losses over the horizon
%     hostV                     : host-bus voltage per evaluated step (pu)
%     hostV_min, hostV_max, hostV_mean
%     Vmin_series               : per-step minimum voltage (pu)
%     steps                     : indices actually evaluated
%     converged_all             : true if every power flow converged

    if nargin < 3; opts = struct(); end
    if ~isfield(opts, 'vLimit');  opts.vLimit  = 0.95; end
    if ~isfield(opts, 'dtHours'); opts.dtHours = 1/12; end
    if ~isfield(opts, 'stride');  opts.stride  = 1; end

    netInjection_kW = netInjection_kW(:);
    if nargin < 4 || isempty(netQ_kvar)
        netQ_kvar = zeros(size(netInjection_kW));   % unity power factor
        nv.reactiveDispatched = false;
    else
        netQ_kvar = netQ_kvar(:);
        if numel(netQ_kvar) ~= numel(netInjection_kW)
            error('network_verify:qLength', ...
                'netQ_kvar (%d) must match netInjection_kW (%d).', ...
                numel(netQ_kvar), numel(netInjection_kW));
        end
        nv.reactiveDispatched = true;
    end
    steps = 1:opts.stride:numel(netInjection_kW);
    nS = numel(steps);

    Vmin_series = zeros(nS,1);
    VminBus     = zeros(nS,1);
    losses_kW   = zeros(nS,1);
    hostV       = zeros(nS,1);
    Vmax_series = zeros(nS,1);
    convOK      = true;

    for k = 1:nS
        busP = sys.busP_base;
        busP(sys.hostBus) = netInjection_kW(steps(k));   % ONE bus, the one hub
        busQ = sys.busQ_base;
        % Q injection reduces the host bus's net reactive load (loads are
        % positive in this convention), which is what raises local voltage.
        busQ(sys.hostBus) = sys.busQ_base(sys.hostBus) - netQ_kvar(steps(k));
        [V, ~, Ploss, ~, ~, ~, conv] = ...
            distflow_bfs(sys.branches, busP, busQ, sys.Vbase_kV);
        Vpu = abs(V) / sys.Vbase_kV;
        [mv, mb] = min(Vpu);
        Vmin_series(k) = mv;
        VminBus(k)     = mb;
        Vmax_series(k) = max(Vpu);
        losses_kW(k)   = Ploss;
        hostV(k)       = Vpu(sys.hostBus);
        convOK = convOK && conv;
    end

    % BASE-CASE REFERENCE. Essential context, computed here so no caller
    % can quote an absolute voltage or violation count without it: the
    % IEEE 33 benchmark ALREADY sits below 0.95 pu across most of its far
    % end with no hub present (21 of 33 buses, 24 h/day). An absolute
    % "hours below limit" figure therefore measures the benchmark feeder,
    % not the hub. Only the DELTAS against this reference say anything
    % about what the hub did.
    [Vb, ~, PlossBase] = distflow_bfs(sys.branches, sys.busP_base, sys.busQ_base, sys.Vbase_kV);
    VbPu = abs(Vb) / sys.Vbase_kV;
    [nv.base_minV, nv.base_minV_bus] = min(VbPu);
    nv.base_loss_kW        = PlossBase;
    nv.base_hostV          = VbPu(sys.hostBus);
    nv.base_busesBelow     = sum(VbPu < opts.vLimit);
    nv.base_lossEnergy_kWh = PlossBase * numel(netInjection_kW) * opts.dtHours;

    [nv.minV, iWorst] = min(Vmin_series);
    nv.minV_bus  = VminBus(iWorst);
    nv.minV_step = steps(iWorst);
    nv.maxV      = max(Vmax_series);

    below = Vmin_series < opts.vLimit;
    nv.nStepsBelowLimit = sum(below);
    nv.hoursBelowLimit  = sum(below) * opts.dtHours * opts.stride;

    nv.worstBusCount = zeros(sys.nBus, 1);
    for k = 1:nS
        nv.worstBusCount(VminBus(k)) = nv.worstBusCount(VminBus(k)) + 1;
    end

    nv.losses_kW     = losses_kW;
    nv.peakLoss_kW   = max(losses_kW);
    nv.meanLoss_kW   = mean(losses_kW);
    nv.lossEnergy_kWh = sum(losses_kW) * opts.dtHours * opts.stride;

    nv.hostV      = hostV;
    nv.hostV_min  = min(hostV);
    nv.hostV_max  = max(hostV);
    nv.hostV_mean = mean(hostV);

    % Deltas against the no-hub base case -- the figures that actually
    % attribute anything to the hub.
    nv.dMinV_vs_base       = nv.minV - nv.base_minV;
    nv.dHostV_mean_vs_base = nv.hostV_mean - nv.base_hostV;
    nv.dHostV_min_vs_base  = nv.hostV_min  - nv.base_hostV;
    nv.dLossEnergy_kWh     = nv.lossEnergy_kWh - nv.base_lossEnergy_kWh;
    nv.dLossEnergy_pct     = 100 * nv.dLossEnergy_kWh / nv.base_lossEnergy_kWh;

    nv.Vmin_series   = Vmin_series;
    nv.steps         = steps;
    nv.vLimit        = opts.vLimit;
    nv.stride        = opts.stride;
    nv.converged_all = convOK;
end
