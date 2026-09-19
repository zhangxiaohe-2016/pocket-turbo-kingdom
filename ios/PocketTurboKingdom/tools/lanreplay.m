// lanreplay —— macOS 无头联调：用客户端自己的 Net + Render 代码连真实服务器打一场，把 snapshot 渲成 PNG。
//
//   clang -fobjc-arc ... client/Net/PTKWebSocket.m client/Net/PTKProtocol.m \
//     client/Render/PTKTrackData.m client/Render/PTKKartNode.m client/Render/PTKWorldBuilder.m \
//     tools/lanreplay.m -o /tmp/lanreplay
//   /tmp/lanreplay assets/track.ptkgeo /tmp/ptkshots/lan --host 127.0.0.1:5173 --seconds 8
//
// 它会开两条 WebSocket：A 建房、B 用房间码加入，双方准备后 A 发车，
// 然后 10Hz 推油门，按真实 snapshot 驱动渲染。iPad 上跑的插值公式与这里逐行一致。
#import <Foundation/Foundation.h>
#import <SceneKit/SceneKit.h>
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import "PTKTrackData.h"
#import "PTKKartNode.h"
#import "PTKWorldBuilder.h"
#import "PTKWebSocket.h"
#import "PTKProtocol.h"

@interface PTKTestKart : NSObject
@property (nonatomic, copy) NSString *playerId, *name;
@property (nonatomic, strong) PTKKartNode *node;
@property (nonatomic) SCNVector3 previousPosition, position;
@property (nonatomic) CGFloat previousYaw, yaw, speed, steering, boost, invulnerable, bank;
@property (nonatomic) BOOL grounded, drift, initialized, finished;
@property (nonatomic) NSInteger lap, rank;
@end

@implementation PTKTestKart
@end

@interface PTKReplay : NSObject <PTKWebSocketDelegate>
@property (nonatomic) NSInteger snapshots, frames, shots;
@property (nonatomic, copy) NSString *roomCode, *host;
@property (nonatomic) BOOL started, finished, readySent, kartsReady;
@end

static PTKReplay *gReplay;
static PTKWebSocket *gSocketA, *gSocketB;
static PTKTrackData *gData;
static PTKTrackPath *gPath;
static SCNScene *gScene;
static SCNNode *gCamera, *gWorld;
static NSMutableArray<PTKTestKart *> *gKarts;
static NSMutableArray<PTKItemBoxNode *> *gBoxes;
static NSMutableArray<PTKObstacleNode *> *gObstacles;
static NSMutableArray<PTKProjectileNode *> *gProjectiles;
static NSString *gOutPrefix;
static double gStartTime, gSeconds, gLastInput, gLastPose;
static long long gSeqA, gSeqB;
static CGFloat gFov = 64;
static double gTime;

static double now(void) { return [NSDate date].timeIntervalSince1970; }

#pragma mark - 场景

static void buildScene(PTKTrackData *data) {
  gScene = [SCNScene scene];
  gScene.background.contents = PTKColor(0.70, 0.85, 0.84);
  gScene.fogColor = PTKColor(0.70, 0.85, 0.84);
  gScene.fogStartDistance = 110;
  gScene.fogEndDistance = 420;

  SCNNode *ambient = [SCNNode node];
  ambient.light = [SCNLight light];
  ambient.light.type = SCNLightTypeAmbient;
  ambient.light.color = PTKColor(0.66, 0.76, 0.74);
  ambient.light.intensity = 900;
  [gScene.rootNode addChildNode:ambient];

  SCNNode *sun = [SCNNode node];
  sun.light = [SCNLight light];
  sun.light.type = SCNLightTypeDirectional;
  sun.light.color = PTKColor(1.0, 0.93, 0.78);
  sun.light.intensity = 1000;
  sun.position = SCNVector3Make(30, 65, 20);
  [sun lookAt:SCNVector3Zero up:SCNVector3Make(0, 1, 0) localFront:SCNVector3Make(0, 0, -1)];
  [gScene.rootNode addChildNode:sun];

  gCamera = [SCNNode node];
  gCamera.camera = [SCNCamera camera];
  gCamera.camera.zNear = 0.3;
  gCamera.camera.zFar = 700;
  gCamera.camera.fieldOfView = 64;
  [gScene.rootNode addChildNode:gCamera];

  gWorld = [SCNNode node];
  [gScene.rootNode addChildNode:gWorld];
  [gWorld addChildNode:[data buildStaticScene]];

  gBoxes = [NSMutableArray array];
  for (PTKAnchor *anchor in data.boxes) {
    PTKItemBoxNode *box = [[PTKItemBoxNode alloc] initWithPosition:anchor.position];
    [gWorld addChildNode:box.node];
    [gBoxes addObject:box];
  }
  gObstacles = [NSMutableArray array];
  for (PTKAnchor *anchor in data.obstacles) {
    PTKObstacleNode *obstacle = [[PTKObstacleNode alloc] initWithAnchor:anchor];
    [gWorld addChildNode:obstacle.node];
    [gObstacles addObject:obstacle];
  }
  gProjectiles = [NSMutableArray array];
  for (int i = 0; i < 36; i++) {
    PTKProjectileNode *projectile = [[PTKWorldBuilder shared] nextProjectile];
    [gWorld addChildNode:projectile.node];
    [gProjectiles addObject:projectile];
  }
}

static void renderFrame(NSString *path, double time) {
  SCNRenderer *renderer = [SCNRenderer rendererWithDevice:nil options:nil];
  renderer.scene = gScene;
  renderer.pointOfView = gCamera;
  renderer.autoenablesDefaultLighting = NO;
  NSImage *image = [renderer snapshotAtTime:time withSize:CGSizeMake(1024, 768) antialiasingMode:SCNAntialiasingModeMultisampling4X];
  if (!image) { printf("渲染失败\n"); return; }
  CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
  CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
  if (!destination) return;
  CGImageDestinationAddImage(destination, cg, NULL);
  CGImageDestinationFinalize(destination);
  CFRelease(destination);
  printf("  渲染 → %s\n", path.lastPathComponent.UTF8String);
}

#pragma mark - 快照

static void applySnapshot(PTKSnapshot *snapshot) {
  gReplay.snapshots++;
  for (PTKKartState *state in snapshot.karts) {
    PTKTestKart *kart = nil;
    for (PTKTestKart *candidate in gKarts) if ([candidate.playerId isEqualToString:state.kartId]) kart = candidate;
    if (!kart) continue;
    kart.previousPosition = kart.initialized ? kart.position : SCNVector3Make(state.px, state.py, state.pz);
    kart.previousYaw = kart.initialized ? kart.yaw : state.yaw;
    kart.initialized = YES;
    kart.position = SCNVector3Make(state.px, state.py, state.pz);
    kart.yaw = state.yaw;
    kart.speed = state.speed;
    kart.steering = state.steering;
    kart.boost = state.boost;
    kart.invulnerable = state.invulnerable;
    kart.grounded = state.grounded;
    kart.drift = state.drift;
    kart.lap = state.lap;
    kart.rank = state.rank;
    kart.finished = state.finished;
    if (gPath) {
      PTKTrackSample *sample = [gPath nearest:kart.position];
      kart.bank = sample ? sample.bank : 0;
    }
  }
  for (NSUInteger i = 0; i < gBoxes.count; i++) {
    BOOL available = i < snapshot.boxes.count ? snapshot.boxes[i].doubleValue <= 0.001 : YES;
    [gBoxes[i] setAvailable:available];
  }
  for (PTKProjectileNode *projectile in gProjectiles) projectile.node.hidden = YES;
  for (PTKItemState *item in snapshot.items) {
    if (item.index < 0 || item.index >= (NSInteger)gProjectiles.count) continue;
    PTKProjectileNode *projectile = gProjectiles[item.index];
    [projectile setKind:item.kind];
    projectile.node.position = SCNVector3Make(item.px, item.py, item.pz);
  }
}

static void stepVisuals(double dt) {
  for (PTKTestKart *kart in gKarts) {
    PTKKartVisual visual;
    visual.previousPosition = kart.previousPosition;
    visual.position = kart.position;
    visual.previousYaw = kart.previousYaw;
    visual.yaw = kart.yaw;
    visual.speed = kart.speed;
    visual.steering = kart.steering;
    visual.boost = kart.boost;
    visual.invulnerable = kart.invulnerable;
    visual.bank = kart.bank;
    visual.grounded = kart.grounded;
    visual.drift = kart.drift;
    visual.airborne = !kart.grounded;
    [kart.node applyVisual:visual alpha:1.0 dt:dt time:gTime];
  }
  if (gKarts.count == 0) return;
  PTKTestKart *local = gKarts[0];
  SCNVector3 forward = SCNVector3Make(sin(local.yaw), 0, cos(local.yaw));
  SCNVector3 focus = SCNVector3Make(local.position.x + forward.x * 13, local.position.y + 1.3, local.position.z + forward.z * 13);
  gCamera.position = SCNVector3Make(local.position.x - forward.x * 9.6, local.position.y + 3.5, local.position.z - forward.z * 9.6);
  [gCamera lookAt:focus up:SCNVector3Make(0, 1, 0) localFront:SCNVector3Make(0, 0, -1)];
  gFov = 64 + MIN(16, fabs(local.speed) * 0.42);
  gCamera.camera.fieldOfView = gFov;
}

#pragma mark - 状态机

@implementation PTKReplay

- (void)webSocketDidOpen:(PTKWebSocket *)ws {
  if (ws == gSocketA) {
    printf("A 已连接，建房\n");
    [ws sendText:PTKJoinMessage(@"", @"测试A", 0)];
  } else {
    printf("B 已连接，用房间码 %s 加入\n", self.roomCode.UTF8String);
    [ws sendText:PTKJoinMessage(self.roomCode, @"测试B", 1)];
  }
}

- (void)webSocket:(PTKWebSocket *)ws didReceiveText:(NSString *)text {
  PTKServerMessage *message = [PTKServerMessage messageFromJSON:text];
  if ([message.type isEqualToString:@"room"]) {
    PTKRoom *room = message.room;
    if (!self.roomCode.length) {
      self.roomCode = room.code;
      printf("A 建房成功: %s（phase=%s, %lu 人）\n", room.code.UTF8String, room.phase.UTF8String, (unsigned long)room.players.count);
      gSocketB = [[PTKWebSocket alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"ws://%@/lan", self.host]] delegate:self];
      [gSocketB open];
      return;
    }
    if (room.players.count < 2) return;
    if (!self.readySent) {
      self.readySent = YES;
      printf("房间 %s 两人到齐，双方准备\n", room.code.UTF8String);
      [gSocketA sendText:PTKReadyMessage(YES)];
      [gSocketB sendText:PTKReadyMessage(YES)];
      return;
    }
    BOOL allReady = YES;
    for (PTKPlayer *player in room.players) if (!player.ready) allReady = NO;
    if (allReady && !self.started && [room.host isEqualToString:message.you]) {
      self.started = YES;
      printf("全员准备 → 发车（房主 %s）\n", message.you.UTF8String);
      [gSocketA sendText:PTKStartMessage()];
    }
    if ([room.phase isEqualToString:@"results"]) {
      printf("比赛结束，服务器结算\n");
      self.finished = YES;
    }
    return;
  }
  if ([message.type isEqualToString:@"snapshot"]) {
    if (!self.kartsReady) {
      // 第一次 snapshot：按房间玩家顺序建车（与 iPad 客户端同样的顺序假设）
      NSMutableArray<NSString *> *ids = [NSMutableArray array];
      for (PTKKartState *state in message.snapshot.karts) [ids addObject:state.kartId];
      gKarts = [NSMutableArray array];
      NSArray<NSString *> *names = @[ @"测试A", @"测试B" ];
      for (NSUInteger i = 0; i < ids.count; i++) {
        NSInteger specIndex = MIN((NSInteger)gData.karts.count - 1, (NSInteger)i);
        PTKTestKart *kart = [PTKTestKart new];
        kart.playerId = ids[i];
        kart.name = i < names.count ? names[i] : @"车手";
        kart.node = [PTKKartNode kartWithSpec:gData.karts[specIndex] ghost:NO];
        [gWorld addChildNode:kart.node.root];
        [gKarts addObject:kart];
      }
      self.kartsReady = YES;
      printf("首帧 snapshot：%lu 辆车，tick=%ld phase=%s\n", (unsigned long)ids.count, (long)message.snapshot.tick, message.snapshot.phase.UTF8String);
    }
    applySnapshot(message.snapshot);
    return;
  }
  if ([message.type isEqualToString:@"error"]) {
    printf("服务器错误: %s\n", message.errorMessage.UTF8String);
  }
}

- (void)webSocket:(PTKWebSocket *)ws didCloseWithCode:(NSInteger)code reason:(NSString *)reason {
  printf("连接关闭 code=%ld reason=%s\n", (long)code, reason.UTF8String);
}

- (void)webSocket:(PTKWebSocket *)ws didFailWithError:(NSError *)error {
  printf("连接失败: %s\n", error.localizedDescription.UTF8String);
}

@end

#pragma mark - main

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    if (args.count < 3) {
      fprintf(stderr, "用法: lanreplay <track.ptkgeo> <输出前缀> [--host ip:port] [--seconds N]\n");
      return 2;
    }
    NSString *geoPath = args[1];
    gOutPrefix = args[2];
    NSString *host = @"127.0.0.1:5173";
    gSeconds = 8;
    for (NSUInteger i = 3; i + 1 < args.count; i++) {
      if ([args[i] isEqualToString:@"--host"]) host = args[i + 1];
      if ([args[i] isEqualToString:@"--seconds"]) gSeconds = args[i + 1].doubleValue;
    }

    NSError *error = nil;
    gData = [PTKTrackData dataWithContentsOfFile:geoPath error:&error];
    if (!gData) {
      fprintf(stderr, "读取几何失败: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }
    gPath = [[PTKTrackPath alloc] initWithTrackData:gData];
    buildScene(gData);
    printf("几何就绪: %lu mesh / %lu 三角形 / %lu 道具箱\n", (unsigned long)gData.nodes.count,
           (unsigned long)gData.triangleCount, (unsigned long)gData.boxes.count);

    gReplay = [PTKReplay new];
    gReplay.host = host;
    NSString *url = [NSString stringWithFormat:@"ws://%@/lan", host];
    gSocketA = [[PTKWebSocket alloc] initWithURL:[NSURL URLWithString:url] delegate:gReplay];
    [gSocketA open];
    gStartTime = now();

    // 10Hz 推油门 + 轻微转向（服务器 500ms 无输入会清空控制）；1.5s 存一帧
    NSTimer *tick = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
      double elapsed = now() - gStartTime;
      gTime += 0.1;
      if (elapsed > gSeconds) {
        [timer invalidate];
        if (gKarts.count) {
          stepVisuals(0.1);
          renderFrame([gOutPrefix stringByAppendingString:@"-final.png"], gTime);
          gReplay.frames++;
        }
        printf("\n=== 汇总 ===\nsnapshot 收到 %ld 帧, 渲染 %ld 张\n", (long)gReplay.snapshots, (long)gReplay.frames);
        for (PTKTestKart *kart in gKarts) {
          printf("  %s: 位置 (%.1f, %.1f, %.1f) yaw %.2f 速度 %.1f m/s 圈 %ld 名次 %ld%s\n",
                 kart.name.UTF8String, kart.position.x, kart.position.y, kart.position.z, kart.yaw,
                 kart.speed, (long)kart.lap, (long)kart.rank, kart.finished ? " [完赛]" : "");
        }
        [gSocketA close];
        [gSocketB close];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          exit(gReplay.snapshots > 10 ? 0 : 1);
        });
        return;
      }
      if (gSocketA.isOpen && elapsed > 2.0 && gSeqA >= 0) {
        PTKControls *controls = [PTKControls new];
        controls.throttle = 1;
        controls.steer = sin(elapsed * 0.6) * 0.25;
        gSeqA++;
        [gSocketA sendText:PTKInputMessage(gSeqA, controls)];
      }
      if (gSocketB.isOpen && elapsed > 2.0 && gSeqB >= 0) {
        PTKControls *controls = [PTKControls new];
        controls.throttle = 1;
        controls.steer = sin(elapsed * 0.45 + 1.0) * 0.3;
        gSeqB++;
        [gSocketB sendText:PTKInputMessage(gSeqB, controls)];
      }
      stepVisuals(0.1);
      if (elapsed > 3.0 && gKarts.count && gReplay.frames < 3 && elapsed - gLastPose > 1.6) {
        gLastPose = elapsed;
        for (PTKItemBoxNode *box in gBoxes) [box updateTime:gTime];
        for (PTKObstacleNode *obstacle in gObstacles) [obstacle updateTime:gTime dt:0.1];
        renderFrame([NSString stringWithFormat:@"%@-%ld.png", gOutPrefix, (long)++gReplay.frames], gTime);
      }
    }];
    (void)tick;
    [[NSRunLoop mainRunLoop] run];
  }
  return 0;
}
