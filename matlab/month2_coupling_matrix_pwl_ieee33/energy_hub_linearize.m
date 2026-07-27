function [C_local, d_local, f0, A] = energy_hub_linearize(edges, nNodes, nInputs, outputEdgeIdx, P0)
%ENERGY_HUB_LINEARIZE Local affine coupling matrix around one operating point.
%
%   [C_local, d_local, f0, A] = ENERGY_HUB_LINEARIZE(edges, nNodes, nInputs, outputEdgeIdx, P0)
%
%   Generalizes energy_hub_coupling_matrix.m to hubs containing PWL
%   (variable-efficiency) edges: since a piecewise-linear hub has no
%   single global C, this instead builds the LOCAL affine approximation
%       L =~ C_local * P + d_local
%   valid near P0 (while every PWL edge stays in the same breakpoint
%   segment it occupies at P0). Constant-Eta edges contribute their
%   usual linear term with d = 0; each PWL edge is replaced by the local
%   (slope, intercept) of its active segment at P0, found with
%   pwl_utils.m 'local_affine'.
%
%   At P = P0 exactly, C_local*P0 + d_local reproduces
%   energy_hub_evaluate_hub.m's f0 exactly (both describe the same
%   segment selection). Away from P0, the approximation degrades once
%   the true operating point crosses into a different PWL segment --
%   re-linearize (call this function again at the new P0) when that
%   happens, exactly as a constant-efficiency model would need
%   re-deriving for a different nominal operating point, but now with
%   segment-sized error instead of whole-curve error.
%
%   Inputs
%     edges, nNodes, nInputs, outputEdgeIdx : as in energy_hub_coupling_matrix.m
%     P0 : nInputs x 1 operating point to linearize around
%
%   Outputs
%     C_local, d_local : local affine map, L =~ C_local*P + d_local
%     f0 : exact edge flows at P0 (from energy_hub_evaluate_hub.m)
%     A  : incidence matrix

    [f0, A] = energy_hub_evaluate_hub(edges, nNodes, nInputs, P0);

    nEdges = numel(edges);
    M = zeros(nEdges, nEdges);
    N = zeros(nEdges, nInputs);
    b = zeros(nEdges, 1);

    for k = 1:nEdges
        M(k, k) = 1;
        switch edges(k).Type
            case 'input'
                N(k, edges(k).InputIndex) = 1;
            case 'dependent'
                node = edges(k).From;
                inflowEdges = find(A(node, :) == -1);
                if isnumeric(edges(k).Eta)
                    M(k, inflowEdges) = M(k, inflowEdges) - edges(k).Eta;
                else
                    x0 = sum(f0(inflowEdges));
                    [slope, intercept] = pwl_utils('local_affine', edges(k).Eta.x, edges(k).Eta.y, x0);
                    M(k, inflowEdges) = M(k, inflowEdges) - slope;
                    b(k) = intercept;
                end
            otherwise
                error('energy_hub_linearize:type', ...
                    'Unknown edge type "%s" on edge %d.', edges(k).Type, k);
        end
    end

    S = zeros(numel(outputEdgeIdx), nEdges);
    for i = 1:numel(outputEdgeIdx)
        S(i, outputEdgeIdx(i)) = 1;
    end

    C_local = S * (M \ N);
    d_local = S * (M \ b);
end
