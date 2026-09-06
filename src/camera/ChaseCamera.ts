import * as THREE from 'three';
import RAPIER from '@dimforge/rapier3d-compat';
import type { KartPhysics } from '../vehicle/KartPhysics';
export class ChaseCamera {
  far=false;shake=0;private initialized=false;private target=new THREE.Vector3();private desired=new THREE.Vector3();private look=new THREE.Vector3();private smoothLook=new THREE.Vector3();private direction=new THREE.Vector3();private ray=new RAPIER.Ray({x:0,y:0,z:0},{x:0,y:0,z:1});
  constructor(public camera:THREE.PerspectiveCamera,private world:RAPIER.World){}
  reset(){this.initialized=false;this.shake=0;}
  update(k:KartPhysics,dt:number,time:number){
    const forwardX=Math.sin(k.yaw),forwardZ=Math.cos(k.yaw),speed=Math.max(0,k.speed),distance=this.far?9.3:6.1;
    this.target.copy(k.renderPosition);this.desired.copy(this.target);this.desired.x-=forwardX*distance;this.desired.z-=forwardZ*distance;this.desired.y+=(this.far?3.4:1.65)+(k.grounded?0:.3);
    if(k.drift){this.desired.x-=forwardZ*k.steering*.65;this.desired.z+=forwardX*k.steering*.65;}
    this.look.copy(this.target);this.look.x+=forwardX*(this.far?5:7);this.look.z+=forwardZ*(this.far?5:7);this.look.y+=.9;
    const terrain=k.track.project(this.desired);if(terrain.distance<10)this.desired.y=Math.max(this.desired.y,terrain.height+.6);else this.desired.y=Math.max(this.desired.y,-1.8);
    this.direction.subVectors(this.desired,this.target);const len=this.direction.length();this.direction.divideScalar(len);this.ray.origin=this.target;this.ray.dir=this.direction;
    const hit=this.world.castRay(this.ray,len,true,RAPIER.QueryFilterFlags.EXCLUDE_DYNAMIC|RAPIER.QueryFilterFlags.EXCLUDE_SENSORS,undefined,undefined,k.body);
    if(hit)this.desired.copy(this.target).addScaledVector(this.direction,Math.max(.8,hit.timeOfImpact-.35));
    if(!this.initialized){this.camera.position.copy(this.desired);this.smoothLook.copy(this.look);this.initialized=true;}
    const follow=k.grounded?9:4;this.camera.position.lerp(this.desired,1-Math.exp(-follow*dt));this.smoothLook.lerp(this.look,1-Math.exp(-11*dt));
    this.shake=Math.max(this.shake,k.impact*.15);this.shake=Math.max(0,this.shake-dt*.9);const shake=Math.min(.13,this.shake+(k.boost>0?.018:0));this.camera.position.x+=Math.sin(time*63)*shake;this.camera.position.y+=Math.sin(time*79)*shake*.55;
    // A second ray checks the smoothed position: damping must not pull the camera back through a wall.
    this.direction.subVectors(this.camera.position,this.target);const smoothLen=this.direction.length();if(smoothLen>.1){this.direction.divideScalar(smoothLen);this.ray.dir=this.direction;const block=this.world.castRay(this.ray,smoothLen,true,RAPIER.QueryFilterFlags.EXCLUDE_DYNAMIC|RAPIER.QueryFilterFlags.EXCLUDE_SENSORS,undefined,undefined,k.body);if(block)this.camera.position.copy(this.target).addScaledVector(this.direction,Math.max(.55,block.timeOfImpact-.25));}
    this.camera.position.y=Math.max(-2.3,this.camera.position.y);this.camera.lookAt(this.smoothLook);this.camera.fov=THREE.MathUtils.damp(this.camera.fov,64+Math.min(15,speed*.34)+(k.boost>0?3:0),4,dt);this.camera.updateProjectionMatrix();
  }
}
