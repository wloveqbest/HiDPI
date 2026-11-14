#ifndef HD_SHIM_H
#define HD_SHIM_H

#include <stdint.h>

/// 一个显示模式的描述（从私有的 CGSDisplayMode 精简而来）
typedef struct {
  uint32_t modeNumber;
  uint32_t width;        ///< 逻辑宽（point）
  uint32_t height;       ///< 逻辑高（point）
  uint32_t depth;
  double refreshRate;
  int hiDPI;             ///< 1 = 背衬为 2x 像素
} hd_mode_t;

/// 创建一块虚拟显示器，返回其 CGDirectDisplayID；失败返回 0。
/// 虚拟显示器与调用进程同生命周期：进程退出即断开。
int hd_create_virtual_display(uint32_t logicalWidth,
                              uint32_t logicalHeight,
                              double refreshRate,
                              const char *name,
                              int hiDPI);

/// 释放本进程创建的全部虚拟显示器。
void hd_release_virtual_displays(void);

/// 返回当前连接的虚拟显示器数量。
int hd_virtual_display_count(void);

int hd_display_mode_count(uint32_t displayID);
int hd_display_mode_at(uint32_t displayID, int index, hd_mode_t *out);
int hd_display_current_mode(uint32_t displayID);
int hd_display_set_mode(uint32_t displayID, int index);

#endif
