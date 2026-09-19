// PTKHUDView —— 比赛内 HUD：名次/圈数/速度/道具槽/倒计时/结算面板。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PTKHUDView : UIView
@property (nonatomic, copy, nullable) void (^onResultsButton)(void);
@property (nonatomic, copy, nullable) void (^onExitButton)(void);
- (void)setLap:(NSInteger)lap total:(NSInteger)total rank:(NSInteger)rank players:(NSInteger)players
         speed:(CGFloat)speed score:(NSInteger)score arena:(BOOL)arena finished:(BOOL)finished;
- (void)setCountdown:(CGFloat)seconds goFlash:(CGFloat)goFlash;
- (void)setSlots:(NSArray *)slots;
- (void)showToast:(NSString *)text;
- (void)showResultsWithTitle:(NSString *)title lines:(NSArray<NSString *> *)lines button:(NSString *)button;
- (void)hideResults;
- (void)setBadge:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
