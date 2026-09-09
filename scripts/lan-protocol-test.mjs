import WebSocket from "ws";
import assert from "node:assert/strict";
const clients = [];
async function client() {
  const ws = new WebSocket("ws://localhost:5173/lan");
  const messages = [];
  ws.on("message", (d) => messages.push(JSON.parse(d)));
  await new Promise((r) => ws.once("open", r));
  const c = {
    ws,
    messages,
    send: (m) => ws.send(JSON.stringify(m)),
    wait: async (type) => {
      const end = Date.now() + 5000;
      while (Date.now() < end) {
        const i = messages.findIndex((m) => m.type === type);
        if (i >= 0) return messages.splice(i, 1)[0];
        await new Promise((r) => setTimeout(r, 20));
      }
      throw Error("Timed out: " + type);
    },
  };
  clients.push(c);
  return c;
}
try {
  const a = await client();
  a.send({ type: "join", version: 2, code: "", name: "A", kart: 0 });
  const room = (await a.wait("room")).room;
  a.send({ type: "start" });
  assert.match((await a.wait("error")).message, /至少/);
  const b = await client();
  b.send({ type: "join", version: 2, code: room.code, name: "B", kart: 1 });
  await b.wait("room");
  b.send({type:'mode',mode:'arena'});assert.match((await b.wait('error')).message,/房主/);
  a.send({type:'ready',ready:true});b.send({type:'ready',ready:true});await new Promise(r=>setTimeout(r,100));b.messages.length=0;
  a.send({type:'mode',mode:'arena'});const changed=await b.wait('room');assert.equal(changed.room.mode,'arena');assert.ok(changed.room.players.every(p=>!p.ready));
  a.send({type:'mode',mode:'quick'});await new Promise(r=>setTimeout(r,100));
  b.send({ type: "start" });
  assert.match((await b.wait("error")).message, /房主/);
  for (let i = 2; i < 4; i++) {
    const c = await client();
    c.send({
      type: "join",
      version: 2,
      code: room.code,
      name: "C" + i,
      kart: i,
    });
    await c.wait("room");
  }
  const fifth = await client();
  fifth.send({
    type: "join",
    version: 2,
    code: room.code,
    name: "Fifth",
    kart: 0,
  });
  assert.match((await fifth.wait("error")).message, /已满/);
  for (const c of clients.slice(0, 4)) c.send({ type: "ready", ready: true });
  await new Promise((r) => setTimeout(r, 100));
  a.send({ type: "start" });
  const snap = await a.wait("snapshot");
  assert.equal(snap.karts.length, 4);
  assert.equal(snap.phase, "countdown");
  a.ws.close();
  let transferred;
  for (let n = 0; n < 12; n++) {
    const r = await b.wait("room");
    if (r.room.host === r.you) {
      transferred = r;
      break;
    }
  }
  assert.ok(transferred);
  console.log(
    "PASS: minimum players, host-only start, four-player capacity, authoritative snapshot, host transfer",
  );
} finally {
  clients.forEach((c) => c.ws.close());
}
