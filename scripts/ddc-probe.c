// DDC 只读探针：枚举 IOAVService 节点，尝试读亮度（VCP 0x10）
// 只发读命令，不会修改任何显示器状态。
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef void *IOAVServiceRef;
typedef IOAVServiceRef (*CreateFn)(CFAllocatorRef, io_service_t);
typedef kern_return_t (*ReadFn)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
typedef kern_return_t (*WriteFn)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);

static uint8_t xor_checksum(uint8_t *buf, size_t len) {
  uint8_t c = 0x6E;
  for (size_t i = 0; i < len; i++) {
    c ^= buf[i];
  }
  return c;
}

int main(void) {
  void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
  if (!iokit) {
    printf("无法打开 IOKit\n");
    return 1;
  }
  CreateFn create = (CreateFn)dlsym(iokit, "IOAVServiceCreateWithService");
  ReadFn readI2C = (ReadFn)dlsym(iokit, "IOAVServiceReadI2C");
  WriteFn writeI2C = (WriteFn)dlsym(iokit, "IOAVServiceWriteI2C");
  printf("符号: create=%p read=%p write=%p\n", (void *)create, (void *)readI2C, (void *)writeI2C);
  if (!create || !readI2C || !writeI2C) {
    printf("IOAVService 符号不可用\n");
    return 1;
  }

  CFMutableDictionaryRef match = IOServiceMatching("DCPAVServiceProxy");
  io_iterator_t iter = 0;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) {
    printf("匹配不到 DCPAVServiceProxy\n");
    return 1;
  }

  io_service_t service = 0;
  int index = 0;
  while ((service = IOIteratorNext(iter)) != 0) {
    CFTypeRef locRef = IORegistryEntryCreateCFProperty(service, CFSTR("Location"), kCFAllocatorDefault, 0);
    char loc[64] = "(null)";
    if (locRef && CFGetTypeID(locRef) == CFStringGetTypeID()) {
      CFStringGetCString((CFStringRef)locRef, loc, sizeof(loc), kCFStringEncodingUTF8);
    }
    if (locRef) {
      CFRelease(locRef);
    }
    printf("节点 %d: Location=%s\n", index, loc);

    IOAVServiceRef av = create(kCFAllocatorDefault, service);
    if (!av) {
      printf("  IOAVServiceCreateWithService 失败\n");
      IOObjectRelease(service);
      index++;
      continue;
    }

    // DDC/CI: 读 VCP 0x10（亮度）
    uint8_t req[6] = {0x51, 0x82, 0x01, 0x10, 0x00, 0x00};
    req[5] = xor_checksum(req, 5);
    uint8_t reply[12] = {0};
    kern_return_t kr = writeI2C(av, 0x37, 0x51, req, sizeof(req));
    printf("  写: kr=0x%x\n", (unsigned)kr);
    usleep(50000);
    kr = readI2C(av, 0x37, 0x00, reply, sizeof(reply));
    printf("  读: kr=0x%x ->", (unsigned)kr);
    for (int i = 0; i < 12; i++) {
      printf(" %02x", reply[i]);
    }
    printf("\n");

    if (reply[2] == 0x02 && reply[3] == 0x00) {
      uint16_t max = (uint16_t)((reply[6] << 8) | reply[7]);
      uint16_t cur = (uint16_t)((reply[8] << 8) | reply[9]);
      printf("  => DDC 可用，亮度 %u/%u\n", cur, max);
    } else {
      printf("  => DDC 无有效应答\n");
    }
    IOObjectRelease(service);
    index++;
  }
  IOObjectRelease(iter);
  return 0;
}
