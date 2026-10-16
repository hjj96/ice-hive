// ================================================================
//  STATIONS — seeded station layouts (v1.1, package E)
// ================================================================
// Stage-0 stub: the classic «Кельвин-9» layout only (seed 0).
// stationBoot() runs once in boot() before the first resetWorld; stationPrepare(opts) runs in startMission
// (opts.seed) before resetWorld; stationLabel() is the station name shown in banners, the title and the report.
let STATION = { seed: 0, name: 'Кельвин-9' };
function stationBoot() {}
function stationPrepare(opts) {}
function stationLabel() { return STATION.name; }
