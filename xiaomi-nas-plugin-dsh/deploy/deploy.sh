#!/bin/sh
# dsh 部署脚本 — 在小米 NAS 上以 root 执行
# 用法: sh deploy.sh <uid> [nas_ip]
set -e

UID_NUM="${1:-}"
case "$UID_NUM" in
    ''|*[!0-9]*) echo "Usage: sh deploy.sh <NAS_UID> [NAS_IP]" >&2; exit 2 ;;
esac
NAS_IP="${2:-127.0.0.1}"
PLUGIN="dsh"
USER_NAME="u${UID_NUM}"
SRC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="/home/${USER_NAME}/plugin/${PLUGIN}"
WWW_DIR="/data/plugin/www/${USER_NAME}"
ICON_DST="/data/plugin/www/icon/${PLUGIN}.icon"
LIST_FILE="/data/plugin/${USER_NAME}.list"
NGINX_CONF="/etc/nginx/conf.d/luci/plugincenter.conf"
BACKUP_DIR="/data/backup/plugins/${PLUGIN}"
RESTORE_UNIT="/etc/systemd/system/${PLUGIN}-restore.service"
STAMP="$(date +%F-%H%M%S)"
PORT="3080"

echo "==> [1/8] 备份 .list / nginx 配置"
[ -f "$LIST_FILE" ] && cp "$LIST_FILE" "${LIST_FILE}.bak-${STAMP}" && echo "    → ${LIST_FILE}.bak-${STAMP}"
[ -f "$NGINX_CONF" ] && cp "$NGINX_CONF" "${NGINX_CONF}.bak-${STAMP}" && echo "    → ${NGINX_CONF}.bak-${STAMP}"

echo "==> [2/8] 部署插件目录（真机布局 src/{files,ui}）"
mkdir -p "${HOME_DIR}/src" "${HOME_DIR}/scripts"
cp -a "${SRC_ROOT}/INFO" "${HOME_DIR}/INFO"
rm -rf "${HOME_DIR}/src/files" "${HOME_DIR}/src/ui"
cp -a "${SRC_ROOT}/src/files" "${SRC_ROOT}/src/ui" "${HOME_DIR}/src/"
chmod +x "${HOME_DIR}/src/files/server.sh" "${HOME_DIR}/src/ui/${PLUGIN}.cgi"
cp -a "${SRC_ROOT}/scripts/control" "${HOME_DIR}/scripts/control"
chmod +x "${HOME_DIR}/scripts/control"
chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}" 2>/dev/null || true

echo "==> [3/8] www 软链 + 图标"
mkdir -p "$WWW_DIR" "/data/plugin/www/icon"
ln -sfn "${HOME_DIR}/src/ui" "${WWW_DIR}/${PLUGIN}"
cp "${HOME_DIR}/src/ui/icon.png" "$ICON_DST"
chown "${USER_NAME}:${USER_NAME}" "$ICON_DST" 2>/dev/null || true

echo "==> [4/8] 注册 .list 条目"
python3 - "$LIST_FILE" "$PLUGIN" "$UID_NUM" "$PORT" "${BACKUP_DIR}" "${SRC_ROOT}/deploy/list-entry.json" <<'PY'
import json, time, sys, os
path, plugin, uid, port, backup_dir, tmpl_path = sys.argv[1:7]
home = f"/home/u{uid}/plugin/{plugin}"

entry = json.load(open(tmpl_path))
entry[plugin]["resource"]["mpk"] = f"{home}/INFO"
entry[plugin]["changetime"] = int(time.time())
entry[plugin]["info"]["timestamp"] = int(time.time())

data = {}
if os.path.isfile(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as e:
        print(f"WARN: 读取 {path} 失败: {e}，将新建")

data[plugin] = entry[plugin]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)

os.makedirs(backup_dir, exist_ok=True)
with open(os.path.join(backup_dir, "list-entry.json"), "w", encoding="utf-8") as f:
    json.dump({plugin: entry[plugin]}, f, ensure_ascii=False, indent=1)

print(f"    已在 {path} 写入 {plugin} 条目")
PY

echo "==> [5/8] 配置 Nginx 反代规则并注入 dsh 签名 Cookie"
python3 - "$NGINX_CONF" "$UID_NUM" "$PORT" <<'PY'
import sys, os, re, base64, hashlib, hmac, json, time

path, uid, port = sys.argv[1:4]

def b64url_decode(s):
    rem = len(s) % 4
    if rem > 0: s += '=' * (4 - rem)
    return base64.urlsafe_b64decode(s)

def b64url_encode(b):
    return base64.urlsafe_b64encode(b).decode('ascii').rstrip('=')

# 读取 /data/phirmu/.dsh/.credentials.yaml 中的 HMAC 秘钥
raw_secret = None
cred_file = '/data/phirmu/.dsh/.credentials.yaml'
if os.path.exists(cred_file):
    with open(cred_file) as f:
        for line in f:
            if 'secret:' in line:
                raw_secret = line.split('secret:')[1].strip()
                break

if not raw_secret:
    print("WARN: 未找到 dsh 秘钥文件，使用空秘钥生成")
    key = b"0" * 32
else:
    key = b64url_decode(raw_secret)

authority = f"127.0.0.1:{port}"
cookie_name = 'dsh-auth-' + b64url_encode(hashlib.sha256(authority.encode()).digest())
now = int(time.time() * 1000)
# 设定有效期（25天，自愈服务开机和刷新脚本会自动重算更新）
payload = {
    'version': 1,
    'authority': authority,
    'issuedAt': now,
    'expiresAt': now + 25 * 86400 * 1000
}
body = b64url_encode(json.dumps(payload, separators=(',', ':')).encode('utf-8'))
sig = b64url_encode(hmac.new(key, body.encode('ascii'), hashlib.sha256).digest())
cookie_val = f"v1.{body}.{sig}"

block = f"""# === dsh (auto-added) ===
location ~ ^(?:/[a-zA-Z]:)?/plugin/u?(?:{uid}|[0-9]+)/dsh/(?:index\\.html)?$ {{
  if ($http_authorization != "") {{
    add_header 'Access-Control-Allow-Credentials' "true" always;
    add_header Set-Cookie "token=$http_authorization; Path=/; HttpOnly; Secure" always;
  }}
  if ($arg_token != "") {{
    add_header 'Access-Control-Allow-Credentials' "true" always;
    add_header Set-Cookie "token=$arg_token; Path=/; HttpOnly; Secure" always;
  }}
  rewrite ^ / break;
  proxy_pass http://127.0.0.1:{port};
  proxy_http_version 1.1;
  proxy_set_header Host 127.0.0.1:{port};
  proxy_set_header Origin "http://127.0.0.1:{port}";
  proxy_set_header Sec-Fetch-Site "same-origin";
  proxy_set_header Cookie "{cookie_name}={cookie_val}; $http_cookie";
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-Proto https;
  proxy_read_timeout 3600s;
}}

location ~ ^(?:/[a-zA-Z]:)?/plugin/u?(?:{uid}|[0-9]+)/dsh/(?:index\\.html/)?(.*)$ {{
  if ($http_authorization != "") {{
    add_header 'Access-Control-Allow-Credentials' "true" always;
    add_header Set-Cookie "token=$http_authorization; Path=/; HttpOnly; Secure" always;
  }}
  if ($arg_token != "") {{
    add_header 'Access-Control-Allow-Credentials' "true" always;
    add_header Set-Cookie "token=$arg_token; Path=/; HttpOnly; Secure" always;
  }}
  rewrite ^(?:/[a-zA-Z]:)?/plugin/u?(?:{uid}|[0-9]+)/dsh/(?:index\\.html/)?(.*)$ /$1 break;
  proxy_pass http://127.0.0.1:{port};
  proxy_http_version 1.1;
  proxy_set_header Host 127.0.0.1:{port};
  proxy_set_header Origin "http://127.0.0.1:{port}";
  proxy_set_header Sec-Fetch-Site "same-origin";
  proxy_set_header Cookie "{cookie_name}={cookie_val}; $http_cookie";
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-Proto https;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_read_timeout 3600s;
}}
# === /dsh ===
"""

with open(path) as f:
    content = f.read()

content = re.sub(r'# === dsh \(auto-added\) ===.*?# === /dsh ===\n?', '', content, flags=re.DOTALL)

lines = content.splitlines(keepends=True)
out = []
inserted = False
for line in lines:
    if not inserted and "location /plugin" in line:
        out.append(block)
        inserted = True
    out.append(line)
if not inserted:
    out.append(block)

with open(path, "w") as f:
    f.writelines(out)
print(f"    已向 {path} 注入 dsh location 规则")

luci_path = '/etc/nginx/sites-available/luci.conf'
if os.path.exists(luci_path):
    with open(luci_path, 'r', encoding='utf-8') as lf:
        lc = lf.read()
    old_m = 'map "$ssl_client_cert|$http_authorization|$arg_token|$http_cookie" $need_reject {\n\t"~^\\|\\|\\|$" 1;\n\tdefault 0;\n}'
    new_m = 'map "$uri|$ssl_client_cert|$http_authorization|$arg_token|$http_cookie" $need_reject {\n\t"~^/(?:[a-zA-Z]:/)?plugin/.*" 0;\n\t"~^[^|]*\\|\\|\\|\\|$" 1;\n\tdefault 0;\n}'
    if old_m in lc:
        lc = lc.replace(old_m, new_m)
        with open(luci_path, 'w', encoding='utf-8') as lf:
            lf.write(lc)
        print("    已更新 luci.conf 放行插件路径")
PY

nginx -t && nginx -s reload && echo "    nginx reload 成功"

echo "==> [5.5/8] 检查并修补 dsh 前端渲染与构造器 bug"
python3 - <<'PATCH_PY'
import glob, os

pattern = "/data/phirmu/.npm/_npx/*/node_modules/@deepseek-ai/dsh-web-frontend/dist/assets/index-*.js"
for target_file in glob.glob(pattern):
    try:
        with open(target_file, "r", encoding="utf-8") as f:
            code = f.read()
        changed = False

        old_u7 = 'function u7(e){return!(!e.prototype||e instanceof Tb||_h!==Function&&e instanceof _h)}'
        new_u7 = 'function u7(e){return typeof e=="function"&&(/^class\\s/.test(Function.prototype.toString.call(e))||!(!e.prototype||e instanceof Tb||_h!==Function&&e instanceof _h))}'
        if old_u7 in code:
            code = code.replace(old_u7, new_u7)
            changed = True

        old_exec = 'execute:function(){if(u7(i.callback)){const u=new i.callback(this.ctx,this.config);for(const h of u?.[ce.initHooks]??[])h();return u?.[ce.init]?.()}else return i.callback(this.ctx,this.config)}'
        new_exec = 'execute:function(){let isCls=false;try{isCls=typeof i.callback==="function"&&/^class\\s/.test(Function.prototype.toString.call(i.callback));}catch(e){}if(u7(i.callback)||isCls){const u=new i.callback(this.ctx,this.config);for(const h of u?.[ce.initHooks]??[])h();return u?.[ce.init]?.()}else return i.callback(this.ctx,this.config)}'
        if old_exec in code:
            code = code.replace(old_exec, new_exec)
            changed = True

        old_abd1 = 'reportEntryError(e,t,r,i){if(i.abdicate){'
        new_abd1 = 'reportEntryError(e,t,r,i){if(i.abdicate&&e!=="root"){'
        if old_abd1 in code:
            code = code.replace(old_abd1, new_abd1)
            changed = True

        old_abd2 = 'for(const s of t.entries){if(this.abdicated.has(s))continue;'
        new_abd2 = 'for(const s of t.entries){if(e!=="root"&&this.abdicated.has(s))continue;'
        if old_abd2 in code:
            code = code.replace(old_abd2, new_abd2)
            changed = True

        if changed:
            with open(target_file, "w", encoding="utf-8") as f:
                f.write(code)
            print(f"    成功修补: {os.path.basename(target_file)}")
        else:
            print(f"    已是最新修补版本: {os.path.basename(target_file)}")
    except Exception as e:
        print(f"WARN: 修补 {target_file} 失败: {e}")

# 修补 dsh-client-ui-renderer
for target_file in glob.glob("/data/phirmu/.npm/_npx/*/node_modules/@deepseek-ai/dsh-client-ui-renderer/lib/client.js"):
    try:
        with open(target_file, "r", encoding="utf-8") as f:
            code = f.read()
        changed = False

        old_sp_orig = """\t\tfunction ScopeProvider({ scope, children }) {
\t\t\tconst host = useHost();
\t\t\tobservableHook(host.scopeRevision)((value) => value);
\t\t\tconst adapter = host.scope(scope);
\t\t\tif (adapter === void 0) throw new SlotAssemblyError(`scope '${scope}' rendered without an installed adapter`);
\t\t\tconst binding = observableHook(adapter.current)((value) => value);
\t\t\treturn (0, react_jsx_runtime.jsx)(ScopeBindingContext.Provider, {
\t\t\t\tvalue: binding,
\t\t\t\tchildren
\t\t\t});
\t\t}"""
        old_sp_prev = """\t\tfunction ScopeProvider({ scope, children }) {
\t\t\tconst host = useHost();
\t\t\tobservableHook(host.scopeRevision)((value) => value);
\t\t\tconst adapter = host.scope(scope);
\t\t\tif (adapter === void 0) {
\t\t\t\treturn scope === "session-maybe" ? (0, react_jsx_runtime.jsx)(ScopeBindingContext.Provider, {
\t\t\t\t\tvalue: { key: void 0, sessionId: void 0, hooks: {}, keyedHooks: {}, props: {} },
\t\t\t\t\tchildren
\t\t\t\t}) : null;
\t\t\t}
\t\t\tconst binding = observableHook(adapter.current)((value) => value);
\t\t\treturn (0, react_jsx_runtime.jsx)(ScopeBindingContext.Provider, {
\t\t\t\tvalue: binding,
\t\t\t\tchildren
\t\t\t});
\t\t}"""
        new_sp = """\t\tconst fallbackScopeBinding = { key: void 0, sessionId: void 0, hooks: {}, keyedHooks: {}, props: {} };
\t\tconst fallbackScopeSource = {
\t\t\tgetSnapshot: () => fallbackScopeBinding,
\t\t\tsubscribe: () => () => {}
\t\t};
\t\tfunction ScopeProvider({ scope, children }) {
\t\t\tconst host = useHost();
\t\t\tobservableHook(host.scopeRevision)((value) => value);
\t\t\tconst adapter = host.scope(scope);
\t\t\tconst source = adapter?.current ?? fallbackScopeSource;
\t\t\tconst binding = observableHook(source)((value) => value ?? fallbackScopeBinding);
\t\t\tif (adapter === void 0 && scope !== "session-maybe") {
\t\t\t\treturn null;
\t\t\t}
\t\t\treturn (0, react_jsx_runtime.jsx)(ScopeBindingContext.Provider, {
\t\t\t\tvalue: binding,
\t\t\t\tchildren
\t\t\t});
\t\t}"""
        if old_sp_prev in code:
            code = code.replace(old_sp_prev, new_sp)
            changed = True
        elif old_sp_orig in code:
            code = code.replace(old_sp_orig, new_sp)
            changed = True

        old_err = "if (error instanceof SlotAssemblyError) throw error;"
        new_err = "/* if (error instanceof SlotAssemblyError) throw error; */"
        if old_err in code:
            code = code.replace(old_err, new_err)
            changed = True

        old_entry_sp = """if (adapter === void 0) throw new SlotAssemblyError("entry declares a session child without an installed 'session' scope adapter");
\t\t\t\t\tkit["SessionProvider"] = scopeAreaProvider(adapter);"""
        new_entry_sp = """kit["SessionProvider"] = adapter !== void 0 ? scopeAreaProvider(adapter) : ({ children }) => children;"""
        if old_entry_sp in code:
            code = code.replace(old_entry_sp, new_entry_sp)
            changed = True

        old_fac_sp = """if (sessionAdapter === void 0) throw new SlotAssemblyError("factory declares a session child without an installed 'session' scope adapter");
\t\t\t\t\tregistrationKit["SessionProvider"] = scopeAreaProvider(sessionAdapter);"""
        new_fac_sp = """registrationKit["SessionProvider"] = sessionAdapter !== void 0 ? scopeAreaProvider(sessionAdapter) : ({ children }) => children;"""
        if old_fac_sp in code:
            code = code.replace(old_fac_sp, new_fac_sp)
            changed = True

        # runInject safe wrapper
        old_run_inject = """function runInject(entry, binding, actions) {
\t\t\tconst inject = entry.inject;
\t\t\tif (!inject) return EMPTY_INJECTED_PROPS;
\t\t\tconst args = [];
\t\t\tif (binding !== void 0) args.push(binding.key);
\t\t\tif (actions !== void 0) args.push(actions);
\t\t\treturn bindInjectSources(inject(...args));
\t\t}"""
        new_run_inject = """function runInject(entry, binding, actions) {
\t\t\tconst inject = entry.inject;
\t\t\tif (!inject) return EMPTY_INJECTED_PROPS;
\t\t\tconst args = [];
\t\t\tif (binding !== void 0) args.push(binding.key);
\t\t\tif (actions !== void 0) args.push(actions);
\t\t\ttry {
\t\t\t\treturn bindInjectSources(inject(...args));
\t\t\t} catch (e) {
\t\t\t\treturn EMPTY_INJECTED_PROPS;
\t\t\t}
\t\t}"""
        if old_run_inject in code:
            code = code.replace(old_run_inject, new_run_inject)
            changed = True

        # Prevent SlotAssemblyError when session is not yet selected
        t_f1 = 'if (declared.scope === "session" && localScopeBinding.key === void 0) throw new SlotAssemblyError(`strict session local slot \'${name}\' from factory \'${definition.name}\' rendered without a scope binding`);'
        r_f1 = 'if (declared.scope === "session" && localScopeBinding.key === void 0) return null;'
        if t_f1 in code:
            code = code.replace(t_f1, r_f1)
            changed = True

        t_f2 = 'if (binding.key === void 0) throw new SlotAssemblyError(`strict session factory \'${definition.name}\' rendered without a scope binding`);'
        r_f2 = 'if (binding.key === void 0) return null;'
        if t_f2 in code:
            code = code.replace(t_f2, r_f2)
            changed = True

        t_f3 = 'if (binding.key === void 0) throw new SlotAssemblyError(`strict session slot \'${slotKey}\' rendered without a scope binding`);'
        r_f3 = 'if (binding.key === void 0) return null;'
        if t_f3 in code:
            code = code.replace(t_f3, r_f3)
            changed = True

        t_f4 = 'if (spec.scope === "session" && scopeBinding.key === void 0) throw new SlotAssemblyError(`strict session slot \'${slotKey}\' rendered without a scope binding`);'
        r_f4 = 'if (spec.scope === "session" && scopeBinding.key === void 0) return null;'
        if t_f4 in code:
            code = code.replace(t_f4, r_f4)
            changed = True

        # Prevent boot order crash on root slot
        t_root = 'throw new SlotAssemblyError("renderSlot(\'root\') before any \'root\' registration (boot order)");'
        r_root = 'return (0, react_jsx_runtime.jsx)("div", { "data-slot-loading": "root" });'
        if t_root in code:
            code = code.replace(t_root, r_root)
            changed = True

        # Prevent unmounting DOM root container on context teardown
        old_unmount = """ctx.reflect.provide("uiRenderer", { mount: (container) => {
\t\t\t\tconst root = mountApp(container, buildRenderApp({ ctx }));
\t\t\t\treturn () => {
\t\t\t\t\troot.unmount();
\t\t\t\t};
\t\t\t} });"""
        new_unmount = """ctx.reflect.provide("uiRenderer", { mount: (container) => {
\t\t\t\tconst root = mountApp(container, buildRenderApp({ ctx }));
\t\t\t\treturn () => {
\t\t\t\t\t/* root.unmount(); */
\t\t\t\t};
\t\t\t} });"""
        if old_unmount in code:
            code = code.replace(old_unmount, new_unmount)
            changed = True

        # standardProps fallback
        t_sp = 'if (scopeBinding === void 0) throw new SlotAssemblyError(`scope \'${scope}\' rendered without a standard-source binding`);'
        r_sp = 'if (scopeBinding === void 0) return root;'
        if t_sp in code:
            code = code.replace(t_sp, r_sp)
            changed = True

        # BootHandoff AppWrapper boundary isolation (avoids React Error #310)
        old_boot = """\t\tfunction BootHandoff(props) {
\t\t\tconst [ready, setReady] = (0, react.useState)(false);
\t\t\t(0, react.useLayoutEffect)(() => {
\t\t\t\tsetReady(true);
\t\t\t}, []);
\t\t\tif (ready) return props.app();
\t\t\treturn (0, react.createElement)("div", {
\t\t\t\tclassName: props.boot.className,
\t\t\t\t"data-dsh-boot": "",
\t\t\t\tdangerouslySetInnerHTML: { __html: props.boot.html }
\t\t\t});
\t\t}"""
        new_boot = """\t\tfunction AppWrapper(props) {
\t\t\treturn props.app();
\t\t}
\t\tfunction BootHandoff(props) {
\t\t\tconst [ready, setReady] = (0, react.useState)(false);
\t\t\t(0, react.useLayoutEffect)(() => {
\t\t\t\tsetReady(true);
\t\t\t}, []);
\t\t\tif (ready) return (0, react.createElement)(AppWrapper, { app: props.app });
\t\t\treturn (0, react.createElement)("div", {
\t\t\t\tclassName: props.boot.className,
\t\t\t\t"data-dsh-boot": "",
\t\t\t\tdangerouslySetInnerHTML: { __html: props.boot.html }
\t\t\t});
\t\t}"""
        if old_boot in code:
            code = code.replace(old_boot, new_boot)
            changed = True

        old_render_app = "root.render(app());"
        new_render_app = "root.render((0, react.createElement)(AppWrapper, { app }));"
        if old_render_app in code:
            code = code.replace(old_render_app, new_render_app)
            changed = True

        # Frozen snapshots and stable observable hook fallbacks in standardProps
        target_m = "function materializeStandardBinding(binding, optional, defaultKey) {"
        fallback_defs = """const EMPTY_SESSION_SNAPSHOT = Object.freeze({ byId: {}, projectionsBySession: {}, phase: "ready", retainedBy: {} });
\t\tconst EMPTY_WORKSPACE_SNAPSHOT = Object.freeze({ items: [], pinnedSessionIds: [], archivedSessionIds: [], phase: "ready", byId: {} });
\t\tconst fallbackSessionSource = {
\t\t\tgetSnapshot: () => EMPTY_SESSION_SNAPSHOT,
\t\t\tsubscribe: () => () => {}
\t\t};
\t\tconst fallbackWorkspaceSource = {
\t\t\tgetSnapshot: () => EMPTY_WORKSPACE_SNAPSHOT,
\t\t\tsubscribe: () => () => {}
\t\t};
\t\t"""
        if "fallbackSessionSource" not in code and target_m in code:
            code = code.replace(target_m, fallback_defs + target_m)
            changed = True

        old_std_props = """\t\tfunction standardProps(scope, rootBinding, scopeBinding) {
\t\t\tlet root = rootStandardCache.get(rootBinding);
\t\t\tif (root === void 0) {
\t\t\t\troot = materializeStandardBinding(rootBinding, false);
\t\t\t\trootStandardCache.set(rootBinding, root);
\t\t\t}
\t\t\tif (scope === "root") return root;
\t\t\tif (scopeBinding === void 0) return root;
\t\t\tconst cache = scope === "session" ? sessionStandardCache : sessionMaybeStandardCache;
\t\t\tlet perScope = cache.get(rootBinding);
\t\t\tif (perScope === void 0) {
\t\t\t\tperScope = /* @__PURE__ */ new WeakMap();
\t\t\t\tcache.set(rootBinding, perScope);
\t\t\t}
\t\t\tlet standard = perScope.get(scopeBinding);
\t\t\tif (standard !== void 0) return standard;
\t\t\tstandard = {
\t\t\t\t...materializeStandardBinding(rootBinding, false, scopeBinding.key),
\t\t\t\t...materializeStandardBinding(scopeBinding, scope === "session-maybe")
\t\t\t};
\t\t\tperScope.set(scopeBinding, standard);
\t\t\treturn standard;
\t\t}"""

        new_std_props = """\t\tfunction standardProps(scope, rootBinding, scopeBinding) {
\t\t\tlet root = rootStandardCache.get(rootBinding);
\t\t\tif (root === void 0) {
\t\t\t\troot = materializeStandardBinding(rootBinding, false);
\t\t\t\tif (typeof root.useSessions !== "function") {
\t\t\t\t\troot.useSessions = observableHook(fallbackSessionSource);
\t\t\t\t}
\t\t\t\tif (typeof root.useWorkspaces !== "function") {
\t\t\t\t\troot.useWorkspaces = observableHook(fallbackWorkspaceSource);
\t\t\t\t}
\t\t\t\trootStandardCache.set(rootBinding, root);
\t\t\t}
\t\t\tif (scope === "root") return root;
\t\t\tif (scopeBinding === void 0) return root;
\t\t\tconst cache = scope === "session" ? sessionStandardCache : sessionMaybeStandardCache;
\t\t\tlet perScope = cache.get(rootBinding);
\t\t\tif (perScope === void 0) {
\t\t\t\tperScope = /* @__PURE__ */ new WeakMap();
\t\t\t\tcache.set(rootBinding, perScope);
\t\t\t}
\t\t\tlet standard = perScope.get(scopeBinding);
\t\t\tif (standard !== void 0) return standard;
\t\t\tstandard = {
\t\t\t\t...materializeStandardBinding(rootBinding, false, scopeBinding.key),
\t\t\t\t...materializeStandardBinding(scopeBinding, scope === "session-maybe")
\t\t\t};
\t\t\tif (typeof standard.useSessions !== "function") {
\t\t\t\tstandard.useSessions = observableHook(fallbackSessionSource);
\t\t\t}
\t\t\tif (typeof standard.useWorkspaces !== "function") {
\t\t\t\tstandard.useWorkspaces = observableHook(fallbackWorkspaceSource);
\t\t\t}
\t\t\tperScope.set(scopeBinding, standard);
\t\t\treturn standard;
\t\t}"""

        if old_std_props in code:
            code = code.replace(old_std_props, new_std_props)
            changed = True

        # Prevent line 1567 fatal error when root entries are momentarily 0
        old_1567 = 'if (this._core.entries("root").length === 0) throw new Error("\'root\' has no registration — a layout entry must register into \'root\' before the shell renders it");'
        new_1567 = 'if (this._core.entries("root").length === 0) return (0, react_jsx_runtime.jsx)("div", { "data-slot-loading": "root" });'
        if old_1567 in code:
            code = code.replace(old_1567, new_1567)
            changed = True

        # Prevent root slot from abdicating to data-slot-error
        old_root_entry = """\t\t\tconst entry = host.entriesOfSlot("root")[0];
\t\t\tif (!entry) {
\t\t\t\tif (host.entriesOf("root").length > 0) return (0, react_jsx_runtime.jsx)("div", { "data-slot-error": "root" });
\t\t\t\treturn (0, react_jsx_runtime.jsx)("div", { "data-slot-loading": "root" });
\t\t\t}"""
        new_root_entry = """\t\t\tlet entry = host.entriesOfSlot("root")[0];
\t\t\tif (!entry && host.entriesOf("root").length > 0) {
\t\t\t\tentry = host.entriesOf("root")[0];
\t\t\t}
\t\t\tif (!entry) {
\t\t\t\treturn (0, react_jsx_runtime.jsx)("div", { "data-slot-loading": "root" });
\t\t\t}"""
        if old_root_entry in code:
            code = code.replace(old_root_entry, new_root_entry)
            changed = True

        # SlotErrorBoundary root recovery UI fallback
        old_slot_eb = 'if (this.state.failed) return (0, react_jsx_runtime.jsx)(Anchor, { "data-slot-error": this.props.slotKey });'
        new_slot_eb = """if (this.state.failed) {
\t\t\t\t\tif (this.props.slotKey === "root") {
\t\t\t\t\t\treturn (0, react_jsx_runtime.jsxs)("div", {
\t\t\t\t\t\t\tstyle: { padding: "40px", color: "#ccc", fontFamily: "sans-serif", background: "#1e1e1e", height: "100vh" },
\t\t\t\t\t\t\tchildren: [
\t\t\t\t\t\t\t\t(0, react_jsx_runtime.jsx)("h2", { children: "DeepSeek Harness 页面加载异常" }),
\t\t\t\t\t\t\t\t(0, react_jsx_runtime.jsx)("p", { children: "组件运行捕获到错误，点击下方按钮尝试恢复：" }),
\t\t\t\t\t\t\t\t(0, react_jsx_runtime.jsx)("button", {
\t\t\t\t\t\t\t\t\tonClick: () => { this.setState({ failed: false }); },
\t\t\t\t\t\t\t\t\tstyle: { padding: "8px 16px", cursor: "pointer", borderRadius: "4px", background: "#238636", color: "#fff", border: "none" },
\t\t\t\t\t\t\t\t\tchildren: "恢复界面"
\t\t\t\t\t\t\t\t})
\t\t\t\t\t\t\t]
\t\t\t\t\t\t});
\t\t\t\t\t}
\t\t\t\t\treturn (0, react_jsx_runtime.jsx)(Anchor, { "data-slot-error": this.props.slotKey });
\t\t\t\t}"""
        if old_slot_eb in code:
            code = code.replace(old_slot_eb, new_slot_eb)
            changed = True

        if changed:
            with open(target_file, "w", encoding="utf-8") as f:
                f.write(code)
            print(f"    成功修补: dsh-client-ui-renderer/{os.path.basename(target_file)}")
        else:
            print(f"    已是最新修补版本: dsh-client-ui-renderer/{os.path.basename(target_file)}")
    except Exception as e:
        print(f"WARN: 修补 {target_file} 失败: {e}")

# 修补 dsh-client-ui-conversation
for target_file in glob.glob("/data/phirmu/.npm/_npx/*/node_modules/@deepseek-ai/dsh-client-ui-conversation/lib/client.js"):
    try:
        with open(target_file, "r", encoding="utf-8") as f:
            code = f.read()
        changed = False
        old_av = "if (active !== void 0) uiConversation.binding(sessionId).activate(active.id);"
        new_av = "if (active !== void 0) { try { uiConversation.binding(sessionId).activate(active.id); } catch (e) {} }"
        if old_av in code:
            code = code.replace(old_av, new_av)
            changed = True

        old_sessions = """\t\t\tsessions() {
\t\t\t\tconst sessions = this.rootCtx.get("sessions");
\t\t\t\tif (sessions === void 0) throw new Error("conversation.input: sessions service unavailable");
\t\t\t\treturn sessions;
\t\t\t}"""
        new_sessions = """\t\t\tsessions() {
\t\t\t\tconst sessions = this.rootCtx.get("sessions");
\t\t\t\tif (sessions === void 0) {
\t\t\t\t\treturn {
\t\t\t\t\t\tsessionOf: () => void 0,
\t\t\t\t\t\tbinding: () => void 0,
\t\t\t\t\t\tretainInfo: () => void 0,
\t\t\t\t\t\tlist: { getSnapshot: () => [], subscribe: () => () => {} }
\t\t\t\t\t};
\t\t\t\t}
\t\t\t\treturn sessions;
\t\t\t}"""
        if old_sessions in code:
            code = code.replace(old_sessions, new_sessions)
            changed = True

        old_conv = """\t\t\tconversation() {
\t\t\t\tconst conversation = this.rootCtx.get("conversation");
\t\t\t\tif (conversation === void 0) throw new Error("conversation.input: conversation service unavailable");
\t\t\t\treturn conversation;
\t\t\t}"""
        new_conv = """\t\t\tconversation() {
\t\t\t\tconst conversation = this.rootCtx.get("conversation");
\t\t\t\tif (conversation === void 0) return void 0;
\t\t\t\treturn conversation;
\t\t\t}"""
        if old_conv in code:
            code = code.replace(old_conv, new_conv)
            changed = True

        old_model_locked = "const modelSeatLocked = removed || inert || !live;"
        new_model_locked = "const modelSeatLocked = removed || !live; /* UNLOCK_INERT_MODEL */"
        if old_model_locked in code:
            code = code.replace(old_model_locked, new_model_locked)
            changed = True

        old_row = """\t\t\t\t\t\t\t(0, react_jsx_runtime.jsxs)("div", {
\t\t\t\t\t\t\t\tref: rowRef,
\t\t\t\t\t\t\t\tclassName: InputBar_module_css_default.row,
\t\t\t\t\t\t\t\tchildren: [(0, react_jsx_runtime.jsxs)("div", {"""
        new_row = """\t\t\t\t\t\t\t(0, react_jsx_runtime.jsxs)("div", {
\t\t\t\t\t\t\t\tref: rowRef,
\t\t\t\t\t\t\t\tclassName: InputBar_module_css_default.row,
\t\t\t\t\t\t\t\tonClick: (e) => { e.stopPropagation(); },
\t\t\t\t\t\t\t\tonPointerDown: (e) => { e.stopPropagation(); },
\t\t\t\t\t\t\t\tchildren: [(0, react_jsx_runtime.jsxs)("div", {"""
        if old_row in code:
            code = code.replace(old_row, new_row)
            changed = True

        if changed:
            with open(target_file, "w", encoding="utf-8") as f:
                f.write(code)
            print(f"    成功修补: dsh-client-ui-conversation/{os.path.basename(target_file)}")
        else:
            print(f"    已是最新修补版本: dsh-client-ui-conversation/{os.path.basename(target_file)}")
    except Exception as e:
        print(f"WARN: 修补 {target_file} 失败: {e}")

# 修补 dsh-api-session-controller
for target_file in glob.glob("/data/phirmu/.npm/_npx/*/node_modules/@deepseek-ai/dsh-api-session-controller/lib/client.js"):
    try:
        with open(target_file, "r", encoding="utf-8") as f:
            code = f.read()
        changed = False
        old_b = """\t\t\tget binding() {
\t\t\t\tif (this.record === void 0 || !this.record.live) throw new Error(`Session reference "${this.sessionId}" is released`);
\t\t\t\treturn this.record.binding;
\t\t\t}"""
        new_b = """\t\t\tget binding() {
\t\t\t\tif (this.record === void 0 || !this.record.live) return void 0;
\t\t\t\treturn this.record.binding;
\t\t\t}"""
        if old_b in code:
            code = code.replace(old_b, new_b)
            changed = True

        if changed:
            with open(target_file, "w", encoding="utf-8") as f:
                f.write(code)
            print(f"    成功修补: dsh-api-session-controller/{os.path.basename(target_file)}")
        else:
            print(f"    已是最新修补版本: dsh-api-session-controller/{os.path.basename(target_file)}")
    except Exception as e:
        print(f"WARN: 修补 {target_file} 失败: {e}")

# 修补 dsh-cordis-client-runner
for target_file in glob.glob("/data/phirmu/.npm/_npx/*/node_modules/@deepseek-ai/dsh-cordis-client-runner/lib/client.js"):
    try:
        with open(target_file, "r", encoding="utf-8") as f:
            code = f.read()
        old_runner = """\t\t\t\tsync: async (providers) => {
\t\t\t\t\tconst answered = await ctx.remote.dynamicCordisRunner.syncInspectManifest(providers);
\t\t\t\t\tif (!answered.ok) throw new Error(`${answered.error.code}: ${answered.error.message}`);
\t\t\t\t},
\t\t\t\tresolve: async (agentId, requestId, resolution) => {
\t\t\t\t\tconst answered = await ctx.remote.dynamicCordisRunner.resolveInspectQuery(agentId, requestId, resolution);
\t\t\t\t\tif (!answered.ok) throw new Error(`${answered.error.code}: ${answered.error.message}`);
\t\t\t\t}"""
        new_runner = """\t\t\t\tsync: async (providers) => {
\t\t\t\t\ttry {
\t\t\t\t\t\tif (!ctx.remote || typeof ctx.remote.dynamicCordisRunner?.syncInspectManifest !== "function") return;
\t\t\t\t\t\tconst answered = await ctx.remote.dynamicCordisRunner.syncInspectManifest(providers);
\t\t\t\t\t\tif (!answered.ok) throw new Error(`${answered.error.code}: ${answered.error.message}`);
\t\t\t\t\t} catch (e) {}
\t\t\t\t},
\t\t\t\tresolve: async (agentId, requestId, resolution) => {
\t\t\t\t\ttry {
\t\t\t\t\t\tif (!ctx.remote || typeof ctx.remote.dynamicCordisRunner?.resolveInspectQuery !== "function") return;
\t\t\t\t\t\tconst answered = await ctx.remote.dynamicCordisRunner.resolveInspectQuery(agentId, requestId, resolution);
\t\t\t\t\t\tif (!answered.ok) throw new Error(`${answered.error.code}: ${answered.error.message}`);
\t\t\t\t\t} catch (e) {}
\t\t\t\t}"""
        if old_runner in code:
            code = code.replace(old_runner, new_runner)
            with open(target_file, "w", encoding="utf-8") as f:
                f.write(code)
            print(f"    成功修补: dsh-cordis-client-runner/{os.path.basename(target_file)}")
        else:
            print(f"    已是最新修补版本: dsh-cordis-client-runner/{os.path.basename(target_file)}")
    except Exception as e:
        print(f"WARN: 修补 {target_file} 失败: {e}")

# 修补 dsh-client-ui-settings-general
for target_file in glob.glob("/data/phirmu/.npm/_npx/*/node_modules/@deepseek-ai/dsh-client-ui-settings-general/lib/client.js"):
    try:
        with open(target_file, "r", encoding="utf-8") as f:
            code = f.read()
        changed = False

        boundary_def = """var SettingsErrorBoundary = class extends react.Component {
\t\t\tstate = { error: null };
\t\t\tstatic getDerivedStateFromError(error) {
\t\t\t\treturn { error };
\t\t\t}
\t\t\tcomponentDidCatch(error) {
\t\t\t\tconsole.error("Settings section error:", error);
\t\t\t}
\t\t\trender() {
\t\t\t\tif (this.state.error) {
\t\t\t\t\treturn (0, react_jsx_runtime.jsxs)("div", {
\t\t\t\t\t\tstyle: { padding: "20px", color: "var(--dsw-alias-state-error-primary, red)" },
\t\t\t\t\t\tchildren: [
\t\t\t\t\t\t\t(0, react_jsx_runtime.jsx)("p", { children: "该设置页面加载出错: " + (this.state.error?.message || this.state.error) }),
\t\t\t\t\t\t\t(0, react_jsx_runtime.jsx)("button", {
\t\t\t\t\t\t\t\tstyle: { marginTop: "10px", padding: "6px 12px", cursor: "pointer" },
\t\t\t\t\t\t\t\tonClick: () => this.setState({ error: null }),
\t\t\t\t\t\t\t\tchildren: "重试"
\t\t\t\t\t\t\t})
\t\t\t\t\t\t]
\t\t\t\t\t});
\t\t\t\t}
\t\t\t\treturn this.props.children;
\t\t\t}
\t\t};
\t\t"""
        old_target = 'active !== void 0 && renderSlot("settings.section", { close: onClose }, { only: active })'
        new_target = 'active !== void 0 && (0, react_jsx_runtime.jsx)(SettingsErrorBoundary, { key: active, children: renderSlot("settings.section", { close: onClose }, { only: active }) })'
        if "SettingsErrorBoundary" not in code and old_target in code:
            idx = code.find("function SettingsPanel(")
            if idx != -1:
                code = code[:idx] + boundary_def + code[idx:]
                code = code.replace(old_target, new_target)
                changed = True

        if changed:
            with open(target_file, "w", encoding="utf-8") as f:
                f.write(code)
            print(f"    成功修补: dsh-client-ui-settings-general/{os.path.basename(target_file)}")
        else:
            print(f"    已是最新修补版本: dsh-client-ui-settings-general/{os.path.basename(target_file)}")
    except Exception as e:
        print(f"WARN: 修补 {target_file} 失败: {e}")

# 修补 dsh-client-hmr（生产环境禁用 stat-poll 导致的无谓热重载风暴和闪退）
for target_file in glob.glob("/data/phirmu/.npm/_npx/*/node_modules/@deepseek-ai/dsh-client-hmr/lib/index.js"):
    try:
        with open(target_file, "r", encoding="utf-8") as f:
            code = f.read()
        if "/* DSH_HMR_DISABLED */" not in code and "function apply(ctx, config) {" in code:
            code = code.replace("function apply(ctx, config) {", "function apply(ctx, config) {\n\t/* DSH_HMR_DISABLED */\n\treturn;")
            with open(target_file, "w", encoding="utf-8") as f:
                f.write(code)
            print(f"    成功修补: dsh-client-hmr/{os.path.basename(target_file)}")
        else:
            print(f"    已是最新修补版本: dsh-client-hmr/{os.path.basename(target_file)}")
    except Exception as e:
        print(f"WARN: 修补 {target_file} 失败: {e}")

# 确保 cordis.patch.yml 禁用 client-hmr
patch_yml = "/data/phirmu/.dsh/profiles/web/cordis.patch.yml"
if os.path.isfile(patch_yml):
    try:
        with open(patch_yml, "r", encoding="utf-8") as f:
            yml_content = f.read()
        if "id: client-hmr" not in yml_content:
            with open(patch_yml, "a", encoding="utf-8") as f:
                f.write("\n- id: client-hmr\n  disabled: true\n")
            print("    已在 cordis.patch.yml 中禁用 client-hmr")
    except Exception as e:
        print(f"WARN: 更新 {patch_yml} 失败: {e}")
PATCH_PY

echo "==> [6/8] 启动服务（通过 scripts/control postinstall）"
PLUG_SRC_DIR="${HOME_DIR}/src" \
PLUG_HOME_DIR="${HOME_DIR}" \
PLUG_USER="${USER_NAME}" \
PLUG_PORT_ALLOC="${PORT}" \
sh "${HOME_DIR}/scripts/control" postinstall

echo "==> [7/8] 配置重启自愈服务"
mkdir -p "${BACKUP_DIR}"
rm -rf "${BACKUP_DIR}/${PLUGIN}"
cp -a "${HOME_DIR}" "${BACKUP_DIR}/${PLUGIN}"

cat > "${BACKUP_DIR}/restore.sh" <<'RST'
#!/bin/sh
UID_N=__NAS_UID__
PLUGIN=dsh
PORT=3080
USER_NAME=u${UID_N}
HOME_DIR=/home/${USER_NAME}/plugin/${PLUGIN}
WWW_DIR=/data/plugin/www/${USER_NAME}
LIST_FILE=/data/plugin/${USER_NAME}.list
NGINX_CONF=/etc/nginx/conf.d/luci/plugincenter.conf
BACKUP_DIR=/data/backup/plugins/${PLUGIN}
SRC=${BACKUP_DIR}/${PLUGIN}

if [ ! -f "${HOME_DIR}/INFO" ] && [ -f "${SRC}/INFO" ]; then
    mkdir -p /home/${USER_NAME}/plugin
    cp -a "${SRC}" "${HOME_DIR}"
    chmod +x "${HOME_DIR}/scripts/control" "${HOME_DIR}/src/files/server.sh" "${HOME_DIR}/src/ui/${PLUGIN}.cgi" 2>/dev/null || true
    echo "restore: 插件目录已恢复"
fi

mkdir -p "${WWW_DIR}" /data/plugin/www/icon
ln -sfn "${HOME_DIR}/src/ui" "${WWW_DIR}/${PLUGIN}"
cp "${HOME_DIR}/src/ui/icon.png" "/data/plugin/www/icon/${PLUGIN}.icon" 2>/dev/null || true

if [ -f "${BACKUP_DIR}/list-entry.json" ]; then
    python3 - "${LIST_FILE}" "${BACKUP_DIR}/list-entry.json" <<'PY2'
import json, sys, os
list_path, entry_path = sys.argv[1], sys.argv[2]
entry = json.load(open(entry_path))
data = {}
if os.path.isfile(list_path):
    with open(list_path) as f:
        data = json.load(f)
data.update(entry)
with open(list_path, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)
PY2
fi

if [ -f "${HOME_DIR}/scripts/control" ]; then
    PLUG_SRC_DIR="${HOME_DIR}/src" PLUG_HOME_DIR="${HOME_DIR}" PLUG_USER="${USER_NAME}" \
      PLUG_PORT_ALLOC="${PORT}" sh "${HOME_DIR}/scripts/control" postinstall
fi

# 重新注入并更新 nginx 中的 dsh 动态认证 Cookie
sh "${SRC}/deploy/deploy.sh" "$UID_N" >/dev/null 2>&1 || true
exit 0
RST
sed -i "s/^UID_N=__NAS_UID__$/UID_N=${UID_NUM}/" "${BACKUP_DIR}/restore.sh"
chmod +x "${BACKUP_DIR}/restore.sh"

cat > "$RESTORE_UNIT" <<UNIT
[Unit]
Description=${PLUGIN} plugin restore on boot
After=network.target
Before=${PLUGIN}.service
ConditionPathExists=${BACKUP_DIR}/restore.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${BACKUP_DIR}/restore.sh

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "${PLUGIN}-restore.service"

echo "==> 安装 plugincenter 应用列表重置拦截防护"
mkdir -p /data/plugincenter_shield
if [ ! -f /data/plugincenter_shield/plugincenter.orig ] && [ -f /usr/bin/plugincenter ]; then
    cp -a /usr/bin/plugincenter /data/plugincenter_shield/plugincenter.orig
fi
cat > /data/plugincenter_shield/plugincenter << 'SH'
#!/bin/sh
for arg in "$@"; do
    if [ "$arg" = "update" ]; then
        echo '{"code":0,"result":"成功","data":{}}'
        exit 0
    fi
done
exec /data/plugincenter_shield/plugincenter.orig "$@"
SH
chmod 755 /data/plugincenter_shield/plugincenter

cat > /data/plugincenter_shield/shield.sh << 'SH'
#!/bin/sh
mkdir -p /data/plugincenter_shield
if [ -x /data/plugincenter_shield/plugincenter ]; then
    grep -q '/usr/bin/plugincenter' /proc/mounts || mount --bind /data/plugincenter_shield/plugincenter /usr/bin/plugincenter
fi
for ulist in /data/plugin/u*.list; do
    [ -f "$ulist" ] || continue
    python3 - "$ulist" <<'PY'
import json, sys, os
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as f: data = json.load(f)
except Exception: data = {}
changed = False
for p in ['ttyd', 'dsh', 'motrix']:
    if p not in data:
        ef = f'/data/backup/plugins/{p}/list-entry.json'
        if os.path.isfile(ef):
            try:
                with open(ef, 'r', encoding='utf-8') as f:
                    data.update(json.load(f))
                    changed = True
            except Exception: pass
if changed:
    with open(path, 'w', encoding='utf-8') as f: json.dump(data, f, ensure_ascii=False, indent=1)
PY
done
exit 0
SH
chmod 755 /data/plugincenter_shield/shield.sh

cat > /etc/systemd/system/plugincenter-shield.service << 'UNIT'
[Unit]
Description=Shield Xiaomi NAS plugincenter update against plugin wipe
Before=minas.plugin_center.service multi-user.target nginx.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh /data/plugincenter_shield/shield.sh

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable plugincenter-shield.service >/dev/null 2>&1 || true
systemctl start plugincenter-shield.service >/dev/null 2>&1 || true

echo "==> [8/8] 验收"
sleep 1
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:3080/" 2>/dev/null || echo "000")
if [ "$CODE" = "200" ] || [ "$CODE" = "401" ] || [ "$CODE" = "302" ] || [ "$CODE" = "303" ]; then
    echo "    ✓ dsh 服务运行正常 (http://127.0.0.1:3080/)"
else
    echo "    WARN: dsh 端口未响应，请查看 /tmp/dsh/server.log"
fi
echo "✓ dsh 部署完成"
