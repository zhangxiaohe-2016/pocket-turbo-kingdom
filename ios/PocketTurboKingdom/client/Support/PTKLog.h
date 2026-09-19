// PTKLog —— iPad 上没有调试器：所有异常都写进 NSLog + 临时文件，并把最后一条显示在屏幕上。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 记录一条日志（同时 NSLog 并追加到 tmp/ptk.log）。线程安全。
void PTKLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// 记录异常与错误；最后一条会通过 PTKLogDidUpdateNotification 抛给 UI 显示。
void PTKLogError(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void PTKLogException(NSException *exception, NSString *context);

/// 最近一条错误（用于在屏幕上显示），没有则返回 nil。
NSString *_Nullable PTKLogLastError(void);
NSString *PTKLogFilePath(void);

/// PTKLogError/PTKLogException 时在主线程发出，object 是错误文本。
extern NSString *const PTKLogDidUpdateNotification;

NS_ASSUME_NONNULL_END
