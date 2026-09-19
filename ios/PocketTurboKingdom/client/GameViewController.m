#import "GameViewController.h"
#import <SceneKit/SceneKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "PTKTrackData.h"
#import "PTKKartNode.h"
#import "PTKWorldBuilder.h"
#import "PTKWebSocket.h"
#import "PTKProtocol.h"
#import "PTKTouchControls.h"
#import "PTKHUDView.h"
#import "PTKLobbyView.h"
#import "PTKLog.h"

static CGFloat PTKDamp(CGFloat current, CGFloat target, CGFloat lambda, CGFloat dt) {
  return current + (target - current) * (1 - exp(-lambda * dt));
}

/// 每辆车的运行时状态：服务器字段 + 插值用的上一帧位姿
@interface PTKRuntimeKart : NSObject
@property (nonatomic, copy) NSString *playerId, *name;
@property (nonatomic, strong) PTKKartNode *node;
@property (nonatomic) SCNVector3 previousPosition, position;
@property (nonatomic) CGFloat previousYaw, yaw, speed, steering, boost, stun, invulnerable, bank;
@property (nonatomic) BOOL grounded, drift, finished, disconnected, initialized;
@property (nonatomic) NSInteger rank, lap, score, hitsTaken;
@property (nonatomic) CGFloat finishTime;
@property (nonatomic, copy) NSArray *slots;
@end

@implementation PTKRuntimeKart
@end

/// 自动驾驶输出（仅测试钩子使用）
@interface PTKTestDrive : NSObject
@property (nonatomic) double throttle, brake, steer;
@end

@implementation PTKTestDrive
@end

@interface PTKGameViewController () <PTKWebSocketDelegate, PTKLobbyViewDelegate>
@end

@implementation PTKGameViewController {
  SCNView *_scnView;
  SCNScene *_scene;
  SCNNode *_cameraNode, *_worldRoot;
  PTKTrackData *_trackData, *_arenaData;
  PTKTrackPath *_path;

  PTKLobbyView *_lobby;
  PTKHUDView *_hud;
  PTKTouchControls *_touch;

  NSMutableArray<PTKRuntimeKart *> *_karts;
  NSMutableArray<PTKItemBoxNode *> *_itemBoxes;
  NSMutableArray<PTKObstacleNode *> *_obstacles;
  NSMutableArray<PTKProjectileNode *> *_projectiles;

  PTKWebSocket *_socket;
  PTKRoom *_room;
  NSString *_you, *_host, *_playerName, *_joinedCode;
  NSInteger _kartIndex, _seq;

  CADisplayLink *_link;
  UILabel *_errorBanner;
  NSUInteger _frameErrors;
  BOOL _soloPending;
  BOOL _autoplay, _autoplayChecked, _autoplayDrive;
  NSUInteger _fpsFrames;
  double _lastFpsLog;
  double _time, _lastFrame, _snapshotAt, _lastInput, _lastHud, _lastPing;
  NSString *_phase;
  double _countdown, _goFlash, _rtt;
  CGFloat _cameraFov;
  BOOL _localFinished, _resultsShown, _worldIsArena;
}

#pragma mark - 生命周期

- (instancetype)init {
  if ((self = [super init])) {
    _karts = [NSMutableArray array];
    _itemBoxes = [NSMutableArray array];
    _obstacles = [NSMutableArray array];
    _projectiles = [NSMutableArray array];
    _phase = @"lobby";
    _kartIndex = 0;
    _cameraFov = 64;
    _seq = -1;
  }
  return self;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLoad {
  [super viewDidLoad];
  @try {
    [self setupEverything];
  } @catch (NSException *exception) {
    PTKLogException(exception, @"viewDidLoad");
    UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
    label.backgroundColor = [UIColor blackColor];
    label.textColor = [UIColor colorWithRed:1 green:0.5 blue:0.5 alpha:1];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.text = [NSString stringWithFormat:@"启动失败\n%@\n%@", exception.reason, PTKLogFilePath()];
    [self.view addSubview:label];
  }
}

- (void)setupEverything {
  PTKLog(@"启动: iOS %@, 屏幕 %.0fx%.0f", [UIDevice currentDevice].systemVersion,
         self.view.bounds.size.width, self.view.bounds.size.height);
  self.view.backgroundColor = [UIColor blackColor];

  _scene = [SCNScene scene];
  _scene.background.contents = PTKColor(0.70, 0.85, 0.84);
  _scene.fogColor = PTKColor(0.70, 0.85, 0.84);
  _scene.fogStartDistance = 110;
  _scene.fogEndDistance = 420;

  SCNNode *ambient = [SCNNode node];
  ambient.light = [SCNLight light];
  ambient.light.type = SCNLightTypeAmbient;
  ambient.light.color = PTKColor(0.66, 0.76, 0.74);
  ambient.light.intensity = 900;
  [_scene.rootNode addChildNode:ambient];

  SCNNode *sun = [SCNNode node];
  sun.light = [SCNLight light];
  sun.light.type = SCNLightTypeDirectional;
  sun.light.color = PTKColor(1.0, 0.93, 0.78);
  sun.light.intensity = 1000;
  sun.position = SCNVector3Make(30, 65, 20);
  [sun lookAt:SCNVector3Zero];
  [_scene.rootNode addChildNode:sun];

  _cameraNode = [SCNNode node];
  _cameraNode.camera = [SCNCamera camera];
  _cameraNode.camera.zNear = 0.3;
  _cameraNode.camera.zFar = 700;
  _cameraNode.camera.fieldOfView = 64;
  [_scene.rootNode addChildNode:_cameraNode];

  _worldRoot = [SCNNode node];
  [_scene.rootNode addChildNode:_worldRoot];

  _scnView = [[SCNView alloc] initWithFrame:self.view.bounds];
  _scnView.scene = _scene;
  _scnView.pointOfView = _cameraNode;
  _scnView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _scnView.preferredFramesPerSecond = 60;
  _scnView.antialiasingMode = SCNAntialiasingModeNone; // A7：优先帧率
  _scnView.rendersContinuously = YES;
  _scnView.backgroundColor = [UIColor blackColor];
  _scnView.autoenablesDefaultLighting = NO;
  _scnView.jitteringEnabled = NO;
  [self.view addSubview:_scnView];

  _hud = [[PTKHUDView alloc] initWithFrame:self.view.bounds];
  _hud.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _hud.hidden = YES;
  [self.view addSubview:_hud];
  __weak PTKGameViewController *weakSelf = self;
  _hud.onResultsButton = ^{ [weakSelf resultsButtonTapped]; };
  _hud.onExitButton = ^{ [weakSelf lobbyDidLeave]; };

  _touch = [[PTKTouchControls alloc] initWithFrame:self.view.bounds];
  _touch.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _touch.hidden = YES;
  [self.view insertSubview:_touch belowSubview:_hud];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clearDrivingInput)
      name:UIApplicationWillResignActiveNotification object:nil];

  _errorBanner = [[UILabel alloc] initWithFrame:CGRectZero];
  _errorBanner.backgroundColor = [UIColor colorWithRed:0.55 green:0.10 blue:0.10 alpha:0.92];
  _errorBanner.textColor = [UIColor whiteColor];
  _errorBanner.font = [UIFont systemFontOfSize:13];
  _errorBanner.numberOfLines = 3;
  _errorBanner.textAlignment = NSTextAlignmentCenter;
  _errorBanner.hidden = YES;
  _errorBanner.userInteractionEnabled = NO;
  [self.view addSubview:_errorBanner];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(logError:)
                                               name:PTKLogDidUpdateNotification object:nil];

  _lobby = [[PTKLobbyView alloc] initWithFrame:self.view.bounds];
  _lobby.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _lobby.delegate = self;
  [self.view addSubview:_lobby];

  // 冷启动看门狗（0x8badf00d）：A7 + 1GB 设备上，解析 4.7MB 几何 + SceneKit 首次编译着色器
  // 很容易超过 SpringBoard 给的 5 秒。这里先让窗口把第一帧渲出来，再推迟做重活。
  __weak PTKGameViewController *weakSelf2 = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    PTKGameViewController *strongSelf = weakSelf2;
    if (!strongSelf) return;
    [strongSelf loadAssets];
    [strongSelf setLobbyWorldArena:NO];
    [strongSelf updateLobbyCamera:0];
  });

  _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(frameTick:)];
  _link.preferredFramesPerSecond = 60;
  [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)clearDrivingInput {
  [_touch reset];
  if (_socket.isOpen) [_socket sendText:PTKInputMessage(++_seq, [_touch pollControls])];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [self clearDrivingInput];
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGRect area = self.view.safeAreaLayoutGuide.layoutFrame;
  _errorBanner.frame = CGRectMake(area.origin.x, area.origin.y, area.size.width, 56);
}

- (void)loadAssets {
  NSString *trackPath = [[NSBundle mainBundle] pathForResource:@"track" ofType:@"ptkgeo"];
  NSString *arenaPath = [[NSBundle mainBundle] pathForResource:@"arena" ofType:@"ptkgeo"];
  NSError *error = nil;
  if (trackPath) _trackData = [PTKTrackData dataWithContentsOfFile:trackPath error:&error];
  if (arenaPath) _arenaData = [PTKTrackData dataWithContentsOfFile:arenaPath error:&error];
  PTKLog(@"几何: track=%@ arena=%@ error=%@", trackPath ? @"有" : @"缺失", arenaPath ? @"有" : @"缺失", error.localizedDescription ?: @"无");
  if (_trackData) {
    _path = [[PTKTrackPath alloc] initWithTrackData:_trackData];
    _lobby.karts = _trackData.karts;
    NSArray<PTKKartSpec *> *karts = _trackData.karts;
    if (karts.count) {
      [_lobby prefillHost:[[NSUserDefaults standardUserDefaults] stringForKey:@"PTKHost"] ?: @"192.168.31.249"];
      [self showLobby:@"创建房间当主机，或输入 Mac 上显示的 6 位房间码加入。"];
    }
  } else {
    PTKLogError(@"找不到几何资源 assets/track.ptkgeo（打包时 assets 没拷进 .app）");
    [self showLobby:@"找不到几何资源 assets/track.ptkgeo，请重新打包安装。"];
  }
}

- (void)logError:(NSNotification *)notification {
  NSString *text = [notification.object isKindOfClass:NSString.class] ? notification.object : @"";
  _errorBanner.text = text;
  _errorBanner.hidden = NO;
  _errorBanner.frame = CGRectMake(0, 0, self.view.bounds.size.width, 56);
  [self.view bringSubviewToFront:_errorBanner];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    self->_errorBanner.hidden = YES;
  });
}

- (void)showLobby:(NSString *)status {
  _lobby.hidden = NO;
  _hud.hidden = YES;
  _touch.hidden = YES;
  [_lobby showEntryWithStatus:status];
}

#pragma mark - 场景装配

- (void)setLobbyWorldArena:(BOOL)arena {
  PTKTrackData *data = arena ? _arenaData : _trackData;
  if (!data) return;
  [self rebuildStaticWorld:data];
  [self buildItemBoxes:data];
  [self buildObstacles:data];
}

- (void)rebuildStaticWorld:(PTKTrackData *)data {
  [_worldRoot.childNodes makeObjectsPerformSelector:@selector(removeFromParentNode)];
  [_worldRoot addChildNode:[data buildStaticScene]];
}

- (void)buildItemBoxes:(PTKTrackData *)data {
  for (PTKItemBoxNode *box in _itemBoxes) [box.node removeFromParentNode];
  [_itemBoxes removeAllObjects];
  for (PTKAnchor *anchor in data.boxes) {
    PTKItemBoxNode *box = [[PTKItemBoxNode alloc] initWithPosition:anchor.position];
    [_worldRoot addChildNode:box.node];
    [_itemBoxes addObject:box];
  }
}

- (void)buildObstacles:(PTKTrackData *)data {
  for (PTKObstacleNode *obstacle in _obstacles) [obstacle.node removeFromParentNode];
  [_obstacles removeAllObjects];
  for (PTKAnchor *anchor in data.obstacles) {
    PTKObstacleNode *obstacle = [[PTKObstacleNode alloc] initWithAnchor:anchor];
    [_worldRoot addChildNode:obstacle.node];
    [_obstacles addObject:obstacle];
  }
}

/// 开赛：按房间玩家重建赛车（顺序与服务器 ServerRace 一致，索引即服务器 kart 下标）
- (void)prepareRaceWithRoom:(PTKRoom *)room {
  BOOL arena = [room.mode isEqualToString:@"arena"];
  PTKTrackData *data = arena ? _arenaData : _trackData;
  if (!data) return;
  [self rebuildStaticWorld:data];
  [self buildItemBoxes:data];
  [self buildObstacles:data];
  _path = [[PTKTrackPath alloc] initWithTrackData:data];
  _worldIsArena = arena;

  for (PTKRuntimeKart *kart in _karts) [kart.node.root removeFromParentNode];
  [_karts removeAllObjects];
  for (PTKProjectileNode *projectile in _projectiles) [projectile.node removeFromParentNode];
  [_projectiles removeAllObjects];

  for (NSUInteger i = 0; i < room.players.count && i < 4; i++) {
    PTKPlayer *player = room.players[i];
    NSInteger specIndex = MAX(0, MIN((NSInteger)data.karts.count - 1, player.kart));
    PTKKartSpec *spec = data.karts[specIndex];
    PTKRuntimeKart *kart = [PTKRuntimeKart new];
    kart.playerId = player.playerId;
    kart.name = player.name;
    kart.node = [PTKKartNode kartWithSpec:spec ghost:NO];
    kart.rank = (NSInteger)i + 1;
    [_worldRoot addChildNode:kart.node.root];
    [_karts addObject:kart];
    if ([player.playerId isEqualToString:_you]) _kartIndex = (NSInteger)i;
  }
  for (int i = 0; i < 36; i++) {
    PTKProjectileNode *projectile = [[PTKWorldBuilder shared] nextProjectile];
    if (projectile.node.parentNode == nil) [_worldRoot addChildNode:projectile.node];
    projectile.node.hidden = YES;
    [_projectiles addObject:projectile];
  }
  _localFinished = NO;
  _resultsShown = NO;
  [_hud hideResults];
  [_touch reset];
  _hud.hidden = NO;
  _touch.hidden = NO;
  _lobby.hidden = YES;
  [_hud showToast:arena ? @"星火竞技场 · 道具命中对手 +1 分" : @"发条蘑菇山谷 · 3 圈竞速"];
}

#pragma mark - 帧循环

- (void)frameTick:(CADisplayLink *)link {
  @try {
    [self frameTickInner:link];
  } @catch (NSException *exception) {
    if (_frameErrors++ < 3) PTKLogException(exception, @"frameTick");
  }
}

/// 远程抓屏：SSH 里 touch /tmp/ptk-capture 就会把当前画面存到应用容器的 tmp/ptk-screen.png。
/// iPad 上接不了调试器，这是排查画面问题的唯一手段。
- (void)checkCaptureRequest {
  static double lastCheck = 0;
  double nowTime = CACurrentMediaTime();
  if (nowTime - lastCheck < 1.0) return;
  lastCheck = nowTime;
  if (![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/ptk-capture"]) return;
  UIImage *image = [self captureScreen];
  NSData *png = UIImagePNGRepresentation(image);
  if (!png) { PTKLogError(@"抓屏失败：snapshot 返回空"); return; }
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ptk-screen.png"];
  [png writeToFile:path atomically:YES];
  PTKLog(@"已抓屏 %@ (%.0f KB, %.0fx%.0f)", path, png.length / 1024.0, image.size.width, image.size.height);
}

/// 合成截图：SCNView.snapshot 只含 3D；UI 层单独叠上去。
/// 注意两点坑：不能 drawViewHierarchy 整个 window（会把不透明黑底盖在 3D 上），
/// 也不能用 afterScreenUpdates:YES（会强制刷新把 Metal drawable 清成黑帧）。
- (UIImage *)captureScreen {
  CGRect bounds = self.view.bounds;
  CGFloat scale = [UIScreen mainScreen].scale;
  UIImage *scene = [_scnView snapshot];
  UIGraphicsBeginImageContextWithOptions(bounds.size, NO, scale);
  if (scene) [scene drawInRect:bounds];
  for (UIView *overlay in @[ _lobby, _hud, _touch, _errorBanner ]) {
    if (!overlay || overlay.hidden || overlay.alpha < 0.01) continue;
    [overlay drawViewHierarchyInRect:overlay.bounds afterScreenUpdates:NO];
  }
  UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return image ?: scene;
}

/// 自动联机的转向输出（纯追踪：找最近的赛道采样点，再瞄前方第 3 个采样点）
- (PTKTestDrive *)autopilotControls {
  PTKTestDrive *drive = [PTKTestDrive new];
  drive.throttle = 1;
  if (_kartIndex >= (NSInteger)_karts.count || _path.points.count < 8) return drive;
  PTKRuntimeKart *kart = _karts[_kartIndex];
  CGFloat x = kart.position.x, z = kart.position.z;
  NSUInteger best = 0;
  CGFloat bestDistance = INFINITY;
  for (NSUInteger i = 0; i < _path.points.count; i++) {
    PTKTrackSample *p = _path.points[i];
    CGFloat d = (p.position.x - x) * (p.position.x - x) + (p.position.z - z) * (p.position.z - z);
    if (d < bestDistance) { bestDistance = d; best = i; }
  }
  PTKTrackSample *target = _path.points[(best + 3) % _path.points.count];
  CGFloat desired = atan2(target.position.x - x, target.position.z - z);
  CGFloat delta = atan2(sin(desired - kart.yaw), cos(desired - kart.yaw));
  drive.steer = MAX(-1.0, MIN(1.0, delta * 2.2));
  if (fabs(delta) > 1.0) drive.throttle = 0.35;       // 角度太大先减速，别直接撞护栏
  if (kart.speed < 0) { drive.throttle = 0; drive.brake = 0.4; }
  return drive;
}

/// 自动联机测试钩子（默认关闭，防止误触发）：
///   SSH 写入 /tmp/ptk-autoplay，内容必须严格以 "PTK-AUTOTEST|" 开头：
///     PTK-AUTOTEST||iPad车手|1         ← 空房间码 = 单人(对战电脑)；只自动进房/准备/发车
///     PTK-AUTOTEST||iPad车手|1|drive   ← 末尾加 drive 才会自动驾驶
/// 没有这个前缀的文件一律忽略。教训：早先只要文件存在就自动开跑，残留的触发器会让
/// 用户一打开应用就看到赛车自己乱撞，所以必须是显式声明。
- (void)checkAutoplay {
  if (_autoplayChecked) return;
  NSString *config = [NSString stringWithContentsOfFile:@"/tmp/ptk-autoplay" encoding:NSUTF8StringEncoding error:NULL];
  config = [config stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  static NSString *const kMarker = @"PTK-AUTOTEST|";
  if (![config hasPrefix:kMarker]) return;
  _autoplayChecked = YES;
  _autoplay = YES;
  NSArray<NSString *> *parts = [[config substringFromIndex:kMarker.length] componentsSeparatedByString:@"|"];
  NSString *code = parts.count > 0 ? parts[0] : @"";
  NSString *name = (parts.count > 1 && parts[1].length) ? parts[1] : @"iPad车手";
  NSInteger kart = parts.count > 2 ? parts[2].integerValue : 0;
  _autoplayDrive = parts.count > 3 && [parts[3] isEqualToString:@"drive"];
  NSString *host = _lobby.serverHost;
  PTKLog(@"自动联机测试钩子生效: host=%@ code=%@ name=%@ kart=%ld 自动驾驶=%@",
         host, code.length ? code : @"(单人)", name, (long)kart, _autoplayDrive ? @"开" : @"关");
  if (code.length) {
    [self connectToHost:host code:code name:name kart:kart];
  } else {
    [self lobbyDidPlaySoloWithName:name kart:kart host:host];
  }
}

- (void)frameTickInner:(CADisplayLink *)link {
  _fpsFrames++;
  [self checkCaptureRequest];
  double now = link.timestamp;
  double dt = _lastFrame > 0 ? MIN(0.1, now - _lastFrame) : 1.0 / 60.0;
  _lastFrame = now;
  _time += dt;

  if (!_autoplayChecked && _trackData) [self checkAutoplay];
  if (now - _lastFpsLog > 5.0) {
    _lastFpsLog = now;
    NSString *local = @"-";
    if (_kartIndex < (NSInteger)_karts.count && _karts.count) {
      PTKRuntimeKart *me = _karts[_kartIndex];
      local = [NSString stringWithFormat:@"本车 %ld名 %ld圈 %.1fm/s", (long)me.rank, (long)me.lap, me.speed];
    }
    PTKLog(@"fps=%.0f karts=%lu phase=%@ 房间=%@ %@", _fpsFrames / 5.0, (unsigned long)_karts.count,
           _phase, _room.code ?: @"-", local);
    _fpsFrames = 0;
  }
  if (_karts.count == 0) {
    [self updateLobbyCamera:dt];
    return;
  }

  CGFloat alpha = MIN(1.0, (CGFloat)((now - _snapshotAt) / 0.05));
  for (PTKRuntimeKart *kart in _karts) {
    PTKKartVisual visual;
    visual.previousPosition = kart.previousPosition;
    visual.position = kart.position;
    visual.previousYaw = kart.previousYaw;
    visual.yaw = kart.yaw;
    visual.speed = kart.speed;
    visual.steering = kart.steering;
    visual.boost = kart.boost;
    visual.invulnerable = kart.invulnerable;
    visual.bank = kart.bank;
    visual.grounded = kart.grounded;
    visual.drift = kart.drift;
    visual.airborne = !kart.grounded;
    [kart.node applyVisual:visual alpha:alpha dt:dt time:_time];
  }
  [self updateChaseCamera:dt];
  for (PTKItemBoxNode *box in _itemBoxes) [box updateTime:_time];
  for (PTKObstacleNode *obstacle in _obstacles) [obstacle updateTime:_time dt:dt];

  // 输入与心跳
  if (now - _lastInput > 1.0 / 30.0 && _socket.isOpen) {
    _lastInput = now;
    _seq++;
    PTKControls *controls = [_touch pollControls];
    if (_autoplayDrive) {  // 只有显式写了 drive 才自动驾驶（沿赛道采样点纯追踪）
      PTKTestDrive *drive = [self autopilotControls];
      controls.throttle = drive.throttle;
      controls.brake = drive.brake;
      controls.steer = drive.steer;
    }
    [_socket sendText:PTKInputMessage(_seq, controls)];
  }
  if (now - _lastPing > 2.0 && _socket.isOpen) {
    _lastPing = now;
    [_socket sendText:PTKPingMessage(_time * 1000.0)];
  }
  if (now - _lastHud > 0.1) {
    _lastHud = now;
    [self updateHUD];
  }
}

- (void)updateHUD {
  if (_kartIndex >= (NSInteger)_karts.count) return;
  PTKRuntimeKart *local = _karts[_kartIndex];
  [_hud setLap:local.lap total:3 rank:local.rank players:(NSInteger)_karts.count
          speed:local.speed score:local.score arena:_worldIsArena finished:local.finished];
  [_hud setSlots:local.slots ?: @[]];
  [_hud setCountdown:_countdown goFlash:_goFlash];
  NSString *badge = _room ? [NSString stringWithFormat:@"房间 %@ · %@ · %.0f ms", _room.code, local.name, _rtt] : @"";
  [_hud setBadge:badge];
}

- (void)updateChaseCamera:(double)dt {
  if (_kartIndex >= (NSInteger)_karts.count) return;
  PTKRuntimeKart *kart = _karts[_kartIndex];
  CGFloat alpha = MIN(1.0, (CGFloat)((_lastFrame - _snapshotAt) / 0.05));
  SCNVector3 position = SCNVector3Make(kart.previousPosition.x + (kart.position.x - kart.previousPosition.x) * alpha,
                                       kart.previousPosition.y + (kart.position.y - kart.previousPosition.y) * alpha,
                                       kart.previousPosition.z + (kart.position.z - kart.previousPosition.z) * alpha);
  CGFloat yaw = kart.previousYaw + atan2(sin(kart.yaw - kart.previousYaw), cos(kart.yaw - kart.previousYaw)) * alpha;
  SCNVector3 forward = SCNVector3Make(sin(yaw), 0, cos(yaw));
  SCNVector3 target = SCNVector3Make(position.x - forward.x * 9.6, position.y + 3.5, position.z - forward.z * 9.6);
  SCNVector3 look = SCNVector3Make(position.x + forward.x * 13.0, position.y + 1.3, position.z + forward.z * 13.0);
  CGFloat smooth = 1 - exp(-9.0 * dt);
  _cameraNode.position = SCNVector3Make(_cameraNode.position.x + (target.x - _cameraNode.position.x) * smooth,
                                        _cameraNode.position.y + (target.y - _cameraNode.position.y) * smooth,
                                        _cameraNode.position.z + (target.z - _cameraNode.position.z) * smooth);
  // 必须用三参数版本：单参数 lookAt: 以「节点当前的 worldUp」为参考，
  // 每帧调用会把上一帧的微小倾斜累积成滚转，表现就是地平线越来越歪、一直在变。
  [_cameraNode lookAt:look up:SCNVector3Make(0, 1, 0) localFront:SCNVector3Make(0, 0, -1)];
  CGFloat fov = 64 + MIN(16, fabs(kart.speed) * 0.42);
  _cameraFov = PTKDamp(_cameraFov, fov, 4, dt);
  _cameraNode.camera.fieldOfView = _cameraFov;
}

- (void)updateLobbyCamera:(double)dt {
  PTKTrackData *data = _trackData;
  if (!data || !data.start) return;
  SCNVector3 focus = data.start.position;
  CGFloat yaw = data.start.yaw + _time * 0.12;
  SCNVector3 forward = SCNVector3Make(sin(yaw), 0, cos(yaw));
  _cameraNode.position = SCNVector3Make(focus.x - forward.x * 14, focus.y + 6.2, focus.z - forward.z * 14);
  _cameraNode.camera.fieldOfView = 58;
  [_cameraNode lookAt:SCNVector3Make(focus.x, focus.y + 1.2, focus.z)
                     up:SCNVector3Make(0, 1, 0) localFront:SCNVector3Make(0, 0, -1)];
}

#pragma mark - 大厅

- (void)lobbyDidPlaySoloWithName:(NSString *)name kart:(NSInteger)kart host:(NSString *)host {
  [self lobbyDidCreateRoomWithName:name kart:kart host:host];
  _soloPending = YES;
}

- (void)lobbyDidCreateRoomWithName:(NSString *)name kart:(NSInteger)kart host:(NSString *)host {
  _playerName = name;
  _kartIndex = kart;
  [self connectToHost:host code:@"" name:name kart:kart];
}

- (void)lobbyDidJoinCode:(NSString *)code name:(NSString *)name kart:(NSInteger)kart host:(NSString *)host {
  _playerName = name;
  [self connectToHost:host code:code name:name kart:kart];
}

- (void)connectToHost:(NSString *)host code:(NSString *)code name:(NSString *)name kart:(NSInteger)kart {
  _soloPending = NO;
  [_socket close];
  _host = host;
  _joinedCode = code;
  [[NSUserDefaults standardUserDefaults] setObject:host forKey:@"PTKHost"];
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"ws://%@/lan", host]];
  if (!url) { [_lobby setStatus:@"主机地址无效"]; return; }
  [_lobby setBusy:YES];
  [_lobby setStatus:[NSString stringWithFormat:@"正在连接 %@ …", host]];
  _socket = [[PTKWebSocket alloc] initWithURL:url delegate:self];
  [_socket open];
  PTKLog(@"连接主机 %@ (房间码 %@)", host, code.length ? code : @"新建");
}

- (void)lobbyDidToggleReady:(BOOL)ready { [_socket sendText:PTKReadyMessage(ready)]; }
- (void)lobbyDidStart { [_socket sendText:PTKStartMessage()]; }
- (void)lobbyDidChangeMode:(NSString *)mode { [_socket sendText:PTKModeMessage(mode)]; }
- (void)lobbyDidRematch { [_socket sendText:PTKRematchMessage()]; }

- (void)lobbyDidLeave {
  _soloPending = NO;
  [_socket close];
  _socket = nil;
  _room = nil;
  for (PTKRuntimeKart *kart in _karts) [kart.node.root removeFromParentNode];
  [_karts removeAllObjects];
  for (PTKProjectileNode *projectile in _projectiles) [projectile.node removeFromParentNode];
  [_projectiles removeAllObjects];
  [_hud hideResults];
  [self setLobbyWorldArena:NO];
  [self showLobby:@"已离开房间。"];
}

- (void)resultsButtonTapped {
  if (_room && [_room.host isEqualToString:_you]) {
    [_socket sendText:PTKRematchMessage()];
  } else {
    [_hud showToast:@"等待房主开启下一场"];
  }
}

#pragma mark - WebSocket

- (void)webSocketDidOpen:(PTKWebSocket *)ws {
  [_lobby setBusy:NO];
  [_lobby setStatus:@"已连接，正在进入房间…"];
  [ws sendText:PTKJoinMessage(_joinedCode ?: @"", _playerName ?: @"口袋车手", _kartIndex)];
}

- (void)webSocket:(PTKWebSocket *)ws didReceiveText:(NSString *)text {
  PTKServerMessage *message = [PTKServerMessage messageFromJSON:text];
  if ([message.type isEqualToString:@"room"]) {
    _room = message.room;
    _you = message.you;
    PTKLog(@"收到房间 %@ phase=%@ 玩家 %lu", _room.code, _room.phase, (unsigned long)_room.players.count);
    if ([_room.phase isEqualToString:@"lobby"]) {
      NSString *address = message.urls.count ? message.urls.firstObject : @"";
      [_lobby showRoom:_room you:_you address:address];
      if (_soloPending) {
        _soloPending = NO;
        [ws sendText:PTKStartMessage()];
      }
      if (_autoplay) {
        BOOL isHost = [_room.host isEqualToString:_you];
        PTKPlayer *me = nil;
        BOOL allReady = YES;
        for (PTKPlayer *player in _room.players) {
          if ([player.playerId isEqualToString:_you]) me = player;
          if (!player.ready) allReady = NO;
        }
        if (me && !me.ready) [ws sendText:PTKReadyMessage(YES)];
        if (isHost && allReady) {  // 1 人时服务器会补 3 个电脑车手
          PTKLog(@"自动发车（%lu 人已全部准备）", (unsigned long)_room.players.count);
          [ws sendText:PTKStartMessage()];
        }
      }
      if (_karts.count) {
        for (PTKRuntimeKart *kart in _karts) [kart.node.root removeFromParentNode];
        [_karts removeAllObjects];
        [_hud hideResults];
        _hud.hidden = YES;
        _touch.hidden = YES;
        _lobby.hidden = NO;
        [self setLobbyWorldArena:[_room.mode isEqualToString:@"arena"]];
      }
    } else {
      if (_karts.count == 0 || _worldIsArena != [_room.mode isEqualToString:@"arena"]) [self prepareRaceWithRoom:_room];
    }
    return;
  }
  if ([message.type isEqualToString:@"snapshot"]) {
    if (_karts.count == 0 && _room) [self prepareRaceWithRoom:_room];
    [self applySnapshot:message.snapshot];
    return;
  }
  if ([message.type isEqualToString:@"pong"]) {
    _rtt = _time * 1000.0 - message.pongTime;
    return;
  }
  if ([message.type isEqualToString:@"error"]) {
    _soloPending = NO;
    [_lobby setStatus:message.errorMessage];
    [_hud showToast:message.errorMessage];
  }
}

- (void)webSocket:(PTKWebSocket *)ws didCloseWithCode:(NSInteger)code reason:(NSString *)reason {
  if (_room == nil) [_lobby setStatus:[NSString stringWithFormat:@"连接已关闭（%ld %@）", (long)code, reason ?: @""]];
  else [_hud showToast:@"与主机的连接已断开"];
  [_lobby setBusy:NO];
}

- (void)webSocket:(PTKWebSocket *)ws didFailWithError:(NSError *)error {
  PTKLogError(@"WebSocket 失败: %@", error.localizedDescription);
  [_lobby setBusy:NO];
  [_lobby setStatus:[NSString stringWithFormat:@"连接失败：%@（确认 Mac 上已运行 npm run lan，且在同一 Wi-Fi）", error.localizedDescription]];
  [_hud showToast:@"连接失败"];
}

#pragma mark - 快照插值

- (void)applySnapshot:(PTKSnapshot *)snapshot {
  if (!snapshot) return;
  _snapshotAt = CACurrentMediaTime();
  _phase = snapshot.phase;
  _countdown = snapshot.countdown;
  _goFlash = snapshot.goFlash;

  for (PTKKartState *state in snapshot.karts) {
    NSInteger index = -1;
    for (NSUInteger i = 0; i < _karts.count; i++) {
      if ([_karts[i].playerId isEqualToString:state.kartId]) { index = (NSInteger)i; break; }
    }
    if (index < 0) continue;
    PTKRuntimeKart *kart = _karts[index];
    // 首帧不做插值：否则赛车会从原点飞向起跑位
    kart.previousPosition = kart.initialized ? kart.position : SCNVector3Make(state.px, state.py, state.pz);
    kart.previousYaw = kart.initialized ? kart.yaw : state.yaw;
    kart.initialized = YES;
    kart.position = SCNVector3Make(state.px, state.py, state.pz);
    kart.yaw = state.yaw;
    kart.speed = state.speed;
    kart.steering = state.steering;
    kart.boost = state.boost;
    kart.stun = state.stun;
    kart.invulnerable = state.invulnerable;
    kart.grounded = state.grounded;
    kart.drift = state.drift;
    kart.finished = state.finished;
    kart.disconnected = state.disconnected;
    kart.rank = state.rank;
    kart.lap = state.lap;
    kart.score = state.score;
    kart.hitsTaken = state.hitsTaken;
    kart.finishTime = state.finishTime;
    kart.slots = state.slots;
    if (_path) {
      PTKTrackSample *sample = [_path nearest:kart.position];
      kart.bank = sample ? sample.bank : 0;
    }
  }

  for (NSUInteger i = 0; i < _itemBoxes.count; i++) {
    BOOL available = i < snapshot.boxes.count ? snapshot.boxes[i].doubleValue <= 0.001 : YES;
    [_itemBoxes[i] setAvailable:available];
  }

  for (PTKProjectileNode *projectile in _projectiles) projectile.node.hidden = YES;
  for (PTKItemState *item in snapshot.items) {
    if (item.index < 0 || item.index >= (NSInteger)_projectiles.count) continue;
    PTKProjectileNode *projectile = _projectiles[item.index];
    [projectile setKind:item.kind];
    projectile.node.position = SCNVector3Make(item.px, item.py, item.pz);
    projectile.node.eulerAngles = SCNVector3Make(0, _time * 7, [item.kind isEqualToString:@"gear"] ? M_PI / 2 : 0);
  }

  if ([snapshot.phase isEqualToString:@"results"] && !_resultsShown) {
    _resultsShown = YES;
    [self showResults];
  }
}

- (void)showResults {
  NSMutableArray<PTKRuntimeKart *> *sorted = [_karts mutableCopy];
  [sorted sortUsingComparator:^NSComparisonResult(PTKRuntimeKart *a, PTKRuntimeKart *b) {
    if (a.rank == b.rank) return NSOrderedSame;
    return a.rank < b.rank ? NSOrderedAscending : NSOrderedDescending;
  }];
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (PTKRuntimeKart *kart in sorted) {
    NSString *detail = _worldIsArena
        ? [NSString stringWithFormat:@"%ld 分 · 被击中 %ld 次", (long)kart.score, (long)kart.hitsTaken]
        : (kart.finished ? [NSString stringWithFormat:@"%.3f 秒", kart.finishTime] : @"未完赛");
    [lines addObject:[NSString stringWithFormat:@"%ld. %@  %@", (long)kart.rank, kart.name, detail]];
  }
  BOOL isHost = _room && [_room.host isEqualToString:_you];
  [_hud showResultsWithTitle:(_worldIsArena ? @"道具乱斗 · 最终排名" : @"竞速 · 最终排名")
                       lines:lines
                      button:(isHost ? @"再来一场" : @"等待房主开启下一场")];
  _touch.hidden = YES;
}

@end
