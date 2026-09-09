import * as THREE from "three";
import RAPIER from "@dimforge/rapier3d-compat";

/** The same fixed colliders are created in the browser and authoritative server. */
export function buildArena(
  world: RAPIER.World,
  group: THREE.Group,
  surfaces: Set<number>,
  visual: boolean,
) {
  const body = world.createRigidBody(RAPIER.RigidBodyDesc.fixed());
  const block = (
    size: [number, number, number],
    pos: [number, number, number],
    color: number,
    ground = false,
  ) => {
    const c = world.createCollider(
      RAPIER.ColliderDesc.cuboid(size[0] / 2, size[1] / 2, size[2] / 2)
        .setTranslation(...pos)
        .setFriction(0.08)
        .setRestitution(0.25),
      body,
    );
    if (ground) surfaces.add(c.handle);
    if (visual) {
      const m = new THREE.Mesh(
        new THREE.BoxGeometry(...size),
        new THREE.MeshStandardMaterial({ color, roughness: 0.75 }),
      );
      m.position.set(...pos);
      m.receiveShadow = true;
      m.castShadow = !ground;
      group.add(m);
    }
  };
  block([82, 1, 82], [0, -0.5, 0], 0x526b89, true);
  for (const sign of [-1, 1]) {
    block([82, 2.6, 1.2], [0, 1.3, sign * 40.5], 0xadc9e2);
    block([1.2, 2.6, 80], [sign * 40.5, 1.3, 0], 0xadc9e2);
  }
  // Low cover gives the open arena several distinct routes and protects against projectiles.
  for (const sign of [-1, 1]) {
    block([10, 2.4, 2.5], [sign * 17, 1.2, 10], 0xf4bf72);
    block([2.5, 2.4, 10], [10, 1.2, sign * 17], 0xb9a0e7);
  }
  world.createCollider(
    RAPIER.ColliderDesc.cylinder(1.7, 4.8)
      .setTranslation(0, 1.7, 0)
      .setRestitution(0.4),
    body,
  );
  if (!visual) return;
  const hub = new THREE.Mesh(
    new THREE.CylinderGeometry(4.8, 4.8, 3.4, 16),
    new THREE.MeshStandardMaterial({ color: 0x36536f, roughness: 0.5 }),
  );
  hub.position.y = 1.7;
  hub.castShadow = true;
  group.add(hub);
  const crystal = new THREE.Mesh(
    new THREE.OctahedronGeometry(3),
    new THREE.MeshStandardMaterial({
      color: 0xb5ffe7,
      emissive: 0x60d2c7,
      emissiveIntensity: 0.65,
      metalness: 0.3,
      roughness: 0.3,
    }),
  );
  crystal.position.y = 6.2;
  group.add(crystal);
  const lineMat = new THREE.MeshStandardMaterial({
    color: 0x8fa3bd,
    roughness: 1,
  });
  for (let i = -32; i <= 32; i += 8) {
    for (const vertical of [false, true]) {
      const line = new THREE.Mesh(
        new THREE.BoxGeometry(
          vertical ? 0.09 : 79,
          0.012,
          vertical ? 79 : 0.09,
        ),
        lineMat,
      );
      line.position.set(vertical ? i : 0, 0.014, vertical ? 0 : i);
      group.add(line);
    }
  }
  const ring = new THREE.Mesh(
    new THREE.RingGeometry(11.6, 12, 64),
    new THREE.MeshBasicMaterial({ color: 0xf3cf89, side: THREE.DoubleSide }),
  );
  ring.rotation.x = -Math.PI / 2;
  ring.position.y = 0.025;
  group.add(ring);
  for (let i = 0; i < 4; i++) {
    const angle = (i * Math.PI) / 2 + Math.PI / 4,
      x = Math.sin(angle) * 39,
      z = Math.cos(angle) * 39,
      color = [0xa3efd4, 0xf8c583, 0xc5aff6, 0xf8a5bc][i];
    const pad = new THREE.Mesh(
      new THREE.CircleGeometry(4, 32),
      new THREE.MeshStandardMaterial({ color, roughness: 0.7 }),
    );
    pad.rotation.x = -Math.PI / 2;
    pad.position.set(x, 0.028, z);
    group.add(pad);
    const tower = new THREE.Mesh(
      new THREE.CylinderGeometry(1.2, 2.2, 8, 8),
      new THREE.MeshStandardMaterial({ color }),
    );
    tower.position.set(Math.sign(x) * 44, 4, Math.sign(z) * 44);
    group.add(tower);
    const top = new THREE.Mesh(
      new THREE.IcosahedronGeometry(2.4),
      new THREE.MeshStandardMaterial({
        color,
        emissive: color,
        emissiveIntensity: 0.2,
      }),
    );
    top.position.copy(tower.position);
    top.position.y = 9;
    group.add(top);
  }
  const ground = new THREE.Mesh(
    new THREE.PlaneGeometry(650, 650),
    new THREE.MeshStandardMaterial({ color: 0x789aaa, roughness: 1 }),
  );
  ground.rotation.x = -Math.PI / 2;
  ground.position.y = -1.1;
  group.add(ground);
}
