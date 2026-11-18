"""Directos: pedir desde el móvil, grabar en el Mac.

El teléfono no puede grabar un directo de cuatro horas, pero el Mac sí. Aquí se
anota lo que el teléfono pide; el agente que corre junto al motor lo recoge,
graba por trozos y cada trozo entra como una tarea normal de clipeo.

Las rutas del agente se autentican con la misma clave de API que todo lo demás,
así que un agente solo ve y coge los directos de su dueño.
"""

import logging
import os
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from ...auth_headers import resolve_authenticated_user_id
from ...config import get_config
from ...database import get_db
from ...repositories import live_repository as repo
from ...stream_source import live_channel_source

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/lives", tags=["lives"])

# Cuántos directos puede tener uno en marcha a la vez. Debe ir a la par con el
# agente (MAX_DIRECTOS) y con los clips en paralelo (VIDEO_JOB_USER_CONCURRENCY):
# de nada sirve grabar cinco si solo se clipea de uno en uno.
MAX_ACTIVE_LIVES = max(1, int(os.getenv("MAX_DIRECTOS_EN_MARCHA", "3")))
# De qué sitios se puede grabar un directo.
LIVE_SOURCES = {"youtube", "twitch", "kick"}


class CreateLive(BaseModel):
    url: str = Field(min_length=8, max_length=2000)
    # Cada cuánto se cierra un trozo y se manda a clipear: cuanto más corto,
    # antes salen los clips, pero menos contexto tiene el análisis.
    chunk_minutes: int = Field(default=10, ge=2, le=30)
    options: dict = Field(default_factory=dict)


async def _user(request: Request, db: AsyncSession) -> str:
    return await resolve_authenticated_user_id(request, db, get_config())


def _check_source(url: str) -> str:
    """El enlace de un directo en marcha, no el de un video ya terminado.

    Un VOD o un clip ya se pueden clipear de una vez por la vía normal, así que
    mandarlo aquí solo haría que el Mac lo "grabase" sin motivo.
    """
    source = live_channel_source(url)
    if source not in LIVE_SOURCES:
        raise HTTPException(
            status_code=400,
            detail=(
                "Esto no parece un directo. Pega el enlace del canal en directo "
                "de YouTube, Twitch o Kick. Un video ya terminado se clipea con "
                "«Mandar al iMac»."
            ),
        )
    return source


@router.post("/")
async def start_live(body: CreateLive, request: Request, db: AsyncSession = Depends(get_db)):
    """Anota un directo para que el Mac lo grabe y lo vaya clipeando."""
    user_id = await _user(request, db)
    url = body.url.strip()
    _check_source(url)
    # Dos toques al botón no abren dos grabaciones del mismo canal.
    ya = await repo.active_for_url(db, user_id, url)
    if ya is not None:
        return ya
    if await repo.count_active(db, user_id) >= MAX_ACTIVE_LIVES:
        raise HTTPException(
            status_code=409,
            detail=f"Ya hay {MAX_ACTIVE_LIVES} directos en marcha. Para uno antes de empezar otro.",
        )
    live = await repo.create_live(db, user_id, url, body.options, body.chunk_minutes)
    logger.info("Live %s requested by %s", live["id"], user_id)
    return live


@router.get("/")
async def list_lives(request: Request, db: AsyncSession = Depends(get_db)):
    user_id = await _user(request, db)
    return {"lives": await repo.list_lives(db, user_id)}


@router.get("/{live_id}")
async def get_live(live_id: str, request: Request, db: AsyncSession = Depends(get_db)):
    user_id = await _user(request, db)
    live = await repo.get_live(db, live_id, user_id)
    if live is None:
        raise HTTPException(status_code=404, detail="Ese directo no existe.")
    return live


@router.post("/{live_id}/stop")
async def stop_live(live_id: str, request: Request, db: AsyncSession = Depends(get_db)):
    """Pide parar. El trozo a medias se manda igual antes de cerrar."""
    user_id = await _user(request, db)
    if await repo.get_live(db, live_id, user_id) is None:
        raise HTTPException(status_code=404, detail="Ese directo no existe.")
    return await repo.request_stop(db, live_id, user_id)


# ─────────────────────────── El agente del Mac


class AgentCall(BaseModel):
    agent_id: str = Field(min_length=3, max_length=64)


class AgentProgress(AgentCall):
    chunks_sent: int = Field(default=0, ge=0)


class AgentFinish(AgentCall):
    error: str | None = Field(default=None, max_length=2000)


@router.post("/agent/claim")
async def claim_live(body: AgentCall, request: Request, db: AsyncSession = Depends(get_db)):
    """Entrega el siguiente directo que haya que grabar, o nada."""
    user_id = await _user(request, db)
    live = await repo.claim_next(db, user_id, body.agent_id)
    return {"live": live}


@router.post("/{live_id}/agent/heartbeat")
async def live_heartbeat(
    live_id: str, body: AgentProgress, request: Request, db: AsyncSession = Depends(get_db)
):
    """Señal de vida. La respuesta dice si el usuario pidió parar."""
    user_id = await _user(request, db)
    live = await repo.heartbeat(db, live_id, body.agent_id, body.chunks_sent)
    if live is None or live["user_id"] != user_id:
        raise HTTPException(status_code=404, detail="Ese directo no existe.")
    return {"status": live["status"]}


@router.post("/{live_id}/agent/finish")
async def live_finished(
    live_id: str, body: AgentFinish, request: Request, db: AsyncSession = Depends(get_db)
):
    user_id = await _user(request, db)
    live = await repo.get_live(db, live_id, user_id)
    if live is None:
        raise HTTPException(status_code=404, detail="Ese directo no existe.")
    await repo.finish(db, live_id, body.agent_id, body.error)
    return await repo.get_live(db, live_id, user_id)
