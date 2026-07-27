function A = energy_hub_incidence_matrix(edges, nNodes)
%ENERGY_HUB_INCIDENCE_MATRIX Node-edge incidence matrix of the hub graph.
%
%   A = ENERGY_HUB_INCIDENCE_MATRIX(edges, nNodes)
%
%   Builds the standard directed-graph incidence matrix A (nNodes x nEdges):
%       A(i,k) = +1   if edge k leaves node i   (i is the tail)
%       A(i,k) = -1   if edge k enters node i   (i is the head)
%       A(i,k) =  0   otherwise
%
%   Every column of A sums to zero (each edge has exactly one tail and one
%   head), so A encodes Kirchhoff's-current-law-style power conservation
%   for the hub graph: for any node i with no external injection,
%   A(i,:) * f = 0  <=>  inflow(i) == outflow(i).

    nEdges = numel(edges);
    A = zeros(nNodes, nEdges);
    for k = 1:nEdges
        A(edges(k).From, k) = A(edges(k).From, k) + 1;
        A(edges(k).To,   k) = A(edges(k).To,   k) - 1;
    end
end
