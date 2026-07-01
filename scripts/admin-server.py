#!/usr/bin/env python3
import json
import os
import re
import selectors
import shlex
import signal
import subprocess
import time
import ipaddress
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


CONF = Path(os.environ.get("ROUTER_CONF", "/etc/bypassproxy/router.conf"))
APP_DIR = Path(os.environ.get("APP_DIR", "/opt/bypassproxy"))
SUBSCRIPTION_DIR = Path(os.environ.get("SUBSCRIPTION_DIR", "/etc/bypassproxy/subscriptions.d"))
OUTBOUNDS_JSON = Path(os.environ.get("OUTBOUNDS_JSON", "/etc/bypassproxy/outbounds.json"))
SING_BOX_CONFIG = Path(os.environ.get("SING_BOX_CONFIG", "/etc/sing-box/config.json"))
STATIC_DIR = Path(os.environ.get("ADMIN_UI_DIR", "/usr/local/share/bypassproxy-admin"))


def parse_conf_value(value: str) -> str:
    try:
        parts = shlex.split(value, comments=False, posix=True)
    except ValueError:
        return value
    if len(parts) == 1:
        return parts[0]
    return value


def read_conf() -> dict[str, str]:
    values = {}
    if CONF.exists():
        for raw in CONF.read_text(encoding="utf-8-sig").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = parse_conf_value(value.strip())
    defaults = {
        "LAN_IP": "192.168.3.88",
        "PROXY_PORT": "7890",
        "PANEL_PORT": "9091",
        "PANEL_SECRET": "abc123",
        "ADMIN_PORT": "8088",
    }
    defaults.update(values)
    return defaults


def quote_value(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def save_conf_key(key: str, value: str) -> None:
    CONF.parent.mkdir(parents=True, exist_ok=True)
    lines = CONF.read_text(encoding="utf-8-sig").splitlines() if CONF.exists() else []
    new_line = f"{key}={quote_value(value)}"
    written = False
    result = []
    for line in lines:
        if line.startswith(f"{key}="):
            result.append(new_line)
            written = True
        else:
            result.append(line)
    if not written:
        result.append(new_line)
    CONF.write_text("\n".join(result) + "\n", encoding="utf-8")
    try:
        CONF.chmod(0o600)
    except OSError:
        pass


def cidr_to_network(cidr: str) -> str:
    try:
        return str(ipaddress.ip_interface(cidr).network)
    except ValueError:
        return ""


def is_virtual_or_tunnel_interface(name: str) -> bool:
    prefixes = (
        "br-",
        "docker",
        "dummy",
        "ip6tnl",
        "lo",
        "sit",
        "sbtun",
        "tailscale",
        "tun",
        "veth",
        "virbr",
        "wg",
        "zt",
    )
    return name == "lo" or name.startswith(prefixes)


def list_network_interfaces() -> list[dict[str, str]]:
    result = run_command(["ip", "-4", "-o", "addr", "show"], timeout=8)
    if not result["ok"]:
        return []
    items: list[dict[str, str]] = []
    seen: set[str] = set()
    for line in result["stdout"].splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        name = parts[1]
        cidr = parts[3]
        if is_virtual_or_tunnel_interface(name):
            continue
        address = cidr.split("/", 1)[0]
        network = cidr_to_network(cidr)
        key = f"{name}:{cidr}"
        if key in seen:
            continue
        seen.add(key)
        items.append({"name": name, "address": address, "cidr": cidr, "network": network})
    return items


def detect_lan_settings(preferred_if: str = "") -> dict[str, str]:
    interfaces = list_network_interfaces()
    chosen = None
    if preferred_if:
        chosen = next((item for item in interfaces if item["name"] == preferred_if), None)
    if chosen is None:
        route = run_command(["ip", "route", "show", "default"], timeout=8)
        default_if = ""
        if route["ok"]:
            match = re.search(r"\bdev\s+(\S+)", route["stdout"])
            if match:
                default_if = match.group(1)
        if default_if:
            chosen = next((item for item in interfaces if item["name"] == default_if), None)
    if chosen is None and interfaces:
        chosen = interfaces[0]
    return {
        "LAN_IF": chosen["name"] if chosen else "",
        "LAN_IP": chosen["address"] if chosen else "",
        "LAN_NET": chosen["network"] if chosen else "",
    }


def run_command(args: list[str], timeout: int = 120, env: dict[str, str] | None = None) -> dict:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    try:
        completed = subprocess.run(
            args,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            env=merged_env,
        )
        return {
            "ok": completed.returncode == 0,
            "code": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
            "output": (completed.stdout + completed.stderr).strip(),
        }
    except FileNotFoundError as exc:
        return {"ok": False, "code": 127, "stdout": "", "stderr": str(exc), "output": str(exc)}
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        return {"ok": False, "code": 124, "stdout": stdout, "stderr": stderr, "output": f"{stdout}{stderr}\n命令超时".strip()}


def action_steps(action: str, data: dict) -> list[tuple[str, list[str], int, dict[str, str] | None]]:
    router_env = {"ROUTER_CONF": str(CONF)}
    if action == "update-subscription":
        sub_env = dict(router_env)
        if data.get("direct"):
            sub_env["BYPASSPROXY_DIRECT_DOWNLOAD"] = "1"
        return [
            ("更新订阅", ["/usr/local/sbin/bypassproxy-update-subscription.sh"], 240, sub_env),
            ("生成配置", ["python3", str(APP_DIR / "scripts/render-config.py")], 60, {"ROUTER_CONF": str(CONF), "OUTBOUNDS_JSON": str(OUTBOUNDS_JSON), "OUTPUT": str(SING_BOX_CONFIG)}),
            ("检查配置", ["sing-box", "check", "-C", "/etc/sing-box"], 60, None),
            ("重启 sing-box", ["systemctl", "restart", "sing-box"], 40, None),
        ]
    if action == "apply-config":
        return [
            ("生成配置", ["python3", str(APP_DIR / "scripts/render-config.py")], 60, {"ROUTER_CONF": str(CONF), "OUTBOUNDS_JSON": str(OUTBOUNDS_JSON), "OUTPUT": str(SING_BOX_CONFIG)}),
            ("检查配置", ["sing-box", "check", "-C", "/etc/sing-box"], 60, None),
            ("重启 sing-box", ["systemctl", "restart", "sing-box"], 40, None),
        ]
    if action == "check-config":
        return [("检查配置", ["sing-box", "check", "-C", "/etc/sing-box"], 60, None)]
    if action == "restart-sing-box":
        return [("重启 sing-box", ["systemctl", "restart", "sing-box"], 40, None)]
    if action == "update-rulesets":
        return [("更新国内分流规则", ["/usr/local/sbin/bypassproxy-update-rulesets.sh"], 180, router_env)]
    if action == "update-webui":
        return [("更新节点面板", ["/usr/local/sbin/bypassproxy-update-webui.sh"], 240, router_env)]
    if action == "update-core":
        return [("更新 BypassProxy 脚本", ["/usr/local/sbin/bypassproxy-update-core.sh"], 360, router_env)]
    if action == "diagnose-network":
        return [("网络诊断", ["/usr/local/sbin/bypassproxy-diagnose-network.sh"], 180, router_env)]
    if action == "repair":
        return [("一键修复", ["/usr/local/sbin/bypassproxy-repair.sh"], 300, router_env)]
    if action == "apply-forwarding":
        return [("应用转发/NAT", ["/usr/local/sbin/bypassproxy-forward.sh"], 60, router_env)]
    raise ValueError("接口不存在")


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name != "nt" and hasattr(os, "killpg"):
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
        process.wait(timeout=5)
    except Exception:
        try:
            if os.name != "nt" and hasattr(os, "killpg"):
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except Exception:
            pass


def systemctl_is_active(name: str) -> str:
    result = run_command(["systemctl", "is-active", name], timeout=8)
    if result["code"] == 127:
        return "unknown"
    return (result["stdout"] or result["stderr"]).strip() or "unknown"


def detect_zt_ip() -> str:
    result = run_command(["ip", "-4", "-o", "addr", "show"], timeout=8)
    if not result["ok"]:
        return ""
    for line in result["stdout"].splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[1].startswith("zt"):
            return parts[3].split("/", 1)[0]
    return ""


def load_subscription(path: Path) -> dict[str, str]:
    values = {"NAME": path.stem, "URL": "", "ENABLED": "1"}
    if path.exists():
        for raw in path.read_text(encoding="utf-8-sig").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = parse_conf_value(value.strip())
    return {
        "id": path.stem,
        "name": values.get("NAME") or path.stem,
        "url": values.get("URL") or "",
        "enabled": values.get("ENABLED", "1") != "0",
    }


def list_subscriptions() -> list[dict]:
    SUBSCRIPTION_DIR.mkdir(parents=True, exist_ok=True)
    return [load_subscription(path) for path in sorted(SUBSCRIPTION_DIR.glob("*.conf"))]


def next_subscription_id() -> str:
    current = []
    for item in SUBSCRIPTION_DIR.glob("*.conf"):
        if re.fullmatch(r"\d{3}", item.stem):
            current.append(int(item.stem))
    return f"{(max(current) if current else 0) + 1:03d}"


def subscription_path(sub_id: str) -> Path:
    if not re.fullmatch(r"\d{1,3}", sub_id):
        raise ValueError("订阅编号无效")
    return SUBSCRIPTION_DIR / f"{int(sub_id):03d}.conf"


def write_subscription(path: Path, name: str, url: str, enabled: bool) -> None:
    SUBSCRIPTION_DIR.mkdir(parents=True, exist_ok=True)
    content = "\n".join(
        [
            f"NAME={quote_value(name)}",
            f"URL={quote_value(url)}",
            f"ENABLED={quote_value('1' if enabled else '0')}",
            "",
        ]
    )
    path.write_text(content, encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass


def node_count() -> int:
    if not OUTBOUNDS_JSON.exists():
        return 0
    try:
        data = json.loads(OUTBOUNDS_JSON.read_text(encoding="utf-8-sig"))
    except Exception:
        return 0
    if isinstance(data, dict):
        data = data.get("outbounds", [])
    if not isinstance(data, list):
        return 0
    return len([item for item in data if isinstance(item, dict) and item.get("type") not in {"direct", "block"}])


def public_status() -> dict:
    conf = read_conf()
    lan_ip = conf.get("LAN_IP", "192.168.3.88")
    panel_port = conf.get("PANEL_PORT", "9091")
    proxy_port = conf.get("PROXY_PORT", "7890")
    admin_port = conf.get("ADMIN_PORT", "8088")
    zt_ip = detect_zt_ip()
    admin_active = systemctl_is_active("bypassproxy-admin")
    return {
        "services": {
            "singBox": systemctl_is_active("sing-box"),
            "forwardTimer": systemctl_is_active("bypassproxy-forward.timer"),
            "admin": admin_active,
        },
        "addresses": {
            "admin": f"http://{lan_ip}:{admin_port}/",
            "adminZeroTier": f"http://{zt_ip}:{admin_port}/" if zt_ip else "",
            "panel": f"http://{lan_ip}:{panel_port}/ui/",
            "proxy": f"http://{lan_ip}:{proxy_port}",
        },
        "ports": {"admin": admin_port, "panel": panel_port, "proxy": proxy_port},
        "nodeCount": node_count(),
        "subscriptionCount": len(list_subscriptions()),
    }


def api_auth_ok(headers) -> bool:
    secret = read_conf().get("PANEL_SECRET", "abc123")
    if not secret:
        return True
    auth = headers.get("Authorization", "")
    return auth == f"Bearer {secret}"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

    def log_message(self, fmt, *args):
        return

    def send_json(self, data, status=HTTPStatus.OK):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length).decode("utf-8")
        try:
            return json.loads(raw or "{}")
        except json.JSONDecodeError as exc:
            raise ValueError("JSON 格式不正确") from exc

    def require_auth(self) -> bool:
        if api_auth_ok(self.headers):
            return True
        self.send_json({"ok": False, "error": "未登录或密钥不正确"}, HTTPStatus.UNAUTHORIZED)
        return False

    def write_stream(self, text: str) -> bool:
        try:
            self.wfile.write(text.encode("utf-8", errors="replace"))
            self.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError):
            return False

    def stream_step(self, title: str, args: list[str], timeout: int, env: dict[str, str] | None) -> int:
        if not self.write_stream(f"\n== {title} ==\n$ {' '.join(shlex.quote(item) for item in args)}\n"):
            return 499
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)
        try:
            process = subprocess.Popen(
                args,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=merged_env,
                bufsize=0,
                start_new_session=(os.name != "nt"),
            )
        except FileNotFoundError as exc:
            self.write_stream(f"{exc}\nFAILED code=127\n")
            return 127

        assert process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        started = time.monotonic()
        timed_out = False
        try:
            while True:
                if time.monotonic() - started > timeout:
                    timed_out = True
                    self.write_stream(f"\n命令超过 {timeout} 秒，已停止。\n")
                    stop_process(process)
                    break
                events = selector.select(timeout=0.2)
                for key, _ in events:
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if not self.write_stream(chunk.decode("utf-8", errors="replace")):
                        stop_process(process)
                        return 499
                if process.poll() is not None and not selector.get_map():
                    break
                if process.poll() is not None:
                    for key in list(selector.get_map().values()):
                        try:
                            chunk = os.read(key.fileobj.fileno(), 4096)
                        except BlockingIOError:
                            chunk = b""
                        if chunk:
                            if not self.write_stream(chunk.decode("utf-8", errors="replace")):
                                return 499
                        else:
                            selector.unregister(key.fileobj)
        finally:
            selector.close()

        code = 124 if timed_out else int(process.wait() or 0)
        if code == 0:
            self.write_stream("\nOK code=0\n")
        else:
            self.write_stream(f"\nFAILED code={code}\n")
        return code

    def stream_action(self, action: str, data: dict) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        try:
            steps = action_steps(action, data)
        except Exception as exc:
            self.write_stream(f"FAILED: {exc}\n")
            return
        self.write_stream("开始执行，过程会实时显示在这里。\n")
        for title, args, timeout, env in steps:
            code = self.stream_step(title, args, timeout, env)
            if code != 0:
                if code != 499:
                    self.write_stream("\n后续步骤已停止，请先处理上面的错误。\n")
                return
        self.write_stream("\nDONE code=0\n")

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/session":
            self.send_json({"ok": api_auth_ok(self.headers)})
            return
        if parsed.path == "/api/status":
            if not self.require_auth():
                return
            self.send_json(public_status())
            return
        if parsed.path == "/api/subscriptions":
            if not self.require_auth():
                return
            self.send_json({"items": list_subscriptions()})
            return
        if parsed.path == "/api/settings/basic":
            if not self.require_auth():
                return
            conf = read_conf()
            keys = ["LAN_IF", "LAN_NET", "LAN_IP", "PROXY_PORT", "PANEL_PORT", "ADMIN_PORT", "DNS1", "DNS2", "SUBSCRIBE_USER_AGENT", "DOWNLOAD_PROXY"]
            interfaces = list_network_interfaces()
            detected = detect_lan_settings(conf.get("LAN_IF", ""))
            settings = {key: conf.get(key, "") for key in keys}
            for key, value in detected.items():
                if not settings.get(key):
                    settings[key] = value
            self.send_json({"settings": settings, "interfaces": interfaces, "detected": detected})
            return
        if parsed.path == "/api/logs":
            if not self.require_auth():
                return
            query = parse_qs(parsed.query)
            service = query.get("service", ["sing-box"])[0]
            if service not in {"sing-box", "bypassproxy-admin", "bypassproxy-forward"}:
                service = "sing-box"
            result = run_command(["journalctl", "-u", service, "-n", "160", "--no-pager"], timeout=20)
            self.send_json(result)
            return
        return super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/session":
            try:
                data = self.read_json()
                secret = read_conf().get("PANEL_SECRET", "abc123")
                self.send_json({"ok": data.get("secret") == secret})
            except Exception as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)
            return
        if not self.require_auth():
            return
        stream_match = re.fullmatch(r"/api/actions-stream/([a-z0-9-]+)", parsed.path)
        if stream_match:
            try:
                data = self.read_json()
            except Exception as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            self.stream_action(stream_match.group(1), data)
            return
        try:
            data = self.read_json()
            response = self.handle_post(parsed.path, data)
            self.send_json(response, HTTPStatus.OK if response.get("ok", True) else HTTPStatus.BAD_REQUEST)
        except Exception as exc:
            self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)

    def do_PUT(self):
        if not self.require_auth():
            return
        parsed = urlparse(self.path)
        try:
            data = self.read_json()
            match = re.fullmatch(r"/api/subscriptions/(\d{1,3})", parsed.path)
            if not match:
                self.send_json({"ok": False, "error": "接口不存在"}, HTTPStatus.NOT_FOUND)
                return
            path = subscription_path(match.group(1))
            if not path.exists():
                self.send_json({"ok": False, "error": "订阅不存在"}, HTTPStatus.NOT_FOUND)
                return
            old = load_subscription(path)
            name = str(data.get("name") or old["name"]).strip()
            url = str(data.get("url") or old["url"]).strip()
            enabled = bool(data.get("enabled", old["enabled"]))
            if not url:
                raise ValueError("地址不能为空")
            write_subscription(path, name or url, url, enabled)
            self.send_json({"ok": True, "item": load_subscription(path)})
        except Exception as exc:
            self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)

    def do_DELETE(self):
        if not self.require_auth():
            return
        parsed = urlparse(self.path)
        match = re.fullmatch(r"/api/subscriptions/(\d{1,3})", parsed.path)
        if not match:
            self.send_json({"ok": False, "error": "接口不存在"}, HTTPStatus.NOT_FOUND)
            return
        path = subscription_path(match.group(1))
        if path.exists():
            path.unlink()
        self.send_json({"ok": True})

    def handle_post(self, path: str, data: dict) -> dict:
        if path == "/api/subscriptions":
            name = str(data.get("name") or "").strip()
            url = str(data.get("url") or "").strip()
            if not url:
                raise ValueError("地址不能为空")
            sub_id = next_subscription_id()
            item_path = subscription_path(sub_id)
            write_subscription(item_path, name or url, url, bool(data.get("enabled", True)))
            return {"ok": True, "item": load_subscription(item_path)}
        match = re.fullmatch(r"/api/subscriptions/(\d{1,3})/toggle", path)
        if match:
            item_path = subscription_path(match.group(1))
            if not item_path.exists():
                raise ValueError("订阅不存在")
            item = load_subscription(item_path)
            write_subscription(item_path, item["name"], item["url"], not item["enabled"])
            return {"ok": True, "item": load_subscription(item_path)}
        if path == "/api/settings/admin-port":
            port = str(data.get("port") or "").strip()
            if not re.fullmatch(r"\d{2,5}", port) or not (1 <= int(port) <= 65535):
                raise ValueError("端口无效")
            save_conf_key("ADMIN_PORT", port)
            return {"ok": True, "message": "端口已保存，重启 Web 管理页后生效"}
        if path == "/api/settings/basic":
            selected_if = str(data.get("LAN_IF") or "").strip()
            detected = detect_lan_settings(selected_if)
            if selected_if and detected.get("LAN_IF") == selected_if:
                data["LAN_IP"] = detected.get("LAN_IP") or data.get("LAN_IP", "")
                data["LAN_NET"] = detected.get("LAN_NET") or data.get("LAN_NET", "")
            allowed = {
                "LAN_IF": r"^[A-Za-z0-9_.:-]{1,64}$",
                "LAN_NET": r"^[0-9A-Fa-f:.\/]{3,64}$",
                "LAN_IP": r"^[0-9A-Fa-f:.]{3,64}$",
                "PROXY_PORT": r"^\d{2,5}$",
                "PANEL_PORT": r"^\d{2,5}$",
                "ADMIN_PORT": r"^\d{2,5}$",
                "DNS1": r"^[0-9A-Fa-f:.]{3,64}$",
                "DNS2": r"^[0-9A-Fa-f:.]{0,64}$",
                "SUBSCRIBE_USER_AGENT": r"^.{0,120}$",
                "DOWNLOAD_PROXY": r"^.{0,300}$",
            }
            for key, pattern in allowed.items():
                value = str(data.get(key, "")).strip()
                if value and not re.fullmatch(pattern, value):
                    raise ValueError(f"{key} 格式无效")
                if key.endswith("PORT") and value and not (1 <= int(value) <= 65535):
                    raise ValueError(f"{key} 端口无效")
                save_conf_key(key, value)
            return {"ok": True, "message": "基础设置已保存。端口类修改需要应用配置或重启相关服务后生效。"}
        if path == "/api/settings/panel-secret":
            current = str(data.get("current") or "")
            new_secret = str(data.get("newSecret") or "").strip()
            confirm = str(data.get("confirm") or "").strip()
            old_secret = read_conf().get("PANEL_SECRET", "abc123")
            if old_secret and current != old_secret:
                raise ValueError("当前密钥不正确")
            if len(new_secret) < 4:
                raise ValueError("新密钥至少 4 位")
            if new_secret != confirm:
                raise ValueError("两次输入的新密钥不一致")
            save_conf_key("PANEL_SECRET", new_secret)
            render = self.handle_post("/api/actions/render-config", {})
            if render.get("ok"):
                restart = run_command(["systemctl", "restart", "sing-box"], timeout=40)
                render["restart"] = restart
                render["ok"] = restart["ok"]
                render["output"] = (render.get("output", "") + "\n" + restart.get("output", "")).strip()
            return {"ok": bool(render.get("ok")), "message": "登录密钥已修改，请重新登录", "output": render.get("output", "")}
        if path == "/api/actions/update-subscription":
            env = {"ROUTER_CONF": str(CONF)}
            if data.get("direct"):
                env["BYPASSPROXY_DIRECT_DOWNLOAD"] = "1"
            result = run_command(["/usr/local/sbin/bypassproxy-update-subscription.sh"], timeout=240, env=env)
            if result["ok"]:
                apply = self.handle_post("/api/actions/apply-config", {})
                result["apply"] = apply
                result["ok"] = apply.get("ok", False)
            return result
        if path == "/api/actions/render-config":
            result = run_command(
                [
                    "python3",
                    str(APP_DIR / "scripts/render-config.py"),
                ],
                timeout=60,
                env={"ROUTER_CONF": str(CONF), "OUTBOUNDS_JSON": str(OUTBOUNDS_JSON), "OUTPUT": str(SING_BOX_CONFIG)},
            )
            if result["ok"]:
                check = run_command(["sing-box", "check", "-C", "/etc/sing-box"], timeout=60)
                result["check"] = check
                result["ok"] = check["ok"]
                result["output"] = (result["output"] + "\n" + check["output"]).strip()
            return result
        if path == "/api/actions/apply-config":
            result = self.handle_post("/api/actions/render-config", {})
            if result["ok"]:
                restart = run_command(["systemctl", "restart", "sing-box"], timeout=40)
                result["restart"] = restart
                result["ok"] = restart["ok"]
                result["output"] = (result["output"] + "\n" + restart["output"]).strip()
            return result
        if path == "/api/actions/restart-sing-box":
            return run_command(["systemctl", "restart", "sing-box"], timeout=40)
        if path == "/api/actions/check-config":
            return run_command(["sing-box", "check", "-C", "/etc/sing-box"], timeout=60)
        if path == "/api/actions/update-rulesets":
            return run_command(["/usr/local/sbin/bypassproxy-update-rulesets.sh"], timeout=180, env={"ROUTER_CONF": str(CONF)})
        if path == "/api/actions/update-webui":
            return run_command(["/usr/local/sbin/bypassproxy-update-webui.sh"], timeout=240, env={"ROUTER_CONF": str(CONF)})
        if path == "/api/actions/update-core":
            return run_command(["/usr/local/sbin/bypassproxy-update-core.sh"], timeout=360, env={"ROUTER_CONF": str(CONF)})
        if path == "/api/actions/diagnose-network":
            return run_command(["/usr/local/sbin/bypassproxy-diagnose-network.sh"], timeout=180, env={"ROUTER_CONF": str(CONF)})
        if path == "/api/actions/repair":
            return run_command(["/usr/local/sbin/bypassproxy-repair.sh"], timeout=300, env={"ROUTER_CONF": str(CONF)})
        if path == "/api/actions/apply-forwarding":
            return run_command(["/usr/local/sbin/bypassproxy-forward.sh"], timeout=60, env={"ROUTER_CONF": str(CONF)})
        return {"ok": False, "error": "接口不存在"}


def main() -> None:
    conf = read_conf()
    host = os.environ.get("ADMIN_HOST", "0.0.0.0")
    port = int(os.environ.get("ADMIN_PORT", conf.get("ADMIN_PORT", "8088")))
    STATIC_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"BypassProxy admin listening on {host}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
