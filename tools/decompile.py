"""사이트(oasis.ssu.ac.kr)의 Angular 컴파일 템플릿에서 좌석 도면 구조를 추출한다."""
import json
import re

BS = chr(92)


def unescape(s):
    b = re.escape(BS)
    s = re.sub(b + r'u([0-9a-fA-F]{4})', lambda m: chr(int(m.group(1), 16)), s)
    s = re.sub(b + r'x([0-9a-fA-F]{2})', lambda m: chr(int(m.group(1), 16)), s)
    return s


def balanced(s, i, open_ch='(', close_ch=')'):
    """s[i] 가 open_ch 일 때 짝이 맞는 close 위치를 반환."""
    depth = 0
    in_str = None
    j = i
    while j < len(s):
        c = s[j]
        if in_str:
            if c == BS:
                j += 2
                continue
            if c == in_str:
                in_str = None
        else:
            if c in '"\'`':
                in_str = c
            elif c == open_ch:
                depth += 1
            elif c == close_ch:
                depth -= 1
                if depth == 0:
                    return j
        j += 1
    raise ValueError('unbalanced')


def split_args(a):
    out, depth, cur, in_str = [], 0, '', None
    i = 0
    while i < len(a):
        c = a[i]
        if in_str:
            cur += c
            if c == BS:
                cur += a[i + 1]
                i += 2
                continue
            if c == in_str:
                in_str = None
        else:
            if c in '"\'':
                in_str = c
                cur += c
            elif c in '([{':
                depth += 1
                cur += c
            elif c in ')]}':
                depth -= 1
                cur += c
            elif c == ',' and depth == 0:
                out.append(cur)
                cur = ''
            else:
                cur += c
        i += 1
    if cur != '':
        out.append(cur)
    return out


def js_str(tok):
    tok = tok.strip()
    if tok[:1] in ('"', "'"):
        return unescape(tok[1:-1])
    return None


def parse_consts(comp):
    """component 정의에서 consts 배열의 클래스 목록을 읽는다. 반환: list[list[str]]"""
    m = re.search(r'consts:', comp)
    i = comp.index('[[', m.end())  # 배열의 첫 요소는 항상 배열
    j = balanced(comp, i, '[', ']')
    body = comp[i + 1:j]
    result = []
    for it in split_args(body):
        it = it.strip()
        if it.startswith('['):
            parts = [p.strip() for p in split_args(it[1:-1])]
            classes = []
            if parts and parts[0] == '1':
                for p in parts[1:]:
                    if re.fullmatch(r'-?\d+', p):
                        break
                    s = js_str(p)
                    if s is not None:
                        classes.append(s)
            else:
                for k, p in enumerate(parts):
                    if js_str(p) == 'class' and k + 1 < len(parts):
                        v = js_str(parts[k + 1])
                        if v:
                            classes += v.split()
            result.append(classes)
        else:
            result.append([])  # 식별자(i18n 문자열 등)
    return result


def tokenize_create(code):
    """create 블록 문자열을 (name, args) 호출 목록으로 바꾼다. 체인 호출 (a)(b) 도 같은 함수로 처리."""
    calls = []
    head = re.compile(r't\.(\w+)\(')
    i = 0
    while i < len(code):
        m = head.match(code, i)
        if not m:
            i += 1
            continue
        name = m.group(1)
        j = m.end() - 1
        while True:
            k = balanced(code, j)
            calls.append((name, split_args(code[j + 1:k])))
            j = k + 1
            if j < len(code) and code[j] == '(':
                continue
            break
        i = j
    return calls


def function_body(src, fn_name):
    m = re.search(r'function ' + re.escape(fn_name) + r'\(\w,\w\)\{', src)
    end = balanced(src, m.end() - 1, '{', '}')
    return src[m.end():end]


def parse_body(body, consts):
    """템플릿 함수 본문(create/update 블록)을 트리로 만든다."""
    cm = re.search(r'1&\w&&\(', body)
    cs = cm.end() - 1
    ce = balanced(body, cs)
    create = body[cs + 1:ce]
    rest = body[ce + 1:]
    root = {'tag': 'root', 'cls': [], 'ch': []}
    stack = [root]
    seat_slots = []
    for name, args in tokenize_create(create):
        if name == 'TgZ':
            n = {'tag': js_str(args[1]), 'cls': consts[int(args[2])] if len(args) > 2 else [], 'ch': []}
            stack[-1]['ch'].append(n)
            stack.append(n)
        elif name == 'qZA':
            stack.pop()
        elif name == '_UZ':
            stack[-1]['ch'].append(
                {'tag': js_str(args[1]), 'cls': consts[int(args[2])] if len(args) > 2 else [], 'ch': []})
        elif name == '_uU':
            stack[-1]['ch'].append({'text': js_str(args[1])})
        elif name == 'YNc':
            tag = js_str(args[4])
            if tag == 'ik-seat':
                n = {'seats': len(seat_slots)}
                seat_slots.append(n)
            else:
                n = {'unknown_template': tag, 'fn': args[1]}
            stack[-1]['ch'].append(n)
    exprs = []
    for mm in re.finditer(r't\.Q6J\("ngForOf",', rest):
        p = mm.start() + len('t.Q6J')
        q = balanced(rest, p)
        exprs.append(split_args(rest[p + 1:q])[1].strip())
    return root, seat_slots, exprs


def parse_groups(comp):
    """seatGroupN = this.seats.slice(a,b)[.reverse()] 정의."""
    groups = {}
    pat = r'this\.(seatGroup\d+)=this\.seats\.slice\((\d+),(\d+)\)((?:\.\w+\([^)]*\))*)'
    for m in re.finditer(pat, comp):
        groups[m.group(1)] = {'a': int(m.group(2)), 'b': int(m.group(3)), 'ops': m.group(4)}
    return groups


def extract_styles(src, selector):
    """selectors:[["<selector>"]] 컴포넌트의 styles 문자열을 반환 (없으면 None)."""
    m = re.search(r'selectors:\[\["%s"\]\]' % re.escape(selector), src)
    if not m:
        return None
    sm = re.compile(r"styles:\[(['\"])").search(src, m.end())
    quote = sm.group(1)
    end = src.index(quote + ']', sm.end())
    return src[sm.end():end].replace(BS + 'n', '\n')


def extract_room(src, room):
    m = re.search(r'selectors:\[\["ik-seat-r%d"\]\]' % room, src)
    nxt = re.search(r'selectors:\[\["', src[m.end():])
    begin = src.rfind('(()=>{class ', 0, m.start())  # 클래스 본문(ngAfterContentChecked 등)부터
    comp = src[begin: m.end() + (nxt.start() if nxt else len(src))]
    consts = parse_consts(comp)
    cm = re.search(r'template:function\(e,s\)\{', comp)
    tb = comp[cm.end(): balanced(comp, cm.end() - 1, '{', '}')]
    body_fn = None
    for mm in re.finditer(r't\.YNc\((\d+),(\w+),\d+,\d+,"div",(\d+)\)', tb):
        if 'ikc-seat-map' in consts[int(mm.group(3))]:
            body_fn = mm.group(2)
    css_m = re.search(r"styles:\[(['\"])", comp)
    quote = css_m.group(1)
    css_end = comp.index(quote + ']', css_m.end())
    css = comp[css_m.end():css_end].replace(BS + 'n', '\n')
    # ngIf 로 감싼 본문 함수가 없으면(15번 도면) 컴포넌트 템플릿 자체가 본문이다.
    body = function_body(src, body_fn) if body_fn else tb
    root, slots, exprs = parse_body(body, consts)
    groups = parse_groups(comp)
    for slot, e in zip(slots, exprs):
        gm = re.fullmatch(r'\w\.(seatGroup\d+)', e)
        sm = re.fullmatch(r't\.\w+\(\d+,\d+,\w\.seats,(\d+),(\d+)\)', e)
        if gm:
            g = groups[gm.group(1)]
            idx = list(range(g['a'], g['b']))
            if '.reverse()' in g['ops']:
                idx.reverse()
            slot['idx'] = idx
        elif sm:
            slot['idx'] = list(range(int(sm.group(1)), int(sm.group(2))))
        else:
            slot['unparsed'] = e
    legend = extract_legend(tb, consts, css)
    return {'room': room, 'tree': root, 'css': css, 'groups': groups, 'exprs': exprs,
            'slots': len(slots), 'legend': legend}


def find_node(node, cls):
    if cls in node.get('cls', []):
        return node
    for c in node.get('ch', []):
        r = find_node(c, cls)
        if r:
            return r
    return None


def extract_legend(template_body, consts, css):
    """범례(일반석/방음부스/...)를 [{label, bg, bc}] 로 반환."""
    try:
        troot, _, _ = parse_body(template_body, consts)
    except Exception:
        return []
    status = find_node(troot, 'ikc-seat-status')
    if not status:
        return []
    colors = {}
    for m in re.finditer(r'\.ikc-seat-status \.(seat-[\w-]+)\{border-color:(#\w+);background:(#\w+)\}', css):
        colors[m.group(1)] = (m.group(3), m.group(2))
    items = []
    for span in status['ch']:
        em = next((c for c in span.get('ch', []) if c.get('tag') == 'em'), None)
        label = next((c['text'] for c in span.get('ch', []) if 'text' in c), None)
        if em is None or label is None:
            continue
        key = next((c for c in em['cls'] if c in colors), None)
        bg, bc = colors.get(key, ('#cccccc', '#999999'))
        items.append({'label': label, 'bg': bg, 'bc': bc, 'disabled': key == 'seat-disabled'})
    return items


if __name__ == '__main__':
    import sys
    text = open(sys.argv[1], encoding='utf-8').read()
    for r in [int(x) for x in sys.argv[2:]]:
        d = extract_room(text, r)
        print('== room', r, 'slots', d['slots'], 'exprs', len(d['exprs']), 'css', len(d['css']))
        print(json.dumps(d['tree'], ensure_ascii=False)[:1800])
