// PTKLobbyView —— 局域网大厅：昵称、选车、创建/加入房间、准备与发车。
#import <UIKit/UIKit.h>
#import "PTKProtocol.h"
#import "PTKTrackData.h"

NS_ASSUME_NONNULL_BEGIN

@protocol PTKLobbyViewDelegate <NSObject>
- (void)lobbyDidPlaySoloWithName:(NSString *)name kart:(NSInteger)kart host:(NSString *)host;
- (void)lobbyDidCreateRoomWithName:(NSString *)name kart:(NSInteger)kart host:(NSString *)host;
- (void)lobbyDidJoinCode:(NSString *)code name:(NSString *)name kart:(NSInteger)kart host:(NSString *)host;
- (void)lobbyDidToggleReady:(BOOL)ready;
- (void)lobbyDidStart;
- (void)lobbyDidChangeMode:(NSString *)mode;
- (void)lobbyDidRematch;
- (void)lobbyDidLeave;
@end

@interface PTKLobbyView : UIView
@property (nonatomic, weak, nullable) id<PTKLobbyViewDelegate> delegate;
@property (nonatomic, copy) NSArray<PTKKartSpec *> *karts;
@property (nonatomic, readonly) NSString *serverHost;
@property (nonatomic, readonly) NSInteger selectedKart;
- (void)showEntryWithStatus:(NSString *)status;
- (void)showRoom:(PTKRoom *)room you:(NSString *)you address:(NSString *)address;
- (void)setStatus:(NSString *)status;
- (void)setBusy:(BOOL)busy;
- (void)prefillHost:(NSString *)host;
@end

NS_ASSUME_NONNULL_END
