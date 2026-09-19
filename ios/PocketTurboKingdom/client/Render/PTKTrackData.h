// PTKTrackData —— 读取 export-scene.mjs 产出的 .ptkgeo 几何资产，装配成 SceneKit 场景。
// 只依赖 Foundation + SceneKit + CoreGraphics/CoreText，可在 iOS 12 与 macOS 上编译。
#import <Foundation/Foundation.h>
#import <SceneKit/SceneKit.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 每个材质合并后的一块静态几何（对应 .ptkgeo 里的一个 node）
@interface PTKGeoNode : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *materialKey;
@property (nonatomic, strong) SCNGeometry *geometry;
@property (nonatomic, strong) SCNMaterial *material;
@end

/// 指示牌：导出时只留文字、尺寸、颜色和世界变换，客户端用 CoreGraphics 重绘贴图
@interface PTKSign : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *color;   // "#rrggbb"
@property (nonatomic) CGFloat width, height;
@property (nonatomic) SCNMatrix4 transform;
@end

/// 动态锚点：道具箱 / 移动障碍 / 加速带 / 起点
@interface PTKAnchor : NSObject
@property (nonatomic, copy) NSString *kind;
@property (nonatomic) SCNVector3 position;
@property (nonatomic) SCNVector3 right;
@property (nonatomic) CGFloat t, lane, yaw, phase, bank;
@end

/// 赛道采样点（导出时每 4 个采样取 1 个）：用于按位置查赛道倾斜角与做小地图
@interface PTKTrackSample : NSObject
@property (nonatomic) SCNVector3 position;
@property (nonatomic) CGFloat yaw, bank, t;
@end

/// 赛车规格（来自 src/config/game.ts 的 KARTS，导出时一并带过来，避免两边各写一份）
@interface PTKKartSpec : NSObject
@property (nonatomic, copy) NSString *kartId, *name, *title, *vehicle, *type;
@property (nonatomic) NSInteger color, accent;
+ (instancetype)specFromDictionary:(NSDictionary *)dict;
@end

@interface PTKTrackData : NSObject
@property (nonatomic, copy) NSArray<PTKGeoNode *> *nodes;
@property (nonatomic, copy) NSArray<PTKSign *> *signs;
@property (nonatomic, copy) NSArray<PTKAnchor *> *boxes;
@property (nonatomic, copy) NSArray<PTKAnchor *> *obstacles;
@property (nonatomic, copy) NSArray<PTKAnchor *> *boostPads;
@property (nonatomic, copy) NSArray<PTKKartSpec *> *karts;
@property (nonatomic, copy) NSArray<PTKTrackSample *> *trackSamples;
@property (nonatomic, strong, nullable) PTKAnchor *start;
@property (nonatomic) CGFloat halfWidth;
@property (nonatomic) BOOL arena;
@property (nonatomic) NSUInteger triangleCount;

+ (nullable instancetype)dataWithContentsOfFile:(NSString *)path error:(NSError **)error;

/// 装配静态场景：所有合并几何一次性加到 root 上，返回 root。
- (SCNNode *)buildStaticScene;

/// 用 CoreGraphics/CoreText 画出的指示牌贴图（透明背景）。
+ (nullable id)textImageForSign:(PTKSign *)sign scale:(CGFloat)scale;
@end

/// 简单几何图元工厂，客户端和离屏工具共用
SCNNode *PTKBoxNode(CGFloat w, CGFloat h, CGFloat d, id color);
SCNNode *PTKCylinderNode(CGFloat radius, CGFloat height, id color);
SCNNode *PTKSphereNode(CGFloat radius, id color);
SCNNode *PTKConeNode(CGFloat radius, CGFloat height, id color);
id PTKColor(CGFloat r, CGFloat g, CGFloat b);
/// 0xRRGGBB（sRGB，与游戏配置一致）
id PTKColorHex(NSInteger hex);
/// 无光泽/带高光的材质，A7 上用 Blinn
SCNMaterial *PTKMaterial(id color, CGFloat specular);

NS_ASSUME_NONNULL_END
