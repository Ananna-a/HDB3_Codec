// ViewModels/MainViewModel.cs — 主窗口视图模型
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Input;
using HDB3_App.Models;
using HDB3_App.Services;

namespace HDB3_App.ViewModels
{
    public class ObservableSymbol : INotifyPropertyChanged
    {
        private string _value;
        public string Value { get => _value; set { _value = value; OnPropertyChanged(); } }

        private bool _isCorrect = true;
        public bool IsCorrect { get => _isCorrect; set { _isCorrect = value; OnPropertyChanged(); } }

        public event PropertyChangedEventHandler PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    public class MainViewModel : INotifyPropertyChanged
    {
        private const int MaxFrameSymbols = 64;
        private const int MinRandomBits = 16;
        private const int MaxRandomBits = 20;

        private readonly SerialService _serial;

        // ---- 串口 ----
        public ObservableCollection<string> PortList { get; } = new();
        private string _selPort;
        public string SelectedPort { get => _selPort; set { _selPort = value; OnPropertyChanged(); } }
        public bool IsConnected => _serial.IsOpen;
        private bool _isBusy;
        public bool IsBusy
        {
            get => _isBusy;
            set
            {
                if (_isBusy == value) return;
                _isBusy = value;
                OnPropertyChanged();
                CommandManager.InvalidateRequerySuggested();
            }
        }

        // ---- 编码区 ----
        public ObservableCollection<ObservableSymbol> EncExpected { get; } = new();
        public ObservableCollection<ObservableSymbol> EncActual { get; } = new();
        private bool _encAllMatch = true;
        private bool _encResponded;
        public string EncStatus => !_encResponded ? "-" : (_encAllMatch ? "✓ 全部正确" : "✗ 存在差异");

        // ---- 解码区 ----
        private string _decRaw = "";
        public string DecInput
        {
            get => _decRaw;
            set
            {
                value ??= "";
                var normalized = new string(value
                    .Replace('，', ',')
                    .Replace('；', ';')
                    .Replace('、', ',')
                    .Select(c => c == 'v' ? 'V' : c == 'b' ? 'B' : c)
                    .ToArray());
                if (normalized != _decRaw)
                {
                    _decRaw = normalized;
                    OnPropertyChanged();
                }
            }
        }
        public ObservableCollection<ObservableSymbol> DecExpected { get; } = new();
        public ObservableCollection<ObservableSymbol> DecActual { get; } = new();
        private bool _decAllMatch = true;
        private bool _decResponded;
        public string DecStatus => !_decResponded ? "-" : (_decAllMatch ? "✓ 全部正确" : "✗ 存在差异");

        // ---- 日志 ----
        private string _log = "";
        public string LogText { get => _log; set { _log = value; OnPropertyChanged(); } }

        // ---- 命令 ----
        public ICommand ConnectCmd { get; }
        public ICommand EncodeCmd { get; }
        public ICommand DecodeCmd { get; }
        public ICommand DecSymCmd { get; }
        public ICommand DecClearCmd { get; }
        public ICommand DecBackCmd { get; }
        public ICommand EncClearCmd { get; }
        public ICommand EncBit0Cmd { get; }
        public ICommand EncBit1Cmd { get; }
        public ICommand EncRandCmd { get; }
        public ICommand DecRandCmd { get; }
        public ICommand DecImportCmd { get; }

        // ---- 解码符号按钮 ----
        public string[] DecSymbols { get; } = { "0", "+1", "-1", "+V", "-V", "+B", "-B" };

        private static readonly Random _rng = new();

        public MainViewModel()
        {
            var disp = new SynchronizedDispatcher(Application.Current.Dispatcher);
            _serial = new SerialService(disp);
            _serial.FrameReceived += OnFrame;

            ConnectCmd   = new RelayCommand(_ => ToggleConnect());
            EncodeCmd    = new RelayCommand(_ => SendEncode(), _ => !IsBusy && _serial.IsOpen);
            DecodeCmd    = new RelayCommand(_ => SendDecode(), _ => !IsBusy && _serial.IsOpen);
            DecSymCmd    = new RelayCommand(p => AppendDecSymbol(p as string));
            DecClearCmd  = new RelayCommand(_ => DecInput = "");
            DecBackCmd   = new RelayCommand(_ => RemoveLastDecodeToken());
            EncClearCmd  = new RelayCommand(_ => EncInput = "");
            EncBit0Cmd   = new RelayCommand(_ => EncInput += "0");
            EncBit1Cmd   = new RelayCommand(_ => EncInput += "1");
            EncRandCmd   = new RelayCommand(_ => GenerateRandomBits());
            DecRandCmd   = new RelayCommand(_ => GenerateRandomSymbols());
            DecImportCmd = new RelayCommand(_ => ImportFromEncode());

            RefreshPorts();
        }

        /// <summary>随机生成包含 HDB3 四零替换场景的二进制序列</summary>
        private void GenerateRandomBits()
        {
            var bits = GenerateRandomTestBits();
            EncInput = BitsToText(bits);
            Log($"生成随机序列: {bits.Length} bit，已包含 0000 替换场景");
        }

        /// <summary>随机生成 HDB3 符号序列（编码随机bit得到的合法符号）</summary>
        private void GenerateRandomSymbols()
        {
            var bits = GenerateRandomTestBits();
            var syms = HDB3Codec.Encode(bits);
            DecInput = string.Join(" ", syms.Select(s => HDB3Codec.SymbolToString(s)));
            Log($"生成随机合法符号: {syms.Length} 个，源序列 {bits.Length} bit");
        }

        /// <summary>将编码期望结果复制到解码输入框</summary>
        private void ImportFromEncode()
        {
            if (EncExpected.Count == 0) { Log("提示: 请先执行一次编码"); return; }
            var tokens = EncExpected.Select(e => e.Value).ToArray();
            DecInput = string.Join(" ", tokens);
            Log($"已导入 {tokens.Length} 个符号到解码区");
        }

        /// <summary>HDB3 符号序列合法性检查, 返回错误文本 (null=无问题)</summary>
        private static string ValidateHdb3(byte[] syms)
        {
            var decoded = HDB3Codec.Decode(syms);
            var canonical = HDB3Codec.Encode(decoded);
            var invertedStart = HDB3Codec.Encode(decoded, firstPulseNegative: true);
            if (SymbolsEqual(syms, invertedStart))
                return null;

            if (canonical.Length != syms.Length)
                return $"长度不一致: 输入 {syms.Length} 个符号，重新编码得到 {canonical.Length} 个符号";

            for (int i = 0; i < syms.Length; i++)
            {
                if (syms[i] != canonical[i])
                    return $"第{i + 1}个符号应为 {HDB3Codec.SymbolToString(canonical[i])}，当前为 {HDB3Codec.SymbolToString(syms[i])}";
            }
            return null;
        }

        private static bool SymbolsEqual(byte[] left, byte[] right)
            => left.Length == right.Length && left.SequenceEqual(right);

        private void AppendDecSymbol(string sym)
        {
            if (string.IsNullOrEmpty(sym)) return;
            DecInput = (DecInput.Length > 0 ? DecInput + " " : "") + sym;
        }

        private void RemoveLastDecodeToken()
        {
            var text = DecInput.TrimEnd();
            if (text.Length == 0)
            {
                DecInput = "";
                return;
            }

            for (int i = text.Length - 1; i >= 0; i--)
            {
                if (IsSymbolSeparator(text[i]))
                {
                    DecInput = text.Substring(0, i).TrimEnd();
                    return;
                }
            }
            DecInput = "";
        }

        private static bool[] GenerateRandomTestBits()
        {
            int length = _rng.Next(MinRandomBits, MaxRandomBits + 1);
            var bits = new List<bool>(length);

            int prefixLen = _rng.Next(0, 5);
            bool firstPrefixOne = _rng.Next(2) == 0;
            bool secondPrefixOne = _rng.Next(2) == 0;
            for (int i = 0; i < prefixLen; i++)
            {
                bool value = i switch
                {
                    0 => firstPrefixOne,
                    1 => secondPrefixOne,
                    _ => _rng.Next(2) == 0
                };
                bits.Add(value);
            }

            if (bits.Count(b => b) % 2 != 0)
                bits.Add(true);

            AddZeros(bits, 4);   // 偶数脉冲后: B00V
            bits.Add(true);
            AddZeros(bits, 4);   // 奇数脉冲后: 000V

            while (bits.Count < length)
                bits.Add(_rng.Next(100) < 45);

            return bits.Take(length).ToArray();
        }

        private static void AddZeros(List<bool> bits, int count)
        {
            for (int i = 0; i < count; i++) bits.Add(false);
        }

        private static string BitsToText(IEnumerable<bool> bits)
            => new string(bits.Select(b => b ? '1' : '0').ToArray());

        private static bool TryParseHdb3Input(string input, out byte[] symbols, out string error)
        {
            var parsed = new List<byte>();
            symbols = Array.Empty<byte>();
            error = null;

            if (string.IsNullOrWhiteSpace(input))
            {
                symbols = parsed.ToArray();
                return true;
            }

            int i = 0;
            while (i < input.Length)
            {
                if (IsSymbolSeparator(input[i]))
                {
                    i++;
                    continue;
                }

                char c = char.ToUpperInvariant(input[i]);
                if (c == '0')
                {
                    parsed.Add((byte)Hdb3Symbol.Zero);
                    i++;
                    continue;
                }
                if (c == '1')
                {
                    parsed.Add((byte)Hdb3Symbol.P1);
                    i++;
                    continue;
                }

                if (c == '+' || c == '-')
                {
                    bool negative = c == '-';
                    int signIndex = i;
                    i++;

                    while (i < input.Length && char.IsWhiteSpace(input[i]))
                        i++;

                    if (i >= input.Length || IsSymbolSeparator(input[i]))
                    {
                        parsed.Add(negative ? (byte)Hdb3Symbol.N1 : (byte)Hdb3Symbol.P1);
                        continue;
                    }

                    char type = char.ToUpperInvariant(input[i]);
                    byte symbol = type switch
                    {
                        '1' => negative ? (byte)Hdb3Symbol.N1 : (byte)Hdb3Symbol.P1,
                        'V' => negative ? (byte)Hdb3Symbol.NV : (byte)Hdb3Symbol.PV,
                        'B' => negative ? (byte)Hdb3Symbol.NB : (byte)Hdb3Symbol.PB,
                        _ => 0xFF
                    };

                    if (symbol == 0xFF)
                    {
                        error = $"第{signIndex + 1}个字符后应输入 1、V 或 B";
                        return false;
                    }

                    parsed.Add(symbol);
                    i++;
                    continue;
                }

                if (c == 'V' || c == 'B')
                {
                    error = $"第{i + 1}个符号 {c} 缺少 + 或 - 极性前缀";
                    return false;
                }

                error = $"第{i + 1}个字符 '{input[i]}' 无效；可输入 0、+1、-1、+V、-V、+B、-B，支持空格/逗号/分号分隔或紧凑输入";
                return false;
            }

            symbols = parsed.ToArray();
            return true;
        }

        private static bool IsSymbolSeparator(char c)
            => char.IsWhiteSpace(c) || c == ',' || c == ';' || c == '，' || c == '；' || c == '、';

        // ================================================================
        // 编码输入校验: 实时过滤非法字符
        // ================================================================
        private string _encRaw = "";
        public string EncInput
        {
            get => _encRaw;
            set
            {
                var filtered = new string(value.Where(c => c == '0' || c == '1').ToArray());
                if (filtered != _encRaw)
                {
                    _encRaw = filtered;
                    OnPropertyChanged();
                }
            }
        }

        private void RefreshPorts()
        {
            PortList.Clear();
            foreach (var p in _serial.PortNames) PortList.Add(p);
            if (PortList.Count > 0) SelectedPort = PortList[0];
        }

        private void ToggleConnect()
        {
            try
            {
                if (_serial.IsOpen)
                {
                    _serial.Close();
                    Log("串口已断开");
                }
                else
                {
                    if (string.IsNullOrWhiteSpace(SelectedPort))
                    {
                        RefreshPorts();
                        if (string.IsNullOrWhiteSpace(SelectedPort))
                        {
                            Log("错误: 未找到可用串口");
                            return;
                        }
                    }

                    _serial.Open(SelectedPort);
                    Log($"串口 {SelectedPort} 已打开, 115200bps");
                }
            }
            catch (Exception ex)
            {
                Log($"串口错误: {ex.Message}");
            }
            OnPropertyChanged(nameof(IsConnected));
            CommandManager.InvalidateRequerySuggested();
        }

        // ================================================================
        // 编码
        // ================================================================
        private void SendEncode()
        {
            if (IsBusy) { Log("FPGA 忙, 请等待"); return; }

            // 提取 0/1 字符
            var chars = EncInput.Where(c => c == '0' || c == '1').ToArray();
            if (chars.Length == 0) { Log("错误: 请输入二进制序列"); return; }
            if (chars.Length > MaxFrameSymbols)
            {
                Log($"错误: 当前 FPGA 应答帧最多支持 {MaxFrameSymbols} bit/符号，请缩短编码输入");
                return;
            }

            var bits = chars.Select(c => c == '1').ToArray();

            // 软件编码
            byte[] expected = HDB3Codec.Encode(bits);

            // 构建 payload: [bit_cnt_l][bit_cnt_h][packed bits...]
            int bitCnt = bits.Length;
            byte[] packed = HDB3Codec.PackBits(bits);
            var payload = new byte[2 + packed.Length];
            payload[0] = (byte)(bitCnt & 0xFF);
            payload[1] = (byte)((bitCnt >> 8) & 0xFF);
            Array.Copy(packed, 0, payload, 2, packed.Length);

            _serial.SendCommand(0x01, payload);
            IsBusy = true;
            _encResponded = false;
            EncActual.Clear();
            OnPropertyChanged(nameof(EncStatus));
            Log($"编码请求: {bitCnt} bit → {expected.Length} 符号");

            // 显示期望
            EncExpected.Clear();
            foreach (var s in expected)
                EncExpected.Add(new ObservableSymbol { Value = HDB3Codec.SymbolToString(s), IsCorrect = true });
        }

        // ================================================================
        // 解码
        // ================================================================
        private void SendDecode()
        {
            if (IsBusy) { Log("FPGA 忙, 请等待"); return; }

            if (!TryParseHdb3Input(DecInput, out var symArr, out var parseError))
            {
                Log($"错误: {parseError}");
                return;
            }
            if (symArr.Length == 0) { Log("错误: 请输入符号序列"); return; }
            if (symArr.Length > MaxFrameSymbols)
            {
                Log($"错误: 当前 FPGA 应答帧最多支持 {MaxFrameSymbols} 个符号，请缩短解码输入");
                return;
            }

            // 软件解码 (期望)
            bool[] expected = HDB3Codec.Decode(symArr);

            // HDB3 合法性检查
            var invalidReason = ValidateHdb3(symArr);
            if (!string.IsNullOrEmpty(invalidReason))
            {
                Log($"错误: HDB3 序列不合法，{invalidReason}");
                return;
            }

            _serial.SendCommand(0x02, symArr);
            IsBusy = true;
            _decResponded = false;
            DecActual.Clear();
            OnPropertyChanged(nameof(DecStatus));
            Log($"解码请求: {symArr.Length} 符号 → {expected.Length} bit");

            DecExpected.Clear();
            foreach (var b in expected)
                DecExpected.Add(new ObservableSymbol { Value = b ? "1" : "0", IsCorrect = true });
        }

        // ================================================================
        // FPGA 应答
        // ================================================================
        private void OnFrame(byte cmd, byte status, byte[] payload)
        {
            IsBusy = false;

            if (status != 0x00)
            {
                string err = status switch { 0x01 => "FPGA忙", 0x02 => "校验错误", 0x03 => "无效命令", _ => $"状态{status}" };
                Log($"FPGA 错误: {err}");
                return;
            }

            if (cmd == 0x01) HandleEncResponse(payload);
            else if (cmd == 0x02) HandleDecResponse(payload);
        }

        private void HandleEncResponse(byte[] payload)
        {
            _encResponded = true;
            EncActual.Clear();
            _encAllMatch = payload.Length == EncExpected.Count;
            for (int i = 0; i < payload.Length; i++)
            {
                var exp = EncExpected.ElementAtOrDefault(i);
                bool ok = exp != null && exp.Value == HDB3Codec.SymbolToString(payload[i]);
                if (!ok) _encAllMatch = false;
                EncActual.Add(new ObservableSymbol { Value = HDB3Codec.SymbolToString(payload[i]), IsCorrect = ok });
            }
            OnPropertyChanged(nameof(EncStatus));
            if (payload.Length != EncExpected.Count)
                Log($"编码应答长度不一致: 期望 {EncExpected.Count}，实际 {payload.Length}");
            Log($"编码应答: {payload.Length} 符号, {(_encAllMatch ? "全部正确" : "存在差异")}");
        }

        private void HandleDecResponse(byte[] payload)
        {
            _decResponded = true;
            DecActual.Clear();
            _decAllMatch = payload.Length == DecExpected.Count;
            // payload 格式: 每字节一个 bit (0x00/0x01)
            for (int i = 0; i < payload.Length; i++)
            {
                var exp = DecExpected.ElementAtOrDefault(i);
                string val = (payload[i] != 0x00) ? "1" : "0";
                bool ok = exp != null && exp.Value == val;
                if (!ok) _decAllMatch = false;
                DecActual.Add(new ObservableSymbol { Value = val, IsCorrect = ok });
            }
            OnPropertyChanged(nameof(DecStatus));
            if (payload.Length != DecExpected.Count)
                Log($"解码应答长度不一致: 期望 {DecExpected.Count}，实际 {payload.Length}");
            Log($"解码应答: {payload.Length} bit, {(_decAllMatch ? "全部正确" : "存在差异")}");
        }

        // ================================================================
        // 日志
        // ================================================================
        private void Log(string msg)
        {
            string ts = DateTime.Now.ToString("HH:mm:ss");
            Application.Current.Dispatcher.Invoke(() =>
                LogText += $"[{ts}] {msg}\n");
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    public class RelayCommand : ICommand
    {
        private readonly Action<object> _exec;
        private readonly Func<object, bool> _canExec;
        public RelayCommand(Action<object> exec, Func<object, bool> canExec = null)
        { _exec = exec; _canExec = canExec; }
        public bool CanExecute(object p) => _canExec?.Invoke(p) ?? true;
        public void Execute(object p) => _exec(p);
        public event EventHandler CanExecuteChanged
        {
            add => CommandManager.RequerySuggested += value;
            remove => CommandManager.RequerySuggested -= value;
        }
    }
}
