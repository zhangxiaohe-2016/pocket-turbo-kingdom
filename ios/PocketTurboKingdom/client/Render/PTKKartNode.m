#import "PTKKartNode.h"
#import <math.h>

// three 的 MathUtils.damp：一阶指数收敛，帧率无关
static CGFloat damp(CGFloat current, CGFloat target, CGFloat lambda, CGFloat dt) {
  return current + (target - current) * (1 - exp(-lambda * dt));
}

static CGFloat wrapAngle(CGFloat a) {
  return atan2(sin(a), cos(a));
}

@implementation PTKKartNode {
  NSMutableArray<SCNNode *> *_wheels;
  NSMutableArray<SCNNode *> *_wheelMounts;
  NSMutableArray<SCNNode *> *_frontMounts;
  NSMutableArray<SCNNode *> *_flames;
  SCNNode *_antenna;
  CGFloat _wheelSpin;
  CGFloat _bodyPitch, _bodyRoll;
}

// 与 KartModel.ts 的 add() 等价：单位图元 + 位置 + 缩放
static SCNNode *addPart(SCNNode *parent, SCNGeometry *geometry, SCNMaterial *material, SCNVector3 position, SCNVector3 scale) {
  // 关键：SceneKit 的 materials 属于 SCNGeometry 而不是 SCNNode。
  // 共享同一个图元实例会让所有节点都显示最后赋的那份材质，所以每个部件必须持有自己的几何副本。
  SCNGeometry *instance = [geometry copy];
  SCNNode *node = [SCNNode nodeWithGeometry:instance];
  node.geometry.materials = @[ material ];
  node.position = position;
  node.scale = scale;
  [parent addChildNode:node];
  return node;
}

static SCNVector3 V(CGFloat x, CGFloat y, CGFloat z) { return SCNVector3Make(x, y, z); }

+ (instancetype)kartWithSpec:(PTKKartSpec *)spec ghost:(BOOL)ghost {
  return [[self alloc] initWithSpec:spec ghost:ghost];
}

- (instancetype)initWithSpec:(PTKKartSpec *)spec ghost:(BOOL)ghost {
  if ((self = [super init])) {
    SCNMaterial *shell = PTKMaterial(PTKColorHex(spec.color), 0.30);
    SCNMaterial *accent = PTKMaterial(PTKColorHex(spec.accent), 0.14);
    SCNMaterial *dark = PTKMaterial(PTKColorHex(0x263d43), 0.06);
    SCNMaterial *rubber = PTKMaterial(PTKColorHex(0x202c32), 0.02);
    SCNMaterial *chrome = PTKMaterial(PTKColorHex(0xc8d7cc), 0.72);
    SCNMaterial *skin = PTKMaterial(PTKColorHex(0xf5d6a1), 0.08);
    if (ghost) {
      for (SCNMaterial *m in @[ shell, accent, dark, rubber, chrome, skin ]) {
        m.transparency = 0.28;
        m.blendMode = SCNBlendModeAlpha;
        m.writesToDepthBuffer = NO;
      }
    }

    // 共享的单位图元（对应 KartModel.ts 顶部的 box/sphere/cylinder/tireGeo）
    SCNBox *box = [SCNBox boxWithWidth:1 height:1 length:1 chamferRadius:0];
    SCNSphere *sphere = [SCNSphere sphereWithRadius:1];
    SCNCylinder *cylinder = [SCNCylinder cylinderWithRadius:1 height:1];
    SCNCylinder *tire = [SCNCylinder cylinderWithRadius:0.43 height:0.34];

    _root = [SCNNode node];
    _root.name = @"kart";
    _body = [SCNNode node];
    _body.name = @"body";
    [_root addChildNode:_body];

    addPart(_body, box, dark, V(0, -0.18, 0), V(1.22, 0.22, 2.25));
    addPart(_body, sphere, shell, V(0, 0.05, 0.3), V(0.78, 0.38, 1.06));
    addPart(_body, box, shell, V(0, 0.06, 0.92), V(1.26, 0.3, 0.58));
    addPart(_body, box, accent, V(0, 0.26, 0.77), V(0.27, 0.05, 0.82));
    addPart(_body, box, chrome, V(0, -0.05, 1.36), V(1.62, 0.14, 0.16));
    addPart(_body, box, dark, V(0, -0.12, -1.24), V(1.55, 0.2, 0.22));
    for (NSNumber *x in @[ @(-0.57), @(0.57) ]) {
      CGFloat xv = x.doubleValue;
      addPart(_body, box, dark, V(xv, 0.37, -0.98), V(0.08, 0.6, 0.09));
      addPart(_body, sphere, accent, V(xv, 0.18, 1.16), V(0.16, 0.1, 0.1));
      for (NSNumber *z in @[ @0.5, @(-0.7) ]) {
        addPart(_body, cylinder, chrome, V(xv, 0.32, z.doubleValue), V(0.045, 0.035, 0.045));
      }
    }
    addPart(_body, box, shell, V(0, 0.68, -1.03), V(1.65, 0.13, 0.45));   // 尾翼
    addPart(_body, box, accent, V(0, 0.755, -1.03), V(0.6, 0.022, 0.39));
    addPart(_body, sphere, dark, V(0, 0.42, -0.22), V(0.43, 0.6, 0.46));  // 座椅
    addPart(_body, sphere, accent, V(0, 0.67, -0.13), V(0.34, 0.44, 0.28));
    addPart(_body, sphere, skin, V(0, 1.15, -0.03), V(0.38, 0.35, 0.34)); // 头
    addPart(_body, sphere, shell, V(0, 1.31, -0.07), V(0.44, 0.27, 0.4)); // 头盔

    // 每辆车的专属细节
    if ([spec.kartId isEqualToString:@"pip"]) {
      addPart(_body, sphere, accent, V(0.08, 1.52, -0.1), V(0.15, 0.08, 0.15));
      addPart(_body, box, shell, V(0, 1.23, 0.28), V(0.62, 0.075, 0.2));
    } else if ([spec.kartId isEqualToString:@"lumi"]) {
      for (NSNumber *x in @[ @(-0.22), @(0.22) ]) {
        SCNNode *ear = addPart(_body, [SCNCone coneWithTopRadius:0 bottomRadius:0.14 height:0.48], accent,
                               V(x.doubleValue, 1.65, -0.05), V(1, 1, 1));
        ear.eulerAngles = SCNVector3Make(0, 0, -x.doubleValue);
      }
    } else if ([spec.kartId isEqualToString:@"brass"]) {
      addPart(_body, box, chrome, V(0, 1.48, 0), V(0.15, 0.2, 0.7));
    } else if ([spec.kartId isEqualToString:@"wisp"]) {
      SCNNode *hat = addPart(_body, [SCNCone coneWithTopRadius:0 bottomRadius:0.36 height:0.64], shell,
                             V(0.1, 1.67, -0.13), V(1, 1, 1));
      hat.eulerAngles = SCNVector3Make(0, 0, -0.35);
    }

    // 眼睛与手臂
    for (NSNumber *x in @[ @(-0.17), @(0.17) ]) {
      CGFloat xv = x.doubleValue;
      addPart(_body, sphere, chrome, V(xv, 1.17, 0.28), V(0.15, 0.13, 0.07));
      addPart(_body, sphere, dark, V(xv, 1.17, 0.34), V(0.1, 0.09, 0.025));
      SCNNode *arm = addPart(_body, cylinder, accent, V(xv * 2.1, 0.64, 0.27), V(0.10, 0.44, 0.10));
      arm.eulerAngles = SCNVector3Make(-0.8, 0, 0);
    }
    SCNNode *steering = addPart(_body, [SCNTorus torusWithRingRadius:0.22 pipeRadius:0.04], dark, V(0, 0.63, 0.53), V(1, 1, 1));
    steering.eulerAngles = SCNVector3Make(-0.55, 0, 0);
    _antenna = [SCNNode node];
    _antenna.name = @"antenna";
    SCNNode *mast = [SCNNode nodeWithGeometry:[cylinder copy]];
    mast.geometry.materials = @[ dark ];
    mast.position = V(0.52, 0.8, -0.67);
    mast.scale = V(0.025, 1.4, 0.025);
    [_antenna addChildNode:mast];
    SCNNode *bulb = [SCNNode nodeWithGeometry:[sphere copy]];
    bulb.geometry.materials = @[ accent ];
    bulb.position = V(0.52, 1.52, -0.67);
    bulb.scale = V(0.07, 0.07, 0.07);
    [_antenna addChildNode:bulb];

    // 轮子：mount 挂在 root 上（与 KartModel.ts 一致），order = (z=.78,-x), (z=.78,+x), (z=-.77,-x), (z=-.77,+x)
    _wheels = [NSMutableArray array];
    _wheelMounts = [NSMutableArray array];
    _frontMounts = [NSMutableArray array];
    for (NSNumber *z in @[ @0.78, @(-0.77) ]) {
      for (NSNumber *x in @[ @(-0.85), @(0.85) ]) {
        CGFloat xv = x.doubleValue, zv = z.doubleValue;
        SCNNode *axle = addPart(_body, cylinder, chrome, V(xv * 0.6, -0.22, zv), V(0.06, 0.68, 0.06));
        axle.eulerAngles = SCNVector3Make(0, 0, M_PI / 2);
        SCNNode *spring = addPart(_body, [SCNTorus torusWithRingRadius:0.095 pipeRadius:0.025], chrome, V(xv * 0.71, -0.08, zv), V(1, 1, 1));
        spring.eulerAngles = SCNVector3Make(M_PI / 2, 0, 0);

        SCNNode *mount = [SCNNode node];
        mount.position = V(xv, -0.31, zv);
        [_root addChildNode:mount];
        [_wheelMounts addObject:mount];
        if (zv > 0) [_frontMounts addObject:mount];

        SCNNode *wheel = [SCNNode node];
        [mount addChildNode:wheel];
        SCNNode *tireNode = addPart(wheel, tire, rubber, V(0, 0, 0), V(1, 1, 1));
        tireNode.eulerAngles = SCNVector3Make(0, 0, M_PI / 2);
        SCNNode *hub = addPart(wheel, cylinder, accent, V((xv > 0 ? 1 : -1) * 0.18, 0, 0), V(0.235, 0.06, 0.235));
        hub.eulerAngles = SCNVector3Make(0, 0, M_PI / 2);
        SCNNode *screw = addPart(wheel, cylinder, chrome, V((xv > 0 ? 1 : -1) * 0.218, 0, 0), V(0.07, 0.075, 0.07));
        screw.eulerAngles = SCNVector3Make(0, 0, M_PI / 2);
        for (int i = 0; i < 8; i++) {
          CGFloat a = i / 8.0 * M_PI * 2;
          SCNNode *tread = addPart(wheel, box, dark, V(0, cos(a) * 0.425, sin(a) * 0.425), V(0.355, 0.035, 0.085));
          tread.eulerAngles = SCNVector3Make(a, 0, 0);
        }
        [_wheels addObject:wheel];
      }
    }

    // 尾焰（喷口留在 body 上一起 flatten，火焰本体是可动的独立节点）
    _flames = [NSMutableArray array];
    SCNMaterial *flame = [SCNMaterial material];
    flame.lightingModelName = SCNLightingModelConstant;
    flame.diffuse.contents = PTKColorHex(0xcfff8c);
    flame.emission.contents = PTKColorHex(0x8cff68);
    for (NSNumber *x in @[ @(-0.44), @(0.44) ]) {
      SCNNode *pipe = addPart(_body, cylinder, chrome, V(x.doubleValue, -0.03, -1.23), V(0.14, 0.34, 0.14));
      pipe.eulerAngles = SCNVector3Make(M_PI / 2, 0, 0);
      SCNNode *flameNode = [SCNNode nodeWithGeometry:[SCNCone coneWithTopRadius:0 bottomRadius:0.18 height:1]];
      flameNode.geometry.materials = @[ flame ];
      flameNode.position = V(x.doubleValue, 0, -1.8);
      flameNode.eulerAngles = SCNVector3Make(-M_PI / 2, 0, 0);
      flameNode.hidden = YES;
      [_flames addObject:flameNode];
    }

    // 车身静态部件 flatten：SceneKit 会把同材质的几何合并，把 ~50 个 draw call 压到 ~6 个（A7 必需）
    SCNNode *flattened = [_body flattenedClone];
    flattened.name = @"body";
    [_body removeFromParentNode];
    _body = flattened;
    [_root addChildNode:_body];
    [_body addChildNode:_antenna];
    for (SCNNode *flameNode in _flames) [_body addChildNode:flameNode];

    // 轮子同样 flatten（轮胎 + 8 个胎纹 + 轮毂 → 2 个 draw call）
    for (NSUInteger i = 0; i < _wheels.count; i++) {
      SCNNode *wheel = _wheels[i];
      SCNNode *mount = wheel.parentNode;
      SCNNode *flatWheel = [wheel flattenedClone];
      flatWheel.name = @"wheel";
      [wheel removeFromParentNode];
      [mount addChildNode:flatWheel];
      _wheels[i] = flatWheel;
    }
  }
  return self;
}

- (NSInteger)wheelCount { return (NSInteger)_wheels.count; }

- (void)setWheelVisible:(BOOL)visible {
  for (SCNNode *w in _wheels) w.hidden = !visible;
}

- (void)applyVisual:(PTKKartVisual)visual alpha:(CGFloat)alpha dt:(CGFloat)dt time:(CGFloat)time {
  if (dt <= 0) dt = 1.0 / 60.0;
  CGFloat a = MAX(0.0, MIN(1.0, alpha));
  _root.position = SCNVector3Make(visual.previousPosition.x + (visual.position.x - visual.previousPosition.x) * a,
                                  visual.previousPosition.y + (visual.position.y - visual.previousPosition.y) * a,
                                  visual.previousPosition.z + (visual.position.z - visual.previousPosition.z) * a);
  _root.eulerAngles = SCNVector3Make(0, visual.previousYaw + wrapAngle(visual.yaw - visual.previousYaw) * a, 0);

  // 车身俯仰（服务器不给地面法线：用速度变化近似落地点头）与侧倾（转向 + 赛道倾斜）
  CGFloat slope = visual.grounded ? 0 : MAX(-0.22, MIN(0.22, -visual.boost * 0.02));
  _bodyPitch = damp(_bodyPitch, slope, 10, dt);
  CGFloat roll = -visual.steering * MIN(fabs(visual.speed) / 30.0, 1.0) * (visual.drift ? 0.13 : 0.075) + visual.bank;
  _bodyRoll = damp(_bodyRoll, roll, 8, dt);
  _body.eulerAngles = SCNVector3Make(_bodyPitch, 0, _bodyRoll);
  _body.position = SCNVector3Make(0, sin(time * 22) * MIN(fabs(visual.speed) * 0.001, 0.025), 0);

  _wheelSpin += visual.speed * dt / 0.43;
  for (SCNNode *wheel in _wheels) wheel.eulerAngles = SCNVector3Make(_wheelSpin, 0, 0);
  for (SCNNode *mount in _frontMounts) mount.eulerAngles = SCNVector3Make(0, -visual.steering * 0.4, 0);
  _antenna.eulerAngles = SCNVector3Make(0, 0, sin(time * 13) * visual.speed * 0.0015);

  BOOL boosting = visual.boost > 0;
  for (SCNNode *flame in _flames) {
    flame.hidden = !boosting;
    if (boosting) flame.scale = SCNVector3Make(1, 0.8 + sin(time * 58) * 0.25, 1);
  }
  // 无敌期闪烁（与网页版一致）
  _root.hidden = visual.invulnerable > 0 && sin(time * 28) <= -0.6;
}

@end
