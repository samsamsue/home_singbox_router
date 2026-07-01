import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Activity,
  CheckCircle2,
  ExternalLink,
  Globe2,
  KeyRound,
  Loader2,
  Network,
  PanelTop,
  Plus,
  Power,
  RefreshCcw,
  Save,
  Shield,
  TerminalSquare,
  Trash2,
  XCircle,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { cn } from "@/lib";
import "./styles.css";

type Status = {
  services: { singBox: string; forwardTimer: string; admin: string };
  addresses: { admin: string; adminZeroTier: string; panel: string; proxy: string };
  ports: { admin: string; panel: string; proxy: string };
  nodeCount: number;
  subscriptionCount: number;
};

type Subscription = { id: string; name: string; url: string; enabled: boolean };
type ActionResult = { ok: boolean; output?: string; error?: string; message?: string };
type BasicSettings = Record<"LAN_IF" | "LAN_NET" | "LAN_IP" | "PROXY_PORT" | "PANEL_PORT" | "ADMIN_PORT" | "DNS1" | "DNS2" | "SUBSCRIBE_USER_AGENT" | "DOWNLOAD_PROXY", string>;
type NetworkInterface = { name: string; address: string; cidr: string; network: string };
type DialogState = {
  open: boolean;
  action: string;
  title: string;
  description: string;
  confirmText?: string;
  body?: Record<string, unknown>;
  directChoice?: boolean;
  dangerous?: boolean;
};

const tokenKey = "bypassproxy-admin-secret";

function authHeaders() {
  const token = localStorage.getItem(tokenKey) || "";
  return token ? { Authorization: `Bearer ${token}` } : {};
}

async function api<T>(path: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", ...authHeaders(), ...(options.headers || {}) },
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || "请求失败");
  return data as T;
}

function StatusBadge({ value }: { value: string }) {
  const active = value === "active";
  return (
    <span className={cn("inline-flex h-6 items-center rounded-full border px-2.5 text-xs font-medium", active ? "border-emerald-200 bg-emerald-50 text-emerald-700" : "border-border bg-muted text-muted-foreground")}>
      {active ? "运行中" : value || "未知"}
    </span>
  );
}

function statusOk(status: Status | null) {
  return status?.services.singBox === "active" && status?.services.forwardTimer === "active";
}

function Pill({ children, active }: { children: React.ReactNode; active?: boolean }) {
  return <span className={cn("inline-flex h-7 items-center rounded-md border px-2.5 text-xs font-medium", active ? "border-emerald-200 bg-emerald-50 text-emerald-700" : "bg-muted text-muted-foreground")}>{children}</span>;
}

function Alert({ message }: { message: string }) {
  return (
    <div className="flex items-center gap-2 rounded-md border border-destructive/25 bg-destructive/10 px-3 py-2 text-sm text-destructive">
      <XCircle className="h-4 w-4 shrink-0" />
      <span className="min-w-0">{message}</span>
    </div>
  );
}

function DialogShell({
  title,
  description,
  children,
  footer,
  onClose,
  wide,
}: {
  title: string;
  description?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
  onClose: () => void;
  wide?: boolean;
}) {
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent wide={wide}>
        <DialogHeader>
          <DialogTitle className="text-lg font-semibold">{title}</DialogTitle>
          {description ? <DialogDescription className="mt-1 text-sm text-muted-foreground">{description}</DialogDescription> : null}
        </DialogHeader>
        <DialogBody>{children}</DialogBody>
        <DialogFooter>{footer || <Button variant="secondary" onClick={onClose}>关闭</Button>}</DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function Login({ onLogin }: { onLogin: () => void }) {
  const [secret, setSecret] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const result = await api<{ ok: boolean }>("/api/session", { method: "POST", body: JSON.stringify({ secret }) });
      if (!result.ok) {
        setError("密钥不正确");
        return;
      }
      localStorage.setItem(tokenKey, secret);
      onLogin();
    } catch (err) {
      setError(err instanceof Error ? err.message : "登录失败");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="grid min-h-screen place-items-center bg-muted/35 p-4">
      <Card className="w-full max-w-[420px]">
        <CardHeader className="border-b-0 pb-2">
          <div className="flex items-center gap-3">
            <div className="grid h-10 w-10 place-items-center rounded-md bg-primary text-primary-foreground">
              <Shield className="h-5 w-5" />
            </div>
            <div>
              <h1 className="text-xl font-semibold">BypassProxy</h1>
              <p className="text-sm text-muted-foreground">管理后台</p>
            </div>
          </div>
        </CardHeader>
        <CardContent>
          <form className="grid gap-4" onSubmit={submit}>
            <Label>
              登录密钥
              <Input value={secret} onChange={(event) => setSecret(event.target.value)} type="password" placeholder="默认 abc123" />
            </Label>
            {error ? <Alert message={error} /> : null}
            <Button busy={busy} type="submit" className="w-full">登录</Button>
          </form>
        </CardContent>
      </Card>
    </main>
  );
}

function ActionDialog({
  dialog,
  setDialog,
  running,
  output,
  error,
  onConfirm,
}: {
  dialog: DialogState;
  setDialog: (next: DialogState) => void;
  running: boolean;
  output: string;
  error: string;
  onConfirm: () => void;
}) {
  const outputRef = useRef<HTMLPreElement>(null);
  useEffect(() => {
    if (outputRef.current) outputRef.current.scrollTop = outputRef.current.scrollHeight;
  }, [output, running]);
  if (!dialog.open) return null;
  return (
    <DialogShell
      title={dialog.title}
      description={dialog.description}
      wide
      onClose={() => setDialog({ ...dialog, open: false })}
      footer={
        <>
          <Button variant="secondary" disabled={running} onClick={() => setDialog({ ...dialog, open: false })}>关闭</Button>
          <Button variant={dialog.dangerous ? "destructive" : "default"} busy={running} onClick={onConfirm}>
            {dialog.confirmText || "开始执行"}
          </Button>
        </>
      }
    >
      <div className="grid gap-4">
        {dialog.directChoice !== undefined ? (
          <label className="flex items-center gap-2 rounded-md border bg-muted/30 px-3 py-2 text-sm text-muted-foreground">
            <input
              className="h-4 w-4 accent-primary"
              type="checkbox"
              checked={dialog.directChoice}
              onChange={(event) => setDialog({ ...dialog, directChoice: event.target.checked })}
              disabled={running}
            />
            本次直连下载订阅，不使用下载代理
          </label>
        ) : null}
        {running ? (
          <div className="flex items-center gap-2 rounded-md border bg-muted/30 px-3 py-2 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" />
            正在执行，请保持页面打开
          </div>
        ) : null}
        {error ? <Alert message={error} /> : null}
        {(output || error) ? (
          <pre ref={outputRef} className="max-h-[48vh] overflow-auto whitespace-pre-wrap rounded-md bg-slate-950 p-3 font-mono text-xs leading-5 text-slate-100">{output || error}</pre>
        ) : (
          <div className="rounded-md border bg-muted/30 px-3 py-2 text-sm text-muted-foreground">确认后开始执行，过程和结果会实时显示在这个弹窗里。</div>
        )}
      </div>
    </DialogShell>
  );
}

function Overview({ status }: { status: Status | null }) {
  const tiles = [
    { label: "代理服务", value: status?.services.singBox || "unknown", detail: `${status?.nodeCount ?? 0} 个节点`, icon: Activity },
    { label: "旁路由转发", value: status?.services.forwardTimer || "unknown", detail: "NAT / 网关转发", icon: Network },
    { label: "管理后台", value: status?.services.admin || "unknown", detail: `端口 ${status?.ports.admin ?? "8088"}`, icon: Shield },
  ];
  return (
    <div className="grid gap-3 sm:grid-cols-3">
      {tiles.map((tile) => {
        const Icon = tile.icon;
        const active = tile.value === "active";
        return (
          <div className="flex min-w-0 items-center justify-between gap-3 rounded-lg border bg-card p-4 shadow-panel" key={tile.label}>
            <div className="flex min-w-0 items-center gap-3">
              <div className={cn("grid h-9 w-9 shrink-0 place-items-center rounded-md", active ? "bg-emerald-50 text-emerald-700" : "bg-muted text-muted-foreground")}>
                <Icon className="h-4 w-4" />
              </div>
              <div className="min-w-0">
                <div className="truncate text-sm font-medium">{tile.label}</div>
                <div className="truncate text-xs text-muted-foreground">{tile.detail}</div>
              </div>
            </div>
            <StatusBadge value={tile.value} />
          </div>
        );
      })}
    </div>
  );
}

function HeaderPanel({ healthy }: { healthy: boolean }) {
  return (
    <header className="rounded-lg border bg-card px-4 py-4 shadow-panel sm:px-5">
      <div className="flex min-w-0 items-center gap-3">
        <div className="grid h-12 w-12 shrink-0 place-items-center rounded-md bg-primary text-primary-foreground">
          <Shield className="h-5 w-5" />
        </div>
        <div className="min-w-0">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <h1 className="truncate text-xl font-semibold leading-tight">BypassProxy</h1>
            <Pill active={healthy}>{healthy ? "运行正常" : "需要检查"}</Pill>
          </div>
          <p className="mt-1 truncate text-sm text-muted-foreground">旁路由代理管理后台</p>
        </div>
      </div>
    </header>
  );
}

function ControlCenter({
  status,
  openAction,
  openPassword,
  openBasicSettings,
  showRecent,
}: {
  status: Status | null;
  openAction: (dialog: DialogState) => void;
  openPassword: () => void;
  openBasicSettings: () => void;
  showRecent: () => void;
}) {
  const panelUrl = status?.addresses.panel || "";
  const actions = [
    {
      title: "网络诊断",
      description: "检查 DNS、转发、服务状态和节点连通性。",
      icon: TerminalSquare,
      onClick: () => openAction({ open: true, action: "diagnose-network", title: "网络诊断", description: "检查服务、DNS、转发、订阅节点等常见问题。", confirmText: "开始诊断" }),
    },
    {
      title: "检查配置",
      description: "确认 sing-box 配置语法和引用文件是否可用。",
      icon: CheckCircle2,
      onClick: () => openAction({ open: true, action: "check-config", title: "检查配置", description: "运行 sing-box check，确认当前配置是否可用。", confirmText: "检查" }),
    },
    {
      title: "应用转发/NAT",
      description: "手机设网关不能上网时，优先重新应用这一项。",
      icon: Network,
      onClick: () => openAction({ open: true, action: "apply-forwarding", title: "应用转发/NAT", description: "重新写入旁路由转发规则，手机设网关不能上网时常用。", confirmText: "应用" }),
    },
    {
      title: "一键修复",
      description: "修复脚本入口、重新生成配置、检查配置、重启服务并应用转发。",
      icon: Shield,
      onClick: () => openAction({ open: true, action: "repair", title: "一键修复", description: "适合服务异常、配置丢失、端口或转发规则不正常时使用。", confirmText: "开始修复" }),
    },
    {
      title: "重启 sing-box",
      description: "代理服务异常、配置应用后可用它恢复服务。",
      icon: Power,
      onClick: () => openAction({ open: true, action: "restart-sing-box", title: "重启 sing-box", description: "重启代理服务，通常用于配置修改后恢复服务。", confirmText: "重启" }),
    },
    {
      title: "暂停代理",
      description: "停止 sing-box，不停止 Web 管理页。家里设备会暂时不能走旁路由。",
      icon: Power,
      onClick: () => openAction({ open: true, action: "pause-proxy", title: "暂停代理", description: "只停止 sing-box 代理服务，Web 管理页仍可打开，之后可以点“恢复代理”。", confirmText: "暂停代理", dangerous: true }),
    },
    {
      title: "恢复代理",
      description: "重新生成并检查配置，启动 sing-box，再应用转发/NAT。",
      icon: RefreshCcw,
      onClick: () => openAction({ open: true, action: "resume-proxy", title: "恢复代理", description: "启动 sing-box 并重新应用旁路由转发规则。", confirmText: "恢复代理" }),
    },
    {
      title: "节点面板",
      description: "打开 MetaCubeXD 查看节点、测速、连接和流量；也可以单独更新面板。",
      icon: PanelTop,
      onClick: () => panelUrl && window.open(panelUrl, "_blank", "noopener,noreferrer"),
      tools: [
        { label: "打开节点面板", icon: ExternalLink, onClick: () => panelUrl && window.open(panelUrl, "_blank", "noopener,noreferrer") },
        { label: "更新节点面板", icon: RefreshCcw, onClick: () => openAction({ open: true, action: "update-webui", title: "更新节点面板", description: "检查并更新 MetaCubeXD 静态面板。", confirmText: "更新" }) },
      ],
    },
    {
      title: "更新分流规则",
      description: "检查国内 geosite/geoip 规则，有变化才下载。",
      icon: Globe2,
      onClick: () => openAction({ open: true, action: "update-rulesets", title: "更新国内分流规则", description: "检查 geosite-cn 和 geoip-cn，有变化才会下载。", confirmText: "更新" }),
    },
    {
      title: "更新脚本",
      description: "从 GitHub 检查并更新 BypassProxy 程序本体。",
      icon: RefreshCcw,
      onClick: () => openAction({ open: true, action: "update-core", title: "更新 BypassProxy 脚本", description: "从 GitHub 检查并更新本项目脚本。更新过程中管理后台可能会短暂重启。", confirmText: "更新脚本" }),
    },
    {
      title: "基础设置",
      description: "修改端口、LAN 信息、DNS、订阅 User-Agent 和下载代理。",
      icon: Save,
      onClick: openBasicSettings,
    },
    {
      title: "修改密钥",
      description: "修改管理后台和节点面板共用的登录密钥。",
      icon: KeyRound,
      onClick: openPassword,
    },
    {
      title: "最近结果",
      description: "查看上一次操作摘要。",
      icon: Activity,
      onClick: showRecent,
    },
  ];
  return (
    <Card>
      <CardHeader>
        <CardTitle description="需要处理问题或维护时，从这里点对应操作。">操作</CardTitle>
      </CardHeader>
      <CardContent className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        {actions.map((action) => {
          const Icon = action.icon;
          return (
            <button key={action.title} className="group grid min-h-[104px] gap-3 rounded-lg border bg-background p-4 text-left transition-colors hover:border-primary/40 hover:bg-accent" onClick={action.onClick}>
              <div className="flex items-start justify-between gap-3">
                <div className="flex min-w-0 items-center gap-3">
                  <div className="grid h-9 w-9 shrink-0 place-items-center rounded-md bg-secondary text-secondary-foreground group-hover:bg-primary group-hover:text-primary-foreground">
                    <Icon className="h-4 w-4" />
                  </div>
                  <div className="truncate text-sm font-semibold">{action.title}</div>
                </div>
                {"tools" in action && action.tools ? (
                  <div className="flex shrink-0 gap-1">
                    {action.tools.map((tool) => {
                      const ToolIcon = tool.icon;
                      return (
                        <span
                          key={tool.label}
                          title={tool.label}
                          role="button"
                          tabIndex={0}
                          className="inline-flex h-8 w-8 items-center justify-center rounded-md border bg-background text-muted-foreground hover:bg-accent hover:text-foreground"
                          onClick={(event) => {
                            event.stopPropagation();
                            tool.onClick();
                          }}
                          onKeyDown={(event) => {
                            if (event.key === "Enter" || event.key === " ") {
                              event.preventDefault();
                              event.stopPropagation();
                              tool.onClick();
                            }
                          }}
                        >
                          <ToolIcon className="h-4 w-4" />
                        </span>
                      );
                    })}
                  </div>
                ) : null}
              </div>
              <p className="text-sm leading-5 text-muted-foreground">{action.description}</p>
            </button>
          );
        })}
      </CardContent>
    </Card>
  );
}

function PasswordDialog({ onClose, onPasswordChanged }: { onClose: () => void; onPasswordChanged: () => void }) {
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  async function changePassword() {
    setBusy(true);
    setMessage("");
    try {
      const result = await api<ActionResult>("/api/settings/panel-secret", {
        method: "POST",
        body: JSON.stringify({ current, newSecret: next, confirm }),
      });
      setMessage(result.message || "登录密钥已修改");
      localStorage.removeItem(tokenKey);
      window.setTimeout(onPasswordChanged, 900);
    } catch (err) {
      setMessage(err instanceof Error ? err.message : "修改失败");
    } finally {
      setBusy(false);
    }
  }

  return (
    <DialogShell
      title="修改登录密钥"
      description="管理后台和节点面板共用这个密钥。"
      onClose={onClose}
      footer={
        <>
          <Button variant="secondary" disabled={busy} onClick={onClose}>取消</Button>
          <Button busy={busy} disabled={!current || !next || !confirm} onClick={changePassword}>保存</Button>
        </>
      }
    >
      <div className="grid gap-4">
        <Label>
          当前密钥
          <Input type="password" value={current} onChange={(event) => setCurrent(event.target.value)} />
        </Label>
        <Label>
          新密钥
          <Input type="password" value={next} onChange={(event) => setNext(event.target.value)} />
        </Label>
        <Label>
          确认新密钥
          <Input type="password" value={confirm} onChange={(event) => setConfirm(event.target.value)} />
        </Label>
        {message ? <div className="rounded-md border bg-muted/30 px-3 py-2 text-sm text-muted-foreground">{message}</div> : null}
      </div>
    </DialogShell>
  );
}

function TextDialog({ title, content, onClose }: { title: string; content: string; onClose: () => void }) {
  return (
    <DialogShell title={title} description="最近一次操作的摘要。完整实时输出仍会显示在执行弹窗里。" onClose={onClose} wide>
      <pre className="max-h-[55vh] overflow-auto whitespace-pre-wrap rounded-md bg-slate-950 p-3 font-mono text-xs leading-5 text-slate-100">{content || "暂无操作"}</pre>
    </DialogShell>
  );
}

function BasicSettingsDialog({ onClose, setResult }: { onClose: () => void; setResult: (result: string) => void }) {
  const empty: BasicSettings = {
    LAN_IF: "",
    LAN_NET: "",
    LAN_IP: "",
    PROXY_PORT: "",
    PANEL_PORT: "",
    ADMIN_PORT: "",
    DNS1: "",
    DNS2: "",
    SUBSCRIBE_USER_AGENT: "",
    DOWNLOAD_PROXY: "",
  };
  const [settings, setSettings] = useState<BasicSettings>(empty);
  const [interfaces, setInterfaces] = useState<NetworkInterface[]>([]);
  const [busy, setBusy] = useState(true);
  const [message, setMessage] = useState("");
  const selectedInterface = interfaces.find((item) => item.name === settings.LAN_IF);

  useEffect(() => {
    let alive = true;
    api<{ settings: BasicSettings; interfaces: NetworkInterface[] }>("/api/settings/basic")
      .then((data) => {
        if (!alive) return;
        setInterfaces(data.interfaces || []);
        setSettings({ ...empty, ...data.settings });
      })
      .catch((err) => {
        if (alive) setMessage(err instanceof Error ? err.message : "读取失败");
      })
      .finally(() => {
        if (alive) setBusy(false);
      });
    return () => {
      alive = false;
    };
  }, []);

  function update(key: keyof BasicSettings, value: string) {
    setSettings((current) => ({ ...current, [key]: value }));
  }

  function chooseInterface(name: string) {
    const match = interfaces.find((item) => item.name === name);
    setSettings((current) => ({
      ...current,
      LAN_IF: name,
      LAN_IP: match?.address || current.LAN_IP,
      LAN_NET: match?.network || current.LAN_NET,
    }));
  }

  async function save() {
    setBusy(true);
    setMessage("");
    try {
      const result = await api<ActionResult>("/api/settings/basic", { method: "POST", body: JSON.stringify(settings) });
      const text = result.message || "基础设置已保存";
      setMessage(text);
      setResult(text);
    } catch (err) {
      setMessage(err instanceof Error ? err.message : "保存失败");
    } finally {
      setBusy(false);
    }
  }

  return (
    <DialogShell
      title="基础设置"
      description="一般只需要选 LAN 网卡。旁路由 IP 和 LAN 网段会根据网卡自动识别。"
      onClose={onClose}
      wide
      footer={
        <>
          <Button variant="secondary" disabled={busy} onClick={onClose}>关闭</Button>
          <Button busy={busy} onClick={save}>保存</Button>
        </>
      }
    >
      <div className="grid gap-5">
        <div className="rounded-lg border bg-muted/20 p-4">
          <div className="mb-4">
            <h3 className="text-sm font-semibold">网络识别</h3>
            <p className="mt-1 text-sm leading-6 text-muted-foreground">选择家里设备能访问到的那张网卡。手机设置网关时使用下面识别出的旁路由 IP。</p>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <Label className="sm:col-span-2">
              LAN 网卡
              <Select value={settings.LAN_IF} onValueChange={chooseInterface} disabled={busy || interfaces.length === 0}>
                <SelectTrigger>
                  <SelectValue placeholder="未识别到可用网卡" />
                </SelectTrigger>
                <SelectContent>
                  {interfaces.map((item) => (
                    <SelectItem key={`${item.name}-${item.cidr}`} value={item.name}>
                      {item.name} - {item.address}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Label>
            <div className="rounded-md border bg-background px-3 py-2">
              <div className="text-xs text-muted-foreground">旁路由 IP</div>
              <div className="mt-1 truncate text-sm font-medium">{selectedInterface?.address || settings.LAN_IP || "未识别"}</div>
            </div>
            <div className="rounded-md border bg-background px-3 py-2">
              <div className="text-xs text-muted-foreground">LAN 网段</div>
              <div className="mt-1 truncate text-sm font-medium">{selectedInterface?.network || settings.LAN_NET || "未识别"}</div>
            </div>
          </div>
        </div>

        <div className="grid gap-4 sm:grid-cols-3">
          <Label>
            代理端口
            <Input value={settings.PROXY_PORT} onChange={(event) => update("PROXY_PORT", event.target.value)} disabled={busy} />
          </Label>
          <Label>
            节点面板端口
            <Input value={settings.PANEL_PORT} onChange={(event) => update("PANEL_PORT", event.target.value)} disabled={busy} />
          </Label>
          <Label>
            管理后台端口
            <Input value={settings.ADMIN_PORT} onChange={(event) => update("ADMIN_PORT", event.target.value)} disabled={busy} />
          </Label>
        </div>

        <details className="rounded-lg border bg-background">
          <summary className="cursor-pointer px-4 py-3 text-sm font-medium">高级设置</summary>
          <div className="grid gap-4 border-t p-4 sm:grid-cols-2">
            <Label>
              旁路由 IP
              <Input value={settings.LAN_IP} onChange={(event) => update("LAN_IP", event.target.value)} disabled={busy} />
            </Label>
            <Label>
              LAN 网段
              <Input value={settings.LAN_NET} onChange={(event) => update("LAN_NET", event.target.value)} disabled={busy} />
            </Label>
            <Label>
              DNS 1
              <Input value={settings.DNS1} onChange={(event) => update("DNS1", event.target.value)} disabled={busy} />
            </Label>
            <Label>
              DNS 2
              <Input value={settings.DNS2} onChange={(event) => update("DNS2", event.target.value)} disabled={busy} />
            </Label>
            <Label>
              订阅 User-Agent
              <Input value={settings.SUBSCRIBE_USER_AGENT} onChange={(event) => update("SUBSCRIBE_USER_AGENT", event.target.value)} disabled={busy} />
            </Label>
            <Label>
              下载代理
              <Input value={settings.DOWNLOAD_PROXY} placeholder="例如 http://127.0.0.1:7890，可留空" onChange={(event) => update("DOWNLOAD_PROXY", event.target.value)} disabled={busy} />
            </Label>
          </div>
        </details>

        {message ? <div className="rounded-md border bg-muted/30 px-3 py-2 text-sm text-muted-foreground">{message}</div> : null}
      </div>
    </DialogShell>
  );
}

function AddSubscriptionDialog({
  onClose,
  reload,
  setResult,
}: {
  onClose: () => void;
  reload: () => void;
  setResult: (result: string) => void;
}) {
  const [name, setName] = useState("");
  const [url, setUrl] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function create() {
    setBusy(true);
    setError("");
    try {
      const result = await api<{ ok: boolean; item: Subscription }>("/api/subscriptions", { method: "POST", body: JSON.stringify({ name, url, enabled: true }) });
      setResult(result.ok ? "已添加订阅" : "添加失败");
      reload();
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : "添加失败");
    } finally {
      setBusy(false);
    }
  }

  return (
    <DialogShell
      title="添加订阅"
      description="支持 Clash/Mihomo 订阅，也支持单条 vmess、vless、trojan、ss、hysteria2 节点。"
      onClose={onClose}
      footer={
        <>
          <Button variant="secondary" disabled={busy} onClick={onClose}>取消</Button>
          <Button busy={busy} disabled={!url.trim()} onClick={create}>添加</Button>
        </>
      }
    >
      <div className="grid gap-4">
        <Label>
          名称
          <Input value={name} onChange={(event) => setName(event.target.value)} placeholder="例如：主订阅" />
        </Label>
        <Label>
          订阅/节点地址
          <Input value={url} onChange={(event) => setUrl(event.target.value)} placeholder="https://... 或 vless:// / vmess:// / trojan:// / ss://" />
        </Label>
        {error ? <Alert message={error} /> : null}
      </div>
    </DialogShell>
  );
}

function EditSubscriptionDialog({
  item,
  onClose,
  reload,
  setResult,
}: {
  item: Subscription;
  onClose: () => void;
  reload: () => void;
  setResult: (result: string) => void;
}) {
  const [name, setName] = useState(item.name);
  const [url, setUrl] = useState(item.url);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function save() {
    setBusy(true);
    setError("");
    try {
      const result = await api<{ ok: boolean }>(`/api/subscriptions/${item.id}`, { method: "PUT", body: JSON.stringify({ ...item, name, url }) });
      setResult(result.ok ? "已保存订阅" : "保存失败");
      reload();
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : "保存失败");
    } finally {
      setBusy(false);
    }
  }

  return (
    <DialogShell
      title="编辑订阅"
      description={`编号 ${item.id}`}
      onClose={onClose}
      footer={
        <>
          <Button variant="secondary" disabled={busy} onClick={onClose}>取消</Button>
          <Button busy={busy} disabled={!url.trim()} onClick={save}>保存</Button>
        </>
      }
    >
      <div className="grid gap-4">
        <Label>
          名称
          <Input value={name} onChange={(event) => setName(event.target.value)} />
        </Label>
        <Label>
          订阅/节点地址
          <Input value={url} onChange={(event) => setUrl(event.target.value)} />
        </Label>
        {error ? <Alert message={error} /> : null}
      </div>
    </DialogShell>
  );
}

function SubscriptionCard({
  items,
  reload,
  setResult,
  openAction,
  openAdd,
}: {
  items: Subscription[];
  reload: () => void;
  setResult: (result: string) => void;
  openAction: (dialog: DialogState) => void;
  openAdd: () => void;
}) {
  const [editingItem, setEditingItem] = useState<Subscription | null>(null);

  async function remove(item: Subscription) {
    if (!confirm(`删除 ${item.name}？`)) return;
    await api(`/api/subscriptions/${item.id}`, { method: "DELETE" });
    setResult("已删除订阅");
    reload();
  }

  async function toggle(item: Subscription) {
    await api(`/api/subscriptions/${item.id}/toggle`, { method: "POST", body: "{}" });
    reload();
  }

  return (
    <Card>
      <CardHeader className="flex-col sm:flex-row sm:items-center">
        <CardTitle description="常用操作集中在这里：添加、修改、更新并应用。">订阅与节点</CardTitle>
        <div className="flex w-full flex-wrap items-center gap-2 sm:w-auto sm:justify-end">
          <Pill>{items.length} 个订阅</Pill>
          <Button variant="secondary" onClick={openAdd}>
            <Plus className="h-4 w-4" />
            添加
          </Button>
          <Button onClick={() => openAction({ open: true, action: "update-subscription", title: "更新订阅并应用", description: "重新拉取所有启用订阅，失败的订阅会继续使用上次成功缓存。", confirmText: "更新并应用", directChoice: false })}>
            <RefreshCcw className="h-4 w-4" />
            更新并应用
          </Button>
        </div>
      </CardHeader>
      <CardContent>
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          {items.map((item) => (
            <div className={cn("grid min-w-0 gap-4 overflow-hidden rounded-lg border p-4 transition-colors", item.enabled ? "bg-background" : "border-border/70 bg-muted/45")} key={item.id}>
              <div className="flex min-w-0 items-start justify-between gap-3">
                <div className="min-w-0 flex-1 overflow-hidden">
                  <div className="flex min-w-0 items-center gap-2">
                    <span className={cn("truncate text-sm font-semibold", !item.enabled && "text-muted-foreground")}>{item.name}</span>
                    <span className="shrink-0 font-mono text-xs text-muted-foreground">#{item.id}</span>
                  </div>
                  <div className={cn("mt-1 block w-full min-w-0 overflow-hidden text-ellipsis whitespace-nowrap font-mono text-xs leading-5", item.enabled ? "text-muted-foreground/75" : "text-muted-foreground/55")} title={item.url}>{item.url}</div>
                </div>
                <div className="shrink-0"><StatusBadge value={item.enabled ? "active" : "disabled"} /></div>
              </div>
              <div className="flex flex-wrap gap-2">
                <Button size="sm" variant="secondary" onClick={() => setEditingItem(item)} className={!item.enabled ? "bg-background/70" : ""}>
                  <Save className="h-4 w-4" />
                  编辑
                </Button>
                <Button size="sm" variant="secondary" onClick={() => toggle(item)} className={!item.enabled ? "bg-background/70" : ""}>
                  <Power className="h-4 w-4" />
                  {item.enabled ? "停用" : "启用"}
                </Button>
                <Button size="sm" variant="ghost" onClick={() => remove(item)} className="text-destructive hover:bg-destructive/10 hover:text-destructive">
                  <Trash2 className="h-4 w-4" />
                  删除
                </Button>
              </div>
            </div>
          ))}
          {items.length === 0 ? <div className="rounded-lg border p-8 text-center text-sm text-muted-foreground sm:col-span-2 xl:col-span-3">暂无订阅</div> : null}
        </div>
      </CardContent>
      {editingItem ? <EditSubscriptionDialog item={editingItem} onClose={() => setEditingItem(null)} reload={reload} setResult={setResult} /> : null}
    </Card>
  );
}

function App() {
  const [loggedIn, setLoggedIn] = useState(Boolean(localStorage.getItem(tokenKey)));
  const [status, setStatus] = useState<Status | null>(null);
  const [subscriptions, setSubscriptions] = useState<Subscription[]>([]);
  const [dialog, setDialog] = useState<DialogState>({ open: false, action: "", title: "", description: "" });
  const [addOpen, setAddOpen] = useState(false);
  const [passwordOpen, setPasswordOpen] = useState(false);
  const [basicOpen, setBasicOpen] = useState(false);
  const [recentOpen, setRecentOpen] = useState(false);
  const [busyAction, setBusyAction] = useState("");
  const [dialogOutput, setDialogOutput] = useState("");
  const [dialogError, setDialogError] = useState("");
  const [lastResult, setLastResult] = useState("");
  const [error, setError] = useState("");

  const healthy = statusOk(status);

  async function loadAll() {
    if (!loggedIn) return;
    try {
      const [nextStatus, subs] = await Promise.all([api<Status>("/api/status"), api<{ items: Subscription[] }>("/api/subscriptions")]);
      setStatus(nextStatus);
      setSubscriptions(subs.items);
      setError("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "读取失败");
      if ((err instanceof Error ? err.message : "").includes("密钥")) setLoggedIn(false);
    }
  }

  function openAction(next: DialogState) {
    setDialog(next);
    setDialogOutput("");
    setDialogError("");
  }

  async function confirmAction() {
    const current = dialog;
    setBusyAction(current.action);
    setDialogOutput("");
    setDialogError("");
    let fullOutput = "";
    try {
      const body = { ...(current.body || {}) };
      if (current.directChoice !== undefined) body.direct = current.directChoice;
      const response = await fetch(`/api/actions-stream/${current.action}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify(body),
      });
      if (!response.ok) {
        const text = await response.text();
        throw new Error(text || "操作失败");
      }
      if (!response.body) throw new Error("浏览器不支持实时输出");
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        const chunk = decoder.decode(value, { stream: true });
        fullOutput += chunk;
        setDialogOutput((currentOutput) => currentOutput + chunk);
      }
      const tail = fullOutput.trim().slice(-1200) || "完成";
      setLastResult(tail);
      if (!fullOutput.includes("DONE code=0")) {
        setDialogError("执行没有完整成功，请查看上面的输出。");
      }
      await loadAll();
    } catch (err) {
      const message = err instanceof Error ? err.message : "操作失败";
      setDialogError(message);
      setLastResult(fullOutput.trim() || message);
    } finally {
      setBusyAction("");
    }
  }

  useEffect(() => {
    loadAll();
    const timer = window.setInterval(loadAll, 12000);
    return () => window.clearInterval(timer);
  }, [loggedIn]);

  if (!loggedIn) return <Login onLogin={() => setLoggedIn(true)} />;

  return (
    <main className="min-h-screen bg-muted/35">
      <div className="mx-auto grid w-full max-w-[1440px] gap-4 px-4 py-4 sm:px-6 lg:px-8">
        <HeaderPanel healthy={healthy} />

        {error ? <Alert message={error} /> : null}
        <Overview status={status} />

        <div className="grid gap-4">
          <SubscriptionCard items={subscriptions} reload={loadAll} setResult={setLastResult} openAction={openAction} openAdd={() => setAddOpen(true)} />
          <ControlCenter status={status} openAction={openAction} openPassword={() => setPasswordOpen(true)} openBasicSettings={() => setBasicOpen(true)} showRecent={() => setRecentOpen(true)} />
        </div>
      </div>
      <ActionDialog dialog={dialog} setDialog={setDialog} running={Boolean(busyAction)} output={dialogOutput} error={dialogError} onConfirm={confirmAction} />
      {addOpen ? <AddSubscriptionDialog onClose={() => setAddOpen(false)} reload={loadAll} setResult={setLastResult} /> : null}
      {passwordOpen ? <PasswordDialog onClose={() => setPasswordOpen(false)} onPasswordChanged={() => setLoggedIn(false)} /> : null}
      {basicOpen ? <BasicSettingsDialog onClose={() => setBasicOpen(false)} setResult={setLastResult} /> : null}
      {recentOpen ? <TextDialog title="最近结果" content={lastResult} onClose={() => setRecentOpen(false)} /> : null}
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
