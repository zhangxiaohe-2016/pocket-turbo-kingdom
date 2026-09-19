#import "PTKLog.h"

NSString *const PTKLogDidUpdateNotification = @"PTKLogDidUpdateNotification";

static NSString *gLastError = nil;
static NSString *gLogPath = nil;

static void PTKLogWrite(NSString *line) {
  NSLog(@"[PTK] %@", line);
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ptk.log"];
  });
  NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:gLogPath]) {
    [data writeToFile:gLogPath atomically:YES];
    return;
  }
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
  if (handle) {
    @try {
      [handle seekToEndOfFile];
      [handle writeData:data];
    } @catch (__unused NSException *exception) {
    }
    [handle closeFile];
  }
}

void PTKLog(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  PTKLogWrite(message);
}

void PTKLogError(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  NSString *line = [@"[ERROR] " stringByAppendingString:message];
  PTKLogWrite(line);
  gLastError = message;
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:PTKLogDidUpdateNotification object:message];
  });
}

void PTKLogException(NSException *exception, NSString *context) {
  PTKLogError(@"%@ 异常: %@ — %@\n%@", context, exception.name, exception.reason,
              [exception.callStackSymbols componentsJoinedByString:@"\n"]);
}

NSString *PTKLogLastError(void) { return gLastError; }
NSString *PTKLogFilePath(void) { return gLogPath ?: @"/tmp/ptk.log"; }
