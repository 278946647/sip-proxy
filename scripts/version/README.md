# Version automation

权威说明：[`docs/VERSION_AND_RELEASE.md`](../../docs/VERSION_AND_RELEASE.md)  
机器矩阵：[`docs/releases/VERSION_MATRIX.json`](../../docs/releases/VERSION_MATRIX.json)

## Windows（本仓库推荐）

```powershell
.\scripts\version\check_release.ps1
.\scripts\version\show_compat.ps1 -From 1.1.0 -To 1.2.0
.\scripts\version\show_compat.ps1 -From 1.1.0 -To 2.0.0
.\scripts\version\cut_release.ps1 -Version 1.1.0 -DryRun
```

## Linux / CI（有 Python3）

```bash
python3 scripts/version/check_release.py
python3 scripts/version/show_compat.py --from 1.1.0 --to 1.2.0
python3 scripts/version/cut_release.py --version 1.2.0 --dry-run
```

无第三方依赖（标准库 JSON）。**禁止**对已发布 tag 执行 `git tag -f` / force-push。
