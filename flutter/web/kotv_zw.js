/* KO影视 Web：ZWPlayer（全能播放器）胶水，关自带控件 */
(function (global) {
  'use strict';

  function destroy(container) {
    if (!container) return;
    try {
      if (container._kotvZw) {
        if (typeof container._kotvZw.destroy === 'function') {
          container._kotvZw.destroy();
        }
        container._kotvZw = null;
      }
    } catch (_) {}
    try {
      container.innerHTML = '';
    } catch (_) {}
  }

  function create(container, url, headers) {
    destroy(container);
    if (!container || !url) return 'none';
    var ZW = global.ZWPlayer;
    if (!ZW) {
      console.warn('kotvZw: ZWPlayer missing');
      return 'none';
    }
    if (!container.id) {
      container.id = 'kotv-zw-' + Date.now() + '-' + Math.floor(Math.random() * 1e6);
    }
    container.style.width = '100%';
    container.style.height = '100%';
    container.style.background = '#000';

    var opts = {
      playerElm: container.id,
      url: url,
      autoplay: true,
      controls: false,
      nativecontrols: false,
      alwaysShowControls: false,
    };
    // 部分版本支持 headers / xhr
    if (headers) {
      opts.headers = headers;
      opts.xhrSetup = function (xhr) {
        try {
          Object.keys(headers).forEach(function (k) {
            try {
              xhr.setRequestHeader(k, headers[k]);
            } catch (_) {}
          });
        } catch (_) {}
      };
    }
    var player = new ZW(opts);
    container._kotvZw = player;
    container._kotvZwMode = String(url).toLowerCase().indexOf('.m3u8') >= 0 ? 'hls' : 'html';
    try {
      var style = document.createElement('style');
      style.textContent = [
        '#' + container.id + ' .zwp-controls,',
        '#' + container.id + ' .zwp-controlbar,',
        '#' + container.id + ' .zwp-big-play,',
        '#' + container.id + ' .zwp-loading{display:none!important}',
        '#' + container.id + '{background:#000!important}',
        '#' + container.id + ' video{object-fit:contain;width:100%;height:100%}',
      ].join('');
      container.appendChild(style);
    } catch (_) {}
    return container._kotvZwMode;
  }

  function player(container) {
    return container && container._kotvZw ? container._kotvZw : null;
  }

  function videoEl(container) {
    var p = player(container);
    if (!p) return null;
    if (p.video) return p.video;
    if (p.videoEl) return p.videoEl;
    try {
      return container.querySelector('video');
    } catch (_) {
      return null;
    }
  }

  function play(container) {
    var p = player(container);
    if (!p) return;
    try {
      if (typeof p.play === 'function') p.play();
      else if (videoEl(container)) videoEl(container).play();
    } catch (_) {}
  }

  function pause(container) {
    var p = player(container);
    if (!p) return;
    try {
      if (typeof p.pause === 'function') p.pause();
      else if (videoEl(container)) videoEl(container).pause();
    } catch (_) {}
  }

  function seek(container, seconds) {
    var p = player(container);
    var v = videoEl(container);
    try {
      if (p && typeof p.currentTime === 'number') p.currentTime = seconds;
      else if (p && typeof p.seek === 'function') p.seek(seconds);
      else if (v) v.currentTime = seconds;
    } catch (_) {}
  }

  function setVolume(container, v01) {
    var p = player(container);
    var v = videoEl(container);
    try {
      if (p && typeof p.volume === 'number') p.volume = Math.max(0, Math.min(1, v01));
      else if (v) v.volume = Math.max(0, Math.min(1, v01));
    } catch (_) {}
  }

  function setRate(container, rate) {
    var p = player(container);
    var v = videoEl(container);
    try {
      if (p && typeof p.playbackRate === 'number') p.playbackRate = rate;
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
      buffering: v.readyState < 3,
      currentTime: v.currentTime || 0,
      duration: dur,
      buffered: buffered,
      volume: typeof v.volume === 'number' ? v.volume : 1,
      rate: v.playbackRate || 1,
      width: v.videoWidth || 0,
      height: v.videoHeight || 0,
      mode: container._kotvZwMode || 'html',
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

  global.kotvZw = {
    ready: !!global.ZWPlayer,
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
