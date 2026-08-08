#import "KotvVlcPlugin.h"
#import "KotvVlcEngine.h"
#import "vlc_shim.h"

@interface KotvVlcPlugin ()
@property(nonatomic, strong, nullable) KotvVlcEngine *engine;
@property(nonatomic, weak, nullable) NSObject<FlutterTextureRegistry> *textures;
@end

@implementation KotvVlcPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"kotv_vlc"
                                  binaryMessenger:registrar.messenger];
  KotvVlcPlugin *instance = [[KotvVlcPlugin alloc] init];
  instance.textures = registrar.textures;
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
  if ([call.method isEqualToString:@"create"]) {
    if (!self.textures) {
      result([FlutterError errorWithCode:@"no_tex" message:@"texture registry missing" details:nil]);
      return;
    }
    [self.engine dispose];
    self.engine = [[KotvVlcEngine alloc] initWithTextures:self.textures];
    result(@{@"mode" : @"texture", @"textureId" : @(self.engine.textureId)});
    return;
  }
  if ([call.method isEqualToString:@"load"]) {
    if (!self.engine) {
      result([FlutterError errorWithCode:@"no_engine" message:@"call create first" details:nil]);
      return;
    }
    NSError *err = nil;
    if ([self.engine loadLibDir:args[@"libDir"] ?: @"" pluginDir:args[@"pluginDir"] ?: @"" error:&err]) {
      result(nil);
    } else {
      result([FlutterError errorWithCode:@"load" message:err.localizedDescription details:nil]);
    }
    return;
  }
  if ([call.method isEqualToString:@"play"]) {
    if (!self.engine) {
      result([FlutterError errorWithCode:@"no_engine" message:@"call create first" details:nil]);
      return;
    }
    NSError *err = nil;
    NSString *headers = [args[@"headers"] isKindOfClass:[NSString class]] ? args[@"headers"] : nil;
    if ([self.engine playURL:args[@"url"] ?: @"" headers:headers error:&err]) {
      result(nil);
    } else {
      result([FlutterError errorWithCode:@"play" message:err.localizedDescription details:nil]);
    }
    return;
  }
  if ([call.method isEqualToString:@"stop"]) {
    [self.engine stop];
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"pause"]) {
    [self.engine setPaused:YES];
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"resume"]) {
    [self.engine setPaused:NO];
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"toggle"]) {
    BOOL playing = [self.engine isPlaying];
    [self.engine setPaused:playing];
    result(@{@"playing" : @(!playing)});
    return;
  }
  if ([call.method isEqualToString:@"seek"]) {
    [self.engine seekMs:[args[@"ms"] longLongValue]];
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"volume"]) {
    [self.engine setVolume:[args[@"value"] intValue]];
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"rate"]) {
    [self.engine setRate:[args[@"value"] floatValue]];
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"decode"]) {
    NSString *mode = args[@"mode"];
    if ([mode isKindOfClass:[NSString class]] && mode.length > 0) {
      [self.engine setDecodeMode:mode];
    } else {
      [self.engine setDecodeSoft:[args[@"soft"] boolValue]];
    }
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"repeat"]) {
    kotv_vlc_set_repeat([args[@"on"] boolValue] ? 1 : 0);
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"tracks"]) {
    int type = [args[@"type"] intValue];
    char buf[8192];
    int n = kotv_vlc_track_list(type, buf, (int)sizeof(buf));
    NSMutableArray *tracks = [NSMutableArray array];
    if (n > 0) {
      NSArray *lines = [[NSString stringWithUTF8String:buf] componentsSeparatedByString:@"\n"];
      for (NSString *line in lines) {
        if (line.length == 0) continue;
        NSRange tab = [line rangeOfString:@"\t"];
        if (tab.location == NSNotFound) {
          [tracks addObject:@{@"id" : line, @"name" : line}];
        } else {
          [tracks addObject:@{
            @"id" : [line substringToIndex:tab.location],
            @"name" : [line substringFromIndex:tab.location + 1],
          }];
        }
      }
    }
    result(@{
      @"tracks" : tracks,
      @"current" : @(kotv_vlc_get_track(type)),
      @"count" : @(n < 0 ? 0 : n),
    });
    return;
  }
  if ([call.method isEqualToString:@"setTrack"]) {
    int type = [args[@"type"] intValue];
    int tid = [args[@"id"] intValue];
    int rc = kotv_vlc_set_track(type, tid);
    if (rc < 0) {
      result([FlutterError errorWithCode:@"setTrack" message:@"set track failed" details:nil]);
      return;
    }
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"status"]) {
    if (!self.engine) {
      result(@{@"playing" : @NO, @"positionMs" : @0, @"durationMs" : @0, @"width" : @0, @"height" : @0});
      return;
    }
    int w = 0, h = 0;
    [self.engine videoSize:&w height:&h];
    result(@{
      @"playing" : @([self.engine isPlaying]),
      @"positionMs" : @([self.engine positionMs]),
      @"durationMs" : @([self.engine durationMs]),
      @"bufferedMs" : @(kotv_vlc_get_buffered()),
      @"buffering" : @(kotv_vlc_is_buffering() != 0),
      @"speedBps" : @(kotv_vlc_get_speed_bps()),
      @"width" : @(w),
      @"height" : @(h),
      @"rate" : @([self.engine rate]),
      @"textureId" : @(self.engine.textureId),
      @"frameSeq" : @(self.engine.frameSeq),
      @"mode" : @"texture",
    });
    return;
  }
  if ([call.method isEqualToString:@"dispose"]) {
    [self.engine dispose];
    self.engine = nil;
    result(nil);
    return;
  }
  result(FlutterMethodNotImplemented);
}

@end
