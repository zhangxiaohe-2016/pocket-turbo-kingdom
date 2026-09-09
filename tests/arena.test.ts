import { beforeAll, describe, it, expect } from "vitest";
import RAPIER from "@dimforge/rapier3d-compat";
import { ServerRace } from "../server/Race";
import { emptyControls } from "../src/input/InputManager";
import { ArenaDriver } from "../src/ai/ArenaDriver";
import { ARENA_SECONDS } from "../src/config/arena";
const players = Array.from({ length: 4 }, (_, i) => ({
  id: `p${i}`,
  name: `P${i}`,
  kart: i,
  ready: true,
  connected: true,
}));
beforeAll(async () => {
  await RAPIER.init();
});
describe("open arena battle", () => {
  it("has independent floor, cardinal spawns, cover and no checkpoint requirement", () => {
    const sim = new ServerRace(players, "arena");
    try {
      expect(sim.track.arena).toBe(true);
      expect(sim.track.surfaceHandles.size).toBe(1);
      expect(sim.items.boxes).toHaveLength(8);
      expect(sim.karts.every((k) => k.grounded && k.position.y > 0.5)).toBe(
        true,
      );
      expect(
        new Set(
          sim.karts.map(
            (k) => `${Math.sign(k.position.x)},${Math.sign(k.position.z)}`,
          ),
        ).size,
      ).toBe(4);
      expect(
        sim.track.legal(sim.track.project({ x: -30, y: 1, z: 0 }), 1),
      ).toBe(true);
    } finally {
      sim.dispose();
    }
  });
  it("scores real projectile hits once, excludes self-hits and protected repeats", () => {
    const sim = new ServerRace(players, "arena");
    try {
      for (let i = 0; i < 220; i++) sim.step(new Map());
      const [a, b] = sim.karts;
      for (const [k, z] of [
        [a, 0],
        [b, 5],
      ] as const) {
        k.position.set(-25, 0.8, z);
        k.previous.copy(k.position);
        k.body.setTranslation(k.position, true);
        k.body.setLinvel({ x: 0, y: 0, z: 0 }, true);
        k.yaw = 0;
        k.invulnerable = 0;
      }
      a.slots[0] = "gear";
      sim.step(new Map([["p0", { ...emptyControls(), item1: true }]]));
      for (let i = 0; i < 12; i++) sim.step(new Map());
      expect(a.score).toBe(1);
      expect(b.hitsTaken).toBe(1);
      expect(b.stun).toBeGreaterThan(0);
      expect(a.slots[0]).toBeNull();
      sim.race.arenaHit(a.id, a);
      expect(a.score).toBe(1);
      expect(b.hit()).toBe(false);
      a.reset();
      const first = a.position.clone();
      a.reset();
      expect(a.position.equals(first)).toBe(true);
      expect(a.arenaResetCooldown).toBe(8);
      sim.race.arenaHit(b.id, a);
      expect(a.rank).toBe(1);
      expect(b.rank).toBe(1);
    } finally {
      sim.dispose();
    }
  });
  it("plays a complete 3-minute bot battle, ends on time and preserves scores", () => {
    const sim = new ServerRace(players, "arena");
    try {
      const bots = sim.karts.map((k) => new ArenaDriver(k));
      for (let i = 0; i < 12000 && !sim.done; i++)
        sim.step(
          new Map(
            players.map((p, j) => [p.id, bots[j].update(1 / 60, 0, sim.items)]),
          ),
        );
      expect(sim.done).toBe(true);
      expect(sim.snapshot().phase).toBe("results");
      expect(sim.race.elapsed).toBe(ARENA_SECONDS);
      expect(sim.karts.every((k) => k.lap === 0 && k.finished)).toBe(true);
      expect(sim.karts.reduce((n, k) => n + k.score, 0)).toBeGreaterThan(0);
      const scores = sim.karts.map((k) => k.score);
      sim.step(new Map());
      expect(sim.karts.map((k) => k.score)).toEqual(scores);
    } finally {
      sim.dispose();
    }
  });
});
