function ldf = lindistflow_sensitivity(sys)
%LINDISTFLOW_SENSITIVITY Linearized DistFlow voltage model for the ONE hub.
%
%   ldf = LINDISTFLOW_SENSITIVITY(sys)
%
%   Builds the LinDistFlow (linearized DistFlow) voltage model of the IEEE
%   33 feeder in a form that can be embedded directly in a MILP, so the
%   network can CONSTRAIN the dispatch rather than merely be checked
%   afterwards (network_verify.m does the latter).
%
%   THE MODEL. LinDistFlow drops the quadratic loss terms from the exact
%   DistFlow recursion, leaving the linear voltage-drop relation
%
%       V_j = V_slack - sum over branches k on the root->j path of
%                       (R_k * P_k + X_k * Q_k) / (1000 * Vbase_kV^2)   [pu]
%
%   where P_k, Q_k are the total downstream power flowing through branch
%   k. Both are linear in the bus injections, so V_j is linear in them
%   too -- which is exactly what a MILP needs.
%
%   THE SINGLE-HUB SIMPLIFICATION. This study has exactly ONE controllable
%   injection (the one hub at sys.hostBus); every other bus is a fixed
%   load. Under LinDistFlow that makes each bus voltage an EXACTLY AFFINE
%   function of the hub's net import I:
%
%       V_j(I) = C_j + a_j * I
%
%       C_j : LinDistFlow voltage at bus j with the host bus load zeroed
%       a_j : dV_j/dI = -(sum of R over branches common to the root->j
%             and root->hostBus paths) / (1000 * Vbase_kV^2)
%
%   a_j is negative everywhere (more import = lower voltage) and largest
%   in magnitude for buses sharing the most series resistance with the
%   hub. Verified to reproduce a full LinDistFlow solve to 1e-16 pu, so
%   the affine form is an exact restatement, not a further approximation.
%
%   This means the whole per-bus voltage constraint set can be added to
%   the MILP as a handful of rows in the EXISTING grid-exchange variables,
%   with no new variables at all.
%
%   ACCURACY, AND THE DIRECTION OF THE ERROR. Measured against the exact
%   backward-forward sweep on the base case: maximum error 0.0064 pu, and
%   LinDistFlow reads HIGH at 32 of the 33 buses. That direction is the
%   known and expected property of the approximation -- dropping the
%   quadratic loss term removes part of the voltage drop -- and it means
%   LinDistFlow is OPTIMISTIC. A schedule it certifies as legal can be
%   marginally illegal under the exact solver, so any co-optimized result
%   must be re-checked with distflow_bfs. Callers are expected to do that
%   and report the discrepancy rather than trusting the linear model.
%
%   Output struct ldf:
%     C        : 33x1 intercept, LinDistFlow pu voltage with host bus at 0 kW
%     a        : 33x1 sensitivity dV_j/dI in pu per kW (negative)
%     hostBus  : the ONE hub's bus
%     V_of     : @(I) C + a*I, all bus voltages at hub import I
%     Vlin_base: 33x1 LinDistFlow voltage with the host bus at its NOMINAL
%                load, i.e. the no-hub reference in the same model
%     maxErr_vs_exact : max |LinDistFlow - distflow_bfs| on the base case
%     optimisticBuses : how many buses LinDistFlow reads high on

    n  = sys.nBus;
    br = sys.branches;
    nb = numel(br);
    h  = sys.hostBus;
    den = 1000 * sys.Vbase_kV^2;

    % Radial topology: parent and incoming-branch index for every bus.
    par = zeros(n,1); bidx = zeros(n,1);
    for k = 1:nb
        par(br(k).To)  = br(k).From;
        bidx(br(k).To) = k;
    end

    % Root -> bus branch path for every bus.
    pathOf = cell(n,1);
    for j = 2:n
        q = j; acc = [];
        while q ~= 1
            acc = [bidx(q) acc]; %#ok<AGROW>
            q = par(q);
        end
        pathOf{j} = acc;
    end

    % Buses downstream of each branch (a bus is downstream of every branch
    % on its own root path).
    downOf = cell(nb,1);
    for k = 1:nb
        d = [];
        for j = 2:n
            if any(pathOf{j} == k); d = [d j]; end %#ok<AGROW>
        end
        downOf{k} = d;
    end

    R = arrayfun(@(k) br(k).R, 1:nb);
    X = arrayfun(@(k) br(k).X, 1:nb);

    % Intercept: LinDistFlow with the host bus contributing nothing.
    bp0 = sys.busP_base; bp0(h) = 0;
    C = ones(n,1);
    for j = 2:n
        s = 0;
        for k = pathOf{j}
            s = s + R(k)*sum(bp0(downOf{k})) + X(k)*sum(sys.busQ_base(downOf{k}));
        end
        C(j) = 1 - s/den;
    end

    % Sensitivities: only branches shared by the two root paths carry the
    % hub's power on the way to bus j. a_j is built from series RESISTANCE
    % (active power), b_j from series REACTANCE (reactive power) in exactly
    % the same way -- LinDistFlow treats the two symmetrically.
    %
    % These are NOT proportional to one another. b_j/a_j = (sum X)/(sum R)
    % over each bus's shared path, and on IEEE 33 that ratio varies from
    % about 0.51 to 0.86 depending on which branches are shared. That is
    % what makes the per-bus voltage rows linearly independent once Q is a
    % decision variable: with P alone every row is a scalar multiple of
    % every other and the whole set collapses to one import cap.
    a = zeros(n,1); b = zeros(n,1);
    for j = 2:n
        shared = intersect(pathOf{j}, pathOf{h});
        a(j) = -sum(R(shared)) / den;
        b(j) = -sum(X(shared)) / den;
    end

    ldf.C       = C;
    ldf.a       = a;
    ldf.b       = b;
    ldf.hostBus = h;
    ldf.V_of    = @(I) C + a*I;                 % Q = 0 (unity power factor)
    ldf.V_ofPQ  = @(I,Q) C + a*I - b*Q;         % Q > 0 = injecting (reduces net Q load)
    ldf.Vlin_base = C + a*sys.busP_base(h);
    % Ratio spread: the diagnostic for whether the per-bus rows are
    % linearly independent. Constant ratio => colinear => collapses to a
    % single scalar cap on import.
    ldf.bOverA        = b(2:end) ./ a(2:end);
    ldf.bOverA_range  = [min(ldf.bOverA) max(ldf.bOverA)];
    ldf.rowsColinear  = (ldf.bOverA_range(2) - ldf.bOverA_range(1)) < 1e-9;

    % Accuracy against the exact solver, on the base case.
    Vex = abs(distflow_bfs(sys.branches, sys.busP_base, sys.busQ_base, sys.Vbase_kV)) / sys.Vbase_kV;
    ldf.maxErr_vs_exact  = max(abs(ldf.Vlin_base - Vex));
    ldf.optimisticBuses  = sum(ldf.Vlin_base > Vex);
    ldf.Vexact_base      = Vex;
end
