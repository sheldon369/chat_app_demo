# third_app

一个基于 Flutter 的聊天程序 Demo，可实现多客户端之间的实时通信，主要用于学习与演示移动端聊天应用的基本架构与实现方式。

---

## 项目简介

本项目包含一个 Flutter 客户端与一个本地运行的服务端程序，通过本地网络实现多客户端之间的聊天通信。项目结构清晰，功能完整，适合作为课程设计、实验项目或 Flutter 学习示例。

主要内容包括：
- Flutter 移动端聊天客户端
- 基于 C++（CMake 模板）的本地服务端程序（Server.exe）
- 使用 LaTeX 编写的产品技术报告（可生成 PDF）

---

## 运行环境

- Flutter SDK（建议稳定版）
- Android 模拟器或 Android 真机
- Windows 系统（用于运行 Server.exe）
- Android SDK（包含 adb 工具）

---

## Getting Started

### 1. 后端服务配置

客户端默认后端 API 地址为： http://127.0.0.1:8080

请确保：
- 服务端程序（`Server.exe`）已成功启动；
- 移动端设备或模拟器能够访问该地址；
- 如需修改后端地址，请在客户端代码中调整 `AuthService.apiBaseUrl`。

---

### 2. 安装客户端依赖

首次运行项目前，请在项目根目录执行：

flutter pub get

### 3. Android 模拟器本地调试（adb reverse）

当前测试方式为在同一台电脑上同时运行服务端与（多个）客户端，通过本地网络地址实现通信。

在启动 Server.exe 后，在命令行执行：

adb.exe reverse --remove-all

adb.exe -s emulator-5556 reverse tcp:8080 tcp:8080
adb.exe -s emulator-5554 reverse tcp:8080 tcp:8080

adb.exe devices

说明：
- emulator-5554、emulator-5556 为模拟器设备名称（可用 adb.exe devices 查看）。
- 上述命令将模拟器的 tcp:8080 端口映射到本机的 tcp:8080，使模拟器可通过 127.0.0.1:8080 访问本机服务端。
- 注意以上命令依赖 Android SDK 目录下的 adb.exe。请将 adb 所在目录添加到系统环境变量；若未配置环境变量，请在 adb.exe 所在目录下执行上述命令。

完成上述步骤后，客户端即可正确访问本地运行的服务端服务。


## 项目结构说明

third_app/
├── lib/            # Flutter 客户端全部源码
├── Server/         # 基于 C++ + CMake 的服务端程序
├── 产品报告/       
├── pubspec.yaml
└── README.md

## 备注
本项目为腾讯微信客户端大作业 Demo 示例，主要用于学习与演示，未包含完整的权限控制、加密通信与高并发优化等生产级能力。





