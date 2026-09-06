import { CUPS,CUP_POINTS } from '../config/game';
// Tested data-layer extension only. The menu never starts unavailable tracks.
export interface CupStanding {id:string;points:number;wins:number;totalTime:number}
export class CupSession {
  readonly plan;round=0;standings:CupStanding[];
  constructor(cupId:string,players:string[]){const plan=CUPS.find(c=>c.id===cupId);if(!plan)throw new Error('Unknown cup');if(!players.length||new Set(players).size!==players.length)throw new Error('Unique players required');this.plan=plan;this.standings=players.map(id=>({id,points:0,wins:0,totalTime:0}));}
  get nextTrack(){return this.plan.tracks[this.round]??null;}
  get complete(){return this.round===4;}
  available(implemented:ReadonlySet<string>){return !!this.nextTrack&&implemented.has(this.nextTrack);}
  recordRound(finishers:{id:string;time:number}[]){if(this.complete)throw new Error('Cup complete');if(finishers.length!==this.standings.length||new Set(finishers.map(f=>f.id)).size!==finishers.length||finishers.some(f=>!this.standings.some(s=>s.id===f.id)||!Number.isFinite(f.time)||f.time<=0))throw new Error('Invalid result');const ordered=[...finishers].sort((a,b)=>a.time-b.time);ordered.forEach((f,i)=>{const s=this.standings.find(s=>s.id===f.id)!;s.points+=CUP_POINTS[i]??0;s.wins+=i===0?1:0;s.totalTime+=f.time;});this.round++;this.standings.sort((a,b)=>b.points-a.points||b.wins-a.wins||a.totalTime-b.totalTime||a.id.localeCompare(b.id));}
}
