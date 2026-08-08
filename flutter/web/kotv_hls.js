/* KO影视 Web：hls.js 胶水（Safari 原生 HLS，其它浏览器走 hls.js） */
(function (global) {
  'use strict';
  function destroy(video) {
    if (!video) return;
    try {
      if (video._kotvHls) {
        video._kotvHls.destroy();
        video._kotvHls = null;
      }
    } catch (_) {}
    try {
      video.removeAttribute('src');
      video.load();
    } catch (_) {}
  }

  function attach(video, url, headers) {
    destroy(video);
    if (!video || !url) return 'none';

    var HlsCtor = global.Hls;
    if (HlsCtor && typeof HlsCtor.isSupported === 'function' && HlsCtor.isSupported()) {
      var hls = new HlsCtor({
        enableWorker: true,
        lowLatencyMode: false,
        xhrSetup: function (xhr) {
          if (!headers) return;
          try {
            Object.keys(headers).forEach(function (k) {
              try {
                xhr.setRequestHeader(k, headers[k]);
              } catch (_) {}
            });
          } catch (_) {}
        },
      });
      hls.loadSource(url);
      hls.attachMedia(video);
      video._kotvHls = hls;
      return 'hls';
    }

    // Safari / iOS：原生 HLS
    if (video.canPlayType && video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = url;
      return 'native';
    }

    // 非 HLS 或无法探测：直链
    video.src = url;
    return 'html';
  }

  global.kotvHls = {
    ready: !!(global.Hls),
    attach: attach,
    destroy: destroy,
  };
})(typeof window !== 'undefined' ? window : globalThis);
