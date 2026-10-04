package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.sessions.ConversationActions
import org.junit.Assert.*
import org.junit.Test

class ConversationActionsTest {
    private fun submit(active: Boolean, queue: Boolean, content: Boolean, unresolved: Boolean = false) =
        ConversationActions.submit(active, queue, true, true, false, false, unresolved, false, content)
    @Test fun runningTaskWithoutDraftNeverTurnsSubmissionIntoAStop() {
        assertFalse(submit(true, true, false).enabled)
        assertFalse(submit(true, false, false).enabled)
        assertTrue(submit(true, true, true).queued)
        assertTrue(submit(true, true, true).enabled)
        assertFalse(submit(false, true, true).queued)
        assertFalse(submit(true, false, true).queued)
    }
    @Test fun unconfirmedOperationKeepsDraftAndBlocksAnotherSubmission() {
        assertFalse(submit(true, true, true, unresolved = true).enabled)
        assertFalse(submit(false, false, true, unresolved = true).enabled)
    }
}
