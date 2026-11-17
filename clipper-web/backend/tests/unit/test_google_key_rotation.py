"""A Gemini key that runs out of quota hands over to the next one."""

import pytest
from pydantic_ai.exceptions import ModelHTTPError

from src import ai
from src.config import Config, get_config, reset_google_api_key_rotation, rotate_google_api_key


@pytest.fixture(autouse=True)
def _fresh_rotation():
    reset_google_api_key_rotation()
    yield
    reset_google_api_key_rotation()


def _quota_error():
    return ModelHTTPError(status_code=429, model_name="gemini", body="RESOURCE_EXHAUSTED: quota")


def _busy_error():
    return ModelHTTPError(status_code=429, model_name="gemini", body="The model is overloaded")


def test_the_pool_reads_both_spellings_and_keeps_the_order(monkeypatch):
    monkeypatch.setenv("GOOGLE_API_KEY", " first , second ")
    monkeypatch.setenv("GOOGLE_API_KEY_2", "third")
    monkeypatch.setenv("GOOGLE_API_KEY_4", "first")  # already in the pool
    assert Config._google_api_key_pool() == ["first", "second", "third"]
    assert get_config().google_api_key == "first"


def test_rotation_stops_at_the_last_key(monkeypatch):
    monkeypatch.setenv("GOOGLE_API_KEY", "one,two")
    assert rotate_google_api_key("one") is True
    assert get_config().google_api_key == "two"
    assert rotate_google_api_key("two") is False


def test_one_key_alone_never_rotates(monkeypatch):
    monkeypatch.setenv("GOOGLE_API_KEY", "only")
    monkeypatch.delenv("GOOGLE_API_KEY_2", raising=False)
    assert rotate_google_api_key("only") is False


def test_a_window_that_already_lost_the_race_does_not_skip_a_key(monkeypatch):
    # Windows run concurrently: the second one to report the same dead key must
    # take the key the first one moved to, not the one after it.
    monkeypatch.setenv("GOOGLE_API_KEY", "one,two,three")
    assert rotate_google_api_key("one") is True
    assert rotate_google_api_key("one") is True
    assert get_config().google_api_key == "two"


def test_only_an_exhausted_key_counts_as_exhausted():
    assert ai._is_quota_exhausted_error(_quota_error()) is True
    assert ai._is_quota_exhausted_error(_busy_error()) is False


@pytest.mark.asyncio
async def test_a_spent_key_hands_the_call_to_the_next_one(monkeypatch):
    monkeypatch.setenv("GOOGLE_API_KEY", "one,two")
    used = []

    class Fake:
        def __init__(self, key):
            self.key = key

        async def run(self, _prompt):
            used.append(self.key)
            if self.key == "one":
                raise _quota_error()
            return type("Result", (), {"output": "done"})()

    result = await ai._run_transcript_analysis(
        Fake("one"), "prompt", timeout_seconds=30,
        rebuild=lambda: Fake(get_config().google_api_key),
    )
    assert used == ["one", "two"]
    assert result.output == "done"


@pytest.mark.asyncio
async def test_a_busy_provider_is_not_mistaken_for_a_spent_key(monkeypatch):
    # Overload is retried on the same key, so a free key is never thrown away.
    monkeypatch.setenv("GOOGLE_API_KEY", "one,two")
    monkeypatch.setattr(ai.asyncio, "sleep", lambda _seconds: _noop())
    used = []

    async def _noop():
        return None

    class Fake:
        async def run(self, _prompt):
            used.append(get_config().google_api_key)
            if len(used) == 1:
                raise _busy_error()
            return type("Result", (), {"output": "done"})()

    agent = Fake()
    result = await ai._run_transcript_analysis(
        agent, "prompt", timeout_seconds=30, rebuild=lambda: agent
    )
    assert used == ["one", "one"]
    assert result.output == "done"
