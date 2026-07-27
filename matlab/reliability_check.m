function viol = reliability_check(Pg_imp5, Pg_exp5, capacityLimit)
%RELIABILITY_CHECK Quantify feeder-capacity violations for a 5-min dispatch.
%
%   viol = RELIABILITY_CHECK(Pg_imp5, Pg_exp5, capacityLimit)
%
%   A "reliability violation" is any 5-minute interval where the
%   required grid import or export exceeds an assumed contracted feeder
%   capacity (p.reliability.feederCapMargin x a reference peak -- see
%   main_case_studies.m / main_sensitivity_analysis.m for how the
%   reference is chosen). Import violations represent unmet demand
%   (load shedding would be needed); export violations represent
%   renewable curtailment (surplus that cannot be exported).
%
%   Output viol:
%     violationIntervals : count of 5-min slots exceeding the limit
%     violationHours      : same, in hours
%     unmetEnergy_kWh      : total energy over the import limit
%     curtailedEnergy_kWh  : total energy over the export limit
%     maxOverImport_kW, maxOverExport_kW : worst single-interval excess

    overImport = max(Pg_imp5 - capacityLimit, 0);
    overExport = max(Pg_exp5 - capacityLimit, 0);

    viol.violationIntervals = sum(overImport > 1e-9 | overExport > 1e-9);
    viol.violationHours = viol.violationIntervals * (5/60);
    viol.unmetEnergy_kWh = sum(overImport) * (1/12);
    viol.curtailedEnergy_kWh = sum(overExport) * (1/12);
    viol.maxOverImport_kW = max(overImport);
    viol.maxOverExport_kW = max(overExport);
end
