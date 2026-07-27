function s = eh_describe_eta(eta)
%EH_DESCRIBE_ETA Human-readable description of a branch's Eta for labels.
%
%   s = EH_DESCRIBE_ETA(eta)
%
%   eta is either a constant scalar efficiency/dispatch factor or a PWL
%   breakpoint struct (see pwl_fit_from_function.m); components use this
%   so their edge labels stay readable regardless of which one was
%   passed in.

    if isnumeric(eta)
        s = num2str(eta);
    elseif isstruct(eta) && isfield(eta, 'type') && strcmp(eta.type, 'pwl')
        s = sprintf('PWL "%s", %d segments, 0..%.3g kW', eta.name, numel(eta.x)-1, eta.x(end));
    else
        s = '<unrecognized Eta>';
    end
end
