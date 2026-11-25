package az.smartbee.pixel

import android.content.Context

/** Testlər üçün adlı parametrlərlə seçim qurucusu (açıq API-də yalnız [SmartBeeOptions.Builder] var). */
internal fun opts(
    consent: SmartBeeConsent? = null,
    debug: Boolean = false,
    autoEvents: Boolean = true,
    endpoint: String? = null,
    wrapper: String? = null,
    wrapperVersion: String? = null,
    collectAdvertisingId: Boolean = true,
): SmartBeeOptions = SmartBeeOptions.Builder()
    .consent(consent)
    .debug(debug)
    .autoEvents(autoEvents)
    .endpoint(endpoint)
    .wrapper(wrapper, wrapperVersion)
    .collectAdvertisingId(collectAdvertisingId)
    .build()

// Test qarmaqları buraxılış AAR-ında başqa koddan əlçatan olmamalıdır, ona görə `SmartBee`-də `private`-dir və
// yalnız buradan, refleksiya ilə işlədilir.

private fun hookField(name: String) = SmartBee::class.java.getDeclaredField(name).apply { isAccessible = true }

private fun hookCall(name: String) {
    SmartBee::class.java.getDeclaredMethod(name).apply { isAccessible = true }.invoke(SmartBee)
}

/** Saxta nəqliyyat. */
internal var SmartBee.testTransport: (Boolean) -> Transport
    @Suppress("UNCHECKED_CAST")
    get() = hookField("transportFactory").get(null) as (Boolean) -> Transport
    set(value) = hookField("transportFactory").set(null, value)

/** Saxta reklam ID-si mənbəyi. */
internal var SmartBee.testAdIds: (Context) -> AdIdLookup?
    @Suppress("UNCHECKED_CAST")
    get() = hookField("adIdFactory").get(null) as (Context) -> AdIdLookup?
    set(value) = hookField("adIdFactory").set(null, value)

/** İşçi axındakı bütün gözləyən işlər bitənə qədər gözləyir. */
internal fun SmartBee.testAwaitIdle() = hookCall("awaitIdle")

/** SDK-nı başlamamış vəziyyətə qaytarır. */
internal fun SmartBee.testShutdown() = hookCall("shutdown")
