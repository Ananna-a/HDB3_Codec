// Services/SerialService.cs — 串口管理 + 55AA/AA55 帧协议
using System;
using System.Collections.Generic;
using System.IO.Ports;

namespace HDB3_App.Services
{
    /// <summary>
    /// 串口服务: 管理单 UART, 发送命令帧 / 接收应答帧
    /// SerialPort.DataReceived 在后台线程, 事件通过同步上下文传递
    /// </summary>
    public class SerialService : IDisposable
    {
        private SerialPort _port;
        private readonly List<byte> _rxBuf = new List<byte>(512);
        private readonly SynchronizedDispatcher _dispatcher;

        /// <summary>接收到完整应答帧 (cmd + status + payload)</summary>
        public event Action<byte, byte, byte[]> FrameReceived;
        public event Action<string> RawLog;

        public bool IsOpen => _port?.IsOpen ?? false;
        public string[] PortNames => SerialPort.GetPortNames();

        public SerialService(SynchronizedDispatcher dispatcher)
        {
            _dispatcher = dispatcher;
        }

        public void Open(string portName, int baudRate = 115200)
        {
            Close();
            _port = new SerialPort(portName, baudRate, Parity.None, 8, StopBits.One);
            _port.DataReceived += OnDataReceived;
            _port.Open();
            _rxBuf.Clear();
        }

        public void Close()
        {
            if (_port != null)
            {
                _port.DataReceived -= OnDataReceived;
                if (_port.IsOpen) _port.Close();
                _port.Dispose();
                _port = null;
            }
        }

        /// <summary>
        /// 发送命令帧: 55 AA cmd len_l len_h payload... cs
        /// </summary>
        public void SendCommand(byte cmd, byte[] payload)
        {
            if (!IsOpen) throw new InvalidOperationException("串口未打开");

            int len = payload?.Length ?? 0;
            var frame = new byte[5 + len + 1];
            frame[0] = 0x55;
            frame[1] = 0xAA;
            frame[2] = cmd;
            frame[3] = (byte)(len & 0xFF);
            frame[4] = (byte)((len >> 8) & 0xFF);
            if (payload != null)
                Array.Copy(payload, 0, frame, 5, len);

            // 校验和: cmd + len_l + len_h + Σpayload
            frame[5 + len] = CalcChecksum(frame, 2, 3 + len);

            _port.Write(frame, 0, frame.Length);
            RawLog?.Invoke($"TX {ToHex(frame)}");
        }

        /// <summary>
        /// 串口接收回调 (后台线程)
        /// </summary>
        private void OnDataReceived(object sender, SerialDataReceivedEventArgs e)
        {
            try
            {
                int cnt = _port.BytesToRead;
                byte[] buf = new byte[cnt];
                _port.Read(buf, 0, cnt);
                _rxBuf.AddRange(buf);
                RawLog?.Invoke($"RX {ToHex(buf)}");

                // 字节流状态机解析 AA 55 应答帧
                while (_rxBuf.Count >= 7)
                {
                    // 找 AA 55 帧头
                    int idx = -1;
                    for (int i = 0; i < _rxBuf.Count - 1; i++)
                    {
                        if (_rxBuf[i] == 0xAA && _rxBuf[i + 1] == 0x55)
                        { idx = i; break; }
                    }
                    if (idx < 0) break;

                    // 跳过帧头前垃圾数据
                    if (idx > 0) _rxBuf.RemoveRange(0, idx);

                    if (_rxBuf.Count < 7) break;

                    byte cmd = _rxBuf[2];
                    byte status = _rxBuf[3];
                    int len = _rxBuf[4] | (_rxBuf[5] << 8);
                    int frameLen = 6 + len + 1;  // 帧头2 + cmd+status+len2 + payload + cs

                    if (_rxBuf.Count < frameLen) break;

                    // 校验和验证: cmd + status + len_l + len_h + Σpayload
                    byte csCalc = _rxBuf[2];
                    csCalc += _rxBuf[3];
                    csCalc += _rxBuf[4];
                    csCalc += _rxBuf[5];
                    for (int i = 0; i < len; i++)
                        csCalc += _rxBuf[6 + i];

                    if (csCalc == _rxBuf[6 + len])
                    {
                        var payload = new byte[len];
                        for (int i = 0; i < len; i++)
                            payload[i] = _rxBuf[6 + i];

                        // 切回 UI 线程
                        var cmdCopy = cmd;
                        var statusCopy = status;
                        var payloadCopy = payload;
                        _dispatcher.Invoke(() => FrameReceived?.Invoke(cmdCopy, statusCopy, payloadCopy));
                    }
                    else
                    {
                        RawLog?.Invoke($"RX checksum error calc={csCalc:X2} got={_rxBuf[6 + len]:X2}");
                    }

                    // 移除已解析帧
                    _rxBuf.RemoveRange(0, frameLen);
                }
            }
            catch { /* 串口异常忽略 */ }
        }

        private static byte CalcChecksum(byte[] data, int start, int count)
        {
            byte cs = 0;
            for (int i = start; i < start + count; i++)
                cs += data[i];
            return cs;
        }

        private static string ToHex(byte[] data)
            => BitConverter.ToString(data).Replace('-', ' ');

        public void Dispose() => Close();
    }

    /// <summary>
    /// 跨线程调度器 (WPF 用 Dispatcher.Invoke)
    /// </summary>
    public class SynchronizedDispatcher
    {
        private readonly System.Windows.Threading.Dispatcher _dispatcher;
        public SynchronizedDispatcher(System.Windows.Threading.Dispatcher d) => _dispatcher = d;
        public void Invoke(Action action) => _dispatcher.Invoke(action);
    }
}
