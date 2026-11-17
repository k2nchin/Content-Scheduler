"""Qué enlaces se aceptan para grabar un directo."""

import pytest
from fastapi import HTTPException

from src.api.routes.lives import CreateLive, _check_source


@pytest.mark.parametrize("url, source", [
    ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "youtube"),
    ("https://www.twitch.tv/somestreamer", "twitch"),
    ("https://kick.com/somestreamer", "kick"),
])
def test_the_places_a_live_can_come_from(url, source):
    assert _check_source(url) == source


@pytest.mark.parametrize("url", [
    "upload://abc123",                               # un archivo ya subido
    "https://example.com/v.mp4",                     # un sitio cualquiera
    "no-es-una-direccion",
    # Estos sí los entiende el motor, pero ya han terminado: grabarlos no tiene
    # sentido, se clipean de una vez por la vía normal.
    "https://www.twitch.tv/videos/123456789",
    "https://kick.com/canal/videos/abc-123",
])
def test_everything_else_is_refused_with_a_reason(url):
    with pytest.raises(HTTPException) as caught:
        _check_source(url)
    assert caught.value.status_code == 400
    assert "Mandar al iMac" in caught.value.detail


def test_the_chunk_length_stays_within_what_the_mac_can_keep_up_with():
    # Trozos de menos de dos minutos dan al análisis demasiado poco con lo que
    # trabajar, y de más de media hora tardan demasiado en dar el primer clip.
    assert CreateLive(url="https://twitch.tv/x").chunk_minutes == 10
    with pytest.raises(ValueError):
        CreateLive(url="https://twitch.tv/x", chunk_minutes=1)
    with pytest.raises(ValueError):
        CreateLive(url="https://twitch.tv/x", chunk_minutes=60)
