# Energy Hub — Matrix Modeling and Multi-Time-Space Scale Optimization

MATLAB/Octave implementation of the full thesis roadmap: a multi-carrier
energy hub (PV, Fuel Cell, Battery, EV, Electrolyzer, Heat Pump) modeled
with the incidence-and-coupling-matrix method, integrated into the IEEE
33-bus distribution system, and dispatched with a three-level (day-ahead
/ intraday / real-time) optimization framework — evaluated with case
studies and a sensitivity analysis.

## One hub, benchmarked on IEEE 33

Two things define the scope of this study:

**Exactly one energy hub.** The thesis models a *single* hub containing
the full technology set — PV, fuel cell, battery, EV fleet, heat pump,
building and pipe thermal storage — on shared electrical and heat buses
with grid import/export. There is never more than one hub anywhere in the
codebase. Where several buses are examined (`main_month2b...`), they are
**alternative sitings of that one hub**, each solved on its own against
the clean base case, never coexisting. `ieee33_system_definition.m` is
the single source of truth for what the study system is.

**IEEE 33 is the benchmark for every result.** Dispatch is no longer
reported from a network-free abstraction: every case study, scenario and
PWL segmentation run is replayed through the exact IEEE 33 power flow and
reports bus voltages and feeder losses alongside cost, CO2 and fuel. Two
modes exist:

| Mode | File | What it does |
|---|---|---|
| **Verify-only** (default) | `network_verify.m` | Replays a completed dispatch through the exact backward-forward sweep. `distflow_bfs` is iterative and nonlinear, so it cannot sit inside a MILP — this *verifies* a schedule, it does not *constrain* one. |
| **Co-optimized** | `lindistflow_sensitivity.m` + `p.network` in **all three** of `dayahead_dispatch.m`, `intraday_dispatch.m` and `realtime_balance.m`, driven by `main_month4d...` | Embeds a linearized DistFlow voltage model in the MILP so the network constrains the schedule while it is chosen, at every time resolution. Opt-in; absent `p.network` the model is bit-identical to the network-free one. The real-time floor is *soft* (penalised slack) because a hard one there is genuinely infeasible. |

Every script now reports network consequences, including the sensitivity
analysis (`main_month4b...`), which was the last one judging results by
the scalar feeder cap alone.

**The hub exchanges reactive power, to a published standard.** It was
previously modelled at unity power factor, which is not a conservative
assumption but an unrealistic one: it removes the only mechanism by which
a hub can support voltage, and it was the root cause of several negative
findings here. `p.Inverter` (`multiscale_default_params.m`) now gives the
grid-facing inverter an apparent-power rating and a reactive decision
variable in **all three** dispatch layers:

| Quantity | Value | Basis |
|---|---|---|
| Design active power | 574 kW | non-coincident connected load (peak demand + EV + battery + heat-pump ratings), the same basis `feeder_capacity.m` uses |
| Oversize | 1.15 | smallest sensible margin above the algebraic minimum `S ≥ P/√(1−0.44²) = 1.114·P` needed to deliver the standard's reactive capability at rated P |
| `S_max` | 660.1 kVA | |
| Reactive limit | **±0.44·S = ±290.4 kvar** | **IEEE Std 1547-2018, Clause 5.2, Category B**: a DER shall be capable of *injecting and absorbing* at least 44% of nameplate apparent power (= 0.90 pf at rated P). Category A requires 44% injection but only 25% absorption; B is the symmetric one that applies to DER expected to provide voltage support. Verified against the clause, not assumed. |
| S-limit linearization | 12-sided polygon **inscribed** in `P²+Q² ≤ S²` | an inscribed polygon lies strictly inside the true limit, so the model slightly *under*-uses the inverter — the safe direction. Worst-case shortfall `1 − cos(π/12) = 3.4%`. |
| `Qcost` | 1e−4 $/kvarh | a **tie-breaker only**. With no voltage constraint active the optimizer is indifferent to Q, and `glpk` returned an arbitrary vertex — observed pinned at full absorption for all 24 hours, which would have silently *degraded* voltage in every verify-only result. The tie is broken toward Q = 0, which is both physically right (reactive current causes real conduction loss) and normatively right (IEEE 1547's default mode is constant power factor at unity). Its total effect on daily cost is printed so a reader can confirm it does no real work. |

A model whose network output depends on solver tie-breaking is not
reporting physics; that is why the coefficient exists and why its size is
justified rather than chosen.

**Scale, and why it moved.** The hub sits at **bus 25** and its peak
import is **484 kW** — **13.03% of the 3715 kW feeder**, and **115% of its
host bus's own 420 kW load**. Both figures are reported everywhere so the
scale is never quoted one-sidedly.

It was not always this size. An earlier configuration put a ~104 kW hub at
bus 18 (2.79% feeder-wide, 115% of that bus's 90 kW load) and argued
explicitly against scaling it up, on the grounds that the local effect was
already measurable and scaling would move the Case 1–4 regression anchors.
That was right for the local questions and wrong for the feeder-wide ones:
two headline findings — *"PWL segment count does not change grid outcomes"*
(Month 4c) and *"reserve margin does not move voltage"* (Month 4b) — were
measured on a hub too small for either sweep to have come out any other
way. They were reporting the hub's size, not the mechanism each claimed to
study. Preserving regression anchors is not a good enough reason to leave
findings resting on an untestable configuration.

The scale factor is **derived, not chosen**: `hub_sizing().scale =
L(bus 25) / L(bus 18) = 420/90 = 4.6667`, so the hub's size *relative to
its host bus* is unchanged and only its size *relative to the feeder*
moves. One variable, and it is the one the sweeps could not resolve.

**What decides how big a hub a bus can host** — the reason bus 18 could
never have worked. Under the do-no-harm floor used throughout Month 4d, the
per-bus LinDistFlow constraint for a hub at bus *h* rearranges to
`P ≤ L_h + (b_j/a_j)·Q`: the sensitivities `a_j`, `b_j` **cancel**, and the
largest import a hub may draw is set by `L_h`, the nominal load of the bus
it replaces. Voltage sensitivity decides how much a kW *matters*; it does
not decide how many kW are *allowed*. Bus 18 is the most sensitive bus per
kW (−6.90e−05 pu/kW) and carries only 90 kW; bus 25 is 3.9× less sensitive
and carries 420 kW. The product |a_h|·L_h — local voltage authority at full
do-no-harm allowance — is 0.0062 pu at bus 18 and 0.0074 pu at bus 25, i.e.
**near-identical locally and utterly different feeder-wide**.

**What that cost.** Bus 18 is the electrically weakest bus in the base case
(0.9131 pu, the benchmark's own minimum) and was the most demanding place
to site an active node. Bus 25 sits at 0.9694 pu. The feeder minimum is
still bus 18, and the hub — now on a *different lateral* — reaches it only
through the two trunk branches their paths share. `ieee33_system_definition(18, 1.0)`
restores the old siting and size exactly, and Month 2b still evaluates
buses 18, 25 and 33 side by side.

**Three seasons, not one generic day.** Every result used to come from a
single 24-hour profile, which for a *multi-carrier* hub is the largest
realism gap there is: heat demand peaks when PV output is at its minimum,
so one averaged day cancels the two carriers against each other.
`forecast_profiles(seed, unc, hubScale, season)` now takes
`'winter' | 'shoulder' | 'summer'`, and **`'shoulder'` reproduces the
previous profiles bit-for-bit** (verified: max |Δ| = 0 on all three curves),
so it is the default and no existing result moved.

`season_profile_factors.m` derives every factor and labels each one
`[SOURCED]`, `[GEOMETRY]` or `[ASSUMED]`, because they do not carry equal
weight:

| Quantity | Basis | winter / shoulder / summer |
|---|---|---|
| Seasons, representative days | **[SOURCED]** BDEW/VDEW standard-load-profile seasons (winter 1 Nov–20 Mar, transition 21 Mar–14 May & 15 Sep–31 Oct, summer 15 May–14 Sep) | 15 Jan / 15 Apr / 15 Jul |
| Electrical demand | **[SOURCED]** the official BDEW **H0 dynamisation polynomial** `f(t) = −3.92e−10·t⁴ + 3.20e−7·t³ − 7.02e−5·t² + 2.10e−3·t + 1.24`, normalised to the shoulder day | 1.2451 / 1.0000 / 0.7785 |
| Day length | **[GEOMETRY]** Magdeburg 52.13°N, Cooper's declination, `L = (2/15)·acos(−tan φ·tan δ)` | 7.99 / 13.64 / 16.06 h |
| PV peak | **[ASSUMED]** monthly yields (Jan 22, Apr 112, Jul 128 kWh/kWp) + the geometry above, peak derived from `E = P·(2/π)·L` | 0.3091 / 1.0000 / 0.8952 |
| Space heating | **[SOURCED]** degree-day method, VDI 3807/2067 (room 20 °C, heating limit 15 °C); **[ASSUMED]** monthly means 0.5 / 9.0 / 18.5 °C | 1.7727 / 1.0000 / 0.0000 |

PVGIS was unreachable from the build environment, so the monthly yields are
**declared as assumptions rather than dressed up as sourced**. They are
consistent with the one reachable published figure — German PV output
differs between peak-month June and weakest-month December by "a factor of
up to 10"; the assumed set gives 8.2. Note the counter-intuitive
consequence, which is correct and not a slip: **the summer PV *peak* is 10%
below April's while summer daily *energy* is 11% above it** — at 52°N the
extra summer yield is day length, not midday power. No summer cooling is
modelled (low German residential AC penetration, and the H0 curve — measured
German behaviour — already puts summer below the annual mean). EV
plugged-in hours and the tariff are deliberately **not** varied, with
reasons given in the file.

**Three claims turned out to be shoulder-season-specific.** All three had
been stated as general:

1. *"At today's delivered hydrogen price the fuel cell never starts."*
   False in winter — 43.5 kWh of fuel on the shoulder day, **1552.6 kWh in
   winter at the same price**. The mechanism is arithmetic, not economics:
   winter heat demand is 3261 kWh/day and the heat pump can deliver at most
   37.3 kW × COP 3.2 × 24 h = 2867 kWh, so ~394 kWh cannot come from it and
   the fuel cell's byproduct heat is the only other source. It is
   **must-run**. `multiscale_default_params.m` states the heat pump exists
   precisely to prevent that; the reasoning holds at the shoulder and fails
   in winter.
2. *"Case 4 saves 72.1%."* That is a shoulder figure: **21.0% / 72.1% /
   90.4%** across winter / shoulder / summer. No annual number is claimed —
   three days are not a year, and the three days are not equally common.
3. **The ablations change sign in winter.** Case 2 is −2.68% and Case 3 is
   −0.84%: the full proposed system is the *most expensive* of the three hub
   cases. Unmet energy is 0.00 kWh in every winter case, so the obvious
   "it didn't serve the load" explanation is false. The measured mechanism
   is **fuel substitution**: the closed loop burns 167 kWh more hydrogen
   (+$36.78) and saves $14.21 of grid cost. The rolling layers commit more
   fuel cell than the day-ahead plan in both seasons because each 15-minute
   solve sees one slot ahead; whether that pays depends on **heat-pump
   saturation** (24 of 24 hours in winter versus 9 of 24 at the shoulder).
   The closed loop is still cleaner (−25.8 kgCO₂/day), so this is a
   cost-versus-carbon trade a single-objective ablation scores as a loss.

**Does building thermal mass contribute in winter?** Yes — and it does not
take over, and both halves are reported. It goes from 1.24 to **55.73
kWh/day** (45×) and from 0.37% to 13.0% of the pipe network's throughput.
But the pipe still cycles **7.7× more** in the season most favourable to the
building and leads in all three seasons, so *"each mechanism dominates in a
different season"* is **not** supported and is not claimed. The statement
is: the displacement finding holds in every season; what changes is only
whether the displaced device is negligible or merely secondary. With the
pipe disabled the building cycles 164.96 kWh/day over its full SOC band —
displacement, not incapacity.

## Per-device PWL: the decision rule

PWL was originally applied to exactly one device — the fuel cell — which is
the **lowest-throughput** converter in the hub (43.5 kWh on a shoulder day
against the heat pump's 634 kWh of electricity and PV's 1922 kWh, and 0 kWh
in summer). This session added a sourced, load- and ambient-dependent COP
curve to the heat pump (`heatpump_curve.m`), embedded it with the same
segment / concentrator / fill-order structure the fuel cell uses, and then
**measured whether it earns its complexity** rather than assuming it does.

**The curve.** Manufacturer rating points for the Stiebel Eltron WPL 25 ACS
at W35 flow — A−7 2.98, A2 4.14, A7 4.82 — which are near-collinear in
ambient, giving `COP_rated(T) = 3.8926 + 0.1311·T` to within 0.01.
Extrapolation beyond the characterised −7…+7 °C range is **refused**: a
summer ambient of 18.5 °C would give COP 6.3, which the datasheet does not
support and which points the wrong way anyway (summer heat here is hot
water, needing a *higher* flow temperature and therefore a *lower* COP). The
part-load shape `f(u) = (1.25−0.25u)(1−e^(−u/0.08))` is **declared as an
assumption**, not sourced.

**Slope check, done numerically as required.** Segment slopes at n=5 are
`5.299 5.691 4.876 4.337 3.849` (shoulder) — segment 2 **exceeds** segment 1,
because the low-load cycling penalty makes the first slice the least
efficient. The slopes are *not* monotonically decreasing, so **fill-order
binaries are required**, exactly as for the fuel cell.

**The gate: not passed.** 60 paired draws, n-segment PWL against a
**1-segment chord of the same curve** (comparing against the legacy COP 3.2
would measure a *level* change, 3.2 → 4.81, and report it as a PWL benefit —
the same category error this project refuses for the 72.1% headline; that
comparison is +17.21% and is reported separately).

| | pooled | winter | shoulder | summer |
|---|---|---|---|---|
| Heat-pump PWL benefit | **−0.063%** [−0.352, +0.226] | +0.244% | +0.985% | **−1.419%** |
| verdict | spans zero | resolved | resolved | **reliable cost** |

Cost of the complexity: **96 extra binaries** per day-ahead solve and
**≈+16%** closed-loop solve time (+15.9% and +15.7% on two independent solo runs; the cost statistics reproduce exactly across them). Per the session's own gate, **Tasks 2 (PV
inverter) and 3 (battery) were not run.**

**The pooled null is two resolved effects cancelling**, and the mechanism is
measured, not reasoned:

| season | median load *u* | time in segment 1 | PWL error | chord error |
|---|---|---|---|---|
| winter | 0.97 | 0% | −0.14 kW | −2.66 kW |
| shoulder | 0.51 | 1% | −0.27 kW | −9.37 kW |
| summer | 0.12 | **70%** | **+1.46 kW** | −2.21 kW |

(+ = the model *over-promises*.) In summer the only heat demand is a flat
hot-water baseline, so the heat pump lives inside segment 1 — where a
**uniform** 5-segment fit averages the curve's steepest rise into one wide
chord of slope 5.30 against a true COP near 4.70. **The finer model is the
more optimistic one exactly where the device operates**, and optimism is
punished asymmetrically (a shortfall is covered at the import tariff, a
surplus is only worth the export price — the same mechanism the Optimism
column established for the fuel cell).

**Is the failure just breakpoint placement? No — and an earlier version of
this study said yes.** Curvature-placed breakpoints (same segment count, same
binaries, the placement option Month 2a already implemented) were reported as
**+0.700% [+0.394, +1.005]**, resolved. That was measured with a defective
cost correction whose error fell almost entirely on summer. **Corrected, it
gives −0.137% [−0.580, +0.307] — spanning zero — and is withdrawn.** In summer
it is *worse* than uniform placement (−2.211% vs −1.419%).

**What survives is the more interesting half.** Curvature placement is
genuinely the better *fit*: the summer error moves from +1.461 kW (optimistic)
to −0.695 kW (pessimistic). It is still the worse *cost*. **A fit closer to the
true curve does not automatically buy a cheaper dispatch** — so any argument
for PWL reasoning from approximation error alone is incomplete. (One bound: the
correction credits surplus heat at the rate it charges shortfall, so a
systematically pessimistic fit earns a systematic credit, and the chord is the
most pessimistic model here. Left as measured rather than re-tuned; the gate
spans zero under either convention.)

**The default remains `usePWL = false`.** No tested configuration resolves
positive, and enabling the curve would also apply the +17.21% *level* change
to every cost figure in Months 3 and 4. Keeping the legacy constant means
every pre-existing result reproduces exactly.

### The rule the data supports

`main_month4j_pwl_device_table.m` compares constant efficiency against PWL
per device, at **two hydrogen prices**, with realized cost corrected to the
true continuous curves on **both** the electrical and the thermal side.

| cell | throughput | curvature | thru × curv | dispatch | PWL benefit |
|---|---|---|---|---|---|
| fuel cell, H2 today | 52 kWh | 1.06 | 55 | **must-run** | **−0.594%** [−0.71, −0.48] resolved |
| heat pump, H2 target | 286 kWh | 0.38 | 109 | economic | +0.331% [−0.04, +0.70] not resolved |
| heat pump, H2 today | 433 kWh | 0.38 | 166 | economic | −0.234% [−0.48, +0.02] not resolved |
| fuel cell, H2 target | 1846 kWh | 1.06 | 1961 | economic | **+2.309%** [+1.68, +2.94] resolved |
| PV inverter | 1922 kWh | — | — | — | **NOT RUN** — gate not passed |

Throughput **alone** does not predict it — the heat pump moves 8.4× the fuel
cell's energy at today's price and never resolves.

**Throughput × curvature does *not* order the four cells either**, and the
rows above are sorted by it so the failure is visible: the heat pump's two
cells run the wrong way round each other, its product *falling* 166 → 109
while its benefit *rises* −0.234% → +0.331%. The honest reading is narrower.
**Only two of the four cells resolve**, both the fuel cell's: lowest product
gives a resolved negative, highest gives a resolved positive, with both
heat-pump cells unresolved in between. That is *consistent* with the product
mattering and it is two points — too thin to call an ordering law. The
non-monotonicity sits entirely inside the unresolved pair, so it does not
refute the hypothesis either. It is simply **not settled by this data**.

Two things it *does* settle. First, **throughput is not a property of a
device** — the heat pump moves *less* energy when hydrogen gets *cheaper*
(433 → 286 kWh/day), because the fuel cell then runs hard and its waste heat
covers demand the pump would have served. Two devices, one heat load. That
alone disqualifies throughput as a design-time screening rule. Second, **the
same device, same curve, same segment count and same binaries shows a
resolved positive or a resolved negative benefit depending only on the price
regime** — so "we applied PWL" is not by itself a statement about anything.

What that second point cannot do is separate throughput from dispatch
freedom: the fuel cell's two rows differ only in hydrogen price, which
changes throughput (36×) *and* flips the device from must-run to
economically dispatched. **Perfectly confounded, and no experiment here
separates them** — it would take a run that raises throughput while keeping
the device must-run.

**Four necessary conditions:** (1) throughput × curvature large — a *screen,
not a score*, per the ranking above; (2) the optimizer must actually *choose*
the operating point (confounded with (1) in this data, so stated as a
condition rather than a proven one); (3) the device must move across several
segments, not sit inside one; (4) the fit must err *pessimistically* where
the device operates. Conditions 3 and 4 are about **breakpoint placement, not
segment count** — segment count is the last thing to tune, not the first.

**What this does not settle:** it measures *cost*. The **feasibility**
argument for the fill-order binaries is independent and stronger — without
them the LP relaxation reports dispatches the machines cannot physically
produce. That was already verified for the fuel cell; this session verified
it on the heat pump too, by solving the same day-ahead with the ordering
indicators relaxed (`p.diag.relaxOrder`, a diagnostic flag that defaults off):

| season | out-of-order segment pairs, MILP | LP | worst fill of segment 1 |
|---|---|---|---|
| winter | 0 | **0** | none |
| shoulder | 0 | **3** | 2.9% |
| summer | 0 | **6** | 26.6% |

The relaxation loads segment 2 while segment 1 is 2.9% full and pockets the
difference as heat the machine cannot produce. Note the seasonal pattern,
which is measured rather than assumed: it does **not** happen in winter,
because the pump runs near its rating there and no segment has spare room to
leave empty. **The defect is a part-load defect** — the same condition that
makes the *cost* case fail. A model that reports impossible dispatches is
wrong irrespective of what the error is worth on a given day, so the heat
pump needs those binaries the moment its curve is modelled at all.

## Assessment covers all four thesis criteria

The brief requires assessment on **operational cost, carbon reduction, system
resilience and efficiency**. All four are now reported. `hub_efficiency.m`
computes whole-hub energy efficiency from completed dispatches and it appears
in the Month 4a case table and the Month 3 seasonal table.

**Two ratios are reported because neither alone is honest.** Purchased-energy
efficiency can exceed 100% — a heat pump at COP 3.2 delivers heat it never
bought, lifted from ambient air. First-law efficiency charges the hub for that
ambient heat and is bounded by 100%.

| Case | η purchased (%) | η first-law (%) |
|---|---|---|
| 1: Conventional | 95.7 | **95.7** |
| 4: Full proposed | **121.1** | 92.3 |

**The conventional case is more efficient on first law, and that is reported
rather than buried.** The hub interposes a PV inverter, a fuel cell, and four
storage devices — the largest single loss being 178 kWh/day of storage
self-discharge, mostly building thermal mass leaking at 15%/hour. **The hub buys
its cost and carbon reductions with thermodynamic efficiency.**

Seasonally, efficiency peaks at the **shoulder** (121.1%), not winter (119.0%),
even though winter is when the fuel cell's byproduct heat is fully used. The
fuel cell recovers ~75% of its hydrogen across both outputs; the heat pump
returns ~320% against purchased electricity. Any hour the fuel cell displaces
the heat pump lowers the average.

## Segment count: n = 10, and what it cost

The default PWL segment count is **10**, selected where the realized-cost gap
converges (−0.02% at n = 10, against −0.12% at n = 5 and −4.36% at n = 1).
Beyond n ≈ 36, extra segments cut curve-fit error without moving any reported
dispatch number while solve time grows superlinearly.

**Moving from 5 to 10 cost the project its strongest single claim, and that is
reported rather than absorbed.** "PWL beats constant efficiency" went from
**resolved** (+1.42%, 44/60 draws, sign test *p* = 0.00039) to
**outlier-driven** (+0.87%, 32/60, *p* = 0.7). Per season, shoulder fell from a
resolved +0.93% to a null and summer's reliable cost grew from −0.20% to
−0.94%; winter was untouched. See `VALIDATION.md` for the mechanism.

**Solve time — quote the range, not the sweep's single figure.** The sweep's
`Solve(s)` column implies +0.089 s per day-ahead solve. Measured across price
regimes and seasons the real cost is **1.4× where the fuel cell is idle, up to
13.8× (0.269 → 3.713 s) where it runs at part load** — roughly 40× the sweep's
figure, because the sweep measures one configuration that is not the hard case.
Binaries per device per 24-hour solve: 96 → 216.

**Memory is the harder limit.** Three concurrent scripts ran fine at n = 5; at
n = 10 the same layout OOM-kills at ~8.6 GB RSS. The growth is in the intraday
stochastic MILP, not the day-ahead solve, and the runs are now serialised.

## Confidence intervals on the headline claims

`main_month4e_monte_carlo.m`. Three numbers carried the modelling argument
and every one was a single-draw point estimate.

**Protocol:** 60 draws = **20 seeds × 3 seasons**, varying both forecast
noise and season. Every comparison runs **both configurations on the same
draw** and differences them per draw — the scenario is then common to both
members of the pair and cancels exactly, which is the only test with any
power here (an unpaired comparison would be swamped by the ~16× spread
between winter and summer costs). Differences are expressed as a percentage
of their own baseline, because absolute dollars are not comparable across
seasons. `paired_stats.m` reports **three tests** — a 95% t interval, a 95%
bootstrap percentile interval, and an exact sign test — with no toolbox
dependency (t critical values tabulated, bootstrap from `rand`, sign test
summed in log space via `gammaln`).

| Claim | quoted | mean | median | 95% CI | sign+ | verdict |
|---|---|---|---|---|---|---|
| PWL vs constant efficiency | 0.26% | **+1.42%** | +0.99% | [+1.00, +1.84] | 44/60 | **distinguishable** (p = 4e−4) |
| Rolling layers on/off | 2.85% | **+3.06%** | +1.39% | [+1.20, +4.93] | 33/60 | **mean nonzero but outlier-driven** (sign test p = 0.52) |
| Robust reserve on/off | 2.62% | **+1.63%** | +2.08% | [+1.17, +2.10] | 39/60 | **distinguishable** (p = 0.027) |

**The rolling-layers result is the one to read carefully.** Its interval on
the *mean* excludes zero, but the claimed direction held in only 33 of 60
draws and the sign test does not reject — the mean is carried by a minority
of large positive draws while the typical draw shows little. Quoting the
mean alone would turn *"usually nothing, occasionally large"* into
*"reliably positive"*. `paired_stats` has a verdict category for exactly
this, and the script prints it rather than averaging the tests together.

**All three claims change sign by season, and two of the flips are
themselves resolved:**

| Claim | winter | shoulder | summer |
|---|---|---|---|
| PWL vs constant | +3.52% | +0.93% | **−0.20% (reliable cost)** |
| Rolling layers | **−3.77% (reliable cost)** | +1.38% | +11.58% |
| Robust reserve | **−0.60% (reliable cost)** | +2.50% | +3.01% |

A 0/20 sign count is strong evidence *against* a claim, not weak evidence
for it; `paired_stats` labels that case `CONSISTENTLY OPPOSITE` rather than
letting it fall into the outlier-driven bucket.

These intervals cover **scenario** uncertainty only — efficiency curves,
prices, emission factors, network data and hub size are fixed in every draw.
The three seasons are weighted equally, which is not how a year is
distributed, so the pooled mean is not an annual mean.

## What the optimization is worth, as opposed to the equipment

`main_month4h_rule_based_baseline.m`. The 72.1% headline compares against a
system that owns no PV, battery, EV or heat pump, so most of it is the value
of hardware. The demanding comparator is **the same hub under simple
heuristic control** (`rule_based_dispatch.m`): charge storage below the
median import price, discharge above it, run the fuel cell only when its
marginal cost beats the grid or the heat balance forces it, no look-ahead.
Same ratings, same SOC bands, same storage state equation, same true
fuel-cell curves, same realized profiles.

Over **30 paired draws** the heuristic costs **+31.5% more on a
cost-weighted basis** and the optimizer won **30 of 30** draws — per season
**+21.5% / +34.5% / +189.7%**. This is the strongest modelling claim the
project can make, because identical hardware on identical scenarios differs
only in scheduling.

Two caveats travel with it. The summer figure is inflated by one specific
weakness of the chosen rule: midday hours sit *exactly at* the median
tariff, so the rule never charges from surplus PV — measured, the heuristic
exports 1329 kWh/day in summer against the optimizer's 313 and re-imports it
overnight. A one-line improvement would close much of that, so the winter
and shoulder figures are the conservative ones. And the heuristic is not
charged for peak demand, network impact, or the reserve it fails to hold.
(An earlier version of the rule let thermal-storage charging start the fuel
cell, which inflated the optimizer's margin from 31.5% to well over 100%;
that was a defect in the baseline, not a result, and it was fixed.)

## Siting: bus 18 versus bus 25

`main_month4f_siting_comparison.m` runs the same single hub at each bus, one
at a time. **Siting determines whether a hub can support voltage**, and the
two halves of that pull against each other almost exactly:

| | bus 18 | bus 25 |
|---|---|---|
| Host-bus load | 90 kW | 420 kW |
| Penetration (feeder / host) | 2.79% / 115.3% | 13.03% / 115.3% |
| dV/dQ at host | −5.70e−05 pu/kvar | −1.26e−05 pu/kvar |
| Inverter reactive limit | 62.2 kvar | 290.4 kvar |
| **Reactive support achieved** | **0.0018 pu** | **0.0003 pu** |
| Loss reduction vs no hub | 251 kWh/day | 353 kWh/day |
| Closed-loop compliance | 9/9 | 0/9 (worst shortfall 2.89e−06 pu) |

Bus 18 is **4.5× more responsive per kvar**; bus 25 hosts **4.7× more
inverter**, because the do-no-harm floor caps hub import at the nominal load
of the bus it replaces. The product — full-output reactive authority
`Q_max × |dV/dQ|` — is **0.00355 pu at bus 18 and 0.00365 pu at bus 25, a
ratio of 0.97**. On a radial feeder the two properties are inversely related
*by construction*: weak buses are weak precisely because they sit at the end
of long thin laterals serving small loads. Neither siting is simply better —
bus 18 is the stress test, bus 25 is the only one where a feeder-wide
question can be asked at all.

The compliance flip is reported with its magnitude and is **not** bus 25
failing: the worst shortfall is 2.89e−06 pu against a LinDistFlow model
whose own base-case error is 2208× larger. At bus 18 the hub sits *on* the
binding bus so the linearization bias cancels; at bus 25 the binding bus is
still 18, on a different lateral.

## Voltage in space and time

`main_month4g_voltage_heatmap.m` plots the full 33-bus × 288-step field
(absolute, with the 0.95 pu contour) and the difference against the no-hub
base case (diverging scale, zero contour), and renders both as text for
headless runs. `network_verify` now returns `Vfield` and `Vbase_field`.

The hub improves **93.7%** of the field and degrades 3.3% — but the worst
degradation anywhere is **1.25e−06 pu**, four orders of magnitude below the
0.0869 pu the feeder already sits below nominal, so "degrades 3% of the
field" is true and nearly meaningless. The spatial pattern is **not**
distance from the hub: mean lift is +0.00444 pu on the hub's own lateral,
+0.00143 pu at buses sharing branches 1-2 and 2-3, +0.00021 pu at buses
19–22 which share only branch 1-2, and 0 at the slack. **Bus 18, the
furthest bus from the hub, gains 6.9× more than bus 19, which is far nearer
in hop count** — what sets the lift is shared series impedance, exactly as
the LinDistFlow sensitivity `a_j` predicts, here reproduced by the exact
nonlinear solver rather than asserted by the linear one.

**The answer the re-sizing produced: both flat findings survived.** Across
a 4× reserve sweep and a 6× uncertainty sweep the feeder minimum spans
0.0002 pu and the *host bus itself* spans 0.0007 pu; across a 36× change in
PWL fidelity the feeder minimum spans 0.0004 pu. Reserve margin and PWL
segment count are cost instruments, not network instruments — and that is
now an established result rather than an artifact of a hub too small to
test it.

**The code is organized into four folders, one per roadmap month**, each
with its own runnable script(s). Nothing else at the top level.

```
matlab/
  month1_component_graph_models/        Month 1: component models + graph theory
  month2_coupling_matrix_pwl_ieee33/     Month 2: coupling matrix automation + PWL + IEEE 33-bus
  month3_multiscale_optimization/        Month 3: day-ahead / intraday / real-time dispatch
  month4_case_studies_sensitivity/       Month 4: case studies + sensitivity analysis
```

Tested with Octave 8.4 (headless via `xvfb-run`); Month 3–4 need core
Octave's built-in `glpk` (LP/MILP solver) — no other toolboxes required.
Months 3–4 are numerically self-contained (their own LP dispatch does not
reuse Month 1–2's graph engine); Month 2 depends on Month 1's component/
graph engine via `addpath('../month1_component_graph_models')`.

## How to run each month

```matlab
cd matlab/month1_component_graph_models
main_month1_components_and_graph_theory

cd ../month2_coupling_matrix_pwl_ieee33
main_month2a_arbitrary_configuration_and_pwl
main_month2b_ieee33_grid_integration

cd ../month3_multiscale_optimization
main_month3_multiscale_dispatch

cd ../month4_case_studies_sensitivity
main_month4a_case_studies
main_month4b_sensitivity_analysis
main_month4c_pwl_segment_sweep
main_month4d_lindistflow_cooptimization
main_month4e_monte_carlo            % confidence intervals, ~10 min
main_month4f_siting_comparison      % bus 18 vs bus 25
main_month4g_voltage_heatmap        % 33 buses x 288 steps
main_month4h_rule_based_baseline    % optimization vs heuristic control
main_month4i_heatpump_pwl_gate      % does heat-pump PWL pay? ~15 min
main_month4j_pwl_device_table       % per-device PWL table, ~35 min
```

Each script is self-contained (`clear; clc;` + whatever `addpath` it
needs) and prints/plots everything described below.

---

## Month 1 — Component models + graph theory

`month1_component_graph_models/`

1. **Individual component models** (PV, Fuel Cell, Battery, EV,
   Electrolyzer), built with the incidence-and-coupling-matrix approach.
   All five live in **one dispatcher file**, `components/hub_component.m`
   (`hub_component('pv', name, eta)`, `hub_component('battery', name,
   v_ch)`, etc.) — each case is a short, self-contained local graph, and
   the dispatcher pattern replaces what used to be five near-identical
   files with one place to see and compare them.
2. **Graph theory hub assembly** (`energy_hub_assemble.m`): components
   are wired onto shared carrier buses (electricity, heat) into one
   global graph, capturing **bidirectional flow** (storage charge/
   discharge as two independent edges, not a signed variable) and
   **MIMO conversion** (the fuel cell's single hydrogen input drives an
   electrical *and* a thermal output at once).

Every component is a small directed graph: local nodes = its
energy-carrier ports, local edges = its conversion/storage branches
(`eh_edge.m`). One rule covers every case: a `'dependent'` edge's value
= `eta_or_PWL(inflow(tail node))`, where `inflow` is read directly off
the node-edge **incidence matrix** (`energy_hub_incidence_matrix.m`).
`energy_hub_assemble.m` merges an *arbitrary* list of components
automatically: any endpoint name ending in `"_Bus"` is a shared carrier
bus across every component that references it; everything else is
namespaced to its owning instance.

**PV model boundary note**: the PV component starts at the array's **DC
electrical output**, not at the solar resource. Its node is `PV_DC_in`
and `eta_PV = 0.97` is the **inverter / DC-DC converter** efficiency
applied to already-generated DC power. Module-level conversion of
irradiance to DC (~15–22% for real silicon modules) is *upstream* of this
model boundary and is embedded in the driving profile —
`forecast_profiles.m`'s `solar` series is the array's available DC output
in kW (a ~50 kW-peak array), not irradiance. Read as a
sunlight-to-electricity efficiency, 0.97 would be physically impossible;
as a power-electronics efficiency it is ordinary. The value is correct —
only its labelling was previously ambiguous.

**Sign convention note**: `energy_hub_incidence_matrix.m` uses the
standard graph-theory convention (+1 at an edge's tail node, -1 at its
head node). The energy-hub literature's own "coupling matrix"
convention (`energy_hub_coupling_matrix.m`, `P_out = C*P_in`) instead
signs by port role (+1 input port, -1 output port), a different
bookkeeping axis that doesn't in general agree edge-by-edge with the
tail/head signs here. Both are correct for what each is used for; this
is a documented difference, not a bug, and no behavior depends on it.

Run `main_month1_components_and_graph_theory.m` to see: each
component's own standalone local incidence matrix
(`energy_hub_display_component.m`), the assembled global incidence
matrix and coupling matrix `C` (`L = C*P`, `energy_hub_coupling_matrix.m`),
a numeric MIMO check (one column of `C` has two nonzero rows), two
operating points with storage running in opposite directions with exact
energy-balance validation, and a graph plot (`energy_hub_plot_graph.m`).

## Month 2 — Coupling matrix automation, PWL, and IEEE 33-bus integration

`month2_coupling_matrix_pwl_ieee33/` (depends on Month 1)

3. **Standardized coupling matrix, automatic for arbitrary
   configurations**: shared buses are found by naming convention (no
   per-hub wiring code), and `energy_hub_print_equations.m` prints the
   literal energy-flow equations generated from any edge list — proven
   by building two structurally different hubs from the same component
   library with no solver changes (`main_month2a...`, "Hub configuration
   1" vs. "Hub configuration 2").
4. **Piecewise Linearization (PWL) of variable efficiencies**
   (`pwl_utils.m` — one dispatcher for fit/eval/local-affine, replacing
   three files): realistic nonlinear part-load efficiency curves (Fuel
   Cell, PV, Electrolyzer) are PWL-fitted and shown to track the true
   curve one to two orders of magnitude more closely than a single
   constant efficiency — quantified in a printed error table, not just
   claimed. `pwl_utils('fit', ...)` takes an optional breakpoint-
   placement argument: `'uniform'` (default, used everywhere in this
   project) spaces breakpoints evenly in load fraction; `'curvature'`
   concentrates them by equal cumulative |second derivative| instead.
   Curvature placement is a max-error-oriented heuristic — it reduces
   MaxErr for 3 of the 4 example curves (all but the electrolyzer, whose
   curve is close to a plain quadratic with only mildly-varying
   curvature) but does **not** reliably improve RMSE, which only
   improves for the fuel-cell electrical curve — an honest, quantified
   trade-off (`main_month2a...`'s "Breakpoint placement" table), not a
   universally-better alternative default. Since a single global `C`
   cannot represent a piecewise-linear
   hub, `energy_hub_coupling_matrix.m` explicitly refuses PWL edges;
   `energy_hub_evaluate_hub.m` (exact evaluation at one operating point)
   and `energy_hub_linearize.m` (local affine map, valid near one
   operating point, degrading once the true point crosses into a
   different PWL segment) take over instead.
5. **IEEE 33-bus distribution system integration**
   (`ieee33_data.m` + `distflow_bfs.m`, run via `main_month2b...`):
   the standard Baran & Wu 33-bus radial feeder, solved with a
   backward-forward-sweep power flow — **validated** against the
   widely-published benchmark for this exact system (this
   implementation reproduces 202.68 kW total losses and 0.9131 pu
   minimum voltage at bus 18, matching literature essentially exactly).
   Energy hubs are sited as active nodes (net P injections) at three
   buses: two favorable scenarios and one **deliberately adverse** one
   (an EV depot charging at evening peak draws more than the original
   load), so the grid-impact comparison is honest, not one-sided. The
   adverse bus is also re-run in isolation to show its true local effect
   is a voltage drop that gets offset, once all three hubs run together,
   by upstream trunk-voltage gains from the other two — a genuine
   emergent finding from shared-trunk network coupling, not scripted.

## Month 3 — Multi-time-space scale optimization

`month3_multiscale_optimization/` (self-contained)

Three optimization levels (Octave's built-in `glpk`), coordinated so
each level starts from where the previous one actually left the system:

- **Day-ahead** (`dayahead_dispatch.m`, hourly, 24-step horizon, solved
  once): minimizes 24h energy cost subject to electrical/heat balance
  and the generalized-storage state equation for all four devices. The
  fuel cell is a genuine **PWL/MILP embedding**, not a standalone Month-2
  demo: its electrical and thermal part-load efficiency curves are both
  non-concave/S-shaped, so a plain LP relaxation would cherry-pick a
  higher-slope segment while leaving a lower one empty (verified
  numerically — see `VALIDATION.md`). Fill-order binary variables
  (`u_1..u_(s-1)` per hour) force segments to fill in order, making
  day-ahead a genuine MILP; `p.PWL.nSegments` (default 5,
  `multiscale_default_params.m`) controls fidelity, and `nSegments=1`
  provably collapses back to the old constant-efficiency LP (bit-exact
  match, verified). **Robustness** is a reserve-margin proxy — every
  hour must keep enough *unused* storage charge/discharge headroom to
  cover a fraction of that hour's load/solar forecast — the standard
  simplification when a full robust-MILP toolchain isn't available. A
  genuine robust-MILP (e.g. via YALMIP's `robustify` + a solver like
  Gurobi that handles the resulting semi-infinite/robust-counterpart
  constraints) would instead optimize against an explicit uncertainty
  set (box/polyhedral/budget) for solar and load, guaranteeing
  feasibility for *every* realization in that set rather than just
  reserving headroom sized to a fraction of the forecast — a real
  worst-case guarantee instead of a proxy for one. That would need a
  solver this codebase deliberately doesn't depend on (Octave's `glpk`
  only), so the reserve-margin proxy is a documented, honest
  substitute, not a claim of true robustness.
- **Intraday** (`intraday_dispatch.m`, 15-min, rolling horizon): a
  genuine **two-stage stochastic MILP** re-solved every slot — stage 1 is
  the shared "here-and-now" decision, stage 2 is a 3-scenario (low/mid/
  high solar) recourse decision for the *next* slot, branching from the
  same stage-1 storage state (true non-anticipativity). The same
  fuel-cell PWL/MILP segment+binary structure as day-ahead is applied
  independently in every block (stage 1 and each scenario), since each
  makes its own fuel cell decision. Only stage 1 is ever committed —
  classic receding-horizon dispatch. A soft penalty keeps its storage
  trajectory close to the (15-min-interpolated) day-ahead plan without
  forcing an exact match.
- **Real-time** (`realtime_balance.m`, 5-min, fast): re-dispatches only
  the **electrical** carrier, only the fastest resources (grid + battery)
  — matching real grid-operator practice. The fuel cell, heat pump, EV
  charging, and both thermal storages stay at intraday's committed
  setpoint; heat-side mismatch is physically absorbed by the buildings'/
  pipes' own thermal inertia, which doesn't need sub-minute balancing
  the way electricity does. The fuel cell's committed fuel is already a
  fixed number here (not re-optimized), so it's converted to electricity
  via an exact PWL curve lookup (`pwl_utils('eval', ...)`), not the
  segment/binary machinery day-ahead/intraday need for the optimization
  itself.

### Three hydrogen-price scenarios (production gate vs. delivered)

Hydrogen cost is the single parameter that decides whether the fuel cell
runs at all, so it is treated as a deliberate scenario axis
(`p.scenarios` in `multiscale_default_params.m`) rather than one fixed
number. Every point is anchored to a published figure, converted at
hydrogen's lower heating value of 120 MJ/kg = 33.3 kWh/kg.

**The basis distinction matters.** DOE's headline hydrogen targets are
*production* targets: the Bipartisan Infrastructure Law's Clean Hydrogen
Electrolysis Program funds "$2/kg clean hydrogen **from electrolysis** by
2026", and the Hydrogen Shot's $1/kg by 2031 is likewise the cost of
*producing* hydrogen. Neither includes compression, storage, transport or
dispensing. DOE tracks delivered cost separately and with much larger
numbers — its **dispensed** target for heavy-duty vehicles is $7/kg by
2028, several times the production target for the same era. A fuel cell
in a building pays a *delivered* price, so comparing today's delivered
cost against a future production-gate cost would silently switch basis
and overstate the improvement. Hence three scenarios, not two:

| Scenario | $/kWh fuel | $/kg | Basis | Role |
|---|---|---|---|---|
| `H2_today` (default) | 0.22 | 7.33 | delivered | Clean hydrogen delivered today. DOE puts renewable-sourced hydrogen near $5/kg at the production gate; delivery puts the delivered cost above that. |
| `H2_doeTargetDelivered` | 0.0879 | 2.93 | delivered | **Like-for-like headline.** DOE's $2/kg 2026 production target carried to the meter with this project's own implied delivery markup (7.33 ÷ 5.00 = 1.465×, derived in code, not hardcoded). |
| `H2_doeTargetGate` | 0.06 | 2.00 | production | **Optimistic bound.** The same target at the gate, unmodified — i.e. a fuel cell that pays nothing for delivery. |

`main_month3_multiscale_dispatch.m` runs the full stack at **all three**,
changing only `p.price_H2`, and prints them side by side so the result is
a bracketed range rather than a point estimate. At today's delivered cost
the fuel cell is uneconomic against grid import and the optimizer
correctly never starts it (`FC fuel = 0` — the right economic answer, not
a broken component). At the like-for-like delivered target it runs 2
hours a day (138 kWh fuel), cutting day-ahead grid import 22% and
emissions 10%; at the optimistic gate price, 5 hours (339 kWh), cutting
import 61% and emissions 28%.

In **both** target columns it runs at part load — 40–52% of rated fuel
input delivered, 37–55% at the gate — never at the rated point a single
nameplate efficiency is calibrated to. That is the regime where a
constant efficiency is least accurate and where the PWL/MILP formulation
contributes. The PWL model is inert at today's prices because the
component it describes is inert, and becomes load-bearing exactly when
hydrogen gets cheap enough to dispatch.

Month 4's segment sweep runs at `H2_doeTargetGate` for a stated reason:
it is a *convergence* study, and the gate price maximises fuel-cell
throughput, giving the clearest signal. That is legitimate for measuring
convergence but would not be for a cost headline — which is why Case 5
reports both target prices.

**Generalized storage** (`storage_soc_update.m`): one state equation,
`SOC(t) = SOC(t-1) + [eta_ch*Pch - Pdis/eta_dis]*dt/Emax -
selfLoss*SOC(t-1)*dt`, used for all four devices via
`multiscale_default_params.m`'s physical reinterpretation:
- **Battery / EV fleet**: the literal case (EV masked by a plugged-in-
  hours availability schedule).
- **Building thermal mass**: SOC 0↔1 maps to indoor temperature across
  the comfort band; a short thermal time constant (~7h) means it mostly
  can't hold charge from midday to evening peak — visibly much shallower
  cycling than the other three devices in the plots, a physically
  realistic distinction, not an underused component.
- **District-heating pipe storage**: same equations, larger capacity,
  slower, better insulated — it *can* hold charge across the day, and
  the optimizer uses it for exactly that.

`main_month3_multiscale_dispatch.m` runs one simulated day end-to-end (1
day-ahead solve + 96 intraday solves + 288 real-time solves, via the
reusable `simulate_multiscale_day.m`) and plots the grid interchange at
all three resolutions overlaid, all four devices' SOC trajectories, and
the real-time correction magnitude over the day. Solve time is
machine-dependent; see `VALIDATION.md` for the before/after measurement
of embedding the fuel cell's PWL/MILP structure into day-ahead and
intraday (Tasks 1-2 of that log).

## Month 4 — Case studies and sensitivity analysis

`month4_case_studies_sensitivity/` (depends on Month 3)

`simulate_multiscale_day.m` (in Month 3) takes an `opts` struct
(`useIntraday` switches full closed-loop vs. **open-loop** — day-ahead
setpoints held fixed and executed against actual data with no
adaptation; `reserveScale` multiplies the reserve-margin fractions, 0
disabling robustness; `usePWL`, default `true`, switches the fuel
cell's PLANNING model between the true PWL curve and a single constant
efficiency — the physical/realized side always uses the true curve
regardless, since the fuel cell doesn't know what the planner assumed)
so it can be re-run for comparison and sweeps without duplicating the
385-solve orchestration loop.

### Case studies (`main_month4a_case_studies.m`)

Four cases, each removing exactly one modeling contribution from the
next so the improvement it buys can be attributed, not just observed in
aggregate:

| Case | What it has | Isolates |
|---|---|---|
| 1: Conventional | Grid electricity + gas boiler, no PV/FC/heat pump/storage at all | The pre-energy-hub reference point |
| 2: Day-ahead only | Energy hub, day-ahead LP, **open loop** (no intraday/real-time) | Value of the rolling multi-timescale layers |
| 3: No robust reserve | Full closed loop, `reserveScale=0` | Value of the robust-reserve proxy |
| 4: Full proposed system | Everything as built | The complete proposed approach |
| 5: Constant efficiency | Case-4-style closed loop, but day-ahead/intraday PLAN with a constant fuel-cell efficiency instead of PWL (`usePWL=false`); the physical realization still uses the true curve | The value of PWL itself, not a coordination/robustness layer — reported separately, not part of the 1→4 progression |

Case 5 runs at **both** DOE target prices (see [Three hydrogen-price
scenarios](#three-hydrogen-price-scenarios-production-gate-vs-delivered)
above), because those are the scenarios in which the fuel cell is
economic at all; at the `H2_today` default it never dispatches, so the
comparison would weigh 0 fuel against 0 fuel. Cases 1-4 keep the default.

**The PWL cost benefit is utilization-dependent, and is reported as a
range rather than a single number.** Comparing realized cost (both
variants evaluated against the one true curve, isolating the modeling
choice from forecast noise), constant efficiency costs:

| Hydrogen price | FC fuel dispatched | Constant efficiency vs. PWL |
|---|---|---|
| $2.93/kg delivered (like-for-like) | 138 kWh / 2 h | **+0.20%** |
| $2.00/kg gate (optimistic bound) | 339 kWh / 5 h | **+1.47%** |

The mechanism is straightforward: a part-load model can only matter in
proportion to how much energy actually flows through the nonlinear
device, and 2.5× more fuel flows at the gate price. Quoting +1.47% alone
would be quietly conditioned on the more optimistic cost basis, so both
are given — on the like-for-like basis the cost benefit is real but
modest. (Same direction as Huang et al.'s reported 13.7% for a
constant-efficiency baseline, though different system/curves/price
levels — not a claim of matching their number.)

**The argument that does not depend on cost is the stronger one.** The
PWL segments and fill-order binaries exist to keep the dispatch
*physically possible*, not to save money. Without the ordering binaries
the LP relaxation fills segment 2 while segment 1 is only fractionally
full (verified counterfactual: `PH2seg(2) > 0` at `PH2seg(1) = 4.576` of
30), reporting more electricity per unit hydrogen than the device can
produce. That defect exists at *every* price, including ones where the
cost difference rounds to zero. See `main_month4c_pwl_segment_sweep.m`
(below) for how the gap and the underlying curve-fit error behave as
`p.PWL.nSegments` varies.

Reliability (`reliability_check.m`) is checked against ONE feeder
capacity shared by cases 2-4. **How that threshold is set is a
methodological choice, so it is an explicit switch** (`feeder_capacity.m`,
`p.reliability.capBasis`):

- `'design'` (**default**) — sized the way a real connection is sized,
  from connected load and nameplate ratings only: `diversityFactor ×
  (peak elec demand + EV charger + battery charger + heat pump)` =
  0.85 × 123.0 = **104.55 kW**. Every term is exogenous; no dispatch
  strategy enters it.
- `'case4'` — the earlier basis (Case 4's own day-ahead peak, 104.19 kW),
  retained only for comparison. It is self-favourable: it measures the
  proposed system against a line the proposed system draws.

The threshold feeds `reliability_check` only, *after* every case is
solved — it never enters the dispatch, so it cannot move cost, CO2 or
peak, only `unmetE`/`violHrs`. Both bases are printed side by side.

**Case 4's reliability advantage does survive the independent
threshold** (0.00 violation hours vs 0.17 and 0.42) — but the script
reports how narrow that is rather than leaving it to be discovered. The
three realized peaks lie within 1.75 kW, so Case 4 is the only clean case
for caps in **[103.76, 105.07) kW** — a 1.31 kW window, ~1.3% of the
peak. Tighter and all three violate; looser and none do. What *is* robust
is the **ordering of unmet energy**: Case 4 lowest and Case 3 highest at
every swept threshold where anything violates at all. That ranking, not
the zero, is the defensible reliability claim.

Headline result: **72% cost reduction, 60% CO2 reduction** (Case 4 vs.
Case 1) — but see the caveat below on what that measures. Two claims
deliberately NOT made:

- **Peak grid import is *higher* in Case 4 than Case 1**, reported rather
  than glossed over: Case 4 serves strictly more (EV charging, heat-pump
  electrification of what was gas heat) and its cost-minimizing dispatch
  deliberately imports more during cheap hours to pre-charge storage.
  Cost/emissions optimality and peak-shaving are different objectives;
  peak-shaving needs its own objective term (e.g. a demand charge).
- **The 72%/60% figures measure the equipment, not the modelling.**
  Case 1 has no PV at all; Case 4 has ~1922 kWh/day of free solar. Most of
  that gap is the value of *owning* PV, a battery, an EV fleet and a heat
  pump — any competently dispatched system with the same hardware would
  capture most of it. The figures should never be quoted without stating
  what they compare. The numbers that isolate *this thesis's* modelling
  contributions are the ablations, and they are appropriately smaller:
  **+2.9%** for the rolling intraday/real-time layers (Case 2 vs 4),
  **+2.6%** for the robust reserve margin (Case 3 vs 4), and
  **0.26–1.47%** for PWL vs constant efficiency (Case 5,
  utilization-dependent). Those are the defensible modelling claims.

### Network consequences on IEEE 33

Every case is replayed through the exact power flow. Two findings the
cost table alone would have missed, both reported rather than smoothed:

- **The cheapest dispatch is not the best one for the network.** Case 4
  is cheapest ($229.63) *and* has the lowest feeder losses (4515.4
  kWh/day), but the best **minimum voltage** belongs to Case 1, the
  conventional no-hub baseline (0.9140 pu vs Case 4's 0.9128). Case 4's
  cost-minimising schedule concentrates EV and battery charging into
  cheap hours, and nothing in its objective knows bus 18 is the
  electrically weakest point on the feeder. Better on losses, worse at
  the feeder's weakest moment — which is exactly the trade-off
  benchmarking on IEEE 33 rather than on a scalar import cap exists to
  expose. Note that the hub now sits at bus 25 while the worst bus is
  still 18: at 13% of feeder load it degrades a bus on a *different
  lateral*, reached only through shared trunk impedance. The earlier
  configuration could not show that at all, because host bus and worst
  bus were the same node.
- **Modelling error does not propagate into grid error here.** PWL vs
  constant efficiency differ by 0.0001 pu in minimum voltage and 0.4
  kWh/day in losses — practically indistinguishable — while differing by
  0.26–1.47% in cost. On this profile PWL fidelity is a *cost* accuracy
  question, not a grid accuracy one. Unlike the earlier version of this
  claim, the comparison now runs at a hub size where it could have come
  out otherwise.

One caveat that must travel with any voltage number from this study:
**21 of 33 IEEE 33 buses already sit below 0.95 pu in the published base
case**, all day, with no hub present. The "hours below 0.95 pu" column
therefore reads 24.00 for every case *including the no-hub base*, and
measures the benchmark feeder rather than anything this thesis does. Read
minimum voltage and the loss delta instead.

### Sensitivity analysis (`main_month4b_sensitivity_analysis.m`)

Two headline sweeps, each averaged over 3 random-scenario seeds, plus a
small single-seed 2D grid for visualization:

1. **Reserve-margin sweep** (`reserveScale` in {0, 0.5, 1, 1.5, 2}):
   reliability improves monotonically to zero violations. The day-ahead
   **planned** cost rises monotonically with reserve, as expected — but
   the **actual realized** cost does not show that same rise: avoiding
   real-time corrections/violations appears to offset most or all of the
   day-ahead premium. Two genuinely different trends, reported
   separately rather than collapsed into one "cost of robustness" figure.
2. **Uncertainty sweep** (forecast-noise scale in {0.5, 1, 1.5, 2, 3},
   with vs. without reserve): unmet energy grows monotonically with
   uncertainty in both cases, while violation *hours* roughly plateaus —
   once the same few intervals are already over capacity, more
   uncertainty mostly deepens those shortfalls rather than creating many
   new ones. The reserve margin keeps unmet energy far below the
   no-reserve case at low-to-moderate uncertainty, but the gap narrows
   at 3x — a margin calibrated for one range degrades gracefully, not
   perfectly, beyond it.
3. A 4x4 reserve x uncertainty grid (violation hours, **feeder-minimum
   voltage and host-bus voltage**) visualizes the interaction as a
   heatmap. Host-bus voltage is tracked separately because the feeder
   minimum (bus 18) is not the hub's bus (25) — reporting only the
   minimum would test the sweeps against a node the hub barely touches
   and make "insensitive" true by construction.

**All three sweeps are now verified against IEEE 33**, and the answer is
a clean negative result: **forecast uncertainty and reserve margin move
cost and unmet energy, not voltage.** Across every scenario in all three
sweeps the feeder minimum spans just **0.0002 pu** and the hub's own host
bus spans **0.0007 pu** — negligible next to the 0.0869 pu the feeder is
already below nominal in its own base case. This was re-run after the hub
was re-sited and scaled 4.7×, and the answer did not change: at 2.79%
feeder penetration the result was guaranteed by the hub's size; at 13.03%
it is a finding. The direction is consistent (more reserve raises
voltage slightly on every grid row, more uncertainty lowers it slightly
down every column), so the honest statement is "directionally as
expected, practically irrelevant", not "no effect". Mechanism: the
reserve margin changes *when* energy is drawn and how much shortfall
survives to real time, but barely changes the *peak* net injection — and
peak injection is what sets minimum voltage. The reserve margin is a
cost/energy instrument and should not be sold as voltage support.

### PWL segment-count trade-off (`main_month4c_pwl_segment_sweep.m`)

Sweeps `p.PWL.nSegments` in `{1, 2, 5, 10, 20, 36, 50, 75, 100, 150}` for
the fuel cell curves, reporting curve-fit approximation error (Max/RMSE
vs. the exact continuous efficiency function — same methodology as Month
2's error table), day-ahead MILP solve time, and planned-vs-realized cost —
mirroring the accuracy-vs-computation trade-off style used by Huang et
al. (not a claim of matching their specific numbers). Curve-fit error
falls monotonically with segment count and MILP solve time grows with
it (more segment/binary variables per hour) — the two sides of the
trade-off the thesis is centrally about. The realized-vs-planned cost
gap is *not* monotonic (each segment count gives the MILP a genuinely
different feasible region, so it makes a genuinely different fuel
dispatch decision, not just a more accurate evaluation of one fixed
plan) — reported honestly rather than smoothed into a cleaner-looking
curve; see `VALIDATION.md` for the full table.

**The tractability wall is found — and the seconds are not the result.**
The thesis claims high-fidelity PWL *while retaining MILP tractability*,
and a sweep stopping at 36 never tested the second half of that claim.
Solve time grows **superlinearly**: roughly 1 s (n=36) → 3 s (n=50) → 6–8 s
(n=75) → 15–18 s (n=100) → 30–62 s (n=150), tens of times the n=36
baseline. The binary count grows strictly *linearly* (3576 fill-order
binaries at n=150), so this is not "more binaries" — as segments narrow,
each binary controls a thinner slice of fuel, the LP relaxation becomes a
weaker guide to the integer optimum, and `glpk` explores disproportionately
more nodes.

**The absolute times are not a property of the segment count**, and this
session established that twice over. *Across instances*: the identical
MILP — same variables, same rows, same 3576 binaries, only different
numbers in it — took **169 s at n=150** before the hub was re-sized and
**30–62 s** after. *Across runs of the same instance*: repeated executions
of the unchanged script returned **30.1 s, 36.3 s and 61.7 s** at n=150, a
2× spread from machine state alone, because every count above n=36 is a
single timed solve. The superlinear shape reproduces every time; the wall's
location does not, and quoting "149.7 s at n=150" as a result (as an
earlier version of this file did) overstates what one timed solve can
establish. A 300 s per-solve budget records an over-budget count as a
*result* rather than dropping the row.

**Practical band for this system: roughly n=10 to n=36.** Below 10 the
cost error is material (n=1 is wrong by −4.36%, n=2 by +1.45%); above ~36
curve-fit error is already under 0.13 kW on a 700 kW device and solve time
climbs steeply for accuracy that changes no reported number. Huang et al.
report 30–70 on their system; this one sits lower — *not* a reproduction
of their result (different system, curves, prices and solver), only the
same shape of trade-off.

**A previously reported outlier was a bug, and is withdrawn.** Earlier
versions put the n=2 row at **+24.80%** and called it "a genuine outlier —
worse than n=1", with an explanation built on top of it. It was
arithmetic, not modelling. The fuel cell idles in most hours and the LP
returns `-1.19e-13` rather than `0` for one of them; `sqrt()` of a negative
makes the true-curve evaluation **complex**, and Octave's `max(X, 0)`
compares **magnitudes** for complex `X` — so the standard idiom that splits
net exchange into import and export returned a *negative import* and priced
a 4.4 kWh export as a 4.4 kWh import at the evening tariff. 23.35 of those
24.80 points were the bug. The corrected value is **+1.45%**, `|gap|` now
falls monotonically with segment count, and n=2 is not an outlier. What
survives is the part that was load-bearing: the **sign** of the Optimism
column still predicts the sign of the gap in every row. Fixed at the source
in `fc_true_output.m`.

### Co-optimization: LinDistFlow inside the MILP (`main_month4d...`)

Verification cannot change a schedule — it can only report after the fact
that the dispatch was network-unfriendly, which is what Month 3 found.
This closes the loop by embedding a linearized DistFlow voltage model in
the MILP. The rows now live in **all three** dispatch layers
(`dayahead_dispatch.m`, `intraday_dispatch.m`, `realtime_balance.m`), each
at its own time resolution, alongside a reactive-power decision variable
bounded by an IEEE 1547 capability and an apparent-power polygon.

**The 0.95 pu limit is infeasible on this system, and the script asks
before assuming.** Reaching it would need the hub to *export* 7942 kW at
bus 18 and 7066 kW at bus 33, against a total simultaneous export
capability (peak PV plus both storage discharge ratings, local load
ignored) of 551 kW — infeasible by an order of magnitude, and it stayed
infeasible after the hub grew 4.7×. So the co-optimization imposes an
achievable and more meaningful floor: **do no harm**, no bus driven below
its no-hub voltage.

| | Verify-only | Co-optimized |
|---|---|---|
| Day-ahead cost | $200.7961 | $200.8091 (**+0.01%**) |
| Peak grid import | 486.21 kW | 486.21 kW |
| Exact min voltage | 0.91281 pu | 0.913089 pu |
| Margin vs. no-hub floor | **−2.79e−04 pu** | **−1.32e−06 pu** |

Respecting the network costs **$0.0130/day**, and — this is the change
reactive power made — it costs *no active power at all*: peak import is
identical in both columns. The hub holds the floor by injecting up to 130
kvar instead of by curtailing.

**Report the margin, not the boolean.** Both columns fail a strict
`≥ floor − 1e−9 pu` test, which on its own would hide the entire effect:
the constraint removes **99.5%** of the violation (2.79e−04 → 1.32e−06 pu)
without removing the last part in a million. Across the full closed loop
(3 seeds × 3 uncertainty levels) the worst shortfall is **2.89e−06 pu** —
about 37× `distflow_bfs`'s own convergence floor, so resolvable rather
than noise, but **2208× smaller than LinDistFlow's own 6.38e−03 pu base-case
error**. The honest statement is *"the floor is held to within 3e−06 pu"*,
not "held" and not "failed". The tolerance has deliberately **not** been
widened to make it pass.

**Why this reads differently from the previous siting**, where the same
test returned 9 of 9. At bus 18 the hub sat *on* the binding bus, so the
floor and the achieved point were evaluated at the same node with the same
large linearization bias; the bias cancelled and left a comfortable
+7e−04 pu true margin. At bus 25 the binding bus is still 18, on a
different lateral, reached only through two shared trunk branches
(dV(18)/dP = −3.65e−06 pu/kW, twenty times weaker). The constraint no
longer clamps the schedule comfortably *inside* the floor — it clamps it
almost exactly *on* it, and the quadratic term LinDistFlow drops then lands
a few parts per million on the wrong side. **A guarantee stated in
LinDistFlow terms cannot be tighter than LinDistFlow**, and the re-sizing is
what finally made that visible.

**Two limitations that remain.** The real-time floor is **soft** (a heavily
penalised slack), because a hard floor there is genuinely infeasible — real
time must balance actual load with the fuel cell, heat pump and EV already
fixed at intraday setpoints, and a real controller cannot refuse to serve
load either. And LinDistFlow is **optimistic**, reading 0.0064 pu high on
the base case at 32 of 33 buses.

**What is no longer true, stated because it was reported for several
sessions.** The claim that the 32-row constraint set "collapses exactly to
a single scalar cap" was an artifact of having no reactive variable: with P
as the only lever every row is proportional to every other. With Q the ratio
`b_j/a_j` varies and the rows are independent — **but the variety is thinner
at this siting**, 5 distinct values from bus 25 against 16 from bus 18,
because every bus outside the 23-24-25 lateral shares exactly the same two
trunk branches. Five independent directions is not one, but 29 of the 32
rows are duplicates, and that is a property of radial topology and hub
placement rather than of the method.

## Scope notes

- Dispatch factors (`v`) and storage discharge inputs are free
  parameters of the Month 1-2 coupling matrix — nothing there enforces
  that a device cannot be charging and discharging at once. That's an
  operating *constraint* for whichever optimizer chooses `v` and `P`
  (Month 3), not something the graph/coupling-matrix model itself is
  responsible for.
- Real bugs caught and fixed during development (kept here since they
  show what was actually verified, not just claimed): a heat pump had to
  be added in Month 3 because the fuel cell was initially the *only*
  heat source, making it must-run regardless of price and masking the
  entire grid-import cost tradeoff; the real-time LP originally bounded
  battery power only by rating, not by the resulting SOC staying in
  bounds; the Month 4 case-study reliability margin was originally too
  generous (1.3x) to show any contrast between cases.
