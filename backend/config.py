"""Runtime settings, read from environment variables. Values are never logged or returned."""
import os
from dataclasses import dataclass

from backend.llm.ollama_client import DEFAULT_BASE_URL, OllamaClient, assert_local_model
from backend.llm.qwen_adapter import QwenAdapter
from backend.llm.translategemma_adapter import TranslateGemmaAdapter

DEFAULT_MODEL = "qwen3.5:9b"
# Allow-list of local models and the adapter that knows how to prompt each. No cloud fallback.
ADAPTERS = {
    "qwen3.5:9b": QwenAdapter,
    "translategemma:12b": TranslateGemmaAdapter,
}
MAX_INPUT_CHARS = 1000
MAX_SPANS = 24
BATCH_MAX_SPANS = 6
BATCH_MAX_CHARS = 150  # total source characters per LLM call (num_predict is fixed at 512)


class ConfigError(ValueError):
    pass


def validate_model(name: str) -> str:
    """Raise ConfigError unless `name` is an allow-listed, non-cloud model."""
    if not isinstance(name, str) or name not in ADAPTERS:
        raise ConfigError(f"model is not allowed; choose one of: {', '.join(sorted(ADAPTERS))}")
    try:
        assert_local_model(name)
    except ValueError as exc:
        raise ConfigError(str(exc)) from None
    return name


def _float_env(name: str, default: float, lo: float, hi: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        value = float(raw)
    except ValueError:
        raise ConfigError(f"{name} must be a number") from None
    if not lo <= value <= hi:
        raise ConfigError(f"{name} must be between {lo} and {hi}")
    return value


@dataclass(frozen=True)
class Settings:
    model: str = DEFAULT_MODEL
    ollama_url: str = DEFAULT_BASE_URL
    call_timeout: float = 120.0      # seconds per Ollama call
    deadline: float = 180.0          # seconds per translation request (checked between batches)
    allow_lan: bool = False
    token: str | None = None
    extra_hosts: tuple[str, ...] = ()

    @classmethod
    def from_env(cls) -> "Settings":
        env = os.environ
        settings = cls(
            model=env.get("MAZEMAZE_MODEL") or DEFAULT_MODEL,
            ollama_url=env.get("OLLAMA_URL") or DEFAULT_BASE_URL,
            call_timeout=_float_env("MAZEMAZE_CALL_TIMEOUT", 120.0, 5.0, 600.0),
            deadline=_float_env("MAZEMAZE_DEADLINE", 180.0, 10.0, 900.0),
            allow_lan=env.get("MAZEMAZE_ALLOW_LAN") == "1",
            token=env.get("MAZEMAZE_TOKEN") or None,
            extra_hosts=tuple(h.strip().lower() for h in
                              (env.get("MAZEMAZE_ALLOWED_HOSTS") or "").split(",") if h.strip()),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        validate_model(self.model)
        try:
            OllamaClient(self.ollama_url)  # rejects non-loopback / credentials / non-http
        except ValueError as exc:
            raise ConfigError(f"OLLAMA_URL: {exc}") from None
