package io.github.junweiup.vibepier.remote.fixtures

import org.json.JSONObject

/** Production has no review payloads or sample projects. Review entry points fail closed. */
internal object ConversationReviewFixtures {
    fun conversation(kind: String): JSONObject = error("Review fixtures are not included in this build")
    fun reply(op: String, fields: JSONObject, kind: String): JSONObject = error("Review fixtures are not included in this build")
}
