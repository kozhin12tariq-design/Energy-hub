function energy_hub_plot_graph(nodeNames, edges)
%ENERGY_HUB_PLOT_GRAPH Draw the hub's node/edge graph.
%
%   ENERGY_HUB_PLOT_GRAPH(nodeNames, edges)
%
%   Plain plot()/text()/annotation-free drawing (no graph/digraph object)
%   so it runs the same way in base MATLAB and in Octave.

    % Manual layout: [x y] per node, matches the node order in
    % energy_hub_define_network.m
    pos = [ ...
        0.0  2.0;   % 1 Grid_in
        0.0  1.0;   % 2 H2_in
        0.0  0.0;   % 3 Solar_in
        1.5  1.0;   % 4 FuelCell
        1.5  0.0;   % 5 PV
        3.0  1.0;   % 6 Bus
        4.5  2.0;   % 7 Battery
        4.5  0.0;   % 8 EV
        4.5  1.0];  % 9 Elec_Load

    % Edges sharing the same unordered node pair (e.g. a storage device's
    % charge and discharge edges both connect Bus<->Battery) are offset
    % sideways so they don't overlap on the plot.
    pairKey = zeros(numel(edges), 1);
    for k = 1:numel(edges)
        pairKey(k) = min(edges(k).From, edges(k).To) * 100 + max(edges(k).From, edges(k).To);
    end

    figure; hold on; box on;
    for k = 1:numel(edges)
        p1 = pos(edges(k).From, :);
        p2 = pos(edges(k).To, :);

        sameGroup = find(pairKey == pairKey(k));
        rankInGroup = find(sameGroup == k, 1);
        nInGroup = numel(sameGroup);
        offsetSteps = ((1:nInGroup) - (nInGroup+1)/2) * 0.35;

        % Perpendicular direction must be computed from a fixed
        % (direction-independent) reference for the node pair, otherwise
        % two opposite-direction edges (e.g. battery charge/discharge)
        % would flip both the perpendicular AND the rank sign and cancel
        % out, landing back on top of each other.
        loNode = min(edges(k).From, edges(k).To);
        hiNode = max(edges(k).From, edges(k).To);
        dRef = pos(hiNode,:) - pos(loNode,:);
        nrm = norm(dRef);
        perp = [0 0];
        if nrm > eps
            perp = [-dRef(2) dRef(1)] / nrm;
        end
        off = offsetSteps(rankInGroup) * perp;

        % stagger the along-edge position of the label too, so opposite
        % direction edges between the same two nodes don't print on top
        % of each other
        frac = 0.30 + 0.40 * (rankInGroup - 1) / max(nInGroup - 1, 1);

        arrow_line(p1 + off, p2 + off, [0.2 0.4 0.8]);
        labelPos = (1-frac)*(p1+off) + frac*(p2+off);
        text(labelPos(1), labelPos(2) + 0.10, sprintf('e%d (%.2f)', k, edges(k).Eta), ...
            'FontSize', 8, 'Color', [0.2 0.4 0.8], 'HorizontalAlignment', 'center');
    end

    for i = 1:numel(nodeNames)
        plot(pos(i,1), pos(i,2), 'ko', 'MarkerSize', 22, 'MarkerFaceColor', [1 1 1], 'LineWidth', 1.5);
        text(pos(i,1), pos(i,2), strrep(nodeNames{i}, '_', '\_'), ...
            'HorizontalAlignment', 'center', 'FontSize', 8, 'FontWeight', 'bold');
    end

    axis equal off;
    xlim([-0.6 5.1]); ylim([-0.6 2.6]);
    title({'Energy hub graph:','nodes (ports/converters/storage/load) and edges (power flow)'}, ...
        'FontSize', 10);
end

function arrow_line(p1, p2, color)
    plot([p1(1) p2(1)], [p1(2) p2(2)], '-', 'Color', color, 'LineWidth', 1.2);
    d = p2 - p1;
    n = norm(d);
    if n < eps
        return;
    end
    u = d / n;
    tip = p1 + 0.8 * d;                       % arrowhead position along the edge
    perp = [-u(2) u(1)];
    a1 = tip - 0.10 * u + 0.05 * perp;
    a2 = tip - 0.10 * u - 0.05 * perp;
    plot([a1(1) tip(1) a2(1)], [a1(2) tip(2) a2(2)], '-', 'Color', color, 'LineWidth', 1.2);
end
