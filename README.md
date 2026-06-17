# HDB3 Codec — FPGA 硬件实现 + C# WPF 上位机

HDB3（High Density Bipolar 3）编解码器，面向教学演示场景。

[![FPGA](https://img.shields.io/badge/FPGA-GW5AT--138B-blue)](https://www.gowinsemi.com)
[![Host](https://img.shields.io/badge/上位机-C%23%20WPF%20.NET%2010-purple)](https://dotnet.microsoft.com)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## 功能

| 功能 | 说明 |
|------|------|
| **编码** | 二进制序列 → HDB3 符号序列（含 +1 / -1 / +V / -V / +B / -B 六种符号），遵循 ITU-T G.703 |
| **解码** | HDB3 符号序列 → 二进制序列 |
| **DAC 输出** | DA0 输出编码波形，DA1 输出译码波形，循环回放，示波器可观察 |
| **自检回环** | 编码模式下 encoder 输出自动送入 decoder，一次请求双通道都有波形 |
| **正确性对比** | 上位机 C# 软实现 HDB3 算法，FPGA 返回结果后逐符号比对，差异标红 |

## 硬件平台

- **芯片**: 高云 GW5AT-138B (GW5AT-LV138PG484AC1/I0)
- **开发板**: ACX720
- **时钟**: 50 MHz 板载晶振
- **通信**: 单 UART 115200 bps 8N1
- **DAC**: 双通道 8-bit，-5V ~ +5V

## 系统架构

```
┌──────────────────────────────────────────────────────────┐
│  上位机 C# WPF (.NET 10)                                  │
│  ┌──────────────────┐  ┌──────────────────┐              │
│  │  编码区           │  │  解码区           │              │
│  │  输入二进制序列    │  │  输入符号序列      │              │
│  │  期望 vs FPGA返回  │  │  期望 vs FPGA返回  │              │
│  └────────┬─────────┘  └────────┬─────────┘              │
│           └──────────┬──────────┘                         │
│               UART 115200                                │
└──────────────────────┼──────────────────────────────────┘
                       │
┌──────────────────────┼──────────────────────────────────┐
│  FPGA GW5AT-138B     │                                   │
│                      ▼                                   │
│  ┌─────────────────────────────────────────────────┐    │
│  │  packet_parser → 55 AA 帧解析                     │    │
│  └────────┬─────────────────┬──────────────────────┘    │
│           │ cmd=0x01 (编码)  │ cmd=0x02 (解码)           │
│           ▼                 ▼                            │
│  ┌───────────────┐  ┌────────────────┐                  │
│  │ hdb3_encoder   │  │ hdb3_decoder    │                  │
│  │ 二进制 → HDB3  │  │ HDB3 → 二进制   │                  │
│  └───────┬───────┘  └───────┬────────┘                  │
│          │    ┌─────────────┘                            │
│          ▼    ▼                                          │
│  ┌─────────────────────────────────────────────┐        │
│  │  dac_playback (2× dac_wave_ram BRAM)          │        │
│  │  DA0: 编码波形    DA1: 译码波形                │        │
│  └─────────────────────────────────────────────┘        │
│                                                          │
│  ┌─────────────────────────────────────────────┐        │
│  │  response_tx → AA 55 应答帧 → UART TX        │        │
│  └─────────────────────────────────────────────┘        │
│  LED: led0 心跳灯 (~2Hz)                                 │
└──────────────────────────────────────────────────────────┘
```

## 快速开始

### FPGA 端

1. 高云云源软件（Gowin EDA）打开 `HDB3_Codec.gprj`
2. 综合（GowinSyn）→ 布局布线 → 生成比特流 → 下载到 FPGA

### 上位机端

```powershell
cd src/APP
dotnet build
dotnet run
```

### 仿真

```powershell
cd src/Sim
iverilog -o tb_hdb3_encoder.vvp tb_hdb3_encoder.v ../hdb3/hdb3_encoder.v
vvp tb_hdb3_encoder.vvp
```

## 项目结构

```
src/
├── hdb3_top.v              # FPGA 顶层模块（10 状态 FSM）
├── comm/
│   ├── uart_byte_rx.v      # UART 接收（16 倍过采样）
│   └── uart_byte_tx.v      # UART 发送（8N1）
├── hdb3/
│   ├── hdb3_encoder.v      # HDB3 编码器（三趟批处理）
│   ├── hdb3_decoder.v      # HDB3 解码器
│   ├── dac_playback.v      # 双通道 DAC 播放控制
│   ├── dac_wave_ram.v      # 2048×8 BRAM 缓冲
│   ├── packet_parser.v     # 55 AA 命令帧解析
│   └── response_tx.v       # AA 55 应答帧发送
├── Sim/                    # 仿真 testbench
├── APP/                    # C# WPF 上位机
│   ├── Models/HDB3Codec.cs # C# 软编解码算法
│   ├── Services/SerialService.cs  # 串口通信
│   └── ViewModels/MainViewModel.cs # MVVM 视图模型
└── hdb3_codec.cst          # 引脚约束文件
docs/                       # 详细设计文档
参考/                       # 参考项目 Code_260314_1
```

## 通信协议

帧格式（55 AA / AA 55 帧头区分命令/应答）：

| 方向 | 帧结构 |
|------|--------|
| PC → FPGA (命令) | `55 AA` \| cmd \| len_l \| len_h \| payload[...] \| cs |
| FPGA → PC (应答) | `AA 55` \| cmd \| status \| len_l \| len_h \| payload[...] \| cs |

校验和: `cs = (cmd + len_l + len_h + Σpayload) & 0xFF`

### 命令码

| cmd | 方向 | 说明 |
|-----|------|------|
| 0x01 | PC→FPGA | 编码请求：payload = [bit_cnt_l][bit_cnt_h][bit_data...] |
| 0x01 | FPGA→PC | 编码应答：payload = 符号序列（每字节 1 符号） |
| 0x02 | PC→FPGA | 解码请求：payload = 符号序列（每字节 1 符号） |
| 0x02 | FPGA→PC | 解码应答：payload = 比特序列（每字节 1 bit） |

## HDB3 符号编码

| 值 | 符号 | 含义 |
|----|------|------|
| 0x00 | 0 | 零电平 |
| 0x01 | +1 | 正脉冲 |
| 0x02 | -1 | 负脉冲 |
| 0x03 | +V | 正破坏脉冲 |
| 0x04 | -V | 负破坏脉冲 |
| 0x05 | +B | 正平衡脉冲 |
| 0x06 | -B | 负平衡脉冲 |

## 引脚约束

| 功能 | 引脚 | 类型 |
|------|------|------|
| clk_50m | Y18 | LVCMOS33 |
| rst_n | F15 | LVCMOS33 |
| uart_tx | M15 | LVCMOS33, PU, DRIVE=8 |
| uart_rx | J21 | LVCMOS33, PU |
| DA0_Data[7:0] | A13/A16/A15/A19/A18/F14/F13/E14 | LVCMOS33 |
| DA0_Clk | A14 | LVCMOS33 |
| DA1_Data[7:0] | C13/B13/D14/D15/C14/C15/B15/B16 | LVCMOS33 |
| DA1_Clk | E13 | LVCMOS33 |
| led0 | M22 | LVCMOS33 |

## 文档

| 文档 | 内容 |
|------|------|
| [系统设计](docs/01_系统设计.md) | 完整架构、所有模块接口、协议细节 |
| [实施计划](docs/02_实施计划.md) | 开发进度、文件清单、验证清单 |
| [上位机框架](docs/03_上位机框架详解.md) | WPF 零基础入门、MVVM 详解 |

## 参数

| 参数 | 值 |
|------|-----|
| 系统时钟 | 50 MHz |
| 码元速率 | 100 kHz（50M / 500） |
| DAC 分辨率 | 8 bit |
| DAC 电压 | -5V ~ +5V (0V = 0x80) |
| 最大序列 | 2048 bit/symbol |
| 波特率 | 115200 bps |
