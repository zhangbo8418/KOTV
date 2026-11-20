using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace KotvWin7Chrome
{
    public partial class MainWindow : Window
    {
        private OverlayController _controller;
        private Protocol _protocol;

        public MainWindow()
        {
            InitializeComponent();
            SourceInitialized += (_, __) =>
            {
                var hwnd = new WindowInteropHelper(this).Handle;
                var ex = GetWindowLong(hwnd, GWL_EXSTYLE);
                ex |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TOPMOST;
                SetWindowLong(hwnd, GWL_EXSTYLE, ex);
                var source = (HwndSource)PresentationSource.FromVisual(this);
                source?.AddHook(WndProc);
            };
            Loaded += (_, __) =>
            {
                _controller = new OverlayController(this, SurfaceHost, DanmakuLayer);
                _protocol = new Protocol(_controller);
                _protocol.Start();
                CompositionTarget.Rendering += OnRendering;
            };
        }

        private void OnRendering(object sender, EventArgs e)
        {
            _controller?.TickAlign();
        }

        protected override void OnClosed(EventArgs e)
        {
            CompositionTarget.Rendering -= OnRendering;
            _protocol?.Stop();
            base.OnClosed(e);
        }

        private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            const int WM_NCHITTEST = 0x0084;
            const int HTTRANSPARENT = -1;
            const int HTCLIENT = 1;
            if (msg != WM_NCHITTEST) return IntPtr.Zero;

            int x = (short)((uint)lParam.ToInt64() & 0xFFFF);
            int y = (short)(((uint)lParam.ToInt64() >> 16) & 0xFFFF);
            Point pt;
            try { pt = PointFromScreen(new Point(x, y)); }
            catch
            {
                handled = true;
                return new IntPtr(HTTRANSPARENT);
            }

            var hit = VisualTreeHelper.HitTest(Root, pt);
            if (hit?.VisualHit != null && IsInteractive(hit.VisualHit as DependencyObject))
            {
                handled = true;
                return new IntPtr(HTCLIENT);
            }
            handled = true;
            return new IntPtr(HTTRANSPARENT);
        }

        private static bool IsInteractive(DependencyObject d)
        {
            while (d != null)
            {
                if (d is System.Windows.Controls.Primitives.ButtonBase) return true;
                if (d is System.Windows.Controls.Primitives.RangeBase) return true;
                if (d is System.Windows.Controls.ListBoxItem) return true;
                if (d is System.Windows.Controls.ScrollViewer) return true;
                if (d is FrameworkElement fe && Equals(fe.Tag, "interactive")) return true;
                d = VisualTreeHelper.GetParent(d);
            }
            return false;
        }

        const int GWL_EXSTYLE = -20;
        const int WS_EX_TOOLWINDOW = 0x00000080;
        const int WS_EX_NOACTIVATE = 0x08000000;
        const int WS_EX_LAYERED = 0x00080000;
        const int WS_EX_TOPMOST = 0x00000008;

        [DllImport("user32.dll")]
        static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")]
        static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    }
}
