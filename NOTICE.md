# 第三方署名

本项目的私有 API 声明方式参考自 **BetterDummy OpenSource Edition**：

- 项目：https://github.com/waydabber/BetterDisplay/tree/opensource
- 许可：MIT License
- 版权：Copyright (c) 2021 Istvan T.

具体而言，`Sources/HDShim/` 中 `CGVirtualDisplay` 相关的 `@interface` 声明形式、以及 `CGSConfigureDisplayMode` / `CGGetDisplayTransferByTable` 等私有接口的调用方式，参考了该项目的实现。

上游当前的 BetterDisplay 5.x 已闭源，与本项目无代码关系。
