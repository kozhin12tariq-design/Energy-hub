function energy_hub_print_equations(nodeNames, edges, inputLabels, outputLabels, outputEdgeIdx)
%ENERGY_HUB_PRINT_EQUATIONS Auto-generate and print the hub's energy-flow
%equations from its edge list.
%
%   ENERGY_HUB_PRINT_EQUATIONS(nodeNames, edges, inputLabels, outputLabels, outputEdgeIdx)
%
%   This is the literal "automatic generation of energy flow equations
%   for arbitrary configurations" step: given any assembled hub (any
%   number/mix of components, buses, MIMO or PWL branches), it reads the
%   incidence matrix and prints, for every edge, the exact equation
%   energy_hub_evaluate_hub.m / energy_hub_coupling_matrix.m solve --
%   nothing here is specific to one hub topology.

    nEdges = numel(edges);
    A = energy_hub_incidence_matrix(edges, numel(nodeNames));

    fprintf('Energy-flow equations (%d edges, auto-generated from the graph):\n', nEdges);
    for k = 1:nEdges
        arrowStr = sprintf('{ %s -> %s }', nodeNames{edges(k).From}, nodeNames{edges(k).To});
        switch edges(k).Type
            case 'input'
                fprintf('  f%-2d = P.%-16s              %s\n', ...
                    k, inputLabels{edges(k).InputIndex}, arrowStr);
            case 'dependent'
                inflowEdges = find(A(edges(k).From, :) == -1);
                if isempty(inflowEdges)
                    rhsInflow = '0';
                else
                    terms = arrayfun(@(j) sprintf('f%d', j), inflowEdges, 'UniformOutput', false);
                    rhsInflow = strjoin(terms, ' + ');
                end
                if isnumeric(edges(k).Eta)
                    fprintf('  f%-2d = %.4f * (%s)%s%s\n', k, edges(k).Eta, rhsInflow, ...
                        repmat(' ', 1, max(1, 24 - length(rhsInflow))), arrowStr);
                else
                    fprintf('  f%-2d = PWL_%s(%s)%s%s\n', k, edges(k).Eta.name, rhsInflow, ...
                        repmat(' ', 1, max(1, 20 - length(rhsInflow) - length(edges(k).Eta.name))), arrowStr);
                end
            otherwise
                error('energy_hub_print_equations:type', ...
                    'Unknown edge type "%s" on edge %d.', edges(k).Type, k);
        end
    end

    fprintf('\nHub outputs:\n');
    for i = 1:numel(outputEdgeIdx)
        fprintf('  L.%-16s = f%d\n', outputLabels{i}, outputEdgeIdx(i));
    end
end
