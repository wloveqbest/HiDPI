//
//  HDShim — macOS 私有显示 API 的最小封装层
//
//  CGVirtualDisplay 系列类的声明与调用方式参考自
//  BetterDummy OpenSource Edition (MIT, Copyright (c) 2021 Istvan T.)
//  https://github.com/waydabber/BetterDisplay/tree/opensource
//
//  CGS* 函数不在公开 SDK 中：这里用 dlopen/dlsym 在运行时解析，
//  避免把整个工具绑死在任何私有框架的链接上。
//

#import "hd.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <ColorSync/ColorSync.h>
#import <dlfcn.h>
#include <math.h>
#include <string.h>

#pragma mark - 私有类型声明

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) uint32_t maxPixelsWide;
@property(nonatomic) uint32_t maxPixelsHigh;
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t serialNum;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(nonatomic, strong) id queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) uint32_t hiDPI;
@property(nonatomic, strong) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) uint32_t displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

/// 私有 CGSDisplayMode 结构（212 字节）的字段镜像
typedef struct {
  uint32_t modeNumber;
  uint32_t flags;
  uint32_t width;
  uint32_t height;
  uint32_t depth;
  uint8_t unknown[170];
  uint16_t freq;
  uint8_t moreUnknown[16];
  float density;
} CGSDisplayModeRaw;

typedef void (*CGSGetNumberOfDisplayModesFn)(uint32_t, int *);
typedef void (*CGSGetCurrentDisplayModeFn)(uint32_t, int *);
typedef void (*CGSGetDisplayModeDescriptionFn)(uint32_t, int, void *, int);
typedef void (*CGSConfigureDisplayModeFn)(CGDisplayConfigRef, uint32_t, int);

#pragma mark - 状态

/// 强引用所有已创建的虚拟显示器，避免被 ARC 回收（回收即断开连接）
static NSMutableArray<CGVirtualDisplay *> *gVirtualDisplays = nil;

static void *skyLightHandle(void) {
  static void *handle = NULL;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                    RTLD_LAZY | RTLD_LOCAL);
  });
  return handle;
}

static void *resolveCGS(const char *name) {
  void *handle = skyLightHandle();
  if (handle == NULL) {
    return NULL;
  }
  return dlsym(handle, name);
}

#pragma mark - 虚拟显示器

int hd_create_virtual_display(uint32_t logicalWidth,
                              uint32_t logicalHeight,
                              double refreshRate,
                              const char *name,
                              int hiDPI) {
  if (logicalWidth < 320 || logicalHeight < 240) {
    return 0;
  }

  @autoreleasepool {
    // 私有类在运行时才存在，先确认可用性，失败时给出明确原因而不是崩在 msgSend
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (descriptorClass == Nil || displayClass == Nil || modeClass == Nil || settingsClass == Nil) {
      return 0;
    }

    uint32_t scale = hiDPI ? 2 : 1;

    CGVirtualDisplayDescriptor *descriptor = [(CGVirtualDisplayDescriptor *)[descriptorClass alloc] init];
    if (descriptor == nil) {
      return 0;
    }
    descriptor.name = name ? [NSString stringWithUTF8String:name] : @"HiDPI Display";
    descriptor.maxPixelsWide = logicalWidth * scale;
    descriptor.maxPixelsHigh = logicalHeight * scale;
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);

    // 色彩主坐标取自 Generic RGB Profile.icc（与 BetterDummy 一致）
    descriptor.whitePoint = CGPointMake(0.950, 1.000);
    descriptor.redPrimary = CGPointMake(0.454, 0.242);
    descriptor.greenPrimary = CGPointMake(0.353, 0.674);
    descriptor.bluePrimary = CGPointMake(0.157, 0.084);

    // 以 24 英寸对角线反推物理尺寸，让 macOS 计算出合理的 DPI
    double diagonalMM = 24.0 * 25.4;
    double aspect = sqrt((double)logicalWidth * logicalWidth + (double)logicalHeight * logicalHeight);
    double unit = diagonalMM / aspect;
    descriptor.sizeInMillimeters = CGSizeMake((double)logicalWidth * unit, (double)logicalHeight * unit);

    descriptor.vendorID = 0xF0F0;
    descriptor.productID = (uint32_t)((logicalWidth & 0xFF) << 8 | (logicalHeight & 0xFF));
    descriptor.serialNum = (uint32_t)arc4random();

    CGVirtualDisplay *display = [(CGVirtualDisplay *)[displayClass alloc] initWithDescriptor:descriptor];
    if (display == nil) {
      return 0;
    }

    // 提供几档逻辑分辨率，用户可在系统设置里挑选
    NSMutableArray *modes = [NSMutableArray array];
    NSArray<NSNumber *> *scales = @[ @0.5, @0.75, @1.0 ];
    for (NSNumber *factor in scales) {
      uint32_t w = (uint32_t)lround((double)logicalWidth * factor.doubleValue);
      uint32_t h = (uint32_t)lround((double)logicalHeight * factor.doubleValue);
      CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:w
                                                             height:h
                                                        refreshRate:refreshRate];
      if (mode != nil) {
        [modes addObject:mode];
      }
    }
    if (modes.count == 0) {
      return 0;
    }

    CGVirtualDisplaySettings *settings = [(CGVirtualDisplaySettings *)[settingsClass alloc] init];
    if (settings == nil) {
      return 0;
    }
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = modes;

    if (![display applySettings:settings]) {
      return 0;
    }

    if (gVirtualDisplays == nil) {
      gVirtualDisplays = [NSMutableArray array];
    }
    [gVirtualDisplays addObject:display];
    return display.displayID;
  }
}

void hd_release_virtual_displays(void) {
  @autoreleasepool {
    [gVirtualDisplays removeAllObjects];
    gVirtualDisplays = nil;
  }
}

int hd_virtual_display_count(void) {
  return (int)gVirtualDisplays.count;
}

#pragma mark - 显示模式

#pragma mark - 亮度（gamma 软件调光）

// 原始 gamma 表落盘保存，否则每次新进程都会把"当前"当成原始值
static NSString *gammaStorePath(uint32_t displayID) {
  NSArray<NSString *> *dirs =
      NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
  NSString *dir = [dirs.firstObject stringByAppendingPathComponent:@"hidpi"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"gamma-%u.bin", displayID]];
}

static NSData *loadOriginalGamma(uint32_t displayID, UInt32 *sampleCount) {
  NSData *data = [NSData dataWithContentsOfFile:gammaStorePath(displayID)];
  if (data.length < sizeof(UInt32)) {
    return nil;
  }
  UInt32 n = 0;
  [data getBytes:&n range:NSMakeRange(0, sizeof(UInt32))];
  size_t expected = sizeof(UInt32) + n * sizeof(CGGammaValue) * 3;
  if (n == 0 || n > 4096 || data.length != expected) {
    return nil;
  }
  if (sampleCount) {
    *sampleCount = n;
  }
  return data;
}

static BOOL saveOriginalGamma(uint32_t displayID, UInt32 n,
                              const CGGammaValue *red, const CGGammaValue *green, const CGGammaValue *blue) {
  NSMutableData *data = [NSMutableData data];
  [data appendBytes:&n length:sizeof(UInt32)];
  [data appendBytes:red length:n * sizeof(CGGammaValue)];
  [data appendBytes:green length:n * sizeof(CGGammaValue)];
  [data appendBytes:blue length:n * sizeof(CGGammaValue)];
  return [data writeToFile:gammaStorePath(displayID) atomically:YES];
}

int hd_set_brightness(uint32_t displayID, float level) {
  if (level < 0.05f) {
    level = 0.05f;
  }
  if (level > 1.0f) {
    level = 1.0f;
  }

  const UInt32 capacity = 1024;
  CGGammaValue red[1024], green[1024], blue[1024];
  UInt32 sampleCount = 0;

  UInt32 originalCount = 0;
  NSData *original = loadOriginalGamma(displayID, &originalCount);
  const CGGammaValue *baseRed = NULL;
  const CGGammaValue *baseGreen = NULL;
  const CGGammaValue *baseBlue = NULL;

  if (original != nil && originalCount > 0) {
    const uint8_t *bytes = original.bytes;
    baseRed = (const CGGammaValue *)(bytes + sizeof(UInt32));
    baseGreen = (const CGGammaValue *)(bytes + sizeof(UInt32) + originalCount * sizeof(CGGammaValue));
    baseBlue = (const CGGammaValue *)(bytes + sizeof(UInt32) + originalCount * 2 * sizeof(CGGammaValue));
    sampleCount = originalCount;
  } else {
    if (CGGetDisplayTransferByTable((CGDirectDisplayID)displayID, capacity, red, green, blue, &sampleCount)
            != kCGErrorSuccess
        || sampleCount == 0) {
      return -1;
    }
    saveOriginalGamma(displayID, sampleCount, red, green, blue);
    baseRed = red;
    baseGreen = green;
    baseBlue = blue;
  }

  CGGammaValue outRed[1024], outGreen[1024], outBlue[1024];
  for (UInt32 i = 0; i < sampleCount; i++) {
    outRed[i] = baseRed[i] * level;
    outGreen[i] = baseGreen[i] * level;
    outBlue[i] = baseBlue[i] * level;
  }
  CGError error = CGSetDisplayTransferByTable((CGDirectDisplayID)displayID, sampleCount, outRed, outGreen, outBlue);
  return error == kCGErrorSuccess ? 0 : -2;
}

float hd_get_brightness(uint32_t displayID) {
  const UInt32 capacity = 1024;
  CGGammaValue red[1024], green[1024], blue[1024];
  UInt32 sampleCount = 0;
  if (CGGetDisplayTransferByTable((CGDirectDisplayID)displayID, capacity, red, green, blue, &sampleCount)
          != kCGErrorSuccess
      || sampleCount == 0) {
    return -1;
  }

  UInt32 originalCount = 0;
  NSData *original = loadOriginalGamma(displayID, &originalCount);
  if (original == nil || originalCount != sampleCount) {
    return 1.0f;
  }
  const CGGammaValue *baseRed = (const CGGammaValue *)((const uint8_t *)original.bytes + sizeof(UInt32));
  UInt32 peak = sampleCount - 1;
  if (baseRed[peak] <= 0) {
    return 1.0f;
  }
  float ratio = red[peak] / baseRed[peak];
  return ratio < 0 ? 0 : (ratio > 1 ? 1 : ratio);
}

#pragma mark - 颜色描述文件

static NSArray<NSString *> *profileDirectories(void) {
  return @[
    @"/System/Library/ColorSync/Profiles",
    @"/Library/ColorSync/Profiles",
    [@"~/Library/ColorSync/Profiles" stringByExpandingTildeInPath],
  ];
}

int hd_list_color_profiles(char ***paths, int *count) {
  if (paths == NULL || count == NULL) {
    return -1;
  }
  NSMutableArray<NSString *> *found = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *dir in profileDirectories()) {
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *file in files) {
      NSString *ext = file.pathExtension.lowercaseString;
      if ([ext isEqualToString:@"icc"] || [ext isEqualToString:@"icm"]) {
        [found addObject:[dir stringByAppendingPathComponent:file]];
      }
    }
  }
  *count = (int)found.count;
  char **result = calloc(found.count, sizeof(char *));
  for (NSUInteger i = 0; i < found.count; i++) {
    result[i] = strdup(found[i].UTF8String);
  }
  *paths = result;
  return 0;
}

void hd_free_profiles(char **paths, int count) {
  if (paths == NULL) {
    return;
  }
  for (int i = 0; i < count; i++) {
    free(paths[i]);
  }
  free(paths);
}

/// 读出该显示器的默认 profile 标识与工厂 profile 的 URL
static NSDictionary *factoryProfileInfo(CFUUIDRef uuid) {
  CFDictionaryRef info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass, uuid);
  if (info == NULL) {
    return nil;
  }
  NSDictionary *dict = (__bridge NSDictionary *)info;
  NSDictionary *factory = dict[@"FactoryProfiles"];
  NSString *defaultID = factory[@"DeviceDefaultProfileID"];
  NSDictionary *entry = defaultID ? factory[defaultID] : nil;
  NSURL *url = entry[@"DeviceProfileURL"];
  NSDictionary *result = nil;
  if (defaultID != nil && url != nil) {
    result = @{defaultID: url};
  }
  CFRelease(info);
  return result;
}

int hd_apply_color_profile(uint32_t displayID, const char *path) {
  CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID((CGDirectDisplayID)displayID);
  if (uuid == NULL) {
    return -1;
  }
  NSDictionary *info = nil;
  if (path != NULL) {
    info = @{(__bridge id)kColorSyncDeviceDefaultProfileID
             : [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]]};
    // 上面这种写法用错了 key，改用「profile 标识 -> URL」的形式
    NSDictionary *factory = factoryProfileInfo(uuid);
    if (factory != nil) {
      info = @{factory.allKeys.firstObject: [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]]};
    }
  } else {
    info = factoryProfileInfo(uuid);
  }
  bool ok = info != nil
      && ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, uuid, (__bridge CFDictionaryRef)info);
  CFRelease(uuid);
  return ok ? 0 : -2;
}

/// CFURL / NSString / NSURL 统一转成文件路径
static NSString *pathFromProfileValue(id value) {
  if ([value isKindOfClass:[NSURL class]]) {
    return [(NSURL *)value path];
  }
  if ([value isKindOfClass:[NSString class]]) {
    NSString *text = (NSString *)value;
    if ([text hasPrefix:@"file://"]) {
      return [(NSURL *)[NSURL URLWithString:text] path];
    }
    return text;
  }
  return nil;
}

char *hd_current_color_profile(uint32_t displayID) {
  CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID((CGDirectDisplayID)displayID);
  if (uuid == NULL) {
    return NULL;
  }
  CFDictionaryRef info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass, uuid);
  CFRelease(uuid);
  if (info == NULL) {
    return NULL;
  }

  NSDictionary *dict = (__bridge NSDictionary *)info;
  char *result = NULL;

  NSDictionary *custom = dict[@"CustomProfiles"];
  NSDictionary *factory = dict[@"FactoryProfiles"];
  NSString *defaultID = factory[@"DeviceDefaultProfileID"];
  NSString *factoryPath = pathFromProfileValue(factory[defaultID][@"DeviceProfileURL"]);

  if ([custom isKindOfClass:[NSDictionary class]] && custom.count > 0) {
    NSString *customPath = pathFromProfileValue([custom allValues].firstObject);
    // 与工厂 profile 相同即视为系统默认
    if (customPath.length > 0 && (factoryPath == nil || ![factoryPath isEqualToString:customPath])) {
      result = strdup(customPath.UTF8String);
    }
  }
  CFRelease(info);
  return result;
}

int hd_display_mode_count(uint32_t displayID) {
  CGSGetNumberOfDisplayModesFn fn = (CGSGetNumberOfDisplayModesFn)resolveCGS("CGSGetNumberOfDisplayModes");
  if (fn == NULL) {
    return -1;
  }
  int count = 0;
  fn(displayID, &count);
  return count;
}

int hd_display_mode_at(uint32_t displayID, int index, hd_mode_t *out) {
  if (out == NULL) {
    return -1;
  }
  CGSGetDisplayModeDescriptionFn fn =
      (CGSGetDisplayModeDescriptionFn)resolveCGS("CGSGetDisplayModeDescriptionOfLength");
  if (fn == NULL) {
    return -1;
  }
  CGSDisplayModeRaw raw;
  memset(&raw, 0, sizeof(raw));
  fn(displayID, index, &raw, (int)sizeof(raw));
  out->modeNumber = raw.modeNumber;
  out->width = raw.width;
  out->height = raw.height;
  out->depth = raw.depth;
  out->refreshRate = (double)raw.freq;
  out->hiDPI = raw.density > 1.0f ? 1 : 0;
  return 0;
}

int hd_display_current_mode(uint32_t displayID) {
  CGSGetCurrentDisplayModeFn fn = (CGSGetCurrentDisplayModeFn)resolveCGS("CGSGetCurrentDisplayMode");
  if (fn == NULL) {
    return -1;
  }
  int current = -1;
  fn(displayID, &current);
  return current;
}

typedef void (*CGSConfigureDisplayEnabledFn)(CGDisplayConfigRef, uint32_t, bool);

int hd_cycle_display(uint32_t displayID, double seconds) {
  CGSConfigureDisplayEnabledFn configure =
      (CGSConfigureDisplayEnabledFn)resolveCGS("CGSConfigureDisplayEnabled");
  if (configure == NULL) {
    return -1;
  }

  CGDisplayConfigRef config = NULL;
  if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || config == NULL) {
    return -1;
  }
  configure(config, displayID, false);
  CGError disableError = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
  if (disableError != kCGErrorSuccess) {
    return -2;
  }

  if (seconds > 0) {
    usleep((useconds_t)(seconds * 1e6));
  }

  // 无论发生什么都要尝试恢复
  CGDisplayConfigRef restore = NULL;
  if (CGBeginDisplayConfiguration(&restore) != kCGErrorSuccess || restore == NULL) {
    return -3;
  }
  configure(restore, displayID, true);
  CGError enableError = CGCompleteDisplayConfiguration(restore, kCGConfigurePermanently);
  return enableError == kCGErrorSuccess ? 0 : -4;
}

typedef void (*SLSDetectDisplaysFn)(void);

int hd_detect_displays(void) {
  SLSDetectDisplaysFn fn = (SLSDetectDisplaysFn)resolveCGS("SLSDetectDisplays");
  if (fn == NULL) {
    return -1;
  }
  fn();
  return 0;
}

uint32_t hd_display_vendor_id(uint32_t displayID) {
  return (uint32_t)CGDisplayVendorNumber(displayID);
}

uint32_t hd_display_product_id(uint32_t displayID) {
  return (uint32_t)CGDisplayModelNumber(displayID);
}

int hd_display_set_mode(uint32_t displayID, int index) {
  CGSConfigureDisplayModeFn configure = (CGSConfigureDisplayModeFn)resolveCGS("CGSConfigureDisplayMode");
  if (configure == NULL) {
    return -1;
  }
  CGDisplayConfigRef config = NULL;
  if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || config == NULL) {
    return -1;
  }
  configure(config, displayID, index);
  CGError error = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
  return error == kCGErrorSuccess ? 0 : -1;
}
