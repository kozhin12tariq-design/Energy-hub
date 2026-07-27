function e = eh_edge(from, to, type, eta, ioTag, label)
%EH_EDGE Build one edge specification for a component or hub-level graph.
%
%   e = EH_EDGE(from, to, type, eta, ioTag, label)
%
%   from, to : node name strings. A name is treated as a *shared* hub bus
%              (e.g. 'Elec_Bus') if it is passed unchanged by the caller;
%              energy_hub_assemble.m namespaces every other name to the
%              owning component instance so multiple instances of the
%              same component type never collide.
%   type     : 'input'     - exogenous branch, value fixed by the hub
%                             input vector P (see ioTag)
%              'dependent' - branch value = eta * (total flow entering
%                             node `from`); this single rule is what lets
%                             one node feed several dependent edges at
%                             once (MIMO conversion) and lets storage
%                             nodes sit on two independent directed edges
%                             (bidirectional flow)
%   eta      : branch efficiency (Type='dependent') or 1 (Type='input',
%              the exogenous value itself is not scaled here)
%   ioTag    : Type='input'     -> name of the hub input this edge maps to
%              Type='dependent' -> name of the hub output this edge maps
%                                   to, or '' if it is an internal branch
%              (not a hub-level port)
%   label    : human-readable description

    e.From = from;
    e.To = to;
    e.Type = type;
    e.Eta = eta;
    e.IOTag = ioTag;
    e.Label = label;
end
