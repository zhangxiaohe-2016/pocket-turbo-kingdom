#import "PTKTrackData.h"
#import <CoreText/CoreText.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

static const uint32_t kPTKMagic = 0x474b5450; // 'PTKG' little-endian

#pragma mark - 颜色与图元

id PTKColor(CGFloat r, CGFloat g, CGFloat b) {
#if TARGET_OS_IPHONE
  return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
#else
  return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
#endif
}

id PTKColorHex(NSInteger hex) {
  return PTKColor(((hex >> 16) & 0xff) / 255.0, ((hex >> 8) & 0xff) / 255.0, (hex & 0xff) / 255.0);
}

SCNMaterial *PTKMaterial(id color, CGFloat specular) {
  SCNMaterial *m = [SCNMaterial material];
  m.lightingModelName = SCNLightingModelBlinn;
  m.diffuse.contents = color;
  m.specular.contents = PTKColor(specular, specular, specular);
  m.shininess = MAX(0.02, specular);
  return m;
}

static id PTKColorAlpha(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
#if TARGET_OS_IPHONE
  return [UIColor colorWithRed:r green:g blue:b alpha:a];
#else
  return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
#endif
}

static SCNMaterial *PTKMaterialWithColor(id color) {
  SCNMaterial *m = [SCNMaterial material];
  m.lightingModelName = SCNLightingModelBlinn;
  m.diffuse.contents = color;
  m.specular.contents = PTKColor(0.12, 0.12, 0.12);
  m.shininess = 0.12;
  return m;
}

static SCNNode *PTKNodeForGeometry(SCNGeometry *geometry, id color) {
  SCNNode *node = [SCNNode nodeWithGeometry:geometry];
  node.geometry.materials = @[ PTKMaterialWithColor(color) ];
  return node;
}

SCNNode *PTKBoxNode(CGFloat w, CGFloat h, CGFloat d, id color) {
  return PTKNodeForGeometry([SCNBox boxWithWidth:w height:h length:d chamferRadius:0], color);
}

SCNNode *PTKCylinderNode(CGFloat radius, CGFloat height, id color) {
  return PTKNodeForGeometry([SCNCylinder cylinderWithRadius:radius height:height], color);
}

SCNNode *PTKSphereNode(CGFloat radius, id color) {
  return PTKNodeForGeometry([SCNSphere sphereWithRadius:radius], color);
}

SCNNode *PTKConeNode(CGFloat radius, CGFloat height, id color) {
  return PTKNodeForGeometry([SCNCone coneWithTopRadius:0 bottomRadius:radius height:height], color);
}

#pragma mark - 模型

@implementation PTKGeoNode
@end

@implementation PTKSign
@end

@implementation PTKAnchor
- (instancetype)init {
  if ((self = [super init])) _kind = @"anchor";
  return self;
}
@end

@implementation PTKTrackSample
@end

@implementation PTKKartSpec
+ (instancetype)specFromDictionary:(NSDictionary *)dict {
  PTKKartSpec *spec = [PTKKartSpec new];
  spec.kartId = dict[@"id"] ?: @"";
  spec.name = dict[@"name"] ?: @"";
  spec.title = dict[@"title"] ?: @"";
  spec.vehicle = dict[@"vehicle"] ?: @"";
  spec.type = dict[@"type"] ?: @"";
  spec.color = [dict[@"color"] integerValue];
  spec.accent = [dict[@"accent"] integerValue];
  return spec;
}
@end

#pragma mark - 资产读取

@implementation PTKTrackData

static SCNVector3 PTKVector3(NSArray *a) {
  if (![a isKindOfClass:NSArray.class] || a.count < 3) return SCNVector3Zero;
  return SCNVector3Make([a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue]);
}

static SCNMatrix4 PTKMatrix4(NSArray *e) {
  if (![e isKindOfClass:NSArray.class] || e.count < 16) return SCNMatrix4Identity;
  SCNMatrix4 m;
  // three 是列主序：elements[(col)*4 + row]
  m.m11 = [e[0] floatValue];  m.m12 = [e[1] floatValue];  m.m13 = [e[2] floatValue];  m.m14 = [e[3] floatValue];
  m.m21 = [e[4] floatValue];  m.m22 = [e[5] floatValue];  m.m23 = [e[6] floatValue];  m.m24 = [e[7] floatValue];
  m.m31 = [e[8] floatValue];  m.m32 = [e[9] floatValue];  m.m33 = [e[10] floatValue]; m.m34 = [e[11] floatValue];
  m.m41 = [e[12] floatValue]; m.m42 = [e[13] floatValue]; m.m43 = [e[14] floatValue]; m.m44 = [e[15] floatValue];
  return m;
}

+ (instancetype)dataWithContentsOfFile:(NSString *)path error:(NSError **)error {
  NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
  if (!file) return nil;
  if (file.length < 12) {
    if (error) *error = [NSError errorWithDomain:@"PTKTrackData" code:1 userInfo:@{ NSLocalizedDescriptionKey: @"几何文件过短" }];
    return nil;
  }
  const uint8_t *bytes = file.bytes;
  uint32_t magic, version, jsonLength;
  memcpy(&magic, bytes, 4);
  memcpy(&version, bytes + 4, 4);
  memcpy(&jsonLength, bytes + 8, 4);
  if (magic != kPTKMagic || version != 1 || 12 + jsonLength > file.length) {
    if (error) *error = [NSError errorWithDomain:@"PTKTrackData" code:2 userInfo:@{ NSLocalizedDescriptionKey: @"几何文件头无效" }];
    return nil;
  }
  NSData *jsonData = [file subdataWithRange:NSMakeRange(12, jsonLength)];
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:error];
  if (![json isKindOfClass:NSDictionary.class]) return nil;
  NSUInteger payloadStart = 12 + jsonLength;

  // 按 key 建材质，多个 node 共享同一材质实例
  NSMutableDictionary<NSString *, SCNMaterial *> *materials = [NSMutableDictionary dictionary];
  for (NSDictionary *rec in json[@"materials"]) {
    if (![rec isKindOfClass:NSDictionary.class]) continue;
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelBlinn;
    NSArray *color = rec[@"color"];
    m.diffuse.contents = PTKColor([color[0] doubleValue], [color[1] doubleValue], [color[2] doubleValue]);
    double metalness = [rec[@"metalness"] doubleValue];
    double roughness = [rec[@"roughness"] doubleValue];
    double spec = (0.08 + metalness * 0.85) * (1.0 - roughness * 0.7);
    m.specular.contents = PTKColor(spec, spec, spec);
    m.shininess = MAX(0.02, 1.0 - roughness);
    m.doubleSided = [rec[@"doubleSided"] boolValue];
    if (rec[@"emissive"] != nil && rec[@"emissive"] != [NSNull null]) {
      NSArray *e = rec[@"emissive"];
      m.emission.contents = PTKColor([e[0] doubleValue], [e[1] doubleValue], [e[2] doubleValue]);
    }
    if ([rec[@"transparent"] boolValue]) {
      CGFloat opacity = rec[@"opacity"] ? [rec[@"opacity"] doubleValue] : 0.85;
      m.transparency = opacity;
      m.transparencyMode = SCNTransparencyModeRGBZero;
      m.blendMode = SCNBlendModeAlpha;
      m.writesToDepthBuffer = NO;
      m.diffuse.contents = PTKColorAlpha([color[0] doubleValue], [color[1] doubleValue], [color[2] doubleValue], 1.0);
    }
    materials[rec[@"key"]] = m;
  }

  NSMutableArray<PTKGeoNode *> *nodes = [NSMutableArray array];
  NSUInteger triangles = 0;
  for (NSDictionary *rec in json[@"nodes"]) {
    if (![rec isKindOfClass:NSDictionary.class]) continue;
    NSDictionary *pos = rec[@"position"], *nrm = rec[@"normal"], *col = rec[@"color"], *idx = rec[@"indices"];
    if (!pos || !nrm || !idx) continue;
    NSUInteger vertexCount = [pos[@"count"] unsignedIntegerValue];
    NSUInteger indexCount = [idx[@"count"] unsignedIntegerValue];
    if (!vertexCount || !indexCount) continue;

    NSData *positions = [file subdataWithRange:NSMakeRange(payloadStart + [pos[@"offset"] unsignedIntegerValue], vertexCount * 12)];
    NSData *normals = [file subdataWithRange:NSMakeRange(payloadStart + [nrm[@"offset"] unsignedIntegerValue], vertexCount * 12)];
    NSData *indices = [file subdataWithRange:NSMakeRange(payloadStart + [idx[@"offset"] unsignedIntegerValue], indexCount * 4)];
    NSMutableArray<SCNGeometrySource *> *sources = [NSMutableArray array];
    [sources addObject:[SCNGeometrySource geometrySourceWithData:positions semantic:SCNGeometrySourceSemanticVertex
                                               vectorCount:vertexCount floatComponents:YES componentsPerVector:3
                                          bytesPerComponent:4 dataOffset:0 dataStride:12]];
    [sources addObject:[SCNGeometrySource geometrySourceWithData:normals semantic:SCNGeometrySourceSemanticNormal
                                               vectorCount:vertexCount floatComponents:YES componentsPerVector:3
                                          bytesPerComponent:4 dataOffset:0 dataStride:12]];
    if (col != nil && col != (id)[NSNull null]) {
      NSData *colors = [file subdataWithRange:NSMakeRange(payloadStart + [col[@"offset"] unsignedIntegerValue], vertexCount * 12)];
      [sources addObject:[SCNGeometrySource geometrySourceWithData:colors semantic:SCNGeometrySourceSemanticColor
                                               vectorCount:vertexCount floatComponents:YES componentsPerVector:3
                                          bytesPerComponent:4 dataOffset:0 dataStride:12]];
    }
    SCNGeometryElement *element = [SCNGeometryElement geometryElementWithData:indices
                                                                primitiveType:SCNGeometryPrimitiveTypeTriangles
                                                               primitiveCount:indexCount / 3
                                                                bytesPerIndex:4];
    SCNGeometry *geometry = [SCNGeometry geometryWithSources:sources elements:@[ element ]];
    SCNMaterial *material = materials[rec[@"material"]];
    if (material == nil) {
      material = [SCNMaterial material];
      material.lightingModelName = SCNLightingModelBlinn;
      material.diffuse.contents = PTKColor(0.8, 0.8, 0.8);
    }
    geometry.materials = @[ material ];
    PTKGeoNode *node = [PTKGeoNode new];
    node.name = rec[@"name"] ?: @"geometry";
    node.materialKey = rec[@"material"] ?: @"";
    node.geometry = geometry;
    node.material = material;
    [nodes addObject:node];
    triangles += indexCount / 3;
  }

  PTKTrackData *data = [PTKTrackData new];
  data.nodes = nodes;
  data.triangleCount = triangles;
  NSMutableArray<PTKSign *> *signs = [NSMutableArray array];
  for (NSDictionary *rec in json[@"signs"]) {
    PTKSign *sign = [PTKSign new];
    sign.text = rec[@"text"] ?: @"";
    sign.color = rec[@"color"] ?: @"#fff1ca";
    sign.width = [rec[@"width"] doubleValue];
    sign.height = [rec[@"height"] doubleValue];
    sign.transform = PTKMatrix4(rec[@"transform"]);
    [signs addObject:sign];
  }
  data.signs = signs;

  NSDictionary *anchors = json[@"anchors"];
  NSMutableArray<PTKAnchor *> *boxes = [NSMutableArray array];
  for (NSDictionary *rec in anchors[@"boxes"]) {
    PTKAnchor *a = [PTKAnchor new];
    a.kind = @"box";
    a.position = PTKVector3(rec[@"p"]);
    a.t = [rec[@"t"] doubleValue];
    a.lane = [rec[@"lane"] doubleValue];
    [boxes addObject:a];
  }
  NSMutableArray<PTKAnchor *> *obstacles = [NSMutableArray array];
  for (NSDictionary *rec in anchors[@"obstacles"]) {
    PTKAnchor *a = [PTKAnchor new];
    a.kind = @"obstacle";
    a.position = PTKVector3(rec[@"p"]);
    a.right = PTKVector3(rec[@"right"]);
    a.t = [rec[@"t"] doubleValue];
    a.phase = [rec[@"phase"] doubleValue];
    [obstacles addObject:a];
  }
  NSMutableArray<PTKAnchor *> *boostPads = [NSMutableArray array];
  for (NSDictionary *rec in anchors[@"boostPads"]) {
    PTKAnchor *a = [PTKAnchor new];
    a.kind = @"boost";
    a.position = PTKVector3(rec[@"p"]);
    a.t = [rec[@"t"] doubleValue];
    a.yaw = [rec[@"yaw"] doubleValue];
    a.bank = [rec[@"bank"] doubleValue];
    [boostPads addObject:a];
  }
  data.boxes = boxes;
  data.obstacles = obstacles;
  data.boostPads = boostPads;
  NSDictionary *startRec = anchors[@"start"];
  if (startRec) {
    PTKAnchor *a = [PTKAnchor new];
    a.kind = @"start";
    a.position = PTKVector3(startRec[@"p"]);
    a.yaw = [startRec[@"yaw"] doubleValue];
    data.start = a;
  }
  NSDictionary *trackRec = anchors[@"track"];
  data.halfWidth = trackRec ? [trackRec[@"halfWidth"] doubleValue] : 7.8;
  data.arena = [trackRec[@"arena"] boolValue];
  NSMutableArray<PTKTrackSample *> *samples = [NSMutableArray array];
  for (NSDictionary *rec in trackRec[@"samples"]) {
    if (![rec isKindOfClass:NSDictionary.class]) continue;
    PTKTrackSample *sample = [PTKTrackSample new];
    sample.position = PTKVector3(rec[@"p"]);
    sample.yaw = [rec[@"yaw"] doubleValue];
    sample.bank = [rec[@"bank"] doubleValue];
    sample.t = [rec[@"t"] doubleValue];
    [samples addObject:sample];
  }
  data.trackSamples = samples;

  NSMutableArray<PTKKartSpec *> *karts = [NSMutableArray array];
  for (NSDictionary *rec in json[@"karts"]) {
    if ([rec isKindOfClass:NSDictionary.class]) [karts addObject:[PTKKartSpec specFromDictionary:rec]];
  }
  data.karts = karts;
  return data;
}

- (SCNNode *)buildStaticScene {
  SCNNode *root = [SCNNode node];
  root.name = self.arena ? @"arena" : @"track";
  for (PTKGeoNode *geo in self.nodes) {
    SCNNode *node = [SCNNode nodeWithGeometry:geo.geometry];
    node.name = geo.name;
    [root addChildNode:node];
  }
  for (PTKSign *sign in self.signs) {
    SCNNode *node = [self signNodeForSign:sign];
    if (node) [root addChildNode:node];
  }
  return root;
}

- (SCNNode *)signNodeForSign:(PTKSign *)sign {
  id image = [PTKTrackData textImageForSign:sign scale:2.0];
  SCNPlane *plane = [SCNPlane planeWithWidth:MAX(0.5, sign.width) height:MAX(0.2, sign.height)];
  SCNMaterial *material = [SCNMaterial material];
  material.lightingModelName = SCNLightingModelConstant;
  material.diffuse.contents = image;
  material.transparent.contents = image;
  material.transparencyMode = SCNTransparencyModeAOne;
  material.blendMode = SCNBlendModeAlpha;
  material.doubleSided = YES;
  material.writesToDepthBuffer = NO;
  plane.materials = @[ material ];
  SCNNode *node = [SCNNode nodeWithGeometry:plane];
  node.name = [@"sign:" stringByAppendingString:sign.text];
  node.transform = sign.transform;
  return node;
}

+ (id)textImageForSign:(PTKSign *)sign scale:(CGFloat)scale {
  NSInteger w = (NSInteger)MAX(64, 512 * scale), h = (NSInteger)MAX(32, 128 * scale);
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (!ctx) return nil;
  CGContextClearRect(ctx, CGRectMake(0, 0, w, h));

  unsigned int r = 255, g = 241, b = 202;
  if (sign.color.length >= 7) {
    unsigned int packed = 0;
    sscanf(sign.color.UTF8String + 1, "%6x", &packed);
    r = (packed >> 16) & 0xff; g = (packed >> 8) & 0xff; b = packed & 0xff;
  }
  // CGColorCreateGenericRGB 是 iOS 13+，iOS 12 上必须走 CGColorCreate + sRGB 色彩空间
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  const CGFloat components[4] = { r / 255.0, g / 255.0, b / 255.0, 1.0 };
  CGColorRef color = CGColorCreate(srgb, components);
  CGColorSpaceRelease(srgb);
  // 字号自适应：从 0.62h 起按宽度收敛，保证长文案（POCKET TURBO）不被裁掉
  CGFloat fontSize = h * 0.62;
  CTFontRef font = NULL;
  CTLineRef line = NULL;
  CGRect bounds = CGRectZero;
  for (int attempt = 0; attempt < 16; attempt++) {
    if (font) CFRelease(font);
    if (line) CFRelease(line);
    font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), fontSize, NULL);
    NSDictionary *attrs = @{ (__bridge id)kCTFontAttributeName: (__bridge id)font,
                             (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color };
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:sign.text attributes:attrs];
    line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    bounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    if (bounds.size.width <= w * 0.90) break;
    fontSize *= 0.88;
  }
  CGContextSetTextPosition(ctx, (w - bounds.size.width) / 2.0 - bounds.origin.x, (h - bounds.size.height) / 2.0 - bounds.origin.y);
  CTLineDraw(line, ctx);
  CGImageRef image = CGBitmapContextCreateImage(ctx);
  CFRelease(line);
  CFRelease(font);
  CGColorRelease(color);
  CGContextRelease(ctx);
#if TARGET_OS_IPHONE
  id result = [UIImage imageWithCGImage:image];
#else
  id result = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(w, h)];
#endif
  CGImageRelease(image);
  return result;
}

@end
