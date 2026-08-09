#import "KotvVlcEngine.h"
#import "vlc_shim.h"

#import <CoreVideo/CoreVideo.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

@interface KotvVlcEngine ()
@property(nonatomic, weak) NSObject<FlutterTextureRegistry> *textures;
@property(nonatomic, assign) int64_t textureId;
@property(nonatomic, assign) BOOL ready;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property(nonatomic, assign) int bufW;
@property(nonatomic, assign) int bufH;
@property(nonatomic, strong) NSMutableData *frameBytes;
@property(nonatomic, assign) int64_t lastSeq;
@property(nonatomic, assign) int64_t frameSeq;
@property(nonatomic, assign) int frameW;
@property(nonatomic, assign) int frameH;
@property(nonatomic, assign) int tickCount;
@end

@implementation KotvVlcEngine

- (instancetype)initWithTextures:(NSObject<FlutterTextureRegistry> *)textures {
  self = [super init];
  if (self) {
    _textures = textures;
    _textureId = [textures registerTexture:self];
    _frameBytes = [NSMutableData dataWithLength:0]; // 按实际分辨率动态扩容
    _lastSeq = -1;
  }
  return self;
}

- (void)dispose {
  [self.timer invalidate];
  self.timer = nil;
  kotv_vlc_set_hard_win(0);
  kotv_vlc_stop();
  kotv_vlc_unload();
  if (self.pixelBuffer) {
    CVPixelBufferRelease(self.pixelBuffer);
    self.pixelBuffer = nil;
  }
  if (self.textures && self.textureId >= 0) {
    [self.textures unregisterTexture:self.textureId];
  }
  self.ready = NO;
}

- (void)_prependDyld:(NSString *)libDir {
  if (libDir.length == 0) return;
  const char *cur = getenv("DYLD_LIBRARY_PATH");
  if (cur && strstr(cur, libDir.UTF8String)) return;
  if (cur && cur[0]) {
    setenv("DYLD_LIBRARY_PATH", [[NSString stringWithFormat:@"%@:%s", libDir, cur] UTF8String], 1);
  } else {
    setenv("DYLD_LIBRARY_PATH", libDir.UTF8String, 1);
  }
}

- (BOOL)loadLibDir:(NSString *)libDir pluginDir:(NSString *)pluginDir error:(NSError **)error {
  [self _prependDyld:libDir];
  // 确保走回调软渲，而不是 NSView/硬窗
  kotv_vlc_set_hard_win(0);
  int rc = kotv_vlc_load(libDir.UTF8String, pluginDir.UTF8String);
  if (rc != 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"kotv_vlc" code:rc userInfo:@{
        NSLocalizedDescriptionKey : [NSString stringWithFormat:@"libvlc load failed (%d)", rc]
      }];
    }
    return NO;
  }
  // load 可能早退（已加载）；强制重建为回调模式
  kotv_vlc_set_hard_win(0);
  self.ready = YES;
  return YES;
}

- (void)_ensureTimer {
  if (self.timer) return;
  __weak typeof(self) weakSelf = self;
  self.timer = [NSTimer timerWithTimeInterval:1.0 / 30.0
                                      repeats:YES
                                        block:^(__unused NSTimer *timer) {
                                          [weakSelf _tickFrame];
                                        }];
  [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)_ensurePixelBufferW:(int)w h:(int)h {
  if (self.pixelBuffer && self.bufW == w && self.bufH == h) return;
  if (self.pixelBuffer) {
    CVPixelBufferRelease(self.pixelBuffer);
    self.pixelBuffer = nil;
  }
  NSDictionary *attrs = @{
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVPixelBufferRef buf = NULL;
  CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                    (__bridge CFDictionaryRef)attrs, &buf);
  if (cr != kCVReturnSuccess || !buf) {
    NSLog(@"kotv_vlc: CVPixelBufferCreate failed %d", (int)cr);
    return;
  }
  self.pixelBuffer = buf;
  self.bufW = w;
  self.bufH = h;
}

- (BOOL)_ensureFrameCapacity:(size_t)bytes {
  if (bytes == 0) return NO;
  if (self.frameBytes.length >= bytes) return YES;
  @try {
    self.frameBytes.length = bytes;
    return self.frameBytes.length >= bytes;
  } @catch (__unused NSException *ex) {
    NSLog(@"kotv_vlc: frame buffer alloc failed (%zu bytes)", bytes);
    return NO;
  }
}

- (void)_tickFrame {
  if (!self.ready) return;
  self.tickCount++;
  int64_t seq = kotv_vlc_frame_seq();
  self.frameSeq = seq;

  // 通用：先 peek 尺寸 → 扩容 → take（支持 8K 等任意分辨率）
  int pw = 0, ph = 0;
  int64_t pseq = 0;
  if (kotv_vlc_peek_frame(&pw, &ph, &pseq) && pw > 1 && ph > 1) {
    size_t need = (size_t)pw * (size_t)ph * 4;
    if (![self _ensureFrameCapacity:need]) return;
  } else if (self.frameBytes.length == 0) {
    // 尚无帧信息时给一个起步容量，失败会再按回报扩
    [self _ensureFrameCapacity:1280ull * 720ull * 4];
  }

  int w = 0, h = 0;
  int ok = kotv_vlc_take_frame((uint8_t *)self.frameBytes.mutableBytes,
                               (int)self.frameBytes.length, &w, &h);
  if (!ok && w > 1 && h > 1) {
    size_t need = (size_t)w * (size_t)h * 4;
    if ([self _ensureFrameCapacity:need]) {
      ok = kotv_vlc_take_frame((uint8_t *)self.frameBytes.mutableBytes,
                               (int)self.frameBytes.length, &w, &h);
    }
  }

  if (self.tickCount % 30 == 1) {
    FILE *f = fopen("/tmp/kotv_vlc_frames.log", "a");
    if (f) {
      fprintf(f, "tick=%d ok=%d %dx%d seq=%lld play=%d state=%d t=%lld cap=%zu\n",
              self.tickCount, ok, w, h, (long long)seq, kotv_vlc_is_playing(),
              kotv_vlc_get_state(), (long long)kotv_vlc_get_time(),
              (size_t)self.frameBytes.length);
      fclose(f);
    }
  }

  if (!ok || w < 2 || h < 2) return;
  if (seq == self.lastSeq && self.pixelBuffer) return;

  [self _ensurePixelBufferW:w h:h];
  if (!self.pixelBuffer) return;

  CVPixelBufferLockBaseAddress(self.pixelBuffer, 0);
  uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(self.pixelBuffer);
  size_t stride = CVPixelBufferGetBytesPerRow(self.pixelBuffer);
  const uint8_t *src = (const uint8_t *)self.frameBytes.bytes;
  for (int y = 0; y < h; y++) {
    uint8_t *drow = dst + y * stride;
    const uint8_t *srow = src + (size_t)y * (size_t)w * 4;
    if (stride == (size_t)w * 4) {
      memcpy(drow, srow, (size_t)w * 4);
      for (int x = 0; x < w; x++) drow[x * 4 + 3] = 255;
    } else {
      for (int x = 0; x < w; x++) {
        drow[x * 4 + 0] = srow[x * 4 + 0];
        drow[x * 4 + 1] = srow[x * 4 + 1];
        drow[x * 4 + 2] = srow[x * 4 + 2];
        drow[x * 4 + 3] = 255;
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(self.pixelBuffer, 0);
  self.frameW = w;
  self.frameH = h;
  self.lastSeq = seq;
  [self.textures textureFrameAvailable:self.textureId];
}

- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  if (!self.pixelBuffer) return nil;
  CVPixelBufferRetain(self.pixelBuffer);
  return self.pixelBuffer;
}

- (BOOL)playURL:(NSString *)url
        headers:(NSDictionary<NSString *, NSString *> *)headers
          error:(NSError **)error {
  if (!self.ready) {
    if (error) {
      *error = [NSError errorWithDomain:@"kotv_vlc" code:-1
                             userInfo:@{NSLocalizedDescriptionKey : @"libvlc not loaded"}];
    }
    return NO;
  }
  kotv_vlc_set_hard_win(0); // 强制回调出画
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *val, BOOL *stop) {
    if (key.length == 0 || val.length == 0) return;
    [lines addObject:[NSString stringWithFormat:@"%@: %@", key, val]];
  }];
  const char **c_lines = NULL;
  int n = (int)lines.count;
  if (n > 0) {
    c_lines = (const char **)calloc((size_t)n, sizeof(char *));
    if (c_lines) {
      for (int i = 0; i < n; ++i) {
        c_lines[i] = lines[(NSUInteger)i].UTF8String;
      }
    } else {
      n = 0;
    }
  }
  int rc = kotv_vlc_play_with_headers(url.UTF8String, c_lines, n);
  free(c_lines);
  if (rc != 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"kotv_vlc" code:rc userInfo:@{
        NSLocalizedDescriptionKey : [NSString stringWithFormat:@"vlc play failed (%d)", rc]
      }];
    }
    return NO;
  }
  [self _ensureTimer];
  return YES;
}

- (void)stop { kotv_vlc_stop(); }
- (void)setPaused:(BOOL)paused { kotv_vlc_pause(paused ? 1 : 0); }
- (BOOL)isPlaying { return kotv_vlc_is_playing() != 0; }
- (void)seekMs:(int64_t)ms {
  // 勿堵 Flutter platform 线程：HLS 重建 seek 可能数秒。
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    kotv_vlc_set_time(ms);
  });
}
- (int64_t)positionMs { return kotv_vlc_get_time(); }
- (int64_t)durationMs { return kotv_vlc_get_length(); }
- (void)setVolume:(int)volume { kotv_vlc_set_volume(volume); }
- (BOOL)setRate:(float)rate { return kotv_vlc_set_rate(rate) == 0; }
- (float)rate { return kotv_vlc_get_rate(); }

- (void)videoSize:(int *)w height:(int *)h {
  if (self.frameW > 0 && self.frameH > 0) {
    if (w) *w = self.frameW;
    if (h) *h = self.frameH;
    return;
  }
  int vw = 0, vh = 0;
  if (kotv_vlc_video_size(&vw, &vh) == 0 && vw > 0 && vh > 0) {
    if (w) *w = vw;
    if (h) *h = vh;
    return;
  }
  if (w) *w = self.bufW;
  if (h) *h = self.bufH;
}

- (void)setDecodeSoft:(BOOL)soft { kotv_vlc_set_decode(soft ? 1 : 0); }
- (void)setDecodeMode:(NSString *)mode {
  if ([mode isEqualToString:@"soft"]) kotv_vlc_set_decode(1);
  else if ([mode isEqualToString:@"hard"]) kotv_vlc_set_decode(0);
  else kotv_vlc_set_decode(-1);
}

@end
