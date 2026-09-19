// PTKGameViewController —— SceneKit 视图 + 局域网联机 + 快照插值的主控。
//
// 局域网模式下服务器是权威物理：本类只做三件事
//   1. 把 20Hz 的 snapshot 插值成 60fps 的渲染（与网页版一致：alpha = min(1, 距上次快照 / 50ms)）
//   2. 30Hz 上传触屏输入（seq 严格递增）
//   3. 用导出的 .ptkgeo 静态几何 + 服务器状态重建画面
#import <UIKit/UIKit.h>

@interface PTKGameViewController : UIViewController
@end
