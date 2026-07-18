# GFC Changelog（产品版本）

按 [`VERSION_AND_RELEASE.md`](../VERSION_AND_RELEASE.md) 追加。每条对应 Git tag `vX.Y.Z`。

格式：

```
## [X.Y.Z] - YYYY-MM-DD

### 级别
Patch | Minor | Major | Dataplane-Arch

### 组件钉扎
- control_plane_api: …
- node_agent: …
- gfc_client: …

### 变更
- …

### 升级
- 同 Major 直升：是/否
- 跨 Major 路径：…
- OTA 基线：…

### 验收探针
- …
```

---

## [1.1.0] - 2026-07-16

### 级别
Minor（相对历史 v1.0.0 tag；本规范起始基线）

### 组件钉扎
- control_plane_api: 0.1.0
- node_agent: 0.3.1
- gfc_client: 1.1.0-r15

### 变更
- 线路/设备生命周期（绑定守卫、软重置、硬退役 reclaim）
- Runtime OTA 一期（制品库、单设备下发、进度轮询）
- VLESS 出口检测（国内直联 + SOCKS/节点双期望）

### 升级
- 同 Major 直升：是（Major 1）
- 跨 Major 路径：无（当前无 v2）
- OTA 基线：本版本；更旧无 OTA 能力的盒子须先人工 install.sh / 刷机

### 验收探针
- 客户端 `GET /api/v1/upgrade/status`
- `POST /api/v1/diagnostics/vless` 含 `expected_ip` / `socks_ip`
- 固件 manifest：`gfc-client - 1.1.0-r15`
