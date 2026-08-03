function s = hub_sizing()
%HUB_SIZING Where the ONE hub sits, and how big it is. Single source of truth.
%
%   s = HUB_SIZING()
%
%   Two numbers decide the entire physical scale of this study -- WHICH bus
%   hosts the single energy hub, and HOW LARGE that hub is -- and until now
%   they were spread across three files (a default argument in
%   ieee33_system_definition.m, a set of nameplate ratings in
%   multiscale_default_params.m, and a set of demand/PV profiles in
%   forecast_profiles.m). Anything that changes one of the three must
%   change all three or the model becomes internally inconsistent (large
%   ratings serving small loads, or the reverse). They are defined here,
%   once, and the three files read them.
%
%   ------------------------------------------------------------------
%   WHY THE HUB MOVED FROM BUS 18 TO BUS 25, AND WHY IT GREW BY 4.667x
%   ------------------------------------------------------------------
%   The earlier configuration -- a ~104 kW hub at bus 18 -- had a defect
%   that only became visible once the network studies were built on top of
%   it. At 2.79% of the 3715 kW feeder, the hub was too small to move any
%   feeder-wide quantity. Month 4c then reported that PWL segment count
%   does not change grid outcomes, and Month 4b that reserve margin does
%   not change voltage. Both statements were true, but neither was a
%   statement about SEGMENTATION or RESERVE: they were statements about
%   hub size. A 104 kW device cannot move a 3715 kW feeder no matter what
%   internal model it uses, so those sweeps could not have come out any
%   other way, and reporting them as findings about the mechanisms was
%   over-claiming.
%
%   THE CONSTRAINT THAT DECIDES HOW BIG A HUB A BUS CAN HOST. The
%   do-no-harm floor used throughout Month 4d says no bus may be driven
%   below its own no-hub voltage. Written out in LinDistFlow terms for a
%   hub at bus h with import P and reactive injection Q, the row for bus j
%   is
%       C_j + a_j*P - b_j*Q  >=  C_j + a_j*L_h
%   and dividing by a_j (which is negative) gives
%       P  <=  L_h + (b_j/a_j)*Q .
%   The per-bus sensitivities a_j and b_j CANCEL. The largest import a hub
%   may draw without harming any bus is set by L_h -- the nominal load of
%   the bus it replaces -- and nothing else. Voltage sensitivity decides
%   how much a given kW MATTERS; it does not decide how many kW are
%   allowed. That is why hub size has to be chosen against the host bus's
%   load, and it is why bus 18 (90 kW) can never host a hub that is
%   feeder-relevant.
%
%   AND THE TWO CRITERIA POINT DIFFERENT WAYS. Measured on IEEE 33:
%     bus 18: a = -6.90e-05 pu/kW, L = 90 kW  -> most sensitive per kW,
%             smallest hostable hub
%     bus 25: a = -1.77e-05 pu/kW, L = 420 kW -> 3.9x less sensitive per
%             kW, 4.67x larger hostable hub
%   The product |a_h|*L_h -- the voltage swing the hub commands at its own
%   bus when it uses its full do-no-harm allowance -- is 0.0062 pu at bus
%   18 and 0.0074 pu at bus 25, i.e. essentially the same LOCAL authority
%   from very different sizes. The two buses are near-equivalent locally
%   and utterly different feeder-wide, so the choice is decided by the
%   feeder-wide question, which is the one that was unanswerable before.
%   (Bus 32, at 0.0083 pu, edges out both, but it carries 210 kW and sits
%   on the same lateral as bus 33, which Month 2b uses as its deliberately
%   adverse siting; bus 25 is the feeder's largest single load and is the
%   bus the siting study already identified as best for losses.)
%
%   THE SCALE FACTOR IS NOT A FREE PARAMETER. It is
%       scale = L(bus 25) / L(bus 18) = 420 / 90 = 4.6667
%   so the hub's size RELATIVE TO ITS HOST BUS is exactly what it was
%   before -- peak import stays at 115.3% of the host bus load, the
%   do-no-harm cap binds by exactly the same relative margin, and the
%   inverter, storage and fuel cell keep their existing proportions to one
%   another and to the local demand. The ONLY thing that changes is the
%   hub's size relative to the FEEDER (2.79% -> 13.0% of feeder load).
%   That is deliberately a controlled experiment: one variable moves, and
%   it is the variable the previous sweeps could not resolve.
%
%   WHAT IS *NOT* SCALED, and this is a hard rule: no efficiency, no
%   efficiency curve, no price, no emission factor, no state-of-charge
%   band, no self-discharge rate, no reserve fraction, no diversity
%   factor. Those are all intensive quantities -- they describe how the
%   equipment behaves, not how much of it there is -- and changing them
%   would make this a different hub rather than a bigger one. Only
%   extensive quantities (kW, kWh, kVA ratings and the local kW demand /
%   PV profiles) are multiplied by `scale`.
%
%   HONEST CONSEQUENCE OF THE MOVE: bus 18 is the electrically weakest bus
%   on the feeder (0.9131 pu, the benchmark's own minimum) and was chosen
%   as the most demanding test. Bus 25 sits at 0.9694 pu, comfortably
%   above the 0.95 limit, so the hub no longer sits at the feeder's worst
%   point. The feeder minimum is still bus 18 and the hub still cannot
%   repair it -- Month 4d's "a 0.95 pu floor everywhere is structurally
%   infeasible" finding is unaffected, and is if anything easier to see
%   now that the hub is nowhere near the offending bus. What is gained is
%   the ability to ask whether a hub that is 13% of its feeder changes
%   feeder-wide outcomes. What is given up is the weakest-bus stress test.
%   Both are stated wherever the host bus is reported.
%
%   Output struct s:
%     hostBus, hostBusLoad_kW : the ONE bus hosting the ONE hub
%     refBus, refBusLoad_kW   : the previous host bus, kept as the
%                               reference the scale factor is derived from
%     scale                   : multiplier applied to every extensive
%                               rating and to the local demand/PV profiles
%     refPeakImport_kW        : measured peak net import of the scale-1
%                               hub (day-ahead, network-constrained)
%     peakImport_kW           : scale * refPeakImport_kW, the reference
%                               peak used for the penetration percentages
%
%   To reproduce the pre-Task-3 configuration exactly, no edit to this
%   file is needed -- pass the old values explicitly:
%       p   = multiscale_default_params(1.0);
%       fc  = forecast_profiles(42, 1.0, 1.0);
%       sys = ieee33_system_definition(18, 1.0);

    thisFile = mfilename('fullpath');
    addpath(fullfile(fileparts(thisFile), '..', 'month2_coupling_matrix_pwl_ieee33'));

    % Host-bus loads are READ from the benchmark rather than written down
    % here, so the scale factor cannot silently drift away from the network
    % data it is derived from.
    [~, busP_base] = ieee33_data();

    s.hostBus = 25;
    s.refBus  = 18;
    s.hostBusLoad_kW = busP_base(s.hostBus);   % 420 kW
    s.refBusLoad_kW  = busP_base(s.refBus);    %  90 kW

    s.scale = s.hostBusLoad_kW / s.refBusLoad_kW;   % 14/3 = 4.6667

    % Measured, not assumed: the scale-1 hub's peak net import under the
    % network-constrained day-ahead MILP. Fixed here rather than
    % re-simulated so this function stays cheap and side-effect free;
    % network_verify.m reports the ACTUAL per-timestep injections and every
    % script that needs the true peak takes it from the solution.
    s.refPeakImport_kW = 103.76;
    s.peakImport_kW    = s.scale * s.refPeakImport_kW;
end
