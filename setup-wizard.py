#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================================
# Solar Monitor - Kurulum Sihirbazi (web)
# ----------------------------------------------------------------------------
# install.sh tarafindan baslatilir. Tarayicidan yedek .tgz yuklenir -> DB + ayar
# geri yuklenir -> tum stack ayaga kalkar. Ya da "sifirdan" baslatilir.
# Sadece stdlib (Raspberry Pi OS python3). Root olarak calisir (docker + dosya).
#   Ortam: SOLAR_DIR, SETUP_TOKEN, SETUP_PORT
# ============================================================================
import os, sys, hmac, ssl, subprocess, threading, secrets, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Konsol UTF-8 (Windows cp1252'de Türkçe print çökmesin; Linux'ta zaten UTF-8)
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SOLAR_DIR = os.environ.get("SOLAR_DIR", os.path.expanduser("~/solar-monitor"))
TOKEN     = os.environ.get("SETUP_TOKEN", "")
PORT      = int(os.environ.get("SETUP_PORT", "8888"))
STACK     = "solar.stack.yaml"

PAGE = """<!doctype html><html lang="tr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Solar Monitor - Kurulum</title><style>
:root{--bg0:#060910;--bg1:#0c1220;--panel:#131b2a;--line:rgba(255,255,255,.08);
--text:#eef3f8;--muted:#94a8bd;--solar:#fbbf24;--ok:#34d399;--crit:#f87171;--accent:#38bdf8}
*{box-sizing:border-box;margin:0;padding:0}body{min-height:100vh;color:var(--text);
font-family:system-ui,"Segoe UI",Roboto,sans-serif;background:
radial-gradient(1200px 700px at 85% -10%,rgba(56,189,248,.13),transparent 60%),
radial-gradient(1000px 600px at 5% 110%,rgba(251,191,36,.10),transparent 55%),
linear-gradient(165deg,var(--bg1),var(--bg0));display:flex;align-items:center;justify-content:center;padding:24px}
.card{width:min(760px,100%);background:var(--panel);border:1px solid var(--line);border-radius:20px;
padding:34px 38px;box-shadow:0 30px 80px rgba(0,0,0,.45);position:relative;overflow:hidden}
.card::before{content:"";position:absolute;inset:0 0 auto 0;height:1px;
background:linear-gradient(90deg,transparent,rgba(255,255,255,.18),transparent)}
.brand{display:flex;align-items:center;gap:16px;margin-bottom:8px}
.sun{width:46px;height:46px;border-radius:50%;background:radial-gradient(circle at 50% 40%,#ffd166,#f4a259 70%,#e07a1f);
box-shadow:0 0 30px rgba(244,162,89,.5)}
h1{font-size:1.7rem;font-weight:800}.sub{color:var(--muted);margin:6px 0 24px;font-size:.98rem;line-height:1.5}
label{display:block;color:var(--muted);font-size:.82rem;margin:16px 0 8px;letter-spacing:.04em;text-transform:uppercase}
input[type=text],input[type=password]{width:100%;font-size:1.1rem;color:var(--text);background:#0b1220;
border:2px solid var(--line);border-radius:12px;padding:14px 16px;outline:none}
input:focus{border-color:var(--accent)}
.drop{border:2px dashed rgba(148,168,189,.4);border-radius:14px;padding:26px;text-align:center;color:var(--muted);
cursor:pointer;transition:border-color .2s,background .2s}.drop:hover{border-color:var(--accent);background:rgba(56,189,248,.06)}
.drop.has{border-color:var(--ok);color:var(--text)}
.row{display:flex;gap:14px;margin-top:24px;flex-wrap:wrap}
button{flex:1;min-width:180px;font-size:1.05rem;font-weight:700;color:#06231f;border:0;border-radius:12px;
padding:16px;cursor:pointer;transition:transform .08s,filter .15s}
button.primary{background:linear-gradient(180deg,var(--solar),#f59e0b)}
button.ghost{background:transparent;color:var(--muted);border:2px solid var(--line)}
button:disabled{opacity:.5;cursor:not-allowed}button:active{transform:translateY(1px)}
#log{display:none;margin-top:22px;background:#05080f;border:1px solid var(--line);border-radius:12px;
padding:16px;font-family:ui-monospace,Consolas,monospace;font-size:.82rem;color:#b8c6d6;
white-space:pre-wrap;max-height:320px;overflow:auto;line-height:1.5}
.done{margin-top:20px;padding:16px;border-radius:12px;display:none}
.done.ok{display:block;background:rgba(52,211,153,.12);border:1px solid rgba(52,211,153,.4)}
.done.err{display:block;background:rgba(248,113,113,.12);border:1px solid rgba(248,113,113,.4)}
.done a{color:var(--accent);font-weight:700}
</style></head><body><div class="card">
<div class="brand"><div class="sun"></div><h1>Solar Monitor Kurulumu</h1></div>
<div class="sub">Yedeğini yükle; veritabanın + ayarların geri yüklenip tüm sistem ayağa kalksın.
Yedeğin yoksa sıfırdan da başlatabilirsin.</div>
<label for="tok">Tek-seferlik kod (terminalde gösterildi)</label>
<input id="tok" type="text" inputmode="text" autocomplete="off" placeholder="ör. a1b2c3d4e5f6">
<label>Yedek dosyası (solar-backup-*.tgz)</label>
<div class="drop" id="drop">Dosyayı buraya sürükle ya da tıkla seç<input id="file" type="file" accept=".tgz,.gz,.tar" hidden></div>
<div class="row">
<button class="primary" id="restore">Yedeği Yükle & Kur</button>
<button class="ghost" id="fresh">Sıfırdan Başlat (yedeksiz)</button>
</div>
<pre id="log"></pre>
<div class="done" id="done"></div>
</div><script>
var f=null;
var drop=document.getElementById('drop'),file=document.getElementById('file'),log=document.getElementById('log'),done=document.getElementById('done');
drop.onclick=function(){file.click()};
file.onchange=function(){if(file.files[0]){f=file.files[0];drop.classList.add('has');drop.textContent='✓ '+f.name+' ('+(f.size/1048576).toFixed(0)+' MB)';}};
['dragover','dragenter'].forEach(function(e){drop.addEventListener(e,function(ev){ev.preventDefault();drop.classList.add('has');});});
drop.addEventListener('drop',function(ev){ev.preventDefault();if(ev.dataTransfer.files[0]){f=ev.dataTransfer.files[0];file.files=ev.dataTransfer.files;drop.classList.add('has');drop.textContent='✓ '+f.name+' ('+(f.size/1048576).toFixed(0)+' MB)';}});
function tok(){return document.getElementById('tok').value.trim();}
function lock(){document.getElementById('restore').disabled=true;document.getElementById('fresh').disabled=true;log.style.display='block';log.textContent='';done.className='done';}
async function stream(url,body){lock();
 try{var res=await fetch(url,{method:'POST',body:body||null});
  var rd=res.body.getReader(),dec=new TextDecoder(),full='';
  while(true){var r=await rd.read();if(r.done)break;var t=dec.decode(r.value);full+=t;log.textContent+=t;log.scrollTop=log.scrollHeight;}
  if(full.indexOf('__SOLAR_OK__')>=0){done.className='done ok';done.innerHTML='✓ Kurulum tamam! Panele git: <a href="http://'+location.hostname+'/">http://'+location.hostname+'/</a> · TV panosu: <a href="http://'+location.hostname+'/tv/">/tv/</a>';}
  else{done.className='done err';done.textContent='✗ İşlem başarısız — yukarıdaki günlüğe bak.';document.getElementById('restore').disabled=false;document.getElementById('fresh').disabled=false;}
 }catch(e){done.className='done err';done.textContent='✗ Bağlantı hatası: '+e;document.getElementById('restore').disabled=false;document.getElementById('fresh').disabled=false;}
}
document.getElementById('restore').onclick=function(){
 if(!tok()){alert('Tek-seferlik kodu gir');return;}
 if(!f){alert('Önce yedek dosyasını seç');return;}
 stream('/restore?token='+encodeURIComponent(tok())+'&name='+encodeURIComponent(f.name),f);
};
document.getElementById('fresh').onclick=function(){
 if(!tok()){alert('Tek-seferlik kodu gir');return;}
 if(!confirm('Yedeksiz, boş bir sistem kurulacak. Emin misin?'))return;
 stream('/fresh?token='+encodeURIComponent(tok()),null);
};
</script></body></html>"""

def check_token(q):
    t = (urllib.parse.parse_qs(q).get("token", [""])[0])
    return TOKEN and hmac.compare_digest(t, TOKEN)

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def _stream_headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()

    def w(self, s):
        try:
            self.wfile.write(s.encode("utf-8", "replace")); self.wfile.flush()
        except Exception:
            pass

    def do_GET(self):
        if self.path.split("?")[0] in ("/", "/index.html"):
            body = PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        path, _, query = self.path.partition("?")
        if not check_token(query):
            self.send_error(403, "invalid token"); return
        if path == "/restore":
            self._restore(query)
        elif path == "/fresh":
            self._fresh()
        else:
            self.send_error(404)

    def _run(self, cmd, cwd=None, env=None):
        """Bir komutu calistir, ciktisini istemciye canli akit. Cikis kodunu dondur."""
        p = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, bufsize=1, universal_newlines=True)
        for line in p.stdout:
            self.w(line)
        p.wait()
        return p.returncode

    def _restore(self, query):
        self._stream_headers()
        name = urllib.parse.parse_qs(query).get("name", ["backup.tgz"])[0]
        self.w(">>> Yedek alınıyor: %s\n" % name)
        up = os.path.join(SOLAR_DIR, "upload.tgz")
        try:
            length = int(self.headers.get("Content-Length", 0))
            got = 0
            with open(up, "wb") as fh:
                while got < length:
                    chunk = self.rfile.read(min(1 << 20, length - got))
                    if not chunk: break
                    fh.write(chunk); got += len(chunk)
            self.w(">>> %d MB alındı, açılıyor...\n" % (got // 1048576))
            if got < 1024:
                self.w("HATA: yedek boş/eksik.\n"); return
            # bundle'ı SOLAR_DIR içine düz aç (üstteki solar-backup-* klasörünü at).
            # stack.yaml + restore.sh HARİÇ: install.sh'in indirdiği GÜNCEL repo sürümleri
            # kalsın (eski bir yedek NO_TS_TUNE fix'ini ezmesin). Yedek yalnız .env + veri verir.
            rc = self._run(["tar", "xzf", up, "-C", SOLAR_DIR, "--strip-components=1",
                            "--exclude=*/solar.stack.yaml", "--exclude=*/restore.sh"])
            if rc != 0:
                self.w("HATA: arşiv açılamadı (bozuk .tgz?).\n"); return
            os.remove(up)
            if not os.path.exists(os.path.join(SOLAR_DIR, "solar-db.bak")):
                self.w("HATA: yedek içinde solar-db.bak yok — bu bir Solar Monitor yedeği mi?\n"); return
            self.w(">>> Geri yükleme başlıyor (restore.sh)...\n\n")
            env = dict(os.environ)
            rc = self._run(["bash", "restore.sh"], cwd=SOLAR_DIR, env=env)
            if rc == 0:
                self.w("\n__SOLAR_OK__\n")
                threading.Timer(2.5, lambda: os._exit(0)).start()
            else:
                self.w("\nHATA: geri yükleme başarısız (kod %d).\n" % rc)
        except Exception as e:
            self.w("HATA: %s\n" % e)

    def _fresh(self):
        self._stream_headers()
        self.w(">>> Sıfırdan kurulum (yedeksiz)...\n")
        try:
            envf = os.path.join(SOLAR_DIR, ".env")
            if not os.path.exists(envf):
                pw = secrets.token_hex(16); adm = secrets.token_hex(6); jwt = secrets.token_hex(32)
                with open(envf, "w") as fh:
                    fh.write("POSTGRES_USER=solar\nPOSTGRES_DB=solar\nPOSTGRES_PASSWORD=%s\n"
                             "ADMIN_USERNAME=admin\nADMIN_PASSWORD=%s\nJWT_SECRET=%s\nLOG_LEVEL=info\n"
                             "HUB_USER=signorali\nTAG=latest\n" % (pw, adm, jwt))
                self.w(">>> Yeni .env üretildi. ADMIN parolası: %s  (NOT AL!)\n" % adm)
            os.makedirs(os.path.join(SOLAR_DIR, "proxy"), exist_ok=True)
            os.makedirs(os.path.join(SOLAR_DIR, "data", "postgres"), exist_ok=True)
            if os.path.exists(os.path.join(SOLAR_DIR, "Caddyfile")):
                subprocess.run(["cp", "Caddyfile", "proxy/Caddyfile"], cwd=SOLAR_DIR)
            rc = self._run(["docker", "compose", "-f", STACK, "up", "-d"], cwd=SOLAR_DIR, env=dict(os.environ))
            if rc == 0:
                self.w("\n__SOLAR_OK__\n")
                threading.Timer(2.5, lambda: os._exit(0)).start()
            else:
                self.w("\nHATA: stack başlatılamadı (kod %d).\n" % rc)
        except Exception as e:
            self.w("HATA: %s\n" % e)

def main():
    if not TOKEN:
        print("HATA: SETUP_TOKEN yok."); sys.exit(1)
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), H)
    print("Kurulum sihirbazı: http://0.0.0.0:%d  (kod ile)" % PORT)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
