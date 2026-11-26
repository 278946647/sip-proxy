"""AmneziaWG 控制面纯工具：密钥、混淆参数、内层 /32 池与校验和。

本模块只做计算，不访问数据库与网络；持久化、加密存储与审计由调用方负责。
边界见 `2026-11-23/amneziawg-rollout/outputs/amneziawg-dev-constraints.mdc`：
- 每条 awg 线路一个唯一内层 /32；
- 混淆参数整组下发，不允许部分更新；
- 不新增 mark / 路由表，不涉及任何自动切换。
"""
from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
import secrets
from typing import Any, Iterable, Mapping

# 接口与默认值（契约草案，见 docs/PAYLOAD_SCHEMA.md）
AWG_IFACE = "awg0"
AWG_DEFAULT_PORT = 51820
AWG_DEFAULT_MTU = 1408
AWG_MTU_MIN = 1280
AWG_MTU_MAX = 1420
AWG_DEFAULT_MSS_CLAMP = 1360
AWG_DEFAULT_PERSISTENT_KEEPALIVE = 25
AWG_DEFAULT_POOL_CIDR = "10.66.0.0/16"
AWG_DEFAULT_PARAMS_VERSION = 1
# 每个节点在池内保留前 N 个可用地址（网关、预留、人工排障）
AWG_RESERVED_ADDRS_PER_NODE = 16

# 混淆参数范围：契约草案默认值，最终以 awg-quick / kmod 实测为准。
AWG_PARAM_RANGES: dict[str, tuple[int, int]] = {
    "jc": (1, 128),
    "jmin": (0, 1280),
    "jmax": (0, 1280),
    "s1": (0, 1132),
    "s2": (0, 1132),
    "s3": (0, 1132),
    "s4": (0, 1132),
    "h1": (1, 2147483647),
    "h2": (1, 2147483647),
    "h3": (1, 2147483647),
    "h4": (1, 2147483647),
}
AWG_REQUIRED_PARAMS = frozenset(
    {"jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4"}
)
AWG_OPTIONAL_PARAMS = frozenset({"s3", "s4"})


class AwgPoolExhausted(RuntimeError):
    """节点内层 /32 池已无可用地址。"""


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def is_valid_key(value: Any) -> bool:
    """WireGuard / AmneziaWG 密钥为 32 字节原始数据的标准 base64。"""
    if not isinstance(value, str):
        return False
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        return False
    return len(raw) == 32


def validate_key(value: Any, *, field: str = "key") -> str:
    if not is_valid_key(value):
        raise ValueError(f"{field} 必须是 32 字节 base64 字符串")
    return value


def generate_private_key() -> str:
    """生成 X25519 私钥并按 WireGuard 约定做 clamp。"""
    raw = bytearray(secrets.token_bytes(32))
    raw[0] &= 248
    raw[31] &= 127
    raw[31] |= 64
    return _b64(bytes(raw))


def derive_public_key(private_key: str) -> str:
    """由私钥推导公钥；依赖 `cryptography`（控制面既有依赖）。"""
    raw = base64.b64decode(validate_key(private_key, field="private_key"))
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    except ImportError as exc:  # pragma: no cover - 部署环境已安装 cryptography
        raise RuntimeError("需要 cryptography 才能推导 AWG 公钥") from exc
    private = X25519PrivateKey.from_private_bytes(raw)
    public = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return _b64(public)


def generate_keypair() -> tuple[str, str]:
    private_key = generate_private_key()
    return private_key, derive_public_key(private_key)


def generate_preshared_key() -> str:
    return _b64(secrets.token_bytes(32))


def default_obfuscation_params() -> dict[str, int]:
    """与 rollout-plan v1.2 §5.2 示例一致的默认参数组。"""
    return {
        "jc": 4,
        "jmin": 40,
        "jmax": 70,
        "s1": 30,
        "s2": 40,
        "h1": 1,
        "h2": 2,
        "h3": 3,
        "h4": 4,
    }


def generate_obfuscation_params(rng: Any = None) -> dict[str, int]:
    """生成一组合法参数；同一节点内应随 paramsVersion 整组下发。"""
    random = rng or secrets.SystemRandom()
    jc = random.randint(*AWG_PARAM_RANGES["jc"])
    jmin = random.randint(*AWG_PARAM_RANGES["jmin"])
    jmax = random.randint(jmin, AWG_PARAM_RANGES["jmax"][1])
    s1 = random.randint(*AWG_PARAM_RANGES["s1"])
    s2 = random.randint(*AWG_PARAM_RANGES["s2"])
    h = random.sample(range(1, 1 << 31), 4)
    return {
        "jc": jc,
        "jmin": jmin,
        "jmax": jmax,
        "s1": s1,
        "s2": s2,
        "h1": h[0],
        "h2": h[1],
        "h3": h[2],
        "h4": h[3],
    }


def validate_obfuscation_params(params: Any) -> list[str]:
    """返回错误列表；空列表表示可下发。"""
    if not isinstance(params, Mapping):
        return ["obfuscation 必须是对象"]

    errors: list[str] = []
    keys = set(params)
    missing = sorted(AWG_REQUIRED_PARAMS - keys)
    if missing:
        errors.append("缺少参数: " + ", ".join(missing))
    unknown = sorted(keys - AWG_REQUIRED_PARAMS - AWG_OPTIONAL_PARAMS)
    if unknown:
        errors.append("未知参数: " + ", ".join(unknown))

    for name in sorted(AWG_REQUIRED_PARAMS | AWG_OPTIONAL_PARAMS):
        if name not in params:
            continue
        value = params[name]
        if isinstance(value, bool) or not isinstance(value, int):
            errors.append(f"{name} 必须是整数")
            continue
        low, high = AWG_PARAM_RANGES[name]
        if value < low or value > high:
            errors.append(f"{name} 超出范围 {low}..{high}: {value}")

    if not errors:
        if params["jmin"] > params["jmax"]:
            errors.append("jmin 不得大于 jmax")
        h_values = [params[f"h{i}"] for i in range(1, 5)]
        if len(set(h_values)) != 4:
            errors.append("h1..h4 必须互不相同")
    return errors


def awg_checksum(
    *,
    params_version: int,
    obfuscation: Mapping[str, Any],
    server_public_key: str = "",
) -> str:
    """两端一致性校验和：paramsVersion + obfuscation + serverPublicKey。

    返回完整 sha256 十六进制串；参数非法时拒绝计算。
    """
    errors = validate_obfuscation_params(obfuscation)
    if errors:
        raise ValueError("; ".join(errors))
    canonical = {
        "obfuscation": {key: obfuscation[key] for key in sorted(obfuscation)},
        "paramsVersion": int(params_version),
        "serverPublicKey": (server_public_key or "").strip(),
    }
    blob = json.dumps(
        canonical, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def normalize_pool_cidr(pool_cidr: str) -> ipaddress.IPv4Network:
    try:
        network = ipaddress.ip_network(pool_cidr, strict=True)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"非法 AWG 地址池: {pool_cidr}") from exc
    if not isinstance(network, ipaddress.IPv4Network):
        raise ValueError("AWG 地址池目前仅支持 IPv4")
    if network.prefixlen > 30:
        raise ValueError("AWG 地址池至少需要 /30")
    return network


def _as_inner_address(value: Any) -> ipaddress.IPv4Address:
    if isinstance(value, ipaddress.IPv4Interface):
        if value.network.prefixlen != 32:
            raise ValueError(f"内层地址必须是 /32: {value}")
        return value.ip
    if isinstance(value, ipaddress.IPv4Address):
        return value
    text = str(value).strip()
    try:
        if "/" in text:
            interface = ipaddress.ip_interface(text)
            if not isinstance(interface, ipaddress.IPv4Interface):
                raise ValueError("仅支持 IPv4")
            if interface.network.prefixlen != 32:
                raise ValueError(f"内层地址必须是 /32: {text}")
            return interface.ip
        address = ipaddress.ip_address(text)
    except ValueError as exc:
        raise ValueError(f"非法内层地址: {value}") from exc
    if not isinstance(address, ipaddress.IPv4Address):
        raise ValueError("仅支持 IPv4")
    return address


def validate_inner_ip(value: Any) -> str:
    """校验并归一化为 `a.b.c.d/32`；拒绝组播、回环、链路本地与保留地址。"""
    address = _as_inner_address(value)
    if (
        address.is_multicast
        or address.is_unspecified
        or address.is_loopback
        or address.is_link_local
        or address.is_reserved
    ):
        raise ValueError(f"内层地址不可用: {address}")
    return f"{address}/32"


def allocate_inner_ip(
    pool_cidr: str,
    used: Iterable[Any] = (),
    *,
    reserved: int = AWG_RESERVED_ADDRS_PER_NODE,
    server_inner_ip: Any | None = None,
) -> str:
    """从节点池分配一个未占用的 /32。

    - 跳过池内前 `reserved` 个可用地址（含网关/预留位）；
    - `used` 与 `server_inner_ip` 均视为已占用；
    - 池耗尽抛 `AwgPoolExhausted`。
    """
    network = normalize_pool_cidr(pool_cidr)
    taken = {_as_inner_address(item) for item in used}
    if server_inner_ip is not None:
        taken.add(_as_inner_address(server_inner_ip))
    if reserved < 0:
        reserved = 0

    for index, address in enumerate(network.hosts()):
        if index < reserved:
            continue
        if address in taken:
            continue
        return f"{address}/32"
    raise AwgPoolExhausted(f"AWG 地址池已耗尽: {pool_cidr}")


def validate_mtu(value: Any = AWG_DEFAULT_MTU) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("mtu 必须是整数")
    if value < AWG_MTU_MIN or value > AWG_MTU_MAX:
        raise ValueError(f"mtu 超出范围 {AWG_MTU_MIN}..{AWG_MTU_MAX}: {value}")
    return value


def _fernet() -> Any:
    """Derive a stable Fernet key from the platform auth secret."""
    from cryptography.fernet import Fernet

    from .settings import settings

    secret = (getattr(settings, "auth_secret", "") or "").strip() or "gfc-awg-dev"
    key = base64.urlsafe_b64encode(
        hashlib.sha256(f"gfc-awg:{secret}".encode("utf-8")).digest()
    )
    return Fernet(key)


def encrypt_secret(value: str) -> str:
    """Encrypt private key material at rest (`fernet:` prefix)."""
    text = (value or "").strip()
    if not text:
        return ""
    return "fernet:" + _fernet().encrypt(text.encode("utf-8")).decode("ascii")


def decrypt_secret(value: str | None) -> str:
    """Decrypt stored key material; plaintext legacy values pass through."""
    text = (value or "").strip()
    if not text:
        return ""
    if not text.startswith("fernet:"):
        return text
    return _fernet().decrypt(text[len("fernet:"):].encode("ascii")).decode("utf-8")


def default_node_awg_config(pool_cidr: str | None = None) -> dict[str, Any]:
    """Server-side AWG defaults for a node (keys, port, params, pool)."""
    pool = normalize_pool_cidr(pool_cidr or AWG_DEFAULT_POOL_CIDR)
    server_ip = next(pool.hosts())
    host_prefix = 24 if pool.prefixlen <= 24 else pool.prefixlen
    params = default_obfuscation_params()
    private_key, public_key = generate_keypair()
    return {
        "enabled": True,
        "iface": AWG_IFACE,
        "listenPort": AWG_DEFAULT_PORT,
        "serverInnerIp": f"{server_ip}/{host_prefix}",
        "mtu": AWG_DEFAULT_MTU,
        "paramsVersion": AWG_DEFAULT_PARAMS_VERSION,
        "obfuscation": params,
        "serverPrivateKey": private_key,
        "serverPublicKey": public_key,
        "checksum": awg_checksum(
            params_version=AWG_DEFAULT_PARAMS_VERSION,
            obfuscation=params,
            server_public_key=public_key,
        ),
        "poolCidr": str(pool),
    }


def ensure_node_awg_config(
    raw_json: str | None, pool_cidr: str | None = None
) -> dict[str, Any]:
    """Parse persisted node AWG config, filling any missing/invalid pieces."""
    cfg: dict[str, Any] = {}
    if raw_json:
        try:
            parsed = json.loads(raw_json)
            if isinstance(parsed, dict):
                cfg = parsed
        except (json.JSONDecodeError, TypeError):
            cfg = {}

    defaults = default_node_awg_config(pool_cidr or cfg.get("poolCidr"))
    cfg.setdefault("enabled", True)
    cfg.setdefault("iface", AWG_IFACE)
    cfg.setdefault("listenPort", AWG_DEFAULT_PORT)
    cfg.setdefault("mtu", AWG_DEFAULT_MTU)
    cfg.setdefault("paramsVersion", AWG_DEFAULT_PARAMS_VERSION)
    cfg.setdefault("poolCidr", defaults["poolCidr"])
    if not isinstance(cfg.get("obfuscation"), Mapping) or validate_obfuscation_params(
        cfg["obfuscation"]
    ):
        cfg["obfuscation"] = defaults["obfuscation"]
    if not is_valid_key(cfg.get("serverPrivateKey")) or not is_valid_key(
        cfg.get("serverPublicKey")
    ):
        cfg["serverPrivateKey"] = defaults["serverPrivateKey"]
        cfg["serverPublicKey"] = defaults["serverPublicKey"]
    if not str(cfg.get("serverInnerIp") or "").strip():
        cfg["serverInnerIp"] = defaults["serverInnerIp"]
    cfg["checksum"] = awg_checksum(
        params_version=int(cfg["paramsVersion"]),
        obfuscation=cfg["obfuscation"],
        server_public_key=str(cfg["serverPublicKey"]),
    )
    try:
        cfg["mtu"] = validate_mtu(int(cfg["mtu"]))
    except (TypeError, ValueError):
        cfg["mtu"] = AWG_DEFAULT_MTU
    return cfg
