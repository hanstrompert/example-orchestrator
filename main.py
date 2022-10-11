from orchestrator import OrchestratorCore
from orchestrator.cli.main import app as core_cli
from orchestrator.settings import AppSettings

import products  # noqa: F401  Side-effects
import workflows  # noqa: F401  Side-effects
from products.product_types.user import User
from products.product_types.user_group import UserGroup

app = OrchestratorCore(base_settings=AppSettings())
app.register_subscription_models( {
        "User Group": UserGroup,
        "User internal": User,
        "User external": User,
    })

if __name__ == "__main__":
    core_cli()
