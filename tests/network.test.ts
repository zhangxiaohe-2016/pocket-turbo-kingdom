import { beforeAll, describe, expect, it } from "vitest";
import RAPIER from "@dimforge/rapier3d-compat";
import { ServerRace } from "../server/Race";
import { AIDriver } from "../src/ai/AIDriver";
import { emptyControls } from "../src/input/InputManager";
const players = [0, 1].map((i) => ({
  id: `p${i}`,
  name: `Player ${i}`,
  kart: i,
  ready: true,
  connected: true,
}));
beforeAll(async () => {
  await RAPIER.init();
});
describe("authoritative LAN race", () => {
  it("shares countdown, real inputs, item effects and snapshots", () => {
    const sim = new ServerRace(players);
    try {
      const inputs = new Map(players.map((p) => [p.id, emptyControls()]));
      for (let i = 0; i < 220; i++) sim.step(inputs);
      expect(sim.snapshot().phase).toBe("racing");
      const k = sim.karts[1];
      k.slots[0] = "battery";
      inputs.set("p1", { ...emptyControls(), throttle: 1, item1: true });
      sim.step(inputs);
      expect(sim.snapshot().karts[1].boost).toBeGreaterThan(2);
      expect(k.slots[0]).toBeNull();
      expect(inputs.get("p1")!.item1).toBe(false);
      for (let i = 0; i < 60; i++) sim.step(inputs);
      expect(k.speed).toBeGreaterThan(10);
      expect(sim.karts[0].speed).toBeCloseTo(0);
    } finally {
      sim.dispose();
    }
  });
  it("finishes both real drivers and produces a single final order", () => {
    const sim = new ServerRace(players);
    const ai = sim.karts.map((k) => new AIDriver(k, k.id ? 2 : -2));
    try {
      for (let i = 0; i < 18000 && !sim.done; i++)
        sim.step(
          new Map(
            players.map((p, j) => [
              p.id,
              ai[j].update(1 / 60, sim.karts[j].progress, sim.items),
            ]),
          ),
        );
      const s = sim.snapshot();
      expect(s.phase).toBe("results");
      expect(s.karts.every((k) => k.finished && k.lap === 3)).toBe(true);
      expect(s.karts.map((k) => k.rank).sort()).toEqual([1, 2]);
    } finally {
      sim.dispose();
    }
  });
  it("ends when all drivers disconnect", () => {
    const sim = new ServerRace(players);
    try {
      players.forEach((p) => sim.disconnected.add(p.id));
      sim.step(new Map());
      expect(sim.snapshot().phase).toBe("results");
      expect(sim.snapshot().karts.every((k) => !k.finished)).toBe(true);
    } finally {
      sim.dispose();
    }
  });
});
