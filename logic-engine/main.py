from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import spotipy
from spotipy.oauth2 import SpotifyClientCredentials
from spotipy import Spotify
from groq import Groq
import os
import json
from dotenv import load_dotenv

load_dotenv()

app = FastAPI(title="Moodify - Logic Engine", version="3.2.0")

# ── Clientes ──────────────────────────────────────────────────────────────────

sp_public = Spotify(auth_manager=SpotifyClientCredentials(
    client_id=os.getenv("SPOTIFY_CLIENT_ID"),
    client_secret=os.getenv("SPOTIFY_CLIENT_SECRET"),
))

groq_client = Groq(api_key=os.getenv("GROQ_API_KEY"))

# ── Schemas ───────────────────────────────────────────────────────────────────

class MoodRequest(BaseModel):
    text: str
    limit: int = 10
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


def interpret_with_groq(text: str) -> dict:
    """Usa Groq para convertir lenguaje natural en parámetros de Spotify."""
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

    # Limpiar si el modelo agrega backticks por accidente
    if "```" in raw:
        parts = raw.split("```")
        for part in parts:
            part = part.strip()
            if part.startswith("json"):
                part = part[4:].strip()
            if part.startswith("{"):
                raw = part
                break

    return json.loads(raw)


# ── Helpers Spotify ───────────────────────────────────────────────────────────

def search_tracks(sp: Spotify, params: dict, limit: int) -> list[TrackOut]:
    query = params.get("search_query", "")
    market = params.get("market", "AR")

    results = sp.search(q=query, type="track", limit=limit, market=market)
    raw_tracks = results["tracks"]["items"]

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


def save_playlist(sp: Spotify, user_id: str, text: str,
                  track_ids: list[str], interpretation: str) -> tuple[str, str]:
    playlist = sp.user_playlist_create(
        user=user_id,
        name=f"Moodify: {text[:40]}",
        public=False,
        description=f"Generada por Moodify · {interpretation}",
    )
    sp.playlist_add_items(playlist["id"], [f"spotify:track:{tid}" for tid in track_ids])
    return playlist["id"], playlist["external_urls"]["spotify"]


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.post("/analyze", response_model=MoodResponse)
async def analyze_mood(req: MoodRequest):
    if not req.text.strip():
        raise HTTPException(status_code=422, detail="El texto no puede estar vacío.")

    # 1. Groq interpreta el pedido
    try:
        params = interpret_with_groq(req.text)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Error al interpretar con Groq: {str(e)}")

    interpretation = params.get("interpretation", req.text)
    query_used = params.get("search_query", req.text)

    # 2. Elegimos el cliente de Spotify
    sp = Spotify(auth=req.accessToken) if req.accessToken else sp_public

    # 3. Buscamos canciones
    try:
        tracks = search_tracks(sp, params, req.limit)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Error Spotify: {str(e)}")

    if not tracks:
        raise HTTPException(status_code=404,
                            detail="No se encontraron canciones para ese pedido.")

    # 4. Guardamos playlist si hay sesión activa
    playlist_id, playlist_url = None, None
    if req.accessToken and req.userId:
        try:
            playlist_id, playlist_url = save_playlist(
                sp=sp,
                user_id=req.userId,
                text=req.text,
                track_ids=[t.id for t in tracks],
                interpretation=interpretation,
            )
        except Exception as e:
            print(f"No se pudo guardar la playlist: {e}")

    return MoodResponse(
        interpretation=interpretation,
        query_used=query_used,
        tracks=tracks,
        playlistId=playlist_id,
        playlistUrl=playlist_url,
    )


@app.post("/feedback")
async def save_feedback(track_id: str, liked: bool, mood: str):
    print(f"FEEDBACK | track={track_id} | liked={liked} | mood={mood}")
    return {"status": "ok"}


@app.get("/health")
async def health():
    return {"status": "ok", "service": "logic-engine", "version": "3.2.0"}
