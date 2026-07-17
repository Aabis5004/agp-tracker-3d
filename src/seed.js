/**
 * Offline test seed — real data captured from the AGP API.
 * Only used to verify the pipeline without network access.
 * Run: node src/seed.js
 */
import db, { upsertTrack, upsertRacer } from './db.js';

const TRACKS = [
  {id:"ba1eda90-0308-4612-afa2-20e58fbcb99e",name:"Day 4 - AGP track 2",difficulty:"medium",pointCount:8,startsAt:"2026-07-02T16:59:30.011Z",started:true,racerCount:16,winnerLogin:"mystiquemide",over:true,questionCostUsd:0.001,guessCostUsd:0.005,maxRacers:50,createdAt:"2026-07-02T16:44:30.011Z"},
  {id:"ea9bebfd-f8e2-40c2-961b-07daef0f6c2f",name:"Day 4 - AGP track 1",difficulty:"medium",pointCount:8,startsAt:"2026-07-02T15:19:50.476Z",started:true,racerCount:13,winnerLogin:"mystiquemide",over:true,questionCostUsd:0.001,guessCostUsd:0.005,maxRacers:50,createdAt:"2026-07-02T15:04:50.476Z"},
  {id:"1904240f-e18a-4ff1-b50c-12b89b0d2ccb",name:"Day 3 - AGP track 2",difficulty:"easy",pointCount:8,startsAt:"2026-07-01T18:15:01.488Z",started:true,racerCount:8,winnerLogin:"mystiquemide",over:true,questionCostUsd:0.001,guessCostUsd:0.005,maxRacers:50,createdAt:"2026-07-01T18:00:01.489Z"},
  {id:"a48e22d4-f586-49e1-9b73-47f573cbe1b0",name:"Day 3 - AGP track 1",difficulty:"medium",pointCount:8,startsAt:"2026-07-01T16:13:53.639Z",started:true,racerCount:22,winnerLogin:"johnsonnguyen-coll",over:true,questionCostUsd:0.001,guessCostUsd:0.005,maxRacers:50,createdAt:"2026-07-01T15:58:53.639Z"},
  {id:"277a0ae2-b8fc-4837-bdbf-fb132ee1000d",name:"Day 2 -AGP Track 2",difficulty:"easy",pointCount:8,startsAt:"2026-06-30T18:15:29.733Z",started:true,racerCount:20,winnerLogin:"naborii",over:true,questionCostUsd:0.001,guessCostUsd:0,maxRacers:50,createdAt:"2026-06-30T18:00:29.734Z"},
  {id:"1f9fff64-9579-4669-b9fd-a49aa9a8ba9b",name:"Day 2 - AGP",difficulty:"easy",pointCount:8,startsAt:"2026-06-30T15:12:37.696Z",started:true,racerCount:15,winnerLogin:"naborii",over:true,questionCostUsd:0.001,guessCostUsd:0,maxRacers:15,createdAt:"2026-06-30T15:02:37.697Z"},
  {id:"b5f39a74-4ab4-4382-bced-127ee8672523",name:"Inaugural race AGP",difficulty:"easy",pointCount:8,startsAt:"2026-06-26T20:09:15.609Z",started:true,racerCount:15,winnerLogin:"naborii",over:true,questionCostUsd:0.001,guessCostUsd:0,maxRacers:null,createdAt:"2026-06-26T19:59:15.609Z"}
];

// real racers from Day 4 track 2 (the one we fetched in full)
const RACERS = {
  "ba1eda90-0308-4612-afa2-20e58fbcb99e": [
    {login:"tiadler",idx:0,pointCount:8,finished:false,durationMs:2259911,questionsAsked:52,guessCount:4},
    {login:"hositam",idx:0,pointCount:8,finished:false,durationMs:2252617,questionsAsked:151,guessCount:9},
    {login:"sanjeebdas1979",idx:0,pointCount:8,finished:false,durationMs:2242817,questionsAsked:15,guessCount:18},
    {login:"johnsonnguyen-coll",idx:1,pointCount:8,finished:false,durationMs:2238378,questionsAsked:60,guessCount:84},
    {login:"mystiquemide",idx:8,pointCount:8,finished:true,durationMs:2216777,questionsAsked:99,guessCount:142},
    {login:"jena609",idx:0,pointCount:8,finished:false,durationMs:2195085,questionsAsked:0,guessCount:0},
    {login:"naborii",idx:1,pointCount:8,finished:false,durationMs:2179971,questionsAsked:28,guessCount:90},
    {login:"ankerwebs",idx:0,pointCount:8,finished:false,durationMs:2130928,questionsAsked:0,guessCount:0},
    {login:"sukanto01899",idx:0,pointCount:8,finished:false,durationMs:2046441,questionsAsked:20,guessCount:23},
    {login:"zahraefendy",idx:0,pointCount:8,finished:false,durationMs:2020815,questionsAsked:0,guessCount:0},
    {login:"kingclaszzz",idx:0,pointCount:8,finished:false,durationMs:1806461,questionsAsked:27,guessCount:0},
    {login:"ganesh0690",idx:0,pointCount:8,finished:false,durationMs:1744215,questionsAsked:64,guessCount:28},
    {login:"bibidee",idx:0,pointCount:8,finished:false,durationMs:1559780,questionsAsked:56,guessCount:11},
    {login:"himu-xyz",idx:0,pointCount:8,finished:false,durationMs:1559191,questionsAsked:0,guessCount:0},
    {login:"zoefunds",idx:0,pointCount:8,finished:false,durationMs:1552029,questionsAsked:0,guessCount:0},
    {login:"mahi017fr",idx:0,pointCount:8,finished:false,durationMs:1534825,questionsAsked:0,guessCount:0}
  ]
};

const now = new Date().toISOString();

const run = db.transaction(() => {
  for (const t of TRACKS) {
    upsertTrack.run({
      id: t.id, name: t.name, difficulty: t.difficulty, point_count: t.pointCount,
      starts_at: t.startsAt, started: t.started ? 1 : 0, over: t.over ? 1 : 0,
      racer_count: t.racerCount, winner_login: t.winnerLogin,
      question_cost: t.questionCostUsd, guess_cost: t.guessCostUsd,
      max_racers: t.maxRacers, created_at: t.createdAt, now
    });
    for (const r of (RACERS[t.id] || [])) {
      upsertRacer.run({
        track_id: t.id, login: r.login, idx: r.idx, point_count: r.pointCount,
        finished: r.finished ? 1 : 0, duration_ms: r.durationMs,
        questions_asked: r.questionsAsked, guess_count: r.guessCount, now
      });
    }
  }
});

run();
console.log(`[seed] ${TRACKS.length} tracks, ${Object.values(RACERS).flat().length} racers`);
