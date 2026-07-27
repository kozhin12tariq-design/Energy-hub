function [f, A] = energy_hub_evaluate_hub(edges, nNodes, nInputs, P)
%ENERGY_HUB_EVALUATE_HUB Exact edge-flow evaluation for a specific input
%vector, supporting both constant-efficiency and PWL (variable-efficiency)
%branches.
%
%   [f, A] = ENERGY_HUB_EVALUATE_HUB(edges, nNodes, nInputs, P)
%
%   energy_hub_coupling_matrix.m builds ONE matrix C valid for the whole
%   input space, which requires every dependent edge to be linear
%   (constant Eta). PWL edges (eh_edge.m Eta = struct from
%   pwl_utils.m 'fit') make that impossible in general, so this function
%   instead evaluates the graph exactly at one concrete P by resolving
%   edges in dependency order: 'input' edges are known immediately from
%   P; a 'dependent' edge is resolved as soon as every edge feeding its
%   tail node (read off the incidence matrix, exactly as in
%   energy_hub_coupling_matrix.m) is itself resolved, applying either
%   f = Eta*inflow (constant) or f = pwl_utils('eval',Eta.x,Eta.y,inflow)
%   (PWL). This works for any hub whose edges have no circular value
%   dependency (true of every physical hub graph assembled by
%   energy_hub_assemble.m: sources -> converters -> buses -> storage/
%   loads never feeds back into its own inflow).
%
%   Inputs
%     edges, nNodes, nInputs : as in energy_hub_coupling_matrix.m
%     P                      : nInputs x 1 concrete input vector
%
%   Outputs
%     f : nEdges x 1 vector of resolved edge flows (index into it with
%         outputEdgeIdx from energy_hub_assemble.m to get L)
%     A : the incidence matrix (returned for convenience/reuse)

    nEdges = numel(edges);
    A = energy_hub_incidence_matrix(edges, nNodes);

    f = nan(nEdges, 1);
    resolved = false(nEdges, 1);

    for k = 1:nEdges
        if strcmp(edges(k).Type, 'input')
            f(k) = P(edges(k).InputIndex);
            resolved(k) = true;
        end
    end

    progress = true;
    while progress
        progress = false;
        for k = 1:nEdges
            if resolved(k)
                continue;
            end
            if ~strcmp(edges(k).Type, 'dependent')
                error('energy_hub_evaluate_hub:type', ...
                    'Unknown edge type "%s" on edge %d.', edges(k).Type, k);
            end
            inflowEdges = find(A(edges(k).From, :) == -1);
            if ~all(resolved(inflowEdges))
                continue;
            end
            inflowVal = sum(f(inflowEdges));
            if isnumeric(edges(k).Eta)
                f(k) = edges(k).Eta * inflowVal;
            elseif isstruct(edges(k).Eta) && strcmp(edges(k).Eta.type, 'pwl')
                f(k) = pwl_utils('eval', edges(k).Eta.x, edges(k).Eta.y, inflowVal);
            else
                error('energy_hub_evaluate_hub:eta', ...
                    'Edge %d has an unsupported Eta value.', k);
            end
            resolved(k) = true;
            progress = true;
        end
    end

    if ~all(resolved)
        error('energy_hub_evaluate_hub:cycle', ...
            ['Could not resolve edges %s -- the graph has a circular value ' ...
             'dependency (an edge''s tail node inflow depends, directly or ' ...
             'indirectly, on that same edge), which this sequential evaluator ' ...
             'does not support.'], mat2str(find(~resolved)'));
    end
end
