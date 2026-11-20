using System;
using System.Windows;

namespace KotvWin7Chrome
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            // 无控制台窗口：stdin/stdout 仍由父进程重定向管道提供
            DispatcherUnhandledException += (_, args) =>
            {
                try { Protocol.WriteEvent("error", args.Exception.Message); } catch { }
                args.Handled = true;
            };
        }
    }
}
