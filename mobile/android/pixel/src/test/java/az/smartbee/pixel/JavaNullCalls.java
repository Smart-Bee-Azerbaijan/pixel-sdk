package az.smartbee.pixel;

import android.content.Context;

import java.util.HashMap;
import java.util.Map;

/** Açıq API-nin Java-dan null arqumentlərlə çağırılması: Kotlin-in parametr yoxlaması istisna atmamalıdır. */
final class JavaNullCalls {
    private JavaNullCalls() {
    }

    /** Hər açıq metodu null ilə çağırır; `context` verilibsə onunla birlikdə null açar və seçimlər də yoxlanır. */
    static void callEverything(Context context) {
        SmartBee.init(null, null);
        SmartBee.init(null, null, null);
        SmartBee.init(null, "demo0andr1");
        SmartBee.init(null, "demo0andr1", new SmartBeeOptions.Builder().build());
        SmartBee.init(context, null);
        SmartBee.init(context, null, null);
        SmartBee.init(context, null, new SmartBeeOptions.Builder().build());

        SmartBee.track(null);
        SmartBee.track(null, null);
        SmartBee.track(null, null, null);
        SmartBee.track("Lead", null);
        SmartBee.track("Lead", null, null);

        SmartBee.identify(null);
        SmartBee.identify(null, null);
        SmartBee.identify("user-1", null);

        SmartBee.screen(null);
        SmartBee.screen(null, null);
        SmartBee.screen("Home", null);

        SmartBee.handleDeepLink(null);

        Map<String, Object> values = new HashMap<>();
        values.put(null, "null key");
        values.put("nothing", null);
        SmartBee.track("Lead", values, null);
        SmartBee.identify("user-1", values);
        SmartBee.screen("Home", values);

        SmartBee.setConsent(true, true);
        SmartBee.setConsent(null);
        SmartBee.setConsent(new SmartBeeConsent(true, true));
        if (SmartBee.getSdkVersion().isEmpty()) throw new AssertionError("sdkVersion");
        SmartBee.reset();
        SmartBee.flush();
        SmartBee.getAnonymousId();
    }

    /** Null seçimlər və null sahəli seçimlərlə başlanğıc. */
    static void initWithNullOptions(Context context, String key) {
        // Seçimlər yalnız Builder ilə qurulur; null dəyərlər susmaya görə dəyəri saxlayır.
        SmartBeeOptions options = new SmartBeeOptions.Builder().consent(null).debug(false).autoEvents(true).endpoint(null).build();
        if (!"https://c.cdnsb.net".equals(options.getEndpoint())) throw new AssertionError(options.getEndpoint());
        if (options.getConsent() != null) throw new AssertionError("consent default");
        if (!"https://c.cdnsb.net".equals(new SmartBeeOptions.Builder().endpoint("").build().getEndpoint())) throw new AssertionError("empty endpoint");
        SmartBeeOptions withoutAdId = new SmartBeeOptions.Builder().consent(true, false).collectAdvertisingId(false).build();
        if (withoutAdId.getCollectAdvertisingId()) throw new AssertionError("collectAdvertisingId");
        if (!options.getCollectAdvertisingId()) throw new AssertionError("collectAdvertisingId default");
        SmartBeeConsent consent = withoutAdId.getConsent();
        if (consent == null || !consent.getAnalytics() || consent.getAds()) throw new AssertionError("consent");
        if (!consent.equals(new SmartBeeConsent(true, false))) throw new AssertionError("consent equality");
        SmartBee.init(context, key, null);
    }
}
