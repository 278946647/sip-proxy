# 旁路模式开发计划（已冻结）

> **本文不再作为权威。** 产品与数据面契约见 [`BYPASS_MODE.md`](BYPASS_MODE.md)。  
> nft / DNS / sing-box 仍以 `docs/*_ARCHITECTURE.md` 为准。

P0–P3 与公网 `customer_hosts` DNS 回程已实现并联调。后续缺口（不在本文展开）：平台 API 拒绝写入 `proxy_mode`、OEM 默认 LAN 是否改段（当前 **不改**）、固件 Dataplane-Arch 发版。
