-- Directos: grabar un stream en marcha y clipearlo por trozos.
--
-- La app del móvil pide el directo (estado 'pedido'); el agente que corre en
-- el Mac lo coge ('grabando'), va mandando trozos y marca el final. La fila
-- vive en la base de datos y no en memoria para que el agente pueda caerse,
-- reiniciarse y seguir sabiendo qué estaba grabando.
CREATE TABLE IF NOT EXISTS live_sessions (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    url TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pedido'
        CONSTRAINT live_sessions_status_check
        CHECK (status IN ('pedido', 'grabando', 'parando', 'terminado', 'error')),
    options JSONB NOT NULL DEFAULT '{}'::jsonb,
    chunk_minutes INTEGER NOT NULL DEFAULT 10,
    chunks_sent INTEGER NOT NULL DEFAULT 0,
    error_message TEXT,
    -- Quién lo está grabando y cuándo dio señales de vida por última vez: sin
    -- esto un agente muerto dejaría el directo "grabando" para siempre.
    agent_id VARCHAR(64),
    last_heartbeat TIMESTAMP WITH TIME ZONE,
    started_at TIMESTAMP WITH TIME ZONE,
    finished_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_live_sessions_user ON live_sessions(user_id, created_at DESC);
-- El agente pregunta constantemente por lo que tiene que coger o soltar.
CREATE INDEX IF NOT EXISTS idx_live_sessions_pending ON live_sessions(status)
    WHERE status IN ('pedido', 'grabando', 'parando');
