// ================================================================
//  META — profile, tier choice, mission report (v1.1, package D)
// ================================================================
// Stage-0 stub. metaBoot(data) runs in boot() right after GS.best is read (before buildTitle);
// tierPrepare(opts) runs first in startMission and selects TH via setTier (default: Ветеран).
function metaBoot(data) {}
function tierPrepare(opts) { setTier(opts.tier != null ? opts.tier : 1); }
