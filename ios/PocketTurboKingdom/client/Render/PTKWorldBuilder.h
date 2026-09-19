// PTKWorldBuilder —— 用导出的锚点重建动态元素：道具箱、移动障碍、道具弹体，以及赛道路径查询。
#import <Foundation/Foundation.h>
#import <SceneKit/SceneKit.h>
#import "PTKTrackData.h"

NS_ASSUME_NONNULL_BEGIN

@interface PTKTrackPath : NSObject
@property (nonatomic, copy) NSArray<PTKTrackSample *> *points;
- (instancetype)initWithTrackData:(PTKTrackData *)data;
/// 按世界坐标找最近的采样点（用于车身侧倾的赛道倾斜）
- (PTKTrackSample *)nearest:(SCNVector3)position;
@end

/// 晶体道具箱：冷却期间隐藏（对应 snapshot.boxes）
@interface PTKItemBoxNode : NSObject
@property (nonatomic, strong, readonly) SCNNode *node;
@property (nonatomic, readonly) SCNVector3 position;
- (instancetype)initWithPosition:(SCNVector3)position;
- (void)updateTime:(CGFloat)time;
- (void)setAvailable:(BOOL)available;
@end

/// 移动障碍（滚动的齿轮球），位置由锚点 + 时间推导，与网页版公式一致
@interface PTKObstacleNode : NSObject
@property (nonatomic, strong, readonly) SCNNode *node;
- (instancetype)initWithAnchor:(PTKAnchor *)anchor;
- (void)updateTime:(CGFloat)time dt:(CGFloat)dt;
@end

/// 飞行中的道具：果皮 / 齿轮 / 萤火弹
@interface PTKProjectileNode : NSObject
@property (nonatomic, strong, readonly) SCNNode *node;
- (void)setKind:(NSString *)kind;
@end

@interface PTKWorldBuilder : NSObject
+ (instancetype)shared;
/// 一次性建好所有道具模型（最多 36 个，与网页版对象池一致）
- (PTKProjectileNode *)nextProjectile;
- (SCNNode *)projectileTemplateForKind:(NSString *)kind;
@end

NS_ASSUME_NONNULL_END
