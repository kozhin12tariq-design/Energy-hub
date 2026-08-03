function k = hub_scale_of(p)
%HUB_SCALE_OF Hub size multiplier carried by a parameter struct.
%
%   k = HUB_SCALE_OF(p)
%
%   Returns p.sizing.hubScale when the struct came from
%   multiscale_default_params, and 1.0 otherwise. The fallback exists so
%   the dispatch functions stay usable with a hand-built parameter struct
%   (several regression checks build one) instead of erroring on a missing
%   field.
%
%   Used only for quantities that are "effectively unbounded" placeholders
%   rather than modelled limits -- see GRID_CAP in dayahead_dispatch.m,
%   intraday_dispatch.m and realtime_balance.m. A placeholder that does not
%   scale with the hub stops being a placeholder at some size and becomes a
%   silent, undocumented constraint; that is the failure mode this avoids.

    if isfield(p, 'sizing') && isfield(p.sizing, 'hubScale')
        k = p.sizing.hubScale;
    else
        k = 1.0;
    end
end
