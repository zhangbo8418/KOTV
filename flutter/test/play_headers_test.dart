import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/kotv_platform.dart';
import 'package:kotv/player/play_headers.dart';

void main() {
  test('header-capable player opens the site url', () {
    final got = kotvResolvePlayOpenTarget(
      playUrl: 'http://127.0.0.1:9978/proxy/rolling_m3u8?id=1',
      directUrl: 'https://cdn.example/live.m3u8',
      headers: const {'Cookie': 'a=b'},
      magnet: false,
      sendHeaders: true,
    );
    expect(got.url, 'https://cdn.example/live.m3u8');
    expect(got.headers?['Cookie'], 'a=b');
  });

  test('other players keep the engine url', () {
    final got = kotvResolvePlayOpenTarget(
      playUrl: 'http://127.0.0.1:9978/proxy/rolling_m3u8?id=1',
      directUrl: 'https://cdn.example/live.m3u8',
      headers: const {'Cookie': 'a=b'},
      magnet: false,
    );
    expect(got.url, contains('/proxy/rolling_m3u8'));
    expect(got.headers, isNull);
  });

  test('loopback site url stays on the engine url', () {
    final got = kotvResolvePlayOpenTarget(
      playUrl: 'http://127.0.0.1:9978/proxy/play?id=1',
      directUrl: 'http://127.0.0.1:5266/a.mp4',
      headers: const {'Cookie': 'a=b'},
      magnet: false,
      sendHeaders: true,
    );
    expect(got.url, contains('/proxy/play'));
    expect(got.headers, isNull);
  });

  test('hls.js html player opens the site url', () {
    expect(
      kotvPlaybackSendsHeaders(
        playerVal: 'innie#html',
        mediaUrl: 'https://cdn.example/live.m3u8',
        hlsJsSupported: true,
      ),
      isTrue,
    );
    final got = kotvResolvePlayOpenTarget(
      playUrl: 'http://127.0.0.1:9978/proxy/rolling_m3u8?id=1',
      directUrl: 'https://cdn.example/live.m3u8',
      headers: const {'Cookie': 'a=b'},
      magnet: false,
      sendHeaders: true,
    );
    expect(got.url, 'https://cdn.example/live.m3u8');
    expect(got.headers?['Cookie'], 'a=b');
  });

  test('native players and hls.js art can send headers; safari/xg cannot', () {
    expect(
      kotvPlaybackSendsHeaders(
        playerVal: 'innie#mpv',
        mediaUrl: 'https://cdn.example/live.m3u8',
      ),
      isTrue,
    );
    expect(
      kotvPlaybackSendsHeaders(
        playerVal: 'innie#fvp',
        mediaUrl: 'https://cdn.example/a.mp4',
      ),
      isTrue,
    );
    expect(
      kotvPlaybackSendsHeaders(
        playerVal: 'innie#html',
        mediaUrl: 'https://cdn.example/live.m3u8',
        hlsJsSupported: false,
      ),
      isFalse,
    );
    expect(
      kotvPlaybackSendsHeaders(
        playerVal: 'innie#art',
        mediaUrl: 'https://cdn.example/live.m3u8?x=1',
        hlsJsSupported: true,
      ),
      isTrue,
    );
    expect(
      kotvPlaybackSendsHeaders(
        playerVal: 'innie#art',
        mediaUrl: 'https://cdn.example/a.mp4',
        hlsJsSupported: true,
      ),
      isFalse,
    );
    expect(
      kotvPlaybackSendsHeaders(
        playerVal: 'innie#xg',
        mediaUrl: 'https://cdn.example/live.m3u8',
        hlsJsSupported: true,
      ),
      isFalse,
    );
  });

  test('empty site header uses okhttp ua, settings ua wins', () {
    kotvApplyPlayUaSetting('');
    expect(kotvDefaultPlayUA, 'okhttp/5.5.0');
    expect(
      kotvChromePlayUA,
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36',
    );
    expect(
      kotvNormalizePlayHeaders(const {}, url: 'https://cdn.example/a.m3u8')['User-Agent'],
      kotvIsDesktop() ? isNull : 'okhttp/5.5.0',
    );
    kotvSetPlatformPlayUa('com.bobo.kotv/1.2.3 (Linux;Android 16) ExoPlayerLib/1.11.0');
    expect(
      kotvNormalizePlayHeaders(const {}, url: 'https://cdn.example/a.m3u8')['User-Agent'],
      'com.bobo.kotv/1.2.3 (Linux;Android 16) ExoPlayerLib/1.11.0',
    );
    kotvSetPlatformPlayUa('');
    kotvApplyPlayUaSetting('CustomPlayer/1');
    expect(
      kotvNormalizePlayHeaders(const {}, url: 'https://cdn.example/a.m3u8')['User-Agent'],
      'CustomPlayer/1',
    );
    expect(
      kotvNormalizePlayHeaders(
        const {'User-Agent': 'from-site'},
        url: 'https://cdn.example/a.m3u8',
      )['User-Agent'],
      'from-site',
    );
    kotvApplyPlayUaSetting('');
  });
}
