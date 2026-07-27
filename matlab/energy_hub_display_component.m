function A_local = energy_hub_display_component(comp)
%ENERGY_HUB_DISPLAY_COMPONENT Print + return one component's own local
%incidence matrix, independent of any hub assembly.
%
%   A_local = ENERGY_HUB_DISPLAY_COMPONENT(comp)
%
%   Builds a small standalone graph directly from comp.edges (local
%   names used as-is, no bus sharing/namespacing) so an individual
%   component's mathematical model can be inspected on its own, exactly
%   as specified in component_pv.m / component_fuelcell.m /
%   component_battery.m / component_ev.m.

    names = {};
    idxMap = containers.Map('KeyType', 'char', 'ValueType', 'double');
    nEdges = numel(comp.edges);
    localFrom = zeros(nEdges, 1);
    localTo   = zeros(nEdges, 1);

    for i = 1:nEdges
        e = comp.edges{i};
        if ~isKey(idxMap, e.From)
            names{end+1} = e.From; %#ok<AGROW>
            idxMap(e.From) = numel(names);
        end
        if ~isKey(idxMap, e.To)
            names{end+1} = e.To; %#ok<AGROW>
            idxMap(e.To) = numel(names);
        end
        localFrom(i) = idxMap(e.From);
        localTo(i)   = idxMap(e.To);
    end

    E = struct('From', num2cell(localFrom), 'To', num2cell(localTo));

    fprintf('\n--- Component "%s" (%d local nodes, %d edges) ---\n', ...
        comp.name, numel(names), nEdges);
    fprintf('  Local nodes: %s\n', strjoin(names, ', '));
    for i = 1:nEdges
        e = comp.edges{i};
        fprintf('  e%d: %-12s -> %-12s  %-9s eta=%.3f  %s\n', ...
            i, e.From, e.To, e.Type, e.Eta, e.Label);
    end

    A_local = energy_hub_incidence_matrix(E, numel(names));
    fprintf('  Local incidence matrix A_%s:\n', comp.name);
    disp(A_local);
end
