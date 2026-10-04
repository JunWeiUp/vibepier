package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.sessions.ConversationViewState
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPickerTarget
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ConversationViewStateTest {
    private val saved = ConversationViewState("authorization-a", "claude", false, "thread", "Title", 120)
    @Test fun reauthorizationAndUnknownProvidersCannotRestoreAConversation() {
        assertEquals(saved, ConversationViewState.read(saved.json(), "authorization-a"))
        assertNull(ConversationViewState.read(saved.json(), "authorization-b"))
        assertNull(ConversationViewState.read(saved.json(), ""))
        assertNull(ConversationViewState.read(saved.json().put("provider", "unknown"), "authorization-a"))
        assertNull(ConversationViewState.read(saved.json().put("thread", ""), "authorization-a"))
    }
    @Test fun pickerTargetIncludesProviderAndAuthorizationNotOnlyThreadID() {
        assertTrue(saved.sameConversation(saved.copy(scrollY = 800)))
        assertFalse(saved.sameConversation(saved.copy(provider = "codex")))
        assertFalse(saved.sameConversation(saved.copy(source = "authorization-b")))
        assertFalse(saved.sameConversation(saved.copy(thread = "another")))
        assertFalse(saved.sameConversation(saved.copy(drawer = true)))
        assertFalse(saved.copy(drawer = true).sameConversation(saved.copy(drawer = true)))
    }
    @Test fun viewSnapshotDoesNotContainMessageOrDraftBodies() {
        assertEquals(setOf("source", "provider", "drawer", "thread", "title", "scrollY"), saved.json().keys().asSequence().toSet())
        assertEquals(0, ConversationViewState.read(saved.json().put("scrollY", -200), "authorization-a")!!.scrollY)
        assertNull(ConversationViewState.read(JSONObject(), "authorization-a"))
    }
    @Test fun creationPickerRequiresTheOriginalLiveDialogAndCannotFallBackToAnotherTarget() {
        val original = saved.copy(drawer = true).json().put("creationAttachment", true).put("creationPickerToken", "dialog-a")
        assertTrue(ConversationPickerTarget.matchesCreation(original, JSONObject(original.toString()), "authorization-a"))
        for (current in listOf(JSONObject(original.toString()).put("creationPickerToken", "dialog-b"),
            JSONObject(original.toString()).put("creationAttachment", false),
            JSONObject(original.toString()).put("source", "authorization-b"),
            JSONObject(original.toString()).put("provider", "codex"),
            JSONObject(original.toString()).put("thread", "another"),
            JSONObject(original.toString()).put("drawer", false))) {
            assertFalse(ConversationPickerTarget.matchesCreation(original, current, "authorization-a"))
        }
        assertFalse(ConversationPickerTarget.matchesCreation(original, original, "authorization-b"))
        assertFalse(ConversationPickerTarget.matchesCreation(original.put("creationPickerToken", ""), original, "authorization-a"))
    }
}
