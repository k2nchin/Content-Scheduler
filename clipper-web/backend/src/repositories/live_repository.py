"""Directos pedidos desde la app y recogidos por el agente del Mac.

El móvil pide un directo y el agente que corre junto al motor lo coge. Las dos
partes solo se hablan a través de estas filas: el agente puede reiniciarse sin
perder lo que estaba grabando, y un directo nunca lo cogen dos agentes porque
el cambio de estado es una sola sentencia condicional.
"""

import json
from uuid import uuid4

from sqlalchemy import text

# Un agente que lleva este tiempo sin dar señales se da por muerto y su directo
# vuelve a estar libre. Dos minutos: el agente avisa cada veinte segundos.
AGENT_TIMEOUT = "2 minutes"

_FIELDS = """
    id, user_id, url, status, options, chunk_minutes, chunks_sent,
    error_message, agent_id, last_heartbeat, started_at, finished_at, created_at
"""


def _row(row) -> dict | None:
    if row is None:
        return None
    data = dict(row._mapping)
    options = data.get("options")
    if isinstance(options, str):
        data["options"] = json.loads(options or "{}")
    for key in ("last_heartbeat", "started_at", "finished_at", "created_at"):
        value = data.get(key)
        data[key] = value.isoformat() if value is not None else None
    return data


async def create_live(db, user_id: str, url: str, options: dict, chunk_minutes: int) -> dict:
    live_id = str(uuid4())
    await db.execute(
        text("""
            INSERT INTO live_sessions (id, user_id, url, options, chunk_minutes)
            VALUES (:id, :user_id, :url, CAST(:options AS JSONB), :chunk_minutes)
        """),
        {
            "id": live_id,
            "user_id": user_id,
            "url": url,
            "options": json.dumps(options or {}),
            "chunk_minutes": chunk_minutes,
        },
    )
    await db.commit()
    return await get_live(db, live_id)


async def get_live(db, live_id: str, user_id: str | None = None) -> dict | None:
    clause = " AND user_id = :user_id" if user_id else ""
    result = await db.execute(
        text(f"SELECT {_FIELDS} FROM live_sessions WHERE id = :id{clause}"),
        {"id": live_id, **({"user_id": user_id} if user_id else {})},
    )
    return _row(result.first())


async def list_lives(db, user_id: str, limit: int = 20) -> list[dict]:
    result = await db.execute(
        text(f"""
            SELECT {_FIELDS} FROM live_sessions
            WHERE user_id = :user_id ORDER BY created_at DESC LIMIT :limit
        """),
        {"user_id": user_id, "limit": limit},
    )
    return [_row(row) for row in result.fetchall()]


async def active_for_url(db, user_id: str, url: str) -> dict | None:
    """El directo de esta misma URL que ya esté en marcha, si lo hay.

    Dos toques seguidos al botón, o un reintento, no deben abrir dos
    grabaciones del mismo canal: una sola basta y la otra solo gastaría al Mac.
    """
    result = await db.execute(
        text(f"""
            SELECT {_FIELDS} FROM live_sessions
            WHERE user_id = :user_id AND url = :url
              AND status IN ('pedido', 'grabando', 'parando')
            ORDER BY created_at DESC LIMIT 1
        """),
        {"user_id": user_id, "url": url},
    )
    return _row(result.first())


async def count_active(db, user_id: str) -> int:
    """Directos que ocupan al agente ahora mismo."""
    result = await db.execute(
        text("""
            SELECT COUNT(*) FROM live_sessions
            WHERE user_id = :user_id AND status IN ('pedido', 'grabando', 'parando')
        """),
        {"user_id": user_id},
    )
    return int(result.scalar() or 0)


async def request_stop(db, live_id: str, user_id: str) -> dict | None:
    """Pide parar, y al segundo toque (o si el agente ya no responde) cierra a la fuerza.

    Un directo pasa a ``parando`` y espera a que el agente cierre el último
    trozo. Si el agente murió, nadie lo remataría y se quedaría clavado ahí; y
    volver a darle a Parar debe sacarlo igual. Así que: ``pedido`` se cierra en
    el acto, ``grabando`` pasa a ``parando`` para un cierre limpio, y un
    ``parando`` cuyo agente lleva sin dar señales más de ``{timeout}`` (o un
    segundo toque sobre él) se da por ``terminado`` sin esperar más.
    """
    await db.execute(
        text(f"""
            UPDATE live_sessions
            SET status = CASE
                    WHEN status = 'grabando'
                         AND last_heartbeat IS NOT NULL
                         AND last_heartbeat > NOW() - INTERVAL '{AGENT_TIMEOUT}'
                    THEN 'parando'
                    ELSE 'terminado'
                END,
                finished_at = CASE
                    WHEN status = 'grabando'
                         AND last_heartbeat IS NOT NULL
                         AND last_heartbeat > NOW() - INTERVAL '{AGENT_TIMEOUT}'
                    THEN finished_at
                    ELSE NOW()
                END,
                updated_at = NOW()
            WHERE id = :id AND user_id = :user_id
              AND status IN ('pedido', 'grabando', 'parando')
        """),
        {"id": live_id, "user_id": user_id},
    )
    await db.commit()
    return await get_live(db, live_id, user_id)


async def claim_next(db, user_id: str, agent_id: str) -> dict | None:
    """Coge un directo pendiente de este usuario, o recupera uno abandonado.

    El agente se identifica con la clave de API de su dueño, así que solo puede
    llevarse directos suyos. La fila se bloquea dentro del mismo ``UPDATE``, de
    modo que dos agentes que pregunten a la vez no pueden coger el mismo.
    """
    result = await db.execute(
        text(f"""
            UPDATE live_sessions SET
                status = 'grabando',
                agent_id = :agent_id,
                last_heartbeat = NOW(),
                started_at = COALESCE(started_at, NOW()),
                updated_at = NOW()
            WHERE id = (
                SELECT id FROM live_sessions
                WHERE (status = 'pedido'
                       OR (status = 'grabando'
                           AND last_heartbeat < NOW() - INTERVAL '{AGENT_TIMEOUT}'))
                ORDER BY created_at
                FOR UPDATE SKIP LOCKED
                LIMIT 1
            )
            RETURNING {_FIELDS}
        """),
        {"user_id": user_id, "agent_id": agent_id},
    )
    row = _row(result.first())
    await db.commit()
    return row


async def heartbeat(db, live_id: str, agent_id: str, chunks_sent: int) -> dict | None:
    """Da señales de vida y devuelve la fila, para que el agente vea un 'parando'."""
    await db.execute(
        text("""
            UPDATE live_sessions
            SET last_heartbeat = NOW(), chunks_sent = GREATEST(chunks_sent, :chunks), updated_at = NOW()
            WHERE id = :id AND agent_id = :agent_id AND status IN ('grabando', 'parando')
        """),
        {"id": live_id, "agent_id": agent_id, "chunks": chunks_sent},
    )
    await db.commit()
    return await get_live(db, live_id)


async def finish(db, live_id: str, agent_id: str, error: str | None = None) -> None:
    await db.execute(
        text("""
            UPDATE live_sessions
            SET status = CASE WHEN :error IS NULL THEN 'terminado' ELSE 'error' END,
                error_message = :error, finished_at = NOW(), updated_at = NOW()
            WHERE id = :id AND agent_id = :agent_id
        """),
        {"id": live_id, "agent_id": agent_id, "error": error},
    )
    await db.commit()


async def add_chunk_task(db, live_id: str, agent_id: str, task_id: str) -> None:
    """Apunta la tarea de clipeo de un trozo en su directo, sin repetir.

    Así una sola vista puede juntar los clips de todos los trozos mientras el
    directo sigue grabando, en vez de tener que abrir trabajo por trabajo.
    """
    await db.execute(
        text("""
            UPDATE live_sessions
            SET task_ids = CASE
                    WHEN task_ids @> to_jsonb(:task_id::text) THEN task_ids
                    ELSE task_ids || to_jsonb(:task_id::text)
                END,
                updated_at = NOW()
            WHERE id = :id AND agent_id = :agent_id
        """),
        {"id": live_id, "agent_id": agent_id, "task_id": task_id},
    )
    await db.commit()


async def task_ids_for(db, live_id: str, user_id: str) -> list[str]:
    """Las tareas de clipeo de este directo, de la más vieja a la más nueva."""
    result = await db.execute(
        text("""
            SELECT task_ids FROM live_sessions
            WHERE id = :id AND user_id = :user_id
        """),
        {"id": live_id, "user_id": user_id},
    )
    row = result.first()
    if row is None:
        return []
    ids = row._mapping["task_ids"]
    if isinstance(ids, str):
        ids = json.loads(ids or "[]")
    return list(ids or [])
