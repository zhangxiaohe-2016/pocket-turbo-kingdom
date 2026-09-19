// 导出器入口：被打包成单文件后在 Node 里跑，用真实的 Track/Arena 生成赛道几何。
import RAPIER from '@dimforge/rapier3d-compat';
import { Track } from '../../src/track/Track';
import { KARTS, QUALITY, ITEMS } from '../../src/config/game';
import { ARENA_NAME, ARENA_RADIUS, ARENA_SECONDS } from '../../src/config/arena';
export { RAPIER, Track, KARTS, QUALITY, ITEMS, ARENA_NAME, ARENA_RADIUS, ARENA_SECONDS };
