# FPGA 下位机详解

> 面向实机调试：说明 FPGA 端数据流、HDB3 编解码规则、DAC 波形、LED 状态和下载验证方法。当前 FPGA 已下载并与上位机联调成功，仿真和报告均已完成。

## 1. 下位机职责

FPGA 下位机负责接收上位机 UART 命令，完成 HDB3 编码或解码，并把结果同时送到两路 DAC 和 UART 应答帧。

| 功能 | 说明 |
|------|------|
| UART 通信 | 单串口 115200 bps, 8N1，命令和应答共用同一 COM 口 |
| 编码 | 二进制 bit 序列 -> HDB3 符号序列 |
| 解码 | HDB3 符号序列 -> 二进制 bit 序列 |
| DAC 显示 | DA0 显示 HDB3 编码/输入符号波形，DA1 显示译码 bit 波形 |
| LED 调试 | 8 个 LED 显示心跳、收发、命令状态、FSM 和 DAC 播放状态 |
| 7 段数码管 | 通过 74HC595 持续写空白值，避免下载后随机显示 |

## 2. 文件结构

| 文件 | 作用 |
|------|------|
| `src/hdb3_top.v` | 顶层模块，例化所有子模块并调度主 FSM |
| `src/comm/uart_byte_rx.v` | UART 字节接收 |
| `src/comm/uart_byte_tx.v` | UART 字节发送 |
| `src/hdb3/packet_parser.v` | 解析 PC -> FPGA 的 `55 AA` 命令帧 |
| `src/hdb3/response_tx.v` | 发送 FPGA -> PC 的 `AA 55` 应答帧 |
| `src/hdb3/hdb3_encoder.v` | HDB3 编码器 |
| `src/hdb3/hdb3_decoder.v` | HDB3 解码器 |
| `src/hdb3/dac_wave_ram.v` | 双口用途的同步 RAM，用于 DAC 波形缓存 |
| `src/hdb3/dac_playback.v` | 双通道 DAC 循环播放控制 |
| `src/hdb3_codec.cst` | Gowin 引脚约束 |

## 3. 顶层数据流

### 编码命令 `cmd=0x01`

```text
UART RX
  -> packet_parser
  -> payload_buf
  -> bit_buf
  -> hdb3_encoder
  -> DA0 RAM: HDB3 符号波形
  -> sym_buf
  -> hdb3_decoder 回环
  -> DA1 RAM: 译码 bit 波形
  -> response_tx 返回 HDB3 符号序列
```

编码模式下一次请求会同时得到两路 DAC 波形：DA0 是编码后的 HDB3 双极性归零波形，DA1 是把 DA0 符号回环解码后的 bit 波形。

### 解码命令 `cmd=0x02`

```text
UART RX
  -> packet_parser
  -> payload_buf(HDB3 symbols)
  -> DA0 RAM: 输入符号波形
  -> hdb3_decoder
  -> DA1 RAM: 译码 bit 波形
  -> sym_buf
  -> response_tx 返回 bit 序列
```

解码模式下 DA0 显示上位机输入的 HDB3 符号，DA1 显示译码后的 bit。

## 4. 通信协议

### PC -> FPGA 命令帧

```text
55 AA | cmd | len_l | len_h | payload[0..N-1] | checksum
```

校验和：`checksum = (cmd + len_l + len_h + sum(payload)) & 0xFF`。

### FPGA -> PC 应答帧

```text
AA 55 | cmd | status | len_l | len_h | payload[0..N-1] | checksum
```

校验和：`checksum = (cmd + status + len_l + len_h + sum(payload)) & 0xFF`。

| 命令 | 方向 | payload |
|------|------|---------|
| `0x01` | PC -> FPGA | `[bit_cnt_l][bit_cnt_h][packed_bits...]` |
| `0x01` | FPGA -> PC | HDB3 符号，每字节一个符号 |
| `0x02` | PC -> FPGA | HDB3 符号，每字节一个符号 |
| `0x02` | FPGA -> PC | bit，每字节一个 `0x00` 或 `0x01` |

当前上位机和顶层缓冲限制为 64 bit / 64 symbol。

## 5. HDB3 编码规则

当前工程使用奇偶法：每次遇到连续 4 个 `0` 时，根据“自上次 `V` 以来普通 `1` 的个数奇偶”决定替换形式。

| 条件 | 替换形式 | 说明 |
|------|----------|------|
| 普通 `1` 个数为偶 | `B00V` | `B` 与上一个非零脉冲反极性，`V` 与 `B` 同极性 |
| 普通 `1` 个数为奇 | `000V` | `V` 与上一个非零脉冲同极性 |

替换完成后，编码器会同步更新 `ami_pol`，保证下一个普通 `1` 继续按 AMI 交替极性输出。上位机 `HDB3Codec.Encode()` 和 FPGA `hdb3_encoder.v` 保持同一套规则。

### 和课堂表述的区别

你提到的课堂版本可以理解为：“第一次遇到 4 个 `0` 时先直接放 `V`，后面如果出现连续同号 `V`，再用 `B` 矫正”。这种讲法便于理解 `V` 的破坏作用和 `B` 的平衡作用。

本工程采用的奇偶法更适合硬件实现：遇到 `0000` 时立刻决定 `B00V` 或 `000V`。两者目标一致，都是维持 AMI 交替和直流平衡；但在第一个四连零这样的边界例子上，展示出来的符号序列可能不同。实机、上位机期望结果和文档均以本工程奇偶法为准。

## 6. HDB3 解码规则

解码器规则很直接：

| 输入符号 | 输出 bit |
|----------|----------|
| `+1`, `-1` | `1` |
| `0`, `+V`, `-V`, `+B`, `-B` | `0` |

原因是 `V` 和 `B` 都来自四连零替换，本身不代表原始数据中的 `1`。

## 7. DAC 输出时序

`dac_playback.v` 使用 50MHz 系统时钟分频产生 200kHz DAC 采样时钟。每个 HDB3 码元占两个采样点，因此码元速率是 100kSym/s。

| 参数 | 当前值 |
|------|--------|
| 系统时钟 | 50MHz |
| DAC 采样时钟 | 200kHz |
| 码元速率 | 100kSym/s |
| 单个码元时长 | 10us |
| DA0 脉冲宽度 | 前 5us 为正/负脉冲，后 5us 归零 |
| DA1 bit 宽度 | 整个 10us 保持 |

### 通道含义

| 通道 | 波形 | 说明 |
|------|------|------|
| DA0 | HDB3 RZ 波形 | 符号 `+1/+V/+B` 输出正脉冲，`-1/-V/-B` 输出负脉冲，第二半码元归零 |
| DA1 | 解码 bit NRZ 波形 | bit=1 输出正电压，bit=0 输出 0V，保持完整码元宽度 |

`DA1_Clk = DA0_Clk`，所以两个通道采样边界对齐。示波器上看起来 DA0 是半宽 RZ，DA1 是整宽 NRZ，这是预期现象，不是延迟。

### DAC 码值映射

当前参考 DAC 板的码值方向为反向关系：

| 电平 | DA 数据 |
|------|---------|
| 正电压 | `8'h00` |
| 0V | `8'h80` |
| 负电压 | `8'hFF` |

因此代码中 `DAC_POS=8'h00`、`DAC_ZERO=8'h80`、`DAC_NEG=8'hFF`。

## 8. LED 调试映射

顶层 LED 输出为高有效逻辑，当前含义如下：

| LED | 含义 | 观察方法 |
|-----|------|----------|
| LED0 | 心跳 | 约 2Hz 翻转，说明 FPGA 主时钟和复位正常 |
| LED1 | RX 字节脉冲 | 每收到 UART 字节后亮约 0.25s |
| LED2 | 命令解析成功 | 完整命令帧校验通过后亮约 0.25s |
| LED3 | 命令错误 | 帧错误或无效命令时亮约 0.25s |
| LED4 | 主 FSM 忙 | FPGA 正在处理命令或发送应答时亮 |
| LED5 | UART TX 忙 | 正在发送应答字节时亮 |
| LED6 | DAC 播放中 | `dac_playback` 已进入循环播放时亮 |
| LED7 | 应答完成 | `response_tx` 完成一帧发送后亮约 0.25s |

典型正常流程：发送一次编码或解码后，LED1 闪、LED2 闪、LED4 短暂亮、LED5 短暂亮、LED7 闪，LED6 保持亮表示 DAC 正在循环播放。

## 9. 引脚摘要

完整约束见 `src/hdb3_codec.cst`。

| 信号 | 引脚 |
|------|------|
| `clk_50m` | Y18 |
| `rst_n` | F15 |
| `uart_tx` | M15 |
| `uart_rx` | J21 |
| `DA0_Clk` | A14 |
| `DA1_Clk` | E13 |
| `led[7:0]` | M21, H22, J22, K22, K21, L21, N22, M22 |

## 10. Gowin 下载与验证

1. 用 Gowin EDA 打开 `HDB3_Codec.gprj`
2. 确认顶层为 `hdb3_top`
3. 综合工具选择 GowinSyn
4. 运行综合、布局布线、生成 bitstream
5. 下载到 ACX720 / GW5AT-138B 板卡
6. 打开上位机，选择对应 COM 口并连接
7. 发送编码或解码请求，观察上位机返回、LED 和示波器波形

## 11. 实机排查顺序

| 现象 | 优先检查 |
|------|----------|
| LED0 不跳 | 时钟、复位、下载是否成功 |
| LED1 不闪 | COM 口、UART RX 引脚、波特率 115200 |
| LED2 不闪但 LED1 闪 | 帧头、长度、校验和、命令码 |
| LED3 闪 | 命令非法或校验错误 |
| LED5 不亮且无返回 | `response_tx` 或 UART TX 连接 |
| LED6 不亮 | DAC 未启动，检查 FSM 是否到 `M_START_DAC` |
| DA0 波形不像 RZ | 先确认 200kHz `DA_Clk`，再看 DA0 是否前 5us 脉冲、后 5us 归零 |
| DA0/DA1 看似错位 | 注意 DA0 是 RZ 半宽，DA1 是 NRZ 整宽；符号边界由同一 `DA_Clk` 对齐 |
| 综合/布线耗时极长 | 检查 `dac_wave_ram.v` 读端口是否为纯同步 (`posedge clk`)，异步复位会阻碍 BSRAM 推断 |
