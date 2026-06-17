# AGENTS.md — HDB3 编解码器 FPGA 项目

## 项目概述

HDB3（High Density Bipolar 3）编解码器 — FPGA 硬件实现 + 上位机控制 + 仿真验证。
- FPGA 芯片: **GW5AT-138B** (GW5AT-LV138PG484AC1/I0)，ACX720 开发板
- 参考模板: `参考/Code_260314_1/` — 多功能调试器项目，提供 Gowin 工程框架和 UART 通信模块参考
- 通信: **单 UART**（115200 bps, 8N1），命令和应答走同一 COM 口，不用 CDC/CH340 双通道

## 开发命令

### FPGA 端（Windows）

高云云源软件（Gowin EDA）打开 `HDB3_Codec.gprj` → 综合 → 布局布线 → 生成比特流 → 下载。
- 综合工具: **GowinSyn**（非 Synplify Pro）
- 顶层模块: `hdb3_top`
- 引脚约束: `src/hdb3_codec.cst`

### 上位机端（C# WPF）

```powershell
cd src\APP
dotnet build
dotnet run
```

框架: WPF (.NET 6.0+)，串口: System.IO.Ports.SerialPort。

### 仿真验证

仿真源文件放在 `src/Sim/`，仿真工具选择 Gowin EDA 内置仿真器或 ModelSim。

## 项目结构

```
src/
├── hdb3_top.v      # FPGA 顶层模块（模块例化 + 命令调度）
├── comm/          # 复用参考模板的 UART 收发（uart_byte_rx / uart_byte_tx）
├── APP/           # C# WPF 上位机（入口 HDB3_App.csproj）
├── Sim/           # 仿真 testbench 和波形文件
└── hdb3_codec.cst # 引脚约束文件
impl/             # 综合/布局布线输出，.gitignore
参考/             # Code_260314_1 完整参考项目，不参与本工程构建
```

## FPGA 开发注意事项

- 新增 `.v` 文件后需在 `HDB3_Codec.gprj` 的 `<FileList>` 中注册路径
- PLL / FIFO / DDR3 等为 Gowin IP 核，修改需 IP Generator 重新生成
- 工程文件名: **`HDB3_Codec.gprj`**（不是参考项目中的 `acm2108_ddr3_CDC.gprj`）
- UART 模块从参考工程复制后需要改波特率分频为 `CLK_FREQ / BAUD_RATE / 16`（适配 50MHz）
- 本项目使用独立通信协议（55 AA / AA 55 帧），不兼容参考工程的 CDC 协议

## 上位机开发注意事项

- 框架: WPF (.NET 6.0+)，UI: XAML + MVVM
- 命名: 文件 PascalCase.cs，类 PascalCase
- 串口管理: `SerialService` 统一管理单 UART，字节流状态机解析帧
- Threading: SerialPort.DataReceived 在后台线程，更新 UI 需 `Dispatcher.Invoke`
- 通信协议详见 `docs/01_系统设计.md`
- HDB3 软件参考实现: `Models/HDB3Codec.cs`

## 参考项目结构（参考/Code_260314_1/）

参考项目的 AGENTS.md 位于 `参考/Code_260314_1/AGENTS.md`。
参考项目使用 PySide6 + CDC/CH340 双串口，本工程已改为 C# WPF + 单 UART，协议不兼容。
