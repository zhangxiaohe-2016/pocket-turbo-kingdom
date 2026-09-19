// UIKit regression harness; run with run_ui_tests.sh on the Xcode build Mac.
#import <UIKit/UIKit.h>
#import "PTKTouchControls.h"
#import "PTKHUDView.h"
#import "PTKLobbyView.h"
@interface PTKTouchControls (Testing)
- (void)updateStick:(CGPoint)point;
@end
static void Check(BOOL ok, NSString *message) {
  if (!ok) [NSException raise:@"UIRegression" format:@"%@", message];
}
static void Capture(UIView *view, NSString *path) {
  UIGraphicsBeginImageContextWithOptions(view.bounds.size, YES, 1);
  [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
  [UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()) writeToFile:path atomically:YES];
  UIGraphicsEndImageContext();
}
@interface TestApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation TestApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [UIViewController new];
  [self.window makeKeyAndVisible];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    @try {
      for (NSValue *value in @[ [NSValue valueWithCGSize:CGSizeMake(1024,768)],
                               [NSValue valueWithCGSize:CGSizeMake(1133,744)],
                               [NSValue valueWithCGSize:CGSizeMake(1366,1024)] ]) {
        CGSize size = value.CGSizeValue;
        UIView *stage = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, size}];
        stage.backgroundColor = [UIColor darkGrayColor];
        [self.window.rootViewController.view addSubview:stage];
        PTKTouchControls *touch = [[PTKTouchControls alloc] initWithFrame:stage.bounds];
        PTKHUDView *hud = [[PTKHUDView alloc] initWithFrame:stage.bounds];
        [stage addSubview:touch]; [stage addSubview:hud];
        [hud setLap:1 total:3 rank:2 players:4 speed:20 score:3 arena:YES finished:NO];
        [hud setSlots:@[@"firefly", @"battery"]];
        [stage layoutIfNeeded];
        NSArray *keys = @[@"throttle", @"brake", @"drift", @"jump", @"item1", @"item2"];
        UILabel *speed = [hud valueForKey:@"speedLabel"];
        for (NSString *key in keys) {
          UIView *button = [touch valueForKey:key];
          Check(CGRectContainsRect(touch.bounds, button.frame), @"Button clipped");
          Check(!CGRectIntersectsRect(speed.frame, button.frame), @"Speed obscured by controls");
          for (NSString *other in keys) if (![other isEqualToString:key])
            Check(!CGRectIntersectsRect(button.frame, [[touch valueForKey:other] frame]), @"Controls overlap");
        }
        UIView *base = [touch valueForKey:@"stickBase"];
        UIView *knob = [touch valueForKey:@"stickKnob"];
        Check(CGPointEqualToPoint(knob.center, CGPointMake(base.bounds.size.width/2, base.bounds.size.height/2)), @"Knob not centred on launch");
        [touch updateStick:CGPointMake(base.center.x + 100, base.center.y)];
        Check([touch pollControls].steer == 1, @"Right steer mapping");
        [touch updateStick:CGPointMake(base.center.x - 100, base.center.y)];
        Check([touch pollControls].steer == -1, @"Left steer mapping");
        [touch updateStick:CGPointMake(base.center.x + 2, base.center.y)];
        Check([touch pollControls].steer == 0, @"Centre dead zone");
        [touch setValue:@YES forKey:@"oneShotJump"];
        [[touch valueForKey:@"throttle"] setValue:@YES forKey:@"held"];
        touch.hidden = YES;
        PTKControls *c = [touch pollControls];
        Check(c.throttle == 0 && c.steer == 0 && !c.jump, @"Hidden input stuck");
        touch.hidden = NO;
        touch.frame = CGRectMake(0, 0, size.width - 100, size.height - 100);
        [touch layoutIfNeeded];
        Check(CGRectContainsRect(touch.bounds, base.frame), @"Joystick outside resized view");
        Check([touch pollControls].steer == 0, @"Resize retained steering");
        touch.frame = stage.bounds;
        [touch layoutIfNeeded];
        Capture(stage, [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"race-%.0f.png",size.width]]);
        hud.hidden = YES;
        touch.hidden = YES;
        PTKLobbyView *lobby = [[PTKLobbyView alloc] initWithFrame:stage.bounds];
        NSMutableArray *karts = [NSMutableArray array];
        for (NSString *name in @[@"薄荷飞驰", @"奶油冲锋", @"蓝莓闪电", @"草莓旋风"]) {
          PTKKartSpec *spec = [PTKKartSpec new];
          spec.name = name; spec.type = @"均衡型"; spec.color = 0x70ccb0;
          [karts addObject:spec];
        }
        lobby.karts = karts;
        [stage addSubview:lobby];
        [lobby showEntryWithStatus:@"创建房间，或输入六位房间码加入。"];
        [stage layoutIfNeeded];
        UIView *row = [lobby valueForKey:@"kartRow"];
        Check(row.bounds.size.height >= 56, @"Kart selection collapsed");
        Capture(stage, [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"lobby-%.0f.png",size.width]]);
        CGRect keyboard = CGRectMake(0, size.height - 300, size.width, 300);
        [[NSNotificationCenter defaultCenter] postNotificationName:UIKeyboardWillChangeFrameNotification object:nil
            userInfo:@{UIKeyboardFrameEndUserInfoKey:[NSValue valueWithCGRect:keyboard]}];
        UIScrollView *scroll = [lobby valueForKey:@"scroll"];
        UIView *card = [lobby valueForKey:@"card"];
        Check(CGRectGetMaxY(scroll.frame) <= keyboard.origin.y, @"Keyboard covers viewport");
        Check(scroll.contentSize.height >= CGRectGetMaxY(card.frame), @"Card content unreachable");
        [[NSNotificationCenter defaultCenter] postNotificationName:UIKeyboardWillHideNotification object:nil];
        [stage removeFromSuperview];
      }
      [@"PASS: iPad layout, steering, dead zone and input reset" writeToFile:[dir stringByAppendingPathComponent:@"result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {
      [[NSString stringWithFormat:@"FAIL: %@", e] writeToFile:[dir stringByAppendingPathComponent:@"result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
  });
  return YES;
}
@end
int main(int argc, char **argv) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TestApp.class)); }
}
