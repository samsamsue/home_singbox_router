#!/usr/bin/env python3
import base64
import json
import sys
from pathlib import Path

import yaml


def tls_config(proxy, default=True):
    tls = {"enabled": bool(proxy.get("tls", default))}
    server_name = proxy.get("servername") or proxy.get("sni")
    if server_name:
        tls["server_name"] = server_name
    if proxy.get("skip-cert-verify") is not None:
        tls["insecure"] = bool(proxy.get("skip-cert-verify"))
    fp = proxy.get("client-fingerprint")
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    reality = proxy.get("reality-opts") or {}
    if reality:
        tls["reality"] = {
            "enabled": True,
            "public_key": reality.get("public-key") or reality.get("public_key", ""),
        }
        sid = reality.get("short-id") or reality.get("short_id")
        if sid:
            tls["reality"]["short_id"] = sid
    return tls


def truthy(value) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "y", "tls"}


def decode_base64_text(value: str) -> str:
    raw = value.strip()
    raw += "=" * (-len(raw) % 4)
    return base64.urlsafe_b64decode(raw.encode()).decode("utf-8", "replace")


def vmess_transport(network: str, opts: dict) -> dict | None:
    network = (network or "tcp").lower()
    if network == "ws":
        transport = {"type": "ws"}
        path = opts.get("path")
        if path:
            transport["path"] = str(path)
        headers = opts.get("headers") or {}
        host = opts.get("host")
        if host and "Host" not in headers:
            headers["Host"] = host
        if headers:
            transport["headers"] = {str(k): str(v) for k, v in headers.items() if v}
        return transport
    if network == "grpc":
        transport = {"type": "grpc"}
        service_name = opts.get("serviceName") or opts.get("service-name") or opts.get("service_name")
        if service_name:
            transport["service_name"] = str(service_name)
        return transport
    if network in {"http", "h2"}:
        transport = {"type": "http"}
        path = opts.get("path")
        if path:
            transport["path"] = str(path)
        host = opts.get("host")
        if host:
            transport["host"] = [str(host)]
        return transport
    return None


def convert_vmess(proxy):
    tag = str(proxy.get("name", "")).strip()
    server = str(proxy.get("server", "")).strip()
    if not tag:
        tag = f"{server}:{proxy.get('port', 443)}"
    outbound = {
        "type": "vmess",
        "tag": tag,
        "server": server,
        "server_port": int(proxy.get("port", 443)),
        "uuid": str(proxy.get("uuid") or proxy.get("id") or ""),
        "security": str(proxy.get("cipher") or proxy.get("security") or proxy.get("scy") or "auto"),
        "alter_id": int(proxy.get("alterId") or proxy.get("alter-id") or proxy.get("aid") or 0),
    }
    if proxy.get("udp") is True:
        outbound["network"] = "udp"

    tls = tls_config(proxy, default=False)
    if tls["enabled"]:
        outbound["tls"] = tls

    network = str(proxy.get("network") or proxy.get("net") or "tcp").lower()
    opts = {}
    if network == "ws":
        ws = proxy.get("ws-opts") or {}
        opts["path"] = ws.get("path") or proxy.get("path")
        opts["headers"] = ws.get("headers") or {}
        opts["host"] = proxy.get("host")
    elif network == "grpc":
        opts.update(proxy.get("grpc-opts") or {})
    elif network in {"http", "h2"}:
        h2 = proxy.get("h2-opts") or {}
        opts["path"] = h2.get("path") or proxy.get("path")
        hosts = h2.get("host") or proxy.get("host")
        if isinstance(hosts, list):
            opts["host"] = hosts[0] if hosts else ""
        else:
            opts["host"] = hosts
    transport = vmess_transport(network, opts)
    if transport:
        outbound["transport"] = transport
    return outbound


def convert(proxy):
    typ = str(proxy.get("type", "")).lower()
    tag = str(proxy.get("name", "")).strip()
    if typ in {"hysteria2", "hy2"}:
        return {
            "type": "hysteria2",
            "tag": tag,
            "server": str(proxy["server"]),
            "server_port": int(proxy.get("port", 443)),
            "password": str(proxy.get("password", "")),
            "tls": tls_config(proxy),
        }
    if typ == "vless":
        outbound = {
            "type": "vless",
            "tag": tag,
            "server": str(proxy["server"]),
            "server_port": int(proxy.get("port", 443)),
            "uuid": str(proxy.get("uuid", "")),
            "tls": tls_config(proxy),
        }
        if proxy.get("flow"):
            outbound["flow"] = proxy["flow"]
        if proxy.get("network") == "ws":
            ws = proxy.get("ws-opts") or {}
            transport = {"type": "ws"}
            if ws.get("path"):
                transport["path"] = ws["path"]
            if ws.get("headers"):
                transport["headers"] = {str(k): str(v) for k, v in ws["headers"].items()}
            outbound["transport"] = transport
        return outbound
    if typ == "vmess":
        return convert_vmess(proxy)
    return None


def vmess_link_to_proxy(link: str) -> dict:
    body = link.strip()[len("vmess://") :]
    data = json.loads(decode_base64_text(body))
    proxy = {
        "type": "vmess",
        "name": data.get("ps") or data.get("remark") or data.get("add") or "vmess",
        "server": data.get("add"),
        "port": data.get("port") or 443,
        "uuid": data.get("id"),
        "alterId": data.get("aid") or 0,
        "security": data.get("scy") or data.get("security") or "auto",
        "network": data.get("net") or "tcp",
        "tls": str(data.get("tls", "")).lower() == "tls",
        "servername": data.get("sni") or data.get("servername") or "",
        "skip-cert-verify": truthy(data.get("allowInsecure", False)),
        "path": data.get("path") or "",
        "host": data.get("host") or "",
    }
    alpn = data.get("alpn")
    if alpn:
        proxy["alpn"] = alpn
    return proxy


def parse_link_line(line: str) -> dict | None:
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    if line.startswith("vmess://"):
        return convert(vmess_link_to_proxy(line))
    return None


def maybe_decode_subscription(text: str) -> str:
    compact = "".join(text.strip().split())
    if not compact or "://" in text or "proxies:" in text:
        return text
    try:
        decoded = decode_base64_text(compact)
    except Exception:
        return text
    if "://" in decoded or "proxies:" in decoded:
        return decoded
    return text


def extract_from_yaml(text: str) -> list[dict]:
    config = yaml.safe_load(text)
    if not isinstance(config, dict):
        return []
    outbounds = []
    for proxy in config.get("proxies", []) or []:
        if not isinstance(proxy, dict):
            continue
        item = convert(proxy)
        if item:
            outbounds.append(item)
    return outbounds


def extract_from_text(text: str) -> list[dict]:
    text = maybe_decode_subscription(text)
    outbounds = []
    for line in text.splitlines():
        item = parse_link_line(line)
        if item:
            outbounds.append(item)
    if outbounds:
        return outbounds
    try:
        return extract_from_yaml(text)
    except Exception:
        return []


def unique_tags(outbounds: list[dict]) -> list[dict]:
    used = {}
    result = []
    for outbound in outbounds:
        tag = str(outbound.get("tag") or outbound.get("server") or outbound.get("type")).strip()
        base = tag
        if base in used:
            used[base] += 1
            tag = f"{base} #{used[base]}"
        else:
            used[base] = 1
        outbound["tag"] = tag
        result.append(outbound)
    return result


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("用法：extract-outbounds.py 订阅文件... outbounds.json")
    sources = []
    for item in sys.argv[1:-1]:
        path = Path(item)
        if path.is_dir():
            sources.extend(sorted(child for child in path.iterdir() if child.is_file()))
        else:
            sources.append(path)
    target = Path(sys.argv[-1])
    outbounds = []
    for source in sources:
        outbounds.extend(extract_from_text(source.read_text(encoding="utf-8-sig")))
    outbounds = unique_tags(outbounds)
    if not outbounds:
        raise SystemExit("没有找到支持的 hysteria2/vless/vmess 节点")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(outbounds, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"已写入 {len(outbounds)} 个节点到 {target}")


if __name__ == "__main__":
    main()
