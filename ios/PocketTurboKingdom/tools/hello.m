// tools/hello.m — Pocket Turbo Kingdom 远程编译/打包/安装链路的验证 App（最小 UIKit 程序）
//
// 目的：一次性证明「编译 → ldid → dpkg-deb → Sileo 安装 → 启动 → bundle 资源路径」整条链路可用。
// 屏幕上会显示：
//   * iOS 系统版本 + 机型（证明真的在设备上跑起来了）
//   * [[NSBundle mainBundle] pathForResource:@"track" ofType:@"ptkgeo"] 是否存在、路径、大小
//   * bundle 里所有 .ptkgeo 资源列表（证明 assets/*.ptkgeo 被拷进了 .app 根目录）
//
// 编译（在构建机上由 build.sh 完成）：
//   PTK_ENTRY=tools/hello.m PTK_SOURCES=tools/hello.m \
//     APP_NAME=PocketTurboHello APP_BUNDLE_ID=com.zhangzhangco.ptkhello ./build.sh
#import <UIKit/UIKit.h>
#import <sys/utsname.h>

#pragma mark - 视图控制器

@interface PTKHelloViewController : UIViewController
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *sectionLabel;
@property (nonatomic, strong) UILabel *trackLabel;
@property (nonatomic, strong) UILabel *arenaLabel;
@property (nonatomic, strong) UILabel *listLabel;
@property (nonatomic, strong) UILabel *footerLabel;
@end

@implementation PTKHelloViewController

- (BOOL)prefersStatusBarHidden { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskLandscape;      // 只允许横屏，和 Info.plist 一致
}

- (BOOL)shouldAutorotate { return YES; }

#pragma mark 文本

static NSString *MachineModel(void) {
  struct utsname u;
  if (uname(&u) != 0) { return @"unknown"; }
  return [NSString stringWithUTF8String:u.machine];   // 例如 iPad4,4
}

static UIFont *MonoFont(CGFloat size) {
  UIFont *font = [UIFont fontWithName:@"Menlo" size:size];
  return font != nil ? font : [UIFont systemFontOfSize:size];
}

static NSString *DescribeResource(NSString *name, NSString *type, BOOL *found) {
  NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:type];
  if (path == nil) {
    if (found) { *found = NO; }
    return [NSString stringWithFormat:@"%@.%@  ✗ MISSING\n(pathForResource 返回 nil)", name, type];
  }
  if (found) { *found = YES; }
  NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
  unsigned long long size = [attrs fileSize];
  // 真的读一遍，确认不是只有路径存在
  NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
  return [NSString stringWithFormat:@"%@.%@  ✓ FOUND  (%llu bytes, 读到 %lu bytes)\n%@",
                                    name, type, size, (unsigned long)data.length, path];
}

#pragma mark 生命周期

- (void)loadView {
  UIView *root = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
  root.backgroundColor = [UIColor blackColor];
  self.view = root;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  self.titleLabel = [self makeLabelWithText:@"POCKET TURBO KINGDOM"
                                       font:[UIFont systemFontOfSize:56 weight:UIFontWeightHeavy]
                                      color:[UIColor colorWithRed:1.00 green:0.82 blue:0.12 alpha:1.0]];
  self.versionLabel = [self makeLabelWithText:@""
                                         font:[UIFont systemFontOfSize:26 weight:UIFontWeightMedium]
                                        color:[UIColor colorWithWhite:0.85 alpha:1.0]];
  self.sectionLabel = [self makeLabelWithText:@"BUNDLE RESOURCE CHECK"
                                         font:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]
                                        color:[UIColor colorWithRed:0.24 green:0.85 blue:0.85 alpha:1.0]];
  self.trackLabel = [self makeLabelWithText:@""
                                       font:MonoFont(15)
                                      color:[UIColor whiteColor]];
  self.arenaLabel = [self makeLabelWithText:@""
                                       font:MonoFont(15)
                                      color:[UIColor whiteColor]];
  self.listLabel = [self makeLabelWithText:@""
                                      font:MonoFont(13)
                                     color:[UIColor colorWithWhite:0.6 alpha:1.0]];
  self.footerLabel = [self makeLabelWithText:@""
                                        font:[UIFont systemFontOfSize:14 weight:UIFontWeightRegular]
                                       color:[UIColor colorWithWhite:0.45 alpha:1.0]];

  NSString *systemVersion = [[UIDevice currentDevice] systemVersion];
  NSString *systemName = [[UIDevice currentDevice] systemName];
  self.versionLabel.text = [NSString stringWithFormat:@"%@ %@  ·  %@  ·  build chain OK",
                                                      systemName, systemVersion, MachineModel()];

  BOOL trackFound = NO, arenaFound = NO;
  self.trackLabel.text = DescribeResource(@"track", @"ptkgeo", &trackFound);
  self.arenaLabel.text = DescribeResource(@"arena", @"ptkgeo", &arenaFound);
  self.trackLabel.textColor = trackFound ? [UIColor colorWithRed:0.30 green:0.90 blue:0.45 alpha:1.0]
                                         : [UIColor colorWithRed:1.00 green:0.35 blue:0.35 alpha:1.0];
  self.arenaLabel.textColor = arenaFound ? [UIColor colorWithRed:0.30 green:0.90 blue:0.45 alpha:1.0]
                                         : [UIColor colorWithRed:1.00 green:0.35 blue:0.35 alpha:1.0];

  NSArray<NSString *> *geos = [[NSBundle mainBundle] pathsForResourcesOfType:@"ptkgeo" inDirectory:nil];
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (NSString *p in geos) { [names addObject:[p lastPathComponent]]; }
  self.listLabel.text = [NSString stringWithFormat:@"bundle 内 .ptkgeo 共 %lu 个: %@\nresourcePath: %@",
                                                   (unsigned long)geos.count,
                                                   names.count ? [names componentsJoinedByString:@", "] : @"(无)",
                                                   [[NSBundle mainBundle] resourcePath]];

  NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
  self.footerLabel.text = [NSString stringWithFormat:@"%@ v%@  ·  %@  ·  built by ios/PocketTurboKingdom/build.sh",
                                                     info[@"CFBundleName"],
                                                     info[@"CFBundleShortVersionString"],
                                                     info[@"CFBundleIdentifier"]];
}

- (UILabel *)makeLabelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
  UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
  label.text = text;
  label.font = font;
  label.textColor = color;
  label.numberOfLines = 0;
  label.textAlignment = NSTextAlignmentCenter;
  label.lineBreakMode = NSLineBreakByCharWrapping;
  [self.view addSubview:label];
  return label;
}

#pragma mark 布局（手写 frame，避免 Auto Layout 在 iOS 12 上的额外变量）

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGFloat w = self.view.bounds.size.width;
  CGFloat h = self.view.bounds.size.height;
  CGFloat pad = w * 0.05;

  NSArray<UILabel *> *labels = @[ self.titleLabel, self.versionLabel, self.sectionLabel,
                                  self.trackLabel, self.arenaLabel, self.listLabel, self.footerLabel ];
  NSMutableArray<NSNumber *> *heights = [NSMutableArray array];
  CGFloat total = 0;
  for (UILabel *label in labels) {
    CGFloat lh = [label sizeThatFits:CGSizeMake(w - pad * 2, CGFLOAT_MAX)].height;
    [heights addObject:@(lh)];
    total += lh;
  }
  CGFloat spacing = 10;
  total += spacing * (CGFloat)(labels.count - 1);

  CGFloat y = MAX(pad * 0.5, (h - total) / 2.0);
  for (NSUInteger i = 0; i < labels.count; i++) {
    CGFloat lh = [heights[i] doubleValue];
    labels[i].frame = CGRectMake(pad, y, w - pad * 2, lh);
    y += lh + spacing;
  }
}

@end

#pragma mark - AppDelegate

@interface PTKHelloAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation PTKHelloAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.window.rootViewController = [[PTKHelloViewController alloc] init];
  self.window.backgroundColor = [UIColor blackColor];
  [self.window makeKeyAndVisible];
  NSLog(@"[PTKHello] launched on %@ %@ (%@) — bundle=%@",
        [[UIDevice currentDevice] systemName],
        [[UIDevice currentDevice] systemVersion],
        MachineModel(),
        [[NSBundle mainBundle] bundlePath]);
  return YES;
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([PTKHelloAppDelegate class]));
  }
}
