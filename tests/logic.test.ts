import { describe,it,expect } from 'vitest';
import { FixedStep } from '../src/core/FixedStep';
import { advanceProgress,type ProgressState } from '../src/race/RaceManager';
import { itemWeights,pickItem } from '../src/items/ItemSystem';
import { formatTime } from '../src/storage/Records';
const racer=():ProgressState=>({lap:0,nextCheckpoint:1,lastCheckpoint:0,lastT:0,progress:0,finished:false,finishTime:0,lapStart:0,lapTimes:[]});
describe('fixed 60Hz simulation',()=>{
  it('produces identical ticks at 30,60,120 render FPS',()=>{const counts=[30,60,120].map(fps=>{const s=new FixedStep();let count=0;for(let i=0;i<fps*10;i++)s.advance(1/fps,()=>count++);return count;});expect(counts).toEqual([600,600,600]);});
  it('caps catch-up and returns interpolation alpha',()=>{const s=new FixedStep();let ticks=0;const a=s.advance(10,()=>ticks++);expect(ticks).toBeLessThanOrEqual(6);expect(a).toBeGreaterThanOrEqual(0);expect(a).toBeLessThan(1);});
});
describe('sequential checkpoint validation',()=>{
  it('requires 16 forward gates per lap, completes exactly 3 laps',()=>{const k=racer();for(let i=1;i<=3000;i++)advanceProgress(k,(i/1000)%1,true,.002,i*.02);expect(k.lap).toBe(3);expect(k.finished).toBe(true);expect(k.lapTimes).toHaveLength(3);expect(k.finishTime).toBe(60);});
  it('rejects reverse finish crossing and forward recrossing exploits',()=>{const k=racer();for(let i=0;i<100;i++){advanceProgress(k,.999,true,.01,1);advanceProgress(k,.001,true,.01,2);}expect(k.lap).toBe(0);expect(k.lastCheckpoint).toBe(0);});
  it('rejects large skips, off-road gates, and missed gates',()=>{const k=racer();advanceProgress(k,.5,true,.01,1);expect(k.nextCheckpoint).toBe(1);k.lastT=.06;advanceProgress(k,.064,false,.01,2);expect(k.nextCheckpoint).toBe(1);for(let i=65;i<=1000;i++)advanceProgress(k,(i/1000)%1,true,.005,i);expect(k.lap).toBe(0);});
  it('does not advance on stationary reset',()=>{const k=racer();k.lastT=.126;k.nextCheckpoint=3;k.lastCheckpoint=2;advanceProgress(k,.126,true,.01,10);expect(k.lastCheckpoint).toBe(2);expect(k.lap).toBe(0);});
});
describe('rank-weighted items and time formatting',()=>{
  it('limits catch-up weighting and includes all four items',()=>{expect(itemWeights(4,4)[0]).toBeCloseTo(.35);expect(itemWeights(1,4)[1]).toBeCloseTo(.48);const set=new Set(Array.from({length:100},(_,i)=>pickItem(2,4,i/100)));expect(set.size).toBe(4);});
  it('handles time display and missing records',()=>{expect(formatTime(63.456)).toBe('01:03.456');expect(formatTime(Infinity)).toBe('--:--.---');});
});
