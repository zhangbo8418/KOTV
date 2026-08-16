/* KO影视 Web：西瓜播放器 xgplayer 胶水（v2 browser + HlsJsPlayer，关控件） */
(function (global) {
  'use strict';

  function isHlsUrl(url) {
    if (!url) return false;
    return String(url).split('?')[0].toLowerCase().indexOf('.m3u8') >= 0;
  }

  function destroy(container) {
    if (!container) return;
    try {
      if (container._kotvXg) {
        container._kotvXg.destroy(true);
        container._kotvXg = null;
      }
    } catch (_) {}
    try {
      container.innerHTML = '';
    } catch (_) {}
  }

  function create(container, url, headers) {
    destroy(container);
    if (!container || !url) return 'none';
    var Ctor = isHlsUrl(url) && global.HlsJsPlayer ? global.HlsJsPlayer : global.Player;
    if (!Ctor) {
      console.warn('kotvXg: Player missing');
      return 'none';
    }
    var mode = isHlsUrl(url) && global.HlsJsPlayer ? 'hls' : 'html';
    var player = new Ctor({
      el: container,
      url: url,
      fluid: false,
      width: '100%',
      height: '100%',
      autoplay: true,
      playsinline: true,
      closeVideoClick: true,
      closeVideoDblclick: true,
      closePlayerBlur: true,
      closeControlsBlur: true,
      // 尽量关掉内置控件，交给 Flutter
      ignores: [
        'fullscreen',
        'cssfullscreen',
        'playbackrate',
        'download',
        'pip',
        'definition',
        'danmu',
        'texttrack',
        'replay',
        'memoryPlay',
        'playNext',
      ],
      controlPlugins: [],
      customConfig: headers || {},
    });
    container._kotvXg = player;
    container._kotvXgMode = mode;
    try {
      var root = container.querySelector('.xgplayer') || container;
      var style = document.createElement('style');
      style.textContent = [
        '.xgplayer-controls,.xgplayer-progress,.xgplayer-start,.xgplayer-loading,',
        '.xgplayer-poster,.xgplayer-enter,.xgplayer-tips,.xgplayer-error{display:none!important}',
        '.xgplayer{background:#000!important;padding-top:0!important;width:100%!important;height:100%!important}',
        '.xgplayer video{object-fit:contain;width:100%;height:100%}',
      ].join('');
      root.appendChild(style);
    } catch (_) {}
    return mode;
  }

  function player(container) {
    return container && container._kotvXg ? container._kotvXg : null;
  }

  function videoEl(container) {
    var p = player(container);
    return p && p.video ? p.video : null;
  }

  function play(container) {
    var p = player(container);
    if (!p) return;
    try {
      p.play();
    } catch (_) {}
  }

  function pause(container) {
    var p = player(container);
    if (!p) return;
    try {
      p.pause();
    } catch (_) {}
  }

  function seek(container, seconds) {
    var p = player(container);
    if (!p) return;
    try {
      p.currentTime = seconds;
    } catch (_) {}
  }

  function setVolume(container, v01) {
    var p = player(container);
    if (!p) return;
    try {
      p.volume = Math.max(0, Math.min(1, v01));
    } catch (_) {}
  }

  function setRate(container, rate) {
    var p = player(container);
    var v = videoEl(container);
    try {
      if (p && typeof p.playbackRate !== 'undefined') p.playbackRate = rate;
      else if (v) v.playbackRate = rate;
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
    var p = player(container);
    var v = videoEl(container);
    if (!p || !v) {
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
      if (v.buffered && v.buffered.length > 0) buffered = v.buffered.end(v.buffered.length - 1);
    } catch (_) {}
    var dur = v.duration;
    if (typeof dur !== 'number' || isNaN(dur) || !isFinite(dur) || dur < 0) dur = 0;
    return {
      opened: true,
      playing: !v.paused && !v.ended,
      ended: !!v.ended,
      buffering: !!(p.paused === false && v.readyState < 3) || v.readyState < 3,
      currentTime: v.currentTime || 0,
      duration: dur,
      buffered: buffered,
      volume: typeof p.volume === 'number' ? p.volume : v.volume,
      rate: v.playbackRate || 1,
      width: v.videoWidth || 0,
      height: v.videoHeight || 0,
      mode: container._kotvXgMode || 'html',
    };
  }

  function setObjectFit(container, fit) {
    var v = videoEl(container);
    if (!v || !v.style) return;
    try {
      v.style.objectFit = fit || 'contain';
    } catch (_) {}
  }

  function video(container) {
    return videoEl(container);
  }

  global.kotvXg = {
    ready: !!global.Player,
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
    video: video,
  };
})(typeof window !== 'undefined' ? window : globalThis);
