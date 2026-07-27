function energy_hub_plot_graph(nodeNames, edges)
%ENERGY_HUB_PLOT_GRAPH Draw the hub's node/edge graph, any topology.
%
%   ENERGY_HUB_PLOT_GRAPH(nodeNames, edges)
%
%   Node positions are computed automatically (not hardcoded) so this
%   works for whatever set of components energy_hub_assemble.m was given:
%     col 1 : pure sources   (no incoming edge)
%     col 2 : pre-bus converters (feed a "*_Bus" node, e.g. PV/FC output)
%     col 3 : carrier buses  (name ends in "_Bus")
%     col 4 : post-bus branches (fed BY a bus, e.g. storage cells)
%     col 5 : pure sinks     (no outgoing edge)
%   Edges sharing the same node pair (e.g. a storage device's charge and
%   discharge branches) are offset sideways so they don't overlap.
%
%   Plain plot()/text() drawing (no graph/digraph object) so it runs the
%   same way in base MATLAB and in Octave.

    nNodes = numel(nodeNames);
    pos = layout_nodes(nodeNames, edges, nNodes);

    pairKey = zeros(numel(edges), 1);
    for k = 1:numel(edges)
        pairKey(k) = min(edges(k).From, edges(k).To) * 100000 + max(edges(k).From, edges(k).To);
    end

    figure('Position', [100 100 1150 700]); hold on; box on;
    for k = 1:numel(edges)
        p1 = pos(edges(k).From, :);
        p2 = pos(edges(k).To, :);

        sameGroup = find(pairKey == pairKey(k));
        rankInGroup = find(sameGroup == k, 1);
        nInGroup = numel(sameGroup);
        offsetSteps = ((1:nInGroup) - (nInGroup+1)/2) * 0.28;

        loNode = min(edges(k).From, edges(k).To);
        hiNode = max(edges(k).From, edges(k).To);
        dRef = pos(hiNode,:) - pos(loNode,:);
        nrm = norm(dRef);
        perp = [0 0];
        if nrm > eps
            perp = [-dRef(2) dRef(1)] / nrm;
        end
        off = offsetSteps(rankInGroup) * perp;

        arrow_line(p1 + off, p2 + off, [0.2 0.4 0.8]);

        % Many edges converge on hub/bus nodes; besides the same-pair
        % offset above, stagger the label's position along the edge and
        % its vertical offset by edge index so labels on DIFFERENT edges
        % that happen to meet at the same busy node don't all print on
        % top of each other.
        labelFrac = 0.22 + 0.16 * mod(k, 3);
        labelPos = (1-labelFrac)*(p1+off) + labelFrac*(p2+off);
        vOff = 0.12 * (1 - 2*mod(k, 2));
        text(labelPos(1), labelPos(2) + vOff, sprintf('e%d (%.2f)', k, edges(k).Eta), ...
            'FontSize', 7, 'Color', [0.2 0.4 0.8], 'HorizontalAlignment', 'center');
    end

    for i = 1:nNodes
        plot(pos(i,1), pos(i,2), 'ko', 'MarkerSize', 20, 'MarkerFaceColor', [1 1 1], 'LineWidth', 1.5);
        text(pos(i,1), pos(i,2) - 0.35, strrep(nodeNames{i}, '_', '\_'), ...
            'HorizontalAlignment', 'center', 'FontSize', 7.5, 'FontWeight', 'bold');
    end

    axis equal off;
    xlim([-0.7 max(pos(:,1))+0.7]); ylim([min(pos(:,2))-0.7 max(pos(:,2))+1.0]);
    title({'Energy hub graph:','nodes (ports/converters/buses/storage/loads) and edges (power flow)'}, ...
        'FontSize', 10);
end

function pos = layout_nodes(nodeNames, edges, nNodes)
    inCount = zeros(nNodes, 1);
    outCount = zeros(nNodes, 1);
    for k = 1:numel(edges)
        outCount(edges(k).From) = outCount(edges(k).From) + 1;
        inCount(edges(k).To) = inCount(edges(k).To) + 1;
    end

    isBusNode = false(nNodes, 1);
    for i = 1:nNodes
        isBusNode(i) = ~isempty(regexp(nodeNames{i}, '_Bus$', 'once'));
    end

    col = zeros(nNodes, 1);
    for i = 1:nNodes
        if inCount(i) == 0
            col(i) = 1;
        elseif outCount(i) == 0
            col(i) = 5;
        elseif isBusNode(i)
            col(i) = 3;
        else
            feedsBus = false;
            fromBus = false;
            for k = 1:numel(edges)
                if edges(k).From == i && isBusNode(edges(k).To)
                    feedsBus = true;
                end
                if edges(k).To == i && isBusNode(edges(k).From)
                    fromBus = true;
                end
            end
            if fromBus
                col(i) = 4;
            elseif feedsBus
                col(i) = 2;
            else
                col(i) = 3;
            end
        end
    end

    xSpacing = 2.6;
    ySpacing = 2.0;
    pos = zeros(nNodes, 2);
    for c = 1:5
        members = find(col == c);
        n = numel(members);
        for j = 1:n
            y = ((n+1)/2 - j) * ySpacing;
            pos(members(j), :) = [(c-1)*xSpacing, y];
        end
    end
end

function arrow_line(p1, p2, color)
    plot([p1(1) p2(1)], [p1(2) p2(2)], '-', 'Color', color, 'LineWidth', 1.2);
    d = p2 - p1;
    n = norm(d);
    if n < eps
        return;
    end
    u = d / n;
    tip = p1 + 0.75 * d;
    perp = [-u(2) u(1)];
    a1 = tip - 0.12 * u + 0.06 * perp;
    a2 = tip - 0.12 * u - 0.06 * perp;
    plot([a1(1) tip(1) a2(1)], [a1(2) tip(2) a2(2)], '-', 'Color', color, 'LineWidth', 1.2);
end
