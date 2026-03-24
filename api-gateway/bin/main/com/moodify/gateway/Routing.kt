package com.moodify.gateway

import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.engine.cio.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.request.*
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.server.application.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.sessions.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class MoodRequest(val mood: String, val limit: Int = 10)

@Serializable
data class LogicEngineRequest(
    val text: String, val limit: Int,
    val accessToken: String? = null, val userId: String? = null,
)

@Serializable
data class TrackOut(
    val id: String, val name: String, val artist: String,
    val preview_url: String?, val valence: Double,
    val energy: Double, val danceability: Double,
)

@Serializable
data class LogicEngineResponse(
    val interpretation: String,
    val query_used: String,
    val tracks: List<TrackOut>,
    val playlistId: String? = null,
    val playlistUrl: String? = null,
)

@Serializable
data class GatewayResponse(
    val interpretation: String,
    val query_used: String,
    val tracks: List<TrackOut>,
    val playlistId: String? = null,
    val playlistUrl: String? = null,
)

@Serializable
data class ErrorResponse(val error: String)

val httpClient = HttpClient(CIO) {
    install(ContentNegotiation) {
        json(Json { ignoreUnknownKeys = true })
    }
}

val logicEngineUrl = System.getenv("LOGIC_ENGINE_URL") ?: "http://localhost:8000"

fun Application.configureRouting() {
    routing {

        get("/health") {
            call.respond(mapOf("status" to "ok", "service" to "api-gateway"))
        }

        spotifyAuthRoutes(httpClient)

        post("/mood") {
            val engineResponse = runCatching {
    val response = httpClient.post("$logicEngineUrl/analyze") {
        contentType(ContentType.Application.Json)
        setBody(LogicEngineRequest(
            text = request.mood,
            limit = request.limit,
            accessToken = session?.accessToken,
            userId = session?.spotifyUserId,
        ))
    }
    if (!response.status.isSuccess()) {
        val errorBody = response.body<Map<String, String>>()
        val msg = errorBody["detail"] ?: errorBody["error"] ?: "Error desconocido"
        return@post call.respond(HttpStatusCode.BadGateway, ErrorResponse(msg))
    }
    response.body<LogicEngineResponse>()
}.getOrElse { e ->
    return@post call.respond(
        HttpStatusCode.BadGateway,
        ErrorResponse("Error al comunicarse con el Logic Engine: ${e.message}"),
    )
}
}
