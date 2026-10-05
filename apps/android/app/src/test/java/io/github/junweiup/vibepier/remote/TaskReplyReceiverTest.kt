package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.TaskReplyReceiver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TaskReplyReceiverTest {
    @Test fun replyIsBoundToTheAuthorizationThatPostedTheNotification() {
        val fields = TaskReplyReceiver.request("codex", "thread", "phone-auth", "  continue  ", "phone-auth")!!
        assertEquals("codex", fields.getString("provider"))
        assertEquals("thread", fields.getString("threadId"))
        assertEquals("continue", fields.getString("text"))
        assertNull("A different Mac authorization must not send", TaskReplyReceiver.request("codex", "thread", "old-auth", "hi", "phone-auth"))
        assertNull(TaskReplyReceiver.request("codex", "thread", "", "hi", ""))
    }
    @Test fun emptyOversizedOrUnknownTargetsAreNeverSent() {
        assertNull(TaskReplyReceiver.request("codex", "thread", "auth", "   ", "auth"))
        assertNull(TaskReplyReceiver.request("codex", "thread", "auth", "x".repeat(32_001), "auth"))
        assertNull(TaskReplyReceiver.request("other", "thread", "auth", "hi", "auth"))
        assertNull(TaskReplyReceiver.request("codex", "", "auth", "hi", "auth"))
        assertNull(TaskReplyReceiver.request("codex", "t".repeat(513), "auth", "hi", "auth"))
    }
}
