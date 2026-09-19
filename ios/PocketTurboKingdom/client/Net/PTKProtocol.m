// PTKProtocol.m —— NSJSONSerialization 编解码 + 结构化模型。
// 解析原则：宁可给默认值，也不能崩、不能整帧丢弃。
#import "PTKProtocol.h"

const NSInteger PTKProtocolVersion = 2;

#pragma mark - 取值工具（脏数据兜底）

static BOOL PTKIsNum(id v) { return [v isKindOfClass:[NSNumber class]]; }

static double PTKDouble(id v) {
    if (!PTKIsNum(v)) return 0.0;
    double d = [(NSNumber *)v doubleValue];
    return isfinite(d) ? d : 0.0;
}

static float PTKFloat(id v) { return (float)PTKDouble(v); }

static NSInteger PTKInt(id v) {
    if (!PTKIsNum(v)) return 0;
    double d = [(NSNumber *)v doubleValue];
    if (!isfinite(d)) return 0;
    if (d > 9.0e15) return (NSInteger)9.0e15;
    if (d < -9.0e15) return (NSInteger)-9.0e15;
    return (NSInteger)llround(d);
}

static BOOL PTKBool(id v) {
    if (!PTKIsNum(v)) return NO;
    return [(NSNumber *)v boolValue];
}

static NSString *PTKStr(id v) {
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue]; // 容错：数字当字符串
    return @"";
}

/// 从 [x,y,z] 取值；缺失或非数组 -> 全 0。
typedef struct { float x, y, z; } PTKVec;
static PTKVec PTKVec3(id v) {
    PTKVec out = {0, 0, 0};
    if ([v isKindOfClass:[NSArray class]] && [(NSArray *)v count] >= 3) {
        NSArray *arr = (NSArray *)v;
        out.x = PTKFloat(arr[0]);
        out.y = PTKFloat(arr[1]);
        out.z = PTKFloat(arr[2]);
    }
    return out;
}

static NSString *PTKJSON(NSDictionary *dict) {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:0 // 不排序：字段顺序按写入顺序，方便肉眼核对
                                                     error:&err];
    if (!data) return @"{}";
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s ?: @"{}";
}


#pragma mark - PTKControls

@implementation PTKControls

- (NSDictionary *)dictionary {
    return @{
        @"steer" : @(self.steer),
        @"throttle" : @(self.throttle),
        @"brake" : @(self.brake),
        @"drift" : @(self.drift),
        @"backward" : @(self.backward),
        @"jump" : @(self.jump),
        @"item1" : @(self.item1),
        @"item2" : @(self.item2),
        @"reset" : @(self.reset),
        @"discard" : @(self.discard),
    };
}
@end

#pragma mark - PTKKartState

/// slots 固定补到 4 个元素；null / 非法元素 -> NSNull。
static NSArray *PTKSlots(id v) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:4];
    NSArray *src = [v isKindOfClass:[NSArray class]] ? (NSArray *)v : @[];
    for (NSUInteger i = 0; i < 4; i++) {
        id e = i < src.count ? src[i] : [NSNull null];
        if ([e isKindOfClass:[NSString class]])
            [out addObject:e];
        else
            [out addObject:[NSNull null]];
    }
    return out;
}


@implementation PTKKartState

- (instancetype)init {
    if ((self = [super init])) {
        _kartId = @"";
        _slots = @[ [NSNull null], [NSNull null], [NSNull null], [NSNull null] ];
    }
    return self;
}

+ (instancetype)kartFromDictionary:(NSDictionary *)d {
    PTKKartState *k = [PTKKartState new];
    if (![d isKindOfClass:[NSDictionary class]]) return k;
    k.kartId = PTKStr(d[@"id"]);
    PTKVec p = PTKVec3(d[@"position"]);
    k.px = p.x; k.py = p.y; k.pz = p.z;
    PTKVec v = PTKVec3(d[@"velocity"]);
    k.vx = v.x; k.vy = v.y; k.vz = v.z;
    k.yaw = PTKFloat(d[@"yaw"]);
    k.speed = PTKFloat(d[@"speed"]);
    k.steering = PTKFloat(d[@"steering"]);
    k.grounded = PTKBool(d[@"grounded"]);
    k.drift = PTKBool(d[@"drift"]);
    k.disconnected = PTKBool(d[@"disconnected"]);
    k.finished = PTKBool(d[@"finished"]);
    k.driftCharge = PTKFloat(d[@"driftCharge"]);
    k.driftLevel = PTKInt(d[@"driftLevel"]);
    k.boost = PTKFloat(d[@"boost"]);
    k.stun = PTKFloat(d[@"stun"]);
    k.invulnerable = PTKFloat(d[@"invulnerable"]);
    k.lap = PTKInt(d[@"lap"]);
    k.rank = PTKInt(d[@"rank"]);
    k.nextCheckpoint = PTKInt(d[@"nextCheckpoint"]);
    k.lastCheckpoint = PTKInt(d[@"lastCheckpoint"]);
    k.score = PTKInt(d[@"score"]);
    k.hitsTaken = PTKInt(d[@"hitsTaken"]);
    k.progress = PTKFloat(d[@"progress"]);
    k.finishTime = PTKFloat(d[@"finishTime"]);
    k.slots = PTKSlots(d[@"slots"]);
    return k;
}
@end

#pragma mark - PTKItemState

@implementation PTKItemState
- (instancetype)init {
    if ((self = [super init])) _kind = @"";
    return self;
}
@end

#pragma mark - PTKSnapshot

@implementation PTKSnapshot
- (instancetype)init {
    if ((self = [super init])) {
        _phase = @"lobby";
        _karts = @[];
        _boxes = @[];
        _items = @[];
    }
    return self;
}

+ (instancetype)snapshotFromDictionary:(NSDictionary *)dict {
    PTKSnapshot *s = [PTKSnapshot new];
    if (![dict isKindOfClass:[NSDictionary class]]) return s;
    s.tick = PTKInt(dict[@"tick"]);
    s.elapsed = PTKDouble(dict[@"elapsed"]);
    s.countdown = PTKDouble(dict[@"countdown"]);
    s.goFlash = PTKDouble(dict[@"goFlash"]);
    if ([dict[@"phase"] isKindOfClass:[NSString class]]) s.phase = dict[@"phase"];

    id karts = dict[@"karts"];
    if ([karts isKindOfClass:[NSArray class]]) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[(NSArray *)karts count]];
        for (id k in (NSArray *)karts)
            if ([k isKindOfClass:[NSDictionary class]]) [arr addObject:[PTKKartState kartFromDictionary:k]];
        s.karts = arr;
    }

    id boxes = dict[@"boxes"];
    if ([boxes isKindOfClass:[NSArray class]]) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[(NSArray *)boxes count]];
        for (id b in (NSArray *)boxes) [arr addObject:@(PTKDouble(b))]; // 非数字兜底成 0
        s.boxes = arr;
    }

    id items = dict[@"items"];
    if ([items isKindOfClass:[NSArray class]]) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[(NSArray *)items count]];
        for (id it in (NSArray *)items) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *d = (NSDictionary *)it;
            PTKItemState *o = [PTKItemState new];
            o.index = PTKInt(d[@"index"]);
            o.kind = PTKStr(d[@"kind"]);
            PTKVec ip = PTKVec3(d[@"position"]);
            o.px = ip.x; o.py = ip.y; o.pz = ip.z;
            [arr addObject:o];
        }
        s.items = arr;
    }
    return s;
}
@end

#pragma mark - PTKPlayer / PTKRoom

@implementation PTKPlayer
- (instancetype)init {
    if ((self = [super init])) {
        _playerId = @"";
        _name = @"";
    }
    return self;
}
+ (instancetype)playerFromDictionary:(NSDictionary *)d {
    PTKPlayer *p = [PTKPlayer new];
    if (![d isKindOfClass:[NSDictionary class]]) return p;
    p.playerId = PTKStr(d[@"id"]);
    p.name = PTKStr(d[@"name"]);
    p.kart = PTKInt(d[@"kart"]);
    p.ready = PTKBool(d[@"ready"]);
    p.bot = PTKBool(d[@"bot"]);
    p.connected = PTKBool(d[@"connected"]);
    return p;
}
@end

@implementation PTKRoom
- (instancetype)init {
    if ((self = [super init])) {
        _code = @"";
        _host = @"";
        _mode = @"quick";
        _phase = @"lobby";
        _players = @[];
    }
    return self;
}

+ (instancetype)roomFromDictionary:(NSDictionary *)d {
    PTKRoom *r = [PTKRoom new];
    if (![d isKindOfClass:[NSDictionary class]]) return r;
    r.code = PTKStr(d[@"code"]);
    r.host = PTKStr(d[@"host"]);
    if ([d[@"mode"] isKindOfClass:[NSString class]]) r.mode = d[@"mode"];
    if ([d[@"phase"] isKindOfClass:[NSString class]]) r.phase = d[@"phase"];
    id players = d[@"players"];
    if ([players isKindOfClass:[NSArray class]]) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[(NSArray *)players count]];
        for (id p in (NSArray *)players)
            if ([p isKindOfClass:[NSDictionary class]]) [arr addObject:[PTKPlayer playerFromDictionary:p]];
        r.players = arr;
    }
    return r;
}
@end

#pragma mark - PTKServerMessage

@implementation PTKServerMessage
- (instancetype)init {
    if ((self = [super init])) {
        _type = @"unknown";
        _you = @"";
        _urls = @[];
        _errorMessage = @"";
    }
    return self;
}

+ (instancetype)messageFromJSON:(NSString *)json {
    PTKServerMessage *m = [PTKServerMessage new];
    if (![json isKindOfClass:[NSString class]] || json.length == 0) return m;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return m;
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) return m; // 非法 JSON / 顶层不是对象
    NSDictionary *d = (NSDictionary *)obj;
    m.type = [d[@"type"] isKindOfClass:[NSString class]] ? d[@"type"] : @"unknown";

    if ([m.type isEqualToString:@"room"]) {
        m.room = [PTKRoom roomFromDictionary:d[@"room"]];
        m.you = PTKStr(d[@"you"]);
        id urls = d[@"urls"];
        if ([urls isKindOfClass:[NSArray class]]) {
            NSMutableArray *arr = [NSMutableArray array];
            for (id u in (NSArray *)urls)
                if ([u isKindOfClass:[NSString class]]) [arr addObject:u];
            m.urls = arr;
        }
    } else if ([m.type isEqualToString:@"snapshot"]) {
        m.snapshot = [PTKSnapshot snapshotFromDictionary:d];
    } else if ([m.type isEqualToString:@"error"]) {
        m.errorMessage = PTKStr(d[@"message"]);
    } else if ([m.type isEqualToString:@"pong"]) {
        m.pongTime = PTKDouble(d[@"time"]);
    }
    return m;
}
@end

#pragma mark - 上行消息

NSString *PTKJoinMessage(NSString *code, NSString *name, NSInteger kart) {
    return PTKJSON(@{
        @"type" : @"join",
        @"version" : @(PTKProtocolVersion),
        @"code" : code ?: @"",
        @"name" : name ?: @"",
        @"kart" : @(kart),
    });
}

NSString *PTKReadyMessage(BOOL ready) {
    return PTKJSON(@{@"type" : @"ready", @"ready" : @(ready)});
}

NSString *PTKModeMessage(NSString *mode) {
    return PTKJSON(@{@"type" : @"mode", @"mode" : mode ?: @"quick"});
}

NSString *PTKStartMessage(void) { return PTKJSON(@{@"type" : @"start"}); }

NSString *PTKRematchMessage(void) { return PTKJSON(@{@"type" : @"rematch"}); }

NSString *PTKInputMessage(long long seq, PTKControls *controls) {
    return PTKJSON(@{
        @"type" : @"input",
        @"seq" : @(seq),
        @"controls" : [(controls ?: [PTKControls new]) dictionary],
    });
}

NSString *PTKPingMessage(double time) {
    return PTKJSON(@{@"type" : @"ping", @"time" : @(time)});
}
