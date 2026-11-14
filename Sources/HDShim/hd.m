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
