import './style.css';
import { HUD } from './ui/HUD';
import { Records } from './storage/Records';
const records=new Records(),hud=new HUD(document.querySelector('#app')!,records);
async function boot(){try{hud.loading(12,'加载 Three.js 与本地物理模块…');const [{Game},{default:RAPIER}]=await Promise.all([import('./core/Game'),import('@dimforge/rapier3d-compat')]);hud.loading(43,'初始化 Rapier WASM 物理世界…');await RAPIER.init();hud.loading(68,'铺设赛道，组装口袋赛车…');await new Promise(resolve=>requestAnimationFrame(resolve));const game=new Game(hud,records);hud.loading(95,'准备悬挂、着色器与起跑线…');await new Promise(resolve=>requestAnimationFrame(resolve));game.run();hud.ready();}catch(e){console.error(e);hud.error(`启动失败：${e instanceof Error?e.message:String(e)}。请使用现代 WebGL 浏览器，通过本地 HTTP 服务器访问。`);}}
void boot();
