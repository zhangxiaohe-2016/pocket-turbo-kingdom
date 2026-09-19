#import "PTKLobbyView.h"

static UIColor *PTKUIColorHex(NSInteger hex) {
  return [UIColor colorWithRed:((hex >> 16) & 0xff) / 255.0
                         green:((hex >> 8) & 0xff) / 255.0
                          blue:(hex & 0xff) / 255.0
                         alpha:1.0];
}

@implementation PTKLobbyView {
  UIView *_card;
  UIScrollView *_scroll;
  CGRect _keyboardFrame;
  UILabel *_title, *_status, *_roomCode, *_address;
  UITextField *_nameField, *_codeField, *_hostField;
  UIView *_kartRow;
  NSMutableArray<UIButton *> *_kartButtons;
  UIButton *_soloButton, *_createButton, *_joinButton, *_readyButton, *_startButton, *_leaveButton;
  UISegmentedControl *_modeControl;
  UIStackView *_entryStack, *_roomStack, *_playerStack;
  UILabel *_playerTitle;
  BOOL _isHost, _ready;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = [UIColor colorWithWhite:0.03 alpha:0.55];
    _kartButtons = [NSMutableArray array];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.92];
    _card.layer.cornerRadius = 18;
    _card.layer.borderWidth = 1;
    _card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self addSubview:_scroll];
    [_scroll addSubview:_card];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
        name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
        name:UIKeyboardWillHideNotification object:nil];

    _title = [self label:@"口袋涡轮王国 · 局域网竞技" size:26 bold:YES color:[UIColor whiteColor]];
    _status = [self label:@"" size:15 bold:NO color:[UIColor colorWithWhite:0.75 alpha:1]];
    _status.numberOfLines = 0;

    _entryStack = [[UIStackView alloc] init];
    _entryStack.axis = UILayoutConstraintAxisVertical;
    _entryStack.spacing = 12;

    [_entryStack addArrangedSubview:[self label:@"主机地址（Mac 终端里显示的局域网 IP）" size:13 bold:NO color:[UIColor colorWithWhite:0.62 alpha:1]]];
    _hostField = [self textField:@"192.168.31.249" width:0];
    _hostField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    [_entryStack addArrangedSubview:_hostField];

    [_entryStack addArrangedSubview:[self label:@"车手昵称" size:13 bold:NO color:[UIColor colorWithWhite:0.62 alpha:1]]];
    _nameField = [self textField:@"口袋车手" width:0];
    [_entryStack addArrangedSubview:_nameField];

    [_entryStack addArrangedSubview:[self label:@"选择赛车" size:13 bold:NO color:[UIColor colorWithWhite:0.62 alpha:1]]];
    _kartRow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 64)];
    _kartRow.backgroundColor = [UIColor clearColor];
    [_kartRow.heightAnchor constraintEqualToConstant:64].active = YES;
    [_entryStack addArrangedSubview:_kartRow];

    UIStackView *buttons = [[UIStackView alloc] init];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 10;
    buttons.distribution = UIStackViewDistributionFillEqually;
    _createButton = [self button:@"创建房间" color:[UIColor colorWithRed:0.20 green:0.62 blue:0.52 alpha:1]];
    [_createButton addTarget:self action:@selector(createTapped) forControlEvents:UIControlEventTouchUpInside];
    _codeField = [self textField:@"6 位房间码" width:0];
    _codeField.text = @"";
    _codeField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    _joinButton = [self button:@"加入房间" color:[UIColor colorWithWhite:0.24 alpha:1]];
    [_joinButton addTarget:self action:@selector(joinTapped) forControlEvents:UIControlEventTouchUpInside];
    [buttons addArrangedSubview:_createButton];
    [buttons addArrangedSubview:_codeField];
    [buttons addArrangedSubview:_joinButton];
    [_entryStack addArrangedSubview:buttons];

    _soloButton = [self button:@"单人竞速 · 对战 3 名电脑" color:PTKUIColorHex(0x326b96)];
    [_soloButton addTarget:self action:@selector(soloTapped) forControlEvents:UIControlEventTouchUpInside];
    [_entryStack addArrangedSubview:_soloButton];
    [_entryStack addArrangedSubview:[self label:@"单人模式无需其他玩家，仍需连接运行游戏的 Mac。" size:13 bold:NO color:[UIColor colorWithWhite:0.7 alpha:1]]];

    _roomStack = [[UIStackView alloc] init];
    _roomStack.axis = UILayoutConstraintAxisVertical;
    _roomStack.spacing = 10;
    _roomStack.hidden = YES;

    _roomCode = [self label:@"------" size:40 bold:YES color:[UIColor colorWithRed:1.0 green:0.85 blue:0.45 alpha:1]];
    _roomCode.textAlignment = NSTextAlignmentCenter;
    [_roomStack addArrangedSubview:_roomCode];
    _address = [self label:@"" size:13 bold:NO color:[UIColor colorWithWhite:0.66 alpha:1]];
    _address.textAlignment = NSTextAlignmentCenter;
    _address.numberOfLines = 0;
    [_roomStack addArrangedSubview:_address];

    _modeControl = [[UISegmentedControl alloc] initWithItems:@[ @"山谷竞速 · 3 圈", @"星火竞技场 · 道具" ]];
    [_modeControl addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    _modeControl.selectedSegmentIndex = 0;
    [_roomStack addArrangedSubview:_modeControl];

    _playerTitle = [self label:@"车手" size:13 bold:NO color:[UIColor colorWithWhite:0.62 alpha:1]];
    [_roomStack addArrangedSubview:_playerTitle];
    _playerStack = [[UIStackView alloc] init];
    _playerStack.axis = UILayoutConstraintAxisVertical;
    _playerStack.spacing = 5;
    [_roomStack addArrangedSubview:_playerStack];

    UIStackView *roomButtons = [[UIStackView alloc] init];
    roomButtons.axis = UILayoutConstraintAxisHorizontal;
    roomButtons.spacing = 10;
    roomButtons.distribution = UIStackViewDistributionFillEqually;
    _readyButton = [self button:@"准备" color:[UIColor colorWithWhite:0.24 alpha:1]];
    [_readyButton addTarget:self action:@selector(readyTapped) forControlEvents:UIControlEventTouchUpInside];
    _startButton = [self button:@"全员准备后发车" color:[UIColor colorWithRed:0.20 green:0.62 blue:0.52 alpha:1]];
    [_startButton addTarget:self action:@selector(startTapped) forControlEvents:UIControlEventTouchUpInside];
    _leaveButton = [self button:@"离开房间" color:[UIColor colorWithWhite:0.18 alpha:1]];
    [_leaveButton addTarget:self action:@selector(leaveTapped) forControlEvents:UIControlEventTouchUpInside];
    [roomButtons addArrangedSubview:_readyButton];
    [roomButtons addArrangedSubview:_startButton];
    [roomButtons addArrangedSubview:_leaveButton];
    [_roomStack addArrangedSubview:roomButtons];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ _title, _status, _entryStack, _roomStack ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 14;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
      [column.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:26],
      [column.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-26],
      [column.topAnchor constraintEqualToAnchor:_card.topAnchor constant:22],
      [column.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-22],
    ]];
  }
  return self;
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size bold:(BOOL)bold color:(UIColor *)color {
  UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
  label.numberOfLines = 0;
  label.text = text;
  label.textColor = color;
  label.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
  return label;
}

- (UITextField *)textField:(NSString *)placeholder width:(CGFloat)width {
  UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, width, 40)];
  field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder
      attributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:0.65 alpha:1]}];
  field.text = placeholder;
  field.textColor = [UIColor whiteColor];
  field.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
  field.layer.cornerRadius = 9;
  field.borderStyle = UITextBorderStyleNone;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.spellCheckingType = UITextSpellCheckingTypeNo;
  field.clearButtonMode = UITextFieldViewModeWhileEditing;
  field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 40)];
  field.leftViewMode = UITextFieldViewModeAlways;
  [field.heightAnchor constraintEqualToConstant:40].active = YES;
  return field;
}

- (UIButton *)button:(NSString *)title color:(UIColor *)color {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  [button setTitle:title forState:UIControlStateNormal];
  button.titleLabel.numberOfLines = 2;
  button.titleLabel.textAlignment = NSTextAlignmentCenter;
  button.titleLabel.adjustsFontSizeToFitWidth = YES;
  button.titleLabel.font = [UIFont boldSystemFontOfSize:16];
  button.backgroundColor = color;
  button.layer.cornerRadius = 10;
  [button.heightAnchor constraintEqualToConstant:44].active = YES;
  return button;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)keyboardChanged:(NSNotification *)notification {
  _keyboardFrame = [notification.name isEqualToString:UIKeyboardWillHideNotification]
      ? CGRectZero : [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
  [self setNeedsLayout];
  [self layoutIfNeeded];
  for (UITextField *field in @[ _hostField, _nameField, _codeField ]) {
    if (field.isFirstResponder)
      [_scroll scrollRectToVisible:CGRectInset([field convertRect:field.bounds toView:_scroll], 0, -16) animated:YES];
  }
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect visible = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
  CGRect keyboard = [self convertRect:_keyboardFrame fromView:nil];
  CGRect overlap = CGRectIntersection(visible, keyboard);
  if (!CGRectIsNull(overlap) && overlap.size.height > 0)
    visible.size.height = MAX(120, CGRectGetMinY(overlap) - visible.origin.y);
  _scroll.frame = visible;
  CGSize size = visible.size;
  CGFloat cardWidth = MIN(620, size.width - 60);
  CGSize fitting = [_card systemLayoutSizeFittingSize:CGSizeMake(cardWidth, UILayoutFittingCompressedSize.height)
                       withHorizontalFittingPriority:UILayoutPriorityRequired
                             verticalFittingPriority:UILayoutPriorityDefaultLow];
  CGFloat cardHeight = fitting.height;
  _card.frame = CGRectMake((size.width - cardWidth) / 2, MAX(20, (size.height - cardHeight) / 2), cardWidth, cardHeight);
  _scroll.contentSize = CGSizeMake(size.width, MAX(size.height, cardHeight + 40));

  // 选车按钮：一行 4 个，颜色对应 KARTS
  CGFloat gap = 8;
  CGFloat buttonWidth = (cardWidth - 52 - gap * 3) / 4.0;
  for (NSUInteger i = 0; i < _kartButtons.count; i++) {
    _kartButtons[i].frame = CGRectMake(i * (buttonWidth + gap), 0, buttonWidth, 56);
  }
}

- (void)setKarts:(NSArray<PTKKartSpec *> *)karts {
  _karts = karts;
  for (UIButton *button in _kartButtons) [button removeFromSuperview];
  [_kartButtons removeAllObjects];
  for (NSUInteger i = 0; i < karts.count; i++) {
    PTKKartSpec *spec = karts[i];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:[NSString stringWithFormat:@"%@\n%@", spec.name, spec.type] forState:UIControlStateNormal];
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.font = [UIFont systemFontOfSize:13];
    button.tag = (NSInteger)i;
    [button addTarget:self action:@selector(kartTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_kartRow addSubview:button];
    [_kartButtons addObject:button];
  }
  [self highlightKart:0];
  [self setNeedsLayout];
}

- (NSInteger)selectedKart {
  for (UIButton *button in _kartButtons) if (button.selected) return button.tag;
  return 0;
}

- (void)highlightKart:(NSInteger)index {
  for (UIButton *button in _kartButtons) {
    PTKKartSpec *spec = _karts[button.tag];
    BOOL on = button.tag == index;
    button.selected = on;
    button.backgroundColor = [PTKUIColorHex(spec.color) colorWithAlphaComponent:on ? 0.92 : 0.28];
    [button setTitleColor:on ? [UIColor colorWithWhite:0.08 alpha:1] : [UIColor whiteColor] forState:UIControlStateNormal];
    button.layer.cornerRadius = 10;
    button.layer.borderWidth = on ? 3 : 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:on ? 0.9 : 0.25].CGColor;
  }
}

- (void)kartTapped:(UIButton *)sender { [self highlightKart:sender.tag]; }

- (NSString *)serverHost {
  NSString *host = _hostField.text.length ? _hostField.text : _hostField.placeholder;
  host = [host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if ([host hasPrefix:@"ws://"]) host = [host substringFromIndex:5];
  if ([host hasPrefix:@"http://"]) host = [host substringFromIndex:7];
  NSRange slash = [host rangeOfString:@"/"];
  if (slash.location != NSNotFound) host = [host substringToIndex:slash.location];
  if ([host rangeOfString:@":"].location == NSNotFound) host = [host stringByAppendingString:@":5173"];
  return host;
}

- (NSString *)playerName {
  NSString *name = [_nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  return name.length ? name : @"口袋车手";
}

- (void)prefillHost:(NSString *)host {
  if (host.length) _hostField.text = host;
}

- (void)soloTapped {
  [self endEditing:YES];
  [self.delegate lobbyDidPlaySoloWithName:[self playerName] kart:[self selectedKart] host:[self serverHost]];
}

- (void)createTapped {
  [self endEditing:YES];
  if (self.delegate) [self.delegate lobbyDidCreateRoomWithName:[self playerName] kart:[self selectedKart] host:[self serverHost]];
}

- (void)joinTapped {
  [self endEditing:YES];
  NSString *code = [_codeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if (code.length < 6) { [self setStatus:@"请输入主机显示的 6 位房间码"]; return; }
  if (self.delegate) [self.delegate lobbyDidJoinCode:code.uppercaseString name:[self playerName] kart:[self selectedKart] host:[self serverHost]];
}

- (void)readyTapped {
  _ready = !_ready;
  [_readyButton setTitle:_ready ? @"取消准备" : @"准备" forState:UIControlStateNormal];
  _readyButton.backgroundColor = _ready ? [UIColor colorWithRed:0.20 green:0.62 blue:0.52 alpha:1] : [UIColor colorWithWhite:0.24 alpha:1];
  if (self.delegate) [self.delegate lobbyDidToggleReady:_ready];
}

- (void)startTapped { if (self.delegate) [self.delegate lobbyDidStart]; }
- (void)leaveTapped { if (self.delegate) [self.delegate lobbyDidLeave]; }
- (void)modeChanged { if (self.delegate) [self.delegate lobbyDidChangeMode:_modeControl.selectedSegmentIndex == 0 ? @"quick" : @"arena"]; }

- (void)showEntryWithStatus:(NSString *)status {
  _entryStack.hidden = NO;
  _roomStack.hidden = YES;
  _ready = NO;
  [_readyButton setTitle:@"准备" forState:UIControlStateNormal];
  [self setStatus:status];
}

- (void)showRoom:(PTKRoom *)room you:(NSString *)you address:(NSString *)address {
  _entryStack.hidden = YES;
  _roomStack.hidden = NO;
  _isHost = [room.host isEqualToString:you];
  _roomCode.text = room.code;
  _address.text = address.length ? [NSString stringWithFormat:@"朋友在这台 Mac 的浏览器打开 %@ 并输入房间码", address] : @"";
  _modeControl.selectedSegmentIndex = [room.mode isEqualToString:@"arena"] ? 1 : 0;
  _modeControl.enabled = _isHost;
  _modeControl.alpha = _isHost ? 1.0 : 0.55;
  _startButton.hidden = !_isHost;
  [_startButton setTitle:room.players.count == 1 ? @"单人发车 · 对战电脑" : @"全员准备后发车" forState:UIControlStateNormal];
  [_playerStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
  for (PTKPlayer *player in room.players) {
    BOOL isYou = [player.playerId isEqualToString:you];
    NSString *text = [NSString stringWithFormat:@"%@%@ %@", player.name, isYou ? @"（你）" : @"",
                                                player.ready ? @"✅ 已准备" : (player.connected ? @"待准备" : @"已掉线")];
    UILabel *label = [self label:text size:15 bold:isYou color:isYou ? [UIColor colorWithRed:1 green:0.9 blue:0.6 alpha:1] : [UIColor whiteColor]];
    [_playerStack addArrangedSubview:label];
  }
  _playerTitle.text = [NSString stringWithFormat:@"车手 %lu/4 · 房间码 %@", (unsigned long)room.players.count, room.code];
  [self setStatus:@"1 人可直接发车对战电脑；多人时全部准备后发车。"];
  [self setNeedsLayout];
}

- (void)setStatus:(NSString *)status { _status.text = status ?: @""; [self setNeedsLayout]; }

- (void)setBusy:(BOOL)busy {
  _soloButton.enabled = _createButton.enabled = _joinButton.enabled = !busy;
  _soloButton.alpha = _createButton.alpha = _joinButton.alpha = busy ? 0.5 : 1.0;
}

@end
