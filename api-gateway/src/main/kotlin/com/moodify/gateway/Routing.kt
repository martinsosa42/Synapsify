package com.synapsify.gateway

import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.engine.cio.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.server.application.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.sessions.*
import kotlinx.serialization.Serializable

// -- Schemas ------------------------------------------------------------------

@Serializable
data class MoodRequest(
    val mood: String,
    val limit: Int = 50,
)

@Serializable
data class LogicEngineRequest(
    val text: String,
    val limit: Int,
    val accessToken: String? = null,
    val userId: String? = null,
)

@Serializable
data class TrackOut(
    val id: String,
    val name: String,
    val artist: String,
    val preview_url: String?,
    val valence: Double,
    val energy: Double,
    val danceability: Double,
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
data class ErrorResponse(val error: String)

// [NEW] Schemas para /export
@Serializable
data class ExportRequest(
    val trackIds: List<String>,
    val mode: String,                    // "create" | "add"
    val playlistName: String? = null,
    val targetPlaylistId: String? = null,
    val moodText: String? = null,
    val accessToken: String? = null,     // [FIX] fallback cuando no hay cookie de sesion
)

@Serializable
data class LogicEngineExportRequest(
    val accessToken: String,
    val trackIds: List<String>,
    val mode: String,
    val playlistName: String? = null,
    val targetPlaylistId: String? = null,
    val moodText: String? = null,
)

@Serializable
data class ExportResponse(
    val playlistId: String,
    val playlistUrl: String,
    val tracksAdded: Int,
)

// [NEW] Schema para /playlists
@Serializable
data class PlaylistItem(
    val id: String,
    val name: String,
    val total: Int,
)

@Serializable
data class PlaylistsResponse(
    val playlists: List<PlaylistItem>,
)

// -- HTTP Client --------------------------------------------------------------

val httpClient = HttpClient(CIO) {
    install(ContentNegotiation) { json() }
}

val logicEngineUrl = System.getenv("LOGIC_ENGINE_URL") ?: "http://localhost:8000"

// -- Routing ------------------------------------------------------------------

fun Application.configureRouting() {
    routing {

        get("/health") {
            call.respond(mapOf("status" to "ok", "service" to "synapsify-api-gateway"))
        }

        // Rutas de autenticacion OAuth2
        spotifyAuthRoutes(httpClient)

        // POST /mood -- genera playlist (con o sin autenticacion)
        post("/mood") {
            val request = runCatching { call.receive<MoodRequest>() }.getOrNull()
                ?: return@post call.respond(
                    HttpStatusCode.BadRequest,
                    ErrorResponse("Cuerpo de peticion invalido"),
                )

            if (request.mood.isBlank()) {
                return@post call.respond(
                    HttpStatusCode.UnprocessableEntity,
                    ErrorResponse("El campo 'mood' no puede estar vacio"),
                )
            }

            val session = call.sessions.get<UserSession>()

            val engineResponse = runCatching {
                val response = httpClient.post("$logicEngineUrl/analyze") {
                    contentType(ContentType.Application.Json)
                    setBody(LogicEngineRequest(
                        text        = request.mood,
                        limit       = request.limit,
                        accessToken = session?.accessToken,
                        userId      = session?.spotifyUserId,
                    ))
                }
                if (!response.status.isSuccess()) {
                    val errorBody = response.bodyAsText()
                    throw Exception("Logic Engine respondio ${response.status.value}: $errorBody")
                }
                response.body<LogicEngineResponse>()
            }.getOrElse { e ->
                return@post call.respond(
                    HttpStatusCode.BadGateway,
                    ErrorResponse("Error al comunicarse con el Logic Engine: ${e.message}"),
                )
            }

            call.respond(HttpStatusCode.OK, engineResponse)
        }

        // [NEW] POST /export -- exporta tracks a una playlist de Spotify
        post("/export") {
            val session = call.sessions.get<UserSession>()

            val request = runCatching { call.receive<ExportRequest>() }.getOrNull()
                ?: return@post call.respond(
                    HttpStatusCode.BadRequest,
                    ErrorResponse("Cuerpo de peticion invalido"),
                )

            // [FIX] Token desde cookie de sesion o desde el body (Flutter no maneja cookies)
            val accessToken = session?.accessToken ?: request.accessToken
                ?: return@post call.respond(
                    HttpStatusCode.Unauthorized,
                    ErrorResponse("Debes iniciar sesion con Spotify para exportar."),
                )

            if (request.trackIds.isEmpty()) {
                return@post call.respond(
                    HttpStatusCode.UnprocessableEntity,
                    ErrorResponse("La lista de tracks no puede estar vacia"),
                )
            }

            if (request.mode !in listOf("create", "add")) {
                return@post call.respond(
                    HttpStatusCode.UnprocessableEntity,
                    ErrorResponse("mode debe ser 'create' o 'add'"),
                )
            }

            val exportResponse = runCatching {
                val response = httpClient.post("$logicEngineUrl/export") {
                    contentType(ContentType.Application.Json)
                    setBody(LogicEngineExportRequest(
                        accessToken      = accessToken,
                        trackIds         = request.trackIds,
                        mode             = request.mode,
                        playlistName     = request.playlistName,
                        targetPlaylistId = request.targetPlaylistId,
                        moodText         = request.moodText,
                    ))
                }
                if (!response.status.isSuccess()) {
                    val errorBody = response.bodyAsText()
                    throw Exception("Logic Engine respondio ${response.status.value}: $errorBody")
                }
                response.body<ExportResponse>()
            }.getOrElse { e ->
                return@post call.respond(
                    HttpStatusCode.BadGateway,
                    ErrorResponse("Error al exportar: ${e.message}"),
                )
            }

            call.respond(HttpStatusCode.OK, exportResponse)
        }

        // [NEW] GET /playlists -- lista las playlists del usuario autenticado
        get("/playlists") {
            val session = call.sessions.get<UserSession>()
            // [FIX] Flutter manda el token como query param; cookie como fallback
            val accessToken = session?.accessToken
                ?: call.request.queryParameters["access_token"]
                ?: return@get call.respond(
                    HttpStatusCode.Unauthorized,
                    ErrorResponse("Debes iniciar sesion con Spotify."),
                )

            val playlistsResponse = runCatching {
                val response = httpClient.get("$logicEngineUrl/playlists") {
                    parameter("access_token", accessToken)
                }
                if (!response.status.isSuccess()) {
                    val errorBody = response.bodyAsText()
                    throw Exception("Logic Engine respondio ${response.status.value}: $errorBody")
                }
                response.body<PlaylistsResponse>()
            }.getOrElse { e ->
                return@get call.respond(
                    HttpStatusCode.BadGateway,
                    ErrorResponse("Error al obtener playlists: ${e.message}"),
                )
            }

            call.respond(HttpStatusCode.OK, playlistsResponse)
        }
    }
}
