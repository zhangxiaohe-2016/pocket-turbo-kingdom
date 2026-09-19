#import "AppDelegate.h"
#import "GameViewController.h"

@implementation PTKAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.window.rootViewController = [[PTKGameViewController alloc] init];
  self.window.backgroundColor = [UIColor blackColor];
  [self.window makeKeyAndVisible];
  application.idleTimerDisabled = YES; // 玩的时候别锁屏
  return YES;
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
  return UIInterfaceOrientationMaskLandscape;
}

@end
