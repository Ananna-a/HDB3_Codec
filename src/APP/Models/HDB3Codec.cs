// Models/HDB3Codec.cs — HDB3 软编解码 (用于上位机正确性对比)
using System;
using System.Collections.Generic;

namespace HDB3_App.Models
{
    /// <summary>
    /// HDB3 编解码符号定义
    /// </summary>
    public enum Hdb3Symbol : byte
    {
        Zero = 0x00,   // 零电平
        P1   = 0x01,   // +1 正脉冲
        N1   = 0x02,   // -1 负脉冲
        PV   = 0x03,   // +V 正破坏脉冲
        NV   = 0x04,   // -V 负破坏脉冲
        PB   = 0x05,   // +B 正平衡脉冲
        NB   = 0x06    // -B 负平衡脉冲
    }

    /// <summary>
    /// HDB3 软件编码/解码器，与 FPGA 实现算法一致
    /// </summary>
    public static class HDB3Codec
    {
        /// <summary>
        /// HDB3 编码: 二进制 → 符号序列
        /// </summary>
        public static byte[] Encode(bool[] bits, bool firstPulseNegative = false)
        {
            var result = new List<byte>();
            int zeroCnt = 0;
            bool amiPol = firstPulseNegative; // 下一个 '1' 的极性: false=正, true=负
            bool pulseParity = false; // 自上次V以来 '1' 个数奇偶: false=偶, true=奇
            bool lastPol = firstPulseNegative; // 上一个非零脉冲的极性；无前脉冲时作为初始参考极性

            var delayBuf = new byte[3]; // 3 符号延迟缓冲 (B00V 需要回写)
            int delayCnt = 0;

            for (int i = 0; i < bits.Length; i++)
            {
                if (bits[i])  // bit = 1
                {
                    // 先输出延迟缓冲中的零
                    FlushDelayBuf(result, delayBuf, ref delayCnt);

                    byte sym = amiPol ? (byte)Hdb3Symbol.N1 : (byte)Hdb3Symbol.P1;
                    result.Add(sym);
                    lastPol = amiPol;
                    amiPol = !amiPol;
                    zeroCnt = 0;
                    pulseParity = !pulseParity;
                }
                else  // bit = 0
                {
                    zeroCnt++;
                    if (zeroCnt == 4)  // 连续4个零 → 替换
                    {
                        // B00V 需要把前面暂存的 3 个 0 替换成 B00。
                        if (!pulseParity)  // 偶数脉冲 → B00V
                        {
                            bool vPol = !lastPol;  // V = 同B = 反极性
                            result.Add(lastPol ? (byte)Hdb3Symbol.PB : (byte)Hdb3Symbol.NB);
                            result.Add((byte)Hdb3Symbol.Zero);
                            result.Add((byte)Hdb3Symbol.Zero);
                            result.Add(PulseToViolation(vPol));
                            amiPol = !vPol;
                            lastPol = vPol;
                        }
                        else  // 奇数脉冲 → 000V
                        {
                            bool vPol = lastPol;   // V = 同极性
                            result.Add((byte)Hdb3Symbol.Zero);
                            result.Add((byte)Hdb3Symbol.Zero);
                            result.Add((byte)Hdb3Symbol.Zero);
                            result.Add(PulseToViolation(vPol));
                            amiPol = !vPol;
                            lastPol = vPol;
                        }
                        delayCnt = 0;
                        zeroCnt = 0;
                        pulseParity = false;
                    }
                    else if (zeroCnt <= 3)
                    {
                        // 暂存前 3 个零；若后面不是第 4 个零，再原样输出。
                        delayBuf[delayCnt++] = (byte)Hdb3Symbol.Zero;
                    }
                }
            }
            // 末尾剩余缓冲 (没形成4连零)
            FlushDelayBuf(result, delayBuf, ref delayCnt);
            return result.ToArray();
        }

        private static byte PulseToViolation(bool negative)
            => negative ? (byte)Hdb3Symbol.NV : (byte)Hdb3Symbol.PV;

        private static void FlushDelayBuf(List<byte> result, byte[] buf, ref int cnt)
        {
            for (int i = 0; i < cnt; i++)
                result.Add(buf[i]);
            cnt = 0;
        }

        /// <summary>
        /// HDB3 解码: 符号序列 → 二进制 (+1/-1→1, 其他→0)
        /// </summary>
        public static bool[] Decode(byte[] symbols)
        {
            var result = new bool[symbols.Length];
            for (int i = 0; i < symbols.Length; i++)
            {
                byte s = symbols[i];
                result[i] = (s == (byte)Hdb3Symbol.P1 || s == (byte)Hdb3Symbol.N1);
            }
            return result;
        }

        /// <summary>
        /// 比特数组 → 打包字节数组 (MSB在前)
        /// </summary>
        public static byte[] PackBits(bool[] bits)
        {
            int byteCnt = (bits.Length + 7) / 8;
            var result = new byte[byteCnt];
            for (int i = 0; i < bits.Length; i++)
                if (bits[i])
                    result[i / 8] |= (byte)(1 << (7 - i % 8));
            return result;
        }

        /// <summary>
        /// 打包字节数组 → 比特数组
        /// </summary>
        public static bool[] UnpackBits(byte[] packed, int bitCnt)
        {
            var result = new bool[bitCnt];
            for (int i = 0; i < bitCnt; i++)
                result[i] = ((packed[i / 8] >> (7 - i % 8)) & 1) == 1;
            return result;
        }

        /// <summary>
        /// 符号值转可读字符串
        /// </summary>
        public static string SymbolToString(byte sym) => sym switch
        {
            0x00 => "0",
            0x01 => "+1", 0x02 => "-1",
            0x03 => "+V", 0x04 => "-V",
            0x05 => "+B", 0x06 => "-B",
            _    => "?"
        };

        /// <summary>
        /// 可读字符串转符号值
        /// </summary>
        public static byte StringToSymbol(string s) => s.Trim().ToUpper() switch
        {
            "0"  => 0x00,
            "+1" => 0x01, "-1" => 0x02,
            "+V" => 0x03, "-V" => 0x04,
            "+B" => 0x05, "-B" => 0x06,
            _    => 0xFF
        };
    }
}
