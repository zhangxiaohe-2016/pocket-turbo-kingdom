// PTKProtocol.h —— 口袋涡轮王国 · 局域网协议 v2 的消息模型与编解码。
//
// 所有字段与 src/network/protocol.ts 的 Snapshot / Room / Player / KartState 一一对应。
// 渲染层只碰这些对象，不碰裸 NSDictionary。
//
// 健壮性约定（服务器 snapshot 每 50ms 来一发，绝不能因为一个脏字段整帧丢掉）：
//  * 数字字段：只接受 NSNumber 且 isfinite；缺失/类型异常 -> 用 0（或 -1）兜底
//  * 字符串字段：只接受 NSString；缺失 -> @""
//  * 数组字段：只接受 NSArray；元素类型不对 -> 跳过
//  * slots 里的 null -> NSNull（渲染层判空用 `slots[i] == NSNull.null`）
#import <Foundation/Foundation.h>

/// 上行 controls（见 server/index.ts 的 input 分支）。
/// steer/throttle/brake 必须同时存在且有限，服务器才接受这一帧输入。
@interface PTKControls : NSObject
@property (nonatomic) double steer;    // -1..1
@property (nonatomic) double throttle; // 0..1
@property (nonatomic) double brake;    // 0..1
@property (nonatomic) BOOL drift, backward, jump, item1, item2, reset, discard;
- (NSDictionary *)dictionary;
@end

/// 下行单车状态（对应 protocol.ts 的 KartState）。
@interface PTKKartState : NSObject
@property (nonatomic, copy) NSString *kartId; ///< 服务器 player id（不是车型 id）
@property (nonatomic) float px, py, pz;       ///< position
@property (nonatomic) float vx, vy, vz;       ///< velocity
@property (nonatomic) float yaw, speed, steering;
@property (nonatomic) BOOL grounded, drift, disconnected, finished;
@property (nonatomic) float driftCharge;
@property (nonatomic) NSInteger driftLevel;
@property (nonatomic) float boost, stun, invulnerable;
@property (nonatomic) NSInteger lap, rank, nextCheckpoint, lastCheckpoint, score, hitsTaken;
@property (nonatomic) float progress, finishTime;
@property (nonatomic, copy) NSArray *slots; ///< 4 个元素：NSString 或 NSNull
@end

/// 场上道具（对应 protocol.ts 的 items[i]）。
@interface PTKItemState : NSObject
@property (nonatomic) NSInteger index;  ///< 道具池下标
@property (nonatomic, copy) NSString *kind; ///< battery / peel / gear / firefly
@property (nonatomic) float px, py, pz;
@end

/// 20Hz 权威快照（对应 protocol.ts 的 Snapshot）。
@interface PTKSnapshot : NSObject
@property (nonatomic) NSInteger tick;
@property (nonatomic) double elapsed, countdown, goFlash;
@property (nonatomic, copy) NSString *phase; ///< lobby / countdown / racing / results
@property (nonatomic, copy) NSArray<PTKKartState *> *karts;
@property (nonatomic, copy) NSArray<NSNumber *> *boxes; ///< 道具箱冷却（秒）
@property (nonatomic, copy) NSArray<PTKItemState *> *items;
+ (instancetype)snapshotFromDictionary:(NSDictionary *)dict;
@end

@interface PTKPlayer : NSObject
@property (nonatomic, copy) NSString *playerId, *name;
@property (nonatomic) NSInteger kart;
@property (nonatomic) BOOL ready, connected;
/// 服务器派生的电脑车手（单人发车时服务端会补 3 个）
@property (nonatomic) BOOL bot;
@end

@interface PTKRoom : NSObject
@property (nonatomic, copy) NSString *code, *host, *mode, *phase;
@property (nonatomic, copy) NSArray<PTKPlayer *> *players;
@end

/// 统一入口：解析任意服务器消息（room / snapshot / error / pong）。
/// 非法 JSON 返回 type = @"unknown" 的对象，绝不返回 nil、绝不抛异常。
@interface PTKServerMessage : NSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, strong) PTKRoom *room;
@property (nonatomic, copy) NSString *you;
@property (nonatomic, copy) NSArray<NSString *> *urls;
@property (nonatomic, strong) PTKSnapshot *snapshot;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic) double pongTime;
+ (instancetype)messageFromJSON:(NSString *)json;
@end

// ---- 上行消息构造（返回已序列化的 JSON 字符串，可直接丢给 PTKWebSocket.sendText:）----
NSString *PTKJoinMessage(NSString *code, NSString *name, NSInteger kart); ///< code 为空 = 创建房间
NSString *PTKReadyMessage(BOOL ready);
NSString *PTKModeMessage(NSString *mode);
NSString *PTKStartMessage(void);
NSString *PTKRematchMessage(void);
NSString *PTKInputMessage(long long seq, PTKControls *controls);
NSString *PTKPingMessage(double time);

/// 协议版本号，与 src/network/protocol.ts 的 PROTOCOL_VERSION 一致。
FOUNDATION_EXPORT const NSInteger PTKProtocolVersion;
