// PTKWebSocketPrivate.h —— PTKWebSocket 的内部帧编解码层。
//
// 这里放"纯函数"部分（编码/解析/增量喂数据），目的是让 tests/ws_frame_test.m
// 可以在没有任何网络的情况下直接验证：7/16/64 位长度、掩码、分片拼接、
// ping/pong/close、半帧缓冲。产品代码请只 import PTKWebSocket.h。
//
// 本文件是 ios/ 内部私有头，不属于对外 API。
#import <Foundation/Foundation.h>

/// RFC6455 opcode（低 4 位）。
typedef NS_ENUM(uint8_t, PTKOpcode) {
    PTKOpcodeContinuation = 0x0,
    PTKOpcodeText = 0x1,
    PTKOpcodeBinary = 0x2,
    PTKOpcodeClose = 0x8,
    PTKOpcodePing = 0x9,
    PTKOpcodePong = 0xA,
};

/// 把 opcode 渲染成日志用的名字。
FOUNDATION_EXPORT NSString *PTKOpcodeName(PTKOpcode op);

/// 按 RFC6455 组一个帧。payload 为 nil 视作空。
/// 注意：mask=YES 时每次调用都会生成新的随机掩码。
FOUNDATION_EXPORT NSData *PTKFrameEncode(PTKOpcode op, BOOL fin, NSData *payload, BOOL mask);

/// 从 buffer 里尝试取出一帧。返回 YES 时填充 out*，并消费 buffer 里的对应字节。
/// 数据不足（跨 TCP 包的半帧）返回 NO 且不改动 buffer。
/// 帧头非法返回 NO 并通过 outError 报错（buffer 已被消费，避免死循环）。
FOUNDATION_EXPORT BOOL PTKFrameParse(NSMutableData *buffer,
                                     PTKOpcode *outOp,
                                     BOOL *outFin,
                                     NSData *__strong *outPayload,
                                     NSError *__autoreleasing *outError);

/// 解析 close 帧 payload 里的 code（无 payload 返回 -1）+ UTF-8 reason。
FOUNDATION_EXPORT void PTKClosePayloadDecode(NSData *payload, NSInteger *outCode, NSString **outReason);

/// close 帧 payload：2 字节大端 code + UTF-8 reason（reason 为空则只有 code）。
FOUNDATION_EXPORT NSData *PTKClosePayloadEncode(NSInteger code, NSString *reason);

/// SHA-1（RFC3174）。握手校验用；自己实现，不引 OpenSSL / CommonCrypto。
FOUNDATION_EXPORT void PTKSHA1(const uint8_t *data, size_t len, uint8_t out[20]);

/// 增量的消息重组器：把 text/binary + continuation 帧拼成完整消息。
@interface PTKFrameAssembler : NSObject
/// 喂一帧；拼完返回完整 payload（文本按 UTF-8 还原由调用方做），否则返回 nil。
- (NSData *)acceptOpcode:(PTKOpcode)op fin:(BOOL)fin payload:(NSData *)payload error:(NSError **)error;
/// 有未完成的分片消息吗。
@property (nonatomic, readonly) BOOL hasPendingFragment;
@end
