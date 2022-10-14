from orchestrator import OrchestratorCore
from orchestrator.cli.main import app as core_cli
from orchestrator.settings import AppSettings, app_settings
from pathlib import Path

import products  # noqa: F401  Side-effects
import workflows  # noqa: F401  Side-effects

app_settings.TRANSLATIONS_DIR = Path(__file__).parent / "translations"

app = OrchestratorCore(base_settings=AppSettings())

if __name__ == "__main__":
    core_cli()
