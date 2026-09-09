import { KARTS } from "../config/game";
import type { Controls } from "../input/InputManager";
import type {
  ClientMessage,
  LanMode,
  Room,
  ServerMessage,
  Snapshot,
} from "./protocol";
export class LanClient {
  room?: Room;
  you = "";
  socket?: WebSocket;
  seq = 0;
  latestAt = 0;
  active = false;
  private shareAddress = location.origin;
  private panel: HTMLElement;
  private badge: HTMLElement;
  private status: HTMLElement;
  private timer?: number;
  onRoom: (room: Room, you: string) => void = () => {};
  onSnapshot: (s: Snapshot) => void = () => {};
  onLeave: () => void = () => {};
  constructor(root: HTMLElement) {
    root
      .querySelector("#home-actions")!
      .insertAdjacentHTML(
        "beforeend",
        '<button id="lan-btn" class="secondary-button">局域网竞技 · 2–4 人 ↗</button>',
      );
    root.insertAdjacentHTML(
      "beforeend",
      `<div class="modal-backdrop" id="lan-modal" hidden><section class="dialog lan-dialog"><div class="eyebrow">RACE WITH YOUR FRIENDS</div><h2>同一个 Wi-Fi，一起发车。</h2><div id="lan-entry"><p>朋友打开本机的局域网网址，输入相同房间码。</p><label>车手昵称<input id="lan-name" maxlength="16" placeholder="输入昵称" value="口袋车手" /></label><label>选择赛车<select id="lan-kart">${KARTS.map((k, i) => `<option value="${i}">${k.name} · ${k.vehicle}</option>`).join("")}</select></label><label>房间码<input id="lan-code" maxlength="6" placeholder="加入朋友的 6 位房间码" autocapitalize="characters" /></label><div class="lan-actions"><button id="lan-create" class="primary">创建房间</button><button id="lan-join" class="secondary-button">加入房间</button></div></div><div id="lan-room" hidden><div class="lan-code-row">房间码 <strong id="lan-room-code" data-selectable></strong></div><p id="lan-address" data-selectable></p><label>比赛模式<select id="lan-mode"><option value="quick">山谷竞速 · 3 圈</option><option value="arena">星火竞技场 · 道具乱斗</option></select></label><p id="lan-rules"></p><div id="lan-players"></div><div class="lan-actions"><button id="lan-ready" class="secondary-button">准备</button><button id="lan-start" class="primary">全员准备后发车</button></div></div><p id="lan-status" role="status"></p><button id="lan-close" class="text-button">返回主菜单</button></section></div><div id="lan-badge" hidden><span id="lan-live"></span><button id="lan-exit">退出房间</button></div>`,
    );
    this.panel = root.querySelector("#lan-modal")!;
    this.badge = root.querySelector("#lan-badge")!;
    this.status = root.querySelector("#lan-status")!;
    const on = (id: string, fn: () => void) =>
      root.querySelector(id)!.addEventListener("click", fn);
    on("#lan-btn", () => {
      this.panel.hidden = false;
      this.status.textContent = "至少 2 人，最多 4 人；全员准备后由房主发车。";
    });
    on("#lan-close", () => this.leave());
    on("#lan-exit", () => this.leave());
    on("#lan-create", () => this.connect(""));
    on("#lan-join", () => {
      const code = root
        .querySelector<HTMLInputElement>("#lan-code")!
        .value.trim();
      if (!code) {
        this.status.textContent = "请输入房间码";
        return;
      }
      this.connect(code);
    });
    on("#lan-ready", () =>
      this.send({
        type: "ready",
        ready: !this.room?.players.find((p) => p.id === this.you)?.ready,
      }),
    );
    on("#lan-start", () => this.send({ type: "start" }));
    root.querySelector<HTMLSelectElement>("#lan-mode")!.onchange = (e) =>
      this.send({
        type: "mode",
        mode: (e.target as HTMLSelectElement).value as LanMode,
      });
  }
  private connect(code: string) {
    if (this.socket) return;
    clearInterval(this.timer);
    const name = document
      .querySelector<HTMLInputElement>("#lan-name")!
      .value.trim();
    if (!name) {
      this.status.textContent = "请输入车手昵称";
      return;
    }
    this.status.textContent = "正在连接局域网服务器…";
    const ws = (this.socket = new WebSocket(
      `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/lan`,
    ));
    const timeout = window.setTimeout(() => {
      if (!this.room) {
        this.status.textContent = "连接超时，请确认使用 npm run lan 启动服务器";
        ws.close();
      }
    }, 8000);
    ws.onopen = () =>
      this.send({
        type: "join",
        version: 2,
        code,
        name,
        kart: Number(
          document.querySelector<HTMLSelectElement>("#lan-kart")!.value,
        ),
      });
    ws.onmessage = (e) => {
      if (this.socket !== ws) return;
      const m = JSON.parse(e.data) as ServerMessage;
      if (m.type === "error") {
        this.status.textContent = m.message;
        if (!this.room) ws.close();
        return;
      }
      if (m.type === "room") {
        clearTimeout(timeout);
        this.active = true;
        this.shareAddress = ["localhost", "127.0.0.1", "[::1]"].includes(
          location.hostname,
        )
          ? (m.urls.find((url) =>
              /^http:\/\/(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)/.test(
                url,
              ),
            ) ??
            m.urls[0] ??
            "主机终端显示的局域网网址")
          : location.origin;
        this.room = m.room;
        this.you = m.you;
        this.renderRoom();
        this.onRoom(m.room, m.you);
      }
      if (m.type === "snapshot") {
        this.latestAt = performance.now();
        this.onSnapshot(m);
      }
      if (m.type === "pong")
        document.querySelector("#lan-live")!.textContent =
          `房间 ${this.room?.code} · ${Math.round(performance.now() - m.time)} ms`;
    };
    ws.onclose = () => {
      clearTimeout(timeout);
      if (this.socket !== ws) return;
      this.socket = undefined;
      clearInterval(this.timer);
      if (this.active) {
        this.leave();
        this.panel.hidden = false;
        this.status.textContent =
          "连接已断开。请重新加入房间；正在进行的比赛会将掉线车手记为未完赛。";
      } else if (this.status.textContent === "正在连接局域网服务器…")
        this.status.textContent =
          "无法连接，请在主机运行 npm run lan，并使用主机的局域网网址。";
    };
    ws.onerror = () => {
      this.status.textContent = "无法连接局域网服务器，请检查主机地址和网络。";
    };
    this.timer = window.setInterval(() => {
      this.send({ type: "ping", time: performance.now() });
      if (
        this.room &&
        ["countdown", "racing"].includes(this.room.phase) &&
        this.latestAt &&
        performance.now() - this.latestAt > 3000
      )
        document.querySelector("#lan-live")!.textContent =
          "网络中断，等待服务器…";
    }, 2000);
  }
  private renderRoom() {
    const r = this.room!;
    const selector = document.querySelector<HTMLSelectElement>("#lan-mode")!;
    selector.value = r.mode;
    selector.disabled = r.host !== this.you;
    document.querySelector("#lan-rules")!.textContent =
      r.mode === "arena"
        ? "星火玩具竞技场 · 3 分钟自由乱斗。道具命中对手 +1 分，同分并列；不跑圈。切换模式后需要重新准备。"
        : "发条蘑菇山谷 · 三圈竞速，先冲线获胜。切换模式后需要重新准备。";
    this.panel.hidden = r.phase !== "lobby";
    this.badge.hidden = r.phase === "lobby";
    document.querySelector<HTMLElement>("#lan-entry")!.hidden = true;
    document.querySelector<HTMLElement>("#lan-room")!.hidden = false;
    document.querySelector("#lan-room-code")!.textContent = r.code;
    document.querySelector("#lan-address")!.textContent =
      `访问 ${this.shareAddress}，加入房间 ${r.code}。`;
    const list = document.querySelector("#lan-players")!;
    list.replaceChildren();
    for (const p of r.players) {
      const row = document.createElement("div");
      row.className = "lan-player";
      row.textContent = `${p.id === r.host ? "♛ " : ""}${p.name}${p.id === this.you ? "（你）" : ""} · ${KARTS[p.kart].vehicle} · ${!p.connected ? "已掉线" : p.ready ? "已准备" : "等待准备"}`;
      list.append(row);
    }
    document.querySelector("#lan-ready")!.textContent = r.players.find(
      (p) => p.id === this.you,
    )?.ready
      ? "取消准备"
      : "准备";
    const start = document.querySelector<HTMLButtonElement>("#lan-start")!;
    start.hidden = r.host !== this.you;
    start.disabled = r.players.length < 2 || !r.players.every((p) => p.ready);
    this.status.textContent =
      r.host === this.you
        ? "你是房主 · 全员准备后点击发车"
        : "等待所有车手准备，由房主发车";
  }
  input(controls: Controls) {
    if (
      this.room &&
      this.room.phase !== "lobby" &&
      this.room.phase !== "results"
    )
      this.send({ type: "input", seq: this.seq++, controls });
  }
  send(m: ClientMessage) {
    if (this.socket?.readyState === WebSocket.OPEN)
      this.socket.send(JSON.stringify(m));
  }
  leave() {
    const was = this.active;
    this.active = false;
    this.room = undefined;
    const ws = this.socket;
    this.socket = undefined;
    ws?.close();
    clearInterval(this.timer);
    this.panel.hidden = true;
    this.badge.hidden = true;
    document.querySelector<HTMLElement>("#lan-entry")!.hidden = false;
    document.querySelector<HTMLElement>("#lan-room")!.hidden = true;
    if (was) this.onLeave();
  }
}
