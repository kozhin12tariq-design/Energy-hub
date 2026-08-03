function [elec, heat, PH2] = fc_true_output(p, PH2_raw)
%FC_TRUE_OUTPUT Fuel-cell output from the EXACT continuous efficiency curves.
%
%   [elec, heat, PH2] = FC_TRUE_OUTPUT(p, PH2_raw)
%
%   PH2_raw : fuel input per time step as returned by a solver (any shape)
%   elec, heat : true electrical / thermal output, same shape as PH2_raw(:)
%   PH2     : the CLAMPED fuel vector actually used
%
%   Evaluates p.PWL.eta_FC_e_func / eta_FC_th_func at u = PH2/FC_H2_max,
%   which is what "what the device would really have produced" means when a
%   piecewise-linear planning model is checked against reality.
%
%   WHY THIS EXISTS INSTEAD OF AN INLINE ONE-LINER: the electrical curve is
%       eta_e(u) = 0.30 + 0.35*sqrt(u) - 0.28*u^2
%   and sqrt() of a negative number is COMPLEX. A MILP solver routinely
%   returns -1e-15 for a variable that is really zero, so u can be very
%   slightly negative, and one such element makes the WHOLE output array
%   complex.
%
%   That is not a cosmetic problem, and the failure it caused is worth
%   recording. Octave's max(X, 0) on a COMPLEX array does not compare real
%   parts -- it compares MAGNITUDES. So the standard idiom for splitting a
%   net exchange into import and export,
%       Pimp = max(Pnet, 0);  Pexp = max(-Pnet, 0);
%   returns Pimp = -1.29 for Pnet = -1.29 + 0i, because |-1.29| > |0|. A
%   4.4 kWh export was priced as a 4.4 kWh import at the evening peak tariff
%   and the segment sweep reported a 19.85% planned-vs-realized gap at
%   nSegments = 5 that did not exist. Nothing warned: no error, no warning,
%   just a plausible-looking wrong number, and it appeared only when the LP
%   happened to return a NEGATIVE zero rather than a positive one -- which
%   is why it surfaced when the hub was re-sized and not before.
%
%   Clamping the fuel at zero fixes it at the source and is also the
%   physically correct statement: a fuel cell cannot consume negative fuel,
%   so a negative solver value IS zero, and no downstream quantity should
%   ever be complex. Callers that split a net exchange with max(...,0) are
%   then safe.

    PH2 = max(PH2_raw(:), 0);
    u = PH2 / p.PWL.FC_H2_max;
    elec = p.PWL.eta_FC_e_func(u)  .* PH2;
    heat = p.PWL.eta_FC_th_func(u) .* PH2;
end
