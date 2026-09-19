// PTKWebSocket.m —— 零依赖 RFC6455 客户端（BSD socket + CFStream）。
//
// 设计要点（都是被真实服务器行为逼出来的）：
//  * 服务器每 5s 发一个 ping，不回 pong 就被 terminate —— 收 ping 必须立刻回 pong（回显 payload）。
//  * 服务器每 20Hz 广播 snapshot，一帧 JSON 常有 1~4KB，必须能跨 TCP 包缓冲半帧。
//  * 服务器开局 10s 内必须收到 join，所以握手要快、失败要报错，不能静默卡死。
//  * 写方向：立刻尝试 + 4ms poll timer 重试。本机实测 macOS 26 的 CFWriteStream
//    **不会**派发 kCFStreamEventCanAcceptBytes，所以不能只等事件；写满时剩余字节
//    留在 outBuffer，由 poll timer 继续推。
//  * 15s 收不到任何字节即判定断线（服务器 5s 一次 ping，留了 3 倍余量）。
#import "PTKWebSocket.h"
#import "PTKWebSocketPrivate.h"

#import <CFNetwork/CFNetwork.h>
#import <CoreFoundation/CoreFoundation.h>
#import <string.h>

NSString *const PTKWebSocketErrorDomain = @"PTKWebSocketErrorDomain";

static const NSTimeInterval kPTKHandshakeTimeout = 4.0;  // 连接+握手总预算
static const NSTimeInterval kPTKHeartbeatTimeout = 15.0; // 无任何数据即断线
static const NSTimeInterval kPTKCloseGrace = 3.0;        // 发完 close 等对端回 close
static const NSTimeInterval kPTKPollInterval = 0.004;    // CFStream 事件泵
static const NSUInteger kPTKMaxHandshakeBytes = 16384;
static const NSUInteger kPTKMaxMessageBytes = 1u << 22; // 4MB 上限，防止脏数据吃内存
static const char *kPTKGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

static NSError *PTKErr(PTKWebSocketError code, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:PTKWebSocketErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : msg ?: @"websocket error"}];
}

NSString *PTKOpcodeName(PTKOpcode op) {
    switch (op) {
        case PTKOpcodeContinuation: return @"continuation";
        case PTKOpcodeText: return @"text";
        case PTKOpcodeBinary: return @"binary";
        case PTKOpcodeClose: return @"close";
        case PTKOpcodePing: return @"ping";
        case PTKOpcodePong: return @"pong";
    }
    return [NSString stringWithFormat:@"opcode(0x%x)", (unsigned)op];
}

// ---------------------------------------------------------------- SHA-1（自实现，不引 OpenSSL）

void PTKSHA1(const uint8_t *data, size_t len, uint8_t out[20]) {
    uint32_t h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    uint64_t totalBits = (uint64_t)len * 8ull;
    size_t padded = ((len + 8) / 64 + 1) * 64;
    uint8_t *buf = (uint8_t *)calloc(padded, 1);
    if (!buf) {
        memset(out, 0, 20);
        return;
    }
    memcpy(buf, data, len);
    buf[len] = 0x80;
    for (int i = 0; i < 8; i++) buf[padded - 1 - (size_t)i] = (uint8_t)(totalBits >> (8 * i));
    for (size_t off = 0; off < padded; off += 64) {
        uint32_t w[80];
        for (int i = 0; i < 16; i++)
            w[i] = ((uint32_t)buf[off + i * 4] << 24) | ((uint32_t)buf[off + i * 4 + 1] << 16) |
                   ((uint32_t)buf[off + i * 4 + 2] << 8) | (uint32_t)buf[off + i * 4 + 3];
        for (int i = 16; i < 80; i++) {
            uint32_t v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
            w[i] = (v << 1) | (v >> 31);
        }
        uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if (i < 20) {
                f = (b & c) | ((~b) & d);
                k = 0x5A827999;
            } else if (i < 40) {
                f = b ^ c ^ d;
                k = 0x6ED9EBA1;
            } else if (i < 60) {
                f = (b & c) | (b & d) | (c & d);
                k = 0x8F1BBCDC;
            } else {
                f = b ^ c ^ d;
                k = 0xCA62C1D6;
            }
            uint32_t tmp = ((a << 5) | (a >> 27)) + f + e + k + w[i];
            e = d;
            d = c;
            c = (b << 30) | (b >> 2);
            b = a;
            a = tmp;
        }
        h0 += a; h1 += b; h2 += c; h3 += d; h4 += e;
    }
    free(buf);
    uint32_t hs[5] = {h0, h1, h2, h3, h4};
    for (int i = 0; i < 5; i++) {
        out[i * 4] = (uint8_t)(hs[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(hs[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(hs[i] >> 8);
        out[i * 4 + 3] = (uint8_t)hs[i];
    }
}

// ---------------------------------------------------------------- 帧编解码（纯函数）

NSData *PTKFrameEncode(PTKOpcode op, BOOL fin, NSData *payload, BOOL mask) {
    NSData *body = payload ?: [NSData data];
    NSUInteger len = body.length;
    uint8_t header[14];
    NSUInteger n = 0;
    header[n++] = (uint8_t)((fin ? 0x80 : 0x00) | ((uint8_t)op & 0x0F));
    uint8_t maskBit = (uint8_t)(mask ? 0x80 : 0x00);
    if (len < 126) {
        header[n++] = (uint8_t)(maskBit | (uint8_t)len);
    } else if (len <= 0xFFFF) {
        header[n++] = (uint8_t)(maskBit | 126);
        header[n++] = (uint8_t)(len >> 8);
        header[n++] = (uint8_t)(len & 0xFF);
    } else {
        header[n++] = (uint8_t)(maskBit | 127);
        uint64_t v = (uint64_t)len;
        for (int i = 7; i >= 0; i--) header[n++] = (uint8_t)((v >> (8 * i)) & 0xFF);
    }
    uint8_t key[4] = {0, 0, 0, 0};
    if (mask) {
        arc4random_buf(key, sizeof(key)); // 客户端→服务器必须掩码
        memcpy(header + n, key, 4);
        n += 4;
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:n + len];
    [out appendBytes:header length:n];
    if (!len) return out;
    if (!mask) {
        [out appendData:body];
        return out;
    }
    NSMutableData *masked = [NSMutableData dataWithLength:len];
    const uint8_t *src = (const uint8_t *)body.bytes;
    uint8_t *dst = (uint8_t *)masked.mutableBytes;
    for (NSUInteger i = 0; i < len; i++) dst[i] = (uint8_t)(src[i] ^ key[i & 3]);
    [out appendData:masked];
    return out;
}

BOOL PTKFrameParse(NSMutableData *buffer,
                   PTKOpcode *outOp,
                   BOOL *outFin,
                   NSData *__strong *outPayload,
                   NSError *__autoreleasing *outError) {
    const uint8_t *p = (const uint8_t *)buffer.bytes;
    NSUInteger avail = buffer.length;
    if (avail < 2) return NO;
    BOOL fin = (p[0] & 0x80) != 0;
    uint8_t rsv = (uint8_t)(p[0] & 0x70);
    uint8_t opcode = (uint8_t)(p[0] & 0x0F);
    BOOL masked = (p[1] & 0x80) != 0;
    uint64_t len = (uint64_t)(p[1] & 0x7F);
    NSUInteger pos = 2;
    if (len == 126) {
        if (avail < pos + 2) return NO;
        len = ((uint64_t)p[pos] << 8) | (uint64_t)p[pos + 1];
        pos += 2;
    } else if (len == 127) {
        if (avail < pos + 8) return NO;
        len = 0;
        for (int i = 0; i < 8; i++) len = (len << 8) | (uint64_t)p[pos + (NSUInteger)i];
        pos += 8;
    }
    if (rsv != 0) {
        [buffer setLength:0];
        if (outError) *outError = PTKErr(PTKWebSocketErrorProtocolViolation, @"RSV 位非零（未协商扩展）");
        return NO;
    }
    if ((opcode & 0x8) && (!fin || len > 125)) {
        [buffer setLength:0];
        if (outError)
            *outError = PTKErr(PTKWebSocketErrorProtocolViolation, @"控制帧非法：fin=%d len=%llu",
                               (int)fin, (unsigned long long)len);
        return NO;
    }
    if (len > kPTKMaxMessageBytes) {
        [buffer setLength:0];
        if (outError)
            *outError = PTKErr(PTKWebSocketErrorProtocolViolation, @"帧过大：%llu 字节",
                               (unsigned long long)len);
        return NO;
    }
    uint8_t key[4] = {0, 0, 0, 0};
    if (masked) {
        if (avail < pos + 4) return NO;
        memcpy(key, p + pos, 4);
        pos += 4;
    }
    if (avail < pos + (NSUInteger)len) return NO; // 半帧：等下一个 TCP 包
    NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)len];
    if (len) {
        memcpy(payload.mutableBytes, p + pos, (NSUInteger)len);
        if (masked) {
            uint8_t *q = (uint8_t *)payload.mutableBytes;
            for (NSUInteger i = 0; i < (NSUInteger)len; i++) q[i] = (uint8_t)(q[i] ^ key[i & 3]);
        }
    }
    [buffer replaceBytesInRange:NSMakeRange(0, pos + (NSUInteger)len) withBytes:NULL length:0];
    if (outOp) *outOp = (PTKOpcode)opcode;
    if (outFin) *outFin = fin;
    if (outPayload) *outPayload = payload;
    return YES;
}

void PTKClosePayloadDecode(NSData *payload, NSInteger *outCode, NSString **outReason) {
    NSInteger code = -1;
    NSString *reason = @"";
    const uint8_t *p = (const uint8_t *)payload.bytes;
    if (payload.length >= 2) {
        code = (NSInteger)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
        if (payload.length > 2) {
            NSString *s = [[NSString alloc] initWithData:[payload subdataWithRange:NSMakeRange(2, payload.length - 2)]
                                                encoding:NSUTF8StringEncoding];
            if (s) reason = s;
        }
    }
    if (outCode) *outCode = code;
    if (outReason) *outReason = reason;
}

NSData *PTKClosePayloadEncode(NSInteger code, NSString *reason) {
    NSMutableData *d = [NSMutableData dataWithCapacity:2 + reason.length * 3];
    uint16_t c = (uint16_t)code;
    uint8_t b[2] = {(uint8_t)(c >> 8), (uint8_t)(c & 0xFF)};
    [d appendBytes:b length:2];
    if (reason.length) {
        NSData *r = [reason dataUsingEncoding:NSUTF8StringEncoding];
        if (r.length <= 123) [d appendData:r]; // 控制帧总长 <= 125
    }
    return d;
}

@implementation PTKFrameAssembler {
    NSMutableData *_fragment;
}

- (BOOL)hasPendingFragment { return _fragment != nil; }

- (NSData *)acceptOpcode:(PTKOpcode)op fin:(BOOL)fin payload:(NSData *)payload error:(NSError **)error {
    if (op == PTKOpcodeContinuation) {
        if (!_fragment) {
            if (error) *error = PTKErr(PTKWebSocketErrorProtocolViolation, @"收到孤立的 continuation 帧");
            return nil;
        }
        [_fragment appendData:payload ?: [NSData data]];
        if (_fragment.length > kPTKMaxMessageBytes) {
            if (error) *error = PTKErr(PTKWebSocketErrorProtocolViolation, @"分片消息超过上限");
            _fragment = nil;
            return nil;
        }
        if (!fin) return nil;
        NSData *done = _fragment;
        _fragment = nil;
        return done;
    }
    if (op != PTKOpcodeText && op != PTKOpcodeBinary) {
        if (error)
            *error = PTKErr(PTKWebSocketErrorProtocolViolation, @"组装器收到非数据帧 %@", PTKOpcodeName(op));
        return nil;
    }
    if (_fragment) {
        if (error) *error = PTKErr(PTKWebSocketErrorProtocolViolation, @"上一个分片消息还没结束");
        _fragment = nil;
        return nil;
    }
    if (fin) return payload ?: [NSData data];
    _fragment = [NSMutableData dataWithData:payload ?: [NSData data]];
    return nil;
}
@end

// ---------------------------------------------------------------- 事件回调桥

@interface PTKWebSocket ()
- (void)handleReadEvent:(CFStreamEventType)type;
- (void)handleWriteEvent:(CFStreamEventType)type;
- (void)processIncoming;
@end

static void PTKReadStreamCB(CFReadStreamRef stream, CFStreamEventType type, void *info) {
    (void)stream;
    PTKWebSocket *ws = (__bridge PTKWebSocket *)info;
    [ws handleReadEvent:type];
}

static void PTKWriteStreamCB(CFWriteStreamRef stream, CFStreamEventType type, void *info) {
    (void)stream;
    PTKWebSocket *ws = (__bridge PTKWebSocket *)info;
    [ws handleWriteEvent:type];
}

@implementation PTKWebSocket {
    NSURL *_url;
    __weak id<PTKWebSocketDelegate> _delegate;

    CFReadStreamRef _readStream;
    CFWriteStreamRef _writeStream;
    NSTimer *_pollTimer;      // 驱动 CFStream 事件（run loop 上 4ms 一次，极轻）
    NSTimer *_handshakeTimer;
    NSTimer *_heartbeatTimer;
    NSTimer *_closeTimer;

    NSMutableData *_inBuffer;   // 收：TCP 半帧缓冲
    NSMutableData *_outBuffer;  // 发：socket 写满时的待写队列
    NSMutableData *_handshake;  // 握手响应累积
    PTKFrameAssembler *_assembler;
    NSString *_expectedAccept;
    id _selfKeepAlive; // open 期间自持，防止 CFStream context 悬垂（ARC 安全写法）

    BOOL _handshakeDone;
    BOOL _closing;
    BOOL _flushing;
    BOOL _didNotifyFinish;      // 保证 didClose/didFail 只回调一次
    NSInteger _closeCode;       // 对端给的 code（-1 表示没有）
    NSInteger _finishCloseCode; // 收尾时要报的 code
    NSString *_finishCloseReason; // 对端 close 帧里的 reason
    NSTimeInterval _lastRxTime;
}
@synthesize closeCode = _closeCode;
@synthesize url = _url;

- (instancetype)initWithURL:(NSURL *)url delegate:(id<PTKWebSocketDelegate>)delegate {
    if ((self = [super init])) {
        _url = url;
        _delegate = delegate;
        _closeCode = -1;
        _finishCloseCode = -1;
        _inBuffer = [NSMutableData data];
        _outBuffer = [NSMutableData data];
        _handshake = [NSMutableData data];
        _assembler = [PTKFrameAssembler new];
        _lastRxTime = [NSDate timeIntervalSinceReferenceDate];
    }
    return self;
}

- (void)dealloc {
    [self cancelTimers];
    [self detachStreams];
}

- (BOOL)isOpen { return _handshakeDone; }

// ---------------------------------------------------------------- open

- (void)open {
    if (_handshakeDone || _readStream) return;
    NSString *scheme = _url.scheme.lowercaseString;
    BOOL tls = [scheme isEqualToString:@"wss"];
    if (!([scheme isEqualToString:@"ws"] || tls) || _url.host.length == 0) {
        [self finishWithError:PTKErr(PTKWebSocketErrorBadURL, @"不支持的 URL：%@", _url.absoluteString)];
        return;
    }
    NSNumber *portNum = _url.port;
    UInt32 port = portNum ? (UInt32)portNum.integerValue : (tls ? 443u : 80u);
    NSString *host = _url.host;

    CFReadStreamRef rs = NULL;
    CFWriteStreamRef wstream = NULL;
    CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, (__bridge CFStringRef)host, port, &rs, &wstream);
    if (!rs || !wstream) {
        if (rs) CFRelease(rs);
        if (wstream) CFRelease(wstream);
        [self finishWithError:PTKErr(PTKWebSocketErrorStreamOpenFailed, @"无法创建到 %@:%u 的 socket", host, port)];
        return;
    }
    _readStream = rs;
    _writeStream = wstream;
    // 让 CFStream 负责 close(2)，否则原生 fd 会泄漏
    CFReadStreamSetProperty(_readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(_writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    if (tls) {
        CFReadStreamSetProperty(_readStream, kCFStreamPropertySocketSecurityLevel,
                                kCFStreamSocketSecurityLevelNegotiatedSSL);
        CFWriteStreamSetProperty(_writeStream, kCFStreamPropertySocketSecurityLevel,
                                 kCFStreamSocketSecurityLevelNegotiatedSSL);
    }

    // 握手请求：不声明 Sec-WebSocket-Extensions（服务器没开 permessage-deflate）
    uint8_t nonce[16];
    arc4random_buf(nonce, sizeof(nonce));
    NSString *key = [[NSData dataWithBytes:nonce length:sizeof(nonce)] base64EncodedStringWithOptions:0];
    NSString *path = _url.path.length ? _url.path : @"/";
    if (_url.query.length) path = [path stringByAppendingFormat:@"?%@", _url.query];
    BOOL defaultPort = (tls && port == 443) || (!tls && port == 80);
    NSMutableString *req = [NSMutableString string];
    [req appendFormat:@"GET %@ HTTP/1.1\r\n", path];
    [req appendFormat:@"Host: %@%@\r\n", host,
                     defaultPort ? @"" : [NSString stringWithFormat:@":%u", port]];
    [req appendString:@"Upgrade: websocket\r\n"];
    [req appendString:@"Connection: Upgrade\r\n"];
    [req appendFormat:@"Sec-WebSocket-Key: %@\r\n", key];
    [req appendString:@"Sec-WebSocket-Version: 13\r\n"];
    [req appendString:@"\r\n"];
    [_outBuffer setData:[req dataUsingEncoding:NSUTF8StringEncoding]];
    _expectedAccept = [self acceptForKey:key];

    _selfKeepAlive = self;
    // 先在"没有装 client 回调"的状态下 open：CFStream 会在 CFReadStreamOpen /
    // CFWriteStreamOpen 内部同步派发一个事件；若此时 client 已装好，回调里再碰
    // CFWriteStreamWrite 就会和 CFStream 自己的状态机互锁（本机 macOS 实测直接 hang）。
    // 所以顺序必须是：open（无 client）-> attach client + schedule。
    // 连 127.0.0.1 时 open 是同步完成的（真实服务器握手同样走这条路）。
    Boolean rok = CFReadStreamOpen(_readStream);
    Boolean wok = CFWriteStreamOpen(_writeStream);
    if (!rok || !wok) {
        [self finishWithError:PTKErr(PTKWebSocketErrorStreamOpenFailed, @"连接 %@:%u 失败（服务未启动？）", host, port)];
        return;
    }
    [self attachStreams];
    // 立刻把握手请求推出去，不等 CanAcceptBytes 事件
    [self flushOut];
    _lastRxTime = [NSDate timeIntervalSinceReferenceDate];
    [self scheduleTimer:&_handshakeTimer interval:kPTKHandshakeTimeout selector:@selector(onHandshakeTimeout:)];
    [self scheduleTimer:&_heartbeatTimer interval:kPTKHeartbeatTimeout selector:@selector(onHeartbeatTick:)];
}

// Sec-WebSocket-Accept = base64(sha1(key + GUID))
- (NSString *)acceptForKey:(NSString *)key {
    NSMutableData *d = [[key dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [d appendBytes:kPTKGUID length:strlen(kPTKGUID)];
    uint8_t digest[20];
    PTKSHA1((const uint8_t *)d.bytes, d.length, digest);
    return [[NSData dataWithBytes:digest length:20] base64EncodedStringWithOptions:0];
}

// ---------------------------------------------------------------- run loop 接线


- (void)attachStreams {
    CFOptionFlags flags = (kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable |
                           kCFStreamEventCanAcceptBytes | kCFStreamEventErrorOccurred |
                           kCFStreamEventEndEncountered);
    CFStreamClientContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
    if (_readStream) {
        CFReadStreamSetClient(_readStream, flags, PTKReadStreamCB, &ctx);
        CFReadStreamScheduleWithRunLoop(_readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    }
    if (_writeStream) {
        CFWriteStreamSetClient(_writeStream, flags, PTKWriteStreamCB, &ctx);
        CFWriteStreamScheduleWithRunLoop(_writeStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    }
    // CFReadStream/CFWriteStream 在一次 run loop 迭代里只派发**一个**事件；
    // 用 4ms 的 poll timer 连续推进，保证 20Hz snapshot 和 5s ping 都被及时处理。
    if (!_pollTimer) {
        _pollTimer = [NSTimer timerWithTimeInterval:kPTKPollInterval
                                             target:self
                                           selector:@selector(onPoll:)
                                           userInfo:nil
                                            repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)detachStreams {
    if (_readStream) {
        CFReadStreamSetClient(_readStream, kCFStreamEventNone, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(_readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        CFReadStreamClose(_readStream);
        CFRelease(_readStream);
        _readStream = NULL;
    }
    if (_writeStream) {
        CFWriteStreamSetClient(_writeStream, kCFStreamEventNone, NULL, NULL);
        CFWriteStreamUnscheduleFromRunLoop(_writeStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        CFWriteStreamClose(_writeStream);
        CFRelease(_writeStream);
        _writeStream = NULL;
    }
}

- (void)cancelTimers {
    NSTimer *timers[4] = {_pollTimer, _handshakeTimer, _heartbeatTimer, _closeTimer};
    NSTimer *__strong *slots[4] = {&_pollTimer, &_handshakeTimer, &_heartbeatTimer, &_closeTimer};
    for (int i = 0; i < 4; i++) {
        [timers[i] invalidate];
        *slots[i] = nil;
    }
}

- (void)scheduleTimer:(NSTimer *__strong *)slot
             interval:(NSTimeInterval)interval
             selector:(SEL)sel {
    [*slot invalidate];
    *slot = [NSTimer timerWithTimeInterval:interval target:self selector:sel userInfo:nil repeats:NO];
    [[NSRunLoop currentRunLoop] addTimer:*slot forMode:NSRunLoopCommonModes];
}

// ---------------------------------------------------------------- 事件

- (void)onPoll:(NSTimer *)timer {
    (void)timer;
    if (!_handshakeDone) [self flushOut]; // 握手请求可能还没写出去
}

- (void)handleReadEvent:(CFStreamEventType)type {
    if (!_readStream) return;
    if (type & kCFStreamEventOpenCompleted) [self flushOut];
    if (type & kCFStreamEventHasBytesAvailable) {
        uint8_t buf[32768];
        CFIndex n = CFReadStreamRead(_readStream, buf, (CFIndex)sizeof(buf));
        if (n > 0) {
            _lastRxTime = [NSDate timeIntervalSinceReferenceDate];
            [_inBuffer appendBytes:buf length:(NSUInteger)n];
            [self processIncoming];
        } else if (n < 0 && !_closing && !_didNotifyFinish) {
            [self failFromStreams:@"读取失败"];
            return;
        }
    }
    if (!_readStream) return; // 上面的处理可能已经收尾
    if ((type & kCFStreamEventErrorOccurred) && !_closing && !_didNotifyFinish) {
        [self failFromStreams:@"socket 错误"];
        return;
    }
    if (type & kCFStreamEventEndEncountered) {
        if (!_handshakeDone) {
            [self finishWithError:PTKErr(PTKWebSocketErrorClosedByPeer, @"握手期间连接被关闭")];
        } else {
            [self finishWithCode:(_finishCloseCode >= 0 ? _finishCloseCode : 1006)
                          reason:_finishCloseReason];
        }
    }
}

- (void)handleWriteEvent:(CFStreamEventType)type {
    if (!_writeStream) return;
    if (type & (kCFStreamEventOpenCompleted | kCFStreamEventCanAcceptBytes)) [self flushOut];
    if (!_writeStream) return;
    if ((type & kCFStreamEventErrorOccurred) && !_closing && !_didNotifyFinish) {
        [self failFromStreams:@"写入失败"];
        return;
    }
    if (type & kCFStreamEventEndEncountered) {
        if (!_handshakeDone) {
            [self finishWithError:PTKErr(PTKWebSocketErrorClosedByPeer, @"握手期间连接被关闭")];
        } else {
            [self finishWithCode:(_finishCloseCode >= 0 ? _finishCloseCode : 1006)
                          reason:_finishCloseReason];
        }
    }
}

// 再上一道保险：CFStream 会在 CFWriteStreamWrite 内部同步派发事件回调，
// 回调若再进 flushOut 就是递归 + 自锁。_flushing 挡住重入。
- (void)flushOut {
    if (_flushing) return;
    if (!_writeStream || _outBuffer.length == 0) return;
    _flushing = YES;
    while (_writeStream && _outBuffer.length) {
        CFIndex n = CFWriteStreamWrite(_writeStream, _outBuffer.bytes, (CFIndex)_outBuffer.length);
        if (n <= 0) break; // 写满：剩余字节留着，等下一次事件 / poll timer
        [_outBuffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)n) withBytes:NULL length:0];
    }
    _flushing = NO;
}

// ---------------------------------------------------------------- 握手

- (void)processIncoming {
    if (_handshakeDone) {
        [self processFrames];
        return;
    }
    [_handshake appendData:_inBuffer];
    [_inBuffer setLength:0];
    if (_handshake.length > kPTKMaxHandshakeBytes) {
        [self finishWithError:PTKErr(PTKWebSocketErrorHandshakeMalformed, @"握手响应头超过 %lu 字节",
                                     (unsigned long)kPTKMaxHandshakeBytes)];
        return;
    }
    NSRange sep = [_handshake rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4]
                                  options:0
                                    range:NSMakeRange(0, _handshake.length)];
    NSUInteger sepLen = 4;
    if (sep.location == NSNotFound) {
        sep = [_handshake rangeOfData:[NSData dataWithBytes:"\n\n" length:2]
                              options:0
                                range:NSMakeRange(0, _handshake.length)];
        sepLen = 2;
    }
    if (sep.location == NSNotFound) return; // 响应头还没收全
    NSData *headData = [_handshake subdataWithRange:NSMakeRange(0, sep.location)];
    NSData *rest = [_handshake subdataWithRange:NSMakeRange(sep.location + sepLen,
                                                           _handshake.length - sep.location - sepLen)];
    NSString *head = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding];
    if (!head) {
        [self finishWithError:PTKErr(PTKWebSocketErrorHandshakeMalformed, @"握手响应不是 UTF-8")];
        return;
    }
    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\n"];
    NSArray<NSString *> *status =
        [[lines.firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
            componentsSeparatedByString:@" "];
    if (status.count < 2) {
        [self finishWithError:PTKErr(PTKWebSocketErrorHandshakeMalformed, @"无法解析状态行：%@",
                                     lines.firstObject)];
        return;
    }
    NSInteger code = status[1].integerValue;
    if (code != 101) {
        [self finishWithError:PTKErr(PTKWebSocketErrorHandshakeRejected, @"服务器返回 %ld（期望 101）",
                                     (long)code)];
        return;
    }
    NSString *accept = nil;
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        if ([[line substringToIndex:colon.location] caseInsensitiveCompare:@"Sec-WebSocket-Accept"] ==
            NSOrderedSame) {
            // "Sec-WebSocket-Accept: xxx" —— 冒号后面的空格必须去掉再比对
            accept = [[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            break;
        }
    }
    if (!accept || ![accept isEqualToString:_expectedAccept]) {
        [self finishWithError:PTKErr(PTKWebSocketErrorHandshakeBadAccept,
                                     @"Sec-WebSocket-Accept 校验失败（收到 %@，期望 %@）",
                                     accept ?: @"(缺失)", _expectedAccept)];
        return;
    }
    _handshakeDone = YES;
    [_handshakeTimer invalidate];
    _handshakeTimer = nil;
    _lastRxTime = [NSDate timeIntervalSinceReferenceDate];
    [_inBuffer setData:rest]; // 握手响应和第一帧可能挤在同一个 TCP 包里
    [self notifyOpen];
    if (!_didNotifyFinish && _handshakeDone) [self processFrames];
}

- (void)onHandshakeTimeout:(NSTimer *)timer {
    (void)timer;
    if (_handshakeDone) return;
    [self finishWithError:PTKErr(PTKWebSocketErrorHandshakeRejected, @"握手超时（%.0fs）", kPTKHandshakeTimeout)];
}

- (void)onHeartbeatTick:(NSTimer *)timer {
    (void)timer;
    if (!_handshakeDone) return;
    NSTimeInterval idle = [NSDate timeIntervalSinceReferenceDate] - _lastRxTime;
    if (idle >= kPTKHeartbeatTimeout) {
        [self finishWithError:PTKErr(PTKWebSocketErrorHeartbeatTimeout,
                                     @"%.0fs 未收到任何数据（服务器 ping 也没来）", idle)];
        return;
    }
    [self scheduleTimer:&_heartbeatTimer interval:kPTKHeartbeatTimeout selector:@selector(onHeartbeatTick:)];
}

// ---------------------------------------------------------------- 帧分发

- (void)processFrames {
    while (_inBuffer.length && _handshakeDone && !_didNotifyFinish) {
        PTKOpcode op = PTKOpcodeContinuation;
        BOOL fin = NO;
        NSData *payload = nil;
        NSError *err = nil;
        if (!PTKFrameParse(_inBuffer, &op, &fin, &payload, &err)) {
            if (err) [self finishWithError:err];
            return; // 否则是半帧，等更多数据
        }
        _lastRxTime = [NSDate timeIntervalSinceReferenceDate];
        if (![self handleFrameOpcode:op fin:fin payload:payload]) return;
    }
}

- (BOOL)handleFrameOpcode:(PTKOpcode)op fin:(BOOL)fin payload:(NSData *)payload {
    switch (op) {
        case PTKOpcodePing:
            // 最关键的一条：服务器 5s 一次 ping，不回 pong 会被 terminate
            [_outBuffer appendData:PTKFrameEncode(PTKOpcodePong, YES, payload, YES)];
            [self flushOut];
            return YES;
        case PTKOpcodePong:
            return YES; // 服务器只回 pong，不主动发
        case PTKOpcodeClose: {
            NSInteger code = -1;
            NSString *reason = @"";
            PTKClosePayloadDecode(payload, &code, &reason);
            _closeCode = code;
            if (_closing) {
                [self finishWithCode:(_finishCloseCode >= 0 ? _finishCloseCode : 1000) reason:reason];
                return NO;
            }
            _closing = YES;
            NSInteger echo = (code >= 0) ? code : 1000;
            [_outBuffer appendData:PTKFrameEncode(PTKOpcodeClose, YES,
                                                  PTKClosePayloadEncode(echo, @""), YES)];
            [self flushOut];
            _finishCloseCode = code; // 对端给的 code 原样上报
            _finishCloseReason = reason ?: @"";
            // 正常情况：对端收到我们的 close 后关 TCP，read stream 报 EOF 收尾；
            // 这里兜一个 1s 的底，避免对端不回时挂住。
            [self scheduleTimer:&_closeTimer interval:1.0 selector:@selector(onCloseGrace:)];
            return YES;
        }
        case PTKOpcodeText:
        case PTKOpcodeBinary:
        case PTKOpcodeContinuation: {
            NSError *err = nil;
            NSData *message = [_assembler acceptOpcode:op fin:fin payload:payload error:&err];
            if (err) {
                [self finishWithError:err];
                return NO;
            }
            if (!message) return YES; // 分片还没拼完
            NSString *text = [[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding];
            if (!text) {
                [self finishWithError:PTKErr(PTKWebSocketErrorProtocolViolation, @"文本帧不是合法 UTF-8")];
                return NO;
            }
            [self notifyText:text];
            return YES;
        }
    }
    [self finishWithError:PTKErr(PTKWebSocketErrorProtocolViolation, @"未知 opcode 0x%x", (unsigned)op)];
    return NO;
}

// ---------------------------------------------------------------- 发送 / 关闭

- (void)sendText:(NSString *)text {
    if (!_handshakeDone || _closing || !text) return;
    [_outBuffer appendData:PTKFrameEncode(PTKOpcodeText, YES,
                                          [text dataUsingEncoding:NSUTF8StringEncoding], YES)];
    [self flushOut];
}

- (void)close {
    if (!_handshakeDone) {
        [self finishWithCode:1000 reason:@"本地关闭（未连上）"];
        return;
    }
    if (_closing) return;
    _closing = YES;
    _finishCloseCode = 1000;
    _finishCloseReason = @"";
    [_outBuffer appendData:PTKFrameEncode(PTKOpcodeClose, YES,
                                          PTKClosePayloadEncode(1000, @""), YES)];
    [self flushOut];
    [self scheduleTimer:&_closeTimer interval:kPTKCloseGrace selector:@selector(onCloseGrace:)];
}

- (void)onCloseGrace:(NSTimer *)timer {
    (void)timer;
    if (_didNotifyFinish) return;
    [self finishWithCode:(_finishCloseCode >= 0 ? _finishCloseCode : 1000)
                  reason:@"close 握手完成（对端未回 close 帧）"];
}

// ---------------------------------------------------------------- 收尾 / 回调

- (void)failFromStreams:(NSString *)what {
    CFStreamError re = _readStream ? CFReadStreamGetError(_readStream) : (CFStreamError){0, 0};
    CFStreamError we = _writeStream ? CFWriteStreamGetError(_writeStream) : (CFStreamError){0, 0};
    CFStreamError e = re.error ? re : we;
    [self finishWithError:PTKErr(PTKWebSocketErrorTransport, @"%@（domain=%ld code=%ld）",
                                 what, (long)e.domain, (long)e.error)];
}

- (void)finishWithError:(NSError *)error {
    if (_didNotifyFinish) return;
    _didNotifyFinish = YES;
    _handshakeDone = NO;
    [self teardown];
    id<PTKWebSocketDelegate> d = _delegate;
    if ([d respondsToSelector:@selector(webSocket:didFailWithError:)]) [d webSocket:self didFailWithError:error];
    _selfKeepAlive = nil;
}

- (void)finishWithCode:(NSInteger)code reason:(NSString *)reason {
    if (_didNotifyFinish) return;
    _didNotifyFinish = YES;
    _handshakeDone = NO;
    if (_closeCode < 0) _closeCode = code;
    [self teardown];
    id<PTKWebSocketDelegate> d = _delegate;
    if ([d respondsToSelector:@selector(webSocket:didCloseWithCode:reason:)])
        [d webSocket:self didCloseWithCode:code reason:reason ?: @""];
    _selfKeepAlive = nil;
}

- (void)teardown {
    [self cancelTimers];
    [self detachStreams];
    [_outBuffer setLength:0];
    [_inBuffer setLength:0];
    [_handshake setLength:0];
}

- (void)notifyOpen {
    id<PTKWebSocketDelegate> d = _delegate;
    if ([d respondsToSelector:@selector(webSocketDidOpen:)]) [d webSocketDidOpen:self];
}

- (void)notifyText:(NSString *)text {
    id<PTKWebSocketDelegate> d = _delegate;
    if ([d respondsToSelector:@selector(webSocket:didReceiveText:)]) [d webSocket:self didReceiveText:text];
}
@end
