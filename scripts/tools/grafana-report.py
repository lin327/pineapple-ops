#!/usr/bin/env python3
"""Grafana 日报 - Playwright 截图 + PDF + 实时指标 + Resend 邮件

环境变量 (必填):
  GRAFANA_PASS       - Grafana 登录密码
  RESEND_API_KEY     - Resend 邮件 API 密钥

环境变量 (可选，有默认值):
  GRAFANA_URL        - Grafana 地址，默认 http://localhost:30858
  GRAFANA_USER       - Grafana 用户名，默认 admin
  VM_URL             - VictoriaMetrics 地址，默认 http://localhost:32728
  FROM_EMAIL         - 发件人邮箱，默认 report@tentative.me
  TO_EMAIL           - 收件人邮箱，默认 lin2582645823@163.com
  DASHBOARD_UID      - Grafana Dashboard UID，默认 pineapple-ops
"""

import asyncio, base64, json, os, shutil, sys, urllib.request, urllib.parse
from datetime import datetime
from playwright.async_api import async_playwright
import img2pdf

# === 配置 (从环境变量读取) ===
GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://localhost:30858")
GRAFANA_USER = os.environ.get("GRAFANA_USER", "admin")
GRAFANA_PASS = os.environ.get("GRAFANA_PASS", "")
VM_URL = os.environ.get("VM_URL", "http://localhost:32728")
RESEND_API_KEY = os.environ.get("RESEND_API_KEY", "")
FROM_EMAIL = os.environ.get("FROM_EMAIL", "report@tentative.me")
TO_EMAIL = os.environ.get("TO_EMAIL", "lin2582645823@163.com")
DASHBOARD_UID = os.environ.get("DASHBOARD_UID", "pineapple-ops")

# ! 必填凭证校验，缺失时立即退出
if not GRAFANA_PASS:
    print("错误: 未设置 GRAFANA_PASS 环境变量")
    sys.exit(1)
if not RESEND_API_KEY:
    print("错误: 未设置 RESEND_API_KEY 环境变量")
    sys.exit(1)

# note: 节点列表格式 — (instance地址:端口, 节点名称, 角色描述)
NODES = [
    ("100.115.0.33:9100", "DO-Master",  "K3s Master + 数据库"),
    ("100.115.0.40:9100", "DO-Worker1", "K3s Worker"),
    ("100.115.0.41:9100", "DO-Worker2", "K3s Worker"),
    ("100.115.0.1:9100",  "TX-Cloud",   "Nginx 反向代理"),
    ("100.115.0.2:9100",  "JD-Cloud",   "Vaultwarden + Uptime Kuma"),
]


def query_vm(expr):
    url = f"{VM_URL}/api/v1/query?query={urllib.parse.quote(expr)}"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            data = json.loads(r.read())
            if data.get("status") == "success" and data.get("data", {}).get("result"):
                return data["data"]["result"]
    except Exception as e:
        print(f"  查询失败: {expr} -> {e}")
    return []


def get_node_metrics(instance):
    cpu_r = query_vm(f'100 - (avg by(instance)(rate(node_cpu_seconds_total{{mode="idle",instance="{instance}"}}[5m])) * 100)')
    mem_r = query_vm(f'(1 - (node_memory_MemAvailable_bytes{{instance="{instance}"}} / node_memory_MemTotal_bytes{{instance="{instance}"}})) * 100')
    disk_r = query_vm(f'(1 - (node_filesystem_avail_bytes{{mountpoint="/",fstype!="tmpfs",instance="{instance}"}} / node_filesystem_size_bytes{{mountpoint="/",fstype!="tmpfs",instance="{instance}"}})) * 100')
    cpu = float(cpu_r[0]["value"][1]) if cpu_r else -1
    mem = float(mem_r[0]["value"][1]) if mem_r else -1
    disk = float(disk_r[0]["value"][1]) if disk_r else -1
    return cpu, mem, disk


# note: 状态分级阈值 — CRITICAL/WARNING/HEALTHY，可按需调整
def get_status(cpu, mem, disk):
    if cpu < 0 or mem < 0:
        return "N/A", "#9e9e9e", "#f5f5f5"
    if cpu > 90 or mem > 95 or disk > 90:
        return "CRITICAL", "#c62828", "#ffebee"
    if cpu > 70 or mem > 80 or disk > 80:
        return "WARNING", "#e65100", "#fff3e0"
    return "HEALTHY", "#2e7d32", "#e8f5e9"


def fmt(v):
    return f"{v:.1f}%" if v >= 0 else "N/A"


def bar_html(val, color):
    """生成进度条 HTML"""
    if val < 0:
        return '<div style="background:#eee;border-radius:4px;height:6px;width:100%;"></div>'
    w = min(val, 100)
    return f'<div style="background:#e8e8e8;border-radius:4px;height:6px;width:100%;overflow:hidden;"><div style="background:{color};height:100%;width:{w:.0f}%;border-radius:4px;"></div></div>'


def metric_color(val, warn=70, crit=90):
    if val < 0: return "#9e9e9e"
    if val >= crit: return "#c62828"
    if val >= warn: return "#e65100"
    return "#2e7d32"


def build_email(today, nodes_data):
    online = sum(1 for n in nodes_data if n["cpu"] >= 0)
    healthy = sum(1 for n in nodes_data if n["status"] == "HEALTHY")
    warns = sum(1 for n in nodes_data if n["status"] == "WARNING")
    crits = sum(1 for n in nodes_data if n["status"] == "CRITICAL")

    if crits > 0:
        header_icon = "&#9888;&#65039;"
        header_text = f"{crits} 个节点异常"
        header_color = "#c62828"
        header_bg = "#ffebee"
    elif warns > 0:
        header_icon = "&#9888;&#65039;"
        header_text = f"{warns} 个节点警告"
        header_color = "#e65100"
        header_bg = "#fff3e0"
    else:
        header_icon = "&#10003;"
        header_text = "全部正常"
        header_color = "#2e7d32"
        header_bg = "#e8f5e9"

    node_cards = ""
    for n in nodes_data:
        cpu_c = metric_color(n["cpu"])
        mem_c = metric_color(n["mem"])
        disk_c = metric_color(n["disk"], warn=80, crit=90)
        status_c = n["status_color"]

        node_cards += f'''
      <tr>
        <td style="padding:0;padding-bottom:12px;">
          <div style="background:#fff;border:1px solid #e8e8e8;border-radius:10px;padding:18px 20px;">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:14px;">
              <div>
                <span style="font-size:15px;font-weight:700;color:#1a1a1a;">{n["name"]}</span>
                <span style="font-size:12px;color:#999;margin-left:8px;">{n["ip"]}</span>
              </div>
              <span style="background:{n["status_bg"]};color:{status_c};padding:3px 12px;border-radius:20px;font-size:11px;font-weight:700;letter-spacing:0.5px;">{n["status"]}</span>
            </div>
            <div style="font-size:12px;color:#888;margin-bottom:14px;">{n["role"]}</div>
            <table style="width:100%;border-collapse:collapse;">
              <tr>
                <td style="width:50px;font-size:12px;color:#888;padding:0;">CPU</td>
                <td style="padding:0;padding-right:12px;">{bar_html(n["cpu"], cpu_c)}</td>
                <td style="width:50px;text-align:right;font-size:13px;font-weight:600;color:{cpu_c};padding:0;font-family:SF Mono,Menlo,monospace;">{n["cpu_str"]}</td>
              </tr>
              <tr><td colspan="3" style="height:8px;"></td></tr>
              <tr>
                <td style="font-size:12px;color:#888;padding:0;">MEM</td>
                <td style="padding:0;padding-right:12px;">{bar_html(n["mem"], mem_c)}</td>
                <td style="text-align:right;font-size:13px;font-weight:600;color:{mem_c};padding:0;font-family:SF Mono,Menlo,monospace;">{n["mem_str"]}</td>
              </tr>
              <tr><td colspan="3" style="height:8px;"></td></tr>
              <tr>
                <td style="font-size:12px;color:#888;padding:0;">DISK</td>
                <td style="padding:0;padding-right:12px;">{bar_html(n["disk"], disk_c)}</td>
                <td style="text-align:right;font-size:13px;font-weight:600;color:{disk_c};padding:0;font-family:SF Mono,Menlo,monospace;">{n["disk_str"]}</td>
              </tr>
            </table>
          </div>
        </td>
      </tr>'''

    return f'''<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f0f2f5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',sans-serif;">
<div style="max-width:640px;margin:0 auto;padding:24px 16px;">

  <!-- Header -->
  <div style="background:linear-gradient(135deg,#1a1a2e 0%,#16213e 50%,#0f3460 100%);border-radius:14px;padding:32px 28px;color:#fff;margin-bottom:20px;">
    <div style="font-size:12px;text-transform:uppercase;letter-spacing:2px;opacity:0.6;margin-bottom:8px;">Daily Report</div>
    <div style="font-size:24px;font-weight:800;margin-bottom:4px;">Pineapple-Ops</div>
    <div style="font-size:14px;opacity:0.7;">{today} &middot; 24h Monitoring Summary</div>
  </div>

  <!-- Status Banner -->
  <div style="background:{header_bg};border-radius:10px;padding:16px 20px;margin-bottom:20px;display:flex;align-items:center;gap:12px;">
    <span style="font-size:24px;">{header_icon}</span>
    <div>
      <div style="font-size:15px;font-weight:700;color:{header_color};">{header_text}</div>
      <div style="font-size:12px;color:#888;margin-top:2px;">{online}/{len(nodes_data)} nodes online &middot; {healthy} healthy &middot; {warns} warning &middot; {crits} critical</div>
    </div>
  </div>

  <!-- Node Cards -->
  <table style="width:100%;border-collapse:collapse;margin-bottom:20px;">
    {node_cards}
  </table>

  <!-- CTA Button -->
  <div style="text-align:center;margin-bottom:20px;">
    <a href="https://grafana.pineapple-user.site/d/{DASHBOARD_UID}" style="display:inline-block;background:linear-gradient(135deg,#1a73e8,#0d47a1);color:#fff;padding:14px 36px;text-decoration:none;border-radius:8px;font-weight:700;font-size:14px;letter-spacing:0.3px;box-shadow:0 4px 12px rgba(26,115,232,0.3);">Open Dashboard</a>
  </div>

  <!-- Attachment Note -->
  <div style="background:#fff;border:1px solid #e8e8e8;border-radius:8px;padding:14px 18px;margin-bottom:20px;">
    <div style="font-size:13px;color:#555;">
      <span style="color:#1a73e8;font-weight:600;">&#128206; Attachment:</span>
      Pineapple-Ops-Report-{today}.pdf &middot; Detailed 24h screenshots for each node
    </div>
  </div>

  <!-- Footer -->
  <div style="text-align:center;padding:8px 0;">
    <div style="font-size:11px;color:#bbb;">Sent automatically by Pineapple-Ops Monitoring System</div>
    <div style="font-size:11px;color:#ddd;margin-top:4px;">Powered by Grafana + VictoriaMetrics + Playwright</div>
  </div>

</div>
</body>
</html>'''


async def main():
    today = datetime.now().strftime("%Y-%m-%d")
    report_dir = f"/tmp/grafana-reports/{today}"
    os.makedirs(report_dir, exist_ok=True)
    print(f"=== 生成 Grafana 日报 {today} ===")

    # === 1. 获取实时指标 ===
    print("\n=== 获取实时指标 ===")
    nodes_data = []
    for instance, name, role in NODES:
        cpu, mem, disk = get_node_metrics(instance)
        status, status_color, status_bg = get_status(cpu, mem, disk)
        nodes_data.append({
            "instance": instance, "ip": instance.split(":")[0],
            "name": name, "role": role,
            "cpu": cpu, "mem": mem, "disk": disk,
            "status": status, "status_color": status_color, "status_bg": status_bg,
            "cpu_str": fmt(cpu), "mem_str": fmt(mem), "disk_str": fmt(disk),
        })
        print(f"  {name}: CPU={fmt(cpu)} MEM={fmt(mem)} DISK={fmt(disk)} [{status}]")

    # === 2. Playwright 截图 ===
    print("\n=== 生成仪表盘截图 ===")
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        ctx = await browser.new_context(viewport={"width": 1920, "height": 1080}, timezone_id="Asia/Shanghai")
        page = await ctx.new_page()

        print("登录 Grafana...")
        await page.goto(f"{GRAFANA_URL}/login", wait_until="load")
        await page.fill('input[name="user"], input[aria-label="Username input field"]', GRAFANA_USER)
        await page.fill('input[name="password"], input[aria-label="Password input field"]', GRAFANA_PASS)
        await page.click('button[type="submit"], button[aria-label="Login button"]')
        await page.wait_for_timeout(3000)
        print("  登录成功")

        print("截图: 总览")
        url = f"{GRAFANA_URL}/d/{DASHBOARD_UID}?orgId=1&from=now-24h&to=now&timezone=Asia/Shanghai"
        await page.goto(url, wait_until="load")
        await page.wait_for_timeout(8000)
        await page.screenshot(path=f"{report_dir}/overview.png", full_page=True)
        print(f"  overview.png ({os.path.getsize(f'{report_dir}/overview.png')/1024:.0f} KB)")

        for instance, name, _ in NODES:
            print(f"截图: {name} ({instance})")
            url = f"{GRAFANA_URL}/d/{DASHBOARD_UID}?orgId=1&from=now-24h&to=now&timezone=Asia/Shanghai&var-instance={instance}"
            await page.goto(url, wait_until="load")
            await page.wait_for_timeout(8000)
            await page.screenshot(path=f"{report_dir}/{name}.png", full_page=True)
            print(f"  {name}.png ({os.path.getsize(f'{report_dir}/{name}.png')/1024:.0f} KB)")

        await browser.close()

    # === 3. 生成 PDF ===
    print("\n=== 生成 PDF ===")
    png_files = []
    for f in ["overview.png"] + [f"{n}.png" for _, n, _ in NODES]:
        fp = f"{report_dir}/{f}"
        if os.path.exists(fp) and os.path.getsize(fp) > 0:
            png_files.append(fp)
    pdf_path = f"{report_dir}/Pineapple-Ops-Report-{today}.pdf"
    if png_files:
        with open(pdf_path, "wb") as f:
            f.write(img2pdf.convert(png_files))
        print(f"  PDF ({os.path.getsize(pdf_path)/1024:.0f} KB)")

    # === 4. 发送邮件 ===
    # note: 使用 urllib 发送，避免 curl 将 API Key 暴露在进程列表中
    print("\n=== 发送邮件 ===")
    with open(pdf_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    html = build_email(today, nodes_data)
    payload = json.dumps({
        "from": f"Pineapple-Ops Report <{FROM_EMAIL}>",
        "to": [TO_EMAIL],
        "subject": f"[Pineapple-Ops] {'⚠️ ' if any(n['status'] != 'HEALTHY' for n in nodes_data) else ''}服务器监控日报 {today}",
        "html": html,
        "attachments": [{"filename": f"Pineapple-Ops-Report-{today}.pdf", "content": b64}]
    }).encode("utf-8")

    req = urllib.request.Request(
        "https://api.resend.com/emails",
        data=payload,
        headers={
            "Authorization": f"Bearer {RESEND_API_KEY}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f"Resend: {resp.read().decode()}")
    except urllib.error.HTTPError as e:
        print(f"邮件发送失败: {e.code} {e.read().decode()}")
    except Exception as e:
        print(f"邮件发送异常: {e}")

    shutil.rmtree(report_dir, ignore_errors=True)
    print("\n=== 完成 ===")

asyncio.run(main())
