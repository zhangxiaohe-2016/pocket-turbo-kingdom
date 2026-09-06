import { emptyControls,type Controls } from '../input/InputManager';
import type { KartPhysics } from '../vehicle/KartPhysics';
import type { ItemSystem } from '../items/ItemSystem';
export class AIDriver {
  controls:Controls=emptyControls();private timer=0;private useTimer=2;private stuck=0;
  constructor(public kart:KartPhysics,private lane:number){}
  update(dt:number,leaderProgress:number,items?:ItemSystem):Controls {
    const k=this.kart,p=k.projection;if(k.finished)return emptyControls();this.timer+=dt;this.useTimer-=dt;
    const look=7+Math.abs(k.speed)*.36;let lane=this.lane+Math.sin(this.timer*.38+k.id)*.7;
    for(const obstacle of k.track.obstacles){let ahead=obstacle.t-p.t;if(ahead<0)ahead+=1;if(ahead*k.track.length<22){const pos=obstacle.body.translation(),s=k.track.at(obstacle.t),side=(pos.x-s.p.x)*s.right.x+(pos.z-s.p.z)*s.right.z;lane=side>0?-4:4;}}
    if(items)for(const obj of items.pool){if(!obj.active||obj.kind!=='peel')continue;const dx=obj.position.x-k.position.x,dz=obj.position.z-k.position.z;if(dx*dx+dz*dz<225&&dx*Math.sin(k.yaw)+dz*Math.cos(k.yaw)>0)lane=(dx*Math.cos(k.yaw)-dz*Math.sin(k.yaw))>0?-4:4;}
    const target=k.track.point(p.t+look/k.track.length,lane),angle=Math.atan2(target.x-k.position.x,target.z-k.position.z),error=Math.atan2(Math.sin(angle-k.yaw),Math.cos(angle-k.yaw));
    const tangent=k.track.at(p.t+18/k.track.length).tangent,now=p.sample.tangent;
    const curvature=Math.acos(Math.max(-1,Math.min(1,now.dot(tangent))));
    const rubber=Math.max(.95,Math.min(1.055,1+(leaderProgress-k.progress)*.04));
    const targetSpeed=Math.max(12,k.spec.speed*.87-curvature*15)*rubber;
    const c=this.controls;c.steer=Math.max(-1,Math.min(1,-error*1.9));c.throttle=k.speed<targetSpeed?1:.12;c.brake=k.speed>targetSpeed+2?.48:0;c.drift=Math.abs(error)>.36&&Math.abs(error)<.85&&k.speed>15&&curvature>.25;c.jump=false;c.item1=false;c.item2=false;c.backward=false;
    if(this.useTimer<0){c.item1=!!k.slots[0];c.item2=!c.item1&&!!k.slots[1];c.backward=k.slots[0]==='peel';this.useTimer=2.5+k.id*.45;}
    this.stuck=Math.abs(k.speed)<2?this.stuck+dt:0;if(this.stuck>3.5||Math.abs(error)>2.7&&Math.abs(k.speed)<4){k.needsReset=true;this.stuck=0;}return c;
  }
}
