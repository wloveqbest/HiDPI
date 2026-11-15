//
//  hd_modes.m — 显示模式枚举、切换、软件断开/重连
//

#import "hd.h"
#import "hd_internal.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

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

int hd_display_mode_count(uint32_t displayID) {
  CGSGetNumberOfDisplayModesFn fn = (CGSGetNumberOfDisplayModesFn)hd_resolve_cgs("CGSGetNumberOfDisplayModes");
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
      (CGSGetDisplayModeDescriptionFn)hd_resolve_cgs("CGSGetDisplayModeDescriptionOfLength");
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
  CGSGetCurrentDisplayModeFn fn = (CGSGetCurrentDisplayModeFn)hd_resolve_cgs("CGSGetCurrentDisplayMode");
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
      (CGSConfigureDisplayEnabledFn)hd_resolve_cgs("CGSConfigureDisplayEnabled");
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

int hd_display_set_mode(uint32_t displayID, int index) {
  CGSConfigureDisplayModeFn configure = (CGSConfigureDisplayModeFn)hd_resolve_cgs("CGSConfigureDisplayMode");
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
