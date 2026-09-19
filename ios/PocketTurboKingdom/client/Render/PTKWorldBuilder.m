#import "PTKWorldBuilder.h"
#import <math.h>

@implementation PTKTrackPath
- (instancetype)initWithTrackData:(PTKTrackData *)data {
  if ((self = [super init])) _points = data.trackSamples ?: @[];
  return self;
}

- (PTKTrackSample *)nearest:(SCNVector3)position {
  PTKTrackSample *best = nil;
  CGFloat bestDistance = INFINITY;
  for (PTKTrackSample *p in _points) {
    CGFloat dx = p.position.x - position.x, dz = p.position.z - position.z;
    CGFloat d = dx * dx + dz * dz;
    if (d < bestDistance) { bestDistance = d; best = p; }
  }
  return best;
}
@end

#pragma mark - 道具箱

@implementation PTKItemBoxNode
- (instancetype)initWithPosition:(SCNVector3)position {
  if ((self = [super init])) {
    _position = position;
    _node = [SCNNode node];
    _node.position = position;
    SCNMaterial *crystal = PTKMaterial(PTKColorHex(0xb7fbe0), 0.34);
    crystal.emission.contents = PTKColorHex(0x4e957b);
    crystal.transparency = 0.86;
    crystal.blendMode = SCNBlendModeAlpha;
    SCNNode *cube = [SCNNode nodeWithGeometry:[SCNBox boxWithWidth:1.35 height:1.35 length:1.35 chamferRadius:0]];
    cube.geometry.materials = @[ crystal ];
    [_node addChildNode:cube];

    SCNMaterial *gemMaterial = [SCNMaterial material];
    gemMaterial.lightingModelName = SCNLightingModelConstant;
    gemMaterial.diffuse.contents = PTKColorHex(0xffeeaf);
    gemMaterial.emission.contents = PTKColorHex(0xffd365);
    SCNNode *gem = [SCNNode nodeWithGeometry:[SCNPyramid pyramidWithWidth:0.55 height:0.7 length:0.55]];
    gem.geometry.materials = @[ gemMaterial ];
    [_node addChildNode:gem];
  }
  return self;
}

- (void)updateTime:(CGFloat)time {
  _node.eulerAngles = SCNVector3Make(time * 0.38, time * 0.9, 0.14);
  _node.position = SCNVector3Make(_position.x, _position.y + sin(time * 2 + _position.x) * 0.17, _position.z);
}

- (void)setAvailable:(BOOL)available { _node.hidden = !available; }
@end

#pragma mark - 移动障碍

@implementation PTKObstacleNode {
  PTKAnchor *_anchor;
}
- (instancetype)initWithAnchor:(PTKAnchor *)anchor {
  if ((self = [super init])) {
    _anchor = anchor;
    _node = [SCNNode node];
    SCNMaterial *metal = PTKMaterial(PTKColorHex(0xeaa652), 0.6);
    SCNNode *ball = [SCNNode nodeWithGeometry:[SCNSphere sphereWithRadius:1.2]];
    ball.geometry.materials = @[ metal ];
    [_node addChildNode:ball];
    for (int i = 0; i < 8; i++) {
      CGFloat a = i / 8.0 * M_PI * 2;
      SCNNode *tooth = [SCNNode nodeWithGeometry:[SCNBox boxWithWidth:0.6 height:0.6 length:0.7 chamferRadius:0]];
      tooth.geometry.materials = @[ metal ];
      tooth.position = SCNVector3Make(cos(a) * 1.1, sin(a) * 1.1, 0);
      tooth.eulerAngles = SCNVector3Make(0, 0, a);
      [_node addChildNode:tooth];
    }
  }
  return self;
}

- (void)updateTime:(CGFloat)time dt:(CGFloat)dt {
  // 与 Track.update 一致：lane = sin(time*1.05 + phase) * 6，高度 1.3 + |cos(...)| * 0.2
  CGFloat wave = time * 1.05 + _anchor.phase;
  CGFloat lane = sin(wave) * 6;
  _node.position = SCNVector3Make(_anchor.position.x + _anchor.right.x * lane,
                                  1.3 + fabs(cos(wave)) * 0.2,
                                  _anchor.position.z + _anchor.right.z * lane);
  _node.eulerAngles = SCNVector3Make(0, 0, _node.eulerAngles.z + dt * 1.5);
}
@end

#pragma mark - 道具弹体

@implementation PTKProjectileNode {
  SCNNode *_peel, *_gear, *_firefly;
}
- (instancetype)initWithKindColors:(NSDictionary<NSString *, NSNumber *> *)colors {
  if ((self = [super init])) {
    _node = [SCNNode node];
    _node.hidden = YES;
    SCNNode *peel = [SCNNode nodeWithGeometry:[SCNCone coneWithTopRadius:0 bottomRadius:0.55 height:0.7]];
    peel.geometry.materials = @[ PTKMaterial(PTKColorHex(colors[@"peel"].integerValue), 0.12) ];
    SCNNode *gear = [SCNNode nodeWithGeometry:[SCNTorus torusWithRingRadius:0.45 pipeRadius:0.15]];
    gear.geometry.materials = @[ PTKMaterial(PTKColorHex(colors[@"gear"].integerValue), 0.55) ];
    SCNMaterial *fireflyMaterial = [SCNMaterial material];
    fireflyMaterial.lightingModelName = SCNLightingModelConstant;
    fireflyMaterial.diffuse.contents = PTKColorHex(colors[@"firefly"].integerValue);
    fireflyMaterial.emission.contents = PTKColorHex(0xff5896);
    SCNNode *firefly = [SCNNode nodeWithGeometry:[SCNSphere sphereWithRadius:0.36]];
    firefly.geometry.materials = @[ fireflyMaterial ];
    _peel = peel; _gear = gear; _firefly = firefly;
    [_node addChildNode:peel];
    [_node addChildNode:gear];
    [_node addChildNode:firefly];
  }
  return self;
}

- (void)setKind:(NSString *)kind {
  _node.hidden = NO;
  _peel.hidden = ![kind isEqualToString:@"peel"];
  _gear.hidden = ![kind isEqualToString:@"gear"];
  _firefly.hidden = ![kind isEqualToString:@"firefly"];
  _gear.eulerAngles = SCNVector3Make(0, 0, [kind isEqualToString:@"gear"] ? M_PI / 2 : 0);
}
@end

#pragma mark - 工厂

@implementation PTKWorldBuilder {
  NSMutableArray<PTKProjectileNode *> *_pool;
  NSUInteger _cursor;
  NSDictionary<NSString *, NSNumber *> *_itemColors;
}
+ (instancetype)shared {
  static PTKWorldBuilder *shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [PTKWorldBuilder new]; });
  return shared;
}

- (instancetype)init {
  if ((self = [super init])) {
    _itemColors = @{ @"battery": @0xa9ff79, @"peel": @0xffb95e, @"gear": @0x8be7ff, @"firefly": @0xff7bb2 };
    _pool = [NSMutableArray array];
    for (int i = 0; i < 36; i++) [_pool addObject:[[PTKProjectileNode alloc] initWithKindColors:_itemColors]];
  }
  return self;
}

- (PTKProjectileNode *)nextProjectile {
  PTKProjectileNode *node = _pool[_cursor % _pool.count];
  _cursor++;
  return node;
}

- (SCNNode *)projectileTemplateForKind:(NSString *)kind {
  PTKProjectileNode *p = [[PTKProjectileNode alloc] initWithKindColors:_itemColors];
  [p setKind:kind];
  return p.node;
}
@end
