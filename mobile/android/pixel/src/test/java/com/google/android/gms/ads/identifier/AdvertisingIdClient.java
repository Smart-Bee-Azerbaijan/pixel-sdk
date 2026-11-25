package com.google.android.gms.ads.identifier;

import android.content.Context;

import java.io.IOException;

/**
 * Yalnız testlər üçün: `play-services-ads-identifier` kitabxanasındakı sinfin eyni adlı və eyni imzalı əvəzi.
 * SDK onu refleksiya ilə çağırır; real kitabxana asılılıq kimi əlavə olunmayıb. Susmaya görə Play xidmətləri
 * əlçatmaz kimi davranır (istisna atır).
 */
public class AdvertisingIdClient {
    /** Növbəti çağırışın nəticəsi; null olarsa `IOException` atılır. */
    public static volatile Info next;

    /** Çağırışın getdiyi axın yoxlanılsın deyə. */
    public static volatile Thread lastThread;

    public static Info getAdvertisingIdInfo(Context context) throws IOException {
        lastThread = Thread.currentThread();
        Info info = next;
        if (info == null) throw new IOException("Google Play services is not available");
        return info;
    }

    public static final class Info {
        private final String id;
        private final boolean limited;

        public Info(String id, boolean limited) {
            this.id = id;
            this.limited = limited;
        }

        public String getId() {
            return id;
        }

        public boolean isLimitAdTrackingEnabled() {
            return limited;
        }
    }
}
