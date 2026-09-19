// ws_frame_test.m —— PTKWebSocket 帧编解码 + 真 socket 联调测试（macOS，纯 Foundation/CFNetwork）。
//
// 两层：
//   A. 纯函数层：PTKFrameEncode / PTKFrameParse / PTKFrameAssembler —— 7/16/64 位长度、
//      掩码、半帧缓冲、分片拼接、ping/pong/close。
//   B. 真 socket 层：本地起一个手写 RFC6455 服务器（后台 pthread），让 PTKWebSocket
//      真的走完 握手 -> 收分片文本 -> 回 pong -> 收到服务器 close 并回 close -> 回调。
//      这一层专门覆盖"不回 pong 就被 terminate"这个最容易翻车的点。
//
// 编译见 tests/run_tests.sh。失败时 main 返回非零。
#import <Foundation/Foundation.h>
#import "PTKWebSocket.h"
#import "PTKWebSocketPrivate.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <pthread.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

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

static NSString *Hex(NSData *d) {
    const uint8_t *p = d.bytes;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}

#pragma mark - A. 纯函数层

static void TestFrameCodec(void) {
    printf("\n[A] 帧编解码\n");

    // 1) 7 位长度 + 客户端掩码
    {
        NSData *payload = [@"hi" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *f = PTKFrameEncode(PTKOpcodeText, YES, payload, YES);
        const uint8_t *b = f.bytes;
        Check(f.length == 2 + 4 + 2, @"7 位长度帧总长 = 8 字节");
        Check(b[0] == 0x81, @"FIN=1 + opcode=text(0x1)");
        Check(b[1] == (0x80 | 2), @"MASK=1 + 长度 2（客户端必须掩码）");
        // 解回来验证掩码正确性
        NSMutableData *buf = [f mutableCopy];
        PTKOpcode op = PTKOpcodeClose;
        BOOL fin = NO;
        NSData *out = nil;
        NSError *err = nil;
        Check(PTKFrameParse(buf, &op, &fin, &out, &err), @"掩码帧可解析");
        Check(op == PTKOpcodeText && fin, @"opcode/fin 还原正确");
        Check([out isEqualToData:payload], @"掩码异或正确还原 payload");
        Check(buf.length == 0, @"解析后 buffer 被完整消费");
    }

    // 2) 16 位长度（126 分支）
    {
        NSMutableData *payload = [NSMutableData data];
        for (int i = 0; i < 300; i++) [payload appendBytes:&(uint8_t){0x41} length:1];
        NSData *f = PTKFrameEncode(PTKOpcodeBinary, YES, payload, NO);
        const uint8_t *b = f.bytes;
        Check(b[1] == 126, @"长度 300 走 126 分支");
        Check(((NSUInteger)b[2] << 8 | b[3]) == 300, @"16 位长度字段 = 300");
        Check(f.length == 4 + 300, @"16 位长度帧总长");
        NSMutableData *buf = [f mutableCopy];
        PTKOpcode op = PTKOpcodeClose;
        BOOL fin = NO;
        NSData *out = nil;
        NSError *err = nil;
        Check(PTKFrameParse(buf, &op, &fin, &out, &err) && [out isEqualToData:payload],
              @"服务器非掩码 16 位帧解析正确");
    }

    // 3) 64 位长度（127 分支）
    {
        NSUInteger n = 70000;
        NSMutableData *payload = [NSMutableData dataWithLength:n];
        memset(payload.mutableBytes, 0x5A, n);
        NSData *f = PTKFrameEncode(PTKOpcodeBinary, YES, payload, YES);
        const uint8_t *b = f.bytes;
        Check(b[1] == (0x80 | 127), @"长度 70000 走 127 分支且带掩码");
        uint64_t len64 = 0;
        for (int i = 0; i < 8; i++) len64 = (len64 << 8) | b[2 + i];
        Check(len64 == n, @"64 位长度字段 = 70000");
        Check(f.length == 10 + 4 + n, @"64 位长度帧总长");
        NSMutableData *buf = [f mutableCopy];
        PTKOpcode op = PTKOpcodeClose;
        BOOL fin = NO;
        NSData *out = nil;
        NSError *err = nil;
        Check(PTKFrameParse(buf, &op, &fin, &out, &err) && out.length == n, @"64 位长度帧解析正确");
        Check(out.length == n && memcmp(out.bytes, payload.bytes, n) == 0, @"64 位帧 payload 逐字节一致");
    }

    // 4) 跨 TCP 包的半帧缓冲：逐字节喂
    {
        NSData *payload = [@"分片之前的半帧" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *f = PTKFrameEncode(PTKOpcodeText, YES, payload, YES);
        NSMutableData *buf = [NSMutableData data];
        BOOL got = NO;
        for (NSUInteger i = 0; i < f.length; i++) {
            [buf appendBytes:(const uint8_t *)f.bytes + i length:1];
            PTKOpcode op = PTKOpcodeClose;
            BOOL fin = NO;
            NSData *out = nil;
            NSError *err = nil;
            if (PTKFrameParse(buf, &op, &fin, &out, &err)) {
                got = [out isEqualToData:payload] && got == NO;
            }
        }
        Check(got, @"逐字节喂入：半帧不误判，最后一字节才出帧");
        Check(buf.length == 0, @"逐字节喂入后 buffer 干净");
    }

    // 5) 分片消息拼接（text + 2 个 continuation）
    {
        PTKFrameAssembler *asm_ = [PTKFrameAssembler new];
        NSData *p1 = [@"{\"type\":" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *p2 = [@"\"snapshot\"," dataUsingEncoding:NSUTF8StringEncoding];
        NSData *p3 = [@"\"tick\":7}" dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        Check([asm_ acceptOpcode:PTKOpcodeText fin:NO payload:p1 error:&err] == nil, @"首片（fin=0）不回调");
        Check([asm_ acceptOpcode:PTKOpcodeContinuation fin:NO payload:p2 error:&err] == nil, @"中间片不回调");
        Check(asm_.hasPendingFragment, @"组装器记录未完成分片");
        NSData *done = [asm_ acceptOpcode:PTKOpcodeContinuation fin:YES payload:p3 error:&err];
        NSString *s = [[NSString alloc] initWithData:done encoding:NSUTF8StringEncoding];
        Check([s isEqualToString:@"{\"type\":\"snapshot\",\"tick\":7}"], @"三片拼成完整 JSON");
        Check(!asm_.hasPendingFragment, @"拼完后无残留分片");
        // 孤立 continuation 必须报错而不是崩溃
        NSError *e2 = nil;
        Check([asm_ acceptOpcode:PTKOpcodeContinuation fin:YES payload:p1 error:&e2] == nil && e2 != nil,
              @"孤立 continuation 报协议错误");
    }

    // 6) ping / pong / close（带 code + reason）
    {
        NSData *body = [@"ping-body" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *ping = PTKFrameEncode(PTKOpcodePing, YES, body, NO);
        Check((((const uint8_t *)ping.bytes)[0] & 0x0F) == 0x9, @"ping opcode = 0x9");
        NSMutableData *buf = [ping mutableCopy];
        PTKOpcode op = PTKOpcodeClose;
        BOOL fin = NO;
        NSData *out = nil;
        NSError *err = nil;
        Check(PTKFrameParse(buf, &op, &fin, &out, &err) && op == PTKOpcodePing && [out isEqualToData:body],
              @"ping 帧解析 + payload 保留（回 pong 要回显）");

        // close 帧：code + reason
        NSData *closePayload = PTKClosePayloadEncode(1001, @"going away");
        NSData *closeFrame = PTKFrameEncode(PTKOpcodeClose, YES, closePayload, YES);
        Check((((const uint8_t *)closeFrame.bytes)[0] & 0x0F) == 0x8, @"close opcode = 0x8");
        NSMutableData *cbuf = [closeFrame mutableCopy];
        NSData *cout = nil;
        Check(PTKFrameParse(cbuf, &op, &fin, &cout, &err) && op == PTKOpcodeClose, @"close 帧解析");
        NSInteger code = 0;
        NSString *reason = nil;
        PTKClosePayloadDecode(cout, &code, &reason);
        Check(code == 1001, @"close code = 1001");
        Check([reason isEqualToString:@"going away"], @"close reason = 'going away'");
        // 空 payload 的 close（服务器可能这么发）
        NSInteger c2 = 0;
        NSString *r2 = nil;
        PTKClosePayloadDecode([NSData data], &c2, &r2);
        Check(c2 == -1 && r2.length == 0, @"空 close payload -> code=-1 reason=''");
    }

    // 6b) binary 帧按 UTF-8 文本处理（协议里没有真正的二进制消息）
    {
        PTKFrameAssembler *asmB = [PTKFrameAssembler new];
        NSString *txt = @"{\"type\":\"snapshot\",\"tick\":9}";
        NSError *eB = nil;
        NSData *msg = [asmB acceptOpcode:PTKOpcodeBinary fin:YES
                                 payload:[txt dataUsingEncoding:NSUTF8StringEncoding]
                                   error:&eB];
        Check(msg != nil && eB == nil, @"binary 帧也能取到完整 payload");
        Check([[[NSString alloc] initWithData:msg encoding:NSUTF8StringEncoding] isEqualToString:txt],
              @"binary 帧按 UTF-8 还原成文本");
    }

    // 7) 脏帧：控制帧 fin=0 / RSV 非零 必须报错而非崩
    {
        uint8_t bad1[] = {0x09, 0x00}; // ping 但 fin=0
        NSMutableData *b1 = [NSMutableData dataWithBytes:bad1 length:2];
        PTKOpcode op;
        BOOL fin;
        NSData *out = nil;
        NSError *err = nil;
        Check(!PTKFrameParse(b1, &op, &fin, &out, &err) && err != nil, @"控制帧 fin=0 报协议错误");
        uint8_t bad2[] = {0xC1, 0x00}; // RSV1=1
        NSMutableData *b2 = [NSMutableData dataWithBytes:bad2 length:2];
        err = nil;
        Check(!PTKFrameParse(b2, &op, &fin, &out, &err) && err != nil, @"RSV 非零报协议错误");
    }

    // 8) SHA-1（RFC3174 标准向量 + 握手向量）
    {
        uint8_t d[20];
        const char *abc = "abc";
        PTKSHA1((const uint8_t *)abc, 3, d);
        Check([Hex([NSData dataWithBytes:d length:20])
                   isEqualToString:@"a9993e364706816aba3e25717850c26c9cd0d89d"],
              @"SHA1(\"abc\") = a9993e36...");
        const char *longer = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
        PTKSHA1((const uint8_t *)longer, strlen(longer), d);
        Check([Hex([NSData dataWithBytes:d length:20])
                   isEqualToString:@"84983e441c3bd26ebaae4aa1f95129e5e54670f1"],
              @"SHA1(两段 448bit 向量) = 84983e44...");
        // RFC6455 握手示例：key dGhlIHNhbXBsZSBub25jZQ== -> s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
        const char *key = "dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        PTKSHA1((const uint8_t *)key, strlen(key), d);
        NSData *digest = [NSData dataWithBytes:d length:20];
        Check([[digest base64EncodedStringWithOptions:0] isEqualToString:@"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="],
              @"RFC6455 握手 accept 向量正确");
    }
}

#pragma mark - B. 真 socket 层

// 本地手写 RFC6455 服务器：验证客户端握手头、掩码、pong 回显、分片接收、close 回帧。
static int gListenFd = -1;
static int gPort = 0;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL gSawMaskedText = NO;
static BOOL gSawPongEcho = NO;
static NSString *gFirstText = nil;
static BOOL gSawClientClose = NO;
static NSInteger gClientCloseCode = -1;
static BOOL gHandshakeHeadersOK = NO;
static BOOL gServerFinished = NO;

static BOOL ReadExact(int fd, void *dst, size_t n) {
    uint8_t *p = (uint8_t *)dst;
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, p + got, n - got, 0);
        if (r <= 0) return NO;
        got += (size_t)r;
    }
    return YES;
}

static BOOL WriteAll(int fd, const void *src, size_t n) {
    const uint8_t *p = (const uint8_t *)src;
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = send(fd, p + sent, n - sent, 0);
        if (w <= 0) return NO;
        sent += (size_t)w;
    }
    return YES;
}

/// 读一帧（服务器侧：期望客户端帧带掩码）。
static BOOL ReadFrame(int fd, PTKOpcode *outOp, NSData **outPayload) {
    uint8_t h[2];
    if (!ReadExact(fd, h, 2)) return NO;
    BOOL masked = (h[1] & 0x80) != 0;
    uint64_t len = h[1] & 0x7F;
    if (len == 126) {
        uint8_t e[2];
        if (!ReadExact(fd, e, 2)) return NO;
        len = ((uint64_t)e[0] << 8) | e[1];
    } else if (len == 127) {
        uint8_t e[8];
        if (!ReadExact(fd, e, 8)) return NO;
        len = 0;
        for (int i = 0; i < 8; i++) len = (len << 8) | e[i];
    }
    uint8_t key[4] = {0, 0, 0, 0};
    if (masked && !ReadExact(fd, key, 4)) return NO;
    NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)len];
    if (len && !ReadExact(fd, payload.mutableBytes, (size_t)len)) return NO;
    if (masked) {
        uint8_t *q = payload.mutableBytes;
        for (NSUInteger i = 0; i < (NSUInteger)len; i++) q[i] ^= key[i & 3];
    }
    if (outOp) *outOp = (PTKOpcode)(h[0] & 0x0F);
    if (outPayload) *outPayload = payload;
    return YES;
}

static void *ServerThread(void *arg) {
    (void)arg;
    int fd = accept(gListenFd, NULL, NULL);
    if (fd < 0) {
        pthread_mutex_lock(&gLock);
        gServerFinished = YES;
        pthread_mutex_unlock(&gLock);
        return NULL;
    }

    // ---- 读 HTTP 握手请求
    NSMutableData *req = [NSMutableData data];
    uint8_t tmp[512];
    NSRange sep = NSMakeRange(NSNotFound, 0);
    while (sep.location == NSNotFound && req.length < 8192) {
        ssize_t r = recv(fd, tmp, sizeof(tmp), 0);
        if (r <= 0) break;
        [req appendBytes:tmp length:(NSUInteger)r];
        sep = [req rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, req.length)];
    }
    NSString *head = [[NSString alloc] initWithData:req encoding:NSUTF8StringEncoding] ?: @"";
    NSString *key = nil;
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        if ([line.lowercaseString hasPrefix:@"sec-websocket-key:"])
            key = [line substringFromIndex:[line rangeOfString:@":"].location + 1];
    }
    key = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    BOOL headersOK =
        [head hasPrefix:@"GET /lan HTTP/1.1"] && [head containsString:@"Upgrade: websocket"] &&
        [head containsString:@"Connection: Upgrade"] && [head containsString:@"Sec-WebSocket-Version: 13"] &&
        ![head containsString:@"Sec-WebSocket-Extensions"] && key.length > 0;
    pthread_mutex_lock(&gLock);
    gHandshakeHeadersOK = headersOK;
    pthread_mutex_unlock(&gLock);

    // ---- 回 101
    NSString *concat = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    uint8_t digest[20];
    PTKSHA1((const uint8_t *)concat.UTF8String, strlen(concat.UTF8String), digest);
    NSString *accept = [[NSData dataWithBytes:digest length:20] base64EncodedStringWithOptions:0];
    NSString *resp = [NSString stringWithFormat:
                          @"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                          @"Connection: Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n",
                          accept];
    WriteAll(fd, resp.UTF8String, strlen(resp.UTF8String));

    // ---- 1) 先等客户端的 join 文本帧，确认客户端→服务器带掩码
    PTKOpcode op = PTKOpcodeClose;
    NSData *payload = nil;
    if (ReadFrame(fd, &op, &payload)) {
        NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
        pthread_mutex_lock(&gLock);
        gSawMaskedText = (op == PTKOpcodeText) && [text containsString:@"\"join\""];
        gFirstText = text ?: @"";
        pthread_mutex_unlock(&gLock);
    }

    // ---- 2) 服务器主动 ping（对应真实服务器 5s ping），客户端必须回 pong 且回显 payload
    NSData *pingBody = [@"ptk-ping-1" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *ping = PTKFrameEncode(PTKOpcodePing, YES, pingBody, NO);
    WriteAll(fd, ping.bytes, ping.length);
    BOOL pongOK = NO;
    for (int i = 0; i < 3 && !pongOK; i++) {
        NSData *pl = nil;
        if (!ReadFrame(fd, &op, &pl)) break;
        if (op == PTKOpcodePong) pongOK = [pl isEqualToData:pingBody];
        if (op == PTKOpcodeClose) break;
    }
    pthread_mutex_lock(&gLock);
    gSawPongEcho = pongOK;
    pthread_mutex_unlock(&gLock);

    // ---- 3) 服务器发分片文本（text + continuation），中间隔一点时间模拟半帧
    NSString *part1 = @"{\"type\":\"room\",\"room\":{\"code\":\"AB12CD\",";
    NSString *part2 = @"\"host\":\"p1\",\"players\":[";
    NSString *part3 = @"{},{}]},\"you\":\"p1\",\"urls\":[]}";
    NSData *f1 = PTKFrameEncode(PTKOpcodeText, NO, [part1 dataUsingEncoding:NSUTF8StringEncoding], NO);
    NSData *f2 = PTKFrameEncode(PTKOpcodeContinuation, NO, [part2 dataUsingEncoding:NSUTF8StringEncoding], NO);
    NSData *f3 = PTKFrameEncode(PTKOpcodeContinuation, YES, [part3 dataUsingEncoding:NSUTF8StringEncoding], NO);
    WriteAll(fd, f1.bytes, f1.length);
    WriteAll(fd, f2.bytes, f2.length);
    usleep(80 * 1000); // 故意断开，验证跨 TCP 包的缓冲
    WriteAll(fd, f3.bytes, f3.length);

    // ---- 4) 服务器发一个 16 位长度的大文本（>125 字节）
    NSMutableString *big = [NSMutableString string];
    for (int i = 0; i < 40; i++) [big appendFormat:@"snapshot-payload-%02d;", i];
    NSData *bigFrame = PTKFrameEncode(PTKOpcodeText, YES, [big dataUsingEncoding:NSUTF8StringEncoding], NO);
    WriteAll(fd, bigFrame.bytes, bigFrame.length);

    // ---- 5) 服务器发 close(1001,"bye")，期望客户端回 close 并回调 didCloseWithCode:1001
    NSData *closeFrame = PTKFrameEncode(PTKOpcodeClose, YES, PTKClosePayloadEncode(1001, @"bye"), NO);
    WriteAll(fd, closeFrame.bytes, closeFrame.length);
    for (int i = 0; i < 3; i++) {
        NSData *pl = nil;
        if (!ReadFrame(fd, &op, &pl)) break;
        if (op == PTKOpcodeClose) {
            NSInteger code = -1;
            NSString *reason = nil;
            PTKClosePayloadDecode(pl, &code, &reason);
            pthread_mutex_lock(&gLock);
            gSawClientClose = YES;
            gClientCloseCode = code;
            pthread_mutex_unlock(&gLock);
            break;
        }
    }
    usleep(100 * 1000);
    close(fd);
    pthread_mutex_lock(&gLock);
    gServerFinished = YES;
    pthread_mutex_unlock(&gLock);
    return NULL;
}

@interface ProbeDelegate : NSObject <PTKWebSocketDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *messages;
@property (nonatomic) NSInteger openCount, closeCount, failCount;
@property (nonatomic) NSInteger closeCode;
@property (nonatomic, copy) NSString *closeReason;
@property (nonatomic, strong) NSError *failError;
@property (nonatomic) BOOL done;
@end

@implementation ProbeDelegate
- (instancetype)init {
    if ((self = [super init])) _messages = [NSMutableArray array];
    return self;
}
- (void)webSocketDidOpen:(PTKWebSocket *)ws {
    (void)ws;
    self.openCount++;
}
- (void)webSocket:(PTKWebSocket *)ws didReceiveText:(NSString *)text {
    (void)ws;
    [self.messages addObject:text];
}
- (void)webSocket:(PTKWebSocket *)ws didCloseWithCode:(NSInteger)code reason:(NSString *)reason {
    (void)ws;
    self.closeCount++;
    self.closeCode = code;
    self.closeReason = reason;
    self.done = YES;
}
- (void)webSocket:(PTKWebSocket *)ws didFailWithError:(NSError *)error {
    (void)ws;
    self.failCount++;
    self.failError = error;
    self.done = YES;
}
@end

/// 一直跑当前 run loop 直到 predicate 成立或超时。
static BOOL Pump(ProbeDelegate *d, NSTimeInterval seconds, BOOL (^pred)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!pred() && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return pred();
}

static BOOL PumpUntil(ProbeDelegate *d, NSTimeInterval seconds) { return Pump(d, seconds, ^BOOL { return d.done; }); }

static void TestLiveSocket(void) {
    printf("\n[B] 真 socket 联调（本地手写 RFC6455 服务器）\n");

    gListenFd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(gListenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(gListenFd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(gListenFd, 1) != 0) {
        Check(NO, @"本地监听 socket 创建失败");
        return;
    }
    socklen_t alen = sizeof(addr);
    getsockname(gListenFd, (struct sockaddr *)&addr, &alen);
    gPort = ntohs(addr.sin_port);

    pthread_t th;
    pthread_create(&th, NULL, ServerThread, NULL);

    ProbeDelegate *d = [ProbeDelegate new];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%d/lan", gPort]];
    PTKWebSocket *ws = [[PTKWebSocket alloc] initWithURL:url delegate:d];
    [ws open];
    Check(Pump(d, 3.0, ^BOOL { return d.openCount > 0; }) && d.openCount == 1 && d.closeCount == 0 &&
              d.failCount == 0,
          @"握手完成并回调 webSocketDidOpen:（3s 内没被 close/fail）");
    Check(ws.isOpen, @"isOpen == YES");

    // 发一个 join（会打到服务器，验证客户端帧带掩码）
    [ws sendText:@"{\"type\":\"join\",\"version\":2,\"code\":\"\",\"name\":\"ws_frame_test\",\"kart\":0}"];

    Check(PumpUntil(d, 6.0), @"服务器发 close 后客户端收尾并回调（未卡死）");
    Check(ws.isOpen == NO, @"收尾后 isOpen == NO");

    pthread_mutex_lock(&gLock);
    BOOL headersOK = gHandshakeHeadersOK, masked = gSawMaskedText, pong = gSawPongEcho;
    BOOL clientClose = gSawClientClose;
    NSInteger clientCloseCode = gClientCloseCode;
    NSString *firstText = gFirstText;
    pthread_mutex_unlock(&gLock);

    Check(headersOK, @"握手请求头齐全（GET /lan、Upgrade、Version:13、无 Extensions）");
    Check(masked && [firstText containsString:@"\"join\""], @"客户端文本帧被服务器正确解掩码");
    Check(pong, @"收到服务器 ping 后回了 pong 且回显 payload（保命逻辑）");
    Check(d.messages.count == 2, @"收到 2 条完整文本消息（分片拼接 + 16 位长度）");
    if (d.messages.count >= 2) {
        Check([d.messages[0] isEqualToString:@"{\"type\":\"room\",\"room\":{\"code\":\"AB12CD\",\"host\":\"p1\","
                                       @"\"players\":[{},{}]},\"you\":\"p1\",\"urls\":[]}"],
              @"分片文本按顺序拼成完整 JSON 回调");
        Check([d.messages[1] hasPrefix:@"snapshot-payload-00;"] && d.messages[1].length > 125,
              @"16 位长度（>125 字节）消息完整收到");
    }
    Check(clientClose && clientCloseCode == 1001, @"收到 close 后回了 close 帧（code 1001）");
    printf("      └ closeCount=%ld code=%ld reason=[%s] failCount=%ld\n", (long)d.closeCount,
           (long)d.closeCode, d.closeReason.UTF8String, (long)d.failCount);
    Check(d.closeCount == 1 && d.closeCode == 1001 && [d.closeReason isEqualToString:@"bye"],
          @"didCloseWithCode:1001 reason:'bye' 回调正确");
    Check(d.failCount == 0, @"整个流程没有触发 didFailWithError:");

    // 服务端线程收尾
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while (deadline.timeIntervalSinceNow > 0) {
        pthread_mutex_lock(&gLock);
        BOOL fin = gServerFinished;
        pthread_mutex_unlock(&gLock);
        if (fin) break;
        usleep(20 * 1000);
    }
    pthread_join(th, NULL);
    close(gListenFd);
}

#pragma mark - 连接失败路径

typedef struct { int fd; const char *response; int holdMs; } BadServerArgs;

static void *BadServerThread(void *arg) {
    BadServerArgs *a = (BadServerArgs *)arg;
    int fd = accept(a->fd, NULL, NULL);
    if (fd < 0) return NULL;
    uint8_t tmp[1024];
    recv(fd, tmp, sizeof(tmp), 0); // 丢掉握手请求
    if (a->response) send(fd, a->response, strlen(a->response), 0); // NULL = 什么都不发
    usleep((useconds_t)(a->holdMs > 0 ? a->holdMs : 200) * 1000);
    close(fd);
    return NULL;
}

static void ProbeBadServer(NSString *name, const char *response, int holdMs,
                           PTKWebSocketError expected) {
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    bind(lfd, (struct sockaddr *)&a, sizeof(a));
    listen(lfd, 1);
    socklen_t al = sizeof(a);
    getsockname(lfd, (struct sockaddr *)&a, &al);
    BadServerArgs args = {lfd, response, holdMs};
    pthread_t th;
    pthread_create(&th, NULL, BadServerThread, &args);

    ProbeDelegate *d = [ProbeDelegate new];
    PTKWebSocket *ws = [[PTKWebSocket alloc] initWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%d/lan", ntohs(a.sin_port)]]
        delegate:d];
    [ws open];
    Check(Pump(d, 12.0, ^BOOL { return d.done; }) && d.failCount == 1 && d.closeCount == 0,
          name);
    Check(d.failError != nil && d.failError.domain == PTKWebSocketErrorDomain &&
              d.failError.code == expected,
          [NSString stringWithFormat:@"%@ -> code=%ld（期望 %ld）", name, (long)d.failError.code,
                                     (long)expected]);
    if (d.failError) printf("      └ %s\n", d.failError.localizedDescription.UTF8String);
    pthread_join(th, NULL);
    close(lfd);
}

static void TestHandshakeFailure(void) {
    printf("\n[C] 错误路径（都不能静默卡死）\n");
    // 1) 端口没人听 -> StreamOpenFailed，且必须是异步回调而不是阻塞
    ProbeDelegate *d = [ProbeDelegate new];
    PTKWebSocket *ws = [[PTKWebSocket alloc] initWithURL:[NSURL URLWithString:@"ws://127.0.0.1:1/lan"]
                                                delegate:d];
    NSDate *t0 = [NSDate date];
    [ws open];
    NSTimeInterval openCost = -[t0 timeIntervalSinceNow];
    Check(openCost < 1.0, [NSString stringWithFormat:@"open 非阻塞（%.3fs 返回）", openCost]);
    Check(Pump(d, 12.0, ^BOOL { return d.done; }), @"连不上时回调 didFailWithError（不静默卡死）");
    Check(d.failCount == 1 && d.closeCount == 0, @"失败路径走 didFailWithError 一次");
    // macOS 上 CFStream 的"连接被拒"既可能同步报 StreamOpenFailed，也可能异步报 Transport
    Check(d.failError.domain == PTKWebSocketErrorDomain &&
              (d.failError.code == PTKWebSocketErrorStreamOpenFailed ||
               d.failError.code == PTKWebSocketErrorTransport),
          @"连不上 -> StreamOpenFailed(或异步 Transport)");
    if (d.failError) printf("      └ %s\n", d.failError.localizedDescription.UTF8String);

    // 2) 服务器回 200 而不是 101
    ProbeBadServer(@"服务器返回 200 -> HandshakeRejected",
                   "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 200,
                   PTKWebSocketErrorHandshakeRejected);
    // 3) 服务器回 101 但 Accept 是错的
    ProbeBadServer(@"Accept 校验失败 -> HandshakeBadAccept",
                   "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                   "Connection: Upgrade\r\nSec-WebSocket-Accept: wrongvalue\r\n\r\n", 200,
                   PTKWebSocketErrorHandshakeBadAccept);
    // 4) 服务器收下请求后什么都不回 -> 握手超时
    // 服务器装死时要一直挂着（holdMs 必须长过客户端的握手超时）
    ProbeBadServer(@"服务器装死 -> HandshakeRejected(超时)", NULL, 8000,
                   PTKWebSocketErrorHandshakeRejected);
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("PTKWebSocket 帧编解码 + 联调测试\n");
        TestFrameCodec();
        TestLiveSocket();
        TestHandshakeFailure();
        printf("\n结果: %d 通过, %d 失败\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
