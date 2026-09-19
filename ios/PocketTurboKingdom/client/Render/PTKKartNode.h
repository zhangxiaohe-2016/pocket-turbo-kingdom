// PTKKartNode —— 用 SceneKit 图元复刻 src/vehicle/KartModel.ts 的赛车，并实现 KartPhysics.render 的动画。
#import <Foundation/Foundation.h>
#import <SceneKit/SceneKit.h>
#import "PTKTrackData.h"

NS_ASSUME_NONNULL_BEGIN

/// 渲染一帧所需的视觉状态（局域网模式下全部来自服务器 snapshot 的插值）
typedef struct {
  SCNVector3 previousPosition, position;
  CGFloat previousYaw, yaw;
  CGFloat speed, steering, boost, invulnerable, bank;
  BOOL grounded, drift, airborne;
} PTKKartVisual;

@interface PTKKartNode : NSObject
@property (nonatomic, strong, readonly) SCNNode *root;
@property (nonatomic, strong, readonly) SCNNode *body;
@property (nonatomic, readonly) NSInteger wheelCount;
+ (instancetype)kartWithSpec:(PTKKartSpec *)spec ghost:(BOOL)ghost;
/// 按 alpha 在 previous→position 之间插值，并驱动轮子/尾焰/天线这些局部动画
- (void)applyVisual:(PTKKartVisual)visual alpha:(CGFloat)alpha dt:(CGFloat)dt time:(CGFloat)time;
- (void)setWheelVisible:(BOOL)visible;
@end

NS_ASSUME_NONNULL_END
