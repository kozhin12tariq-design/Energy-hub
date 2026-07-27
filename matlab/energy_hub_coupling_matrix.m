function [C, A, M, N] = energy_hub_coupling_matrix(edges, nNodes, nInputs, outputEdgeIdx)
%ENERGY_HUB_COUPLING_MATRIX Coupling matrix derived from the incidence matrix.
%
%   [C, A, M, N] = ENERGY_HUB_COUPLING_MATRIX(edges, nNodes, nInputs, outputEdgeIdx)
%
%   This is the incidence-matrix reformulation of the classical hub
%   coupling-matrix method (Geidl & Andersson): instead of writing the
%   L = C*P relation by hand for one fixed topology, it is derived
%   generically from the node-edge graph description of the hub.
%
%   Every edge k contributes one linear equation in the unknown edge-flow
%   vector f (nEdges x 1):
%     - 'input' edges are exogenous:      f(k) = P(InputIndex(k))
%     - 'dependent' edges obey a branch law tying them to the total flow
%       entering their tail node (a converter efficiency or a dispatch
%       / splitting factor at a junction node):
%           f(k) = Eta(k) * inflow(From(k)),   inflow(i) = sum_{j: A(i,j)=-1} f(j)
%       The set of inflow edges for node i is read directly off the
%       incidence matrix A as the edges where A(i,:) == -1 (edges whose
%       head is node i) -- this is the "reformulation using the
%       incidence-matrix approach" requested: the branch laws are
%       assembled purely from A, not from hand-written per-node balance
%       equations.
%
%   Stacking all nEdges equations gives the square linear system
%       M * f = N * P
%   and the hub outputs are a fixed linear selection of f,
%       L = S * f = S * (M \ N) * P = C * P
%   so   C = S * (M \ N).
%
%   Inputs
%     edges         : edge struct array, see energy_hub_define_network.m
%     nNodes        : number of nodes
%     nInputs       : number of independent hub inputs (columns of C)
%     outputEdgeIdx : edge indices selected as hub outputs (rows of C)
%
%   Outputs
%     C : coupling matrix, L = C*P   (numel(outputEdgeIdx) x nInputs)
%     A : node-edge incidence matrix (nNodes x nEdges)
%     M, N : the assembled linear system M*f = N*P

    nEdges = numel(edges);
    A = energy_hub_incidence_matrix(edges, nNodes);

    M = zeros(nEdges, nEdges);
    N = zeros(nEdges, nInputs);

    for k = 1:nEdges
        M(k, k) = 1;
        switch edges(k).Type
            case 'input'
                N(k, edges(k).InputIndex) = 1;
            case 'dependent'
                node = edges(k).From;
                inflowEdges = find(A(node, :) == -1);
                M(k, inflowEdges) = M(k, inflowEdges) - edges(k).Eta;
            otherwise
                error('energy_hub_coupling_matrix:type', ...
                    'Unknown edge type "%s" on edge %d.', edges(k).Type, k);
        end
    end

    S = zeros(numel(outputEdgeIdx), nEdges);
    for i = 1:numel(outputEdgeIdx)
        S(i, outputEdgeIdx(i)) = 1;
    end

    C = S * (M \ N);
end
