function comp = component_electrolyzer(name, v_ch, eta_H2)
%COMPONENT_ELECTROLYZER Individual component model: Electrolyzer (Power-to-Gas).
%
%   comp = COMPONENT_ELECTROLYZER(name, v_ch, eta_H2)
%
%   Unlike PV/Fuel Cell (which are driven by an exogenous resource --
%   solar irradiance, purchased fuel), an electrolyzer is a LOAD on the
%   electrical bus: it consumes whatever share of bus power is dispatched
%   to it, exactly like a battery's charge branch (component_battery.m).
%   Chaining that dispatch edge into a conversion edge is what lets one
%   node (Conv_in) be fed by a dispatch decision and then drive a
%   (possibly nonlinear/PWL) conversion -- a second structural pattern
%   beyond the direct-exogenous-input converters, assembled with the same
%   generic mechanism.
%
%   Mathematical model
%       Elec_Bus --(dependent v_ch)--> Conv_in --(eta_H2)--> H2_Bus
%   Local nodes:  n1 = Elec_Bus (shared), n2 = Conv_in
%   Local incidence matrix (rows n1,n2; cols e1,e2):
%       A_ELY = [-1   0 ;
%                 1  -1 ]
%   Constitutive law: P_H2 = eta_H2 * (v_ch * inflow(Elec_Bus))
%
%   v_ch is this instance's dispatch factor for the electrical bus (like
%   component_battery.m's charge share); eta_H2 may be a scalar (constant
%   efficiency) or a PWL struct from pwl_fit_from_function.m (variable
%   efficiency vs. load), exactly like component_pv.m / component_fuelcell.m.
%
%   Included to demonstrate that energy_hub_assemble.m handles an
%   entirely new component type and carrier bus (here 'H2_Bus', a
%   hydrogen network fed by this converter) with zero changes to the
%   assembler or to any other component -- the concrete proof for
%   "automatic generation of energy flow equations for arbitrary
%   configurations".

    comp.name = name;
    comp.edges = { ...
        eh_edge('Elec_Bus', 'Conv_in', 'dependent', v_ch, '', ...
            [name ': electrical bus -> electrolyzer (dispatch v_ch = ' num2str(v_ch) ')']), ...
        eh_edge('Conv_in', 'H2_Bus', 'dependent', eta_H2, '', ...
            [name ': electrolyzer output -> hydrogen bus (eta_H2 = ' eh_describe_eta(eta_H2) ')']) ...
    };
end
