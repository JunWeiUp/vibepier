package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.updates.AvailableAppVersion
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AppVersionUpdatesTest {
    private fun release(code: Any, name: String = "0.1.0-beta.1") = JSONObject().put("versionCode", code).put("versionName", name)
    @Test fun comparesBuildCodeAndClearsAfterInstall() {
        assertEquals(6L, AvailableAppVersion.newer(release(6), 5)?.code)
        assertNull(AvailableAppVersion.newer(release(6), 6))
        assertNull(AvailableAppVersion.newer(release(4, "99.0"), 5))
        assertNull(AvailableAppVersion.newer(null, 5))
    }
    @Test fun rejectsMalformedMetadata() {
        for (code in listOf(true, "6", 6.5, -1, 2_100_000_001L)) assertNull(AvailableAppVersion.newer(release(code), 5))
        assertNull(AvailableAppVersion.newer(release(6, "bad\nversion"), 5))
        assertNull(AvailableAppVersion.newer(release(6, ""), 5))
    }
}
