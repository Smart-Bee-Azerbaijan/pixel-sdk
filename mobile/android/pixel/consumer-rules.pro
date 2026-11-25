# Reklam ID-si (GAID) Google kitabxanasından refleksiya ilə oxunur (asılılıq kimi əlavə olunmayıb).
# play-services-ads-identifier öz consumer qaydalarını gətirmir, ona görə kiçildilən (R8) tətbiqdə bu sinif və
# metodlar adları ilə qalmalıdır. Kitabxana tətbiqdə yoxdursa qaydalar heç nəyə təsir etmir.
-keep class com.google.android.gms.ads.identifier.AdvertisingIdClient {
    public static com.google.android.gms.ads.identifier.AdvertisingIdClient$Info getAdvertisingIdInfo(android.content.Context);
}
-keep class com.google.android.gms.ads.identifier.AdvertisingIdClient$Info {
    public java.lang.String getId();
    public boolean isLimitAdTrackingEnabled();
}
