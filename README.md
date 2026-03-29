# 🎵 Synapsify

Synapsify convierte lenguaje humano en playlists de Spotify.  
Escribís lo que querés escuchar — en cualquier forma, en cualquier idioma — y Synapsify lo interpreta y te arma la playlist.

> "Progressive para un atardecer"  
> "Jazz para estudiar de noche"  
> "Rock argentino de los 90"

---

## ¿Cómo funciona?

1. El usuario escribe un prompt en lenguaje natural
2. El **API Gateway** (Kotlin/Ktor) recibe la petición y la reenvía al motor de análisis
3. El **Logic Engine** (Python/FastAPI) interpreta el texto con **Groq (Llama 3.3 70b)**, genera una query optimizada para Spotify y busca canciones que coincidan con los parámetros de audio (energy, valence, danceability)
4. Si el usuario está autenticado con Spotify, la playlist se guarda automáticamente en su cuenta
5. Flutter muestra los resultados con los parámetros de audio de cada canción

---

## Arquitectura

```
Usuario
  │
  ▼
Flutter App — localhost:3000
  │  POST /mood { "mood": "texto libre del usuario" }
  ▼
API Gateway (Kotlin/Ktor) — puerto 8080
  │  Routing, OAuth2, comunicación entre servicios
  ▼
Logic Engine (Python/FastAPI) — puerto 8000
  │  Interpretación NLP (Groq) + búsqueda en Spotify
  ▼
Groq API (Llama 3.3 70b) + Spotify API
```

---

## Tecnologías

| Capa | Tecnología |
|---|---|
| Frontend | Flutter / Dart |
| API Gateway | Kotlin / Ktor |
| Logic Engine | Python / FastAPI |
| Interpretación NLP | Groq — Llama 3.3 70b |
| Música | Spotify API (Spotipy) |
| Auth | Spotify OAuth2 |
| Rate Limiting | slowapi |
| Infraestructura | Docker / Docker Compose |

---

## Estructura del proyecto

```
synapsify/
├── flutter-app/
│   ├── lib/main.dart
│   └── pubspec.yaml
├── api-gateway/
│   ├── src/main/kotlin/com/synapsify/gateway/
│   │   ├── Application.kt       # Servidor + CORS + Sessions
│   │   ├── Routing.kt           # Endpoints + cliente HTTP
│   │   └── SpotifyAuth.kt       # OAuth2 flow completo
│   ├── build.gradle.kts
│   └── Dockerfile
├── logic-engine/
│   ├── main.py                  # Interpretación NLP + Spotify search + guardar playlist
│   ├── requirements.txt
│   └── Dockerfile
├── docker-compose.yml
├── .env.example
└── .gitignore
```

---

## Cómo correr el proyecto

### Requisitos

- Docker Desktop
- Flutter SDK
- Cuenta en Spotify for Developers
- API Key de [Groq](https://console.groq.com)

### Paso 1 — Credenciales

Creá una app en el [dashboard de Spotify](https://developer.spotify.com/dashboard). Agregá esta URI de redirección:

```
http://127.0.0.1:8080/auth/callback
```

Copiá el `.env.example` a `.env` y completá las credenciales:

```powershell
copy .env.example .env
```

### Paso 2 — Backend

```powershell
docker compose up --build
```

### Paso 3 — Frontend

```powershell
cd flutter-app
flutter pub get
flutter run -d chrome --web-port=3000 --web-browser-flag="--disable-web-security"
```

> ⚠️ El flag `--disable-web-security` es necesario para desarrollo local. No usar en producción.

---

## Variables de entorno

```env
SPOTIFY_CLIENT_ID=
SPOTIFY_CLIENT_SECRET=
SPOTIFY_REDIRECT_URI=http://127.0.0.1:8080/auth/callback
GROQ_API_KEY=
JWT_SECRET=
LOGIC_ENGINE_URL=http://logic-engine:8000
ALLOWED_ORIGIN=http://localhost:3000
```

---

## Autor

Desarrollado por Martín Sergio Sosa.
