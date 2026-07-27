function SOC_next = storage_soc_update(SOC, Pch, Pdis, dev, dt)
%STORAGE_SOC_UPDATE One step of the shared generalized-storage state equation.
%
%   SOC_next = STORAGE_SOC_UPDATE(SOC, Pch, Pdis, dev, dt)
%
%   The single state equation used for every storage-like device in this
%   chapter (battery, EV, building thermal mass, pipe storage -- see
%   multiscale_default_params.m for the physical reinterpretation of
%   each):
%       SOC(t) = SOC(t-1) + [eta_ch*Pch - Pdis/eta_dis]*dt/Emax - selfLoss*SOC(t-1)*dt
%
%   dev is one of p.Batt / p.EV / p.Building / p.Pipe (a struct with
%   fields eta_ch, eta_dis, Emax, selfLoss). This is the same equation
%   the day-ahead/intraday/real-time LPs encode as a linear equality
%   constraint; used here to advance the ACTUAL system state between
%   rolling-horizon solves, and to cross-check each LP's own SOC
%   variables against an independent recomputation.

    SOC_next = SOC + (dev.eta_ch*Pch - Pdis/dev.eta_dis) * dt / dev.Emax - dev.selfLoss*SOC*dt;
end
