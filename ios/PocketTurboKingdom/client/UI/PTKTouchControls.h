// PTKTouchControls —— iPad 触屏操作：左侧虚拟摇杆 + 右侧油门/刹车/漂移/跳跃/道具。
// 只在 iPad 上跑（无键盘无手柄），所有控件都是代码布局，横屏。
#import <UIKit/UIKit.h>
#import "PTKProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface PTKTouchControls : UIView
/// 读取当前控制量并清空一次性按键（jump/item1/item2/reset/discard 只发一帧 true，
/// 因为服务器对这几个键做 `next[k] ||= prev[k]` 保持，客户端必须显式回 false）。
- (PTKControls *)pollControls;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
