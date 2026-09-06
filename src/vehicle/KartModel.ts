import * as THREE from 'three';
import type { KartSpec } from '../config/game';
const box=new THREE.BoxGeometry(1,1,1),sphere=new THREE.SphereGeometry(1,14,10),cylinder=new THREE.CylinderGeometry(1,1,1,14),tireGeo=new THREE.CylinderGeometry(.43,.43,.34,16);
export interface KartModel {root:THREE.Group;body:THREE.Group;wheels:THREE.Group[];front:THREE.Group[];antenna:THREE.Mesh;flames:THREE.Mesh[]}
export function makeKart(spec:KartSpec,ghost=false):KartModel {
  const root=new THREE.Group(),body=new THREE.Group();root.add(body);
  const material=(color:number,roughness=.45,metalness=0)=>new THREE.MeshStandardMaterial({color,roughness,metalness,transparent:ghost,opacity:ghost?.28:1,depthWrite:!ghost});
  const shell=material(spec.color,.3,.18),accent=material(spec.accent,.5),dark=material(0x263d43,.8),rubber=material(0x202c32,.96),chrome=material(0xc8d7cc,.3,.65),skin=material(0xf5d6a1,.9);
  const add=(parent:THREE.Object3D,geo:THREE.BufferGeometry,mat:THREE.Material,p:number[],s:number[])=>{const mesh=new THREE.Mesh(geo,mat);mesh.position.set(...p as [number,number,number]);mesh.scale.set(...s as [number,number,number]);mesh.castShadow=!ghost;mesh.receiveShadow=!ghost;parent.add(mesh);return mesh;};
  add(body,box,dark,[0,-.18,0],[1.22,.22,2.25]);add(body,sphere,shell,[0,.05,.3],[.78,.38,1.06]);add(body,box,shell,[0,.06,.92],[1.26,.3,.58]);
  add(body,box,accent,[0,.26,.77],[.27,.05,.82]);add(body,box,chrome,[0,-.05,1.36],[1.62,.14,.16]);add(body,box,dark,[0,-.12,-1.24],[1.55,.2,.22]);
  for(const x of [-.57,.57]){add(body,box,dark,[x,.37,-.98],[.08,.6,.09]);add(body,sphere,accent,[x,.18,1.16],[.16,.1,.1]);for(const z of [.5,-.7])add(body,cylinder,chrome,[x,.32,z],[.045,.035,.045]);}
  add(body,box,shell,[0,.68,-1.03],[1.65,.13,.45]);add(body,box,accent,[0,.755,-1.03],[.6,.022,.39]);
  add(body,sphere,dark,[0,.42,-.22],[.43,.6,.46]);add(body,sphere,accent,[0,.67,-.13],[.34,.44,.28]);
  add(body,sphere,skin,[0,1.15,-.03],[.38,.35,.34]);add(body,sphere,shell,[0,1.31,-.07],[.44,.27,.4]);
  if(spec.id==='pip'){add(body,sphere,accent,[.08,1.52,-.1],[.15,.08,.15]);add(body,box,shell,[0,1.23,.28],[.62,.075,.2]);}
  if(spec.id==='lumi'){for(const x of [-.22,.22]){const ear=add(body,new THREE.ConeGeometry(.14,.48,5),accent,[x,1.65,-.05],[1,1,1]);ear.rotation.z=-x;}}
  if(spec.id==='brass'){add(body,box,chrome,[0,1.48,0],[.15,.2,.7]);}
  if(spec.id==='wisp'){const hat=add(body,new THREE.ConeGeometry(.36,.64,5),shell,[.1,1.67,-.13],[1,1,1]);hat.rotation.z=-.35;}
  for(const x of [-.17,.17]){add(body,sphere,chrome,[x,1.17,.28],[.15,.13,.07]);add(body,sphere,dark,[x,1.17,.34],[.1,.09,.025]);const arm=add(body,cylinder,accent,[x*2.1,.64,.27],[.10,.44,.10]);arm.rotation.x=-.8;}
  const steering=add(body,new THREE.TorusGeometry(.22,.04,6,14),dark,[0,.63,.53],[1,1,1]);steering.rotation.x=-.55;
  const antenna=add(body,cylinder,dark,[.52,.8,-.67],[.025,1.4,.025]);add(body,sphere,accent,[.52,1.52,-.67],[.07,.07,.07]);
  const wheels:THREE.Group[]=[],front:THREE.Group[]=[];
  for(const z of [.78,-.77])for(const x of [-.85,.85]){
    add(body,cylinder,chrome,[x*.6,-.22,z],[.06,.68,.06]).rotation.z=Math.PI/2;
    // Visible suspension springs and independent wheel mounts.
    const spring=add(body,new THREE.TorusGeometry(.095,.025,5,9),chrome,[x*.71,-.08,z],[1,1,1]);spring.rotation.x=Math.PI/2;
    const mount=new THREE.Group();mount.position.set(x,-.31,z);root.add(mount);if(z>0)front.push(mount);
    const wheel=new THREE.Group();mount.add(wheel);add(wheel,tireGeo,rubber,[0,0,0],[1,1,1]).rotation.z=Math.PI/2;
    const hub=add(wheel,cylinder,accent,[Math.sign(x)*.18,0,0],[.235,.06,.235]);hub.rotation.z=Math.PI/2;
    const screw=add(wheel,cylinder,chrome,[Math.sign(x)*.218,0,0],[.07,.075,.07]);screw.rotation.z=Math.PI/2;
    for(let i=0;i<8;i++){const a=i/8*Math.PI*2;const tread=add(wheel,box,dark,[0,Math.cos(a)*.425,Math.sin(a)*.425],[.355,.035,.085]);tread.rotation.x=a;}wheels.push(wheel);
  }
  const flameMat=new THREE.MeshStandardMaterial({color:0xcfff8c,emissive:0x8cff68,emissiveIntensity:2,transparent:true,opacity:ghost?0:.85});
  const flames:THREE.Mesh[]=[];for(const x of [-.44,.44]){add(body,cylinder,chrome,[x,-.03,-1.23],[.14,.34,.14]).rotation.x=Math.PI/2;const flame=add(body,new THREE.ConeGeometry(.18,1,7),flameMat,[x,0,-1.8],[1,1,1]);flame.rotation.x=-Math.PI/2;flame.visible=false;flames.push(flame);}
  return {root,body,wheels,front,antenna,flames};
}
