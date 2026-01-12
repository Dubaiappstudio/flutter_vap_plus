#import "NativeVapView.h"
#import "UIView+VAP.h"
#import "QGVAPWrapView.h"
#import "FetchResourceModel.h"
#import <Flutter/Flutter.h>

@interface NativeVapView : NSObject <FlutterPlatformView, VAPWrapViewDelegate>

- (instancetype)initWithFrame:(CGRect)frame
               viewIdentifier:(int64_t)viewId
                    arguments:(id _Nullable)args
                    registrar:(NSObject<FlutterPluginRegistrar> *)registrar
              binaryMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;

@end

@implementation NativeVapViewFactory {
    NSObject<FlutterPluginRegistrar> *_registrar;
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];
    if (self) {
        _registrar = registrar;
    }
    return self;
}

- (NSObject<FlutterPlatformView> *)createWithFrame:(CGRect)frame
                                    viewIdentifier:(int64_t)viewId
                                         arguments:(id _Nullable)args {
    return [[NativeVapView alloc] initWithFrame:frame
                                 viewIdentifier:viewId
                                      arguments:args
                                      registrar:_registrar
                                binaryMessenger:_registrar.messenger];
}

@end

@implementation NativeVapView {
    UIView *_view;
    QGVAPWrapView *_wrapView;
    BOOL playStatus;
    FlutterMethodChannel *_methodChannel;
    NSArray<FetchResourceModel *> *_fetchResources;
    id _args;

    NSObject<FlutterPluginRegistrar> *_registrar; // ✅ keep registrar so we can resolve assets correctly on iOS
}

- (instancetype)initWithFrame:(CGRect)frame
               viewIdentifier:(int64_t)viewId
                    arguments:(id _Nullable)args
                    registrar:(NSObject<FlutterPluginRegistrar> *)registrar
              binaryMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
    self = [super init];
    if (self) {
        _args = args;
        _registrar = registrar;

        playStatus = NO;
        _view = [[UIView alloc] initWithFrame:frame];

        NSString *methodChannelName = [NSString stringWithFormat:@"flutter_vap_controller_%lld", viewId];
        _methodChannel = [FlutterMethodChannel methodChannelWithName:methodChannelName
                                                     binaryMessenger:messenger];

        __weak typeof(self) weakSelf = self;
        [_methodChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
            [weakSelf handleMethodCall:call result:result];
        }];
    }
    return self;
}

#pragma mark - FlutterPlatformView

- (UIView *)view {
    return _view;
}

#pragma mark - Method Call Handling

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([@"playPath" isEqualToString:call.method]) {
        NSString *path = call.arguments[@"path"];
        if (path) {
            [self playByPath:path withResult:result];
        } else {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"Path is null"
                                       details:nil]);
        }

    } else if ([@"playAsset" isEqualToString:call.method]) {
        NSString *asset = call.arguments[@"asset"];
        if (!asset || asset.length == 0) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"Asset is null"
                                       details:nil]);
            return;
        }

        // ✅ Correct iOS Flutter asset resolution:
        // Convert the Dart asset key into the real bundled key via registrar mapping.
        NSString *key = asset;
        if (_registrar) {
            key = [_registrar lookupKeyForAsset:asset];
        }

        // Try to locate it in main bundle
        NSString *assetPath = [[NSBundle mainBundle] pathForResource:key ofType:nil];

        // Fallback: in many Flutter iOS builds assets live in App.framework/flutter_assets
        if (!assetPath) {
            NSString *appFrameworkPath =
                [[[NSBundle mainBundle] privateFrameworksPath] stringByAppendingPathComponent:@"App.framework"];
            NSBundle *appFrameworkBundle = [NSBundle bundleWithPath:appFrameworkPath];
            assetPath = [appFrameworkBundle pathForResource:key ofType:nil];
        }

        // (Optional extra fallback) Some builds may use Frameworks instead of PrivateFrameworks
        if (!assetPath) {
            NSString *frameworksPath =
                [[[NSBundle mainBundle] builtInPlugInsPath] stringByDeletingLastPathComponent]; // .../Frameworks
            NSString *appFrameworkPath2 = [frameworksPath stringByAppendingPathComponent:@"App.framework"];
            NSBundle *appFrameworkBundle2 = [NSBundle bundleWithPath:appFrameworkPath2];
            assetPath = [appFrameworkBundle2 pathForResource:key ofType:nil];
        }

        NSLog(@"[VAP iOS] playAsset asset=%@ key=%@ path=%@", asset, key, assetPath);

        if (assetPath) {
            [self playByPath:assetPath withResult:result];
        } else {
            result([FlutterError errorWithCode:@"ASSET_NOT_FOUND"
                                       message:@"Asset not found"
                                       details:@{@"asset": asset ?: @"",
                                                 @"key": key ?: @""}]);
        }

    } else if ([@"stop" isEqualToString:call.method]) {
        [self stopPlayback];
        result(nil);

    } else if ([@"setFetchResource" isEqualToString:call.method]) {
        NSString *rawJson = (NSString *) call.arguments;
        _fetchResources = [FetchResourceModel fromRawJsonArray:rawJson];
        result(nil);

    } else {
        result(FlutterMethodNotImplemented);
    }
}

#pragma mark - Playback Control

- (void)playByPath:(NSString *)path withResult:(FlutterResult)result {
    if (playStatus) {
        result([FlutterError errorWithCode:@"ALREADY_PLAYING"
                                   message:@"A video is already playing"
                                   details:nil]);
        return;
    }

    playStatus = YES;

    _wrapView = [[QGVAPWrapView alloc] initWithFrame:_view.bounds];
    _wrapView.center = _view.center;
    _wrapView.contentMode = QGVAPWrapViewContentModeAspectFit;
    _wrapView.autoDestoryAfterFinish = YES;

    [_view addSubview:_wrapView];

    // This is your original call:
    [_wrapView vapWrapView_playHWDMP4:path repeatCount:0 delegate:self];

    result(nil);
    [_methodChannel invokeMethod:@"onStart" arguments:@{@"status" : @"start"}];
}

- (void)stopPlayback {
    if (_wrapView) {
        [_wrapView removeFromSuperview];
        _wrapView = nil;
    }
    playStatus = NO;
}

#pragma mark - VAPWrapViewDelegate

- (void)vapWrap_viewDidStartPlayMP4:(VAPView *)container {
    playStatus = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_methodChannel invokeMethod:@"onStart" arguments:@{@"status" : @"start"}];
    });
}

- (void)vapWrap_viewDidFailPlayMP4:(NSError *)error {
    playStatus = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_methodChannel invokeMethod:@"onFailed" arguments:@{
            @"status": @"failure",
            @"errorMsg": error.localizedDescription ?: @"Unknown error"
        }];
    });
}

- (void)vapWrap_viewDidStopPlayMP4:(NSInteger)lastFrameIndex view:(VAPView *)container {
    playStatus = NO;
}

- (void)vapWrap_viewDidFinishPlayMP4:(NSInteger)totalFrameCount view:(VAPView *)container {
    playStatus = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_methodChannel invokeMethod:@"onComplete" arguments:@{@"status" : @"complete"}];
    });
}

- (NSString *)vapWrapview_contentForVapTag:(NSString *)tag resource:(QGVAPSourceInfo *)info {
    for (FetchResourceModel *model in _fetchResources) {
        if ([model.tag isEqualToString:tag]) {
            NSLog(@"%@", [[@"vapWrapview_contentForVapTaging:" stringByAppendingString:tag] stringByAppendingString:model.resource]);
            return model.resource;
        }
    }
    return nil;
}

- (void)vapWrapView_loadVapImageWithURL:(NSString *)urlStr
                               context:(NSDictionary *)context
                            completion:(VAPImageCompletionBlock)completionBlock {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImage *image = [UIImage imageWithContentsOfFile:urlStr];
        completionBlock(image, nil, urlStr);
    });
}

@end
