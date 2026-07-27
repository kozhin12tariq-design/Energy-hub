function [nodeNames, edges, nInputs, inputLabels, outputEdgeIdx, outputLabels] = ...
    energy_hub_assemble(sharedBuses, components, extraEdges)
%ENERGY_HUB_ASSEMBLE Assemble individual component models into one hub graph.
%
%   [nodeNames, edges, nInputs, inputLabels, outputEdgeIdx, outputLabels] = ...
%       ENERGY_HUB_ASSEMBLE(sharedBuses, components, extraEdges)
%
%   This is the graph-theory step that ties the individually-modeled
%   components (component_pv.m, component_fuelcell.m, ...) together into
%   one hub: every component contributes a small local graph (its
%   `.edges` list of eh_edge specs using local node names); this
%   function merges them into one global node/edge list by identifying
%   any endpoint name that matches a shared bus (e.g. 'Elec_Bus',
%   'Heat_Bus') as the SAME global node across every component, while
%   giving every other endpoint name a component-private namespace
%   (`<instanceName>_<localName>`) so multiple instances of the same
%   component type never collide.
%
%   The resulting node/edge list already carries everything
%   energy_hub_incidence_matrix.m / energy_hub_coupling_matrix.m need
%   (From, To, Type, Eta, InputIndex) -- those two functions are
%   completely unchanged by adding components, buses, or MIMO/
%   bidirectional branches, because "dependent edge = eta * inflow(tail
%   node)" already covers both cases generically (see eh_edge.m).
%
%   Inputs
%     sharedBuses : cellstr of global bus/carrier node names, e.g.
%                   {'Elec_Bus','Heat_Bus'}
%     components  : cell array of component structs (each with .name and
%                   .edges, as returned by the component_*.m functions)
%     extraEdges  : cell array of eh_edge specs for hub-level branches
%                   that do not belong to any single component (grid
%                   import, loads, ...); endpoint names here are always
%                   used as-is (never namespaced)
%
%   Outputs
%     nodeNames     : global node names, in first-seen order
%     edges         : global edge struct array (From, To, Type, Eta,
%                     InputIndex, Label, Component)
%     nInputs       : number of distinct hub inputs found
%     inputLabels   : name of each hub input, in P-vector order
%     outputEdgeIdx : edge indices tagged as hub outputs
%     outputLabels  : name of each hub output, in L-vector order

    rawSpecs = {};
    for ci = 1:numel(components)
        c = components{ci};
        for ei = 1:numel(c.edges)
            e = c.edges{ei};
            e.From = resolve_name(e.From, c.name, sharedBuses);
            e.To   = resolve_name(e.To,   c.name, sharedBuses);
            e.Component = c.name;
            rawSpecs{end+1} = e; %#ok<AGROW>
        end
    end
    for ei = 1:numel(extraEdges)
        e = extraEdges{ei};
        e.Component = '';
        rawSpecs{end+1} = e; %#ok<AGROW>
    end

    nodeNames = {};
    nodeIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
    for k = 1:numel(rawSpecs)
        nodeNames = register_node(nodeNames, nodeIndex, rawSpecs{k}.From);
        nodeNames = register_node(nodeNames, nodeIndex, rawSpecs{k}.To);
    end

    inputLabels = {};
    inputIndexMap = containers.Map('KeyType', 'char', 'ValueType', 'double');
    outputLabels = {};
    outputEdgeIdx = [];

    edges = struct('From', {}, 'To', {}, 'Type', {}, 'Eta', {}, ...
                    'InputIndex', {}, 'Label', {}, 'Component', {});
    for k = 1:numel(rawSpecs)
        s = rawSpecs{k};
        edges(k).From = nodeIndex(s.From);
        edges(k).To   = nodeIndex(s.To);
        edges(k).Type = s.Type;
        edges(k).Eta  = s.Eta;
        edges(k).Label = s.Label;
        edges(k).Component = s.Component;
        edges(k).InputIndex = [];

        if strcmp(s.Type, 'input')
            if ~isKey(inputIndexMap, s.IOTag)
                inputLabels{end+1} = s.IOTag; %#ok<AGROW>
                inputIndexMap(s.IOTag) = numel(inputLabels);
            end
            edges(k).InputIndex = inputIndexMap(s.IOTag);
        elseif strcmp(s.Type, 'dependent') && ~isempty(s.IOTag)
            outputLabels{end+1} = s.IOTag; %#ok<AGROW>
            outputEdgeIdx(end+1) = k; %#ok<AGROW>
        end
    end

    nInputs = numel(inputLabels);
end

function name = resolve_name(rawName, compName, sharedBuses)
    if any(strcmp(rawName, sharedBuses))
        name = rawName;
    else
        name = [compName '_' rawName];
    end
end

function nodeNames = register_node(nodeNames, nodeIndex, name)
    if ~isKey(nodeIndex, name)
        nodeNames{end+1} = name; %#ok<AGROW>
        nodeIndex(name) = numel(nodeNames);
    end
end
