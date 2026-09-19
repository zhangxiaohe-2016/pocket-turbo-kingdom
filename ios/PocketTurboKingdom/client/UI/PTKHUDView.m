#import "PTKHUDView.h"

static const NSInteger PTKSlotCount = 2;

@implementation PTKHUDView {
  UILabel *_rankLabel, *_lapLabel, *_speedLabel, *_scoreLabel, *_badgeLabel;
  UILabel *_countdownLabel, *_toastLabel;
  NSMutableArray<UILabel *> *_slotLabels;
  UIView *_resultsPanel;
  UILabel *_resultsTitle;
  UIStackView *_resultsLines;
  UIButton *_resultsButton, *_exitButton;
  NSTimer *_toastTimer;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = YES;

    _rankLabel = [self panelLabel:@"1/4" size:26 bold:YES];
    _lapLabel = [self panelLabel:@"第 1 / 3 圈" size:17 bold:YES];
    _scoreLabel = [self panelLabel:@"0 分" size:20 bold:YES];
    _scoreLabel.hidden = YES;
    _badgeLabel = [self panelLabel:@"" size:14 bold:NO];
    _badgeLabel.hidden = YES;

    _speedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _speedLabel.textColor = [UIColor whiteColor];
    _speedLabel.font = [UIFont boldSystemFontOfSize:40];
    _speedLabel.textAlignment = NSTextAlignmentRight;
    _speedLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    _speedLabel.shadowOffset = CGSizeMake(0, 2);
    [self addSubview:_speedLabel];

    _slotLabels = [NSMutableArray array];
    for (NSInteger i = 0; i < PTKSlotCount; i++) {
      UILabel *slot = [self panelLabel:@"空" size:16 bold:YES];
      slot.textAlignment = NSTextAlignmentCenter;
      [_slotLabels addObject:slot];
    }

    _countdownLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countdownLabel.textColor = [UIColor colorWithRed:1.0 green:0.92 blue:0.55 alpha:1];
    _countdownLabel.font = [UIFont boldSystemFontOfSize:120];
    _countdownLabel.textAlignment = NSTextAlignmentCenter;
    _countdownLabel.hidden = YES;
    [self addSubview:_countdownLabel];

    _toastLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _toastLabel.textColor = [UIColor whiteColor];
    _toastLabel.numberOfLines = 2;
    _toastLabel.adjustsFontSizeToFitWidth = YES;
    _toastLabel.font = [UIFont boldSystemFontOfSize:19];
    _toastLabel.textAlignment = NSTextAlignmentCenter;
    _toastLabel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.68];
    _toastLabel.layer.cornerRadius = 10;
    _toastLabel.clipsToBounds = YES;
    _toastLabel.hidden = YES;
    [self addSubview:_toastLabel];

    _exitButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_exitButton setTitle:@"返回大厅" forState:UIControlStateNormal];
    _exitButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    _exitButton.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.6];
    _exitButton.layer.cornerRadius = 9;
    [_exitButton addTarget:self action:@selector(exitTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_exitButton];

    _resultsPanel = [[UIView alloc] initWithFrame:CGRectZero];
    _resultsPanel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.93];
    _resultsPanel.layer.cornerRadius = 18;
    _resultsPanel.layer.borderWidth = 1;
    _resultsPanel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    _resultsPanel.hidden = YES;
    _resultsPanel.userInteractionEnabled = YES;
    [self addSubview:_resultsPanel];

    _resultsTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _resultsTitle.textColor = [UIColor colorWithRed:1.0 green:0.88 blue:0.55 alpha:1];
    _resultsTitle.font = [UIFont boldSystemFontOfSize:28];
    _resultsTitle.textAlignment = NSTextAlignmentCenter;
    [_resultsPanel addSubview:_resultsTitle];

    _resultsLines = [[UIStackView alloc] initWithFrame:CGRectZero];
    _resultsLines.axis = UILayoutConstraintAxisVertical;
    _resultsLines.spacing = 6;
    _resultsLines.alignment = UIStackViewAlignmentFill;
    [_resultsPanel addSubview:_resultsLines];

    _resultsButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_resultsButton setTitle:@"再跑一场" forState:UIControlStateNormal];
    _resultsButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _resultsButton.backgroundColor = [UIColor colorWithRed:0.20 green:0.62 blue:0.52 alpha:1];
    _resultsButton.layer.cornerRadius = 10;
    [_resultsButton addTarget:self action:@selector(resultsTapped) forControlEvents:UIControlEventTouchUpInside];
    [_resultsPanel addSubview:_resultsButton];
  }
  return self;
}

- (UILabel *)panelLabel:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
  UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
  label.text = text;
  label.textColor = [UIColor whiteColor];
  label.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
  label.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.55];
  label.layer.cornerRadius = 9;
  label.clipsToBounds = YES;
  label.textAlignment = NSTextAlignmentCenter;
  [self addSubview:label];
  return label;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
  CGFloat w = area.size.width, h = area.size.height;
  CGFloat pad = 16;
  _exitButton.frame = CGRectMake(pad, pad + 112, 116, 44);
  _rankLabel.frame = CGRectMake(pad, pad, 116, 54);
  _lapLabel.frame = CGRectMake(pad, pad + 60, 190, 40);
  _scoreLabel.frame = CGRectMake(pad + 196, pad + 60, 110, 40);
  _badgeLabel.frame = CGRectMake(w / 2 - 170, pad, 340, 34);
  _speedLabel.frame = CGRectMake(w - 160 - pad, pad + 108, 160, 80);
  for (NSUInteger i = 0; i < _slotLabels.count; i++) {
    _slotLabels[i].frame = CGRectMake(w - 118 - pad, pad + i * 52, 118, 46);
  }
  _countdownLabel.frame = CGRectMake(0, h / 2 - 90, w, 170);
  _toastLabel.frame = CGRectMake(w / 2 - MIN(500, w - 320) / 2, pad + 46, MIN(500, w - 320), 64);
  CGFloat panelW = MIN(560, w - 80), panelH = 330;
  _resultsPanel.frame = CGRectMake((w - panelW) / 2, (h - panelH) / 2, panelW, panelH);
  for (UIView *view in self.subviews) view.frame = CGRectOffset(view.frame, area.origin.x, area.origin.y);
  _resultsTitle.frame = CGRectMake(20, 22, panelW - 40, 38);
  _resultsLines.frame = CGRectMake(40, 74, panelW - 80, 170);
  _resultsButton.frame = CGRectMake(panelW / 2 - 120, panelH - 68, 240, 48);
}

- (void)setLap:(NSInteger)lap total:(NSInteger)total rank:(NSInteger)rank players:(NSInteger)players
         speed:(CGFloat)speed score:(NSInteger)score arena:(BOOL)arena finished:(BOOL)finished {
  _rankLabel.text = [NSString stringWithFormat:@"%ld/%ld", (long)MAX(1, rank), (long)MAX(1, players)];
  if (arena) {
    _lapLabel.text = @"星火竞技场";
    _scoreLabel.hidden = NO;
    _scoreLabel.text = [NSString stringWithFormat:@"%ld 分", (long)score];
  } else {
    _lapLabel.text = finished ? @"已完赛" : [NSString stringWithFormat:@"第 %ld / %ld 圈", (long)MIN(lap + 1, total), (long)total];
    _scoreLabel.hidden = YES;
  }
  _speedLabel.text = [NSString stringWithFormat:@"%.0f\nkm/h", speed * 3.6];
  _speedLabel.numberOfLines = 2;
  _speedLabel.font = [UIFont boldSystemFontOfSize:32];
}

- (void)setCountdown:(CGFloat)seconds goFlash:(CGFloat)goFlash {
  if (seconds > 0.01) {
    _countdownLabel.hidden = NO;
    _countdownLabel.text = [NSString stringWithFormat:@"%.0f", ceil(seconds)];
    _countdownLabel.textColor = [UIColor colorWithRed:1.0 green:0.92 blue:0.55 alpha:1];
  } else if (goFlash > 0.01) {
    _countdownLabel.hidden = NO;
    _countdownLabel.text = @"GO!";
    _countdownLabel.textColor = [UIColor colorWithRed:0.45 green:0.95 blue:0.6 alpha:1];
  } else {
    _countdownLabel.hidden = YES;
  }
}

- (void)setSlots:(NSArray *)slots {
  NSDictionary *names = @{ @"battery": @"涡轮电池", @"peel": @"弹跳果皮", @"gear": @"回旋齿轮", @"firefly": @"追踪萤火弹" };
  for (NSInteger i = 0; i < PTKSlotCount; i++) {
    id value = (i < (NSInteger)slots.count) ? slots[i] : [NSNull null];
    NSString *kind = [value isKindOfClass:NSString.class] ? value : nil;
    _slotLabels[i].text = kind ? names[kind] : @"空";
    _slotLabels[i].textColor = kind ? [UIColor colorWithRed:1 green:0.95 blue:0.8 alpha:1] : [UIColor colorWithWhite:0.7 alpha:1];
  }
}

- (void)showToast:(NSString *)text {
  _toastLabel.text = text;
  _toastLabel.hidden = NO;
  [_toastTimer invalidate];
  _toastTimer = [NSTimer scheduledTimerWithTimeInterval:2.2 repeats:NO block:^(NSTimer *timer) {
    self->_toastLabel.hidden = YES;
  }];
}

- (void)showResultsWithTitle:(NSString *)title lines:(NSArray<NSString *> *)lines button:(NSString *)button {
  _resultsTitle.text = title;
  [_resultsLines.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
  for (NSString *text in lines) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:17];
    label.textAlignment = NSTextAlignmentCenter;
    [_resultsLines addArrangedSubview:label];
  }
  [_resultsButton setTitle:button forState:UIControlStateNormal];
  _resultsPanel.hidden = NO;
  self.userInteractionEnabled = YES;
}

- (void)hideResults {
  _resultsPanel.hidden = YES;
  self.userInteractionEnabled = YES;
}

// Let steering and action touches reach the controls beneath the HUD.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *hit = [super hitTest:point withEvent:event];
  return hit == self && _resultsPanel.hidden ? nil : hit;
}

- (void)exitTapped { if (self.onExitButton) self.onExitButton(); }

- (void)resultsTapped { if (self.onResultsButton) self.onResultsButton(); }

- (void)setBadge:(NSString *)text {
  _badgeLabel.hidden = text.length == 0;
  _badgeLabel.text = text;
}

@end
