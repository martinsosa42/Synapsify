from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from spotipy import Spotify, SpotifyClientCredentials
from spotipy.cache_handler import MemoryCacheHandler
from groq import Groq
import os
import json
import logging
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ── App & Middleware ──────────────────────────────────────────────────────────

limiter = Limiter(key_func=get_remote_address)

app = FastAPI(title="Synapsify - Logic Engine", version="3.3.0")

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[os.getenv("ALLOWED_ORIGIN", "http://localhost:3000")],
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)

# ── Clientes ──────────────────────────────────────────────────────────────────

sp_public = Spotify(auth_manager=SpotifyClientCredentials(
    client_id=os.getenv("SPOTIFY_CLIENT_ID"),
    client_secret=os.getenv("SPOTIFY_CLIENT_SECRET"),
    cache_handler=MemoryCacheHandler(),
))

groq_client = Groq(api_key=os.getenv("GROQ_API_KEY"))

# ── Schemas ───────────────────────────────────────────────────────────────────

class MoodRequest(BaseModel):
    text: str
    limit: int = Field(default=50, ge=1, le=50)  # [CHANGE] default 10 → 50
    accessToken: str | None = None
    userId: str | None = None


class TrackOut(BaseModel):
    id: str
    name: str
    artist: str
    preview_url: str | None
    valence: float
    energy: float
    danceability: float


class MoodResponse(BaseModel):
    interpretation: str
    query_used: str
    tracks: list[TrackOut]
    playlistId: str | None = None
    playlistUrl: str | None = None


# [NEW] Schemas para /export
class ExportRequest(BaseModel):
    accessToken: str
    trackIds: list[str] = Field(min_length=1, max_length=50)
    mode: str = Field(pattern="^(create|add)$")          # "create" o "add"
    playlistName: str | None = Field(default=None, max_length=100)
    targetPlaylistId: str | None = None
    moodText: str | None = Field(default=None, max_length=100)


class ExportResponse(BaseModel):
    playlistId: str
    playlistUrl: str
    tracksAdded: int


# ── Prompt ────────────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """Sos un experto en música que convierte descripciones en lenguaje natural 
en parámetros de búsqueda para la API de Spotify.

El usuario describe lo que quiere escuchar. Tu trabajo es interpretar ese pedido y devolver 
un JSON con los parámetros óptimos para buscar en Spotify.

IMPORTANTE: Respondé ÚNICAMENTE con un JSON válido, sin texto adicional, sin markdown, 
sin explicaciones. Solo el JSON puro.

El JSON debe tener exactamente esta estructura:
{
  "search_query": "string - query optimizada para Spotify search en inglés",
  "search_type": "track",
  "market": "AR",
  "interpretation": "string - en español, qué entendiste del pedido en máximo 1 oración",
  "target_energy": número entre 0.0 y 1.0 o null,
  "target_valence": número entre 0.0 y 1.0 o null,
  "target_danceability": número entre 0.0 y 1.0 o null,
  "target_tempo": número en BPM o null
}

Guía de parámetros de audio:
- energy: 0.0 = muy tranquilo/ambient, 1.0 = muy intenso/explosivo
- valence: 0.0 = triste/oscuro, 1.0 = alegre/eufórico  
- danceability: 0.0 = no bailable, 1.0 = muy bailable
- tempo: en BPM (techno ~140, hip-hop ~90, jazz ~120, pop ~120)

Ejemplos:
- "Jazz suave para estudiar de noche" → query: "jazz study lofi night", energy: 0.3, valence: 0.4
- "Canciones de Travis Scott" → query: "Travis Scott", energy: null, valence: null
- "Progressive para un atardecer" → query: "progressive house sunset melodic", energy: 0.65, valence: 0.6
- "Rock argentino de los 90" → query: "rock argentino 90s", energy: 0.7
- "Techno para correr" → query: "techno running workout", energy: 0.9, tempo: 140
"""

VALID_MARKETS = {
    "AR", "US", "ES", "MX", "BR", "CO", "CL", "PE", "UY", "PY",
    "GB", "DE", "FR", "IT", "JP", "AU", "CA", "NZ", "ZA",
}


def _clamp_float(value, lo: float = 0.0, hi: float = 1.0):
    try:
        v = float(value)
        return v if lo <= v <= hi else None
    except (TypeError, ValueError):
        return None


def validate_groq_params(params: dict) -> dict:
    query = str(params.get("search_query", "")).strip()[:200]
    if not query:
        raise ValueError("search_query vacío o ausente en la respuesta del modelo.")

    market = params.get("market", "AR")
    if market not in VALID_MARKETS:
        market = "AR"

    tempo = params.get("target_tempo")
    try:
        tempo = float(tempo) if tempo is not None else None
        if tempo is not None and not (40 <= tempo <= 220):
            tempo = None
    except (TypeError, ValueError):
        tempo = None

    return {
        "search_query":        query,
        "market":              market,
        "interpretation":      str(params.get("interpretation", ""))[:300],
        "target_energy":       _clamp_float(params.get("target_energy")),
        "target_valence":      _clamp_float(params.get("target_valence")),
        "target_danceability": _clamp_float(params.get("target_danceability")),
        "target_tempo":        tempo,
    }


def interpret_with_groq(text: str) -> dict:
    response = groq_client.chat.completions.create(
        model="llama-3.3-70b-versatile",
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Pedido del usuario: {text}"}
        ],
        max_tokens=500,
        temperature=0.3,
    )

    raw = response.choices[0].message.content.strip()

    if "```" in raw:
        parts = raw.split("```")
        for part in parts:
            part = part.strip()
            if part.startswith("json"):
                part = part[4:].strip()
            if part.startswith("{"):
                raw = part
                break

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        logger.error("Groq devolvió JSON inválido: %s", raw[:200])
        raise ValueError("El modelo devolvió una respuesta con formato inválido.")

    return validate_groq_params(parsed)


# ── Helpers Spotify ───────────────────────────────────────────────────────────

_SEARCH_PAGE_SIZE = 10  # spotipy acepta máx 20 por llamada con Client Credentials

def search_tracks(sp: Spotify, params: dict, limit: int) -> list[TrackOut]:
    query = params.get("search_query", "")
    market = params.get("market", "AR")

    # Spotify Search acepta máx 20 por página — hacemos las páginas necesarias
    raw_tracks: list = []
    pages = (limit + _SEARCH_PAGE_SIZE - 1) // _SEARCH_PAGE_SIZE  # ceil division
    for page in range(pages):
        need = min(_SEARCH_PAGE_SIZE, limit - len(raw_tracks))
        try:
            results = sp.search(
                q=query, type="track",
                limit=need, offset=page * _SEARCH_PAGE_SIZE,
                market=market,
            )
            items = results["tracks"]["items"]
            raw_tracks.extend(items)
            if len(items) < need:
                break  # Spotify no tiene más resultados
        except Exception:
            logger.warning("Página %d de búsqueda falló, usando lo que hay", page)
            break

    if not raw_tracks:
        return []

    track_ids = [t["id"] for t in raw_tracks]

    try:
        audio_features = sp.audio_features(track_ids) or []
    except Exception:
        audio_features = []

    af_map = {af["id"]: af for af in audio_features if af}

    target_energy = params.get("target_energy")
    target_valence = params.get("target_valence")
    target_danceability = params.get("target_danceability")

    scored_tracks = []
    for track in raw_tracks:
        if not track.get("id") or not track.get("name"):
            continue
        if not track.get("artists"):
            continue
        af = af_map.get(track["id"], {})
        valence = af.get("valence", 0.5)
        energy = af.get("energy", 0.5)
        danceability = af.get("danceability", 0.5)

        targets = [
            (target_energy, energy),
            (target_valence, valence),
            (target_danceability, danceability),
        ]
        active = [(t, v) for t, v in targets if t is not None]

        if active:
            match_score = sum(1 - abs(t - v) for t, v in active) / len(active)
        else:
            match_score = 1.0

        scored_tracks.append((match_score, TrackOut(
            id=track["id"],
            name=track["name"],
            artist=track["artists"][0]["name"],
            preview_url=track.get("preview_url"),
            valence=valence,
            energy=energy,
            danceability=danceability,
        )))

    scored_tracks.sort(key=lambda x: x[0], reverse=True)
    return [t for _, t in scored_tracks]


def save_playlist(access_token: str, text: str,
                  track_ids: list[str], interpretation: str) -> tuple[str, str]:
    import requests as req_lib
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
    }
    # [FIX] POST /me/playlists en vez del deprecado /users/{id}/playlists
    resp = req_lib.post(
        "https://api.spotify.com/v1/me/playlists",
        headers=headers,
        json={
            "name": f"Synapsify: {text[:40]}",
            "public": True,
            "description": f"Generada por Synapsify · {interpretation}",
        },
    )
    resp.raise_for_status()
    playlist = resp.json()
    playlist_id = playlist["id"]
    uris = [f"spotify:track:{tid}" for tid in track_ids]
    for i in range(0, len(uris), 100):
        req_lib.post(
            f"https://api.spotify.com/v1/playlists/{playlist_id}/items",
            headers=headers,
            json={"uris": uris[i:i+100]},
        )
    return playlist_id, playlist["external_urls"]["spotify"]


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.post("/analyze", response_model=MoodResponse)
@limiter.limit("10/minute")
async def analyze_mood(req: MoodRequest, request: Request):
    if not req.text.strip():
        raise HTTPException(status_code=422, detail="El texto no puede estar vacío.")

    try:
        params = interpret_with_groq(req.text)
    except ValueError as e:
        raise HTTPException(status_code=502, detail=str(e))
    except Exception:
        logger.exception("Error inesperado al llamar a Groq")
        raise HTTPException(status_code=502, detail="Error al interpretar el pedido.")

    interpretation = params.get("interpretation", req.text)
    query_used = params.get("search_query", req.text)

    # Búsqueda siempre con Client Credentials (sin límites de token de usuario)
    sp_user = Spotify(auth=req.accessToken) if req.accessToken else None

    try:
        tracks = search_tracks(sp_public, params, req.limit)
    except Exception:
        logger.exception("Error al buscar en Spotify")
        raise HTTPException(status_code=502, detail="Error al buscar canciones en Spotify.")

    if not tracks:
        raise HTTPException(status_code=404,
                            detail="No se encontraron canciones para ese pedido.")

    playlist_id, playlist_url = None, None
    if sp_user:
        try:
            playlist_id, playlist_url = save_playlist(
                access_token=req.accessToken,
                text=req.text,
                track_ids=[t.id for t in tracks],
                interpretation=interpretation,
            )
        except Exception:
            logger.exception("No se pudo guardar la playlist")

    return MoodResponse(
        interpretation=interpretation,
        query_used=query_used,
        tracks=tracks,
        playlistId=playlist_id,
        playlistUrl=playlist_url,
    )


# [NEW] Endpoint de export explícito
@app.post("/export", response_model=ExportResponse)
@limiter.limit("10/minute")
async def export_playlist(req: ExportRequest, request: Request):
    import requests as req_lib

    headers = {
        "Authorization": f"Bearer {req.accessToken}",
        "Content-Type": "application/json",
    }
    uris = [f"spotify:track:{tid}" for tid in req.trackIds]

    try:
        if req.mode == "create":
            name = req.playlistName or f"Synapsify · {req.moodText or 'Mix'}"[:100]

            # [FIX] Usar POST /me/playlists en vez del deprecado /users/{id}/playlists
            resp = req_lib.post(
                "https://api.spotify.com/v1/me/playlists",
                headers=headers,
                json={"name": name, "public": True, "description": "Exportada desde Synapsify"},
            )
            if resp.status_code not in (200, 201):
                logger.error("Spotify create playlist: %s %s", resp.status_code, resp.text)
                raise HTTPException(status_code=502, detail=f"Spotify error {resp.status_code}: {resp.text}")

            playlist = resp.json()
            playlist_id = playlist["id"]
            playlist_url = playlist["external_urls"]["spotify"]

            # Agregar tracks en batches de 100 (límite de Spotify)
            for i in range(0, len(uris), 100):
                batch = uris[i:i+100]
                add_resp = req_lib.post(
                    f"https://api.spotify.com/v1/playlists/{playlist_id}/items",
                    headers=headers,
                    json={"uris": batch},
                )
                if add_resp.status_code not in (200, 201):
                    logger.error("Spotify add tracks: %s %s", add_resp.status_code, add_resp.text)

            return ExportResponse(
                playlistId=playlist_id,
                playlistUrl=playlist_url,
                tracksAdded=len(uris),
            )

        else:  # mode == "add"
            if not req.targetPlaylistId:
                raise HTTPException(status_code=422,
                                    detail="targetPlaylistId requerido para mode=add")

            for i in range(0, len(uris), 100):
                batch = uris[i:i+100]
                add_resp = req_lib.post(
                    f"https://api.spotify.com/v1/playlists/{req.targetPlaylistId}/items",
                    headers=headers,
                    json={"uris": batch},
                )
                if add_resp.status_code not in (200, 201):
                    logger.error("Spotify add tracks: %s %s", add_resp.status_code, add_resp.text)

            # Obtener URL de la playlist
            pl_resp = req_lib.get(
                f"https://api.spotify.com/v1/playlists/{req.targetPlaylistId}?fields=id,external_urls",
                headers=headers,
            )
            playlist = pl_resp.json()
            return ExportResponse(
                playlistId=playlist["id"],
                playlistUrl=playlist["external_urls"]["spotify"],
                tracksAdded=len(uris),
            )

    except HTTPException:
        raise
    except Exception:
        logger.exception("Error al exportar playlist")
        raise HTTPException(status_code=502, detail="Error al exportar la playlist.")


# Endpoint para listar playlists del usuario (usado en mode=add)
@app.get("/playlists")
async def list_playlists(access_token: str):
    if not access_token:
        raise HTTPException(status_code=401, detail="access_token requerido.")
    import requests as req_lib
    try:
        headers = {"Authorization": f"Bearer {access_token}"}
        resp = req_lib.get("https://api.spotify.com/v1/me/playlists?limit=50", headers=headers)
        if resp.status_code != 200:
            logger.error("Spotify playlists: %s %s", resp.status_code, resp.text)
            raise HTTPException(status_code=502, detail="Error al obtener las playlists.")
        data = resp.json()
        # Obtener el userId del token para filtrar por owner
        me_resp = req_lib.get("https://api.spotify.com/v1/me", headers=headers)
        user_id = me_resp.json().get("id") if me_resp.status_code == 200 else None

        playlists = []
        for p in data.get("items", []):
            if not p or not p.get("id"):
                continue
            # [FIX] Solo mostrar playlists donde el usuario es dueño o colaborador
            owner_id = (p.get("owner") or {}).get("id")
            is_collaborative = p.get("collaborative", False)
            if owner_id != user_id and not is_collaborative:
                continue
            tracks_info = p.get("tracks") or {}
            playlists.append({
                "id": p["id"],
                "name": p["name"],
                "total": tracks_info.get("total", 0),
            })
        return {"playlists": playlists}
    except HTTPException:
        raise
    except Exception:
        logger.exception("Error al obtener playlists")
        raise HTTPException(status_code=502, detail="Error al obtener las playlists.")


@app.get("/health")
async def health():
    return {"status": "ok", "service": "synapsify-logic-engine", "version": "3.3.0"}
