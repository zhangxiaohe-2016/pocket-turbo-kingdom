import * as THREE from 'three';
import type { KartPhysics } from '../vehicle/KartPhysics';
interface Particle {life:number;max:number;x:number;y:number;z:number;vx:number;vy:number;vz:number;size:number;color:THREE.Color}
export class Effects {
  mesh:THREE.InstancedMesh;private particles:Particle[]=[];private cursor=0;private dummy=new THREE.Object3D();private emission=0;limit:number;
  constructor(scene:THREE.Scene,count=180){this.limit=count;this.mesh=new THREE.InstancedMesh(new THREE.IcosahedronGeometry(1,0),new THREE.MeshStandardMaterial({roughness:1,transparent:true,opacity:.72,depthWrite:false}),180);this.mesh.frustumCulled=false;for(let i=0;i<180;i++){this.particles.push({life:0,max:1,x:0,y:-100,z:0,vx:0,vy:0,vz:0,size:0,color:new THREE.Color()});this.dummy.scale.setScalar(0);this.dummy.updateMatrix();this.mesh.setMatrixAt(i,this.dummy.matrix);}scene.add(this.mesh);}
  emit(x:number,y:number,z:number,color:number,count=1,power=1){for(let i=0;i<count;i++){const p=this.particles[this.cursor++%this.limit];p.life=p.max=.35+Math.random()*.5;p.x=x;p.y=y;p.z=z;p.vx=(Math.random()-.5)*3*power;p.vy=Math.random()*2*power;p.vz=(Math.random()-.5)*3*power;p.size=.08+Math.random()*.15;p.color.set(color);}}
  step(dt:number,karts:KartPhysics[]){this.emission+=dt;const emit=this.emission>1/30;if(emit)this.emission=0;
    for(const k of karts){if(k.landed>.1)this.emit(k.position.x,k.position.y-.55,k.position.z,0xffecc1,12,k.landed*2);if(emit&&(k.drift||k.boost>0||k.projection.distance>7.8)&&k.grounded&&Math.abs(k.speed)>5){const color=k.boost>0?0xc3ff87:k.driftLevel===3?0xfa8ccc:k.driftLevel===2?0xffc35c:k.driftLevel===1?0x9aeaff:0xdce6d0;this.emit(k.position.x-Math.sin(k.yaw),k.position.y-.5,k.position.z-Math.cos(k.yaw),color,k.boost>0?3:2);}}
    for(let i=0;i<this.particles.length;i++){const p=this.particles[i];if(p.life>0){p.life-=dt;p.x+=p.vx*dt;p.y+=p.vy*dt;p.z+=p.vz*dt;p.vy-=dt*2;this.dummy.position.set(p.x,p.y,p.z);this.dummy.scale.setScalar(Math.max(0,p.life/p.max)*p.size*(2-p.life/p.max));this.mesh.setColorAt(i,p.color);}else this.dummy.scale.setScalar(0);this.dummy.updateMatrix();this.mesh.setMatrixAt(i,this.dummy.matrix);}this.mesh.instanceMatrix.needsUpdate=true;if(this.mesh.instanceColor)this.mesh.instanceColor.needsUpdate=true;
  }
}
