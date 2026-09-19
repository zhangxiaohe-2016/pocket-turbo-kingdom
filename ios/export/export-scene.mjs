// 把 three.js 里的赛道场景烘焙成 iPad 客户端用的 .ptkgeo 二进制几何。
//
//   node ios/export/export-scene.mjs [--density 1.0] [--out ios/PocketTurboKingdom/assets]
//
// 设计见 ios/DESIGN.md 第 3 节。所有几何在这里烘焙世界变换，客户端一个 node 一个 draw call。
import { build } from 'esbuild';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const args = process.argv.slice(2);
const argOf = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const density = Number(argOf('density', '1.0'));
const outDir = join(root, argOf('out', 'ios/PocketTurboKingdom/assets'));

// ---------------------------------------------------------------- DOM stub
// Track.textSign 会用 canvas 画字再做成贴图：这里让 canvas 记录下文字和颜色，
// 导出成 signs 条目，客户端用 CoreGraphics 重绘（零游戏代码改动）。
function installCanvasStub() {
  globalThis.document = {
    createElement(tag) {
      if (tag !== 'canvas') return {};
      const canvas = { width: 0, height: 0, __text: null, __fill: '#fff1ca', style: {} };
      canvas.getContext = () => ({
        set fillStyle(v) { canvas.__fill = v; },
        get fillStyle() { return canvas.__fill; },
        font: '', textAlign: '', textBaseline: '',
        fillText(text) { canvas.__text = text; },
        clearRect() {}, fillRect() {}, drawImage() {},
      });
      return canvas;
    },
    createElementNS() { return document.createElement('canvas'); },
  };
  globalThis.self = globalThis;
}

// ---------------------------------------------------------------- 打包入口
async function loadGameModules() {
  const buildDir = join(here, '.build');
  await mkdir(buildDir, { recursive: true });
  const outfile = join(buildDir, 'entry.mjs');
  await build({
    entryPoints: [join(here, 'entry.ts')],
    outfile,
    bundle: true,
    platform: 'node',
    format: 'esm',
    packages: 'external',
    logLevel: 'warning',
    alias: { '@dimforge/rapier3d-compat': '@dimforge/rapier3d-compat/rapier.es.js' },
  });
  return import(`${outfile}?t=${Date.now()}`);
}

// ---------------------------------------------------------------- 颜色工具
// three 的工作色彩空间是 Linear-sRGB，SceneKit 侧按 sRGB 处理颜色；这里统一转 sRGB 再导出。
const linearToSRGB = (c) => (c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055);
const toSRGB = (rgb) => [linearToSRGB(rgb[0]), linearToSRGB(rgb[1]), linearToSRGB(rgb[2])];

// ---------------------------------------------------------------- 写入器
class GeoWriter {
  constructor() {
    this.chunks = [];
    this.bytes = 0;
  }
  push(typedArray) {
    const buf = Buffer.from(typedArray.buffer, typedArray.byteOffset, typedArray.byteLength);
    const offset = this.bytes;
    this.chunks.push(buf);
    this.bytes += buf.length;
    return offset;
  }
  payload() {
    return Buffer.concat(this.chunks, this.bytes);
  }
}

function materialKey(three, mat) {
  const attrs = [
    mat.type,
    mat.color ? mat.color.getHexString() : 'none',
    mat.map ? 'map' : 'nomap',
    mat.vertexColors ? 'vc' : 'novc',
    mat.side === three.DoubleSide ? 'double' : 'single',
    mat.transparent ? `t${(mat.opacity ?? 1).toFixed(2)}` : 'opaque',
    mat.emissive && mat.emissive.getHex() !== 0 ? `e${mat.emissive.getHexString()}${(mat.emissiveIntensity ?? 1).toFixed(2)}` : 'noe',
    mat.flatShading ? 'flat' : 'smooth',
  ];
  return attrs.join('|');
}

function materialRecord(three, mat) {
  const rec = {
    color: mat.color ? toSRGB([mat.color.r, mat.color.g, mat.color.b]) : [1, 1, 1],
    roughness: mat.roughness ?? 0.9,
    metalness: mat.metalness ?? 0,
    doubleSided: mat.side === three.DoubleSide,
    vertexColors: !!mat.vertexColors,
    transparent: !!mat.transparent && (mat.opacity ?? 1) < 0.999,
    opacity: mat.opacity ?? 1,
    emissive: null,
  };
  if (mat.emissive && mat.emissive.getHex() !== 0) {
    rec.emissive = toSRGB([mat.emissive.r, mat.emissive.g, mat.emissive.b]);
    rec.emissiveIntensity = mat.emissiveIntensity ?? 1;
  }
  return rec;
}

// 把一个 BufferGeometry（可选地乘上实例矩阵）展开成扁平数组。
function expandGeometry(three, geometry, matrix, instanceColor, forceColor) {
  let g = geometry;
  if (forceColor?.flat) g = g.toNonIndexed();
  else g = g.clone();
  if (matrix) g.applyMatrix4(matrix);
  if (!g.attributes.normal) g.computeVertexNormals();

  const pos = g.attributes.position.array;
  const nrm = g.attributes.normal.array;
  const count = g.attributes.position.count;
  const positions = new Float32Array(count * 3);
  positions.set(pos.subarray(0, count * 3));
  const normals = new Float32Array(count * 3);
  normals.set(nrm.subarray(0, count * 3));

  let colors = null;
  const srcColor = g.attributes.color;
  const tint = forceColor?.tint ?? null; // 实例色 × 材质色
  if (srcColor || tint) {
    colors = new Float32Array(count * 3);
    for (let i = 0; i < count; i++) {
      let r = srcColor ? srcColor.getX(i) : 1;
      let gg = srcColor ? srcColor.getY(i) : 1;
      let b = srcColor ? srcColor.getZ(i) : 1;
      if (tint) { r *= tint[0]; gg *= tint[1]; b *= tint[2]; }
      const s = toSRGB([r, gg, b]);
      colors[i * 3] = s[0]; colors[i * 3 + 1] = s[1]; colors[i * 3 + 2] = s[2];
    }
  }
  const index = g.index ? new Uint32Array(g.index.array) : (() => {
    const seq = new Uint32Array(count);
    for (let i = 0; i < count; i++) seq[i] = i;
    return seq;
  })();
  return { positions, normals, colors, indices: index, triangles: index.length / 3 };
}

function exportScene(three, scene, { name, writer, result }) {
  const skip = new Set();
  const obstacleMeshes = new Set(result.dynamicObstacles);
  scene.traverse((o) => {
    if (o.isLOD) for (let i = 1; i < o.levels.length; i++) o.levels[i].object.traverse((c) => skip.add(c));
  });
  scene.updateMatrixWorld(true);

  const materialKeys = new Map();
  const registerMaterial = (mat, key) => {
    if (!materialKeys.has(key)) materialKeys.set(key, { key, ...materialRecord(three, mat) });
    return key;
  };

  const meshes = [];
  scene.traverse((obj) => {
    if (skip.has(obj) || obstacleMeshes.has(obj)) return;
    if (!obj.isMesh || obj.isLine || obj.isPoints) return;
    if (!obj.visible) return;
    const mat = Array.isArray(obj.material) ? obj.material[0] : obj.material;
    if (!mat) return;

    // canvas 贴图的指示牌 → signs 条目，不导出几何
    if (mat.map && mat.map.image && mat.map.image.__text) {
      const params = obj.geometry.parameters || {};
      result.signs.push({
        text: String(mat.map.image.__text),
        width: params.width ?? 4,
        height: params.height ?? 1,
        color: mat.map.image.__fill || '#fff1ca',
        transform: Array.from(obj.matrixWorld.elements),
      });
      return;
    }

    const key = registerMaterial(mat, materialKey(three, mat));
    const baseColor = mat.color ? [mat.color.r, mat.color.g, mat.color.b] : [1, 1, 1];
    if (obj.isInstancedMesh) {
      const count = obj.count;
      const instMat = new three.Matrix4();
      for (let i = 0; i < count; i++) {
        obj.getMatrixAt(i, instMat);
        let tint = null;
        if (obj.instanceColor) {
          // 与 three 一致：最终颜色 = 材质色 × 实例色
          tint = [
            baseColor[0] * obj.instanceColor.getX(i),
            baseColor[1] * obj.instanceColor.getY(i),
            baseColor[2] * obj.instanceColor.getZ(i),
          ];
        }
        if (instMat.elements[0] === 0 && instMat.elements[5] === 0 && instMat.elements[10] === 0) continue; // 被缩放隐藏的实例
        meshes.push({ name: `${name}/${obj.name || obj.type}/${i}`, key, matrix: instMat.clone(), geometry: obj.geometry, tint });
      }
    } else {
      meshes.push({ name: `${name}/${obj.name || obj.type}`, key, matrix: obj.matrixWorld.clone(), geometry: obj.geometry });
    }
  });

  const writerNodes = [];
  let triangles = 0;
  // 关键：按材质合并。700 根草 + 390 个斑点如果各自成节点就是 2500 个 draw call，A7 撑不住；
  // 合并后每种材质一个静态 mesh（约 27 个），三角形数不变。
  const groups = new Map();
  for (const m of meshes) {
    const data = expandGeometry(three, m.geometry, m.matrix, null, {
      flat: !!m.geometry.__ptkFlat || materialFlat(m),
      tint: m.tint,
    });
    if (!data.triangles) continue;
    triangles += data.triangles;
    if (!groups.has(m.key)) groups.set(m.key, { chunks: [], triangles: 0 });
    const group = groups.get(m.key);
    group.chunks.push(data);
    group.triangles += data.triangles;
  }

  for (const [key, group] of groups) {
    const merged = mergeChunks(group.chunks);
    const vertexCount = merged.positions.length / 3;
    const node = {
      name: `${name}/${key}`,
      material: key,
      position: { offset: writer.push(merged.positions), count: vertexCount, type: 'f32' },
      normal: { offset: writer.push(merged.normals), count: vertexCount, type: 'f32' },
      indices: { offset: writer.push(merged.indices), count: merged.indices.length, type: 'u32' },
    };
    if (merged.colors) node.color = { offset: writer.push(merged.colors), count: vertexCount, type: 'f32' };
    writerNodes.push(node);
  }

  result.nodes.push(...writerNodes);
  const usedColors = new Set(writerNodes.filter((n) => n.color).map((n) => n.material));
  result.materials.push(...[...materialKeys.values()].map((m) => ({ ...m, vertexColors: m.vertexColors || usedColors.has(m.key) })));
  result.stats[name] = { drawCalls: writerNodes.length, triangles };
}

function mergeChunks(chunks) {
  const vertexFloats = chunks.reduce((a, c) => a + c.positions.length, 0);
  const indexCount = chunks.reduce((a, c) => a + c.indices.length, 0);
  const anyColor = chunks.some((c) => c.colors);
  const positions = new Float32Array(vertexFloats);
  const normals = new Float32Array(vertexFloats);
  const colors = anyColor ? new Float32Array(vertexFloats) : null;
  const indices = new Uint32Array(indexCount);
  let floatOffset = 0;
  let indexOffset = 0;
  let vertexBase = 0;
  const white = new Float32Array(3).fill(1);
  for (const c of chunks) {
    positions.set(c.positions, floatOffset);
    normals.set(c.normals, floatOffset);
    if (colors) {
      if (c.colors) colors.set(c.colors, floatOffset);
      else for (let i = 0; i < c.positions.length / 3; i++) { colors[floatOffset + i * 3] = white[0]; colors[floatOffset + i * 3 + 1] = white[1]; colors[floatOffset + i * 3 + 2] = white[2]; }
    }
    for (let i = 0; i < c.indices.length; i++) indices[indexOffset + i] = c.indices[i] + vertexBase;
    vertexBase += c.positions.length / 3;
    floatOffset += c.positions.length;
    indexOffset += c.indices.length;
  }
  return { positions, normals, colors, indices, triangles: indexCount / 3 };
}

const materialFlatCache = new WeakMap();
function materialFlat(m) { return materialFlatCache.get(m.geometry) ?? false; }

// ---------------------------------------------------------------- 主流程
installCanvasStub();
const THREE = await import('three');
const game = await loadGameModules();
const { Track, RAPIER } = game;
await RAPIER.init();

async function exportWorld(arena) {
  const writer = new GeoWriter();
  const result = { version: 1, materials: [], nodes: [], signs: [], anchors: {}, stats: {} };
  const world = new RAPIER.World({ x: 0, y: -9.81, z: 0 });
  world.timestep = 1 / 60;
  const scene = new THREE.Scene();
  const track = new Track(world, scene, arena);
  track.setSceneryDensity(density);
  scene.updateMatrixWorld(true);

  result.dynamicObstacles = track.obstacles.map((o) => o.mesh);
  // flatShading 的材质（树/山）需要面法线
  scene.traverse((o) => {
    if (!o.isMesh) return;
    const mat = Array.isArray(o.material) ? o.material[0] : o.material;
    if (mat && mat.flatShading) o.geometry.__ptkFlat = true;
  });

  const name = arena ? 'arena' : 'track';
  exportScene(THREE, scene, { name, writer, result });

  // 动态锚点：客户端据此重建道具箱、移动障碍和起点
  const v3 = (v) => [v.x, v.y, v.z];
  result.karts = game.KARTS.map((k) => ({
    id: k.id, name: k.name, title: k.title, vehicle: k.vehicle, type: k.type,
    color: k.color, accent: k.accent, stats: k.stats,
  }));
  result.items = game.ITEMS;
  // 顺序必须与服务器 ItemSystem 一致：外层是 boxTs、内层是 lane，否则 snapshot.boxes 的下标会错位
  result.anchors.boxes = track.boxTs.flatMap((t) =>
    (arena ? [0] : [-4, 0, 4]).map((lane) => {
      const p = track.point(t, lane).clone();
      p.y += 1.2;
      return { t, lane, p: v3(p) };
    }),
  );
  result.anchors.obstacles = track.obstacles.map((o, i) => {
    const s = track.at(o.t);
    return { t: o.t, phase: i * 2, p: v3(s.p), right: v3(s.right), y: 1.3 };
  });
  result.anchors.boostPads = (track.boostTs || []).map((t) => {
    const s = track.at(t);
    return { t, p: v3(s.p), yaw: Math.atan2(s.tangent.x, s.tangent.z), bank: s.bank };
  });
  result.anchors.start = (() => {
    const s = track.at(0);
    return { p: v3(s.p), yaw: Math.atan2(s.tangent.x, s.tangent.z) };
  })();
  result.anchors.track = {
    count: track.count,
    halfWidth: track.halfWidth,
    arena,
    samples: track.samples
      .filter((_, i) => i % 4 === 0)
      .map((s) => ({ t: s.t, p: v3(s.p), yaw: Math.atan2(s.tangent.x, s.tangent.z), bank: s.bank })),
  };

  const json = Buffer.from(JSON.stringify(result), 'utf8');
  const payload = writer.payload();
  const header = Buffer.alloc(12);
  header.write('PTKG', 0, 'ascii');
  header.writeUInt32LE(1, 4);
  header.writeUInt32LE(json.length, 8);
  const file = Buffer.concat([header, json, payload]);
  const path = join(outDir, `${name}.ptkgeo`);
  await writeFile(path, file);
  console.log(`\n[${name}] ${path}`);
  console.log(`  draw calls : ${result.stats[name].drawCalls}`);
  console.log(`  triangles  : ${result.stats[name].triangles.toLocaleString()}`);
  console.log(`  materials  : ${result.materials.length}`);
  console.log(`  signs      : ${result.signs.length} (${result.signs.map((s) => s.text).join(', ')})`);
  console.log(`  boxes      : ${result.anchors.boxes.length}, obstacles: ${result.anchors.obstacles.length}, boost: ${result.anchors.boostPads.length}`);
  console.log(`  file size  : ${(file.length / 1024 / 1024).toFixed(2)} MB (payload ${(payload.length / 1024 / 1024).toFixed(2)} MB, json ${(json.length / 1024).toFixed(0)} KB)`);
  return result;
}

await mkdir(outDir, { recursive: true });
const track = await exportWorld(false);
const arena = await exportWorld(true);
console.log('\n密度参数 --density', density, '（A7 掉帧时可降到 0.45）');
