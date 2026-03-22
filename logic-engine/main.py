from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer
import spotipy
from spotipy.oauth2 import SpotifyClientCredentials, SpotifyOAuth
from spotipy import Spotify
import os
from dotenv import load_dotenv

load_dotenv()

app = FastAPI(title="Moodify Me - Logic Engine", version="2.0.0")

analyzer = SentimentIntensityAnalyzer()

# Client de solo lectura (sin usuario autenticado)
sp_public = Spotify(auth_manager=SpotifyClientCredentials(
    client_id=os.getenv("SPOTIFY_CLIENT_ID"),
    client_secret=os.getenv("SPOTIFY_CLIENT_SECRET"),
))

# ── Schemas ───────────────────────────────────────────────────────────────────

class MoodRequest(BaseModel):
    text: str
    limit: int = 10
    accessToken: str | None = None   # token OAuth2 del usuario (opcional)
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
    sentiment: str
    compound: float
    valence: float
    energy: float
    danceability: float
    tracks: list[TrackOut]
    playlistId: str | None = None
    playlistUrl: str | None = None

# ── Helpers ───────────────────────────────────────────────────────────────────

def compound_to_label(compound: float) -> str:
    if compound >= 0.05:
        return "positive"
    elif compound <= -0.05:
        return "negative"
    return "neutral"


def score_to_audio_features(compound: float) -> dict:
    valence = round((compound + 1) / 2, 2)
    if compound >= 0.5:
        energy, danceability = 0.8, 0.75
    elif compound >= 0.05:
        energy, danceability = 0.6, 0.6
    elif compound >= -0.05:
        energy, danceability = 0.5, 0.5
    elif compound >= -0.5:
        energy, danceability = 0.4, 0.4
    else:
        energy, danceability = 0.25, 0.3
    return {"valence": valence, "energy": energy, "danceability": danceability}


GENRE_QUERIES = {
    "positive": "pop feliz dance hits",
    "neutral":  "indie chill lo-fi focus",
    "negative": "sad songs acoustic melancholic",
}


def search_tracks(sp: Spotify, query: str, limit: int) -> list[TrackOut]:
    results = sp.search(q=query, type="track", limit=limit, market="AR")
    raw_tracks = results["tracks"]["items"]
    track_ids = [t["id"] for t in raw_tracks]

    try:
        audio_features = sp.audio_features(track_ids) or []
    except Exception:
        audio_features = []

    af_map = {af["id"]: af for af in audio_features if af}

    return [
        TrackOut(
            id=t["id"],
            name=t["name"],
            artist=t["artists"][0]["name"],
            preview_url=t.get("preview_url"),
            valence=af_map.get(t["id"], {}).get("valence", 0.0),
            energy=af_map.get(t["id"], {}).get("energy", 0.0),
            danceability=af_map.get(t["id"], {}).get("danceability", 0.0),
        )
        for t in raw_tracks
    ]


def save_playlist_to_spotify(
    sp: Spotify,
    user_id: str,
    mood_text: str,
    track_ids: list[str],
    sentiment: str,
) -> tuple[str, str]:
    """Crea una playlist en la cuenta del usuario y agrega las canciones."""
    playlist = sp.user_playlist_create(
        user=user_id,
        name=f"Moodify: {mood_text[:40]}",
        public=False,
        description=f"Generada por Moodify Me · Sentimiento: {sentiment}",
    )
    sp.playlist_add_items(playlist["id"], [f"spotify:track:{tid}" for tid in track_ids])
    return playlist["id"], playlist["external_urls"]["spotify"]


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.post("/analyze", response_model=MoodResponse)
async def analyze_mood(req: MoodRequest):
    if not req.text.strip():
        raise HTTPException(status_code=422, detail="El texto no puede estar vacío.")


    # Análisis de sentimiento
    scores = analyzer.polarity_scores(req.text)
    compound = scores["compound"]
    features = score_to_audio_features(compound)
    label = compound_to_label(compound)

    # Elegimos el cliente correcto según si hay token de usuario
    if req.accessToken:
        sp = Spotify(auth=req.accessToken)
    else:
        sp = sp_public

    # Búsqueda de canciones
    query = GENRE_QUERIES[label]
    try:
        tracks = search_tracks(sp, query, req.limit)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Error Spotify: {str(e)}")

    # Guardar playlist si el usuario está autenticado
    playlist_id, playlist_url = None, None
    if req.accessToken and req.userId and tracks:
        try:
            playlist_id, playlist_url = save_playlist_to_spotify(
                sp=sp,
                user_id=req.userId,
                mood_text=req.text,
                track_ids=[t.id for t in tracks],
                sentiment=label,
            )
        except Exception as e:
            # No es crítico — devolvemos las canciones igual
            print(f"No se pudo guardar la playlist: {e}")

    return MoodResponse(
        sentiment=label,
        compound=compound,
        tracks=tracks,
        playlistId=playlist_id,
        playlistUrl=playlist_url,
        **features,
    )


@app.post("/feedback")
async def save_feedback(track_id: str, liked: bool, mood: str):
    """
    Endpoint para el bucle de feedback (Fase 4).
    Por ahora loguea el dato — en Fase 4 se conecta a una DB.
    """
    print(f"FEEDBACK | track={track_id} | liked={liked} | mood={mood}")
    return {"status": "ok"}


@app.get("/health")
async def health():
    return {"status": "ok", "service": "logic-engine"}
