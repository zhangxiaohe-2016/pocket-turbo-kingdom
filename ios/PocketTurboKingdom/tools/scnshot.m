// scnshot —— macOS 离屏渲染工具：把 .ptkgeo 渲染成 PNG，用于在 Mac 上验证 iPad 客户端的画面。
//
//   clang -fobjc-arc -framework Foundation -framework SceneKit -framework AppKit -framework ImageIO \
//     -framework CoreGraphics -framework CoreText \
//     client/Render/PTKTrackData.m tools/scnshot.m -o /tmp/scnshot
//
//   /tmp/scnshot assets/track.ptkgeo /tmp/track-start.png --view start
#import <Foundation/Foundation.h>
#import <SceneKit/SceneKit.h>
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import "PTKTrackData.h"
#import "PTKKartNode.h"

static NSArray<NSString *> *arguments(void) { return NSProcessInfo.processInfo.arguments; }

static NSString *valueFor(NSString *flag, NSString *fallback) {
  NSArray<NSString *> *args = arguments();
  NSUInteger i = [args indexOfObject:flag];
  return (i != NSNotFound && i + 1 < args.count) ? args[i + 1] : fallback;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSArray<NSString *> *args = arguments();
    if (args.count < 3) {
      fprintf(stderr, "用法: scnshot <file.ptkgeo> <out.png> [--view start|aerial|chase|top] [--width N] [--height N] [--time T]\n");
      return 2;
    }
    NSString *geoPath = args[1];
    NSString *outPath = args[2];
    NSString *view = valueFor(@"--view", @"start");
    CGFloat width = [valueFor(@"--width", @"1024") doubleValue];
    CGFloat height = [valueFor(@"--height", @"768") doubleValue];
    double time = [valueFor(@"--time", @"0") doubleValue];
    BOOL wireframe = [args containsObject:@"--wire"];

    NSError *error = nil;
    NSDate *t0 = [NSDate date];
    PTKTrackData *data = [PTKTrackData dataWithContentsOfFile:geoPath error:&error];
    if (!data) {
      fprintf(stderr, "读取几何失败: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }
    SCNNode *root = [data buildStaticScene];
    NSTimeInterval loadMs = -[t0 timeIntervalSinceNow] * 1000;
    printf("几何: %lu 个 mesh, %lu 三角形, %lu 指示牌, %lu 道具箱, %lu 障碍 (加载 %.0f ms)\n",
           (unsigned long)data.nodes.count, (unsigned long)data.triangleCount, (unsigned long)data.signs.count,
           (unsigned long)data.boxes.count, (unsigned long)data.obstacles.count, loadMs);

    SCNScene *scene = [SCNScene scene];
    scene.background.contents = PTKColor(0.70, 0.85, 0.84);
    scene.fogColor = PTKColor(0.70, 0.85, 0.84);
    scene.fogStartDistance = 120;
    scene.fogEndDistance = 420;
    [scene.rootNode addChildNode:root];

    SCNNode *hemi = [SCNNode node];
    hemi.light = [SCNLight light];
    hemi.light.type = SCNLightTypeAmbient;
    hemi.light.color = PTKColor(0.62, 0.72, 0.70);
    [scene.rootNode addChildNode:hemi];

    SCNNode *sun = [SCNNode node];
    sun.light = [SCNLight light];
    sun.light.type = SCNLightTypeDirectional;
    sun.light.color = PTKColor(1.0, 0.93, 0.78);
    sun.light.intensity = 900;
    sun.position = SCNVector3Make(30, 65, 20);
    [sun lookAt:SCNVector3Zero up:SCNVector3Make(0, 1, 0) localFront:SCNVector3Make(0, 0, -1)];
    [scene.rootNode addChildNode:sun];

    // 静态场景整体材质降级为无高光的漫反射，接近 A7 上的目标画质
    if (wireframe) {
      [root enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
        if (!node.geometry) return;
        SCNMaterial *m = [SCNMaterial material];
        m.fillMode = SCNFillModeLines;
        m.diffuse.contents = PTKColor(0.1, 0.9, 0.5);
        node.geometry.materials = @[ m ];
      }];
    }

    // --karts：把 4 辆赛车摆一排，验证图元移植（轮子/尾翼/头盔/专属细节）
    if ([view isEqualToString:@"karts"]) {
      SCNNode *row = [SCNNode node];
      [scene.rootNode addChildNode:row];
      NSArray<PTKKartSpec *> *specs = data.karts;
      for (NSUInteger i = 0; i < specs.count; i++) {
        PTKKartNode *kart = [PTKKartNode kartWithSpec:specs[i] ghost:NO];
        kart.root.position = SCNVector3Make((CGFloat)i * 3.4 - (specs.count - 1) * 1.7, 0.6, 0);
        kart.root.eulerAngles = SCNVector3Make(0, -0.5, 0);
        PTKKartVisual visual;
        memset(&visual, 0, sizeof(visual));
        visual.position = kart.root.position;
        visual.previousPosition = kart.root.position;
        visual.grounded = YES;
        visual.boost = (i == 1) ? 2.0 : 0;
        [kart applyVisual:visual alpha:1 dt:1.0 / 60.0 time:time];
        [row addChildNode:kart.root];
      }
    }

    SCNNode *camera = [SCNNode node];
    camera.camera = [SCNCamera camera];
    camera.camera.zNear = 0.1;
    camera.camera.zFar = 900;
    camera.camera.fieldOfView = 64;
    SCNVector3 focus = data.start ? data.start.position : SCNVector3Zero;
    SCNVector3 forward = SCNVector3Make(sin(data.start ? data.start.yaw : 0), 0, cos(data.start ? data.start.yaw : 0));
    if ([view isEqualToString:@"karts"]) {
      camera.position = SCNVector3Make(0, 2.4, 8.2);
      focus = SCNVector3Make(0, 1.0, 0);
      camera.camera.fieldOfView = 46;
    } else if ([view isEqualToString:@"aerial"]) {
      camera.position = SCNVector3Make(focus.x - forward.x * 55 + 25, 78, focus.z - forward.z * 55 + 25);
      camera.camera.fieldOfView = 62;
    } else if ([view isEqualToString:@"top"]) {
      camera.position = SCNVector3Make(0, 330, 0);
      camera.camera.fieldOfView = 60;
      focus = SCNVector3Zero;
    } else if ([view isEqualToString:@"chase"]) {
      camera.position = SCNVector3Make(focus.x - forward.x * 9.5, focus.y + 3.4, focus.z - forward.z * 9.5);
      focus = SCNVector3Make(focus.x + forward.x * 12, focus.y + 1.2, focus.z + forward.z * 12);
      camera.camera.fieldOfView = 70;
    } else {
      camera.position = SCNVector3Make(focus.x - forward.x * 13, focus.y + 5.5, focus.z - forward.z * 13);
      focus = SCNVector3Make(focus.x + forward.x * 6, focus.y + 1.0, focus.z + forward.z * 6);
    }
    [camera lookAt:focus up:SCNVector3Make(0, 1, 0) localFront:SCNVector3Make(0, 0, -1)];
    [scene.rootNode addChildNode:camera];

    SCNRenderer *renderer = [SCNRenderer rendererWithDevice:nil options:nil];
    renderer.scene = scene;
    renderer.pointOfView = camera;
    renderer.autoenablesDefaultLighting = NO;

    CGSize size = CGSizeMake(width, height);
    NSImage *image = [renderer snapshotAtTime:time withSize:size antialiasingMode:SCNAntialiasingModeMultisampling4X];
    if (!image) {
      fprintf(stderr, "离屏渲染失败（snapshotAtTime 返回 nil）\n");
      return 1;
    }
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    NSURL *url = [NSURL fileURLWithPath:outPath];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    if (!destination) {
      fprintf(stderr, "无法写入 %s\n", outPath.UTF8String);
      return 1;
    }
    CGImageDestinationAddImage(destination, cgImage, NULL);
    bool ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    printf("%s 视图 → %s (%.0fx%.0f) %s\n", view.UTF8String, outPath.UTF8String, width, height, ok ? "OK" : "失败");
    return ok ? 0 : 1;
  }
}
