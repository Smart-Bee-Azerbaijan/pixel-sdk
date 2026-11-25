#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(SmartBeePixel, NSObject)

RCT_EXTERN_METHOD(start:(NSString *)key options:(NSDictionary *)options)
RCT_EXTERN_METHOD(track:(NSString *)name props:(NSDictionary *)props eventId:(NSString *)eventId)
RCT_EXTERN_METHOD(identify:(NSString *)userId traits:(NSDictionary *)traits)
RCT_EXTERN_METHOD(screen:(NSString *)name props:(NSDictionary *)props)
RCT_EXTERN_METHOD(setConsent:(BOOL)analytics ads:(BOOL)ads)
RCT_EXTERN_METHOD(reset)
RCT_EXTERN_METHOD(flush)
RCT_EXTERN_METHOD(handleDeepLink:(NSString *)url)
RCT_EXTERN_METHOD(getAnonymousId:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)

@end
