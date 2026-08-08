#import <Foundation/Foundation.h>
#import <FlutterMacOS/FlutterMacOS.h>

NS_ASSUME_NONNULL_BEGIN

@interface KotvVlcEngine : NSObject <FlutterTexture>

@property(nonatomic, assign, readonly) int64_t textureId;
@property(nonatomic, assign, readonly) BOOL ready;
@property(nonatomic, assign, readonly) int64_t frameSeq;
@property(nonatomic, assign, readonly) int frameW;
@property(nonatomic, assign, readonly) int frameH;

- (instancetype)initWithTextures:(NSObject<FlutterTextureRegistry> *)textures;
- (BOOL)loadLibDir:(NSString *)libDir pluginDir:(NSString *)pluginDir error:(NSError **)error;
- (BOOL)playURL:(NSString *)url error:(NSError **)error;
- (BOOL)playURL:(NSString *)url headers:(nullable NSString *)headers error:(NSError **)error;
- (void)stop;
- (void)setPaused:(BOOL)paused;
- (BOOL)isPlaying;
- (void)seekMs:(int64_t)ms;
- (int64_t)positionMs;
- (int64_t)durationMs;
- (void)setVolume:(int)volume;
- (BOOL)setRate:(float)rate;
- (float)rate;
- (void)videoSize:(int *)w height:(int *)h;
- (void)setDecodeSoft:(BOOL)soft;
- (void)setDecodeMode:(NSString *)mode;
- (void)dispose;

@end

NS_ASSUME_NONNULL_END
