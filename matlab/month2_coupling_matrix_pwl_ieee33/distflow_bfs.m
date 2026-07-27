function [V_kV, Ibranch_A, Ploss_kW, Qloss_kVAr, busLossKW, iters, converged] = ...
    distflow_bfs(branches, busP_kW, busQ_kVAr, Vbase_kV, tol, maxIter)
%DISTFLOW_BFS Backward-forward sweep power flow for a radial distribution feeder.
%
%   [V_kV, Ibranch_A, Ploss_kW, Qloss_kVAr, busLossKW, iters, converged] = ...
%       DISTFLOW_BFS(branches, busP_kW, busQ_kVAr, Vbase_kV, tol, maxIter)
%
%   Standard ladder-iterative backward/forward sweep for a RADIAL (tree)
%   network, single-phase equivalent, bus 1 = slack/substation. Works
%   entirely in SI units internally (V, A, W, VAr, Ohm) to avoid unit
%   errors, converting from/to the kV/kW/kVAr engineering units used
%   everywhere else in this repo at the boundary.
%
%   Algorithm, each iteration:
%     1) Backward sweep: with the CURRENT voltage estimate, compute each
%        bus's injected current I(i) = conj(S(i)/V(i)), then accumulate
%        branch currents from the leaves toward the root (a branch's
%        current = its own bus's injection + the sum of all of its
%        children's branch currents).
%     2) Forward sweep: starting from the fixed slack voltage, update
%        each bus's voltage from its parent, V(child) = V(parent) -
%        Ibranch*Z, moving root -> leaves.
%     3) Stop when the largest voltage-magnitude change between
%        iterations falls below `tol`.
%
%   Sign convention: busP_kW/busQ_kVAr are LOADS (positive = consumption
%   from the feeder); a negative value is net generation/export at that
%   bus, handled with no special-casing (the current direction simply
%   reverses).
%
%   Inputs
%     branches  : struct array (From, To, R [Ohm], X [Ohm]), radial tree,
%                 From = upstream/parent, To = downstream/child
%     busP_kW, busQ_kVAr : nBus x 1 nominal bus loads (bus 1 = slack, 0)
%     Vbase_kV  : slack bus voltage magnitude (nominal feeder voltage)
%     tol       : convergence tolerance on |V| in kV (default 1e-6)
%     maxIter   : maximum sweep iterations (default 100)
%
%   Outputs
%     V_kV       : nBus x 1 complex bus voltages (kV)
%     Ibranch_A  : nBranch x 1 complex branch currents (A), indexed same
%                  as `branches`
%     Ploss_kW, Qloss_kVAr : total feeder losses
%     busLossKW  : nBranch x 1 real-power loss on each branch (kW)
%     iters      : sweep iterations used
%     converged  : logical

    if nargin < 5 || isempty(tol); tol = 1e-6; end
    if nargin < 6 || isempty(maxIter); maxIter = 100; end

    nBus = numel(busP_kW);
    nBranch = numel(branches);

    parentOf = zeros(nBus, 1);
    branchOfBus = zeros(nBus, 1);   % branch index connecting bus i to its parent
    childBranches = cell(nBus, 1);
    for k = 1:nBranch
        parentOf(branches(k).To) = branches(k).From;
        branchOfBus(branches(k).To) = k;
        childBranches{branches(k).From}(end+1) = k;
    end

    % Topological order via BFS from the root (bus 1); valid for any tree.
    order = zeros(nBus, 1);
    order(1) = 1;
    nOrdered = 1;
    queue = 1;
    while ~isempty(queue)
        b = queue(1); queue(1) = [];
        for k = childBranches{b}
            child = branches(k).To;
            nOrdered = nOrdered + 1;
            order(nOrdered) = child;
            queue(end+1) = child; %#ok<AGROW>
        end
    end
    assert(nOrdered == nBus, 'distflow_bfs:notree', ...
        'branches do not form a connected tree spanning all %d buses (reached %d).', nBus, nOrdered);
    forwardOrder = order(2:end);        % root -> leaves, excluding slack
    backwardOrder = order(end:-1:2);    % leaves -> root, excluding slack

    % SI units internally.
    S_load_VA = (busP_kW + 1i*busQ_kVAr) * 1000;  % W + j*VAr
    Vbase_V = Vbase_kV * 1000;
    R_ohm = [branches.R];
    X_ohm = [branches.X];
    Z_ohm = R_ohm + 1i*X_ohm;

    V = Vbase_V * ones(nBus, 1);   % flat start, complex
    converged = false;
    for iters = 1:maxIter
        Vprev = V;

        Ibus = zeros(nBus, 1);
        Ibus(2:end) = conj(S_load_VA(2:end) ./ V(2:end));

        Ibranch = zeros(nBranch, 1);
        for bIdx = backwardOrder'
            k = branchOfBus(bIdx);
            Ibranch(k) = Ibus(bIdx) + sum(Ibranch(childBranches{bIdx}));
        end

        for bIdx = forwardOrder'
            k = branchOfBus(bIdx);
            V(bIdx) = V(parentOf(bIdx)) - Ibranch(k) * Z_ohm(k);
        end

        if max(abs(V - Vprev)) < tol * 1000  % tol given in kV
            converged = true;
            break;
        end
    end

    V_kV = V / 1000;
    Ibranch_A = Ibranch;
    busLossKW = (abs(Ibranch).^2 .* R_ohm') / 1000;
    busLossQ_kVAr = (abs(Ibranch).^2 .* X_ohm') / 1000;
    Ploss_kW = sum(busLossKW);
    Qloss_kVAr = sum(busLossQ_kVAr);
end
