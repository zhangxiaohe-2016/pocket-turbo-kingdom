import { ARENA_SECONDS } from '../config/arena';
import type { KartPhysics } from '../vehicle/KartPhysics';
import { CHECKPOINTS,LAPS,type Mode } from '../config/game';
export type RaceState='menu'|'countdown'|'racing'|'paused'|'finished';
export interface ProgressState {lap:number;nextCheckpoint:number;lastCheckpoint:number;lastT:number;progress:number;finished:boolean;finishTime:number;lapStart:number;lapTimes:number[]}
// Sequential forward gates + plausible displacement + legal road corridor. Reset never advances a gate.
export function advanceProgress(k:ProgressState,t:number,legal:boolean,distanceBudget:number,time:number):boolean {
  let delta=t-k.lastT;if(delta<-.5)delta+=1;if(delta>.5)delta-=1;
  const before=k.lastT;k.lastT=t;
  if(!legal||delta<=0||delta>distanceBudget||k.finished)return false;
  const gate=(k.nextCheckpoint%CHECKPOINTS)/CHECKPOINTS;
  let toGate=gate-before;if(toGate<0)toGate+=1;
  if(toGate<=delta+1e-7&&toGate>=0){
    k.lastCheckpoint=k.nextCheckpoint%CHECKPOINTS;k.nextCheckpoint++;
    if(k.nextCheckpoint>CHECKPOINTS){k.lap++;k.lapTimes.push(time-k.lapStart);k.lapStart=time;k.nextCheckpoint=1;if(k.lap>=LAPS){k.finished=true;k.finishTime=time;}}
  }
  // Ranking is clamped to the next unvalidated gate; an invalid teleport cannot win a race.
  const segment=(k.nextCheckpoint-1)/CHECKPOINTS;
  let validT=gate===0&&t>.9?t:Math.max(segment,Math.min(t,segment+1/CHECKPOINTS));
  if(k.lap===0&&k.nextCheckpoint===1&&t>.9)validT=t-1;
  k.progress=k.lap+validT;return k.finished;
}
export class RaceManager {
  multiplayer=false;
  state:RaceState='menu';resumeState:RaceState='racing';countdown=3.6;elapsed=0;goFlash=0;finishOrder:KartPhysics[]=[];
  constructor(public karts:KartPhysics[],public mode:Mode){}
  start(){this.elapsed=0;this.karts.forEach(k=>{k.progress=k.projection.t>.9?k.projection.t-1:0;k.rank=k.id+1;});this.countdown=3.6;this.state=this.mode==='practice'?'racing':'countdown';if(this.mode==='arena')this.rankArena();}
  pause(){if(this.state==='paused')this.state=this.resumeState;else if(this.state==='racing'||this.state==='countdown'){this.resumeState=this.state;this.state='paused';}}
  arenaHit(owner:number,target:KartPhysics){
    if(this.mode!=='arena'||this.state!=='racing'||target.disconnected||target.id===owner)return;
    const attacker=this.karts.find(k=>k.id===owner&&!k.disconnected);if(!attacker)return;
    attacker.score++;target.hitsTaken++;this.rankArena();
  }
  rankArena(){const ranked=[...this.karts].sort((a,b)=>Number(a.disconnected)-Number(b.disconnected)||b.score-a.score||a.id-b.id);ranked.forEach((k,i)=>k.rank=i>0&&k.score===ranked[i-1].score&&k.disconnected===ranked[i-1].disconnected?ranked[i-1].rank:i+1);}
  step(dt:number){
    if(this.state==='countdown'){this.countdown-=dt;if(this.countdown<=0){this.state='racing';this.goFlash=1; }return;}
    if(this.mode==='arena'&&this.state==='finished')return;
    if(this.state!=='racing'&&this.state!=='finished')return;this.elapsed+=dt;this.goFlash=Math.max(0,this.goFlash-dt);
    if(this.mode==='arena'){this.rankArena();if(this.elapsed>=ARENA_SECONDS){this.elapsed=ARENA_SECONDS;this.state='finished';this.karts.forEach(k=>{k.finished=true;k.finishTime=this.elapsed;});}return;}
    for(const kart of this.karts){if(kart.finished)continue;
      const done=advanceProgress(kart,kart.projection.t,kart.track.legal(kart.projection,kart.position.y),Math.max(.008,kart.position.distanceTo(kart.previous)/kart.track.length*2.2),this.elapsed);
      if(done){if(this.mode==='practice'){kart.finished=false;kart.lap=0;kart.progress=0;}else{kart.collider.setSensor(true);this.finishOrder.push(kart);if(kart.id===0)this.state='finished';}}
    }
    const ranked=[...this.karts].sort((a,b)=>a.finished&&b.finished?a.finishTime-b.finishTime:a.finished?-1:b.finished?1:b.progress-a.progress||b.projection.t-a.projection.t);ranked.forEach((k,i)=>k.rank=i+1);
  }
}
