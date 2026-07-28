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
%
%   SIGN CONVENTION NOTE: this is the standard GRAPH-THEORY incidence
%   convention (+1 at the tail node, -1 at the head node of each directed
%   edge). The energy-hub literature's own "coupling matrix" convention
%   (Geidl & Andersson and followers; see energy_hub_coupling_matrix.m)
%   instead signs by PORT role -- +1 for an input port, -1 for an output
%   port of the hub as a whole -- which is a different bookkeeping axis
%   (port role vs. edge direction at a node) and does not, in general,
%   agree edge-by-edge with the tail/head signs here. Both conventions
%   are internally consistent and correct for what each is used for in
%   this codebase (this file for graph-theoretic node balance equations;
%   energy_hub_coupling_matrix.m for the hub's input/output port algebra
%   P_out = C*P_in) -- this is a documentation note about the difference,
%   not a bug in either file, and no behavior changes as a result of it.

    nEdges = numel(edges);
    A = zeros(nNodes, nEdges);
    for k = 1:nEdges
        A(edges(k).From, k) = A(edges(k).From, k) + 1;
        A(edges(k).To,   k) = A(edges(k).To,   k) - 1;
    end
end
