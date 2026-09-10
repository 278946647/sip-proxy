# 旁路模式开发计划（已冻结）

> **本文不再作为权威。** 产品与数据面契约见 [`BYPASS_MODE.md`](BYPASS_MODE.md)。  
> nft / DNS / sing-box 仍以 `docs/*_ARCHITECTURE.md` 为准。

P0–P3 与公网 `customer_hosts` DNS 回程已实现并联调。后续缺口（不在本文展开）：平台 API 拒绝写入 `proxy_mode`、固件 Dataplane-Arch 发版。OEM 出厂 LAN 已定为 `192.168.68.0/24`（见 `BYPASS_MODE.md` §2 #11）。
