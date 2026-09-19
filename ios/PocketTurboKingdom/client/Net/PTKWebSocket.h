// PTKWebSocket.h —— 口袋涡轮王国 · 零依赖 RFC6455 客户端
//
// 目标：iOS 12.5.8 (iPad mini 2 / A7) 与 macOS 双端可编译。
// 依赖：Foundation + CFNetwork(+Security 可选)；**不使用** NSURLSessionWebSocketTask（iOS 13+）。
// 线程模型：内部只用 BSD socket + CFStream，所有事件源都挂在调用 open 的 run loop 上
//           （App 里就是 main run loop），所有 delegate 回调都在同一 run loop 触发。
// 内存：ARC；CFStream 是 CF 类型，由本类手工 CFRelease；socket 由 CFStream 负责关闭。
#import <Foundation/Foundation.h>

@class PTKWebSocket;

@protocol PTKWebSocketDelegate <NSObject>
- (void)webSocketDidOpen:(PTKWebSocket *)ws;
- (void)webSocket:(PTKWebSocket *)ws didReceiveText:(NSString *)text;
- (void)webSocket:(PTKWebSocket *)ws didCloseWithCode:(NSInteger)code reason:(NSString *)reason;
- (void)webSocket:(PTKWebSocket *)ws didFailWithError:(NSError *)error;
@end

/// 统一错误域。code 见 PTKWebSocketError 枚举。
extern NSString *const PTKWebSocketErrorDomain;

typedef NS_ENUM(NSInteger, PTKWebSocketError) {
    PTKWebSocketErrorBadURL = 1,             // 不是 ws:// wss:// 或缺少 host
    PTKWebSocketErrorStreamOpenFailed = 2,   // CFStream 打不开（端口不通/被拒）
    PTKWebSocketErrorHandshakeRejected = 3,  // 服务器没回 101
    PTKWebSocketErrorHandshakeBadAccept = 4, // Sec-WebSocket-Accept 校验失败
    PTKWebSocketErrorHandshakeMalformed = 5, // 响应头解析不出状态行
    PTKWebSocketErrorProtocolViolation = 6,  // 非法帧（保留位/控制帧过长/未知 opcode）
    PTKWebSocketErrorTransport = 7,          // 底层读写失败
    PTKWebSocketErrorHeartbeatTimeout = 8,   // 15s 内没有任何数据
    PTKWebSocketErrorClosedByPeer = 9,       // 对端直接断开（无 close 帧）
};

@interface PTKWebSocket : NSObject

/// 建连所用的 URL（ws:// 或 wss://）。
@property (nonatomic, readonly) NSURL *url;

/// YES 表示握手已完成、close 帧尚未发出。
@property (nonatomic, readonly) BOOL isOpen;

/// 服务器在 close 帧里给的 code（对端发起关闭时才有意义，默认 -1）。
@property (nonatomic, readonly) NSInteger closeCode;

/// delegate 是弱引用，避免和渲染层互相持有。
- (instancetype)initWithURL:(NSURL *)url delegate:(id<PTKWebSocketDelegate>)delegate;

/// 非阻塞：建 socket、跑 HTTP Upgrade 握手，把 CFStream 调度到当前 run loop。
- (void)open;

/// 发文本帧（客户端帧强制掩码）。未 open 时静默丢弃。
- (void)sendText:(NSString *)text;

/// 发 close 帧（code 1000），随后收尾并回调 didCloseWithCode:1000。
- (void)close;
@end
