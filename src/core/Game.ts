import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import RAPIER from '@dimforge/rapier3d-compat';
import { Track } from '../track/Track';
import { KartPhysics } from '../vehicle/KartPhysics';
import { makeKart,type KartModel } from '../vehicle/KartModel';
import { ChaseCamera } from '../camera/ChaseCamera';
import { FixedStep } from './FixedStep';
import { InputManager,emptyControls,type Controls } from '../input/InputManager';
import { RaceManager } from '../race/RaceManager';
import { ArenaDriver } from '../ai/ArenaDriver';
import { AIDriver } from '../ai/AIDriver';
import { ItemSystem } from '../items/ItemSystem';
import { Effects } from '../effects/Effects';
import { AudioManager } from '../audio/AudioManager';
import { KARTS,QUALITY,type Mode,type Quality,type ItemKind } from '../config/game';
import { Records,type GhostFrame } from '../storage/Records';
import { HUD } from '../ui/HUD';
import { LanClient } from '../network/LanClient';
import type { Room, Snapshot } from '../network/protocol';
export class Game {
  lan!:LanClient;private lanPlayers:string[]=[];private netAccumulator=0;private snapshotAt=0;
  scene=new THREE.Scene();renderer:THREE.WebGLRenderer;camera=new THREE.PerspectiveCamera(64,1,.1,600);world:RAPIER.World;track:Track;input:InputManager;chase:ChaseCamera;
  karts:KartPhysics[]=[];ais:(AIDriver|ArenaDriver)[]=[];race!:RaceManager;items!:ItemSystem;effects:Effects;audio=new AudioManager();fixed=new FixedStep();
  private light=new THREE.DirectionalLight(0xffedc7,3.2);private queue=new RAPIER.EventQueue(true);private time=0;private last=0;private uiTimer=0;private fps=60;private quality:Quality;
  private mode:Mode='quick';private selected=0;private controls=emptyControls();private resultShown=false;private lastCount=4;private savedLapCount=0;
  private ghost?:KartModel;private ghostFrames:GhostFrame[]=[];private recording:GhostFrame[]=[];private ghostIndex=0;private nextSample=0;
  private menuTarget=new THREE.Vector3();private menuPosition=new THREE.Vector3();private lastInput=emptyControls();private running=true;private auto?:AIDriver;private debugManual=false;
  private dynamicScale=1;private performanceTimer=0;private environment:THREE.WebGLRenderTarget;
  constructor(public hud:HUD,public records:Records){
    this.world=new RAPIER.World({x:0,y:-9.81,z:0});this.world.timestep=1/60;
    this.renderer=new THREE.WebGLRenderer({antialias:true,powerPreference:'high-performance',alpha:false});this.renderer.outputColorSpace=THREE.SRGBColorSpace;this.renderer.toneMapping=THREE.ACESFilmicToneMapping;this.renderer.toneMappingExposure=1.15;this.renderer.shadowMap.type=THREE.PCFSoftShadowMap;
    hud.root.querySelector('#viewport')!.appendChild(this.renderer.domElement);this.renderer.domElement.setAttribute('aria-label','Pocket Turbo Kingdom 3D 游戏画面');this.renderer.domElement.addEventListener('webglcontextlost',e=>{e.preventDefault();this.running=false;hud.error('WebGL 上下文丢失。请刷新页面，或切换到低画质后重试。');});
    this.scene.background=new THREE.Color(0xb3d8d7);this.scene.fog=new THREE.Fog(0xb3d8d7,100,400);
    this.scene.add(new THREE.HemisphereLight(0xe6f6ff,0x7c9971,2.3));this.light.position.set(30,65,20);this.light.castShadow=true;this.light.shadow.camera.left=-42;this.light.shadow.camera.right=42;this.light.shadow.camera.top=42;this.light.shadow.camera.bottom=-42;this.light.shadow.camera.near=1;this.light.shadow.camera.far=160;this.light.shadow.normalBias=.055;this.light.shadow.bias=-.00015;this.scene.add(this.light,this.light.target);
    const pmrem=new THREE.PMREMGenerator(this.renderer),room=new RoomEnvironment();this.environment=pmrem.fromScene(room,.04);this.scene.environment=this.environment.texture;this.scene.environmentIntensity=.32;room.dispose();pmrem.dispose();
    this.track=new Track(this.world,this.scene);this.effects=new Effects(this.scene);this.input=new InputManager(hud.root);this.chase=new ChaseCamera(this.camera,this.world);this.quality=records.data.settings.quality;this.applyQuality(this.quality);this.audio.volume=records.data.settings.volume;
    this.createRace('quick',0,false);hud.bind({start:(m,k)=>this.start(m,k),resume:()=>this.togglePause(),restart:()=>{if(this.lan.active){this.lan.send({type:'rematch'});this.hud.toast('等待房主开启下一场');}else this.start(this.mode,this.selected);},menu:()=>this.menu(),quality:q=>{this.applyQuality(q);records.data.settings.quality=q;records.persist();},touch:on=>{records.data.settings.touch=on;records.persist();},volume:v=>{this.audio.setVolume(v);records.data.settings.volume=v;records.persist();}},i=>this.preview(i));
    this.lan=new LanClient(hud.root);this.lan.onRoom=(r,you)=>this.lanRoom(r,you);this.lan.onSnapshot=s=>this.lanSnapshot(s);this.lan.onLeave=()=>{this.lanPlayers=[];this.createRace('quick',this.selected,false);};
    window.addEventListener('resize',()=>this.resize());window.addEventListener('blur',()=>this.pauseOnBlur());document.addEventListener('visibilitychange',()=>{if(document.hidden){this.pauseOnBlur();this.audio.suspend();}else{this.last=performance.now();this.fixed.reset();}});this.resize();
    if(import.meta.env.DEV&&new URLSearchParams(location.search).has('test'))this.exposeDebug();
  }
  private disposeObject(root:THREE.Object3D){const gs=new Set<THREE.BufferGeometry>(),ms=new Set<THREE.Material>();root.traverse(o=>{if(o instanceof THREE.Mesh){gs.add(o.geometry);for(const m of Array.isArray(o.material)?o.material:[o.material])ms.add(m);}});gs.forEach(g=>g.dispose());ms.forEach(m=>m.dispose());this.scene.remove(root);}
  private createRace(mode:Mode,selected:number,start:boolean,specs?:number[]){
    if(this.items){for(const b of this.items.boxes)if(b.mesh)this.disposeObject(b.mesh);for(const o of this.items.pool)if(o.mesh)this.disposeObject(o.mesh);this.items.dispose(this.scene);}
    for(const k of this.karts){if(k.model)this.disposeObject(k.model.root);this.world.removeRigidBody(k.body);}if(this.ghost){this.disposeObject(this.ghost.root);this.ghost=undefined;}
    if(this.track.arena!==(mode==='arena')){this.disposeObject(this.track.group);this.world.free();this.queue.free();this.queue=new RAPIER.EventQueue(true);this.world=new RAPIER.World({x:0,y:-9.81,z:0});this.world.timestep=1/60;this.track=new Track(this.world,this.scene,mode==='arena');this.chase=new ChaseCamera(this.camera,this.world);this.track.setSceneryDensity(QUALITY[this.quality].scenery);}
    this.time=0;this.track.update(0,0);this.mode=mode;this.selected=selected;this.karts=[];const count=specs?.length??(mode==='quick'||mode==='arena'?4:1);for(let i=0;i<count;i++){const spec=KARTS[specs?.[i]??((selected+i)%KARTS.length)];this.karts.push(new KartPhysics(i,spec,this.world,this.track,this.scene));}
    this.ais=this.karts.slice(1).map((k,i)=>mode==='arena'?new ArenaDriver(k):new AIDriver(k,[-2.7,2.8,.2][i]));this.race=new RaceManager(this.karts,mode);this.items=new ItemSystem(this.track,this.karts,mode,this.scene);this.items.onHit=(owner,target)=>this.race.arenaHit(owner,target);this.items.onEvent=(event,k)=>{if(k?.id===0){this.audio.tone(event);if(event==='pickup')this.hud.toast('晶体装载中 · 双槽道具');if(event==='hit')this.hud.toast('被击中了！抓稳方向');}};
    this.ghostFrames=mode==='time'?(this.records.get(mode,KARTS[selected].id)?.ghost??[]):[];if(this.ghostFrames.length>1){this.ghost=makeKart(KARTS[selected],true);this.scene.add(this.ghost.root);this.ghost.root.visible=false;}
    this.recording=[];this.ghostIndex=0;this.nextSample=0;this.resultShown=false;this.lastCount=4;this.savedLapCount=0;this.chase.reset();this.fixed.reset();this.input.clear();this.controls=emptyControls();this.lastInput=emptyControls();this.auto=undefined;
    // Populate Rapier's scene-query pipeline and settle all four suspension rays before showing the grid.
    for(let i=0;i<70;i++){for(const k of this.karts)k.preStep(1/60,emptyControls(),false);this.world.step(this.queue);for(const k of this.karts)k.postStep(1/60);}
    this.queue.drainCollisionEvents(()=>{});for(const k of this.karts){k.previous.copy(k.position);k.lastT=k.projection.t;k.render(1,1/60,0);}
    if(start)this.race.start();this.hud.reset();this.hud.set('#again-btn','再跑一场 ↗');this.hud.sync(this.race.state);this.updateShadow();
    if(!start){const k=this.karts[0],s=this.track.at(k.projection.t);this.menuPosition.copy(k.position).addScaledVector(s.tangent,5.8).addScaledVector(s.right,6.3);this.menuPosition.y+=3;this.menuTarget.copy(k.position).addScaledVector(s.right,-2.15);this.menuTarget.y+=.4;this.camera.position.copy(this.menuPosition);this.camera.lookAt(this.menuTarget);this.camera.fov=48;this.camera.updateProjectionMatrix();}
  }
  start(mode:Mode,kart:number){void this.audio.unlock();this.createRace(mode,kart,true);this.hud.toast(mode==='arena'?'星火竞技场 · 3 分钟 · 道具命中对手 +1 分':mode==='time'?'计时赛 · 固定电池 · 最佳幽灵自动加载':mode==='practice'?'自由练习 · 随时 R 复位':'三圈冒险 · GO 时开始计时');}
  private preview(i:number){this.createRace('quick',i,false);}
  private menu(){if(this.lan.active){this.lan.leave();return;}this.createRace('quick',this.selected,false);}
  private togglePause(){if(this.lan.active){this.hud.toast('联机比赛持续进行 · 点击左上角退出房间');return;}if(this.race.state==='racing'||this.race.state==='countdown'||this.race.state==='paused'){this.race.pause();this.fixed.reset();this.input.clear();this.hud.sync(this.race.state);if(this.race.state!=='paused')void this.audio.unlock();}}
  private pauseOnBlur(){if(this.lan.active){this.input.clear();this.controls=emptyControls();this.lan.input(emptyControls());return;}if(this.race.state==='racing'||this.race.state==='countdown'){this.race.pause();this.input.clear();this.fixed.reset();this.hud.sync(this.race.state);}}
  private applyQuality(q:Quality){this.quality=q;const config=QUALITY[q];this.renderer.shadowMap.enabled=config.shadow>0;this.light.castShadow=config.shadow>0;if(config.shadow){this.light.shadow.mapSize.setScalar(config.shadow);this.light.shadow.map?.dispose();this.light.shadow.map=null;}this.effects.limit=config.particles;this.track.setSceneryDensity(config.scenery);this.dynamicScale=1;this.resize();}
  private resize(){const w=window.innerWidth,h=window.innerHeight;this.camera.aspect=w/h;this.camera.updateProjectionMatrix();this.renderer.setPixelRatio(Math.min(devicePixelRatio||1,QUALITY[this.quality].pixelRatio)*this.dynamicScale);this.renderer.setSize(w,h);}
  private updateShadow(){const p=this.karts[0].position;this.light.position.set(p.x+25,p.y+55,p.z+20);this.light.target.position.copy(p);this.light.target.updateMatrixWorld();}
  private consumeControls(){const c=this.controls;this.controls={...c,jump:false,item1:false,item2:false,reset:false,pause:false,camera:false,discard:false};return c;}
  step(dt:number){
    if(this.lan?.active){this.netAccumulator+=dt;if(this.netAccumulator>=1/30){this.netAccumulator=0;this.lan.input(this.consumeControls());}this.time+=dt;this.track.update(dt,this.time);this.effects.step(dt,this.karts);return;}
    const state=this.race.state;if(state==='menu'||state==='paused')return;this.time+=dt;
    let input=this.consumeControls();if(this.auto&&state==='racing')input=this.auto.update(dt,this.karts[0].progress,this.items);this.lastInput=input;
    this.track.update(dt,this.time);const enabled=state==='racing'||state==='finished';
    for(const k of this.karts){let c=k.id===0?input:this.ais[k.id-1].update(dt,this.karts[0].progress,this.items);if(k.finished)c=emptyControls();
      if(k.needsReset||c.reset){k.reset();if(k.id===0){this.chase.reset();this.hud.toast(this.mode==='arena'?'竞技场复位 · 冷却 8 秒':'已返回最近合法检查点');}}
      if(enabled&&!k.finished){if(c.item1)this.items.use(k,0,c.backward);if(c.item2)this.items.use(k,1,c.backward);if(c.discard)this.items.discard(k);}
      k.preStep(dt,c,enabled&&!k.finished);
    }
    this.items.update(dt,this.time,enabled);this.world.step(this.queue);
    this.queue.drainCollisionEvents((a,b,started)=>{if(!started)return;const ka=this.karts.find(k=>k.collider.handle===a),kb=this.karts.find(k=>k.collider.handle===b);for(const k of [ka,kb]){if(!k||Math.abs(k.speed)<7||k.invulnerable>0)continue;const other=ka===k?b:a;if(this.track.surfaceHandles.has(other))continue;k.impact=.45;k.stun=Math.max(k.stun,.28);if(k.id===0)this.audio.tone('hit');}});
    for(const k of this.karts){k.postStep(dt);if(k.id===0){if(k.landed>.15){this.chase.shake=Math.max(this.chase.shake,k.landed*.12);this.audio.tone('hit');}if(k.releasedBoost){this.audio.tone('boost');this.hud.toast(`漂移 ${k.releasedBoost} 级 · 涡轮释放！`);}}}
    this.race.step(dt);this.effects.step(dt,this.karts);
    const count=this.race.state==='countdown'?Math.max(1,Math.ceil(this.race.countdown-.6)):0;if(count!==this.lastCount){this.lastCount=count;if(count)this.audio.tone('tick');else if(this.race.goFlash>0)this.audio.tone('go');}
    const player=this.karts[0];if(this.mode!=='practice'&&player.lapTimes.length>this.savedLapCount){this.savedLapCount=player.lapTimes.length;this.records.saveLap(this.mode,player.spec.id,Math.min(...player.lapTimes));}
    if(this.mode==='time'&&this.race.state==='racing'&&this.race.elapsed>=this.nextSample){if(this.recording.length<18000)this.recording.push({t:this.race.elapsed,x:player.position.x,y:player.position.y,z:player.position.z,yaw:player.yaw,action:(player.drift?1:0)|(player.boost>0?2:0)|(player.grounded?0:4)|(player.trick?8:0)});this.nextSample+=.1;}
    if(player.finished&&!this.resultShown){this.resultShown=true;const isBest=this.mode!=='arena'&&this.records.save(this.mode,player.spec.id,Math.min(...player.lapTimes),player.finishTime,this.recording);this.hud.result(this.race,player,isBest,this.records.available);this.hud.sync('finished');this.audio.tone('finish');}
  }
  private lanRoom(room:Room,you:string){
    if(room.phase==='lobby'){if(this.lanPlayers.length){this.lanPlayers=[];this.createRace('quick',this.selected,false);}return;}
    const players=[room.players.find(p=>p.id===you)!,...room.players.filter(p=>p.id!==you)];
    if(!this.lanPlayers.length){this.lanPlayers=players.map(p=>p.id);this.createRace(room.mode,players[0].kart,true,players.map(p=>p.kart));this.karts.forEach((k,i)=>{k.driverName=players[i].name;});this.race.multiplayer=true;this.hud.toast('局域网竞技 · 服务器统一发车');void this.audio.unlock();}
  }
  private lanSnapshot(s:Snapshot){
    if(!this.lanPlayers.length)return;this.snapshotAt=performance.now();
    for(const data of s.karts){const i=this.lanPlayers.indexOf(data.id);if(i<0)continue;const k=this.karts[i];k.previous.copy(k.renderPosition);k.previousYaw=k.model?.root.rotation.y??k.yaw;
      const {id,position,velocity,...state}=data;Object.assign(k,state);k.position.fromArray(position);k.body.setTranslation(k.position,true);k.body.setLinvel({x:velocity[0],y:velocity[1],z:velocity[2]},true);k.projection=this.track.project(k.position);
    }
    this.race.elapsed=s.elapsed;this.race.countdown=s.countdown;this.race.goFlash=s.goFlash;this.race.state=s.phase==='results'?'finished':s.phase==='countdown'?'countdown':'racing';
    s.boxes.forEach((cooldown,i)=>{const b=this.items.boxes[i];if(b?.mesh)b.mesh.visible=cooldown===0;});
    for(const o of this.items.pool)if(o.mesh)o.mesh.visible=false;
    for(const o of s.items){const mesh=this.items.pool[o.index]?.mesh;if(mesh){mesh.visible=true;mesh.position.fromArray(o.position);mesh.children.forEach(c=>c.visible=c.name===o.kind);mesh.rotation.y=this.time*7;}}
    if(s.phase==='results'){const k=this.karts[0];this.hud.result(this.race,k,false,false);this.hud.set('#result-subtitle','局域网多人竞技 · 服务器最终成绩');if(this.mode!=='arena')this.hud.set('#result-time',k.finished?`${k.finishTime.toFixed(3)} 秒`:'未完赛');this.hud.set('#save-status',this.mode==='arena'?'道具命中对手 +1 分 · 同分并列 · 掉线车手退出排名竞争':'首位冲线后 60 秒结算 · 掉线或超时记为未完赛');this.hud.set('#again-btn',this.lan.room?.host===this.lan.you?'返回房间，再跑一场':'等待房主开启下一场');this.hud.sync('finished');}
  }
  private renderGhost(){if(!this.ghost||this.ghostFrames.length<2)return;const t=this.race.elapsed;while(this.ghostIndex<this.ghostFrames.length-2&&this.ghostFrames[this.ghostIndex+1].t<t)this.ghostIndex++;const a=this.ghostFrames[this.ghostIndex],b=this.ghostFrames[this.ghostIndex+1];this.ghost.root.visible=t<=this.ghostFrames.at(-1)!.t&&this.race.state!=='menu';const f=THREE.MathUtils.clamp((t-a.t)/(b.t-a.t),0,1);this.ghost.root.position.set(THREE.MathUtils.lerp(a.x,b.x,f),THREE.MathUtils.lerp(a.y,b.y,f),THREE.MathUtils.lerp(a.z,b.z,f));this.ghost.root.rotation.y=a.yaw+Math.atan2(Math.sin(b.yaw-a.yaw),Math.cos(b.yaw-a.yaw))*f;this.ghost.body.rotation.z=a.action&1?-.1:0;this.ghost.front.forEach(w=>w.rotation.y=0);}
  run(){this.last=performance.now();requestAnimationFrame(this.frame);}
  private frame=(now:number)=>{if(!this.running)return;requestAnimationFrame(this.frame);const delta=Math.min((now-this.last)/1000,.1);this.last=now;if(document.hidden)return;
    this.fps=THREE.MathUtils.damp(this.fps,1/Math.max(.001,delta),2,delta);const c=this.input.poll();if(c.pause)this.togglePause();if(c.camera){this.chase.far=!this.chase.far;this.hud.toast(this.chase.far?'竞速镜头 · 远':'RC 镜头 · 贴地');}
    for(const key of ['jump','item1','item2','reset','discard'] as const)c[key] ||=this.controls[key];this.controls=c;
    const alpha=this.debugManual?1:this.fixed.advance(delta,dt=>this.step(dt));for(const k of this.karts){k.render(this.lan.active?Math.min(1,(performance.now()-this.snapshotAt)/50):alpha,delta,this.time);if(this.race.state==='menu'&&k.model)k.model.root.visible=k.id===0;}this.renderGhost();
    if(this.race.state==='menu'){
      const k=this.karts[0],s=this.track.at(k.projection.t),sway=Math.sin(now*.00012)*.35;this.menuPosition.copy(k.position).addScaledVector(s.tangent,5.8).addScaledVector(s.right,6.3+sway);this.menuPosition.y+=3.0;this.menuTarget.copy(k.position).addScaledVector(s.right,-2.15);this.menuTarget.y+=.4;this.camera.position.lerp(this.menuPosition,1-Math.exp(-delta*3));this.camera.lookAt(this.menuTarget);this.camera.fov=48;this.camera.updateProjectionMatrix();
      for(const b of this.items.boxes)if(b.mesh)b.mesh.rotation.y+=delta*.45;
    }else if(this.race.state!=='paused')this.chase.update(this.karts[0],delta,this.time);
    this.updateShadow();this.renderer.render(this.scene,this.camera);this.audio.update(this.karts[0].speed,this.lastInput.throttle,this.karts[0].drift,this.race.state==='racing');
    this.uiTimer+=delta;if(this.uiTimer>=.1){this.hud.update(this.race,this.karts[0],this.uiTimer,this.track,this.input.gamepadName,this.fps);this.uiTimer=0;}
    this.performanceTimer+=delta;if(this.performanceTimer>5){this.performanceTimer=0;const target=matchMedia('(pointer: coarse)').matches?28:48;if(this.fps<target&&this.dynamicScale>.65){this.dynamicScale=Math.max(.65,this.dynamicScale-.1);this.resize();}else if(this.fps>target+9&&this.dynamicScale<1){this.dynamicScale=Math.min(1,this.dynamicScale+.05);this.resize();}}
  };
  private exposeDebug(){const g=this;let guide:AIDriver|undefined,probe:THREE.PerspectiveCamera|undefined;Object.assign(window,{__PTK__:{
    beginScreenProbe:()=>{const k=g.karts[0],f=new THREE.Vector3(Math.sin(k.yaw),0,Math.cos(k.yaw));probe=new THREE.PerspectiveCamera(64,16/9,.1,100);probe.position.copy(k.position).addScaledVector(f,-6.1);probe.position.y+=1.65;const look=k.position.clone().addScaledVector(f,7);look.y+=.9;probe.lookAt(look);probe.updateMatrixWorld(true);return k.position.clone().project(probe).x;},
    screenX:()=>probe?g.karts[0].position.clone().project(probe).x:NaN,
    suggest:()=>{if(guide?.kart!==g.karts[0])guide=new AIDriver(g.karts[0],-1);return {...guide.update(1/60,g.karts[0].progress,g.items)};},
    advanceInput:(steps:number)=>{for(let i=0;i<steps;i++){const c=g.input.poll();for(const key of ['jump','item1','item2','reset','discard'] as const)c[key] ||=g.controls[key];g.controls=c;g.step(1/60);}return g.snapshot();},
    start:(mode:Mode='quick',kart=0)=>g.start(mode,kart),manual:(v:boolean)=>{g.debugManual=v;},autopilot:(v:boolean)=>{g.auto=v?new AIDriver(g.karts[0],-1):undefined;},
    advance:(steps:number)=>{for(let i=0;i<steps;i++)g.step(1/60);return g.snapshot();},snapshot:()=>g.snapshot(),
    give:(kind:ItemKind,slot=0)=>{g.karts[0].slots[slot]=kind;},use:(slot=0,back=false)=>g.items.use(g.karts[0],slot,back),
    control:(c:Partial<Controls>)=>{g.controls={...emptyControls(),...c};},reset:()=>{g.karts[0].reset();},
    teleport:(t:number)=>g.karts[0].spawn(t,0),
    records:()=>g.records.data,view:()=>({camera:g.camera.position.toArray(),target:g.menuTarget.toArray(),karts:g.karts.map(k=>({id:k.id,visible:k.model?.root.visible,position:k.model?.root.position.toArray(),yaw:k.yaw,invulnerable:k.invulnerable})),time:g.time}),
    renderer:()=>({calls:g.renderer.info.render.calls,triangles:g.renderer.info.render.triangles,geometries:g.renderer.info.memory.geometries,textures:g.renderer.info.memory.textures,pixelRatio:g.renderer.getPixelRatio()}),
  }});}
  private snapshot(){return {mode:this.mode,arena:this.track.arena,state:this.race.state,elapsed:this.race.elapsed,karts:this.karts.map(k=>({id:k.id,score:k.score,hitsTaken:k.hitsTaken,lap:k.lap,cp:k.lastCheckpoint,next:k.nextCheckpoint,t:k.projection.t,progress:k.progress,rank:k.rank,speed:k.speed,yaw:k.yaw,steering:k.steering,grounded:k.grounded,finished:k.finished,time:k.finishTime,boost:k.boost,drift:k.drift,charge:k.driftCharge,stun:k.stun,slots:k.slots,position:{x:k.position.x,y:k.position.y,z:k.position.z},distance:k.projection.distance,air:k.airTime})),ghostFrames:this.ghostFrames.length,activeItems:this.items.pool.filter(o=>o.active).length};}
}
