"""Configuration loading for Pomvox.

Reads ``~/.pomvox/config.toml`` with stdlib :mod:`tomllib`. Every key has a
default, so the file is optional. A malformed file logs an error and falls
back to defaults — config loading must never crash the app.
"""

from __future__ import annotations

import dataclasses
import logging
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger(__name__)

CONFIG_DIR = Path.home() / ".pomvox"
CONFIG_PATH = CONFIG_DIR / "config.toml"

_SECTIONS = (
    "hotkey", "stt", "cleanup", "insert", "log", "hud", "vad", "history",
    "audio", "engine", "dictionary"
)


@dataclass(frozen=True)
class HotkeyConfig:
    ptt: str = "fn"
    toggle: str = "fn+space"
    stop: str = ""  # optional extra stop key; fn tap / fn+space always stop
    cancel: str = "esc"  # discard the utterance; "" disables


@dataclass(frozen=True)
class SttConfig:
    model: str = "mlx-community/parakeet-tdt-0.6b-v2"


@dataclass(frozen=True)
class CleanupConfig:
    enabled: bool = True
    model: str = "mlx-community/Qwen3-4B-4bit"
    style: str = "polish"  # "light" or "polish"
    timeout_s: float = 5.0  # hard deadline; on timeout the raw transcript inserts

    def __post_init__(self) -> None:
        if self.style not in ("light", "polish"):
            raise ValueError(f"style must be 'light' or 'polish', got {self.style!r}")
        if self.timeout_s <= 0:
            raise ValueError("timeout_s must be positive")


@dataclass(frozen=True)
class InsertConfig:
    method: str = "paste"


@dataclass(frozen=True)
class LogConfig:
    file: bool = True


@dataclass(frozen=True)
class HudConfig:
    enabled: bool = True
    show_draft: bool = True  # off keeps live text out of screen-share view
    position: str = "bottom-center"  # or "top-center" / "notch"
    max_chars: int = 120
    sounds: bool = True

    def __post_init__(self) -> None:
        if self.position not in ("bottom-center", "top-center", "notch"):
            raise ValueError(
                f"position must be 'bottom-center', 'top-center', or 'notch', "
                f"got {self.position!r}"
            )
        if self.max_chars <= 0:
            raise ValueError("max_chars must be positive")


@dataclass(frozen=True)
class VadConfig:
    enabled: bool = True  # hands-free auto-stop on a natural pause
    aggressiveness: int = 2  # webrtcvad mode 0–3
    silence_ms: int = 2000  # pause length that ends the utterance
    min_speech_ms: int = 250  # debounce before "speech started"
    energy_gate_dbfs: float = -45.0  # AND-gate: kills breath/keyboard votes
    max_session_s: float = 600.0  # forgotten-open-mic hard stop

    def __post_init__(self) -> None:
        if not 0 <= self.aggressiveness <= 3:
            raise ValueError(f"aggressiveness must be 0–3, got {self.aggressiveness}")
        if self.silence_ms <= 0 or self.min_speech_ms <= 0:
            raise ValueError("silence_ms and min_speech_ms must be positive")
        if self.max_session_s <= 0:
            raise ValueError("max_session_s must be positive")


@dataclass(frozen=True)
class AudioConfig:
    # Input device, by name (sounddevice/PortAudio name). Empty = system
    # default. Wrong-mic is the #1 "it doesn't work" cause, so the Hub
    # surfaces a picker; a name that no longer resolves falls back to the
    # default with a warning (audio.py). Restart-required: the InputStream is
    # built once at startup.
    device: str = ""


@dataclass(frozen=True)
class HistoryConfig:
    enabled: bool = True  # transcripts only — audio is never stored
    retention_days: int = 7  # auto-delete window; 0 = keep nothing

    def __post_init__(self) -> None:
        if self.retention_days < 0:
            raise ValueError("retention_days must be >= 0")


@dataclass(frozen=True)
class EngineConfig:
    # The native Swift engine (Pomvox.app) is on by default and owned by the
    # Hub, which reads/writes `[engine] native`. The Python engine ignores this
    # key entirely — it lives here only so config.toml round-trips cleanly (no
    # "unknown section" warning). Mutual exclusion is enforced at runtime by the
    # pidfile (pidfile.py), not by this flag.
    native: bool = True


@dataclass(frozen=True)
class DictionaryConfig:
    # Custom words injected into the cleanup prompt so the LLM spells proper
    # nouns / jargon the user's way, plus literal misheard→correct
    # replacements applied to the final text (even when cleanup is off or
    # times out). See dictionary.py. Changing `words` is restart-required
    # (it's baked into the cached prompt prefix); `replacements` hot-applies.
    enabled: bool = True
    words: list = field(default_factory=list)
    replacements: dict = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not isinstance(self.words, list) or not all(
            isinstance(w, str) for w in self.words
        ):
            raise ValueError("words must be a list of strings")
        if not isinstance(self.replacements, dict) or not all(
            isinstance(k, str) and isinstance(v, str)
            for k, v in self.replacements.items()
        ):
            raise ValueError("replacements must be a table of string = string")


@dataclass(frozen=True)
class Config:
    hotkey: HotkeyConfig = field(default_factory=HotkeyConfig)
    stt: SttConfig = field(default_factory=SttConfig)
    cleanup: CleanupConfig = field(default_factory=CleanupConfig)
    insert: InsertConfig = field(default_factory=InsertConfig)
    log: LogConfig = field(default_factory=LogConfig)
    hud: HudConfig = field(default_factory=HudConfig)
    vad: VadConfig = field(default_factory=VadConfig)
    history: HistoryConfig = field(default_factory=HistoryConfig)
    audio: AudioConfig = field(default_factory=AudioConfig)
    engine: EngineConfig = field(default_factory=EngineConfig)
    dictionary: DictionaryConfig = field(default_factory=DictionaryConfig)


def _load_section(cls: type, data: dict, name: str):
    raw = data.get(name, {})
    if not isinstance(raw, dict):
        log.warning("config: [%s] is not a table, using defaults", name)
        return cls()
    known = {f.name for f in dataclasses.fields(cls)}
    kwargs = {}
    for key, value in raw.items():
        if key not in known:
            log.warning("config: unknown key %r in [%s], ignoring", key, name)
            continue
        kwargs[key] = value
    try:
        return cls(**kwargs)
    except (TypeError, ValueError) as exc:
        log.error("config: bad [%s] section (%s), using defaults", name, exc)
        return cls()


def restart_required(old: Config, new: Config) -> list[str]:
    """Config changes the menu-bar Reload can't hot-apply, sorted.

    Models load once on worker threads at startup; the hotkey machine and
    event tap are built before the run loop. Everything else hot-applies.
    """
    out = []
    if old.hotkey != new.hotkey:
        out.append("hotkey")
    if old.stt.model != new.stt.model:
        out.append("stt.model")
    if old.cleanup.model != new.cleanup.model:
        out.append("cleanup.model")
    if old.audio.device != new.audio.device:
        out.append("audio.device")
    if old.log != new.log:
        out.append("log")
    # `words` is baked into the cached cleanup prompt prefix at startup, so a
    # change only takes effect on restart; `replacements` (a post-step) and the
    # enabled flag for it hot-apply, so they're deliberately not flagged here.
    old_terms = old.dictionary.words if old.dictionary.enabled else []
    new_terms = new.dictionary.words if new.dictionary.enabled else []
    if old_terms != new_terms:
        out.append("dictionary.words")
    return out


def load(path: Path | None = None) -> Config:
    """Load config from *path* (default ``~/.pomvox/config.toml``)."""
    path = CONFIG_PATH if path is None else path
    if not path.exists():
        log.info("config: %s not found, using defaults", path)
        return Config()
    try:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        log.error("config: failed to read %s (%s), using defaults", path, exc)
        return Config()
    for name in data:
        if name not in _SECTIONS:
            log.warning("config: unknown section [%s], ignoring", name)
    return Config(
        hotkey=_load_section(HotkeyConfig, data, "hotkey"),
        stt=_load_section(SttConfig, data, "stt"),
        cleanup=_load_section(CleanupConfig, data, "cleanup"),
        insert=_load_section(InsertConfig, data, "insert"),
        log=_load_section(LogConfig, data, "log"),
        hud=_load_section(HudConfig, data, "hud"),
        vad=_load_section(VadConfig, data, "vad"),
        history=_load_section(HistoryConfig, data, "history"),
        audio=_load_section(AudioConfig, data, "audio"),
        engine=_load_section(EngineConfig, data, "engine"),
        dictionary=_load_section(DictionaryConfig, data, "dictionary"),
    )
