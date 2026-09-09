import * as THREE from 'three';
import RAPIER from '@dimforge/rapier3d-compat';
import { buildArena } from './Arena';
import { ARENA_RADIUS } from '../config/arena';
import { CHECKPOINTS } from '../config/game';
export interface TrackSample {p:THREE.Vector3;tangent:THREE.Vector3;right:THREE.Vector3;bank:number;t:number}
export interface Projection {t:number;distance:number;lateral:number;height:number;sample:TrackSample;shortcut?:boolean}
const UP=new THREE.Vector3(0,1,0);
export class Track {
  readonly count=512;readonly halfWidth:number=7.8;readonly curve:THREE.CatmullRomCurve3;readonly length:number;
  samples:TrackSample[]=[];group=new THREE.Group();surfaceHandles=new Set<number>();sceneryMeshes:{mesh:THREE.InstancedMesh;max:number}[]=[];
  boostTs=[.065,.46,.79];boxTs=[.025,.235,.425,.65,.895];
  obstacles:{body:RAPIER.RigidBody;mesh:THREE.Group;t:number;phase:number}[]=[];
  shortcut:{a:THREE.Vector3;b:THREE.Vector3;start:number;end:number};
  private obstaclePosition=new THREE.Vector3();
  constructor(public world:RAPIER.World,scene?:THREE.Scene,public arena=false){
    this.curve=new THREE.CatmullRomCurve3([[0,0,60],[58,1,58],[102,4,28],[105,6,-22],[73,8,-66],[18,3,-83],[-31,0,-60],[-77,2,-77],[-111,5,-40],[-111,3,8],[-75,0,48],[-31,0,40]].map(p=>new THREE.Vector3(...p as [number,number,number])),true,'catmullrom',.45);
    if(arena)this.halfWidth=ARENA_RADIUS;
    this.curve.arcLengthDivisions=2048;this.curve.updateArcLengths();this.length=this.curve.getLength();
    for(let i=0;i<=this.count;i++)this.samples.push(this.calculate(i/this.count));
    this.shortcut={a:this.at(.485).p.clone(),b:this.at(.635).p.clone(),start:.485,end:.635};
    if(arena){this.boostTs=[];this.boxTs=Array.from({length:8},(_,i)=>i/8+1/16);buildArena(world,this.group,this.surfaceHandles,!!scene);if(scene)scene.add(this.group);return;}
    this.buildSurface();if(scene)scene.add(this.group);this.buildVisuals(!!scene);if(scene)this.buildScenery();this.buildObstacles(!!scene);
  }
  private calculate(t:number):TrackSample {
    if(this.arena){const angle=t*Math.PI*2;const p=new THREE.Vector3(Math.sin(angle)*28,0,Math.cos(angle)*28),tangent=p.clone().negate().normalize();return {p,tangent,right:new THREE.Vector3(tangent.z,0,-tangent.x),bank:0,t};}
    const u=((t%1)+1)%1,p=this.curve.getPointAt(u),tangent=this.curve.getTangentAt(u).normalize();
    // A physical takeoff ramp: its crest drops back to the road; there is no artificial flight animation.
    if(u>.123&&u<.148)p.y+=3.1*(u-.123)/.025;
    const bank=Math.sin(u*Math.PI*6)*.035+(u>.27&&u<.39?Math.sin((u-.27)/.12*Math.PI)*.16:0);
    const right=new THREE.Vector3(tangent.z,0,-tangent.x).normalize();
    return {p,tangent,right,bank,t:u};
  }
  at(t:number):TrackSample {return this.calculate(t);}
  point(t:number,lane=0){const s=this.at(t);return s.p.addScaledVector(s.right,lane).addScaledVector(UP,lane*s.bank);}
  project(p:{x:number;y:number;z:number},mainOnly=false):Projection {
    if(this.arena){const t=(Math.atan2(p.x,p.z)/(Math.PI*2)+1)%1,s=this.at(t);return {t,distance:Math.max(Math.abs(p.x),Math.abs(p.z)),lateral:0,height:0,sample:s};}
    let best=Infinity,index=0,fraction=0,lateral=0;
    for(let i=0;i<this.count;i++){
      const a=this.samples[i].p,b=this.samples[i+1].p,dx=b.x-a.x,dz=b.z-a.z;
      const f=THREE.MathUtils.clamp(((p.x-a.x)*dx+(p.z-a.z)*dz)/(dx*dx+dz*dz),0,1);
      const x=a.x+dx*f,z=a.z+dz*f,d=(p.x-x)**2+(p.z-z)**2;
      if(d<best){best=d;index=i;fraction=f;lateral=((p.x-x)*dz-(p.z-z)*dx)/Math.hypot(dx,dz);}
    }
    const t=(index+fraction)/this.count,s=this.at(t);
    if(this.shortcut&&!mainOnly){const {a,b,start,end}=this.shortcut,dx=b.x-a.x,dz=b.z-a.z,den=dx*dx+dz*dz;
      const f=THREE.MathUtils.clamp(((p.x-a.x)*dx+(p.z-a.z)*dz)/den,0,1),cx=a.x+dx*f,cz=a.z+dz*f,d=Math.hypot(p.x-cx,p.z-cz);
      if(d<2.5&&d*d<best&&f>0&&f<1){const u=start+(end-start)*f,height=s.p.y+lateral*s.bank+.07,tangent=new THREE.Vector3(dx,b.y-a.y,dz).normalize(),right=new THREE.Vector3(dz,0,-dx).normalize();return {t:u,distance:d,lateral:(p.x-cx)*right.x+(p.z-cz)*right.z,height,sample:{t:u,p:new THREE.Vector3(cx,height,cz),tangent,right,bank:0},shortcut:true};}
    }
    return {t:t%1,distance:Math.sqrt(best),lateral,height:s.p.y+lateral*s.bank,sample:s};
  }
  legal(p:Projection,y?:number){return p.distance<(p.shortcut?2.7:this.halfWidth+4)&&(y===undefined||y>p.height-.7&&y<p.height+9);}
  private buildSurface(){
    const vertices:number[]=[],indices:number[]=[],colors:number[]=[];
    const c=new THREE.Color();
    for(let i=0;i<=this.count;i++){
      const s=this.samples[i];for(const side of [-1,1]){const p=s.p.clone().addScaledVector(s.right,side*this.halfWidth);p.y+=side*this.halfWidth*s.bank;
        vertices.push(p.x,p.y,p.z);c.set(i%32<16?0xdcb987:0xd8b582);colors.push(c.r,c.g,c.b);
      }
      if(i<this.count){const a=i*2;indices.push(a,a+2,a+1,a+1,a+2,a+3);}
    }
    const geometry=new THREE.BufferGeometry();geometry.setAttribute('position',new THREE.Float32BufferAttribute(vertices,3));geometry.setAttribute('color',new THREE.Float32BufferAttribute(colors,3));geometry.setIndex(indices);geometry.computeVertexNormals();
    const road=new THREE.Mesh(geometry,new THREE.MeshStandardMaterial({vertexColors:true,roughness:.92,side:THREE.DoubleSide}));road.receiveShadow=true;this.group.add(road);
    const skirt:number[]=[],si:number[]=[];for(let i=0;i<this.count;i++)for(const side of [0,1]){const a=i*6+side*3,b=(i+1)*6+side*3,n=skirt.length/3;skirt.push(vertices[a],vertices[a+1],vertices[a+2],vertices[b],vertices[b+1],vertices[b+2],vertices[a],vertices[a+1]-1.1,vertices[a+2],vertices[b],vertices[b+1]-1.1,vertices[b+2]);si.push(n,n+1,n+2,n+2,n+1,n+3);}
    const deck=new THREE.BufferGeometry();deck.setAttribute('position',new THREE.Float32BufferAttribute(skirt,3));deck.setIndex(si);deck.computeVertexNormals();const edge=new THREE.Mesh(deck,new THREE.MeshStandardMaterial({color:0xb6926f,roughness:1,side:THREE.DoubleSide}));edge.receiveShadow=true;edge.castShadow=true;this.group.add(edge);
    const body=this.world.createRigidBody(RAPIER.RigidBodyDesc.fixed());const col=this.world.createCollider(RAPIER.ColliderDesc.trimesh(new Float32Array(vertices),new Uint32Array(indices)).setFriction(.1),body);this.surfaceHandles.add(col.handle);
    // A narrow, unguarded chord saves about 12% over the winding main segment.
    // It interpolates the SAME sequential checkpoint progress; it does not skip checkpoints.
    const a=this.shortcut.a,b=this.shortcut.b,d=b.clone().sub(a),right=new THREE.Vector3(d.z,0,-d.x).normalize();
    const sv:number[]=[],sis:number[]=[];for(let i=0;i<=64;i++){const p=a.clone().lerp(b,i/64);for(const sign of [-1,1]){const v=p.clone().addScaledVector(right,sign*2.5);v.y=this.project(v,true).height+.055;sv.push(v.x,v.y,v.z);}if(i<64){const n=i*2;sis.push(n,n+2,n+1,n+1,n+2,n+3);}}
    const sg=new THREE.BufferGeometry();sg.setAttribute('position',new THREE.Float32BufferAttribute(sv,3));sg.setIndex(sis);sg.computeVertexNormals();
    const sm=new THREE.Mesh(sg,new THREE.MeshStandardMaterial({color:0xc99361,roughness:1,side:THREE.DoubleSide}));sm.receiveShadow=true;this.group.add(sm);
    const sc=this.world.createCollider(RAPIER.ColliderDesc.trimesh(new Float32Array(sv),new Uint32Array(sis)),body);this.surfaceHandles.add(sc.handle);
    const floor=this.world.createCollider(RAPIER.ColliderDesc.cuboid(350,.5,350).setTranslation(0,-3.5,0).setFriction(.6),body);this.surfaceHandles.add(floor.handle);
  }
  private buildVisuals(visual:boolean){
    const dummy=new THREE.Object3D(),railGeo=new THREE.BoxGeometry(.32,.65,1),railMat=new THREE.MeshStandardMaterial({color:0xeff4d4,roughness:.65});
    const rails=new THREE.InstancedMesh(railGeo,railMat,256),curbs=new THREE.InstancedMesh(new THREE.BoxGeometry(.85,.18,1),new THREE.MeshStandardMaterial({color:0xe67965}),512);
    const body=this.world.createRigidBody(RAPIER.RigidBodyDesc.fixed());let r=0;
    for(let i=0;i<128;i++)for(const side of [-1,1]){
      const t=(i+.5)/128,s=this.at(t),next=this.at((i+1)/128),prev=this.at(i/128),len=next.p.distanceTo(prev.p)+.15;
      dummy.position.copy(s.p).addScaledVector(s.right,side*(this.halfWidth+.3));dummy.position.y+=side*(this.halfWidth+.3)*s.bank+.4;dummy.rotation.set(0,Math.atan2(s.tangent.x,s.tangent.z),0);dummy.scale.set(1,1,len);dummy.updateMatrix();rails.setMatrixAt(r++,dummy.matrix);
      const sa=this.shortcut.a,sb=this.shortcut.b,dx=sb.x-sa.x,dz=sb.z-sa.z,f=THREE.MathUtils.clamp(((dummy.position.x-sa.x)*dx+(dummy.position.z-sa.z)*dz)/(dx*dx+dz*dz),0,1);
      const shortcutGap=Math.hypot(dummy.position.x-sa.x-dx*f,dummy.position.z-sa.z-dz*f)<4.8;
      if(shortcutGap){dummy.scale.set(0,0,0);dummy.updateMatrix();rails.setMatrixAt(r-1,dummy.matrix);}else this.world.createCollider(RAPIER.ColliderDesc.cuboid(.22,.65,len/2).setTranslation(dummy.position.x,dummy.position.y,dummy.position.z).setRotation({x:0,y:Math.sin(dummy.rotation.y/2),z:0,w:Math.cos(dummy.rotation.y/2)}).setRestitution(.2).setFriction(.05),body);
    }
    rails.castShadow=true;rails.receiveShadow=true;this.group.add(rails);
    if(!visual)return;
    const supports=new THREE.InstancedMesh(new THREE.CylinderGeometry(.5,.8,1,7),new THREE.MeshStandardMaterial({color:0xd4c39b,roughness:.9}),64);let pi=0;
    for(let i=0;i<32;i++)for(const side of [-1,1]){const s=this.at(i/32),height=Math.max(.1,s.p.y+1.9+side*6.6*s.bank);dummy.position.copy(s.p).addScaledVector(s.right,side*6.6);dummy.position.y=-3+height/2;dummy.rotation.set(0,0,0);dummy.scale.set(1,height,1);dummy.updateMatrix();supports.setMatrixAt(pi++,dummy.matrix);}supports.receiveShadow=true;this.group.add(supports);
    let ci=0;for(let i=0;i<256;i++)for(const side of [-1,1]){const s=this.at((i+.5)/256);dummy.position.copy(s.p).addScaledVector(s.right,side*7.4);dummy.position.y+=side*7.4*s.bank+.09;dummy.rotation.set(0,Math.atan2(s.tangent.x,s.tangent.z),0);dummy.scale.set(1,1,this.length/256*.65);dummy.updateMatrix();curbs.setMatrixAt(ci++,dummy.matrix);if(i%2)curbs.setColorAt(ci-1,new THREE.Color(0xfff6d8));}curbs.receiveShadow=true;this.group.add(curbs);
    const ground=new THREE.Mesh(new THREE.PlaneGeometry(700,700),new THREE.MeshStandardMaterial({color:0x80b9a0,roughness:1}));ground.rotation.x=-Math.PI/2;ground.position.y=-2.98;ground.receiveShadow=true;this.group.add(ground);
    const start=this.at(0),gate=new THREE.Group();gate.position.copy(start.p);gate.rotation.y=Math.atan2(start.tangent.x,start.tangent.z);
    const mat=new THREE.MeshStandardMaterial({color:0x296761,roughness:.5}),cream=new THREE.MeshStandardMaterial({color:0xffefc6});
    for(const x of [-8.6,8.6]){this.box(gate,[.7,7,.7],[x,3.5,0],mat);this.box(gate,[1.6,.6,1.6],[x,.3,0],cream);const ball=new THREE.Mesh(new THREE.SphereGeometry(.6,12,8),new THREE.MeshStandardMaterial({color:0xf7c86d,metalness:.4,roughness:.4}));ball.position.set(x,7.2,0);gate.add(ball);}
    this.box(gate,[18,1.5,.65],[0,6.4,0],mat);this.textSign(gate,'POCKET TURBO',new THREE.Vector3(0,6.4,-.36),10.6,1.18);
    for(let x=0;x<16;x++)for(let z=0;z<3;z++){this.box(gate,[.96,.025,.8],[x-7.5,.04,z*.8],new THREE.MeshStandardMaterial({color:(x+z)%2?0x304f4d:0xfff3d4}));}
    this.group.add(gate);
    for(const t of this.boostTs){const s=this.at(t),g=new THREE.Group();g.position.copy(s.p);g.position.y+=.06;g.rotation.set(0,Math.atan2(s.tangent.x,s.tangent.z),s.bank);
      this.box(g,[9,.05,4],[0,0,0],new THREE.MeshStandardMaterial({color:0x386f66,roughness:.45}));
      for(let j=-1;j<=1;j++)for(const sign of [-1,1]){const m=new THREE.Mesh(new THREE.BoxGeometry(1.4,.07,.35),new THREE.MeshStandardMaterial({color:0xcaff72,emissive:0x9de854,emissiveIntensity:1.2}));m.position.set(sign*.47,.08,j*1.05);m.rotation.y=sign*-.65;g.add(m);}this.group.add(g);
    }
    for(const [t,label] of [[.11,'HOP!'],[.477,'RISK / SHORTCUT'],[.34,'DRIFT'],[.54,'TICK · TOCK']] as const){const s=this.at(t),g=new THREE.Group();g.position.copy(s.p).addScaledVector(s.right,-10);g.rotation.y=Math.atan2(s.tangent.x,s.tangent.z);this.box(g,[.25,3,.25],[0,1.5,0],mat);this.box(g,[4,1.1,.15],[0,3,0],cream);this.textSign(g,label,new THREE.Vector3(0,3,-.1),3.8,.8, '#285c56');this.group.add(g);}
  }
  private box(parent:THREE.Object3D,size:number[],pos:number[],mat:THREE.Material){const m=new THREE.Mesh(new THREE.BoxGeometry(...size as [number,number,number]),mat);m.position.set(...pos as [number,number,number]);m.castShadow=true;m.receiveShadow=true;parent.add(m);return m;}
  private textSign(parent:THREE.Object3D,text:string,p:THREE.Vector3,w:number,h:number,color='#fff1ca'){
    const canvas=document.createElement('canvas');canvas.width=1024;canvas.height=128;const ctx=canvas.getContext('2d')!;ctx.fillStyle=color;ctx.font='900 80px sans-serif';ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText(text,512,67);const tex=new THREE.CanvasTexture(canvas);tex.colorSpace=THREE.SRGBColorSpace;
    const m=new THREE.Mesh(new THREE.PlaneGeometry(w,h),new THREE.MeshBasicMaterial({map:tex,transparent:true,side:THREE.DoubleSide}));m.position.copy(p);m.rotation.y=Math.PI;parent.add(m);
  }
  private buildScenery(){
    let seed=721;const rand=()=>{seed=(seed*1664525+1013904223)>>>0;return seed/4294967296;};
    const dummy=new THREE.Object3D(),stemMat=new THREE.MeshStandardMaterial({color:0xffe6b7,roughness:.8}),capMat=new THREE.MeshStandardMaterial({color:0xe9918c,roughness:.55});
    const stems=new THREE.InstancedMesh(new THREE.CylinderGeometry(.42,.75,1,7),stemMat,130),caps=new THREE.InstancedMesh(new THREE.SphereGeometry(1,14,8,0,Math.PI*2,0,Math.PI*.6),capMat,130),spots=new THREE.InstancedMesh(new THREE.SphereGeometry(1,7,5),new THREE.MeshStandardMaterial({color:0xffedcc}),390);
    let n=0;while(n<130){const x=(rand()-.5)*310,z=(rand()-.5)*255,p=this.project({x,y:0,z});if(p.distance<13)continue;const h=3+rand()*11,base=-3;dummy.position.set(x,base+h/2,z);dummy.rotation.set(0,0,0);dummy.scale.set(h*.22,h,h*.22);dummy.updateMatrix();stems.setMatrixAt(n,dummy.matrix);
      dummy.position.y=base+h;dummy.scale.set(h*.58,h*.3,h*.58);dummy.updateMatrix();caps.setMatrixAt(n,dummy.matrix);caps.setColorAt(n,new THREE.Color().setHSL(.015+rand()*.11,.53,.66));
      for(let j=0;j<3;j++){const ang=rand()*Math.PI*2,rad=h*.28;dummy.position.set(x+Math.cos(ang)*rad,base+h+h*.24,z+Math.sin(ang)*rad);dummy.scale.set(h*.095,h*.035,h*.1);dummy.updateMatrix();spots.setMatrixAt(n*3+j,dummy.matrix);}n++;
    }stems.castShadow=true;caps.castShadow=true;this.group.add(stems,caps,spots);this.sceneryMeshes.push({mesh:stems,max:130},{mesh:caps,max:130},{mesh:spots,max:390});
    const trees=new THREE.InstancedMesh(new THREE.IcosahedronGeometry(1,1),new THREE.MeshStandardMaterial({color:0x4f9981,roughness:1,flatShading:true}),110);
    for(let i=0;i<110;i++){let x=(rand()-.5)*400,z=(rand()-.5)*320;const p=this.project({x,y:0,z});if(p.distance<17){x+=p.sample.right.x*25;z+=p.sample.right.z*25;}const h=4+rand()*8;dummy.position.set(x,h*.4-3,z);dummy.rotation.set(0,rand()*6,0);dummy.scale.set(h*.5,h,h*.5);dummy.updateMatrix();trees.setMatrixAt(i,dummy.matrix);trees.setColorAt(i,new THREE.Color().setHSL(.40+rand()*.09,.28,.38+rand()*.18));}this.group.add(trees);this.sceneryMeshes.push({mesh:trees,max:110});
    const hillMat=new THREE.MeshStandardMaterial({color:0x7cafad,roughness:1,flatShading:true});for(let i=0;i<22;i++){const a=i/22*Math.PI*2,mesh=new THREE.Mesh(new THREE.IcosahedronGeometry(1,2),hillMat);mesh.position.set(Math.cos(a)*(240+rand()*50),-7,Math.sin(a)*(205+rand()*50));mesh.scale.set(40+rand()*35,25+rand()*65,45);this.group.add(mesh);}
    const castle=new THREE.Group();castle.position.set(0,-3,-133);const wall=new THREE.MeshStandardMaterial({color:0xf5d9b1,roughness:.8}),roof=new THREE.MeshStandardMaterial({color:0x608d94,metalness:.12,roughness:.6});this.box(castle,[32,16,14],[0,8,0],wall);
    for(const x of [-19,0,19]){const h=x===0?31:23,tower=new THREE.Mesh(new THREE.CylinderGeometry(4,4.8,h,10),wall);tower.position.set(x,h/2,0);tower.castShadow=true;castle.add(tower);const cone=new THREE.Mesh(new THREE.ConeGeometry(6,9,10),roof);cone.position.set(x,h+4,0);cone.castShadow=true;castle.add(cone);for(let j=0;j<3;j++)this.box(castle,[1.2,2,.25],[x,h-4-j*5,4.05],new THREE.MeshStandardMaterial({color:0x497e80}));this.box(castle,[.15,5,.15],[x,h+10,0],wall);this.box(castle,[3,1.6,.12],[x+1.5,h+11,0],new THREE.MeshStandardMaterial({color:0xf0ae62}));}const castleLOD=new THREE.LOD();castleLOD.position.copy(castle.position);castle.position.set(0,0,0);castleLOD.addLevel(castle,0);const distant=new THREE.Group();this.box(distant,[34,17,14],[0,8,0],wall);for(const x of [-19,0,19]){const h=x===0?31:23;this.box(distant,[7,h,7],[x,h/2,0],wall);const cap=new THREE.Mesh(new THREE.ConeGeometry(6,9,6),roof);cap.position.set(x,h+4,0);distant.add(cap);}castleLOD.addLevel(distant,195);this.group.add(castleLOD);
    // Distant cloud clusters are actual low-poly volumes, not sky billboards.
    const clouds=new THREE.InstancedMesh(new THREE.SphereGeometry(1,9,6),new THREE.MeshStandardMaterial({color:0xfff6df,roughness:1}),72);
    for(let i=0;i<72;i++){const cluster=Math.floor(i/3),a=cluster/24*Math.PI*2;dummy.position.set(Math.cos(a)*260+(i%3)*9,66+Math.sin(cluster*4)*15,Math.sin(a)*240);dummy.rotation.set(0,0,0);dummy.scale.set(13,5+(i%3)*2,8);dummy.updateMatrix();clouds.setMatrixAt(i,dummy.matrix);}this.group.add(clouds);
    const grass=new THREE.InstancedMesh(new THREE.ConeGeometry(.35,1.3,4),new THREE.MeshStandardMaterial({color:0xb2cb83,roughness:1}),700);
    for(let i=0;i<700;i++){const s=this.at(rand()),side=rand()>.5?1:-1;dummy.position.copy(s.p).addScaledVector(s.right,side*(9+rand()*5));dummy.position.y=-2.4;dummy.rotation.set(0,rand()*6,0);dummy.scale.setScalar(.7+rand());dummy.updateMatrix();grass.setMatrixAt(i,dummy.matrix);}this.group.add(grass);this.sceneryMeshes.push({mesh:grass,max:700});
  }
  setSceneryDensity(ratio:number){for(const {mesh,max} of this.sceneryMeshes)mesh.count=Math.floor(max*ratio);}
  private buildObstacles(visual:boolean){
    for(const [index,t] of [.565,.85].entries()){
      const s=this.at(t),mesh=new THREE.Group();if(visual){const mat=new THREE.MeshStandardMaterial({color:0xeaa652,metalness:.5,roughness:.4});const ball=new THREE.Mesh(new THREE.IcosahedronGeometry(1.2,1),mat);ball.castShadow=true;mesh.add(ball);for(let i=0;i<8;i++){const tooth=new THREE.Mesh(new THREE.BoxGeometry(.6,.6,.7),mat),a=i/8*Math.PI*2;tooth.position.set(Math.cos(a)*1.1,Math.sin(a)*1.1,0);tooth.rotation.z=a;mesh.add(tooth);}const arch=new THREE.Group();arch.position.copy(s.p);arch.rotation.y=Math.atan2(s.tangent.x,s.tangent.z);const dark=new THREE.MeshStandardMaterial({color:0x44736c});for(const x of [-9,9])this.box(arch,[.45,7,.45],[x,3.5,0],dark);this.box(arch,[18.5,.4,.4],[0,7,0],mat);this.group.add(arch,mesh);}
      const body=this.world.createRigidBody(RAPIER.RigidBodyDesc.kinematicPositionBased().setTranslation(s.p.x,s.p.y+1,s.p.z));this.world.createCollider(RAPIER.ColliderDesc.ball(1.25).setRestitution(.6),body);this.obstacles.push({body,mesh,t,phase:index*2});
    }
  }
  update(dt:number,time:number){for(const o of this.obstacles){const s=this.at(o.t),lane=Math.sin(time*1.05+o.phase)*6;this.obstaclePosition.copy(s.p).addScaledVector(s.right,lane);this.obstaclePosition.y+=1.3+Math.abs(Math.cos(time*1.05+o.phase))*.2;o.body.setNextKinematicTranslation(this.obstaclePosition);o.mesh.position.copy(this.obstaclePosition);o.mesh.rotation.z+=dt*1.5;}}
  checkpoint(index:number,lane=0){return this.point((index%CHECKPOINTS)/CHECKPOINTS,lane);}
}
