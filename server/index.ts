import { createServer } from "node:http";
import { networkInterfaces } from "node:os";
import { randomUUID, randomBytes } from "node:crypto";
import { WebSocketServer, WebSocket } from "ws";
import RAPIER from "@dimforge/rapier3d-compat";
import { createServer as createVite } from "vite";
import { ServerRace } from "./Race";
import { emptyControls, type Controls } from "../src/input/InputManager";
import { KARTS } from "../src/config/game";
import type {
  Room,
  ClientMessage,
  ServerMessage,
} from "../src/network/protocol";
await RAPIER.init();
const vite = await createVite({
  server: { middlewareMode: true },
  appType: "spa",
});
const http = createServer((req, res) => vite.middlewares(req, res));
const wss = new WebSocketServer({ noServer: true, maxPayload: 4096 });
http.on("upgrade", (req, socket, head) => {
  if (req.url === "/lan")
    wss.handleUpgrade(req, socket, head, (ws) =>
      wss.emit("connection", ws, req),
    );
});
interface Session {
  id: string;
  ws: WebSocket;
  room?: RoomData;
  seq: number;
  lastInput: number;
  controls: Controls;
  messages: number;
  alive: boolean;
}
interface RoomData {
  info: Room;
  clients: Map<string, Session>;
  race?: ServerRace;
}
const rooms = new Map<string, RoomData>();
function send(s: Session, m: ServerMessage) {
  if (s.ws.readyState === WebSocket.OPEN && s.ws.bufferedAmount < 1_000_000)
    s.ws.send(JSON.stringify(m));
}
function lanUrls() {
  return Object.values(networkInterfaces()).flatMap((list) =>
    (list ?? [])
      .filter((ip) => ip.family === "IPv4" && !ip.internal)
      .map((ip) => `http://${ip.address}:${Number(process.env.PORT) || 5173}`),
  );
}
function broadcast(r: RoomData) {
  for (const s of r.clients.values())
    send(s, { type: "room", room: r.info, you: s.id, urls: lanUrls() });
}
function error(s: Session, message: string) {
  send(s, { type: "error", message });
}
wss.on("connection", (ws) => {
  const s: Session = {
    id: randomUUID(),
    ws,
    seq: -1,
    lastInput: 0,
    controls: emptyControls(),
    messages: 0,
    alive: true,
  };
  ws.on("pong", () => (s.alive = true));
  const timer = setInterval(() => {
    s.messages = 0;
    if (!s.alive) {
      ws.terminate();
      return;
    }
    s.alive = false;
    ws.ping();
  }, 5000);
  const joinTimeout = setTimeout(() => {
    if (!s.room) ws.close(1008, "Join timeout");
  }, 10000);
  ws.on("message", (data) => {
    try {
      if (++s.messages > 600) {
        ws.close(1008, "Rate limit");
        return;
      }
      const m = JSON.parse(data.toString()) as ClientMessage;
      if (!m || typeof m !== "object") return;
      if (m.type === "join") {
        if (s.room) return;
        if (m.version !== 2) return error(s, "客户端版本不匹配，请刷新页面");
        if (
          typeof m.name !== "string" ||
          !m.name.trim() ||
          !Number.isInteger(m.kart) ||
          !KARTS[m.kart] ||
          typeof m.code !== "string"
        )
          return error(s, "请填写昵称并选择赛车");
        const code = m.code.trim().toUpperCase();
        let r = rooms.get(code);
        if (code && !r) return error(s, "房间不存在，请检查房间码");
        if (!r) {
          if (rooms.size >= 32) return error(s, "服务器房间已满");
          let id: string;
          do {
            id = randomBytes(3).toString("hex").toUpperCase();
          } while (rooms.has(id));
          r = {
            info: {
              code: id,
              host: s.id,
              phase: "lobby",
              mode: "quick",
              players: [],
            },
            clients: new Map(),
          };
          rooms.set(id, r);
        }
        if (r.info.phase !== "lobby")
          return error(s, "比赛已开始，请等待下一场");
        if (r.clients.size >= 4) return error(s, "房间已满（最多 4 人）");
        s.room = r;
        r.clients.set(s.id, s);
        r.info.players.push({
          id: s.id,
          name: m.name.trim().slice(0, 16),
          kart: m.kart,
          ready: false,
          connected: true,
        });
        clearTimeout(joinTimeout);
        broadcast(r);
        return;
      }
      const r = s.room;
      if (!r) return;
      if (m.type === "ping") {
        if (Number.isFinite(m.time)) send(s, { type: "pong", time: m.time });
        return;
      }
      if (
        m.type === "ready" &&
        r.info.phase === "lobby" &&
        typeof m.ready === "boolean"
      ) {
        r.info.players.find((p) => p.id === s.id)!.ready = m.ready;
        broadcast(r);
      }
      if (m.type === "mode" && r.info.phase === "lobby") {
        if (r.info.host !== s.id) return error(s, "只有房主可以选择模式");
        if (m.mode !== "quick" && m.mode !== "arena")
          return error(s, "不支持的比赛模式");
        if (r.info.mode !== m.mode) {
          r.info.mode = m.mode;
          r.info.players.forEach((p) => (p.ready = false));
          broadcast(r);
        }
      }
      if (m.type === "start" && r.info.phase === "lobby") {
        if (r.info.host !== s.id) return error(s, "只有房主可以发车");
        if (r.clients.size > 1 && !r.info.players.every((p) => p.ready))
          return error(s, "多人比赛需所有车手准备后才能发车");
        // A lone driver gets three AI opponents. Multiplayer remains human-only.
        if (r.clients.size === 1) {
          const human = r.info.players[0];
          human.ready = true;
          for (let i = 1; i <= 3; i++) r.info.players.push({
            id: `bot-${randomUUID()}`, name: `电脑车手 ${i}`,
            kart: (human.kart + i) % KARTS.length, ready: true, connected: true, bot: true,
          });
        }
        r.race = new ServerRace(
          r.info.players.map((p) => ({ ...p })),
          r.info.mode,
        );
        r.info.phase = "countdown";
        for (const c of r.clients.values()) {
          c.controls = emptyControls();
          c.seq = -1;
        }
        broadcast(r);
      }
      if (m.type === "rematch" && r.info.phase === "results") {
        if (r.info.host !== s.id) return error(s, "等待房主开启下一场");
        r.race?.dispose();
        r.race = undefined;
        r.info.phase = "lobby";
        r.info.players = r.info.players.filter((p) => p.connected && !p.bot);
        r.info.players.forEach((p) => (p.ready = false));
        broadcast(r);
      }
      if (m.type === "input" && r.race && !r.race.done) {
        const c = m.controls;
        if (
          !Number.isSafeInteger(m.seq) ||
          m.seq <= s.seq ||
          !c ||
          !["steer", "throttle", "brake"].every((k) =>
            Number.isFinite(c[k as keyof Controls]),
          )
        )
          return;
        const next = emptyControls();
        next.steer = Math.max(-1, Math.min(1, c.steer));
        next.throttle = Math.max(0, Math.min(1, c.throttle));
        next.brake = Math.max(0, Math.min(1, c.brake));
        for (const k of [
          "drift",
          "backward",
          "jump",
          "item1",
          "item2",
          "reset",
          "discard",
        ] as const)
          next[k] = c[k] === true;
        for (const k of ["jump", "item1", "item2", "reset", "discard"] as const)
          next[k] ||= s.controls[k];
        s.controls = next;
        s.seq = m.seq;
        s.lastInput = performance.now();
      }
    } catch {
      error(s, "消息格式无效");
    }
  });
  ws.on("error", () => {});
  ws.on("close", () => {
    clearInterval(timer);
    clearTimeout(joinTimeout);
    const r = s.room;
    if (!r) return;
    r.clients.delete(s.id);
    const p = r.info.players.find((p) => p.id === s.id);
    if (p) p.connected = false;
    r.race?.disconnected.add(s.id);
    const kart =
      r.race?.karts[r.race.players.findIndex((p) => p.id === s.id) ?? -1];
    if (kart) {
      kart.disconnected = true;
      kart.collider.setSensor(true);
    }
    if (!r.clients.size) {
      r.race?.dispose();
      rooms.delete(r.info.code);
      return;
    }
    if (r.info.phase === "lobby")
      r.info.players = r.info.players.filter((p) => p.connected && !p.bot);
    if (r.info.host === s.id) r.info.host = r.clients.keys().next().value!;
    broadcast(r);
  });
});
let last = performance.now(),
  accumulator = 0;
setInterval(() => {
  const now = performance.now();
  accumulator += Math.min((now - last) / 1000, 0.25);
  last = now;
  while (accumulator >= 1 / 60) {
    accumulator -= 1 / 60;
    for (const r of rooms.values()) {
      if (!r.race || r.race.done) continue;
      const inputs = new Map<string, Controls>();
      for (const s of r.clients.values()) {
        if (now - s.lastInput > 500) s.controls = emptyControls();
        inputs.set(s.id, s.controls);
      }
      r.race.step(inputs);
      if (r.race.tick % 3 === 0 || r.race.done) {
        const snap = r.race.snapshot();
        if (r.info.phase !== snap.phase) {
          r.info.phase = snap.phase;
          broadcast(r);
        }
        for (const s of r.clients.values()) send(s, snap);
      }
    }
  }
}, 1000 / 60);
const port = Number(process.env.PORT) || 5173;
http.listen(port, "0.0.0.0", () => {
  console.log(`\n局域网多人服务器：http://localhost:${port}`);
  for (const list of Object.values(networkInterfaces()))
    for (const ip of list ?? [])
      if (ip.family === "IPv4" && !ip.internal)
        console.log(`同一 Wi-Fi 的朋友打开：http://${ip.address}:${port}`);
});
