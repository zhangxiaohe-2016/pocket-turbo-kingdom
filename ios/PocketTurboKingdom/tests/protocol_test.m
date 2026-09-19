// protocol_test.m —— PTKProtocol 编解码测试（macOS，纯 Foundation）。
//
// 覆盖：
//   1. 真实 snapshot 样本（字段与 src/network/protocol.ts 的 Snapshot / server/Race.ts 的
//      snapshot() 一一对齐）逐字段解析
//   2. room 消息（含 player 列表 / host / mode / phase）
//   3. 上行 join / ready / input / ping 的 JSON 字段构造
//   4. slots 里的 null、boxes 数字数组
//   5. 脏数据（字段缺失 / 类型异常 / 数组里塞对象 / 空串 / NaN）不崩、不丢整帧
//
// 编译见 tests/run_tests.sh。失败时 main 返回非零。
#import <Foundation/Foundation.h>
#import "PTKProtocol.h"

static int gPass = 0, gFail = 0;

static void Check(BOOL ok, NSString *name) {
    if (ok) {
        gPass++;
        printf("  \033[32m✓\033[0m %s\n", name.UTF8String);
    } else {
        gFail++;
        printf("  \033[31m✗\033[0m %s\n", name.UTF8String);
    }
    fflush(stdout);
}

/// 造一个和 server/Race.ts snapshot() 完全同构的样本（16 个 checkpoint / 4 个道具槽 / 2 台车）。
static NSString *SampleSnapshotJSON(void) {
    return @"{\"type\":\"snapshot\",\"tick\":1234,\"elapsed\":18.75,\"countdown\":0,"
           @"\"goFlash\":0.4,\"phase\":\"racing\","
           @"\"karts\":["
           @"{\"id\":\"p-aaa\",\"score\":7,\"hitsTaken\":2,\"disconnected\":false,"
           @"\"position\":[12.5,-0.25,88.125],\"velocity\":[3.5,0.125,-1.75],"
           @"\"yaw\":0.785,\"speed\":21.5,\"steering\":-0.35,\"grounded\":true,\"drift\":true,"
           @"\"driftCharge\":1.75,\"driftLevel\":2,\"boost\":0.6,\"stun\":0,\"invulnerable\":0,"
           @"\"lap\":2,\"nextCheckpoint\":5,\"lastCheckpoint\":4,\"progress\":0.421,\"rank\":1,"
           @"\"finished\":false,\"finishTime\":0,\"lapTimes\":[9.5,9.25],"
           @"\"slots\":[\"battery\",null,\"peel\",null],\"rolling\":[0.1,0.2]},"
           @"{\"id\":\"p-bbb\",\"score\":0,\"hitsTaken\":0,\"disconnected\":true,"
           @"\"position\":[-4,-0.25,120],\"velocity\":[0,0,0],"
           @"\"yaw\":3.1,\"speed\":0,\"steering\":0,\"grounded\":false,\"drift\":false,"
           @"\"driftCharge\":0,\"driftLevel\":0,\"boost\":0,\"stun\":1.2,\"invulnerable\":2.5,"
           @"\"lap\":1,\"nextCheckpoint\":2,\"lastCheckpoint\":1,\"progress\":0.13,\"rank\":2,"
           @"\"finished\":true,\"finishTime\":42.5,\"lapTimes\":[42.5],"
           @"\"slots\":[null,null,null,null],\"rolling\":[0,0]}],"
           @"\"boxes\":[0,3.5,0,0,7.25],"
           @"\"items\":[{\"index\":2,\"kind\":\"gear\",\"position\":[5,0.4,-9]},"
           @"{\"index\":9,\"kind\":\"firefly\",\"position\":[1,2,3]}]}";
}

static void TestSnapshot(void) {
    printf("\n[A] snapshot 解析\n");
    PTKServerMessage *m = [PTKServerMessage messageFromJSON:SampleSnapshotJSON()];
    Check([m.type isEqualToString:@"snapshot"], @"type = snapshot");
    Check(m.snapshot != nil, @"snapshot 非空");
    PTKSnapshot *s = m.snapshot;
    Check(s.tick == 1234, @"tick = 1234");
    Check(fabs(s.elapsed - 18.75) < 1e-9, @"elapsed = 18.75");
    Check(s.countdown == 0.0, @"countdown = 0");
    Check(fabs(s.goFlash - 0.4) < 1e-6, @"goFlash = 0.4");
    Check([s.phase isEqualToString:@"racing"], @"phase = racing");
    Check(s.karts.count == 2, @"karts 2 台");
    Check(s.boxes.count == 5, @"boxes 5 个冷却值");
    Check(s.items.count == 2, @"items 2 个");

    // ---- 第一台车：每个字段都要对上
    PTKKartState *k = s.karts[0];
    Check([k.kartId isEqualToString:@"p-aaa"], @"kart[0].id = 服务器 player id");
    Check(k.px == 12.5f && k.py == -0.25f && k.pz == 88.125f, @"kart[0].position");
    Check(k.vx == 3.5f && k.vy == 0.125f && k.vz == -1.75f, @"kart[0].velocity");
    Check(fabsf(k.yaw - 0.785f) < 1e-6, @"kart[0].yaw");
    Check(k.speed == 21.5f && k.steering == -0.35f, @"kart[0].speed/steering");
    Check(k.grounded == YES && k.drift == YES, @"kart[0].grounded/drift");
    Check(k.disconnected == NO && k.finished == NO, @"kart[0].disconnected/finished");
    Check(k.driftCharge == 1.75f && k.driftLevel == 2, @"kart[0].driftCharge/driftLevel");
    Check(k.boost == 0.6f && k.stun == 0.0f && k.invulnerable == 0.0f, @"kart[0].boost/stun/invuln");
    Check(k.lap == 2 && k.rank == 1, @"kart[0].lap/rank");
    Check(k.nextCheckpoint == 5 && k.lastCheckpoint == 4, @"kart[0].next/lastCheckpoint");
    Check(k.score == 7 && k.hitsTaken == 2, @"kart[0].score/hitsTaken");
    Check(fabsf(k.progress - 0.421f) < 1e-6 && k.finishTime == 0.0f, @"kart[0].progress/finishTime");
    Check(k.slots.count == 4, @"kart[0].slots 补齐到 4 个");
    Check([k.slots[0] isEqualToString:@"battery"], @"kart[0].slots[0] = battery");
    Check(k.slots[1] == [NSNull null], @"kart[0].slots[1] = null（NSNull）");
    Check([k.slots[2] isEqualToString:@"peel"] && k.slots[3] == [NSNull null],
          @"kart[0].slots[2..3] 正确");

    // ---- 第二台车：finished / disconnected / 全空 slots
    PTKKartState *k2 = s.karts[1];
    Check(k2.disconnected == YES && k2.finished == YES, @"kart[1].disconnected/finished");
    Check(k2.finishTime == 42.5f, @"kart[1].finishTime");
    Check(k2.slots.count == 4 && k2.slots[0] == [NSNull null], @"kart[1].slots 全 null");
    Check(k2.stun == 1.2f && k2.invulnerable == 2.5f, @"kart[1].stun/invulnerable");

    // ---- boxes / items
    Check([s.boxes[1] doubleValue] == 3.5 && [s.boxes[4] doubleValue] == 7.25, @"boxes 数值正确");
    PTKItemState *it = s.items[1];
    Check(it.index == 9 && [it.kind isEqualToString:@"firefly"], @"items[1].index/kind");
    Check(it.px == 1.0f && it.py == 2.0f && it.pz == 3.0f, @"items[1].position");
}

static void TestRoom(void) {
    printf("\n[B] room / pong / error 解析\n");
    NSString *json = @"{\"type\":\"room\",\"room\":{\"code\":\"AB12CD\",\"host\":\"p-1\","
                     @"\"mode\":\"arena\",\"phase\":\"lobby\",\"players\":["
                     @"{\"id\":\"p-1\",\"name\":\"主机车手\",\"kart\":0,\"ready\":true,\"connected\":true},"
                     @"{\"id\":\"p-2\",\"name\":\"<朋友>\",\"kart\":3,\"ready\":false,\"connected\":false}]},"
                     @"\"you\":\"p-2\","
                     @"\"urls\":[\"http://192.168.1.5:5173\",\"http://10.0.0.7:5173\"]}";
    PTKServerMessage *m = [PTKServerMessage messageFromJSON:json];
    Check([m.type isEqualToString:@"room"], @"type = room");
    Check([m.room.code isEqualToString:@"AB12CD"], @"room.code");
    Check([m.room.host isEqualToString:@"p-1"], @"room.host");
    Check([m.room.mode isEqualToString:@"arena"], @"room.mode");
    Check([m.room.phase isEqualToString:@"lobby"], @"room.phase");
    Check([m.you isEqualToString:@"p-2"], @"you = 自己的 id");
    Check(m.urls.count == 2 && [m.urls[0] hasPrefix:@"http://192.168.1.5"], @"urls 数组");
    Check(m.room.players.count == 2, @"players 2 人");
    PTKPlayer *p0 = m.room.players[0];
    Check([p0.playerId isEqualToString:@"p-1"] && [p0.name isEqualToString:@"主机车手"], @"p0 id/name");
    Check(p0.kart == 0 && p0.ready == YES && p0.connected == YES, @"p0 kart/ready/connected");
    PTKPlayer *p1 = m.room.players[1];
    Check(p1.kart == 3 && p1.ready == NO && p1.connected == NO, @"p1 kart/ready/connected");

    PTKServerMessage *pong = [PTKServerMessage messageFromJSON:@"{\"type\":\"pong\",\"time\":123.456}"];
    Check([pong.type isEqualToString:@"pong"] && fabs(pong.pongTime - 123.456) < 1e-9, @"pong.time");

    PTKServerMessage *err = [PTKServerMessage messageFromJSON:
        @"{\"type\":\"error\",\"message\":\"房间不存在，请检查房间码\"}"];
    Check([err.type isEqualToString:@"error"] && [err.errorMessage containsString:@"房间不存在"],
          @"error.message（中文）");
}

static void TestDirtyData(void) {
    printf("\n[C] 脏数据健壮性（不能崩、不能丢整帧）\n");
    // 1) karts 元素类型不对 / position 不是数组 / slots 太短 / boxes 混入字符串
    NSString *dirty = @"{\"type\":\"snapshot\",\"tick\":\"not-a-number\",\"elapsed\":null,"
                      @"\"phase\":12345,\"karts\":[\"oops\",{},"
                      @"{\"id\":9,\"position\":\"nope\",\"velocity\":[1],\"slots\":[\"gear\"],"
                      @"\"lap\":\"3\",\"rank\":1e30}],"
                      @"\"boxes\":[1,\"x\",null],\"items\":[7,{\"kind\":\"peel\"}]}";
    PTKServerMessage *m = [PTKServerMessage messageFromJSON:dirty];
    Check([m.type isEqualToString:@"snapshot"], @"脏 snapshot 仍识别为 snapshot");
    Check(m.snapshot.tick == 0, @"tick 非数字 -> 0");
    Check(m.snapshot.elapsed == 0.0, @"elapsed = null -> 0");
    Check([m.snapshot.phase isEqualToString:@"lobby"], @"phase 非字符串 -> 默认 lobby");
    Check(m.snapshot.karts.count == 2, @"karts 里非字典元素被跳过，剩 2 个");
    PTKKartState *k = m.snapshot.karts[1];
    Check([k.kartId isEqualToString:@"9"], @"id 是数字 -> 宽容地取 \"9\"（不崩）");
    Check(k.px == 0 && k.py == 0 && k.pz == 0, @"position 不是数组 -> 全 0");
    Check(k.vx == 0.0f && k.vy == 0 && k.vz == 0, @"velocity 只有 1 个元素（非合法三元组）-> 全 0 而不是 NaN");
    Check(k.slots.count == 4, @"slots 只有 1 个元素 -> 补齐 4 个");
    Check([k.slots[0] isEqualToString:@"gear"] && k.slots[1] == [NSNull null], @"slots 补 null");
    Check(k.lap == 0, @"lap 是字符串 \"3\"（类型异常）-> 0 兜底，绝不因为一个字段丢整帧");
    Check(k.rank == 9000000000000000, @"rank = 1e30 -> 夹到 9e15 不溢出");
    Check(m.snapshot.boxes.count == 3, @"boxes 长度保持 3");
    Check([m.snapshot.boxes[0] doubleValue] == 1.0 && [m.snapshot.boxes[1] doubleValue] == 0.0,
          @"boxes 非数字 -> 0 兜底");
    Check(m.snapshot.items.count == 1 && [m.snapshot.items[0].kind isEqualToString:@"peel"],
          @"items 里非字典跳过，位置缺失 -> 0");

    // 2) 空对象 / 缺字段
    PTKServerMessage *empty = [PTKServerMessage messageFromJSON:
        @"{\"type\":\"snapshot\"}"];
    Check(empty.snapshot != nil && empty.snapshot.karts.count == 0 && empty.snapshot.items.count == 0,
          @"只有 type 的 snapshot -> 空模型不崩");

    // 3) 非法 / 非对象 / 空串 JSON
    Check([[PTKServerMessage messageFromJSON:@"not json at all"].type isEqualToString:@"unknown"],
          @"非法 JSON -> type=unknown");
    Check([[PTKServerMessage messageFromJSON:@"[1,2,3]"].type isEqualToString:@"unknown"],
          @"顶层是数组 -> type=unknown");
    Check([[PTKServerMessage messageFromJSON:@""].type isEqualToString:@"unknown"], @"空串 -> unknown");
    Check([[PTKServerMessage messageFromJSON:nil].type isEqualToString:@"unknown"], @"nil -> unknown");
    Check([PTKServerMessage messageFromJSON:@"{\"type\":\"pong\",\"time\":\"early\"}"].pongTime == 0.0,
          @"pong time 是字符串 -> 0");
    Check([[PTKServerMessage messageFromJSON:@"{\"type\":\"room\",\"room\":\"oops\",\"urls\":\"oops\"}"]
              .room.code isEqualToString:@""],
          @"room 字段类型不对 -> 空模型");
    Check([[PTKServerMessage messageFromJSON:@"{\"type\":\"wat\"}"].type isEqualToString:@"wat"],
          @"未知 type 原样保留（渲染层可忽略）");
}

static NSDictionary *AsDict(NSString *json) {
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
}

static void TestOutgoing(void) {
    printf("\n[D] 上行消息构造\n");
    NSDictionary *join = AsDict(PTKJoinMessage(@"", @"口袋车手", 2));
    Check([join[@"type"] isEqualToString:@"join"], @"join.type");
    Check([join[@"version"] integerValue] == 2, @"join.version = 2（与 PROTOCOL_VERSION 一致）");
    Check([join[@"code"] isEqualToString:@""], @"join.code 空 = 创建房间");
    Check([join[@"name"] isEqualToString:@"口袋车手"], @"join.name 中文");
    Check([join[@"kart"] integerValue] == 2, @"join.kart");
    NSDictionary *join2 = AsDict(PTKJoinMessage(@"AB12CD", @"B", 0));
    Check([join2[@"code"] isEqualToString:@"AB12CD"], @"join.code 非空 = 加入房间");

    NSDictionary *ready = AsDict(PTKReadyMessage(YES));
    Check([ready[@"type"] isEqualToString:@"ready"] && [ready[@"ready"] boolValue], @"ready=true");
    Check([((NSDictionary *)AsDict(PTKReadyMessage(NO)))[@"ready"] boolValue] == NO, @"ready=false");

    Check([((NSDictionary *)AsDict(PTKModeMessage(@"arena")))[@"mode"] isEqualToString:@"arena"], @"mode=arena");
    Check([((NSDictionary *)AsDict(PTKStartMessage()))[@"type"] isEqualToString:@"start"], @"start");
    Check([((NSDictionary *)AsDict(PTKRematchMessage()))[@"type"] isEqualToString:@"rematch"], @"rematch");

    // input：seq 递增 + controls 十个字段齐全且类型正确
    PTKControls *c = [PTKControls new];
    c.steer = -0.5;
    c.throttle = 1.0;
    c.brake = 0.25;
    c.drift = YES;
    c.backward = NO;
    c.jump = YES;
    c.item1 = NO;
    c.item2 = YES;
    c.reset = NO;
    c.discard = YES;
    NSDictionary *input = AsDict(PTKInputMessage(4096, c));
    Check([input[@"type"] isEqualToString:@"input"], @"input.type");
    Check([input[@"seq"] longLongValue] == 4096, @"input.seq");
    NSDictionary *ct = input[@"controls"];
    Check([ct[@"steer"] doubleValue] == -0.5 && [ct[@"throttle"] doubleValue] == 1.0 &&
              [ct[@"brake"] doubleValue] == 0.25,
          @"controls.steer/throttle/brake 数值");
    Check([ct[@"drift"] boolValue] && ![ct[@"backward"] boolValue] && [ct[@"jump"] boolValue],
          @"controls.drift/backward/jump");
    Check(![ct[@"item1"] boolValue] && [ct[@"item2"] boolValue] && ![ct[@"reset"] boolValue] &&
              [ct[@"discard"] boolValue],
          @"controls.item1/item2/reset/discard");
    Check(ct.count == 10, @"controls 恰好 10 个字段（服务器校验用的三项都在）");
    // 服务器侧校验：["steer","throttle","brake"].every(Number.isFinite)
    NSArray *need = @[ @"steer", @"throttle", @"brake" ];
    BOOL allNum = YES;
    for (NSString *key in need)
        allNum = allNum && [ct[key] isKindOfClass:[NSNumber class]];
    Check(allNum, @"steer/throttle/brake 都是 JSON number");

    NSDictionary *ping = AsDict(PTKPingMessage(99.5));
    Check([ping[@"type"] isEqualToString:@"ping"] && [ping[@"time"] doubleValue] == 99.5, @"ping.time");

    // 构造函数必须容忍 nil
    Check(AsDict(PTKJoinMessage(nil, nil, 0))[@"name"] != nil, @"join(nil,nil,0) 不崩");
    Check([AsDict(PTKInputMessage(1, nil))[@"type"] isEqualToString:@"input"], @"input(seq,nil) 不崩");
    Check([AsDict(PTKModeMessage(nil))[@"mode"] isEqualToString:@"quick"], @"mode(nil) 兜底 quick");
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("PTKProtocol 单元测试\n");
        TestSnapshot();
        TestRoom();
        TestDirtyData();
        TestOutgoing();
        printf("\n结果: %d 通过, %d 失败\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
