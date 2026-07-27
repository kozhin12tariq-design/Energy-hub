function comp = component_pv(name, eta_PV)
%COMPONENT_PV Individual component model: PV array (unidirectional, SISO).
%
%   comp = COMPONENT_PV(name, eta_PV)
%
%   Mathematical model
%     Local graph:  Solar_in --(input P_solar)--> PV_out --(eta_PV)--> Elec_Bus
%     Local nodes:  n1 = Solar_in, n2 = PV_out            (2 nodes)
%     Local edges:  e1 = (n1,n2) input,  e2 = (n2,'Elec_Bus') dependent
%     Local incidence matrix (rows n1,n2; cols e1,e2):
%         A_PV = [ 1   0 ;
%                 -1   1 ]
%     Constitutive/coupling law: P_elec = eta_PV * P_solar
%     i.e. a single-input single-output (SISO) converter branch.
%
%   `name` must be a unique instance identifier (e.g. 'PV1') so several
%   PV arrays can be instantiated in the same hub without node clashes.

    comp.name = name;
    comp.edges = { ...
        eh_edge('Solar_in', 'PV_out', 'input', 1, ['P_solar_' name], ...
            [name ': solar resource -> PV array (exogenous input)']), ...
        eh_edge('PV_out', 'Elec_Bus', 'dependent', eta_PV, '', ...
            [name ': PV array output -> electrical bus (eta_PV = ' num2str(eta_PV) ')']) ...
    };
end
