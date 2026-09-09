import RAPIER from "@dimforge/rapier3d-compat";
import { Track } from "../src/track/Track";
import { KartPhysics } from "../src/vehicle/KartPhysics";
import { RaceManager } from "../src/race/RaceManager";
import { ItemSystem } from "../src/items/ItemSystem";
import { KARTS } from "../src/config/game";
import { emptyControls, type Controls } from "../src/input/InputManager";
import type { LanMode, Player, Snapshot } from "../src/network/protocol";
export class ServerRace {
  world = new RAPIER.World({ x: 0, y: -9.81, z: 0 });
  queue = new RAPIER.EventQueue(true);
  track: Track;
  karts: KartPhysics[];
  race: RaceManager;
  items: ItemSystem;
  tick = 0;
  finishedAt = 0;
  done = false;
  disconnected = new Set<string>();
  constructor(
    public players: Player[],
    public mode: LanMode = "quick",
  ) {
    this.track = new Track(this.world, undefined, mode === "arena");
    this.world.timestep = 1 / 60;
    this.karts = players.map(
      (p, i) => new KartPhysics(i, KARTS[p.kart], this.world, this.track),
    );
    this.race = new RaceManager(this.karts, mode);
    this.items = new ItemSystem(this.track, this.karts, mode);
    for (let n = 0; n < 70; n++) {
      for (const k of this.karts) k.preStep(1 / 60, emptyControls(), false);
      this.world.step(this.queue);
      for (const k of this.karts) k.postStep(1 / 60);
    }
    this.queue.drainCollisionEvents(() => {});
    this.items.onHit = (owner, target) => this.race.arenaHit(owner, target);
    this.race.start();
  }
  step(inputs: Map<string, Controls>) {
    if (this.done) return;
    const dt = 1 / 60;
    this.tick++;
    this.track.update(dt, this.tick * dt);
    const enabled =
      this.race.state === "racing" || this.race.state === "finished";
    this.karts.forEach((k, i) => {
      const c = inputs.get(this.players[i].id) ?? emptyControls();
      if (k.needsReset || c.reset) k.reset();
      if (enabled && !k.finished) {
        if (c.item1) this.items.use(k, 0, c.backward);
        if (c.item2) this.items.use(k, 1, c.backward);
        if (c.discard) this.items.discard(k);
      }
      k.preStep(
        dt,
        c,
        enabled && !k.finished && !this.disconnected.has(this.players[i].id),
      );
      c.jump = c.item1 = c.item2 = c.reset = c.discard = false;
    });
    this.items.update(dt, this.tick * dt, enabled);
    this.world.step(this.queue);
    this.queue.drainCollisionEvents((a, b, started) => {
      if (!started) return;
      for (const k of this.karts) {
        if (
          (k.collider.handle === a || k.collider.handle === b) &&
          Math.abs(k.speed) > 7 &&
          k.invulnerable <= 0 &&
          !this.track.surfaceHandles.has(k.collider.handle === a ? b : a)
        ) {
          k.impact = 0.45;
          k.stun = Math.max(k.stun, 0.28);
        }
      }
    });
    this.karts.forEach((k) => k.postStep(dt));
    this.race.step(dt);
    if (this.mode === "arena") {
      this.done =
        this.race.state === "finished" ||
        this.karts.every((_, i) => this.disconnected.has(this.players[i].id));
      return;
    }
    if (!this.finishedAt && this.karts.some((k) => k.finished))
      this.finishedAt = this.tick;
    this.done =
      this.karts.every(
        (k, i) => k.finished || this.disconnected.has(this.players[i].id),
      ) ||
      (this.finishedAt > 0 && this.tick - this.finishedAt > 60 * 60) ||
      this.tick > 60 * 600;
  }
  snapshot(): Snapshot {
    return {
      type: "snapshot",
      tick: this.tick,
      elapsed: this.race.elapsed,
      countdown: this.race.countdown,
      goFlash: this.race.goFlash,
      phase: this.done
        ? "results"
        : this.race.state === "countdown"
          ? "countdown"
          : "racing",
      karts: this.karts.map((k, i) => ({
        id: this.players[i].id,
        score: k.score,
        hitsTaken: k.hitsTaken,
        disconnected: k.disconnected,
        position: k.position.toArray(),
        velocity: [k.body.linvel().x, k.body.linvel().y, k.body.linvel().z],
        yaw: k.yaw,
        speed: k.speed,
        steering: k.steering,
        grounded: k.grounded,
        drift: k.drift,
        driftCharge: k.driftCharge,
        driftLevel: k.driftLevel,
        boost: k.boost,
        stun: k.stun,
        invulnerable: k.invulnerable,
        lap: k.lap,
        nextCheckpoint: k.nextCheckpoint,
        lastCheckpoint: k.lastCheckpoint,
        progress: k.progress,
        rank: k.rank,
        finished: k.finished,
        finishTime: k.finishTime,
        lapTimes: k.lapTimes,
        slots: k.slots,
        rolling: k.rolling,
      })),
      boxes: this.items.boxes.map((b) => b.cooldown),
      items: this.items.pool.flatMap((o, index) =>
        o.active
          ? [{ index, kind: o.kind, position: o.position.toArray() }]
          : [],
      ),
    };
  }
  dispose() {
    this.queue.free();
    this.world.free();
  }
}
