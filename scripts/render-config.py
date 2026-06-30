#!/usr/bin/env python3
import json
import os
import shlex
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_conf(path: Path) -> dict:
    values = {}
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = parse_conf_value(value.strip())
    return values


def parse_conf_value(value: str) -> str:
    try:
        parts = shlex.split(value, comments=False, posix=True)
    except ValueError:
        return value
    if len(parts) == 1:
        return parts[0]
    return value


def load_outbounds(path: Path) -> str:
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    if isinstance(data, dict):
        data = data.get("outbounds", [])
    if not isinstance(data, list):
        raise SystemExit("outbounds.json 必须是 JSON 列表，或包含 outbounds 字段的对象")
    tags = [item["tag"] for item in data if item.get("type") not in {"direct", "block"}]
    if not tags:
        raise SystemExit("outbounds.json has no proxy outbounds")
    generated = [
        {
            "type": "urltest",
            "tag": "auto",
            "outbounds": tags,
            "url": "https://www.gstatic.com/generate_204",
            "interval": "10m",
            "tolerance": 50,
        },
        {"type": "selector", "tag": "proxy", "outbounds": ["auto"] + tags, "default": "auto"},
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
    ] + data
    return ",\n    ".join(json.dumps(item, ensure_ascii=False, indent=4) for item in generated)


def main() -> None:
    conf_path = Path(os.environ.get("ROUTER_CONF", ROOT / "router.conf"))
    outbounds_path = Path(os.environ.get("OUTBOUNDS_JSON", ROOT / "secrets" / "outbounds.json"))
    out_path = Path(os.environ.get("OUTPUT", ROOT / "build" / "config.json"))

    if not conf_path.exists():
        raise SystemExit(f"缺少 {conf_path}；请先创建 router.conf")
    if not outbounds_path.exists():
        raise SystemExit(f"缺少 {outbounds_path}；请先配置订阅或节点")

    values = {
        "LAN_IF": "enp3s0",
        "LAN_NET": "192.168.3.0/24",
        "LAN_IP": "192.168.3.88",
        "PROXY_PORT": "7890",
        "PANEL_PORT": "9091",
        "PANEL_SECRET": "change-me",
        "TUN_NAME": "sbtun0",
        "TUN_ADDRESS": "28.0.0.1/30",
        "DNS1": "223.5.5.5",
        "DNS2": "119.29.29.29",
    }
    values.update(load_conf(conf_path))
    template = (ROOT / "templates" / "sing-box.template.json").read_text(encoding="utf-8")
    values["OUTBOUNDS"] = load_outbounds(outbounds_path)

    for key, value in values.items():
        template = template.replace("{{" + key + "}}", value)

    unresolved = [part.split("}}", 1)[0] for part in template.split("{{")[1:]]
    if unresolved:
        raise SystemExit(f"模板里还有未解析的配置项：{', '.join(sorted(set(unresolved)))}")

    json.loads(template)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(template, encoding="utf-8")
    print(out_path)


if __name__ == "__main__":
    main()
