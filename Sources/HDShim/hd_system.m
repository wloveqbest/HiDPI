//
//  hd_system.m — 合盖状态、防睡眠断言、重新枚举、EDID 身份
//

#import "hd.h"
#import "hd_internal.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <dlfcn.h>

static void *skyLightHandle(void) {
  static void *handle = NULL;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                    RTLD_LAZY | RTLD_LOCAL);
  });
  return handle;
}

void *hd_resolve_cgs(const char *name) {
  void *handle = skyLightHandle();
  if (handle == NULL) {
    return NULL;
  }
  return dlsym(handle, name);
}

#pragma mark - 合盖状态与防睡眠

static CFTypeRef findClamshellValue(io_registry_entry_t entry, int depth) {
  if (depth > 8) {
    return NULL;
  }
  CFTypeRef value = IORegistryEntryCreateCFProperty(entry, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
  if (value != NULL) {
    return value;
  }
  io_iterator_t children = 0;
  if (IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) != KERN_SUCCESS) {
    return NULL;
  }
  io_registry_entry_t child = 0;
  CFTypeRef result = NULL;
  while (!result && (child = IOIteratorNext(children)) != 0) {
    result = findClamshellValue(child, depth + 1);
    IOObjectRelease(child);
  }
  IOObjectRelease(children);
  return result;
}

int hd_clamshell_closed(void) {
  io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
  if (root == 0) {
    return -1;
  }
  CFTypeRef value = findClamshellValue(root, 0);
  IOObjectRelease(root);
  if (value == NULL) {
    return -1;
  }
  int closed = -1;
  if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
    closed = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
  } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
    int number = 0;
    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
    closed = number ? 1 : 0;
  }
  CFRelease(value);
  return closed;
}

static IOPMAssertionID gSleepAssertion = 0;

int hd_prevent_sleep(int enable) {
  if (enable) {
    if (gSleepAssertion != 0) {
      return 0;
    }
    IOReturn result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("HiDPI: keep display awake"),
        &gSleepAssertion);
    return result == kIOReturnSuccess ? 0 : -1;
  }
  if (gSleepAssertion != 0) {
    IOPMAssertionRelease(gSleepAssertion);
    gSleepAssertion = 0;
  }
  return 0;
}

int hd_sleep_prevented(void) {
  return gSleepAssertion != 0 ? 1 : 0;
}

typedef void (*SLSDetectDisplaysFn)(void);

int hd_detect_displays(void) {
  SLSDetectDisplaysFn fn = (SLSDetectDisplaysFn)hd_resolve_cgs("SLSDetectDisplays");
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
