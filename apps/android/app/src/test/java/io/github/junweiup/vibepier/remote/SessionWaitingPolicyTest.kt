package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.core.session.SessionWaitingPolicy
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionWaitingPolicyTest {
    private val send = JSONObject().put("op", "send").put("text", "hello").put("attachments", JSONArray().put("file-1"))
    @Test fun stoppedWaitStillPreventsRepeatingTextOrAttachments() {
        assertTrue(SessionWaitingPolicy.duplicateSend(listOf(send), " hello ", JSONArray()))
        assertTrue(SessionWaitingPolicy.duplicateSend(listOf(send), "different", JSONArray().put("file-1")))
        assertFalse(SessionWaitingPolicy.duplicateSend(listOf(send), "different", JSONArray().put("file-2")))
        assertFalse(SessionWaitingPolicy.duplicateSend(emptyList(), "hello", JSONArray().put("file-1")))
    }
    @Test fun unrelatedOperationsAndEmptyDraftsDoNotBlockANewMessage() {
        assertFalse(SessionWaitingPolicy.duplicateSend(listOf(JSONObject().put("op", "settings").put("text", "hello")), "hello", JSONArray()))
        assertFalse(SessionWaitingPolicy.duplicateSend(listOf(send), "", JSONArray()))
    }
}
