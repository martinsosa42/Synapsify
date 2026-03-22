package com.moodify.gateway

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

fun Route.spotifyAuthRoutes(client: HttpClient) {

    get("/auth/login") {
        val loginUrl = URLBuilder("https://accounts.spotify.com/authorize").apply {
            parameters.append("client_id",     SPOTIFY_CLIENT_ID)
            parameters.append("response_type", "code")
            parameters.append("redirect_uri",  SPOTIFY_REDIRECT_URI)
            parameters.append("scope",         SPOTIFY_SCOPES)
            parameters.append("show_dialog",   "false")
        }.buildString()
        call.respond(AuthResponse(loginUrl = loginUrl))
    }

    get("/auth/callback") {
        val code = call.request.queryParameters["code"]
            ?: return@get call.respond(HttpStatusCode.BadRequest, "Falta el código")

        // Intercambia code por token usando el cliente con ignoreUnknownKeys
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

        // Obtiene el perfil del usuario
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

        call.sessions.set(UserSession(
            accessToken   = tokenResponse.accessToken,
            refreshToken  = tokenResponse.refreshToken,
            spotifyUserId = userProfile.id,
        ))

        // Redirige a Flutter con el token
        call.respondRedirect(
            "http://localhost:57795/#/callback?token=${tokenResponse.accessToken}&userId=${userProfile.id}"
        )
    }

    post("/auth/logout") {
        call.sessions.clear<UserSession>()
        call.respond(HttpStatusCode.OK, mapOf("message" to "Sesión cerrada"))
    }
}
