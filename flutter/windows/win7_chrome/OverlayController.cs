using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Newtonsoft.Json.Linq;

namespace KotvWin7Chrome
{
    /// <summary>
    /// Win7 专用：透明 WPF 遮罩上复刻播控 / 选集 / EPG / 弹层 / 弹幕。
    /// 与 Win8+ DComp（Flutter 直盖视频）完全独立。
    /// </summary>
    public sealed class OverlayController
    {
        // 与 Dart KotvWinChrome.topH / bottomH / episodeW 同源（逻辑像素）。
        const double TopH = 56;
        const double BottomH = 108;
        const double EpW = 280;
        const double LiveLeftW = 520;
        const double LiveRightW = 220;
        const double ChannelH = 48;
        const double CenterSz = 72;

        readonly Window _window;
        readonly Canvas _surface;
        readonly Canvas _danmaku;
        readonly DispatcherTimer _danmakuTimer;

        IntPtr _hostHwnd = IntPtr.Zero;
        bool _enabled;
        string _mode = "";
        string _title = "", _subtitle = "", _clock = "", _endsAt = "";
        string _posLabel = "", _durLabel = "";
        string _channelNo = "", _channelName = "", _channelProg = "", _channelTicker = "";
        double _anchorL, _anchorT, _anchorW, _anchorH;
        bool _anchorOk;
        double _surfaceL, _surfaceT, _surfaceW, _surfaceH;
        bool _surfaceOk;
        double _volume = 100;
        bool _volumeExpanded;
        bool _showDirect, _directOn, _miniActive;
        bool _topVis, _bottomVis, _epVis, _liveLVis, _liveRVis, _chVis, _centerVis;
        bool _playing = true, _buffering;
        double _progress, _positionSec, _rate = 1;
        readonly List<string> _episodes = new List<string>();
        int _epSelected = -1;
        readonly List<string> _groups = new List<string>();
        int _groupSelected = -1;
        readonly List<string> _channels = new List<string>();
        int _channelSelected = -1;
        readonly List<string> _epgDays = new List<string>();
        int _epgDaySelected;
        readonly List<string> _epgPrograms = new List<string>();
        int _epgProgramSelected = -1;
        readonly List<LineItem> _liveRight = new List<LineItem>();
        readonly List<LineItem> _moreItems = new List<LineItem>();
        readonly List<LineItem> _sheetItems = new List<LineItem>();
        string _sheetKind = "", _sheetTitle = "", _sheetSubtitle = "";
        int _sheetSelected;

        bool _dmEnabled;
        double _dmFont = 18, _dmOpacity = 0.85;
        int _dmDurationMs = 8000, _dmFixedMs = 5000, _dmRows = 6;
        bool _dmScroll = true, _dmTop = true, _dmBottom = true, _dmReverse = true;
        readonly List<DanmakuItem> _dmItems = new List<DanmakuItem>();
        readonly List<DanmakuFlight> _flights = new List<DanmakuFlight>();
        int _dmCursor;

        FrameworkElement _topBar, _bottomBar, _epPanel, _liveLeft, _liveRightPanel, _channelBar, _centerBtn;
        FrameworkElement _sheetPanel;
        Border _sheetBackdrop;

        public event Action<string, JObject> ActionRaised;

        public OverlayController(Window window, Canvas surface, Canvas danmaku)
        {
            _window = window;
            _surface = surface;
            _danmaku = danmaku;
            _danmakuTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
            _danmakuTimer.Tick += (_, __) => TickDanmaku();
        }

        public void TickAlign()
        {
            if (!_enabled || _hostHwnd == IntPtr.Zero)
            {
                if (_window.Visibility == Visibility.Visible) _window.Hide();
                return;
            }
            if (!GetClientRect(_hostHwnd, out var crc)) return;
            var origin = new POINT { X = 0, Y = 0 };
            if (!ClientToScreen(_hostHwnd, ref origin)) return;
            var w = Math.Max(1, crc.Right - crc.Left);
            var h = Math.Max(1, crc.Bottom - crc.Top);
            var src = PresentationSource.FromVisual(_window);
            var dpiX = src?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
            var dpiY = src?.CompositionTarget?.TransformToDevice.M22 ?? 1.0;
            var left = origin.X / dpiX;
            var top = origin.Y / dpiY;
            var width = w / dpiX;
            var height = h / dpiY;
            if (Math.Abs(_window.Left - left) > 0.5 || Math.Abs(_window.Top - top) > 0.5 ||
                Math.Abs(_window.Width - width) > 0.5 || Math.Abs(_window.Height - height) > 0.5)
            {
                _window.Left = left;
                _window.Top = top;
                _window.Width = width;
                _window.Height = height;
            }
            if (_window.Visibility != Visibility.Visible) _window.Show();
            // 保持置顶于宿主之上（不抢激活）
            SetWindowPos(new System.Windows.Interop.WindowInteropHelper(_window).Handle,
                HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }

        public JToken Handle(string method, JObject args)
        {
            switch (method)
            {
                case "setEnabled":
                    _enabled = args.Value<bool?>("enabled") ?? false;
                    if (args["hostHwnd"] != null)
                        _hostHwnd = new IntPtr(args.Value<long?>("hostHwnd") ?? args.Value<int?>("hostHwnd") ?? 0);
                    if (!_enabled)
                    {
                        CloseSheet();
                        ClearChrome();
                        _window.Hide();
                        _danmakuTimer.Stop();
                    }
                    else
                    {
                        Rebuild();
                        _danmakuTimer.Start();
                    }
                    return true;
                case "update":
                    IngestUpdate(args);
                    if (_enabled) Rebuild();
                    return true;
                case "setDanmaku":
                    IngestDanmaku(args);
                    if (_enabled) RebuildDanmakuLayer();
                    return true;
                case "showSheet":
                    IngestSheet(args);
                    RebuildSheet();
                    return true;
                case "hideSheet":
                    CloseSheet();
                    RebuildSheet();
                    return true;
                default:
                    return false;
            }
        }

        void Raise(string type, JObject data = null)
        {
            var payload = data ?? new JObject();
            payload["type"] = type;
            ActionRaised?.Invoke(type, payload);
        }

        void RaiseMap(JObject map) => ActionRaised?.Invoke(map.Value<string>("type") ?? "event", map);

        #region Ingest

        void IngestUpdate(JObject a)
        {
            if (a["mode"] != null)
            {
                var next = a.Value<string>("mode") ?? "";
                if (next != _mode) _volumeExpanded = false;
                _mode = next;
            }
            ReadRect(a["anchorScreen"] as JObject, ref _anchorL, ref _anchorT, ref _anchorW, ref _anchorH, out _anchorOk);
            ReadRect(a["surfaceScreen"] as JObject, ref _surfaceL, ref _surfaceT, ref _surfaceW, ref _surfaceH, out _surfaceOk);
            if (a["volume"] != null) _volume = a.Value<double>("volume");
            if (a["showDirect"] != null) _showDirect = a.Value<bool>("showDirect");
            if (a["directOn"] != null) _directOn = a.Value<bool>("directOn");
            if (a["miniActive"] != null) _miniActive = a.Value<bool>("miniActive");
            if (a["title"] != null) _title = a.Value<string>("title") ?? "";
            if (a["subtitle"] != null) _subtitle = a.Value<string>("subtitle") ?? "";
            if (a["resolution"] != null)
            {
                var r = a.Value<string>("resolution");
                if (!string.IsNullOrEmpty(r)) _subtitle = "[ " + r + " ]";
            }
            if (a["clock"] != null) _clock = a.Value<string>("clock") ?? "";
            if (a["endsAt"] != null) _endsAt = a.Value<string>("endsAt") ?? "";
            if (a["positionLabel"] != null) _posLabel = a.Value<string>("positionLabel") ?? "";
            if (a["durationLabel"] != null) _durLabel = a.Value<string>("durationLabel") ?? "";
            if (a["channelNo"] != null) _channelNo = a.Value<string>("channelNo") ?? "";
            if (a["channelName"] != null) _channelName = a.Value<string>("channelName") ?? "";
            if (a["channelProgram"] != null) _channelProg = a.Value<string>("channelProgram") ?? "";
            if (a["channelTicker"] != null) _channelTicker = a.Value<string>("channelTicker") ?? "";
            if (a["channelText"] != null) _channelName = a.Value<string>("channelText") ?? "";

            if (a["episodes"] is JArray ep) { _episodes.Clear(); foreach (var x in ep) _episodes.Add(x.ToString()); }
            if (a["episodeSelected"] != null) _epSelected = a.Value<int>("episodeSelected");
            if (a["groups"] is JArray g) { _groups.Clear(); foreach (var x in g) _groups.Add(x.ToString()); }
            if (a["groupSelected"] != null) _groupSelected = a.Value<int>("groupSelected");
            if (a["channels"] is JArray ch) { _channels.Clear(); foreach (var x in ch) _channels.Add(x.ToString()); }
            if (a["channelSelected"] != null) _channelSelected = a.Value<int>("channelSelected");
            if (a["liveLeft"] is JArray ll && _channels.Count == 0)
            {
                foreach (var x in ll) _channels.Add(x.ToString());
                if (a["liveLeftSelected"] != null) _channelSelected = a.Value<int>("liveLeftSelected");
            }
            if (a["epgDays"] is JArray ed) { _epgDays.Clear(); foreach (var x in ed) _epgDays.Add(x.ToString()); }
            if (a["epgDaySelected"] != null) _epgDaySelected = a.Value<int>("epgDaySelected");
            if (a["epgPrograms"] is JArray epg) { _epgPrograms.Clear(); foreach (var x in epg) _epgPrograms.Add(x.ToString()); }
            if (a["epgProgramSelected"] != null) _epgProgramSelected = a.Value<int>("epgProgramSelected");

            ParseItems(a["liveRightItems"] as JArray ?? a["liveRight"] as JArray, _liveRight);
            ParseItems(a["moreItems"] as JArray, _moreItems);

            if (a["top"] != null) _topVis = a.Value<bool>("top");
            if (a["bottom"] != null) _bottomVis = a.Value<bool>("bottom");
            if (a["episodesVisible"] != null) _epVis = a.Value<bool>("episodesVisible");
            if (a["liveLeftVisible"] != null) _liveLVis = a.Value<bool>("liveLeftVisible");
            if (a["liveRightVisible"] != null) _liveRVis = a.Value<bool>("liveRightVisible");
            if (a["channelVisible"] != null) _chVis = a.Value<bool>("channelVisible");
            if (a["centerVisible"] != null) _centerVis = a.Value<bool>("centerVisible");
            if (a["playing"] != null) _playing = a.Value<bool>("playing");
            if (a["buffering"] != null) _buffering = a.Value<bool>("buffering");
            if (a["progress"] != null) _progress = a.Value<double>("progress");
            if (a["positionSec"] != null) _positionSec = a.Value<double>("positionSec");
            else if (a["position"] != null) _positionSec = a.Value<double>("position");
            if (a["rate"] != null) _rate = a.Value<double>("rate");
            if (a["danmaku"] is JObject dm) IngestDanmaku(dm);
        }

        void IngestDanmaku(JObject a)
        {
            if (a["enabled"] != null) _dmEnabled = a.Value<bool>("enabled");
            if (a["fontSize"] != null) _dmFont = a.Value<double>("fontSize");
            if (a["opacity"] != null) _dmOpacity = a.Value<double>("opacity");
            if (a["durationMs"] != null) _dmDurationMs = a.Value<int>("durationMs");
            if (a["fixedDurationMs"] != null) _dmFixedMs = a.Value<int>("fixedDurationMs");
            else if (a["fixedMs"] != null) _dmFixedMs = a.Value<int>("fixedMs");
            if (a["rows"] != null) _dmRows = a.Value<int>("rows");
            if (a["showScroll"] != null) _dmScroll = a.Value<bool>("showScroll");
            if (a["showTop"] != null) _dmTop = a.Value<bool>("showTop");
            if (a["showBottom"] != null) _dmBottom = a.Value<bool>("showBottom");
            if (a["showReverse"] != null) _dmReverse = a.Value<bool>("showReverse");
            if (a["items"] is JArray items)
            {
                _dmItems.Clear();
                _dmCursor = 0;
                _flights.Clear();
                _danmaku.Children.Clear();
                foreach (var t in items)
                {
                    if (!(t is JObject row)) continue;
                    var d = new DanmakuItem
                    {
                        Time = row.Value<double?>("t") ?? row.Value<double?>("time") ?? 0,
                        Content = row.Value<string>("c") ?? row.Value<string>("content") ?? "",
                        Mode = row.Value<int?>("m") ?? row.Value<int?>("mode") ?? 1,
                        Color = row.Value<int?>("color") ?? 0xFFFFFF,
                        Size = row.Value<int?>("size") ?? 25,
                    };
                    if (!string.IsNullOrEmpty(d.Content)) _dmItems.Add(d);
                }
                _dmItems.Sort((x, y) => x.Time.CompareTo(y.Time));
            }
        }

        void IngestSheet(JObject a)
        {
            _sheetKind = a.Value<string>("kind") ?? "";
            if (string.IsNullOrEmpty(_sheetKind))
            {
                CloseSheet();
                return;
            }
            _sheetTitle = a.Value<string>("title") ?? "";
            _sheetSubtitle = a.Value<string>("subtitle") ?? "";
            ParseItems(a["items"] as JArray, _sheetItems);
            _sheetSelected = a.Value<int?>("selected") ?? 0;
        }

        void CloseSheet()
        {
            _sheetKind = "";
            _sheetItems.Clear();
            _sheetTitle = "";
            _sheetSubtitle = "";
        }

        static void ReadRect(JObject o, ref double l, ref double t, ref double w, ref double h, out bool ok)
        {
            ok = false;
            if (o == null) return;
            l = o.Value<double?>("left") ?? 0;
            t = o.Value<double?>("top") ?? 0;
            w = o.Value<double?>("width") ?? 0;
            h = o.Value<double?>("height") ?? 0;
            ok = w >= 8 && h >= 8;
        }

        static void ParseItems(JArray arr, List<LineItem> dest)
        {
            if (arr == null) return;
            dest.Clear();
            foreach (var t in arr)
            {
                if (t is JObject row)
                {
                    dest.Add(new LineItem
                    {
                        Id = row.Value<string>("id") ?? "",
                        Label = row.Value<string>("label") ?? "",
                        Trailing = row.Value<string>("trailing") ?? "",
                        Toggle = row.Value<bool?>("toggle") ?? false,
                        On = row.Value<bool?>("on") ?? false,
                        Chevron = row.Value<bool?>("chevron") ?? true,
                        Slider = row.Value<bool?>("slider") ?? false,
                        SliderMin = row.Value<double?>("min") ?? 0,
                        SliderMax = row.Value<double?>("max") ?? 100,
                        SliderValue = row.Value<double?>("value") ?? 0,
                    });
                }
                else
                {
                    dest.Add(new LineItem { Id = dest.Count.ToString(), Label = t.ToString() });
                }
            }
        }

        #endregion

        #region Rebuild chrome

        void ClearChrome()
        {
            _surface.Children.Clear();
            _topBar = _bottomBar = _epPanel = _liveLeft = _liveRightPanel = _channelBar = _centerBtn = null;
            _sheetPanel = null;
            _sheetBackdrop = null;
        }

        void Rebuild()
        {
            ClearChrome();
            if (!_enabled) return;
            var dpi = DpiScale();
            var clientW = _window.ActualWidth > 1 ? _window.ActualWidth : 1280;
            var clientH = _window.ActualHeight > 1 ? _window.ActualHeight : 720;

            if (_mode == "vod_inline")
            {
                if (_bottomVis && _anchorOk)
                {
                    var ax = _anchorL; // 逻辑坐标（与 Dart localToGlobal 一致）
                    var ay = _anchorT;
                    var aw = _anchorW;
                    var ah = _anchorH;
                    _bottomBar = BuildInlineBottom(aw, ah);
                    Place(_bottomBar, ax, ay, aw, ah);
                }
            }
            else
            {
                if (_topVis)
                {
                    _topBar = BuildTopBar(clientW);
                    Place(_topBar, 0, 0, clientW, TopH);
                }
                if (_bottomVis)
                {
                    _bottomBar = BuildFullscreenBottom(clientW);
                    Place(_bottomBar, 0, clientH - BottomH, clientW, BottomH);
                }
                var epTop = _topVis ? TopH : 0;
                var epBot = _bottomVis ? BottomH : 0;
                if (_epVis)
                {
                    _epPanel = BuildEpisodes(EpW, Math.Max(0, clientH - epTop - epBot));
                    Place(_epPanel, clientW - EpW, epTop, EpW, Math.Max(0, clientH - epTop - epBot));
                }
                var liveTop = TopH + 8;
                var liveH = clientH - liveTop - (_chVis ? ChannelH + 12 : 12) - (_bottomVis ? BottomH : 0);
                liveH = Math.Max(120, liveH);
                if (_liveLVis)
                {
                    _liveLeft = BuildLiveLeft(LiveLeftW, liveH);
                    Place(_liveLeft, 12, liveTop, LiveLeftW, liveH);
                }
                if (_liveRVis)
                {
                    _liveRightPanel = BuildLiveRight(LiveRightW, liveH);
                    Place(_liveRightPanel, clientW - LiveRightW - 12, liveTop, LiveRightW, liveH);
                }
                if (_chVis)
                {
                    _channelBar = BuildChannelBar(clientW - 48);
                    Place(_channelBar, 24, clientH - BottomH - ChannelH - 10, clientW - 48, ChannelH);
                }
                if (_centerVis)
                {
                    _centerBtn = BuildCenter();
                    Place(_centerBtn, (clientW - CenterSz) / 2, (clientH - CenterSz) / 2, CenterSz, CenterSz);
                }
            }
            RebuildDanmakuLayer();
            RebuildSheet();
            _ = dpi;
        }

        double DpiScale()
        {
            var src = PresentationSource.FromVisual(_window);
            return src?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        }

        void Place(FrameworkElement el, double x, double y, double w, double h)
        {
            if (el == null) return;
            el.Width = Math.Max(1, w);
            el.Height = Math.Max(1, h);
            Canvas.SetLeft(el, x);
            Canvas.SetTop(el, y);
            _surface.Children.Add(el);
        }

        FrameworkElement BuildTopBar(double w)
        {
            var root = PanelBox();
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var title = new TextBlock
            {
                Text = string.IsNullOrEmpty(_subtitle) ? _title : _title + "  " + _subtitle,
                Foreground = Brush("ChromeFg"),
                FontSize = 15,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(16, 0, 8, 0),
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Grid.SetColumn(title, 0);
            grid.Children.Add(title);
            var exit = ChromeButton("退出", () => Raise("exit"));
            exit.Margin = new Thickness(0, 0, 12, 0);
            Grid.SetColumn(exit, 1);
            grid.Children.Add(exit);
            root.Child = grid;
            return root;
        }

        FrameworkElement BuildInlineBottom(double w, double h)
        {
            var root = PanelBox(bar: true);
            root.Tag = "interactive";
            var stack = new DockPanel { LastChildFill = true, Margin = new Thickness(6, 4, 6, 4) };

            // 进度条贴底
            var seek = new Slider
            {
                Minimum = 0, Maximum = 1, Value = Math.Max(0, Math.Min(1, _progress)),
                Height = 18, VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(4, 0, 4, 0),
            };
            seek.PreviewMouseLeftButtonUp += (_, __) =>
                RaiseMap(new JObject { ["type"] = "seekFraction", ["value"] = seek.Value });
            DockPanel.SetDock(seek, Dock.Bottom);
            stack.Children.Add(seek);

            var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            void AddBtn(string label, string type)
            {
                var b = ChromeButton(label, () => Raise(type));
                b.Width = 36; b.Height = 32; b.Margin = new Thickness(1, 0, 1, 0); b.Padding = new Thickness(0);
                b.FontSize = 11;
                row.Children.Add(b);
            }
            // 顺序对齐 Flutter VodInlineControls：播停 / [直出] / 投屏 / 迷你 / 全屏 / 弹幕 / 更多 / 音量
            AddBtn(_playing ? "暂停" : "播放", "toggle");
            AddBtn("停止", "stop");
            if (_showDirect) AddBtn(_directOn ? "直出●" : "直出", "direct");
            AddBtn("投屏", "cast");
            AddBtn(_miniActive ? "迷你●" : "迷你", "mini");
            AddBtn("全屏", "expand");
            AddBtn(_dmEnabled ? "弹幕●" : "弹幕", "danmakuToggle");
            AddBtn("更多", "more");

            var volBtn = ChromeButton(_volumeExpanded ? "音量▾" : "音量", () =>
            {
                _volumeExpanded = !_volumeExpanded;
                Rebuild();
            });
            volBtn.Width = 40; volBtn.Height = 32; volBtn.FontSize = 11; volBtn.Margin = new Thickness(4, 0, 2, 0);
            row.Children.Add(volBtn);
            if (_volumeExpanded)
            {
                var vs = new Slider
                {
                    Minimum = 1, Maximum = 100, Value = _volume, Width = 90, Height = 28,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                vs.ValueChanged += (_, e) =>
                {
                    _volume = e.NewValue;
                    RaiseMap(new JObject { ["type"] = "slider", ["id"] = "volume", ["value"] = _volume, ["commit"] = false });
                };
                vs.PreviewMouseLeftButtonUp += (_, __) =>
                    RaiseMap(new JObject { ["type"] = "slider", ["id"] = "volume", ["value"] = _volume, ["commit"] = true });
                row.Children.Add(vs);
            }

            stack.Children.Add(row);
            root.Child = stack;
            return root;
        }

        FrameworkElement BuildFullscreenBottom(double w)
        {
            var root = PanelBox(bar: true);
            root.Tag = "interactive";
            var dock = new DockPanel { Margin = new Thickness(16, 8, 16, 8) };

            var seek = new Slider
            {
                Minimum = 0, Maximum = 1, Value = Math.Max(0, Math.Min(1, _progress)),
                Height = 22, Margin = new Thickness(0, 0, 0, 6),
            };
            seek.PreviewMouseLeftButtonUp += (_, __) =>
                RaiseMap(new JObject { ["type"] = "seekFraction", ["value"] = seek.Value });
            DockPanel.SetDock(seek, Dock.Top);
            dock.Children.Add(seek);

            var meta = new TextBlock
            {
                Text = (_posLabel + " / " + _durLabel + "   " + _clock + "   " + _endsAt).Trim(),
                Foreground = Brush("ChromeMuted"),
                FontSize = 12,
                Margin = new Thickness(0, 0, 0, 6),
            };
            DockPanel.SetDock(meta, Dock.Top);
            dock.Children.Add(meta);

            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(ChromeButton("上一集", () => Raise("prev")));
            row.Children.Add(ChromeButton(_playing ? "暂停" : "播放", () => Raise("toggle")));
            row.Children.Add(ChromeButton("下一集", () => Raise("next")));
            row.Children.Add(ChromeButton("更多", () =>
            {
                if (_moreItems.Count > 0)
                {
                    _sheetKind = "more";
                    _sheetTitle = "更多";
                    _sheetSubtitle = "";
                    _sheetItems.Clear();
                    _sheetItems.AddRange(_moreItems);
                    _sheetSelected = 0;
                    RebuildSheet();
                }
                else RaiseMap(new JObject { ["type"] = "more", ["id"] = "open" });
            }));
            dock.Children.Add(row);
            root.Child = dock;
            return root;
        }

        FrameworkElement BuildEpisodes(double w, double h)
        {
            var root = PanelBox();
            root.Tag = "interactive";
            var list = new ListBox
            {
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Foreground = Brush("ChromeFg"),
            };
            for (int i = 0; i < _episodes.Count; i++)
            {
                var idx = i;
                var item = new ListBoxItem
                {
                    Content = _episodes[i],
                    IsSelected = i == _epSelected,
                    Foreground = i == _epSelected ? Brush("ChromeAccent") : Brush("ChromeFg"),
                    Padding = new Thickness(12, 10, 12, 10),
                };
                item.PreviewMouseLeftButtonUp += (_, __) =>
                    RaiseMap(new JObject { ["type"] = "episode", ["index"] = idx });
                list.Items.Add(item);
            }
            var header = new TextBlock
            {
                Text = "选集", Foreground = Brush("ChromeFg"), FontSize = 14,
                Margin = new Thickness(12, 10, 12, 6), FontWeight = FontWeights.SemiBold,
            };
            var stack = new DockPanel();
            DockPanel.SetDock(header, Dock.Top);
            stack.Children.Add(header);
            stack.Children.Add(list);
            root.Child = stack;
            return root;
        }

        FrameworkElement BuildLiveLeft(double w, double h)
        {
            var root = PanelBox();
            root.Tag = "interactive";
            var grid = new Grid();
            if (_groups.Count == 0)
            {
                var list = MakeIndexList(_channels, _channelSelected, idx =>
                {
                    _channelSelected = idx;
                    RaiseMap(new JObject { ["type"] = "liveLeft", ["index"] = idx });
                    Rebuild();
                });
                root.Child = list;
                return root;
            }
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var gList = MakeIndexList(_groups, _groupSelected, idx =>
            {
                _groupSelected = idx;
                RaiseMap(new JObject { ["type"] = "group", ["index"] = idx });
                Rebuild();
            });
            Grid.SetColumn(gList, 0);
            grid.Children.Add(gList);
            var cList = MakeIndexList(_channels, _channelSelected, idx =>
            {
                _channelSelected = idx;
                RaiseMap(new JObject { ["type"] = "liveLeft", ["index"] = idx });
                RaiseMap(new JObject { ["type"] = "channel", ["index"] = idx });
                Rebuild();
            });
            Grid.SetColumn(cList, 1);
            grid.Children.Add(cList);

            var epg = new DockPanel();
            var days = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4) };
            for (int i = 0; i < _epgDays.Count; i++)
            {
                var idx = i;
                var b = ChromeButton(_epgDays[i], () =>
                {
                    _epgDaySelected = idx;
                    RaiseMap(new JObject { ["type"] = "epgDay", ["index"] = idx });
                    Rebuild();
                });
                b.FontSize = 11; b.Padding = new Thickness(6, 2, 6, 2);
                if (i == _epgDaySelected) b.Foreground = Brush("ChromeAccent");
                days.Children.Add(b);
            }
            DockPanel.SetDock(days, Dock.Top);
            epg.Children.Add(days);
            epg.Children.Add(MakeIndexList(_epgPrograms, _epgProgramSelected, idx =>
            {
                _epgProgramSelected = idx;
                RaiseMap(new JObject { ["type"] = "epg", ["index"] = idx });
            }));
            Grid.SetColumn(epg, 2);
            grid.Children.Add(epg);

            var dock = new DockPanel();
            var collapse = ChromeButton("收起", () => Raise("collapseLiveLeft"));
            collapse.Height = 32;
            DockPanel.SetDock(collapse, Dock.Bottom);
            dock.Children.Add(collapse);
            dock.Children.Add(grid);
            root.Child = dock;
            return root;
        }

        FrameworkElement BuildLiveRight(double w, double h)
        {
            var root = PanelBox();
            root.Tag = "interactive";
            var list = new StackPanel { Margin = new Thickness(8, 40, 8, 8) };
            for (int i = 0; i < _liveRight.Count; i++)
            {
                var item = _liveRight[i];
                var idx = i;
                var row = ChromeButton(item.Label + (string.IsNullOrEmpty(item.Trailing) ? "" : "  " + item.Trailing),
                    () => RaiseMap(new JObject { ["type"] = "liveRight", ["index"] = idx, ["id"] = item.Id }));
                row.HorizontalContentAlignment = HorizontalAlignment.Left;
                row.Height = 44;
                row.Margin = new Thickness(0, 0, 0, 6);
                list.Children.Add(row);
            }
            root.Child = list;
            return root;
        }

        FrameworkElement BuildChannelBar(double w)
        {
            var root = PanelBox(bar: true);
            root.Child = new TextBlock
            {
                Text = (_channelNo + "  " + _channelName + "  " + _channelProg + "  " + _channelTicker).Trim(),
                Foreground = Brush("ChromeFg"),
                FontSize = 14,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(16, 0, 16, 0),
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            return root;
        }

        FrameworkElement BuildCenter()
        {
            var b = ChromeButton(_buffering ? "…" : (_playing ? "❚❚" : "▶"), () => Raise("togglePlay"));
            b.Width = CenterSz; b.Height = CenterSz; b.FontSize = 22;
            b.Tag = "interactive";
            return b;
        }

        ListBox MakeIndexList(List<string> items, int selected, Action<int> onPick)
        {
            var list = new ListBox
            {
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Foreground = Brush("ChromeFg"),
            };
            for (int i = 0; i < items.Count; i++)
            {
                var idx = i;
                var it = new ListBoxItem
                {
                    Content = items[i],
                    IsSelected = i == selected,
                    Foreground = i == selected ? Brush("ChromeAccent") : Brush("ChromeFg"),
                    Padding = new Thickness(10, 8, 10, 8),
                };
                it.PreviewMouseLeftButtonUp += (_, __) => onPick(idx);
                list.Items.Add(it);
            }
            return list;
        }

        #endregion

        #region Sheet

        void RebuildSheet()
        {
            if (_sheetBackdrop != null) { _surface.Children.Remove(_sheetBackdrop); _sheetBackdrop = null; }
            if (_sheetPanel != null) { _surface.Children.Remove(_sheetPanel); _sheetPanel = null; }
            if (string.IsNullOrEmpty(_sheetKind) || _sheetItems.Count == 0) return;

            _sheetBackdrop = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(100, 0, 0, 0)),
                Tag = "interactive",
            };
            _sheetBackdrop.Width = Math.Max(1, _window.ActualWidth);
            _sheetBackdrop.Height = Math.Max(1, _window.ActualHeight);
            Canvas.SetLeft(_sheetBackdrop, 0);
            Canvas.SetTop(_sheetBackdrop, 0);
            _sheetBackdrop.MouseLeftButtonUp += (_, __) =>
            {
                var kind = _sheetKind;
                CloseSheet();
                RebuildSheet();
                RaiseMap(new JObject { ["type"] = "sheetClose", ["kind"] = kind, ["sheet"] = kind });
            };
            _surface.Children.Add(_sheetBackdrop);

            var light = _sheetKind == "danmaku" || _sheetKind == "volume";
            var rowH = light ? 56.0 : 48.0;
            var header = light ? 52.0 : (string.IsNullOrEmpty(_sheetSubtitle) ? 40.0 : 54.0);
            var h = Math.Min(520, header + _sheetItems.Count * rowH + 24);
            var w = light ? 380.0 : 320.0;
            var panel = new Border
            {
                Width = w,
                Height = h,
                CornerRadius = new CornerRadius(16),
                Background = light
                    ? new SolidColorBrush(Color.FromRgb(248, 246, 250))
                    : (Brush)Application.Current.Resources["ChromePanel"],
                Tag = "interactive",
            };
            var dock = new DockPanel { Margin = new Thickness(12) };
            var titleBlock = new TextBlock
            {
                Text = _sheetTitle,
                FontSize = 16,
                FontWeight = FontWeights.SemiBold,
                Foreground = light ? Brushes.Black : Brush("ChromeFg"),
                Margin = new Thickness(4, 4, 4, 2),
            };
            DockPanel.SetDock(titleBlock, Dock.Top);
            dock.Children.Add(titleBlock);
            if (!string.IsNullOrEmpty(_sheetSubtitle))
            {
                var sub = new TextBlock
                {
                    Text = _sheetSubtitle,
                    FontSize = 12,
                    Foreground = light ? Brushes.Gray : Brush("ChromeMuted"),
                    Margin = new Thickness(4, 0, 4, 8),
                };
                DockPanel.SetDock(sub, Dock.Top);
                dock.Children.Add(sub);
            }

            var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            var stack = new StackPanel();
            for (int i = 0; i < _sheetItems.Count; i++)
            {
                var item = _sheetItems[i];
                var idx = i;
                if (item.Slider)
                {
                    var lab = new TextBlock
                    {
                        Text = item.Label + "  " + item.Trailing,
                        Foreground = light ? Brushes.Black : Brush("ChromeFg"),
                        Margin = new Thickness(4, 8, 4, 0),
                    };
                    var sl = new Slider
                    {
                        Minimum = item.SliderMin,
                        Maximum = item.SliderMax,
                        Value = item.SliderValue,
                        Margin = new Thickness(4, 0, 4, 8),
                    };
                    sl.ValueChanged += (_, e) =>
                        RaiseMap(new JObject
                        {
                            ["type"] = "slider",
                            ["id"] = item.Id,
                            ["value"] = e.NewValue,
                            ["commit"] = false,
                            ["kind"] = _sheetKind,
                            ["sheet"] = _sheetKind,
                        });
                    sl.PreviewMouseLeftButtonUp += (_, __) =>
                        RaiseMap(new JObject
                        {
                            ["type"] = "slider",
                            ["id"] = item.Id,
                            ["value"] = sl.Value,
                            ["commit"] = true,
                            ["kind"] = _sheetKind,
                            ["sheet"] = _sheetKind,
                        });
                    stack.Children.Add(lab);
                    stack.Children.Add(sl);
                    continue;
                }
                var btn = new Button
                {
                    Content = BuildSheetRow(item, light),
                    Background = Brushes.Transparent,
                    BorderThickness = new Thickness(0),
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    Height = rowH,
                    Tag = "interactive",
                };
                btn.Click += (_, __) => OnSheetItem(item, idx);
                stack.Children.Add(btn);
            }
            scroll.Content = stack;
            dock.Children.Add(scroll);
            panel.Child = dock;

            Canvas.SetLeft(panel, Math.Max(0, (_window.ActualWidth - w) / 2));
            Canvas.SetTop(panel, Math.Max(0, (_window.ActualHeight - h) / 2));
            _sheetPanel = panel;
            _surface.Children.Add(panel);
        }

        UIElement BuildSheetRow(LineItem item, bool light)
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var label = new TextBlock
            {
                Text = item.Label,
                Foreground = light ? Brushes.Black : Brush("ChromeFg"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 0, 8, 0),
            };
            Grid.SetColumn(label, 0);
            g.Children.Add(label);
            string trail = item.Trailing;
            if (item.Toggle) trail = item.On ? "开" : "关";
            else if (item.Chevron && string.IsNullOrEmpty(trail)) trail = "›";
            var trailing = new TextBlock
            {
                Text = trail,
                Foreground = light ? Brushes.Gray : Brush("ChromeMuted"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 0, 8, 0),
            };
            Grid.SetColumn(trailing, 1);
            g.Children.Add(trailing);
            return g;
        }

        void OnSheetItem(LineItem item, int idx)
        {
            var kind = _sheetKind;
            if (item.Toggle)
            {
                RaiseMap(new JObject
                {
                    ["type"] = "toggleItem",
                    ["id"] = item.Id,
                    ["on"] = !item.On,
                    ["kind"] = kind,
                    ["sheet"] = kind,
                });
                return;
            }
            if (kind == "player" || kind == "pickPlayer")
            {
                RaiseMap(new JObject { ["type"] = "pickPlayer", ["id"] = item.Id, ["kind"] = kind, ["sheet"] = kind });
                CloseSheet();
                RebuildSheet();
                return;
            }
            if (kind == "more")
            {
                RaiseMap(new JObject { ["type"] = "more", ["id"] = item.Id, ["kind"] = kind, ["sheet"] = kind });
                // 子菜单由 Dart 再 showSheet；此处先关
                CloseSheet();
                RebuildSheet();
                return;
            }
            RaiseMap(new JObject
            {
                ["type"] = "sheet",
                ["id"] = item.Id,
                ["index"] = idx,
                ["kind"] = kind,
                ["sheet"] = kind,
            });
            CloseSheet();
            RebuildSheet();
        }

        #endregion

        #region Danmaku

        void RebuildDanmakuLayer()
        {
            _danmaku.Children.Clear();
            _flights.Clear();
            if (!_dmEnabled) return;
            double x = 0, y = 0, w = 0, h = 0;
            if (_mode == "vod_inline")
            {
                if (!_surfaceOk) return;
                x = _surfaceL; y = _surfaceT; w = _surfaceW; h = _surfaceH;
                if (_anchorOk && _anchorH > 0 && _anchorT + _anchorH <= y + h)
                    h = Math.Max(0, _anchorT - y);
            }
            else
            {
                w = Math.Max(1, _window.ActualWidth);
                h = Math.Max(1, _window.ActualHeight);
            }
            if (w < 8 || h < 8) return;
            _danmaku.Width = w;
            _danmaku.Height = h;
            Canvas.SetLeft(_danmaku, x);
            Canvas.SetTop(_danmaku, y);
            // 按当前进度播种已到点弹幕
            _dmCursor = 0;
            while (_dmCursor < _dmItems.Count && _dmItems[_dmCursor].Time <= _positionSec + 0.05)
                _dmCursor++;
        }

        void TickDanmaku()
        {
            if (!_dmEnabled || _danmaku.Width < 8) return;
            while (_dmCursor < _dmItems.Count && _dmItems[_dmCursor].Time <= _positionSec + 0.2)
            {
                Spawn(_dmItems[_dmCursor]);
                _dmCursor++;
            }
            var dead = new List<DanmakuFlight>();
            foreach (var f in _flights)
            {
                f.AgeMs += 33;
                if (f.Mode == 1 || f.Mode == 6)
                {
                    var t = Math.Min(1.0, f.AgeMs / (double)Math.Max(1, f.LifeMs));
                    var from = f.Mode == 6 ? -f.Width : _danmaku.Width;
                    var to = f.Mode == 6 ? _danmaku.Width : -f.Width;
                    Canvas.SetLeft(f.Element, from + (to - from) * t);
                    if (f.AgeMs >= f.LifeMs) dead.Add(f);
                }
                else
                {
                    if (f.AgeMs >= f.LifeMs) dead.Add(f);
                }
            }
            foreach (var d in dead)
            {
                _danmaku.Children.Remove(d.Element);
                _flights.Remove(d);
            }
        }

        void Spawn(DanmakuItem d)
        {
            if (d.Mode == 1 && !_dmScroll) return;
            if (d.Mode == 6 && !_dmReverse) return;
            if (d.Mode == 5 && !_dmTop) return;
            if (d.Mode == 4 && !_dmBottom) return;

            var color = Color.FromRgb((byte)((d.Color >> 16) & 0xFF), (byte)((d.Color >> 8) & 0xFF), (byte)(d.Color & 0xFF));
            var tb = new TextBlock
            {
                Text = d.Content,
                FontSize = Math.Max(12, _dmFont * (d.Size / 25.0)),
                Foreground = new SolidColorBrush(Color.FromArgb((byte)(_dmOpacity * 255), color.R, color.G, color.B)),
                FontWeight = FontWeights.SemiBold,
                Effect = new System.Windows.Media.Effects.DropShadowEffect
                {
                    Color = Colors.Black, BlurRadius = 2, ShadowDepth = 0, Opacity = 0.7,
                },
            };
            tb.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var tw = tb.DesiredSize.Width;
            var th = tb.DesiredSize.Height;
            var rows = Math.Max(1, _dmRows);
            var rowH = Math.Max(th + 4, _danmaku.Height / rows);
            int row = (_flights.Count) % rows;
            double y;
            if (d.Mode == 5) y = 4 + row * rowH;
            else if (d.Mode == 4) y = Math.Max(0, _danmaku.Height - (row + 1) * rowH - 4);
            else y = 4 + row * rowH;

            Canvas.SetTop(tb, y);
            Canvas.SetLeft(tb, d.Mode == 5 || d.Mode == 4 ? (_danmaku.Width - tw) / 2 : _danmaku.Width);
            _danmaku.Children.Add(tb);
            _flights.Add(new DanmakuFlight
            {
                Element = tb,
                Mode = d.Mode,
                Width = tw,
                LifeMs = (d.Mode == 4 || d.Mode == 5) ? _dmFixedMs : _dmDurationMs,
            });
        }

        #endregion

        #region Widgets helpers

        Border PanelBox(bool bar = false)
        {
            return new Border
            {
                Background = bar
                    ? (Brush)Application.Current.Resources["ChromeBar"]
                    : (Brush)Application.Current.Resources["ChromePanel"],
                CornerRadius = new CornerRadius(bar ? 0 : 10),
            };
        }

        Button ChromeButton(string text, Action onClick)
        {
            var b = new Button
            {
                Content = text,
                Foreground = Brush("ChromeFg"),
                Background = new SolidColorBrush(Color.FromArgb(40, 255, 255, 255)),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(12, 6, 12, 6),
                Margin = new Thickness(4, 0, 4, 0),
                FontSize = 13,
                Tag = "interactive",
                Cursor = System.Windows.Input.Cursors.Hand,
            };
            b.Click += (_, __) => onClick();
            return b;
        }

        static Brush Brush(string key) => (Brush)Application.Current.Resources[key];

        #endregion

        #region models / win32

        sealed class LineItem
        {
            public string Id, Label, Trailing;
            public bool Toggle, On, Chevron, Slider;
            public double SliderMin, SliderMax, SliderValue;
        }

        sealed class DanmakuItem
        {
            public double Time;
            public string Content;
            public int Mode, Color, Size;
        }

        sealed class DanmakuFlight
        {
            public FrameworkElement Element;
            public int Mode, LifeMs, AgeMs;
            public double Width;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        struct POINT { public int X, Y; }

        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        const uint SWP_NOMOVE = 0x0002, SWP_NOSIZE = 0x0001, SWP_NOACTIVATE = 0x0010;

        [DllImport("user32.dll")]
        static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")]
        static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
        [DllImport("user32.dll")]
        static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        #endregion
    }
}
