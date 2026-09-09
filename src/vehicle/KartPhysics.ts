import * as THREE from 'three';
import RAPIER from '@dimforge/rapier3d-compat';
import { Track, type Projection } from '../track/Track';
import type { KartSpec, ItemKind } from '../config/game';
import type { Controls } from '../input/InputManager';
import { makeKart, type KartModel } from './KartModel';
const wrap=(a:number)=>Math.atan2(Math.sin(a),Math.cos(a));
export class KartPhysics {
  driverName?:string;score=0;hitsTaken=0;disconnected=false;arenaResetCooldown=0;
  body:RAPIER.RigidBody;collider:RAPIER.Collider;model?:KartModel;
  position=new THREE.Vector3();previous=new THREE.Vector3();renderPosition=new THREE.Vector3();yaw=0;previousYaw=0;speed=0;
  grounded=false;wasGrounded=false;groundNormal=new THREE.Vector3(0,1,0);projection:Projection;
  drift=false;driftCharge=0;driftLevel=0;boost=0;stun=0;invulnerable=0;jumpCooldown=0;airTime=0;trick=false;
  offTrackTime=0;stuckTime=0;needsReset=false;landed=0;releasedBoost=0;impact=0;steering=0;wheelSpin=0;
  slots:(ItemKind|null)[]=[null,null];rolling=[0,0];pending:(ItemKind|null)[]=[null,null];itemCooldown=0;boostPadCooldown=0;
  rank=1;finished=false;finishTime=0;lap=0;nextCheckpoint=1;lastCheckpoint=0;lastT=0;progress=0;lapStart=0;lapTimes:number[]=[];
  private forward=new THREE.Vector3();private localX=new THREE.Vector3();private velocity=new THREE.Vector3();private normal=new THREE.Vector3();private rotation=new THREE.Quaternion();
  private ray=new RAPIER.Ray({x:0,y:0,z:0},{x:0,y:-1,z:0});private wheels=[[-.7,.75],[.7,.75],[-.7,-.75],[.7,-.75]];
  wheelHeight=[0,0,0,0];
  constructor(public id:number,public spec:KartSpec,public world:RAPIER.World,public track:Track,scene?:THREE.Scene){
    this.body=world.createRigidBody(RAPIER.RigidBodyDesc.dynamic().setCanSleep(false).setLinearDamping(.05).setAngularDamping(8).enabledRotations(false,false,false).setCcdEnabled(true));
    this.collider=world.createCollider(RAPIER.ColliderDesc.cuboid(.65,.23,1.05).setMass(spec.mass).setFriction(.05).setRestitution(.15).setActiveEvents(RAPIER.ActiveEvents.COLLISION_EVENTS),this.body);
    if(scene){this.model=makeKart(spec);scene.add(this.model.root);}this.projection=track.project({x:0,y:0,z:0});
    this.spawn(track.arena?id/4+.125:-.009-Math.floor(id/2)*.009,track.arena?0:id%2?2.3:-2.3);this.lastT=this.projection.t;
  }
  spawn(t:number,lane=0){const s=this.track.at(t);this.position.copy(s.p).addScaledVector(s.right,lane);this.position.y+=.85+lane*s.bank;this.yaw=Math.atan2(s.tangent.x,s.tangent.z);this.previousYaw=this.yaw;this.previous.copy(this.position);this.body.setTranslation(this.position,true);this.rotation.setFromAxisAngle(THREE.Object3D.DEFAULT_UP,this.yaw);this.body.setRotation(this.rotation,true);this.body.setLinvel({x:0,y:0,z:0},true);this.body.setAngvel({x:0,y:0,z:0},true);this.drift=false;this.driftCharge=0;this.driftLevel=0;this.stun=0;this.boost=0;this.offTrackTime=0;this.stuckTime=0;this.needsReset=false;this.invulnerable=1.6;this.projection=this.track.project(this.position);this.lastT=this.projection.t;this.airTime=0;this.trick=false;}
  reset(){if(this.track.arena){if(this.arenaResetCooldown>0&&!this.needsReset)return;this.spawn(this.id/4+.125,0);this.arenaResetCooldown=8;}else this.spawn(this.lastCheckpoint/16+.001,this.id%2?1.5:-1.5);}
  preStep(dt:number,input:Controls,enabled=true){
    this.previous.copy(this.position);this.previousYaw=this.yaw;this.landed=0;this.releasedBoost=0;this.impact=Math.max(0,this.impact-dt*2);
    for(const key of ['arenaResetCooldown','boost','stun','invulnerable','jumpCooldown','itemCooldown','boostPadCooldown'] as const)this[key]=Math.max(0,this[key]-dt);
    for(let i=0;i<2;i++)if(this.rolling[i]>0){this.rolling[i]=Math.max(0,this.rolling[i]-dt);if(!this.rolling[i]){this.slots[i]=this.pending[i];this.pending[i]=null;}}
    this.forward.set(Math.sin(this.yaw),0,Math.cos(this.yaw));this.localX.set(this.forward.z,0,-this.forward.x);
    const vel=this.body.linvel();this.velocity.set(vel.x,vel.y,vel.z);this.speed=this.velocity.dot(this.forward);this.wasGrounded=this.grounded;this.grounded=false;this.normal.set(0,0,0);let contacts=0;
    for(let i=0;i<4;i++){
      const [x,z]=this.wheels[i],rx=this.position.x+this.localX.x*x+this.forward.x*z,rz=this.position.z+this.localX.z*x+this.forward.z*z;
      this.ray.origin.x=rx;this.ray.origin.y=this.position.y+.45;this.ray.origin.z=rz;
      const hit=this.world.castRayAndGetNormal(this.ray,1.55,true,undefined,undefined,undefined,this.body,c=>this.track.surfaceHandles.has(c.handle));
      if(hit){const height=hit.timeOfImpact-.45;this.wheelHeight[i]=THREE.MathUtils.clamp(.78-height,-.25,.3);
        if(height<1.07){contacts++;this.normal.x+=hit.normal.x;this.normal.y+=hit.normal.y;this.normal.z+=hit.normal.z;const spring=Math.max(-100,Math.min(1900,this.spec.mass*9.81/4+(.78-height)*2400-this.velocity.y*175));this.body.applyImpulse({x:0,y:spring*dt,z:0},true);}
      }else this.wheelHeight[i]=-.24;
    }
    if(contacts>=2){this.grounded=true;this.groundNormal.copy(this.normal.normalize());if(!this.wasGrounded&&this.airTime>.15){this.landed=Math.min(1,Math.abs(vel.y)/9);if(this.trick){this.boost=Math.max(this.boost,.8);this.trick=false;}}this.airTime=0;}else this.airTime+=dt;
    if(!enabled){const y=this.body.linvel().y;this.body.setLinvel({x:0,y,z:0},true);return;}
    this.steering=THREE.MathUtils.damp(this.steering,input.steer,10,dt);
    if(input.jump&&this.jumpCooldown===0){if(this.grounded){this.body.applyImpulse({x:0,y:this.spec.mass*6.4,z:0},true);this.grounded=false;this.jumpCooldown=.65;}else if(this.airTime>.12){this.trick=true;this.jumpCooldown=.5;}}
    const canDrift=input.drift&&Math.abs(this.speed)>8&&this.stun<=0;
    if(canDrift&&!this.drift&&Math.abs(input.steer)>.12&&this.grounded){this.drift=true;this.driftCharge=0;this.body.applyImpulse({x:0,y:this.spec.mass*1.5,z:0},true);}
    if(this.drift){if(canDrift){if(this.grounded&&Math.abs(input.steer)>.12)this.driftCharge=Math.min(3.2,this.driftCharge+dt*(.65+Math.abs(input.steer)*.5));this.driftLevel=this.driftCharge>2.4?3:this.driftCharge>1.35?2:this.driftCharge>.55?1:0;}
      else{if(this.driftLevel&&this.stun<=0){this.releasedBoost=this.driftLevel;this.boost=Math.max(this.boost,(.35+this.driftLevel*.38)*this.spec.drift);}this.drift=false;this.driftCharge=0;this.driftLevel=0;}}
    const steerScale=(.32+.68*Math.min(1,Math.abs(this.speed)/12))/(1+Math.max(0,Math.abs(this.speed)-20)*.027);
    // Chassis forward is local +Z; a chase camera looking +Z sees world -X as RIGHT.
    // Positive input therefore needs a NEGATIVE right-handed Y rotation.
    this.yaw-=this.steering*this.spec.turn*steerScale*(this.drift?1.32:1)*(this.grounded?1:.35)*(this.speed<-.5?-1:1)*dt*(this.stun>0?.3:1);
    if(this.stun>0)this.yaw+=Math.sin(this.stun*19)*dt*2.5;
    this.rotation.setFromAxisAngle(THREE.Object3D.DEFAULT_UP,this.yaw);this.body.setRotation(this.rotation,true);
    const offroad=this.projection.distance>(this.projection.shortcut?2.5:this.track.halfWidth);const top=this.spec.speed*(this.boost>0?1.4:1)*(offroad?.58:1);
    let acceleration=input.throttle*this.spec.accel*(this.boost>0?1.65:1)*(this.stun>0?.12:1);
    if(input.brake>.05)acceleration-=input.brake*(this.speed>1?32:11);acceleration-=this.speed*.2+Math.sign(this.speed)*.45;
    if(this.speed>top)acceleration-=Math.min(60,(this.speed-top)*9);if(this.speed< -8)acceleration+=(-8-this.speed)*12;
    const grip=this.stun>0?1.0:this.drift?2.3*this.spec.drift:11;
    const lateral=this.velocity.dot(this.localX)*Math.exp(-grip*dt*(this.grounded?1:.035));
    let fwd=this.speed+acceleration*dt*(this.grounded?1:.18);if(!input.throttle&&!input.brake&&Math.abs(fwd)<.08)fwd=0;
    const y=this.body.linvel().y;
    this.body.setLinvel({x:this.forward.x*fwd+this.localX.x*lateral,y,z:this.forward.z*fwd+this.localX.z*lateral},true);
    if(this.grounded&&this.boostPadCooldown===0&&this.projection.distance<5&&this.track.boostTs.some(t=>Math.abs(t-this.projection.t)*this.track.length<2.1)){this.boost=1.25;this.boostPadCooldown=2;}
  }
  postStep(dt:number){const p=this.body.translation();this.position.set(p.x,p.y,p.z);this.projection=this.track.project(this.position);const v=this.body.linvel();this.speed=v.x*Math.sin(this.yaw)+v.z*Math.cos(this.yaw);
    this.offTrackTime=this.projection.distance>this.track.halfWidth+5||this.position.y<this.projection.height-1.8?this.offTrackTime+dt:0;
    const q=this.body.rotation(),up=1-2*(q.x*q.x+q.z*q.z);if(p.y< -8||this.offTrackTime>2.2||up<.15)this.needsReset=true;
    if(this.airTime>4)this.needsReset=true;
  }
  hit(strength=1){if(this.invulnerable>0)return false;this.stun=Math.min(1.5,strength*.95*105/this.spec.mass);this.boost=0;this.drift=false;this.driftCharge=0;this.driftLevel=0;this.invulnerable=1.8;const v=this.body.linvel();this.body.setLinvel({x:v.x*.48,y:Math.max(v.y,3.2*strength),z:v.z*.48},true);this.impact=.6;return true;}
  render(alpha:number,dt:number,time:number){if(!this.model)return;const m=this.model;this.renderPosition.lerpVectors(this.previous,this.position,alpha);m.root.position.copy(this.renderPosition);m.root.rotation.y=this.previousYaw+wrap(this.yaw-this.previousYaw)*alpha;
    const slope=this.grounded?Math.atan2(this.groundNormal.x*Math.sin(this.yaw)+this.groundNormal.z*Math.cos(this.yaw),Math.max(.1,this.groundNormal.y)):THREE.MathUtils.clamp(-this.body.linvel().y*.025,-.22,.22);
    m.body.rotation.x=THREE.MathUtils.damp(m.body.rotation.x,slope+(this.landed>0?.1:0),10,dt);
    const roll=-this.steering*Math.min(Math.abs(this.speed)/30,1)*(this.drift?.13:.075)+(this.grounded?this.projection.sample.bank:0);
    m.body.rotation.z=THREE.MathUtils.damp(m.body.rotation.z,roll,8,dt);m.body.position.y=Math.sin(time*22)*Math.min(Math.abs(this.speed)*.001,.025);
    if(this.trick&&!this.grounded)m.body.rotation.z+=Math.sin(this.airTime*6)*.28;
    this.wheelSpin+=this.speed*dt/.43;m.wheels.forEach((wheel,i)=>{wheel.rotation.x=this.wheelSpin;wheel.parent!.position.y=-.31+this.wheelHeight[i]*.75;});m.front.forEach(w=>w.rotation.y=-this.steering*.4);m.antenna.rotation.z=Math.sin(time*13)*this.speed*.0015;
    m.flames.forEach(f=>{f.visible=this.boost>0;f.scale.y=.8+Math.sin(time*58)*.25;});m.root.visible=this.invulnerable<=0||Math.sin(time*28)>-.6;
  }
}
