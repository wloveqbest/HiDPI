//
//  hd_color.m — ColorSync 颜色描述文件
//

#import "hd.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>
#include <string.h>

/// 只接受「显示器类 + RGB 数据空间」的 profile：
///   头 12–15 字节 = "mntr"，16–19 字节 = "RGB "
/// 抽象类（abst，如 Sepia Tone）、色彩空间类（spac）、灰度（GRAY）都会让
/// ColorSync 内部断言直接 abort，且无法用 @try/@catch 拦截。
static BOOL isDisplayProfile(NSString *path) {
  NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
  if (handle == nil) {
    return NO;
  }
  NSData *header = [handle readDataOfLength:128];
  [handle closeFile];
  if (header.length < 128) {
    return NO;
  }
  const uint8_t *bytes = header.bytes;
  return memcmp(bytes + 12, "mntr", 4) == 0 && memcmp(bytes + 16, "RGB ", 4) == 0;
}

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
      NSString *fullPath = [dir stringByAppendingPathComponent:file];
      if (([ext isEqualToString:@"icc"] || [ext isEqualToString:@"icm"]) && isDisplayProfile(fullPath)) {
        [found addObject:fullPath];
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
  if (path != NULL) {
    NSString *profilePath = [NSString stringWithUTF8String:path];
    if (!isDisplayProfile(profilePath)) {
      return -5;  // 非显示器类 / 非 RGB，强设会让系统 abort
    }
  }
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
    // 传 NULL 表示清除自定义描述文件，回到系统默认
    bool cleared = false;
    @try {
      cleared = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, uuid, NULL);
    } @catch (NSException *exception) {
      NSLog(@"[hidpi] 清除自定义描述文件失败: %@", exception.reason);
    }
    if (cleared) {
      CFRelease(uuid);
      return 0;
    }
    info = factoryProfileInfo(uuid);
  }
  bool ok = false;
  @try {
    ok = info != nil
        && ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, uuid, (__bridge CFDictionaryRef)info);
  } @catch (NSException *exception) {
    NSLog(@"[hidpi] ColorSync 拒绝了该描述文件: %@", exception.reason);
    ok = false;
  }
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
  CFDictionaryRef info = NULL;
  @try {
    info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass, uuid);
  } @catch (NSException *exception) {
    NSLog(@"[hidpi] 读取 ColorSync 设备信息失败: %@", exception.reason);
  }
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
