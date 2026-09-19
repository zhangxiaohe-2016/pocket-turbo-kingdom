// screenshot —— 越狱设备专用的小工具：通过 SSH 运行，把当前屏幕抓成 PNG。
//
//   clang -arch arm64 -isysroot <iPhoneOS SDK> -miphoneos-version-min=12.0 \
//     -framework Foundation -framework UIKit -framework ImageIO -framework CoreGraphics \
//     tools/screenshot.m -o build/screenshot && ldid -S build/screenshot
//   scp build/screenshot root@<iPad>:/usr/bin/ && ssh root@<iPad> 'screenshot /tmp/shot.png'
//
// 用的是 UIKit 的私有 SPI UIGetScreenImage（Cydia 系截屏工具一直用它）。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>

typedef CGImageRef (*UIGetScreenImageFn)(void);

int main(int argc, char *argv[]) {
  @autoreleasepool {
    NSString *out = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"/tmp/ptk-screen.png";
    void *handle = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
    if (!handle) {
      fprintf(stderr, "打不开 UIKit: %s\n", dlerror());
      return 1;
    }
    UIGetScreenImageFn getScreen = (UIGetScreenImageFn)dlsym(handle, "UIGetScreenImage");
    if (!getScreen) {
      fprintf(stderr, "UIGetScreenImage 符号不存在（这台系统不支持这个 SPI）\n");
      return 2;
    }
    CGImageRef image = getScreen();
    if (!image) {
      fprintf(stderr, "UIGetScreenImage 返回空\n");
      return 3;
    }
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:out], CFSTR("public.png"), 1, NULL);
    if (!destination) {
      fprintf(stderr, "无法写入 %s\n", out.UTF8String);
      return 4;
    }
    CGImageDestinationAddImage(destination, image, NULL);
    bool ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    printf("%s  %s  %zux%zu\n", ok ? "OK" : "失败", out.UTF8String,
           CGImageGetWidth(image), CGImageGetHeight(image));
    return ok ? 0 : 5;
  }
}
