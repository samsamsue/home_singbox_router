#!/usr/bin/env python3
import json
import sys
from pathlib import Path

import yaml


def tls_config(proxy):
    tls = {"enabled": bool(proxy.get("tls", True))}
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
    return None


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("用法：extract-outbounds.py clash配置.yaml outbounds.json")
    source = Path(sys.argv[1])
    target = Path(sys.argv[2])
    config = yaml.safe_load(source.read_text(encoding="utf-8"))
    outbounds = []
    for proxy in config.get("proxies", []):
        item = convert(proxy)
        if item:
            outbounds.append(item)
    if not outbounds:
        raise SystemExit("没有找到支持的 hysteria2/vless 节点")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(outbounds, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"已写入 {len(outbounds)} 个节点到 {target}")


if __name__ == "__main__":
    main()
