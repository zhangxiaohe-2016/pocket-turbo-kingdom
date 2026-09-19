// 极简设备探测收集器：静态托管 diag 页面，接收 iPad 回传的能力报告。
// 用法：node ios/diag/server.mjs [port]
import { createServer } from "node:http";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { networkInterfaces } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const reports = join(here, "reports");
const port = Number(process.argv[2] || 8123);
await mkdir(reports, { recursive: true });

const server = createServer(async (req, res) => {
  if (req.method === "POST" && req.url === "/report") {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks).toString("utf8");
    let pretty = body;
    try {
      pretty = JSON.stringify(JSON.parse(body), null, 2);
    } catch {}
    const file = join(reports, `${new Date().toISOString().replace(/[:.]/g, "-")}.json`);
    await writeFile(file, pretty);
    console.log(`\n===== iPad 能力报告 @ ${new Date().toLocaleTimeString()} =====`);
    console.log(pretty);
    console.log(`===== 已保存: ${file} =====\n`);
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok");
    return;
  }
  try {
    const html = await readFile(join(here, "index.html"));
    res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    res.end(html);
  } catch (e) {
    res.writeHead(500).end(String(e));
  }
});

server.listen(port, "0.0.0.0", () => {
  console.log(`设备探测页已启动（等待 iPad 打开）：`);
  console.log(`  本机:        http://localhost:${port}/`);
  for (const [name, list] of Object.entries(networkInterfaces())) {
    for (const i of list || []) {
      if (i.family === "IPv4" && !i.internal) console.log(`  ${name.padEnd(11)} http://${i.address}:${port}/`);
    }
  }
});
