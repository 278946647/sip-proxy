# GFC 版本管理与发布规范（权威）

> **状态：** 现行  
> **兼容策略：** **仅同 Major 内可直升**（`1.x → 1.y` 允许；`1.x → 2.0` 禁止直跳，须走迁移/桥接）  
> **机器可读矩阵（权威）：** [`releases/VERSION_MATRIX.json`](releases/VERSION_MATRIX.json)  
> **人类摘要：** [`releases/VERSION_MATRIX.yaml`](releases/VERSION_MATRIX.yaml)（须与 JSON 同步）  
> **变更记录：** [`releases/CHANGELOG.md`](releases/CHANGELOG.md)  
> **自动化：** [`scripts/version/`](../scripts/version/)（Python 或 PowerShell，无第三方依赖）  
> Cursor 规则：`.cursor/rules/gfc-version-release.mdc`

本文是仓库内**版本与发布的唯一真相**。迭代功能前必须先更新矩阵与路线记号，再写代码。

---

## 0. 一句话结论

| 问题 | 答案 |
|------|------|
| 旧代码会被新提交「覆盖找不到」吗？ | **不会**——Git 历史 + **不可变 annotated tag** 永久保留；禁止改写已发布 tag |
| 靠人肉记版本行吗？ | **不行**——以 `VERSION_MATRIX.json` + tag + 脚本校验为准 |
| 盒子能否任意升到最新？ | **仅同产品 Major 内**；跨 Major 必须先到桥接/迁移版本 |
| 自动化能做什么？ | 校验矩阵、切 tag、生成发行说明骨架、列出可升级路径；运行时门禁见 §8 二期 |

---

## 1. 版本对象（不要混谈）

产品发布以 **GFC 产品版本** 为对外记号；各组件版本钉在矩阵里。

| 对象 | 记号 | 权威落点 | 说明 |
|------|------|----------|------|
| **产品发布** | `vMAJOR.MINOR.PATCH` | Git annotated tag + `VERSION_MATRIX.json` | 运维/销售口头版本；升级路径以此为准 |
| 控制面 API | `cp` 字段 | 矩阵 + 发布说明 | 与 Docker/部署同发；勿只升 web |
| 控制面 Web | 随产品 tag | 与 API **同发** | |
| 节点 Agent | `node_agent` | `gfc-platform/node-agent/node_agent/version.py` | 心跳上报 |
| 客户端运行时 | `gfc-client` = `PKG_VERSION-rPKG_RELEASE` | `gfc-client/deploy/immortalwrt/package/Makefile` | **仅正式发版且含固件变更时** bump `PKG_RELEASE`（见 §1.5） |
| LuCI | `luci-app-gfc ~git` | OpenWrt manifest | **辅证**；≠ `gfc-client` rN |
| 协议契约 | `client_proto` / `node_proto` | 矩阵 + 配置/心跳根字段（演进中） | 决定「能否吃新配置」 |
| 配置内容 | `config_version` | 控制面生成的内容指纹 | **只表示内容变了，不表示契约兼容** |

**禁止**用 LuCI git 哈希单独宣称「盒子已是最新」。

---

## 1.5 何时升版本 / 何时不升（强制门禁）

> **原则：只有「正式发布」才动产品版本号与矩阵；排错、试编、日常修 bug 默认不动版本。**

### 必须升产品版本（`vX.Y.Z` + 矩阵 + CHANGELOG + annotated tag）

同时满足：

1. 用户（或发布负责人）**明确说要发版**（如「发 v1.2.0」「正式发布」）；**不是**「帮我编译一下」「再刷一盘试试」  
2. 变更属于对外可交付能力，且已定级（§2.3）：  
   - **Minor / Major**：新功能、新契约、不兼容变更  
   - **Patch**：已决定合入正式渠道的缺陷修复（含固件关键 bug），且要发给客户/产线  
3. 走完 §4 流程后再 `cut_release`

### 禁止升产品版本（下列情况 AI / 开发者不得擅自 bump）

| 场景 | 做法 |
|------|------|
| 只为验证编译 / 再打一盘镜像 | **不改** `product.current`、不改矩阵、不切新 tag |
| 排错、定位（控制台、依赖、构建脚本） | 可改代码并 commit；**不发**新 `vX.Y.Z` |
| 同一功能未宣布发布前的多次迭代 | 继续用当前开发分支；版本号保持不动 |
| `rebuild-gfc-image.sh` 跑成功 | **不**等于发版；产物可用 git short hash / 日期区分 |
| 文档小改、注释、脚本提示文案 | 不升产品版本 |

### `PKG_RELEASE`（`gfc-client` rN）规则

| 何时 | 规则 |
|------|------|
| **正式发版且本次发布含固件内容变更** | 才允许 `PKG_RELEASE+1`，并与矩阵该行 `gfc_client` 钉扎一致 |
| 仅构建机重编、换盘验证、未宣布发版 | **禁止**为「编过一次」就 +r |
| 仅 Runtime OTA 应用层包、不改 OEM 镜像契约 | 可不碰 `PKG_RELEASE`（按 OTA 制品版本策略） |

**禁止**把「每次 commit / 每次编译」默认绑定一次 `PKG_RELEASE` 或一次产品 Patch。

### 构建产物命名（与发版解耦）

- ImmortalWrt 默认名：`immortalwrt-*-ext4-combined-efi.img.gz`（始终保留）  
- **正式发布包名**（含产品版本）：仅当 `GFC_PUBLISH_RELEASE=1` 时由 rebuild 生成 `gfc-os-v…`  
- **日常试编**：可用 `gfc-build-<git短哈希>-….img.gz`（可选），**不得**冒充新的 `vX.Y.Z`

### AI / 协作默认行为

1. 用户说「编译 / 重编 / 再刷」→ 只改构建与代码，**不**改矩阵、`product.current`、不 `cut_release`  
2. 用户说「发版 / 切 tag / 发布 vX.Y.Z」→ 才走 §4  
3. 排错过程中若曾误开过多 Patch tag，已推送的 tag **禁止改写**；后续合并进下一次正式发布说明即可  

---

## 2. 兼容与升级策略（强制）

### 2.1 同 Major 内直升

```
允许：  v1.1.0 ──► v1.2.0 ──► v1.3.0
禁止：  v1.3.0 ──► v2.0.0   （须先完成 Major 迁移路径）
```

- 同一 `MAJOR` 下，舰队从任意已支持的 `MINOR.PATCH` **可直接**升到该 Major 内更新的目标版本（仍须满足矩阵里的 **最低组件地板**，见 §2.3）。
- 控制面在 Major N 生命周期内，应能管理仍停留在 N 内较旧 Minor 的边缘。

### 2.2 跨 Major（禁止直升）

发布 `v(MAJOR+1).0.0` 时必须同时提供其一：

1. **桥接版本** `vMAJOR.LAST`：能说新旧两套协议，专门用于「先升桥接 → 再升新 Major」；或  
2. **书面迁移手册**：停业务窗口、刷机/重装、验收探针；矩阵中写明 `upgrade_path`。

未写路径的跨 Major 发布 = **违规发布**。

### 2.3 变更分级 → 升级通道

| 级别 | 典型变更 | 版本怎么动 | 升级通道 |
|------|----------|------------|----------|
| **Patch** | bugfix、日志、诊断文案 | `PATCH+1` | 同 Major 直升；Runtime OTA 优先 |
| **Minor** | 新 API 字段（旧端可忽略）、新管理页、非破坏能力 | `MINOR+1`，`PATCH=0` | 同 Major 直升；注意最低地板 |
| **Major** | 删/改配置语义、heartbeat 不兼容、协议升主版本 | `MAJOR+1` | **禁止直升**；桥接或刷机 |
| **Dataplane-Arch** | nft / unbound / sing-box 架构契约 | 至少 **Major**（或单独架构评审版本） | 固件/人工通道；须「确认修改」 |

数据面架构变更：**不得**假装成普通 Runtime OTA Patch。

### 2.4 OTA 基线（Baseline）

- 过旧、无 OTA 客户端的盒子：先 **人工 `install.sh` / 刷含 OTA 的固件** 升到矩阵中的 `ota_baseline`，再走平台 OTA。
- 当前基线见 `VERSION_MATRIX.json` → `product.ota_baseline`。

---

## 3. 旧版本代码如何存放（防「被覆盖找不到」）

### 3.1 正确模型：Git 不可变快照，不是目录拷贝

| 做法 | 是否采用 |
|------|----------|
| 每次发布打 **annotated tag** `vX.Y.Z` 并 push 到 origin | **必须** |
| Major 维护分支 `release/MAJOR.x`（可选，长尾补丁用） | 推荐 |
| GitHub Release 挂发行说明 + 制品校验和 | 推荐 |
| 在仓库里复制整树 `archive/v1.0/` 存旧代码 | **禁止**（必漂、必乱） |
| `git tag -f` / `git push --force` 改写已发布 tag | **禁止** |
| 在已发布 tag 上 `commit --amend` 再强推 | **禁止** |

**找回旧代码（任意机器）：**

```bash
git fetch --tags origin
git checkout v1.1.0          # 只读查看/打补丁请另开 branch
git switch -c hotfix/1.1.1 v1.1.0   # 从旧版拉出补丁分支
```

Tag 指向的 commit **永远在**；`main` 前进不会删除历史（只要不 force-push 抹历史）。

### 3.2 仓库内存放规划

```
docs/
  VERSION_AND_RELEASE.md          # 本规范（权威叙述）
  releases/
    VERSION_MATRIX.json           # 兼容矩阵（机器权威，append-only 历史行）
    VERSION_MATRIX.yaml           # 人类摘要（与 JSON 同步）
    CHANGELOG.md                  # 按产品版本追加
    notes/
      v1.1.0.md                   # 单次发行说明（可自动化生成骨架）
scripts/version/
  check_release.py / .ps1         # 发布前校验
  cut_release.py / .ps1           # 切 tag + 写 notes 骨架
  show_compat.py / .ps1           # 查询「从 A 能否升到 B」
```

**矩阵规则：** 已发布版本的行只允许改「支持状态 / EOL 日期」类元数据，**禁止改写**当时钉死的组件版本号。纠错用新 Patch 版本行。

### 3.3 分支策略（简）

| 分支 | 用途 |
|------|------|
| `main` | 当前 Major 的开发集成 |
| `release/1.x` | （可选）1.x 长尾安全/热修；合并回 main 按需 |
| `release/2.x` | 新 Major 稳定后维护 |
| 功能分支 | `feat/*` / `fix/*`；合入前跑 `check_release.py`（若动了版本文件） |

---

## 4. 每次**正式发版**的强制流程（人 + 脚本）

> 仅适用于 §1.5「必须升产品版本」的场合。日常开发 / 试编 **跳过本节约**。

开发新功能并准备对外发布时：

1. **定级**：Patch / Minor / Major / Dataplane-Arch（§2.3）  
2. **改矩阵**：在 `VERSION_MATRIX.json` 增加或更新目标版本行与 `upgrade_path`（并同步 yaml 摘要）  
3. **改 CHANGELOG**：`docs/releases/CHANGELOG.md` 追加条目  
4. **对齐组件号**：若本版含固件，才 bump `PKG_RELEASE`；`AGENT_VERSION` / 产品 tag 与矩阵一致  
5. **跑校验**：`python scripts/version/check_release.py` 或 `.\scripts\version\check_release.ps1`  
6. **切发布**（代码已合入目标 commit）：`cut_release.py --version 1.2.0` / `cut_release.ps1 -Version 1.2.0`  
7. **部署顺序（默认）**：控制面 api+web → 转发节点 → 客户端（或矩阵声明可并行）  
8. **验收**：矩阵中的 `probes` + 固件 manifest（若涉及镜像）；固件发布包用 `GFC_PUBLISH_RELEASE=1` 生成版本化文件名  

未完成 1–5 就写破坏性协议代码 = **流程违规**。  
未宣布发版却 bump `product.current` / 切 tag = **同样违规**。

---

## 5. 自动化能力边界

### 5.1 已实现（仓库脚本）

| 命令 | 作用 |
|------|------|
| `check_release.py` / `check_release.ps1` | 校验矩阵 JSON、组件钉扎与 CHANGELOG |
| `show_compat.* --from 1.1.0 --to 1.2.0` | 打印是否允许升级及原因 |
| `cut_release.* --version X.Y.Z` | 工作区干净、矩阵含该版本 → 创建 **annotated tag**（默认不 push；禁止覆盖已有 tag） |

### 5.2 二期（控制面运行时门禁，待开发）

- 心跳上报 `agent_version` / `gfc-client` / proto  
- 下发配置前查矩阵：低于地板 → **拒绝业务配置**，仅允许 `runtime_upgrade`  
- UI 展示「需先升级到 vX.Y.Z」  

二期落地前，运维以矩阵 + `show_compat.py` 为人工门禁。

### 5.3 CI 建议（可选）

- PR 若改 `VERSION_MATRIX.json` / `Makefile` `PKG_*` / `version.py` → 必须跑 `check_release`  
- 禁止 job 执行 `git push --force` 到 tag  

---

## 6. 当前基线（2026-08）

以 `VERSION_MATRIX.json` 为准；此处摘要：

| 项 | 值 |
|----|-----|
| 产品当前 | `v2.1.0`（Major **2**） |
| 客户端包 | `gfc-client 2.1.0-r1` |
| OTA 基线 | 1.x 含 Runtime OTA 的客户端（矩阵 `product.ota_baseline`） |
| 节点 Agent | `0.3.1` |
| 跨到 v2 | **已开放路径**：桥接 `v1.1.9` + `docs/releases/notes/v2.0.0.md`（固件/人工，禁止 1.x 直升 2.0.0） |

历史 Git tag `v0.2.0` / `v0.3.0` / `v1.0.0` 仍可 checkout。  
**建议尽快**在干净提交上执行一次 `cut_release` 打上正式 `v1.1.0`（若尚未存在），使矩阵 `git_tag` 与远端一致。

---

## 7. 与数据面 / OTA 文档的关系

| 文档 | 关系 |
|------|------|
| `NFT_*` / `UNBOUND_*` / `SINGBOX_*` | 数据面真相；改前仍须「确认修改」；此类变更按 **Major 或 Dataplane-Arch** |
| `SESSION_HANDOFF_2026-07_OTA_LIFECYCLE.md` | OTA 一期完成态与踩坑；**版本政策以本文为准** |
| `gfc-platform/docs/SETUP_AND_UPGRADE.md` | 部署操作；升级是否允许以矩阵为准 |

---

## 8. 违规处理

- 无矩阵行、无 CHANGELOG 的「口头发版」→ 无效  
- **试编 / 排错就 bump `product.current` 或切新 tag** → 违规（见 §1.5）  
- 改写已发布 tag / 矩阵历史组件钉扎 → **事故**  
- 跨 Major 无 `upgrade_path` 却对客户宣称可升级 → **缺陷**  
- 只升 api 或只升 web → 按 OTA 交接文档视为部署错误  

---

## 9. 新会话开场白（建议）

> 严格按 `docs/VERSION_AND_RELEASE.md` 与 `docs/releases/VERSION_MATRIX.json`。  
> **只有正式发版才升 `vX.Y.Z` / 矩阵 / tag**；试编与排错不升版本。  
> 仅同 Major 内直升；跨 Major 须桥接路径。  
> 发版前跑 `scripts/version/check_release.ps1`（或 .py）；用 tag 保留旧版，禁止改写 tag。
