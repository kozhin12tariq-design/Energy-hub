function comp = component_fuelcell(name, eta_e, eta_th)
%COMPONENT_FUELCELL Individual component model: Fuel Cell (MIMO converter).
%
%   comp = COMPONENT_FUELCELL(name, eta_e, eta_th)
%
%   Mathematical model
%     Local graph:
%         H2_in --(input P_H2)--> FC_out --(eta_e)--> Elec_Bus
%                                         --(eta_th)-> Heat_Bus
%     Local nodes:  n1 = H2_in, n2 = FC_out               (2 nodes)
%     Local edges:  e1 = (n1,n2) input,
%                   e2 = (n2,'Elec_Bus') dependent,
%                   e3 = (n2,'Heat_Bus') dependent
%     Local incidence matrix (rows n1,n2; cols e1,e2,e3):
%         A_FC = [ 1   0   0 ;
%                 -1   1   1 ]
%     Constitutive/coupling law:
%         [P_elec; P_heat] = [eta_e; eta_th] * P_H2
%     One input (hydrogen fuel) simultaneously drives two independent
%     outputs (electricity and recovered waste heat) -- a genuine
%     multi-input/multi-output (here 1-in/2-out, i.e. SIMO) conversion
%     branch: node FC_out is the tail of two dependent edges that both
%     read the same inflow, one per energy carrier.
%
%   eta_e, eta_th are typical PEMFC/SOFC-CHP electrical/thermal
%   efficiencies (e.g. 0.45 / 0.35); eta_e + eta_th < 1 leaves a margin
%   for unrecovered losses. Each may instead be a PWL breakpoint struct
%   (see pwl_fit_from_function.m) for a variable/part-load-dependent
%   efficiency curve -- the sanity check below only applies to the
%   constant-efficiency case (a PWL curve's combined output is the fitter
%   caller's responsibility, since it varies point-by-point with load).

    if isnumeric(eta_e) && isnumeric(eta_th) && eta_e + eta_th > 1
        error('component_fuelcell:efficiency', ...
            'eta_e + eta_th must not exceed 1 (got %.3f).', eta_e + eta_th);
    end

    comp.name = name;
    comp.edges = { ...
        eh_edge('H2_in', 'FC_out', 'input', 1, ['P_H2_' name], ...
            [name ': hydrogen fuel -> fuel cell (exogenous input)']), ...
        eh_edge('FC_out', 'Elec_Bus', 'dependent', eta_e, '', ...
            [name ': FC electrical output -> electrical bus (eta_e = ' eh_describe_eta(eta_e) ')']), ...
        eh_edge('FC_out', 'Heat_Bus', 'dependent', eta_th, '', ...
            [name ': FC recovered heat -> heat bus (eta_th = ' eh_describe_eta(eta_th) ') [MIMO branch]']) ...
    };
end
