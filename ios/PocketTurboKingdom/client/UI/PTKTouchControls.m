#import "PTKTouchControls.h"

#pragma mark - 单个按钮

@interface PTKButtonView : UIView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) UIColor *tint;
@property (nonatomic) BOOL held;
@property (nonatomic, copy) void (^onDown)(void);
@property (nonatomic, copy) void (^onUp)(void);
@end

@implementation PTKButtonView {
  UILabel *_label;
}

- (instancetype)initWithTitle:(NSString *)title tint:(UIColor *)tint {
  if ((self = [super initWithFrame:CGRectZero])) {
    _title = title;
    _tint = tint;
    self.backgroundColor = [tint colorWithAlphaComponent:0.22];
    self.layer.cornerRadius = 12;
    self.layer.borderWidth = 2;
    self.layer.borderColor = [tint colorWithAlphaComponent:0.75].CGColor;
    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.text = title;
    _label.textColor = [UIColor whiteColor];
    _label.font = [UIFont boldSystemFontOfSize:17];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.userInteractionEnabled = NO;
    [self addSubview:_label];
    self.userInteractionEnabled = YES;
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _label.frame = self.bounds;
}

- (void)setHeld:(BOOL)held {
  _held = held;
  self.backgroundColor = [self.tint colorWithAlphaComponent:held ? 0.60 : 0.22];

}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  self.held = YES;
  if (self.onDown) self.onDown();
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  self.held = NO;
  if (self.onUp) self.onUp();
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self touchesEnded:touches withEvent:event];
}

@end

#pragma mark - 触屏操作层

@implementation PTKTouchControls {
  UIView *_stickBase, *_stickKnob;
  PTKButtonView *_throttle, *_brake, *_drift, *_jump, *_item1, *_item2;
  CGPoint _stickOrigin;
  CGFloat _steer;
  BOOL _oneShotJump, _oneShotItem1, _oneShotItem2;
  UITouch *_stickTouch;
  CGRect _layoutBounds;
  CGPoint _restOrigin;
  CGFloat _stickRadius;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = [UIColor clearColor];
    self.multipleTouchEnabled = YES;

    _stickBase = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 190, 190)];
    _stickBase.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    _stickBase.layer.cornerRadius = 95;
    _stickBase.layer.borderWidth = 2;
    _stickBase.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    _stickBase.userInteractionEnabled = NO;
    [self addSubview:_stickBase];

    _stickKnob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 78, 78)];
    _stickKnob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
    _stickKnob.layer.cornerRadius = 39;
    _stickKnob.userInteractionEnabled = NO;
    [_stickBase addSubview:_stickKnob];

    UIColor *green = [UIColor colorWithRed:0.42 green:0.93 blue:0.62 alpha:1];
    UIColor *orange = [UIColor colorWithRed:1.0 green:0.72 blue:0.35 alpha:1];
    UIColor *blue = [UIColor colorWithRed:0.50 green:0.80 blue:1.0 alpha:1];
    UIColor *pink = [UIColor colorWithRed:1.0 green:0.55 blue:0.75 alpha:1];
    _throttle = [[PTKButtonView alloc] initWithTitle:@"油门" tint:green];
    _brake = [[PTKButtonView alloc] initWithTitle:@"刹车" tint:orange];
    _drift = [[PTKButtonView alloc] initWithTitle:@"漂移" tint:blue];
    _jump = [[PTKButtonView alloc] initWithTitle:@"跳跃" tint:blue];
    _item1 = [[PTKButtonView alloc] initWithTitle:@"道具 1" tint:pink];
    _item2 = [[PTKButtonView alloc] initWithTitle:@"道具 2" tint:pink];
    for (PTKButtonView *button in @[ _throttle, _brake, _drift, _jump, _item1, _item2 ]) {
      [self addSubview:button];
    }
    __weak PTKTouchControls *weakSelf = self;
    _jump.onDown = ^{ PTKTouchControls *strongSelf = weakSelf; if (strongSelf) strongSelf->_oneShotJump = YES; };
    _item1.onDown = ^{ PTKTouchControls *strongSelf = weakSelf; if (strongSelf) strongSelf->_oneShotItem1 = YES; };
    _item2.onDown = ^{ PTKTouchControls *strongSelf = weakSelf; if (strongSelf) strongSelf->_oneShotItem2 = YES; };
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect b = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
  CGFloat side = MIN(100.0, b.size.height * 0.15);
  CGFloat gap = 12, margin = 20;
  CGFloat right = CGRectGetMaxX(b) - margin;
  CGFloat bottom = CGRectGetMaxY(b) - margin;
  // Three rows stay together, leaving the top right exclusively for the HUD.
  NSArray<PTKButtonView *> *buttons = @[ _brake, _throttle, _jump, _drift, _item1, _item2 ];
  for (NSUInteger i = 0; i < buttons.count; i++) {
    buttons[i].frame = CGRectMake(right - (2 - i % 2) * side - (1 - i % 2) * gap,
                                 bottom - (i / 2 + 1) * side - (i / 2) * gap, side, side);
  }
  _stickRadius = MIN(95, b.size.height * 0.16);
  _restOrigin = CGPointMake(CGRectGetMinX(b) + margin + _stickRadius, bottom - _stickRadius);
  _stickBase.bounds = CGRectMake(0, 0, _stickRadius * 2, _stickRadius * 2);
  _stickBase.layer.cornerRadius = _stickRadius;
  if (!CGRectEqualToRect(_layoutBounds, b)) {
    _layoutBounds = b;
    [self reset];
  }
}

- (void)setHidden:(BOOL)hidden {
  if (hidden) [self reset];
  [super setHidden:hidden];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  // Keep a stable centre: dragging left/right is meaningful from the first touch.
  for (UITouch *touch in touches) {
    CGPoint p = [touch locationInView:self];
    if (!_stickTouch && CGRectContainsPoint(CGRectInset(_stickBase.frame, -24, -24), p)) {
      _stickTouch = touch;
      [self updateStick:p];
      break;
    }
  }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (_stickTouch && [touches containsObject:_stickTouch]) {
    [self updateStick:[_stickTouch locationInView:self]];
  }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (_stickTouch && [touches containsObject:_stickTouch]) {
    _stickTouch = nil;
    _steer = 0;
    _stickKnob.center = CGPointMake(_stickRadius, _stickRadius);
  }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self touchesEnded:touches withEvent:event];
}

- (void)updateStick:(CGPoint)point {
  CGFloat dx = point.x - _stickOrigin.x;
  CGFloat limit = MAX(1, _stickRadius - 39);
  CGFloat x = MAX(-1.0, MIN(1.0, dx / limit));
  CGFloat deadZone = 0.12;
  _steer = fabs(x) <= deadZone ? 0 : copysign((fabs(x) - deadZone) / (1 - deadZone), x);
  _stickKnob.center = CGPointMake(_stickRadius + x * limit, _stickRadius);
}

- (PTKControls *)pollControls {
  PTKControls *c = [PTKControls new];
  c.steer = _steer;
  c.throttle = _throttle.held ? 1 : 0;
  c.brake = _brake.held ? 1 : 0;
  c.drift = _drift.held;
  c.jump = _oneShotJump;
  c.item1 = _oneShotItem1;
  c.item2 = _oneShotItem2;
  _oneShotJump = NO;
  _oneShotItem1 = NO;
  _oneShotItem2 = NO;
  return c;
}

- (void)reset {
  _oneShotJump = _oneShotItem1 = _oneShotItem2 = NO;
  _stickOrigin = _restOrigin;
  _stickBase.center = _restOrigin;
  _steer = 0;
  _stickTouch = nil;
  _stickKnob.center = CGPointMake(_stickRadius, _stickRadius);
  for (PTKButtonView *button in @[ _throttle, _brake, _drift, _jump, _item1, _item2 ]) button.held = NO;
}

@end
