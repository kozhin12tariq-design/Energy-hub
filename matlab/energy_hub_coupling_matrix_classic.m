function C = energy_hub_coupling_matrix_classic(eta_FC, eta_PV, v)
%ENERGY_HUB_COUPLING_MATRIX_CLASSIC Classical (Geidl-Andersson) coupling matrix.
%
%   C = ENERGY_HUB_COUPLING_MATRIX_CLASSIC(eta_FC, eta_PV, v)
%
%   Hand-derived closed form of the same hub used in
%   energy_hub_define_network.m / energy_hub_coupling_matrix.m, kept here
%   only to cross-check the incidence-matrix reformulation.
%
%   Inputs  P = [P_grid; P_H2; P_solar; P_batt_discharge; P_EV_discharge]
%   Outputs L = [L_elec; P_batt_charge; P_EV_charge]
%
%   All five inputs reach the electrical bus with efficiency
%   eta_row = [1, eta_FC, eta_PV, 1, 1], then the bus power is split
%   among the three outputs by the dispatch factors v = [v1 v2 v3]
%   (sum(v) = 1):
%       L = v' * (eta_row * P) = (v' * eta_row) * P = C * P
%   i.e. C is the rank-1 outer product v' * eta_row.

    if abs(sum(v) - 1) > 1e-9
        error('energy_hub_coupling_matrix_classic:dispatch', ...
            'Dispatch factors v must sum to 1 (got sum = %.6f).', sum(v));
    end
    eta_row = [1, eta_FC, eta_PV, 1, 1];
    C = v(:) * eta_row;
end
