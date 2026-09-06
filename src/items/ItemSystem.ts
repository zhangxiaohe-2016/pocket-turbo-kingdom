import * as THREE from 'three';
import RAPIER from '@dimforge/rapier3d-compat';
import { ITEMS,type ItemKind,type Mode } from '../config/game';
import type { KartPhysics } from '../vehicle/KartPhysics';
import type { Track } from '../track/Track';
export function itemWeights(rank:number,count:number):number[]{const behind=count<=1?0:(rank-1)/(count-1);return [.15+.20*behind,.48-.31*behind,.29-.10*behind,.08+.21*behind];}
export function pickItem(rank:number,count:number,random:number):ItemKind {const kinds:ItemKind[]=['battery','peel','gear','firefly'],w=itemWeights(rank,count),sum=w.reduce((a,b)=>a+b,0);let n=random*sum;for(let i=0;i<w.length;i++){n-=w[i];if(n<=0)return kinds[i];}return 'firefly';}
export interface ItemObject {active:boolean;kind:ItemKind;owner:number;age:number;life:number;bounces:number;target:number;position:THREE.Vector3;previous:THREE.Vector3;velocity:THREE.Vector3;mesh?:THREE.Group;body:RAPIER.RigidBody;collider:RAPIER.Collider}
export class ItemSystem {
  pool:ItemObject[]=[];boxes:{position:THREE.Vector3;cooldown:number;mesh?:THREE.Group}[]=[];private seed=32901;
  onEvent:(name:string,kart?:KartPhysics)=>void=()=>{};private ray=new RAPIER.Ray({x:0,y:0,z:0},{x:0,y:0,z:1});private dir=new THREE.Vector3();private delta=new THREE.Vector3();
  constructor(public track:Track,public karts:KartPhysics[],public mode:Mode,scene?:THREE.Scene){
    for(const t of track.boxTs)for(const lane of [-4,0,4]){const position=track.point(t,lane);position.y+=1.2;let mesh:THREE.Group|undefined;
      if(scene){mesh=new THREE.Group();const cube=new THREE.Mesh(new THREE.BoxGeometry(1.35,1.35,1.35),new THREE.MeshStandardMaterial({color:0xb7fbe0,emissive:0x4e957b,emissiveIntensity:.35,metalness:.3,roughness:.23,transparent:true,opacity:.86}));cube.castShadow=true;mesh.add(cube);
        const edges=new THREE.LineSegments(new THREE.EdgesGeometry(cube.geometry),new THREE.LineBasicMaterial({color:0xfff5c2}));mesh.add(edges);
        const gem=new THREE.Mesh(new THREE.OctahedronGeometry(.35),new THREE.MeshStandardMaterial({color:0xffeeaf,emissive:0xffd365,emissiveIntensity:1.3}));mesh.add(gem);scene.add(mesh);mesh.position.copy(position);
      }this.boxes.push({position,cooldown:0,mesh});
    }
    const gearGeo=new THREE.TorusGeometry(.45,.15,7,12),peelGeo=new THREE.ConeGeometry(.55,.7,5),fireGeo=new THREE.IcosahedronGeometry(.36,1);
    const mats={peel:new THREE.MeshStandardMaterial({color:ITEMS.peel.color,roughness:.5}),gear:new THREE.MeshStandardMaterial({color:ITEMS.gear.color,metalness:.65,roughness:.3}),firefly:new THREE.MeshStandardMaterial({color:ITEMS.firefly.color,emissive:0xff5896,emissiveIntensity:2})};
    for(let i=0;i<36;i++){
      let mesh:THREE.Group|undefined;if(scene){mesh=new THREE.Group();for(const [name,geo] of [['peel',peelGeo],['gear',gearGeo],['firefly',fireGeo]] as const){const m=new THREE.Mesh(geo,mats[name]);m.name=name;m.castShadow=true;mesh.add(m);}mesh.visible=false;scene.add(mesh);}
      const body=track.world.createRigidBody(RAPIER.RigidBodyDesc.kinematicPositionBased().setTranslation(0,-100,0));const collider=track.world.createCollider(RAPIER.ColliderDesc.ball(.45).setSensor(true),body);collider.setEnabled(false);
      this.pool.push({active:false,kind:'peel',owner:0,age:0,life:0,bounces:0,target:-1,position:new THREE.Vector3(),previous:new THREE.Vector3(),velocity:new THREE.Vector3(),mesh,body,collider});
    }
  }
  private random(){this.seed=(Math.imul(this.seed,1664525)+1013904223)>>>0;return this.seed/4294967296;}
  use(k:KartPhysics,slot:number,backward=false){
    const kind=k.slots[slot];if(!kind||k.itemCooldown>0||k.finished)return false;
    if(kind==='battery'){k.boost=Math.max(k.boost,2.25);k.slots[slot]=null;k.itemCooldown=.35;this.onEvent('boost',k);return true;}
    const o=this.pool.find(o=>!o.active);if(!o)return false;
    k.slots[slot]=null;k.itemCooldown=.4;o.active=true;o.kind=kind;o.owner=k.id;o.life=kind==='peel'?16:7;o.age=0;o.bounces=0;o.target=-1;
    const sign=backward?-1:1;this.dir.set(Math.sin(k.yaw)*sign,0,Math.cos(k.yaw)*sign);
    o.position.copy(k.position).addScaledVector(this.dir,kind==='peel'?(backward?2.4:3):2.2);o.position.y=k.projection.height+(kind==='peel'?.36:.9);o.previous.copy(o.position);o.velocity.copy(this.dir).multiplyScalar(kind==='peel'?0:kind==='gear'?40:34);
    if(kind==='firefly'){let best=60;for(const other of this.karts){if(other===k||other.finished)continue;this.delta.subVectors(other.position,k.position);const dist=this.delta.length();if(dist<best&&this.delta.dot(this.dir)>dist*.28){o.target=other.id;best=dist;}}}
    o.body.setTranslation(o.position,true);o.collider.setEnabled(true);if(o.mesh){o.mesh.visible=true;o.mesh.position.copy(o.position);o.mesh.children.forEach(m=>m.visible=m.name===kind);}this.onEvent('throw',k);return true;
  }
  discard(k:KartPhysics){if(k.itemCooldown>0)return;k.slots[k.slots[0]?0:1]=null;k.itemCooldown=.3;}
  deactivate(o:ItemObject){o.active=false;o.collider.setEnabled(false);if(o.mesh)o.mesh.visible=false;}
  update(dt:number,time:number,pickups=true){
    for(const b of this.boxes){b.cooldown=Math.max(0,b.cooldown-dt);if(b.mesh){b.mesh.visible=b.cooldown===0;b.mesh.rotation.set(time*.38,time*.9,.14);b.mesh.position.y=b.position.y+Math.sin(time*2+b.position.x)*.17;}
      if(!pickups||b.cooldown>0)continue;for(const k of this.karts){if(k.finished||k.position.distanceToSquared(b.position)>3.6)continue;const slot=k.slots.findIndex((v,i)=>!v&&!k.pending[i]);if(slot<0)continue;
        k.pending[slot]=this.mode==='time'?'battery':pickItem(k.rank,this.karts.length,this.random());k.rolling[slot]=.85;b.cooldown=6;this.onEvent('pickup',k);break;}
    }
    for(const o of this.pool){if(!o.active)continue;o.age+=dt;o.life-=dt;if(o.life<=0){this.deactivate(o);continue;}o.previous.copy(o.position);
      if(o.kind==='firefly'&&o.target>=0){const target=this.karts.find(k=>k.id===o.target&&!k.finished);if(target){this.dir.subVectors(target.position,o.position);this.dir.y=0;this.dir.normalize().multiplyScalar(34);o.velocity.lerp(this.dir,1-Math.exp(-dt*2.5));o.velocity.normalize().multiplyScalar(34);}else o.target=-1;}
      o.position.addScaledVector(o.velocity,dt);const p=this.track.project(o.position);o.position.y=p.height+(o.kind==='peel'?.38:.9);
      if(o.kind!=='peel'){
        this.dir.subVectors(o.position,o.previous);const length=this.dir.length();if(length>0){this.dir.divideScalar(length);this.ray.origin=o.previous;this.ray.dir=this.dir;
          const hit=this.track.world.castRayAndGetNormal(this.ray,length+.25,true,RAPIER.QueryFilterFlags.EXCLUDE_DYNAMIC|RAPIER.QueryFilterFlags.EXCLUDE_SENSORS,undefined,undefined,o.body,c=>!this.track.surfaceHandles.has(c.handle));
          if(hit||p.distance>this.track.halfWidth){if(o.kind==='gear'&&o.bounces===0){this.dir.set(hit?.normal.x??p.sample.right.x,0,hit?.normal.z??p.sample.right.z).normalize();o.velocity.reflect(this.dir);o.position.copy(o.previous);o.bounces++;}else{this.deactivate(o);continue;}}
        }
      }
      for(const k of this.karts){if(k.finished||k.id===o.owner&&o.age<.9)continue;
        this.dir.subVectors(o.position,o.previous);const len=this.dir.lengthSq();this.delta.subVectors(k.position,o.previous);const f=len?THREE.MathUtils.clamp(this.delta.dot(this.dir)/len,0,1):0;this.dir.multiplyScalar(f).add(o.previous);
        if(this.dir.distanceToSquared(k.position)<(o.kind==='peel'?1.65:2.4)){if(k.hit(o.kind==='firefly'?1.15:1)){this.onEvent('hit',k);this.deactivate(o);break;}}
      }
      if(o.active){o.body.setNextKinematicTranslation(o.position);if(o.mesh){o.mesh.position.copy(o.position);o.mesh.rotation.y+=dt*7;o.mesh.rotation.z=o.kind==='gear'?Math.PI/2:0;}}
    }
  }
  dispose(scene:THREE.Scene){for(const b of this.boxes)if(b.mesh)scene.remove(b.mesh);for(const o of this.pool){if(o.mesh)scene.remove(o.mesh);this.track.world.removeRigidBody(o.body);}}
}
