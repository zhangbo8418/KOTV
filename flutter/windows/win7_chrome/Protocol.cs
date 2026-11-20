using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace KotvWin7Chrome
{
    /// <summary>
    /// 与 C++ 桥进程约定：每行一条 JSON。
    /// 入站: {"id":1,"method":"updateFrame","args":{...}}
    /// 出站: {"id":1,"ok":true,"result":{...}} 或 {"event":"action","payload":{...}}
    /// </summary>
    public sealed class Protocol
    {
        private readonly OverlayController _ui;
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();
        private StreamWriter _out;

        public Protocol(OverlayController ui)
        {
            _ui = ui;
            _ui.ActionRaised += OnAction;
        }

        public void Start()
        {
            var stdin = Console.OpenStandardInput();
            var stdout = Console.OpenStandardOutput();
            _out = new StreamWriter(stdout) { AutoFlush = true };
            Task.Run(() => ReadLoop(stdin, _cts.Token));
            WriteEvent("ready", new JObject());
        }

        public void Stop()
        {
            try { _cts.Cancel(); } catch { }
        }

        private void OnAction(string name, JObject payload)
        {
            WriteRaw(new JObject
            {
                ["event"] = "action",
                ["payload"] = new JObject { ["name"] = name, ["data"] = payload ?? new JObject() }
            });
        }

        public static void WriteEvent(string name, object data)
        {
            // 启动早期尚未有实例时的兜底（错误路径）
            try
            {
                var w = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
                w.WriteLine(new JObject { ["event"] = name, ["payload"] = data == null ? null : JToken.FromObject(data) }.ToString(Formatting.None));
            }
            catch { }
        }

        private void WriteRaw(JObject obj)
        {
            try
            {
                lock (_out)
                {
                    _out.WriteLine(obj.ToString(Formatting.None));
                }
            }
            catch { }
        }

        private void Reply(long? id, bool ok, JToken result, string error)
        {
            var o = new JObject();
            if (id.HasValue) o["id"] = id.Value;
            o["ok"] = ok;
            if (error != null) o["error"] = error;
            if (result != null) o["result"] = result;
            WriteRaw(o);
        }

        private void ReadLoop(Stream stdin, CancellationToken ct)
        {
            using (var reader = new StreamReader(stdin))
            {
                while (!ct.IsCancellationRequested)
                {
                    string line;
                    try { line = reader.ReadLine(); }
                    catch { break; }
                    if (line == null) break;
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    Dispatch(line);
                }
            }
            Application.Current?.Dispatcher.BeginInvoke(new Action(() => Application.Current.Shutdown()));
        }

        private void Dispatch(string line)
        {
            JObject msg;
            try { msg = JObject.Parse(line); }
            catch { return; }

            var id = msg["id"]?.Value<long?>();
            var method = msg["method"]?.Value<string>() ?? "";
            var args = msg["args"] as JObject ?? new JObject();

            Application.Current?.Dispatcher.BeginInvoke(new Action(() =>
            {
                try
                {
                    var result = _ui.Handle(method, args);
                    Reply(id, true, result ?? new JObject(), null);
                }
                catch (Exception ex)
                {
                    Reply(id, false, null, ex.Message);
                }
            }), DispatcherPriority.Normal);
        }
    }
}
