export interface Controls {throttle:number;brake:number;steer:number;drift:boolean;jump:boolean;item1:boolean;item2:boolean;reset:boolean;pause:boolean;camera:boolean;discard:boolean;backward:boolean}
export const emptyControls=():Controls=>({throttle:0,brake:0,steer:0,drift:false,jump:false,item1:false,item2:false,reset:false,pause:false,camera:false,discard:false,backward:false});
const editable=(target:EventTarget|null)=>target instanceof Element&&!!target.closest('input,textarea,select,[contenteditable="true"],[data-selectable]');
const blocked=['ArrowUp','ArrowDown','ArrowLeft','ArrowRight','Space','ShiftLeft','ShiftRight'];
export class InputManager {
  keys=new Set<string>(); private pressed=new Set<string>(); private padPrev:boolean[]=[];
  private touches=new Map<number,string>();private touchEdges=new Set<string>();private joyId=-1;private joyX=0;
  gamepadName='';
  constructor(private root:HTMLElement){
    for(const name of ['contextmenu','selectstart','dragstart'])root.addEventListener(name,e=>{if(!editable(e.target))e.preventDefault();});
    root.addEventListener('focusin',e=>{if(editable(e.target))this.clear();});
    window.addEventListener('keydown',e=>{if(editable(e.target))return;if(blocked.includes(e.code))e.preventDefault();if(!this.keys.has(e.code))this.pressed.add(e.code);this.keys.add(e.code);});
    window.addEventListener('keyup',e=>this.keys.delete(e.code));
    window.addEventListener('blur',()=>this.clear());
    root.addEventListener('pointerdown',e=>{
      const target=(e.target as HTMLElement).closest<HTMLElement>('[data-control]');
      if(target){e.preventDefault();const action=target.dataset.control!;target.setPointerCapture(e.pointerId);this.touches.set(e.pointerId,action);this.touchEdges.add(action);target.classList.add('held');if(action==='steer'){this.joyId=e.pointerId;this.updateJoy(e,target);}}
      else if((e.target as HTMLElement).tagName==='CANVAS'&&e.button===0)this.pressed.add('KeyE');
    });
    root.addEventListener('pointermove',e=>{if(e.pointerId===this.joyId){const target=root.querySelector<HTMLElement>('[data-control="steer"]')!;this.updateJoy(e,target);}});
    const release=(e:PointerEvent)=>{const action=this.touches.get(e.pointerId);this.touches.delete(e.pointerId);if(![...this.touches.values()].includes(action!))root.querySelector(`[data-control="${action}"]`)?.classList.remove('held');if(e.pointerId===this.joyId){this.joyX=0;this.joyId=-1;root.style.setProperty('--stick-x','0px');}};
    root.addEventListener('pointerup',release);root.addEventListener('pointercancel',release);root.addEventListener('lostpointercapture',release);
  }
  private updateJoy(e:PointerEvent,target:HTMLElement){const r=target.getBoundingClientRect();this.joyX=Math.max(-1,Math.min(1,(e.clientX-r.left-r.width/2)/(r.width*.35)));this.root.style.setProperty('--stick-x',`${this.joyX*34}px`);}
  clear(){this.keys.clear();this.pressed.clear();this.touches.clear();this.touchEdges.clear();this.joyX=0;this.joyId=-1;this.root.querySelectorAll('.held').forEach(el=>el.classList.remove('held'));}
  poll():Controls {
    const c=emptyControls(), held=(...ks:string[])=>ks.some(k=>this.keys.has(k)), edge=(...ks:string[])=>ks.some(k=>this.pressed.has(k));
    const touch=(s:string)=>[...this.touches.values()].includes(s), te=(s:string)=>this.touchEdges.has(s);
    c.throttle=held('KeyW','ArrowUp')||touch('throttle')?1:0;c.brake=held('KeyS','ArrowDown')||touch('brake')?1:0;
    c.steer=(held('KeyD','ArrowRight')?1:0)-(held('KeyA','ArrowLeft')?1:0)+this.joyX;
    c.drift=held('ShiftLeft','ShiftRight')||touch('drift');c.jump=edge('Space')||te('jump');
    c.item1=edge('KeyE')||te('item1');c.item2=edge('KeyQ')||te('item2');c.reset=edge('KeyR')||te('reset');c.pause=edge('Escape')||te('pause');c.camera=edge('KeyC')||te('camera');c.discard=edge('Delete');
    const pads=navigator.getGamepads?.()??[],pad=Array.from(pads).find(p=>p?.connected);
    if(pad){this.gamepadName=pad.id;const b=pad.buttons.map(b=>b.pressed),pe=(i:number)=>!!b[i]&&!this.padPrev[i];
      const x=pad.axes[0]??0;c.steer+=Math.abs(x)>0.16?(Math.abs(x)-.16)/.84*Math.sign(x):0;
      c.throttle=Math.max(c.throttle,(pad.buttons[7]?.value??0)>.08?pad.buttons[7].value:0);c.brake=Math.max(c.brake,(pad.buttons[6]?.value??0)>.08?pad.buttons[6].value:0);
      c.jump ||=pe(0);c.item1 ||=pe(2)||pe(5);c.item2 ||=pe(4);c.reset ||=pe(1);c.pause ||=pe(9);c.camera ||=pe(3);c.drift ||=!!b[10];this.padPrev=b;
    }else{this.gamepadName='';this.padPrev=[];}
    c.steer=Math.max(-1,Math.min(1,c.steer));c.backward=c.brake>.4;this.pressed.clear();this.touchEdges.clear();return c;
  }
}
