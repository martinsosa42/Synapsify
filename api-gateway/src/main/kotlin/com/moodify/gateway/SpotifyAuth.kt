package com.synapsify.gateway

import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.engine.cio.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.request.*
import io.ktor.client.request.forms.*
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.server.application.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.sessions.*
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.Base64

val SPOTIFY_CLIENT_ID     = System.getenv("SPOTIFY_CLIENT_ID")     ?: ""
val SPOTIFY_CLIENT_SECRET = System.getenv("SPOTIFY_CLIENT_SECRET") ?: ""
val SPOTIFY_REDIRECT_URI  = System.getenv("SPOTIFY_REDIRECT_URI")
    ?: "http://127.0.0.1:8080/auth/callback"

val SPOTIFY_SCOPES = listOf(
    "playlist-modify-public",
    "playlist-modify-private",
    "playlist-read-private",
    "user-read-private",
    "user-read-email",
).joinToString(" ")

// Cliente HTTP propio con ignoreUnknownKeys
val spotifyClient = HttpClient(CIO) {
    install(ContentNegotiation) {
        json(Json { ignoreUnknownKeys = true })
    }
}

@Serializable
data class SpotifyTokenResponse(
    @SerialName("access_token")  val accessToken: String,
    @SerialName("token_type")    val tokenType: String,
    @SerialName("expires_in")    val expiresIn: Int,
    @SerialName("refresh_token") val refreshToken: String? = null,
    @SerialName("scope")         val scope: String? = null,
)

@Serializable
data class UserSession(
    val accessToken: String,
    val refreshToken: String?,
    val spotifyUserId: String,
)

@Serializable
data class SpotifyUserProfile(
    val id: String,
    @SerialName("display_name") val displayName: String? = null,
    val email: String? = null,
)

@Serializable
data class AuthResponse(val loginUrl: String)

// [NEW] Respuesta del endpoint /auth/refresh
@Serializable
data class RefreshResponse(
    val accessToken: String,
    val expiresIn: Int,
)

fun Route.spotifyAuthRoutes(client: HttpClient) {

    get("/auth/login") {
        val loginUrl = URLBuilder("https://accounts.spotify.com/authorize").apply {
            parameters.append("client_id",     SPOTIFY_CLIENT_ID)
            parameters.append("response_type", "code")
            parameters.append("redirect_uri",  SPOTIFY_REDIRECT_URI)
            parameters.append("scope",         SPOTIFY_SCOPES)
            parameters.append("show_dialog",   "true")
        }.buildString()
        call.respond(AuthResponse(loginUrl = loginUrl))
    }

    get("/auth/callback") {
        val code = call.request.queryParameters["code"]
            ?: return@get call.respond(HttpStatusCode.BadRequest, "Falta el código")

        val tokenResponse = runCatching {
            spotifyClient.post("https://accounts.spotify.com/api/token") {
                headers {
                    val credentials = Base64.getEncoder()
                        .encodeToString("$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET".toByteArray())
                    append(HttpHeaders.Authorization, "Basic $credentials")
                }
                setBody(FormDataContent(Parameters.build {
                    append("grant_type",   "authorization_code")
                    append("code",         code)
                    append("redirect_uri", SPOTIFY_REDIRECT_URI)
                }))
            }.body<SpotifyTokenResponse>()
        }.getOrElse { e ->
            return@get call.respond(
                HttpStatusCode.BadRequest,
                mapOf("error" to "Token error: ${e.message}")
            )
        }

        val userProfile = runCatching {
            spotifyClient.get("https://api.spotify.com/v1/me") {
                headers {
                    append(HttpHeaders.Authorization, "Bearer ${tokenResponse.accessToken}")
                }
            }.body<SpotifyUserProfile>()
        }.getOrElse { e ->
            return@get call.respond(
                HttpStatusCode.InternalServerError,
                mapOf("error" to "Profile error: ${e.message}")
            )
        }

        // DEBUG — loguear scopes otorgados por Spotify
        println("[DEBUG] Scopes otorgados: ${tokenResponse.scope}")
        println("[DEBUG] Refresh token presente: ${tokenResponse.refreshToken != null}")

        call.sessions.set(UserSession(
            accessToken   = tokenResponse.accessToken,
            refreshToken  = tokenResponse.refreshToken,
            spotifyUserId = userProfile.id,
        ))

        call.respondRedirect(
            "http://localhost:3000/#/callback?token=${tokenResponse.accessToken}&userId=${userProfile.id}&expiresIn=${tokenResponse.expiresIn}"
        )
    }

    // [NEW] Refresca el access token usando el refresh token guardado en sesión
    get("/auth/refresh") {
        val session = call.sessions.get<UserSession>()
        val refreshToken = session?.refreshToken
            ?: return@get call.respond(
                HttpStatusCode.Unauthorized,
                mapOf("error" to "No hay sesión activa o falta el refresh token")
            )

        val tokenResponse = runCatching {
            spotifyClient.post("https://accounts.spotify.com/api/token") {
                headers {
                    val credentials = Base64.getEncoder()
                        .encodeToString("$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET".toByteArray())
                    append(HttpHeaders.Authorization, "Basic $credentials")
                }
                setBody(FormDataContent(Parameters.build {
                    append("grant_type",    "refresh_token")
                    append("refresh_token", refreshToken)
                }))
            }.body<SpotifyTokenResponse>()
        }.getOrElse { e ->
            return@get call.respond(
                HttpStatusCode.BadGateway,
                mapOf("error" to "Error al refrescar token: ${e.message}")
            )
        }

        // Actualizar sesión con el nuevo access token
        // (el refresh token puede rotar o mantenerse igual según Spotify)
        call.sessions.set(session.copy(
            accessToken  = tokenResponse.accessToken,
            refreshToken = tokenResponse.refreshToken ?: session.refreshToken,
        ))

        call.respond(RefreshResponse(
            accessToken = tokenResponse.accessToken,
            expiresIn   = tokenResponse.expiresIn,
        ))
    }

    post("/auth/logout") {
        call.sessions.clear<UserSession>()
        call.respond(HttpStatusCode.OK, mapOf("message" to "Sesión cerrada"))
    }
}
