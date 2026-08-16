/* KO影视 Web：ArtPlayer 胶水（关自带控件，HLS 复用已有 hls.js） */
(function (global) {
  'use strict';

  function isHlsUrl(url) {
    if (!url) return false;
    var u = String(url).split('?')[0].toLowerCase();
    return u.indexOf('.m3u8') >= 0;
  }

  function destroy(container) {
    if (!container) return;
    try {
      if (container._kotvArt) {
        container._kotvArt.destroy(false);
        container._kotvArt = null;
      }
    } catch (_) {}
    try {
      container.innerHTML = '';
    } catch (_) {}
  }

  function attachHls(video, url, headers, art) {
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
      art._kotvHls = hls;
      art.on('destroy', function () {
        try {
          hls.destroy();
        } catch (_) {}
        art._kotvHls = null;
      });
      return 'hls';
    }
    if (video.canPlayType && video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = url;
      return 'native';
    }
    video.src = url;
    return 'html';
  }

  function create(container, url, headers) {
    destroy(container);
    if (!container || !url) return 'none';
    var Art = global.Artplayer;
    if (!Art) {
      console.warn('kotvArt: Artplayer missing');
      return 'none';
    }

    var mode = 'html';
    var art = new Art({
      container: container,
      url: url,
      type: isHlsUrl(url) ? 'm3u8' : undefined,
      autoplay: true,
      autoSize: false,
      autoOrientation: false,
      fullscreen: false,
      fullscreenWeb: false,
      pip: false,
      setting: false,
      hotkey: false,
      mutex: false,
      backdrop: false,
      miniProgressBar: false,
      theme: '#cf4274',
      lang: 'zh-cn',
      moreVideoAttr: {
        playsinline: true,
        'webkit-playsinline': true,
        crossOrigin: 'anonymous',
      },
      // 关掉自带控件，继续用 Flutter 顶底栏
      controls: [],
      icons: {},
      layers: [],
      contextmenu: [],
      settings: [],
      css: [
        '.art-video-player .art-bottom{display:none!important}',
        '.art-video-player .art-mask{display:none!important}',
        '.art-video-player .art-loading{display:none!important}',
        '.art-video-player .art-notice{display:none!important}',
        '.art-video-player .art-info{display:none!important}',
        '.art-video-player .art-contextmenus{display:none!important}',
        '.art-video-player{background:#000!important}',
        '.art-video-player .art-video{object-fit:contain}',
      ].join(''),
      customType: {
        m3u8: function (video, src, artPlayer) {
          mode = attachHls(video, src, headers, artPlayer);
        },
      },
    });

    if (!isHlsUrl(url)) {
      mode = 'html';
    } else if (!art._kotvHls && art.video) {
      // customType 已处理；兜底
      mode = art._kotvHls ? 'hls' : mode;
    }

    container._kotvArt = art;
    container._kotvArtMode = mode;
    try {
      art.on('ready', function () {
        try {
          if (art.controls) art.controls.show = false;
        } catch (_) {}
      });
    } catch (_) {}
    return mode;
  }

  function player(container) {
    return container && container._kotvArt ? container._kotvArt : null;
  }

  function videoEl(container) {
    var art = player(container);
    return art && art.video ? art.video : null;
  }

  function play(container) {
    var art = player(container);
    if (!art) return;
    try {
      art.play();
    } catch (_) {}
  }

  function pause(container) {
    var art = player(container);
    if (!art) return;
    try {
      art.pause();
    } catch (_) {}
  }

  function seek(container, seconds) {
    var art = player(container);
    if (!art) return;
    try {
      art.currentTime = seconds;
    } catch (_) {}
  }

  function setVolume(container, v01) {
    var art = player(container);
    if (!art) return;
    try {
      art.volume = Math.max(0, Math.min(1, v01));
    } catch (_) {}
  }

  function setRate(container, rate) {
    var art = player(container);
    if (!art) return;
    try {
      art.playbackRate = rate;
    } catch (_) {}
  }

  function setLoop(container, on) {
    var v = videoEl(container);
    if (!v) return;
    try {
      v.loop = !!on;
    } catch (_) {}
  }

  function state(container) {
    var art = player(container);
    var v = videoEl(container);
    if (!art || !v) {
      return {
        opened: false,
        playing: false,
        ended: false,
        buffering: false,
        currentTime: 0,
        duration: 0,
        buffered: 0,
        volume: 1,
        rate: 1,
        width: 0,
        height: 0,
        mode: 'none',
      };
    }
    var buffered = 0;
    try {
      if (v.buffered && v.buffered.length > 0) {
        buffered = v.buffered.end(v.buffered.length - 1);
      }
    } catch (_) {}
    var dur = v.duration;
    if (typeof dur !== 'number' || isNaN(dur) || !isFinite(dur) || dur < 0) dur = 0;
    return {
      opened: true,
      playing: !v.paused && !v.ended,
      ended: !!v.ended,
      buffering: !!art.loading || v.readyState < 3,
      currentTime: v.currentTime || 0,
      duration: dur,
      buffered: buffered,
      volume: typeof art.volume === 'number' ? art.volume : v.volume,
      rate: v.playbackRate || 1,
      width: v.videoWidth || 0,
      height: v.videoHeight || 0,
      mode: container._kotvArtMode || 'html',
    };
  }

  function setObjectFit(container, fit) {
    var v = videoEl(container);
    if (!v || !v.style) return;
    try {
      v.style.objectFit = fit || 'contain';
    } catch (_) {}
  }

  global.kotvArt = {
    ready: !!global.Artplayer,
    create: create,
    destroy: destroy,
    play: play,
    pause: pause,
    seek: seek,
    setVolume: setVolume,
    setRate: setRate,
    setLoop: setLoop,
    state: state,
    setObjectFit: setObjectFit,
  };
})(typeof window !== 'undefined' ? window : globalThis);
