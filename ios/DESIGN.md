# Pocket Turbo Kingdom · iPad mini 2 原生客户端设计

目标机型：**iPad4,4 / iPad mini 2 / A7 / 1GB / iOS 12.5.8**（只支持 WebGL1、WASM 仅 MVP）→ 放弃 WKWebView 路线，改为
**ObjC + SceneKit 薄客户端**：局域网模式下 Node 服务器是权威物理，客户端只做「渲染 snapshot + 上传输入」。

## 1. 与服务器的契约（协议 v2，不可改）

- 端点：`ws://<host>:5173/lan`（明文 WebSocket，RFC6455）
- 服务器 **每 5 秒发 ping 控制帧**；客户端必须回 pong，否则 5 秒后被 terminate
- 服务器每 tick（60Hz）推进物理，每 3 tick 广播一次 `snapshot`（20 Hz）
- 客户端发 `input` 时 `seq` 必须严格递增；服务器在 500 ms 无输入后清空该玩家控制
- 入房 10 秒内必须发 `join`，否则连接被关闭
- 单人消息速率上限 600 条/5 秒

客户端上行：
```json
{"type":"join","version":2,"code":"","name":"口袋车手","kart":0}
{"type":"ready","ready":true}
{"type":"mode","mode":"quick|arena"}      // 仅房主
{"type":"start"}                          // 仅房主，≥2 人且全员准备
{"type":"rematch"}                        // 仅房主，results 阶段
{"type":"input","seq":1,"controls":{...}} // 见下
{"type":"ping","time":123.4}
```

`controls` 字段：`steer(-1..1), throttle(0..1), brake(0..1), drift(bool), backward(bool), jump(bool),
item1(bool), item2(bool), reset(bool), discard(bool)`。`jump/item1/item2/reset/discard` 在服务器侧是边沿保持
（`next[k] ||= s.controls[k]`），所以**按下后要在下一帧置回 false**，否则会连发。

下行：`room`（含 room/you/urls）、`snapshot`（见 `src/network/protocol.ts` 的 `Snapshot`）、`error`、`pong`。

## 2. 客户端架构

```
ios/PocketTurboKingdom/
  client/
    main.m  AppDelegate.{h,m}
    Net/    PTKWebSocket.{h,m}   RFC6455 over CFStream，无第三方依赖（可移植到 macOS 测试）
            PTKProtocol.{h,m}    消息编解码 + Snapshot 模型
            PTKLanClient.{h,m}   连接状态机（join/ready/start/input/ping/heartbeat）
    Render/ PTKTrackData.{h,m}   读取 .ptkgeo → SCNGeometry / SCNMaterial
            PTKWorldBuilder.{h,m} 赛道/场景/竞技场装配
            PTKKartNode.{h,m}     SceneKit 图元拼装赛车（轮子转动、转向、漂移倾斜、尾焰）
            PTKItemNode.{h,m}     电池/果皮/齿轮/萤火虫 + 晶体道具箱
            PTKChaseCamera.{h,m}  追尾相机
    UI/     PTKLobbyView.{h,m}   昵称/选车/房间码/创建/加入/准备/发车/房间列表
            PTKTouchControls.{h,m} 左虚拟摇杆 + 右油门/刹车/漂移/跳跃/道具
            PTKHUD.{h,m}         圈数/名次/速度/道具槽/倒计时/结算
    GameViewController.{h,m}     SCNView + 主循环 + 快照插值
  export/export-scene.mjs        Node 侧从 three.js 场景导出 .ptkgeo（与物理赛道严格对齐）
  tools/scnshot.m                macOS 离屏渲染工具：把 .ptkgeo 渲成 PNG，先在 Mac 上验证渲染
  tests/                         macOS 上可执行的单元测试（clang + Foundation），作为 build.sh 门槛
  build.sh                      在 ruok（Mac mini，Xcode）上编译 + ldid 签名 + dpkg-deb 打包
  dev.sh                        本机 → rsync 到 ruok → 远程 build.sh → 取回 .deb
```

## 3. 几何资产格式 `.ptkgeo`

二进制：`magic "PTKG"` + `u32 version=1` + `u32 jsonLength` + JSON(UTF-8) + payload。
JSON 里的 `offset` 相对 payload 起点，`count` 指**元素个数**。

```json
{
  "version": 1,
  "materials": [
    {"key":"road","color":[0.86,0.72,0.53],"roughness":0.92,"metalness":0.0,
     "doubleSided":true,"emissive":null,"transparent":false,"vertexColors":true}
  ],
  "nodes": [
    {"name":"road","material":"road","transform":[16 floats, 列主序, 缺省单位矩阵],
     "position":{"offset":0,"count":3078,"type":"f32"},
     "normal":{"offset":36936,"count":3078,"type":"f32"},
     "color":{"offset":73872,"count":3078,"type":"f32"},
     "indices":{"offset":110808,"count":6132,"type":"u32"}}
  ],
  "signs": [
    {"text":"POCKET TURBO","width":10.6,"height":1.18,"color":"#fff1ca",
     "transform":[16 floats]}
  ]
}
```

约定：
- 所有几何在导出时**已经烘焙世界变换**（`transform` 恒为单位矩阵时省略），SceneKit 侧一个 node 一个 draw call。
- `position/normal/color` 均为 3×f32；`color` 可选（顶点色 / instancedColor 合并进来）。
- `indices` 为 u16 或 u32，SceneKit 侧统一按 u32 处理（iOS 12 支持）。
- 带 canvas 贴图的指示牌不导出成几何，改为 `signs` 条目，客户端用 `SCNText` 或 CoreGraphics 贴图重建。
- 场景物密度通过导出时调用 `Track.setSceneryDensity(ratio)` 控制，默认 1.0；若 A7 掉帧则降到 0.45。

## 4. 关键实现约束（iOS 12 / A7）

- ObjC + ARC，不用 Swift（避开 iOS 12.0 无 Swift ABI 稳定性的麻烦），不用第三方库
- 不使用 `URLSessionWebSocketTask`（iOS 13+），WS 客户端基于 `CFStreamCreatePairWithSocketToHost`
- 不使用 `SCNScene` 的 PBR 高级特性；`SCNMaterial.lightingModelName = SCNLightingModelBlinn`（A7 上比 PBR 快得多）
- 阴影：`SCNView` 关闭或仅用一个方向光 + 小 shadow map；优先保证 30fps
- 渲染分辨率：`contentsScale` 固定 1.0（768×1024 逻辑分辨率已足够），必要时降到 0.75
- 顶点色：SceneKit 支持 `.color` semantic，与 `diffuse` 相乘
- 场景物（草 700 / 蘑菇 390+130 / 树 110 / 云 72）在导出阶段合并成单个静态 mesh，避免 1500 个 SCNNode

## 5. 里程碑

- **M1 协议层**：`PTKWebSocket` + `PTKProtocol` + macOS 测试工具，能连上 `npm run lan` 的服务器真实入房、收 snapshot
- **M2 几何与渲染**：`export-scene.mjs` 产出 `.ptkgeo`；ObjC 加载器 + `scnshot` 在 Mac 上离屏渲出 PNG 验证
- **M3 iOS 客户端**：大厅 + 触屏 + HUD + 快照插值，在 ruok 上打成 `.deb`
- **M4 iPad 实测**：Sileo 安装、与 Web 版同房对战、性能调优
