"""도서관 홈페이지의 좌석 도면을 앱용 좌표 JSON(assets/layouts/rNN.json)으로 만든다.

사이트의 Angular 템플릿과 CSS 를 그대로 headless Edge/Chrome 에 올려서 각 좌석의 위치/크기/색을 측정한다.
사이트가 바뀌면 다시 실행하면 된다:  python tools/gen_layouts.py
"""
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

import decompile

SITE = 'https://oasis.ssu.ac.kr'
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'layouts')
BROWSERS = [
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
]


def fetch(path, binary=False):
    req = urllib.request.Request(SITE + '/' + path.lstrip('/'), headers={'User-Agent': 'Mozilla/5.0'})
    data = urllib.request.urlopen(req, timeout=60).read()
    return data if binary else data.decode('utf-8', errors='ignore')


def find_layout_chunk():
    """ik-seat-r53 컴포넌트가 들어 있는 JS 청크와 전역 CSS 파일을 찾는다."""
    index = fetch('library-services/smuf/reading-rooms')
    runtime = re.search(r'src="(runtime\.[0-9a-f]+\.js)"', index).group(1)
    styles = re.search(r'href="(styles\.[0-9a-f]+\.css)"', index).group(1)
    rt = fetch(runtime)
    body = re.search(r'a\.u=e=>.*?\{(.*?)\}\[e\]', rt).group(1)
    layout = seat_css = None
    for cid, h in re.findall(r'(\d+):"([0-9a-f]+)"', body):
        text = fetch('%s.%s.js' % (cid, h))
        if layout is None and 'ik-seat-r53' in text:
            layout = text
        if seat_css is None:
            seat_css = decompile.extract_styles(text, 'ik-seat')
        if layout and seat_css:
            break
    if not (layout and seat_css):
        raise RuntimeError('도면/좌석 컴포넌트를 찾지 못했습니다')
    return layout, seat_css + '\n' + fetch(styles)


def room_totals():
    """열람실 API 에서 방별 좌석 총수(사용불가 포함)."""
    req = urllib.request.Request(
        SITE + '/pyxis-api/1/seat-rooms?smufMethodCode=PC&branchGroupId=1',
        headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'})
    j = json.loads(urllib.request.urlopen(req, timeout=60).read())
    out = {}
    for r in j['data']['list']:
        s = r['seats']
        out[r['id']] = s['total'] + s['unavailable']
    return out


MAT_BASE_CSS = """
*{box-sizing:border-box}
body{margin:0;font:14px/1.4 'Malgun Gothic',sans-serif}
.mat-button-base{box-sizing:border-box;position:relative;display:inline-block;white-space:nowrap;
 text-decoration:none;vertical-align:baseline;text-align:center;margin:0;min-width:64px;
 line-height:36px;padding:0 16px;border-radius:4px;border:1px solid transparent;
 font:inherit;overflow:visible;background:transparent}
.mat-button-wrapper{display:block}
"""

MEASURE_JS = r"""
(function(){
 function col(s){var m=s.match(/rgba?\(([^)]+)\)/);if(!m)return null;var p=m[1].split(',').map(parseFloat);
  var a=p.length>3?p[3]:1;return {r:p[0],g:p[1],b:p[2],a:a};}
 function hex(c){if(!c||c.a===0)return null;
  var h=function(n){return ('0'+Math.round(n).toString(16)).slice(-2)};
  return (c.a<1?h(c.a*255):'ff')+h(c.r)+h(c.g)+h(c.b);}
 var root=document.querySelector('[class*="ikc-seat-map"]');
 var all=document.querySelectorAll('[class]');
 for(var i=0;i<all.length;i++){if(/(^|\s)ikc-seat-map\d+(\s|$)/.test(all[i].className)){root=all[i];break;}}
 var rr=root.getBoundingClientRect();
 var out={w:rr.width,h:rr.height,seats:[],boxes:[],texts:[]};
 function rel(r){return {x:+(r.left-rr.left).toFixed(2),y:+(r.top-rr.top).toFixed(2),w:+r.width.toFixed(2),h:+r.height.toFixed(2)};}
 function radius(cs){return [cs.borderTopLeftRadius,cs.borderTopRightRadius,cs.borderBottomRightRadius,cs.borderBottomLeftRadius].map(parseFloat);}
 function boxOf(el,cs,r){
  var bg=hex(col(cs.backgroundColor)),bw=parseFloat(cs.borderTopWidth)||0,bc=hex(col(cs.borderTopColor));
  if(!bg&&!(bw>0&&bc&&cs.borderTopStyle!=='none'))return null;
  var o=rel(r);o.bg=bg;o.bw=bw>0&&cs.borderTopStyle!=='none'?bw:0;o.bc=bc;o.r=radius(cs);return o;}
 // 좌석
 root.querySelectorAll('ik-seat').forEach(function(s){
  var b=s.querySelector('button');var r=b.getBoundingClientRect();var cs=getComputedStyle(b);
  var o=rel(r);o.i=parseInt(s.getAttribute('data-i'));o.bg=hex(col(cs.backgroundColor));
  o.bc=hex(col(cs.borderTopColor));o.fg=hex(col(cs.color));o.r=radius(cs)[0];out.seats.push(o);});
 // 사용불가 좌석 색 (측정용 견본)
 var d=document.getElementById('probe-disabled');
 if(d){var cs=getComputedStyle(d);out.disabled={bg:hex(col(cs.backgroundColor)),bc:hex(col(cs.borderTopColor)),fg:hex(col(cs.color))};}
 // 테두리/배경이 있는 요소, 문구
 var els=[root].concat(Array.prototype.slice.call(root.querySelectorAll('*')));
 els.forEach(function(el){
  if(el.closest('ik-seat'))return;
  var cs=getComputedStyle(el);
  if(cs.display==='none'||cs.visibility==='hidden')return;
  var r=el.getBoundingClientRect();
  if(el!==root||true){var b=boxOf(el,cs,r);if(b){b.root=(el===root);out.boxes.push(b);}}
  // 가상 요소(문 모양 등)
  ['::before','::after'].forEach(function(ps){
   var pc=getComputedStyle(el,ps);
   if(pc.content&&pc.content!=='none'&&pc.display!=='none'&&parseFloat(pc.width)>0){
    var w=parseFloat(pc.width),h=parseFloat(pc.height);
    var x=r.left-rr.left,y=r.top-rr.top;
    if(ps==='::after'){var bp=getComputedStyle(el,'::before');
     if(bp.content&&bp.content!=='none'&&bp.display!=='none')x+=parseFloat(bp.width);}
    var bg=hex(col(pc.backgroundColor));
    if(bg)out.boxes.push({x:+x.toFixed(2),y:+y.toFixed(2),w:w,h:h,bg:bg,bw:0,bc:null,r:radius(pc),pseudo:true});}});
  // 직접 가진 텍스트
  for(var n=el.firstChild;n;n=n.nextSibling){
   if(n.nodeType===3&&n.textContent.trim()){
    var rg=document.createRange();rg.selectNodeContents(n);var tr=rg.getBoundingClientRect();
    var o=rel(tr);o.t=n.textContent.trim();o.fs=parseFloat(cs.fontSize);o.fg=hex(col(cs.color));
    o.fw=cs.fontWeight;out.texts.push(o);}}
 });
 fetch('http://127.0.0.1:__PORT__/',{method:'POST',mode:'no-cors',body:JSON.stringify(out)});
})();
"""


def seat_html(idx):
    return ('<ik-seat data-i="%d"><button class="mat-focus-indicator ikc-button-seat mat-button mat-button-base">'
            '<span class="mat-button-wrapper"><span class="ikc-seat-code">000</span></span></button></ik-seat>' % idx)


def render(node, total):
    if 'text' in node:
        return html.escape(node['text'])
    if 'seats' in node:
        idx = node.get('idx')
        if idx is None:  # e.seats 전체
            idx = list(range(total))
        return ''.join(seat_html(i) for i in idx)
    inner = ''.join(render(c, total) for c in node.get('ch', []))
    cls = ' '.join(node.get('cls', []))
    return '<%s%s>%s</%s>' % (node['tag'], ' class="%s"' % cls if cls else '', inner, node['tag'])


def find_map_root(node):
    if any(re.fullmatch(r'ikc-seat-map\d+', c) for c in node.get('cls', [])):
        return node
    for c in node.get('ch', []):
        r = find_map_root(c)
        if r:
            return r
    return None


def build_page(d, global_css, total):
    root = find_map_root(d['tree'])
    body = render(root, total)
    probe = ('<ik-seat style="position:absolute;left:-999px"><button id="probe-disabled" disabled '
             'class="mat-focus-indicator ikc-button-seat mat-button mat-button-base mat-button-disabled">'
             '<span class="mat-button-wrapper"><span class="ikc-seat-code">0</span></span></button></ik-seat>')
    return ('<!doctype html><html><head><meta charset="utf-8"><style>%s\n%s\n%s</style></head><body>'
            '<ik-seat-room-detail><div class="ikc-seat-map">%s%s</div></ik-seat-room-detail>'
            '<script>%s</script></body></html>') % (MAT_BASE_CSS, global_css, d['css'], body, probe, MEASURE_JS)


def find_browser():
    for b in BROWSERS:
        if os.path.exists(b):
            return b
    raise RuntimeError('Chrome 또는 Edge 를 찾지 못했습니다')


def measure(page_html, browser):
    """페이지를 headless 브라우저로 열고, 페이지가 로컬 서버로 보내는 측정 JSON 을 받는다."""
    import http.server
    import threading

    box = {}
    done = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get('Content-Length', 0))
            box['data'] = self.rfile.read(n)
            self.send_response(204)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            done.set()

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        path = os.path.join(tmp, 'page.html')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(page_html.replace('__PORT__', str(port)))
        proc = subprocess.Popen(
            [browser, '--headless', '--disable-gpu', '--no-sandbox', '--allow-file-access-from-files',
             '--window-size=3000,3000', '--user-data-dir=' + os.path.join(tmp, 'profile'),
             'file:///' + path.replace(os.sep, '/')],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            if not done.wait(90):
                raise RuntimeError('측정 결과를 받지 못했습니다')
        finally:
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(proc.pid)], capture_output=True)
            server.shutdown()
    return json.loads(box['data'])


def main():
    only = [int(x) for x in sys.argv[1:]]
    os.makedirs(OUT_DIR, exist_ok=True)
    chunk, styles = find_layout_chunk()
    totals = room_totals()
    browser = find_browser()
    rooms = sorted({int(x) for x in re.findall(r'selectors:\[\["ik-seat-r(\d+)"\]\]', chunk)})
    for r in rooms:
        if only and r not in only:
            continue
        d = decompile.extract_room(chunk, r)
        total = totals.get(r, 0)
        m = measure(build_page(d, styles, total), browser)
        m['room'] = r
        m['legend'] = d['legend']
        m['seats'].sort(key=lambda s: (s['i'], s['y'], s['x']))
        with open(os.path.join(OUT_DIR, 'r%d.json' % r), 'w', encoding='utf-8') as f:
            json.dump(m, f, ensure_ascii=False, separators=(',', ':'))
        print('room %d: %dx%d, seats %d, boxes %d, texts %d' % (
            r, m['w'], m['h'], len(m['seats']), len(m['boxes']), len(m['texts'])))


if __name__ == '__main__':
    main()
