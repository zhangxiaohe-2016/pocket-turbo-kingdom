import type { Mode, Quality } from '../config/game';
export interface GhostFrame {t:number;x:number;y:number;z:number;yaw:number;action:number}
export interface RecordEntry {lap:number;total:number|null;ghost:GhostFrame[]}
export interface SaveData {version:1;records:Record<string,RecordEntry>;settings:{quality:Quality;touch:boolean|null;volume:number};cups:Record<string,{unlocked:boolean;trophy:number}>}
const KEY='ptk-save-v1';
export class Records {
  data:SaveData={version:1,records:{},settings:{quality:matchMediaSafe()?'low':'high',touch:null,volume:0.35},cups:{sprout:{unlocked:true,trophy:0}}};
  available=true;
  constructor(){try{const raw=localStorage.getItem(KEY);if(raw){const d=JSON.parse(raw);if(d.version!==1)return;
      for(const [key,value] of Object.entries(d.records??{})){const r=value as RecordEntry;if(!r||!Number.isFinite(r.lap)||r.lap<=0)continue;const total=typeof r.total==='number'&&Number.isFinite(r.total)&&r.total>0?r.total:null;
        const ghost=Array.isArray(r.ghost)&&r.ghost.length<=18000&&r.ghost.every((f,i,all)=>f&&[f.t,f.x,f.y,f.z,f.yaw,f.action].every(Number.isFinite)&&f.t>=0&&f.t<=1800&&Math.abs(f.x)<500&&Math.abs(f.z)<500&&Math.abs(f.y)<1000&&(!i||f.t>all[i-1].t))?r.ghost:[];
        this.data.records[key]={lap:r.lap,total,ghost};
      }
      const settings=d.settings??{};if(['low','medium','high'].includes(settings.quality))this.data.settings.quality=settings.quality;if(typeof settings.touch==='boolean')this.data.settings.touch=settings.touch;if(Number.isFinite(settings.volume))this.data.settings.volume=Math.max(0,Math.min(1,settings.volume));
      for(const id of ['sprout','tide','ember','star']){const c=d.cups?.[id];if(c&&typeof c.unlocked==='boolean'&&Number.isInteger(c.trophy)&&c.trophy>=0&&c.trophy<=3)this.data.cups[id]=c;}
    }}catch{this.available=false;}}
  key(mode:Mode,kart:string){return `clockwork-v1:${mode}:${kart}`;}
  get(mode:Mode,kart:string){return this.data.records[this.key(mode,kart)];}
  save(mode:Mode,kart:string,lap:number,total:number,ghost:GhostFrame[]){
    const key=this.key(mode,kart), old=this.data.records[key];
    const best=!old||total<(old.total??Infinity);
    this.data.records[key]={lap:Math.min(old?.lap??Infinity,lap),total:Math.min(old?.total??Infinity,total),ghost:best&&mode==='time'?ghost.slice(0,18000):(old?.ghost??[])};
    this.persist();return best;
  }
  saveLap(mode:Mode,kart:string,lap:number){
    const key=this.key(mode,kart),old=this.data.records[key];
    if(!Number.isFinite(lap)||lap<=0)return;
    if(!old){this.data.records[key]={lap,total:null,ghost:[]};this.persist();}else if(lap<old.lap){old.lap=lap;this.persist();}
  }
  persist(){try{localStorage.setItem(KEY,JSON.stringify(this.data));return true;}catch{this.available=false;return false;}}
}
function matchMediaSafe(){return typeof matchMedia!=='undefined'&&matchMedia('(pointer: coarse)').matches;}
export function formatTime(t:number){if(!Number.isFinite(t))return '--:--.---';const ms=Math.floor(t*1000);return `${Math.floor(ms/60000).toString().padStart(2,'0')}:${Math.floor(ms/1000%60).toString().padStart(2,'0')}.${(ms%1000).toString().padStart(3,'0')}`;}
