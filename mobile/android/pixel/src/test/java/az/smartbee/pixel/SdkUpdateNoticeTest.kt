package az.smartbee.pixel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Konfiqin `sdk_latest` sahəsi: yeni SDK versiyası barədə sazlama rejimində bir dəfəlik xəbər. */
class SdkUpdateNoticeTest {
    private val parts = SDK_VERSION.split('.').map { it.toInt() }
    private val newerPatch = "${parts[0]}.${parts[1]}.${parts[2] + 3}"
    private val newerMinor = "${parts[0]}.${parts[1] + 10}.0"
    private val newerMajor = "${parts[0] + 1}.0.0"

    /** `latest` JSON dəyəri kimi verilir (dırnaqlarla birlikdə); null: sahə yoxdur. */
    private fun config(latest: String?): String =
        if (latest == null) """{"enabled":true}""" else """{"enabled":true,"sdk_latest":$latest}"""

    private fun notices(rig: Rig): List<String> = rig.env.logs.filter { it.contains("is available") }

    /** Verilmiş `sdk_latest` ilə konfiqi bir neçə dəfə yeniləyir və adi işin davam etdiyini yoxlayır. */
    private fun refreshed(latest: String?, options: SmartBeeOptions = opts(debug = true)): Rig {
        val rig = Rig(options)
        val core = rig.core()
        rig.transport.configBody = config(latest)
        repeat(3) {
            rig.transport.configEtag = "W/\"$it\""
            core.refreshConfig(force = true)
        }
        assertEquals(3, rig.transport.configCalls)
        core.onForeground()
        core.track("Lead", null, null)
        core.flush(force = true)
        assertTrue("davranış dəyişməməlidir: ${rig.transport.names}", rig.transport.names.contains("Lead"))
        return rig
    }

    @Test
    fun versionsAreComparedNumericallyPerComponent() {
        assertTrue(Util.newerVersion("1.10.0", "1.9.0"))
        assertFalse(Util.newerVersion("1.9.0", "1.10.0"))
        assertTrue(Util.newerVersion("2.0.0", "1.99.99"))
        assertTrue(Util.newerVersion("1.0.1", "1.0.0"))
        assertTrue(Util.newerVersion("1.0.10", "1.0.9"))
        assertFalse(Util.newerVersion("1.0.0", "1.0.0"))
        assertFalse(Util.newerVersion("1.0.0", "1.0.1"))
        assertFalse(Util.newerVersion("0.9.9", "1.0.0"))
        val malformed = listOf(
            null, "", " ", "1", "1.0", "1.0.0.0", "v1.0.3", "1.0.3-beta", "1.0.x", "a.b.c", "-1.0.0", " 9.9.9", "9.9.9 ",
            "9..9", "99999999999999999999.0.0", "9.9.9\n",
        )
        for (bad in malformed) assertFalse("$bad", Util.newerVersion(bad, "1.0.0"))
        // Öz versiyası oxunmursa da xəbər yoxdur.
        assertFalse(Util.newerVersion("9.9.9", "dev"))
    }

    @Test
    fun newerVersionIsLoggedOnceEvenAfterSeveralConfigRefreshes() {
        for (latest in listOf(newerPatch, newerMinor, newerMajor)) {
            val rig = refreshed("\"$latest\"")
            assertEquals(
                listOf("SmartBee Pixel $latest is available (this app uses $SDK_VERSION). Update the dependency to get fixes."),
                notices(rig),
            )
        }
    }

    @Test
    fun newerVersionFromCachedConfigIsLoggedOnceAtStart() {
        val rig = Rig()
        rig.store.map[Core.K_CONFIG] = config("\"$newerPatch\"")
        val core = rig.core()
        assertEquals(1, notices(rig).size)
        // Server sonra daha da yeni versiya bildirsə belə proses üçün bir sətir kifayətdir.
        rig.transport.configBody = config("\"$newerMajor\"")
        core.refreshConfig(force = true)
        core.refreshConfig(force = true)
        assertEquals(1, notices(rig).size)
    }

    @Test
    fun equalOlderMalformedOrMissingVersionIsNotLogged() {
        val values = listOf(
            null, "\"$SDK_VERSION\"", "\"0.0.0\"", "\"\"", "\"latest\"", "\"1.0\"", "\"v$newerMajor\"", "\"$newerMajor-beta\"",
            "\"$newerMajor.1\"", "\" $newerMajor\"", "\"99999999999999999999.0.0\"", "2", "9.5", "true", "null",
            "[\"$newerMajor\"]", "{\"v\":\"$newerMajor\"}",
        )
        for (latest in values) {
            val rig = refreshed(latest)
            assertTrue("$latest: ${rig.env.logs}", notices(rig).isEmpty())
            // Yararsız `sdk_latest` konfiqin qalanını pozmur.
            assertNotNull("$latest", RemoteConfig.parse(config(latest)))
        }
    }

    @Test
    fun nothingIsLoggedWhenDebugIsOff() {
        val rig = refreshed("\"$newerMajor\"", opts(debug = false))
        assertTrue("${rig.env.logs}", rig.env.logs.isEmpty())
    }

    @Test
    fun wrappersGetTheSameSingleMessage() {
        val rig = refreshed("\"$newerPatch\"", opts(debug = true, wrapper = "react-native", wrapperVersion = "1.0.0"))
        assertEquals(1, notices(rig).size)
        assertTrue(notices(rig)[0].startsWith("SmartBee Pixel $newerPatch is available"))
    }
}
