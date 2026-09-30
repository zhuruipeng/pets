"""pytest 配置。

把 `server/` 加进 sys.path，这样测试可以直接 `import app.sync_logic`，
而不必要求从某个特定目录运行 pytest、也不必给 app 包补 __init__.py
（现有服务端用的是命名空间包，加 __init__.py 会改变导入行为）。
"""

import sys
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parents[1]
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))
