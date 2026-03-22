package com.moodify.gateway

import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.server.plugins.callloging.*
import io.ktor.server.plugins.cors.routing.*
import io.ktor.server.sessions.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.http.*
import org.slf4j.event.Level
import kotlinx.serialization.json.Json

fun main() {
    embeddedServer(Netty, port = 8080, module = Application::module).start(wait = true)
}

fun Application.module() {
    install(ContentNegotiation) {
        json(Json {
            ignoreUnknownKeys = true
        })
    }

    install(CallLogging) { level = Level.INFO }

    install(CORS) {
        anyHost()
        allowMethod(HttpMethod.Post)
        allowMethod(HttpMethod.Get)
        allowHeader(HttpHeaders.ContentType)
        allowHeader(HttpHeaders.Authorization)
        allowCredentials = true
    }

    install(Sessions) {
        cookie<UserSession>("moodify_session") {
            cookie.httpOnly = true
            cookie.maxAgeInSeconds = 3600
        }
    }

    configureRouting()
}