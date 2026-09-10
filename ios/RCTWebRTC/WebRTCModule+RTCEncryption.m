#import <objc/runtime.h>

#import <React/RCTLog.h>
#import <WebRTC/WebRTC.h>

#import "WebRTCModule+RTCPeerConnection.h"
#import "WebRTCModule.h"

/*
 * Bridge over the native `RTCEncryptionManager` (framed AES-GCM E2EE). Only control operations and
 * events cross the bridge, never media frames: the transforms run entirely inside libwebrtc.
 *
 * The attach path (`encrypt`/`decrypt`) and every key operation are blocking-synchronous. An async
 * attach would leave a window where a sender exists before its transform is installed, which is a
 * plaintext window. Only the observational calls use promises.
 */

static char kEncryptionManagerHandleKey;

@interface WebRTCModule (RTCEncryption)<RTC_OBJC_TYPE (RTCEncryptionManagerDelegate)>
@end

@implementation WebRTCModule (RTCEncryption)

#pragma mark - Helpers

/* Values omitted by JS arrive as nil or NSNull; both mean "let native decide". */
static id RTCEncryptionOptionalValue(NSDictionary *options, NSString *key, Class expectedClass) {
    id value = options[key];
    if (value == nil || value == (id)kCFNull || ![value isKindOfClass:expectedClass]) {
        return nil;
    }

    return value;
}

static NSDictionary *RTCEncryptionErrorResult(NSError *error, NSString *fallback) {
    NSString *message = error.localizedDescription.length > 0 ? error.localizedDescription : fallback;
    return @{@"error" : message};
}

- (nullable RTC_OBJC_TYPE(RTCEncryptionManager) *)encryptionManagerForOptions:(NSDictionary *)options {
    NSString *handle = RTCEncryptionOptionalValue(options, @"handle", [NSString class]);
    if (handle == nil) {
        return nil;
    }

    return self.encryptionManagers[handle];
}

/*
 * Absent means "read audio vs video from the sender/receiver"; screenshare must be explicit. A value
 * that is present but unusable is rejected rather than inferred: silently falling back would group a
 * screen-share-audio track with the microphone and share its replay window.
 */
static BOOL RTCEncryptionTrackTypeFromOptions(NSDictionary *options, NSNumber **trackType) {
    id value = options[@"trackType"];
    if (value == nil || value == (id)kCFNull) {
        *trackType = nil;
        return YES;
    }

    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }

    /* Validated before it is narrowed, like the key index: `integerValue` truncates, so a fractional
     * value would land on a valid enum entry instead of being rejected -- 1.5 would become video.
     * NaN fails the first comparison; the range check covers both infinities. */
    double type = [(NSNumber *)value doubleValue];
    if (type != trunc(type) || type < RTCEncryptionTrackTypeAudio || type > RTCEncryptionTrackTypeScreenshareAudio) {
        return NO;
    }

    *trackType = @((NSInteger)type);
    return YES;
}

/*
 * A key index is validated before it is narrowed: `intValue` truncates, so a fractional or non-finite
 * index would otherwise land silently on a valid slot instead of being rejected -- a `keyIndex` of
 * -0.5 would remove slot 0.
 */
static BOOL RTCEncryptionKeyIndexFromOptions(NSDictionary *options, int *keyIndex) {
    NSNumber *value = RTCEncryptionOptionalValue(options, @"keyIndex", [NSNumber class]);
    if (value == nil) {
        return NO;
    }

    /* NaN fails the first comparison; the range check covers both infinities. */
    double index = value.doubleValue;
    if (index != trunc(index) || index < 0 || index > 255) {
        return NO;
    }

    *keyIndex = (int)index;
    return YES;
}

- (nullable NSData *)encryptionKeyFromOptions:(NSDictionary *)options {
    NSString *key = RTCEncryptionOptionalValue(options, @"key", [NSString class]);
    if (key == nil) {
        return nil;
    }

    return [[NSData alloc] initWithBase64EncodedString:key options:0];
}

#pragma mark - Lifecycle

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(encryptionManagerIsSupported) {
    return @([RTC_OBJC_TYPE(RTCEncryptionManager) isSupported]);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(encryptionManagerCreate : (nonnull NSDictionary *)options) {
    __block NSDictionary *result = nil;

    dispatch_sync(self.workerQueue, ^{
        NSString *userId = RTCEncryptionOptionalValue(options, @"userId", [NSString class]);
        if (userId.length == 0) {
            result = @{@"error" : @"encryptionManagerCreate() requires a non-empty userId"};
            return;
        }

        NSNumber *algorithm = RTCEncryptionOptionalValue(options, @"algorithm", [NSNumber class]);
        if (algorithm != nil && algorithm.integerValue != RTCEncryptionAlgorithmAes128Gcm &&
            algorithm.integerValue != RTCEncryptionAlgorithmAes256Gcm) {
            result = @{@"error" : @"encryptionManagerCreate() got an unknown algorithm"};
            return;
        }

        NSError *error = nil;
        RTC_OBJC_TYPE(RTCEncryptionManager) * manager;
        if (algorithm != nil) {
            manager = [RTC_OBJC_TYPE(RTCEncryptionManager) createWithUserId:userId
                                                                  algorithm:algorithm.integerValue
                                                                      error:&error];
        } else {
            manager = [RTC_OBJC_TYPE(RTCEncryptionManager) createWithUserId:userId error:&error];
        }

        if (manager == nil) {
            result = RTCEncryptionErrorResult(error, @"Failed to create the encryption manager");
            return;
        }

        NSString *handle = [[NSUUID UUID] UUIDString];
        objc_setAssociatedObject(manager, &kEncryptionManagerHandleKey, handle, OBJC_ASSOCIATION_COPY);
        /* The delegate is wired before the handle is returned so no event can be missed. */
        manager.delegate = self;
        self.encryptionManagers[handle] = manager;

        result = @{@"handle" : handle};
    });

    return result;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(encryptionManagerDispose : (nonnull NSDictionary *)options) {
    __block NSDictionary *result = @{};

    dispatch_sync(self.workerQueue, ^{
        NSString *handle = RTCEncryptionOptionalValue(options, @"handle", [NSString class]);
        RTC_OBJC_TYPE(RTCEncryptionManager) *manager = handle != nil ? self.encryptionManagers[handle] : nil;
        if (manager == nil) {
            /* Disposing twice, or after a reload, is not an error. */
            return;
        }

        manager.delegate = nil;
        [manager dispose];
        objc_setAssociatedObject(manager, &kEncryptionManagerHandleKey, nil, OBJC_ASSOCIATION_COPY);
        [self.encryptionManagers removeObjectForKey:handle];
    });

    return result;
}

#pragma mark - Keys

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(encryptionManagerSetKey : (nonnull NSDictionary *)options) {
    __block NSDictionary *result = @{};

    dispatch_sync(self.workerQueue, ^{
        RTC_OBJC_TYPE(RTCEncryptionManager) *manager = [self encryptionManagerForOptions:options];
        if (manager == nil) {
            result = @{@"error" : @"encryptionManagerSetKey(): manager not found"};
            return;
        }

        NSString *userId = RTCEncryptionOptionalValue(options, @"userId", [NSString class]);
        int keyIndex = 0;
        BOOL hasKeyIndex = RTCEncryptionKeyIndexFromOptions(options, &keyIndex);
        NSData *key = [self encryptionKeyFromOptions:options];
        if (userId.length == 0 || !hasKeyIndex || key == nil) {
            result = @{@"error" : @"encryptionManagerSetKey() requires userId, a keyIndex in 0-255 and key"};
            return;
        }

        NSError *error = nil;
        if (![manager setKey:userId keyIndex:keyIndex rawKey:key error:&error]) {
            result = RTCEncryptionErrorResult(error, @"setKey failed");
        }
    });

    return result;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(encryptionManagerSetSharedKey : (nonnull NSDictionary *)options) {
    __block NSDictionary *result = @{};

    dispatch_sync(self.workerQueue, ^{
        RTC_OBJC_TYPE(RTCEncryptionManager) *manager = [self encryptionManagerForOptions:options];
        if (manager == nil) {
            result = @{@"error" : @"encryptionManagerSetSharedKey(): manager not found"};
            return;
        }

        int keyIndex = 0;
        BOOL hasKeyIndex = RTCEncryptionKeyIndexFromOptions(options, &keyIndex);
        NSData *key = [self encryptionKeyFromOptions:options];
        if (!hasKeyIndex || key == nil) {
            result = @{@"error" : @"encryptionManagerSetSharedKey() requires a keyIndex in 0-255 and key"};
            return;
        }

        NSError *error = nil;
        if (![manager setSharedKey:keyIndex rawKey:key error:&error]) {
            result = RTCEncryptionErrorResult(error, @"setSharedKey failed");
        }
    });

    return result;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(encryptionManagerRemoveKey : (nonnull NSDictionary *)options) {
    __block NSDictionary *result = @{};

    dispatch_sync(self.workerQueue, ^{
        RTC_OBJC_TYPE(RTCEncryptionManager) *manager = [self encryptionManagerForOptions:options];
        if (manager == nil) {
            result = @{@"error" : @"encryptionManagerRemoveKey(): manager not found"};
            return;
        }

        NSString *userId = RTCEncryptionOptionalValue(options, @"userId", [NSString class]);
        int keyIndex = 0;
        BOOL hasKeyIndex = RTCEncryptionKeyIndexFromOptions(options, &keyIndex);
        if (userId.length == 0 || !hasKeyIndex) {
            result = @{@"error" : @"encryptionManagerRemoveKey() requires userId and a keyIndex in 0-255"};
            return;
        }

        NSError *error = nil;
        if (![manager removeKey:userId keyIndex:keyIndex error:&error]) {
            result = RTCEncryptionErrorResult(error, @"removeKey failed");
        }
    });

    return result;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(encryptionManagerRemoveAllKeys : (nonnull NSDictionary *)options) {
    __block NSDictionary *result = @{};

    dispatch_sync(self.workerQueue, ^{
        RTC_OBJC_TYPE(RTCEncryptionManager) *manager = [self encryptionManagerForOptions:options];
        if (manager == nil) {
            result = @{@"error" : @"encryptionManagerRemoveAllKeys(): manager not found"};
            return;
        }

        NSString *userId = RTCEncryptionOptionalValue(options, @"userId", [NSString class]);
        if (userId.length == 0) {
            result = @{@"error" : @"encryptionManagerRemoveAllKeys() requires userId"};
            return;
        }

        NSError *error = nil;
        if (![manager removeAllKeys:userId error:&error]) {
            result = RTCEncryptionErrorResult(error, @"removeAllKeys failed");
        }
    });

    return result;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(encryptionManagerRemoveSharedKey : (nonnull NSDictionary *)options) {
    __block NSDictionary *result = @{};

    dispatch_sync(self.workerQueue, ^{
        RTC_OBJC_TYPE(RTCEncryptionManager) *manager = [self encryptionManagerForOptions:options];
        if (manager == nil) {
            result = @{@"error" : @"encryptionManagerRemoveSharedKey(): manager not found"};
            return;
        }

        int keyIndex = 0;
        BOOL hasKeyIndex = RTCEncryptionKeyIndexFromOptions(options, &keyIndex);
        if (!hasKeyIndex) {
            result = @{@"error" : @"encryptionManagerRemoveSharedKey() requires a keyIndex in 0-255"};
            return;
        }

        NSError *error = nil;
        if (![manager removeSharedKey:keyIndex error:&error]) {
            result = RTCEncryptionErrorResult(error, @"removeSharedKey failed");
        }
    });

    return result;
}

#pragma mark - Attach

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(encryptionManagerEncrypt : (nonnull NSDictionary *)options) {
    __block NSDictionary *result = @{};

    dispatch_sync(self.workerQueue, ^{
        RTC_OBJC_TYPE(RTCEncryptionManager) *manager = [self encryptionManagerForOptions:options];
        if (manager == nil) {
            result = @{@"error" : @"encryptionManagerEncrypt(): manager not found"};
            return;
        }

        NSNumber *peerConnectionId = RTCEncryptionOptionalValue(options, @"peerConnectionId", [NSNumber class]);
        NSString *senderId = RTCEncryptionOptionalValue(options, @"senderId", [NSString class]);
        if (peerConnectionId == nil || senderId == nil) {
            result = @{@"error" : @"encryptionManagerEncrypt() requires peerConnectionId and senderId"};
            return;
        }

        RTCRtpSender *sender = [self getSenderByPeerConnectionId:peerConnectionId senderId:senderId];
        if (sender == nil) {
            result =
                @{@"error" : [NSString stringWithFormat:@"encryptionManagerEncrypt(): sender %@ not found", senderId]};
            return;
        }

        NSNumber *trackType = nil;
        if (!RTCEncryptionTrackTypeFromOptions(options, &trackType)) {
            result = @{@"error" : @"encryptionManagerEncrypt() got an unusable trackType"};
            return;
        }

        NSError *error = nil;
        NSString *codec = RTCEncryptionOptionalValue(options, @"codec", [NSString class]);
        if (![manager encrypt:sender codec:codec trackType:trackType error:&error]) {
            result = RTCEncryptionErrorResult(error, @"Failed to attach the encrypt transform");
        }
    });

    return result;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(encryptionManagerDecrypt : (nonnull NSDictionary *)options) {
    __block NSDictionary *result = @{};

    dispatch_sync(self.workerQueue, ^{
        RTC_OBJC_TYPE(RTCEncryptionManager) *manager = [self encryptionManagerForOptions:options];
        if (manager == nil) {
            result = @{@"error" : @"encryptionManagerDecrypt(): manager not found"};
            return;
        }

        NSNumber *peerConnectionId = RTCEncryptionOptionalValue(options, @"peerConnectionId", [NSNumber class]);
        NSString *receiverId = RTCEncryptionOptionalValue(options, @"receiverId", [NSString class]);
        NSString *userId = RTCEncryptionOptionalValue(options, @"userId", [NSString class]);
        if (peerConnectionId == nil || receiverId == nil || userId.length == 0) {
            result = @{@"error" : @"encryptionManagerDecrypt() requires peerConnectionId, receiverId and userId"};
            return;
        }

        RTCRtpReceiver *receiver = [self getReceiverByPeerConnectionId:peerConnectionId receiverId:receiverId];
        if (receiver == nil) {
            result = @{
                @"error" : [NSString stringWithFormat:@"encryptionManagerDecrypt(): receiver %@ not found", receiverId]
            };
            return;
        }

        NSNumber *trackType = nil;
        if (!RTCEncryptionTrackTypeFromOptions(options, &trackType)) {
            result = @{@"error" : @"encryptionManagerDecrypt() got an unusable trackType"};
            return;
        }

        NSError *error = nil;
        if (![manager decrypt:receiver userId:userId trackType:trackType error:&error]) {
            result = RTCEncryptionErrorResult(error, @"Failed to attach the decrypt transform");
        }
    });

    return result;
}

#pragma mark - Diagnostics

RCT_EXPORT_METHOD(encryptionManagerEnablePerformanceReporting : (nonnull NSString *)handle enabled : (BOOL)
                      enabled resolve : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
    RTC_OBJC_TYPE(RTCEncryptionManager) *manager = self.encryptionManagers[handle];
    if (manager == nil) {
        reject(@"encryptionManagerEnablePerformanceReportingFailed", @"manager not found", nil);
        return;
    }

    NSError *error = nil;
    if (![manager enablePerformanceReporting:enabled error:&error]) {
        reject(@"encryptionManagerEnablePerformanceReportingFailed", @"enablePerformanceReporting failed", error);
        return;
    }

    resolve(nil);
}

RCT_EXPORT_METHOD(encryptionManagerRequestKeyState : (nonnull NSString *)handle resolve : (RCTPromiseResolveBlock)
                      resolve reject : (RCTPromiseRejectBlock)reject) {
    RTC_OBJC_TYPE(RTCEncryptionManager) *manager = self.encryptionManagers[handle];
    if (manager == nil) {
        reject(@"encryptionManagerRequestKeyStateFailed", @"manager not found", nil);
        return;
    }

    NSError *error = nil;
    if (![manager requestKeyState:&error]) {
        reject(@"encryptionManagerRequestKeyStateFailed", @"requestKeyState failed", error);
        return;
    }

    resolve(nil);
}

#pragma mark - RTCEncryptionManagerDelegate

/* Key fingerprints only; raw key material never crosses the bridge. */
- (NSArray<NSDictionary *> *)keyStatePerUserKeysToJSON:(RTC_OBJC_TYPE(RTCEncryptionKeyState) *)keyState {
    NSMutableArray *keys = [NSMutableArray arrayWithCapacity:keyState.perUserKeys.count];
    for (RTC_OBJC_TYPE(RTCEncryptionUserKey) * key in keyState.perUserKeys) {
        [keys addObject:@{@"userId" : key.userId, @"keyIndex" : @(key.keyIndex), @"fingerprint" : key.fingerprint}];
    }

    return keys;
}

- (NSArray<NSDictionary *> *)keyStateSharedKeysToJSON:(RTC_OBJC_TYPE(RTCEncryptionKeyState) *)keyState {
    NSMutableArray *keys = [NSMutableArray arrayWithCapacity:keyState.sharedKeys.count];
    for (RTC_OBJC_TYPE(RTCEncryptionSharedKey) * key in keyState.sharedKeys) {
        [keys addObject:@{
            @"keyIndex" : @(key.keyIndex),
            @"fingerprint" : key.fingerprint,
            @"isActive" : @(key.isActive)
        }];
    }

    return keys;
}

- (NSArray<NSDictionary *> *)trackPerfToJSON:(NSArray<RTC_OBJC_TYPE(RTCEncryptionTrackPerf) *> *)samples {
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:samples.count];
    for (RTC_OBJC_TYPE(RTCEncryptionTrackPerf) * sample in samples) {
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:@{
            @"userId" : sample.userId,
            @"trackType" : @(sample.trackType),
            @"fps" : @(sample.fps),
            @"maxCryptoMs" : @(sample.maxCryptoMs)
        }];
        if (sample.codec != nil) {
            row[@"codec"] = sample.codec;
        }

        [rows addObject:row];
    }

    return rows;
}

- (void)encryptionManager:(RTC_OBJC_TYPE(RTCEncryptionManager) *)manager
          didReceiveEvent:(RTC_OBJC_TYPE(RTCE2eeEvent) *)event {
    id handle = objc_getAssociatedObject(manager, &kEncryptionManagerHandleKey);
    if (![handle isKindOfClass:[NSString class]]) {
        RCTLogWarn(@"E2EE event for a manager without a handle");
        return;
    }

    NSMutableDictionary *body = [NSMutableDictionary
        dictionaryWithDictionary:@{@"managerId" : (NSString *)handle, @"type" : event.name, @"userId" : event.userId}];

    if (event.trackType != nil) {
        body[@"trackType"] = event.trackType;
    }
    if (event.keyIndex != nil) {
        body[@"keyIndex"] = event.keyIndex;
    }
    if (event.version != nil) {
        body[@"version"] = event.version;
    }
    if (event.reason != nil) {
        body[@"reason"] = event.reason;
    }
    if (event.keyState != nil) {
        body[@"keyState"] = @{
            @"perUserKeys" : [self keyStatePerUserKeysToJSON:event.keyState],
            @"sharedKeys" : [self keyStateSharedKeysToJSON:event.keyState]
        };
    }
    if (event.encode != nil) {
        body[@"encode"] = [self trackPerfToJSON:event.encode];
    }
    if (event.decode != nil) {
        body[@"decode"] = [self trackPerfToJSON:event.decode];
    }

    [self sendEventWithName:kEventEncryptionManagerEvent body:body];
}

@end
