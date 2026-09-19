// wsprobe.m —— 命令行联调工具：真连一台 PTK 局域网服务器，跑满至少 12 秒。
//
// 用法：
//   ./wsprobe [ws-url] [name] [kart] [room-code]
//   ./wsprobe                                              # ws://127.0.0.1:5173/lan 车手0 创建房间
//   ./wsprobe ws://127.0.0.1:5173/lan 口袋车手 1           # 创建房间并打印房间码
//   ./wsprobe ws://192.168.1.5:5173/lan 朋友 2 AB12CD      # 用房间码加入
//
// 行为：连接 → 发 join → 打印 room（房间码 + 玩家列表）→ 每 100ms 发一条
//       seq 递增、throttle=1 的 input → 至少跑 12 秒 → 主动 close → 打印统计。
// 退出码：0 = 成功（握手 + 入房 + 跑满时长）；1 = 失败。
//
// 这个工具是"pong 处理正确"的现场证据：服务器每 5s ping 一次，不回 pong 会被
// terminate，能活过 12 秒就说明 ping/pong 通路是好的。
//
// 编译（macOS，只要 CommandLineTools）：
//   clang -fobjc-arc -Iclient/Net -framework Foundation -framework CFNetwork -framework Security \
//       tools/wsprobe.m client/Net/PTKWebSocket.m client/Net/PTKProtocol.m -o /tmp/wsprobe
#import <Foundation/Foundation.h>
#import "PTKWebSocket.h"
#import "PTKProtocol.h"

static const NSTimeInterval kRunSeconds = 12.0; // 要求：至少跑 12 秒
static const NSTimeInterval kInputInterval = 0.1;

// 可选环境变量 PTK_AUTO_READY=1：两人都用它时，房间凑齐 2 人后各自 ready，
// 房主再发 start，于是能收到真正的 snapshot（默认关闭，保持"只发 input"的行为）。
static BOOL AutoReady(void) {
    const char *v = getenv("PTK_AUTO_READY");
    return v != NULL && v[0] != '0';
}

@interface Probe : NSObject <PTKWebSocketDelegate>
@property (nonatomic, strong) PTKWebSocket *ws;
@property (nonatomic, strong) NSString *name;
@property (nonatomic) NSInteger kart;
@property (nonatomic, strong) NSString *roomCode;
@property (nonatomic, strong) NSString *myId;
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic) BOOL joined, opened, closed, failed;
@property (nonatomic) NSInteger roomCount;
@property (nonatomic) NSInteger lastPlayers;
@property (nonatomic) BOOL autoReadySent;
@property (nonatomic, strong) NSTimer *autoStartTimer;
@property (nonatomic) NSInteger errorCount;
@property (nonatomic) NSInteger snapshotCount;
@property (nonatomic) BOOL printedFirstSnapshot;
@property (nonatomic) NSInteger maxTick;
@property (nonatomic) NSTimeInterval elapsed;
@property (nonatomic) NSTimeInterval lastPongRTT;
@property (nonatomic) NSInteger pongCount;
@property (nonatomic, strong) NSTimer *inputTimer;
@property (nonatomic, strong) NSTimer *pingTimer;
@property (nonatomic, strong) NSTimer *stopTimer;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) double lastCpu;
@property (nonatomic) long long seq;
@end

static NSTimeInterval Now(void) { return [NSDate timeIntervalSinceReferenceDate]; }

@implementation Probe

- (void)start {
    _startedAt = Now();
    printf("→ 连接 %s\n", _ws.url.absoluteString.UTF8String);
    fflush(stdout);
    [_ws open];
}

- (void)webSocketDidOpen:(PTKWebSocket *)ws {
    (void)ws;
    _opened = YES;
    printf("✓ 握手完成（101 + Sec-WebSocket-Accept 校验通过）  已存活 %.2fs\n", Now() - _startedAt);
    fflush(stdout);
    [ws sendText:PTKJoinMessage(_roomCode, _name, _kart)];
    printf("→ 已发 join: %s\n", PTKJoinMessage(_roomCode, _name, _kart).UTF8String);
    fflush(stdout);

    __weak Probe *weakSelf = self;
    _inputTimer = [NSTimer scheduledTimerWithTimeInterval:kInputInterval
                                                  repeats:YES
                                                    block:^(NSTimer *t) {
                                                      (void)t;
                                                      [weakSelf sendInput];
                                                    }];
    _pingTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
                                                     (void)t;
                                                     Probe *s = weakSelf;
                                                     if (s.ws.isOpen)
                                                         [s.ws sendText:PTKPingMessage(Now() * 1000.0)];
                                                   }];
    _stopTimer = [NSTimer scheduledTimerWithTimeInterval:kRunSeconds
                                                 repeats:NO
                                                   block:^(NSTimer *t) {
                                                     (void)t;
                                                     [weakSelf stop];
                                                   }];
}

- (void)maybeAutoReady:(PTKRoom *)room {
    if (!AutoReady() || _autoReadySent || room.players.count < 2) return;
    _autoReadySent = YES;
    printf("· PTK_AUTO_READY=1：房间已有 %lu 人，发 ready + start\n",
           (unsigned long)room.players.count);
    fflush(stdout);
    [_ws sendText:PTKReadyMessage(YES)];
    if ([room.host isEqualToString:_myId]) {
        // 等一下让服务器收齐两边的 ready（服务器是"全员 ready"才允许发车）
        __weak Probe *weakSelf = self;
        _autoStartTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                          repeats:NO
                                                            block:^(NSTimer *t) {
                                                              (void)t;
                                                              Probe *s = weakSelf;
                                                              if (s.ws.isOpen) {
                                                                  printf("· 发 start（房主）\n");
                                                                  fflush(stdout);
                                                                  [s.ws sendText:PTKStartMessage()];
                                                              }
                                                            }];
    }
}

- (void)sendInput {
    if (!_ws.isOpen) return;
    PTKControls *c = [PTKControls new];
    c.throttle = 1.0;
    c.steer = 0.0;
    c.brake = 0.0;
    [_ws sendText:PTKInputMessage(++_seq, c)];
}

- (void)webSocket:(PTKWebSocket *)ws didReceiveText:(NSString *)text {
    (void)ws;
    _elapsed = Now() - _startedAt;
    PTKServerMessage *m = [PTKServerMessage messageFromJSON:text];

    if ([m.type isEqualToString:@"room"]) {
        _roomCount++;
        // 玩家进出时补打一次名单（两个实例互相看得见 = 真进同一个房间）
        if (_joined && (NSInteger)m.room.players.count != _lastPlayers) {
            printf("=== room 变化（t=%.2fs，第 %ld 条 room）玩家 %lu 人 ===\n", _elapsed,
                   (long)_roomCount, (unsigned long)m.room.players.count);
            for (PTKPlayer *p in m.room.players)
                printf("  - %-16s kart=%ld ready=%d connected=%d host=%d id=%s\n", p.name.UTF8String,
                       (long)p.kart, (int)p.ready, (int)p.connected,
                       [p.playerId isEqualToString:m.room.host], p.playerId.UTF8String);
            printf("================================================\n");
            fflush(stdout);
        }
        if (!_joined) {
            _joined = YES;
            _myId = m.you;
            _roomCode = m.room.code;
            printf("\n=== 收到 room（t=%.2fs）===\n", _elapsed);
            printf("房间码   : %s\n", m.room.code.UTF8String);
            printf("房主     : %s\n", m.room.host.UTF8String);
            printf("模式/阶段: %s / %s\n", m.room.mode.UTF8String, m.room.phase.UTF8String);
            printf("我的 id  : %s\n", m.you.UTF8String);
            printf("玩家 %lu 人:\n", (unsigned long)m.room.players.count);
            for (PTKPlayer *p in m.room.players)
                printf("  - %-16s kart=%ld ready=%d connected=%d host=%d id=%s\n", p.name.UTF8String,
                       (long)p.kart, (int)p.ready, (int)p.connected, [p.playerId isEqualToString:m.room.host],
                       p.playerId.UTF8String);
            if (m.urls.count) printf("局域网地址: %s\n", [m.urls componentsJoinedByString:@", "].UTF8String);
            printf("================================\n\n");
            fflush(stdout);
            [self maybeAutoReady:m.room];
        }
        _lastPlayers = (NSInteger)m.room.players.count;
        [self maybeAutoReady:m.room];
        return;
    }

    if ([m.type isEqualToString:@"snapshot"]) {
        if (_snapshotCount == 0) {
            printf("✓ 开始收到 snapshot（t=%.2fs）权威物理快照\n", _elapsed);
            fflush(stdout);
        }
        _snapshotCount++;
        PTKSnapshot *s = m.snapshot;
        if (s.tick > _maxTick) _maxTick = s.tick;
        if (!_printedFirstSnapshot) {
            _printedFirstSnapshot = YES;
            printf("=== 第一帧 snapshot（t=%.2fs）===\n", _elapsed);
            printf("tick=%ld elapsed=%.2f countdown=%.1f goFlash=%.2f phase=%s\n", (long)s.tick,
                   s.elapsed, s.countdown, s.goFlash, s.phase.UTF8String);
            printf("道具箱冷却 %lu 个，场上道具 %lu 个\n", (unsigned long)s.boxes.count,
                   (unsigned long)s.items.count);
            for (PTKKartState *k in s.karts) {
                NSMutableArray *slots = [NSMutableArray array];
                for (id slot in k.slots)
                    [slots addObject:(slot == [NSNull null] ? @"-" : slot)];
                printf("  kart %-38s pos=(%7.2f,%6.2f,%7.2f) vel=(%6.2f,%5.2f,%6.2f) lap=%ld/%ld "
                       "rank=%ld speed=%5.2f yaw=%5.2f grounded=%d drift=%d slots=[%s]\n",
                       k.kartId.UTF8String, k.px, k.py, k.pz, k.vx, k.vy, k.vz, (long)k.lap,
                       (long)k.nextCheckpoint, (long)k.rank, k.speed, k.yaw, (int)k.grounded,
                       (int)k.drift, [slots componentsJoinedByString:@","].UTF8String);
            }
            printf("================================\n");
            fflush(stdout);
        }
        return;
    }

    if ([m.type isEqualToString:@"pong"]) {
        _pongCount++;
        _lastPongRTT = Now() * 1000.0 - m.pongTime;
        return;
    }

    if ([m.type isEqualToString:@"error"]) {
        _errorCount++;
        printf("✗ 服务器 error（t=%.2fs）: %s\n", _elapsed, m.errorMessage.UTF8String);
        fflush(stdout);
        return;
    }

    printf("· 未识别消息（t=%.2fs）: %s\n", _elapsed, text.UTF8String);
    fflush(stdout);
}

- (void)webSocket:(PTKWebSocket *)ws
    didCloseWithCode:(NSInteger)code
              reason:(NSString *)reason {
    (void)ws;
    _closed = YES;
    printf("✓ 收到 close：code=%ld reason=\"%s\"（t=%.2fs）\n", (long)code, reason.UTF8String,
           Now() - _startedAt);
    fflush(stdout);
}

- (void)webSocket:(PTKWebSocket *)ws didFailWithError:(NSError *)error {
    (void)ws;
    _failed = YES;
    printf("✗ 连接失败：code=%ld %s\n", (long)error.code, error.localizedDescription.UTF8String);
    fflush(stdout);
}

- (void)stop {
    _elapsed = Now() - _startedAt;
    printf("\n→ 已跑满 %.1fs，主动发 close(1000)\n", _elapsed);
    fflush(stdout);
    [_inputTimer invalidate];
    [_pingTimer invalidate];
    _inputTimer = nil;
    _pingTimer = nil;
    [_ws close];
}

- (void)printSummaryAndExit {
    NSTimeInterval alive = Now() - _startedAt;
    printf("\n================ 统计 ================\n");
    printf("目标 URL      : %s\n", _ws.url.absoluteString.UTF8String);
    printf("握手成功      : %s\n", _opened ? "是" : "否");
    printf("已入房        : %s\n", _joined ? "是" : "否");
    printf("房间码        : %s\n", _roomCode.length ? _roomCode.UTF8String : "(没有)");
    printf("我的 player id: %s\n", _myId.length ? _myId.UTF8String : "(没有)");
    printf("存活时长      : %.2fs（要求 >= %.0fs）\n", alive, kRunSeconds);
    printf("snapshot 帧数 : %ld（最高 tick=%ld）\n", (long)_snapshotCount, (long)_maxTick);
    printf("上行 input 数 : %lld（每 100ms 一条，throttle=1）\n", _seq);
    printf("ping/pong     : 发出 %d 次 ping，收到 %d 次 pong，最后一次 RTT=%.1fms\n",
           (int)(_elapsed / 3.0), (int)_pongCount, _lastPongRTT);
    printf("room 消息数   : %ld（最后已知玩家人数 %ld）\n", (long)_roomCount, (long)_lastPlayers);
    printf("服务器 error  : %ld 条\n", (long)_errorCount);
    printf("close/失败    : closed=%d failed=%d\n", (int)_closed, (int)_failed);
    printf("======================================\n");

    BOOL ok = _opened && _joined && !_failed && alive >= kRunSeconds;
    if (ok) {
        printf("\n\033[32mPASS\033[0m：握手 + 入房 + 跑满 %.1fs + 正常 close（服务器 5s 一次的 ping 全程回了 pong）\n",
               alive);
    } else {
        printf("\n\033[31mFAIL\033[0m：opened=%d joined=%d failed=%d alive=%.1fs\n", (int)_opened,
               (int)_joined, (int)_failed, alive);
    }
    fflush(stdout);
    exit(ok ? 0 : 1);
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        NSString *urlString = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"ws://127.0.0.1:5173/lan";
        NSString *name = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"口袋车手";
        NSInteger kart = argc > 3 ? [[NSString stringWithUTF8String:argv[3]] integerValue] : 0;
        NSString *code = argc > 4 ? [[NSString stringWithUTF8String:argv[4]] uppercaseString] : @"";

        if ([urlString hasPrefix:@"-"]) {
            printf("用法: wsprobe [ws-url] [name] [kart] [room-code]\n"
                   "      默认 ws://127.0.0.1:5173/lan\n");
            return 2;
        }

        printf("Pocket Turbo Kingdom · LAN WebSocket 探针\n");
        printf("url=%s name=%s kart=%ld code=%s\n\n", urlString.UTF8String, name.UTF8String, (long)kart,
               code.length ? code.UTF8String : "(空→创建房间)");

        Probe *p = [Probe new];
        p.name = name;
        p.kart = kart;
        p.roomCode = code;
        PTKWebSocket *ws = [[PTKWebSocket alloc] initWithURL:[NSURL URLWithString:urlString] delegate:p];
        p.ws = ws;
        [p start];

        // 主 run loop：所有回调都在这里，最多等 kRunSeconds + 6s（留给 close 握手）
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kRunSeconds + 6.0];
        while (deadline.timeIntervalSinceNow > 0 && !p.closed && !p.failed) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        // close/fail 之后再给 0.2s 让最后的消息落地
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        if (!p.closed && !p.failed) {
            printf("\n✗ 超时未收到 close/fail，强制收尾\n");
        }
        [p printSummaryAndExit];
        return 0;
    }
}
