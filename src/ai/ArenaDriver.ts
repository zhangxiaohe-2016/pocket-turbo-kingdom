import RAPIER from "@dimforge/rapier3d-compat";
import type { KartPhysics } from "../vehicle/KartPhysics";
import type { ItemSystem } from "../items/ItemSystem";
import { emptyControls } from "../input/InputManager";
export class ArenaDriver {
  private stuck = 0;
  constructor(public kart: KartPhysics) {}
  update(dt: number, _progress: number, items: ItemSystem) {
    const k = this.kart,
      c = emptyControls();
    const opponents = items.karts.filter((o) => o !== k && !o.disconnected);
    const target = opponents.sort(
      (a, b) =>
        a.position.distanceToSquared(k.position) -
        b.position.distanceToSquared(k.position),
    )[0];
    const pickup = items.boxes
      .filter((b) => b.cooldown === 0)
      .sort(
        (a, b) =>
          a.position.distanceToSquared(k.position) -
          b.position.distanceToSquared(k.position),
      )[0];
    const goal =
      !k.slots.some(Boolean) && pickup ? pickup.position : target?.position;
    if (!goal) return c;
    const dx = goal.x - k.position.x,
      dz = goal.z - k.position.z,
      angle = Math.atan2(dx, dz) - k.yaw,
      error = Math.atan2(Math.sin(angle), Math.cos(angle));
    c.steer = Math.max(-1, Math.min(1, -error * 2));
    c.throttle = 1;
    c.brake = Math.abs(error) > 1 && k.speed > 9 ? 0.55 : 0;
    const ray = new RAPIER.Ray(
      { x: k.position.x, y: 0.9, z: k.position.z },
      { x: Math.sin(k.yaw), y: 0, z: Math.cos(k.yaw) },
    );
    const hit = k.world.castRay(
      ray,
      7,
      true,
      RAPIER.QueryFilterFlags.EXCLUDE_DYNAMIC |
        RAPIER.QueryFilterFlags.EXCLUDE_SENSORS,
      undefined,
      undefined,
      k.body,
      (col) => !k.track.surfaceHandles.has(col.handle),
    );
    if (hit) {
      c.steer = k.id % 2 ? 1 : -1;
      c.brake = k.speed > 8 ? 0.6 : 0;
    }
    const aim = target && Math.abs(error) < 0.35 && Math.hypot(dx, dz) < 35;
    c.item1 = k.slots[0] === "battery" || !!aim;
    c.item2 = k.slots[1] === "battery" || !!aim;
    this.stuck = Math.abs(k.speed) < 1 ? this.stuck + dt : 0;
    c.reset = this.stuck > 3;
    c.drift = false;
    return c;
  }
}
