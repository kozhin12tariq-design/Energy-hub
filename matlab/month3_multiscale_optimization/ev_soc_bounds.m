function [lo, hi] = ev_soc_bounds(p, evAvailable)
%EV_SOC_BOUNDS State-of-charge bounds for the EV fleet in one time step.
%
%   [lo, hi] = EV_SOC_BOUNDS(p, evAvailable)
%
%   evAvailable : true/1 when the fleet is plugged in during this step
%                 (p.EV.pluggedInHours), false/0 when it is away.
%
%   WHY THIS IS NOT SIMPLY [SOCmin, SOCmax].
%
%   p.EV.SOCmin/SOCmax define the USABLE band -- the range the operator is
%   willing to cycle the batteries through. That is an OPERATIONAL limit,
%   and an operational limit can only be honoured by an action. When the
%   fleet is plugged in, the action exists (charge, or stop discharging) and
%   the band is a genuine constraint on the dispatch. When the fleet is
%   away, Pch and Pdis are both bounded to zero and the SOC recursion
%   reduces to free decay,
%       SOC(t) = SOC(t-1) * (1 - selfLoss*dt),
%   with no decision variable in it at all. Imposing SOC >= SOCmin on that
%   row does not constrain a choice; it asserts that self-discharge does
%   not happen, and if the state has already reached SOCmin the assertion
%   is simply false and the MILP is INFEASIBLE.
%
%   HOW THAT SURFACED, because it is worth recording rather than quietly
%   patching. The hub was re-sited and scaled up (hub_sizing.m). At the
%   larger size the intraday optimizer found it worthwhile to run the EV
%   fleet down to exactly SOCmin = 0.20 in the last plugged-in slot of the
%   morning, which is legal. One slot later the fleet departs, self-
%   discharge takes the state to 0.19990, and glpk reported
%   "PROBLEM HAS NO PRIMAL FEASIBLE SOLUTION" -- a myopic-horizon trap in
%   which a decision that is feasible at step k makes step k+1 infeasible.
%   The bug is not the size: it was always latent, and the smaller hub
%   simply never chose to sit exactly on the bound at that hour. The fix is
%   the same at every size.
%
%   WHAT THE RELAXATION COSTS, quantified rather than waved through. Over
%   the fleet's whole 11-hour absence, free decay at selfLoss = 0.002/h
%   removes 0.002*11 = 2.2% of the state, so an EV that departs at the
%   20% floor returns at about 19.6%. The relaxed bound therefore admits
%   states at most ~0.4 percentage points below SOCmin, and only while the
%   vehicle is away and nothing can be done about it. It does NOT let the
%   optimizer discharge the fleet below its reserve: Pdis is zero
%   throughout that window. The moment the fleet plugs back in the full
%   [SOCmin, SOCmax] band applies again, which is enforceable because
%   charging is available.
%
%   The bounds returned while away are the battery's PHYSICAL limits,
%   0 and 1 -- the same 0..1 normalisation storage_soc_update.m uses.

    if evAvailable
        lo = p.EV.SOCmin;
        hi = p.EV.SOCmax;
    else
        lo = 0;
        hi = 1;
    end
end
