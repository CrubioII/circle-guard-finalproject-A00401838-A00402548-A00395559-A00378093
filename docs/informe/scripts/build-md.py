# =============================================================================
# CircleGuard — Convierte el informe de la Parte 1 a Markdown (US-19 / CA4)
#
# Fuente: docs/informe/informe-parte1.html. Salida: docs/informe/INFORME_PARTE1.md
# Las capturas que existen en capturas/ se enlazan como imagen; las que faltan quedan
# como «Captura pendiente» con la instrucción para tomarla.
#
# Uso (desde la raíz del repo, Python 3.8+ sin dependencias):
#   python docs/informe/scripts/build-md.py
# =============================================================================
import os, re, sys
from html.parser import HTMLParser

here = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, '..', 'informe-parte1.html')
out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, '..', 'INFORME_PARTE1.md')
base = os.path.dirname(src)
html = open(src, encoding='utf-8').read()
html = html[html.index('<main>') + 6: html.index('</main>')]

VOID = {'img', 'br', 'meta'}

class Node:
    def __init__(self, tag, attrs, parent=None):
        self.tag, self.attrs, self.parent, self.kids = tag, dict(attrs), parent, []

class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node('root', [])
        self.cur = self.root
    def handle_starttag(self, tag, attrs):
        n = Node(tag, attrs, self.cur)
        self.cur.kids.append(n)
        if tag not in VOID:
            self.cur = n
    def handle_endtag(self, tag):
        n = self.cur
        while n is not self.root and n.tag != tag:
            n = n.parent
        if n is not self.root:
            self.cur = n.parent
    def handle_data(self, d):
        self.cur.kids.append(d)

p = P(); p.feed(html)

def inline(n):
    if isinstance(n, str):
        return re.sub(r'\s+', ' ', n)
    t = n.tag
    inner = ''.join(inline(k) for k in n.kids)
    if t == 'code':
        txt = ''.join(k if isinstance(k, str) else inline(k) for k in n.kids)
        return '`' + txt + '`'
    if t == 'b':
        return '**' + inner.strip() + '**'
    if t == 'i':
        return '*' + inner.strip() + '*'
    if t == 'a':
        href = n.attrs.get('href', '')
        txt = inner.strip()
        return f'<{href}>' if txt == href else f'[{txt}]({href})'
    if t == 'span' and 'badge' in n.attrs.get('class', ''):
        return '**' + inner.strip() + ('**:' if 'gap' in n.attrs.get('class', '') and n.parent.tag == 'li' else '**')
    if t == 'br':
        return '<br>'
    return inner

def cell(n):
    return inline(n).strip().replace('|', '\\|')

def table(n):
    rows = [r for r in walk(n) if not isinstance(r, str) and r.tag == 'tr']
    lines = []
    carry = {}
    for i, r in enumerate(rows):
        cells = [c for c in r.kids if not isinstance(c, str) and c.tag in ('td', 'th')]
        expanded = []
        col = 0
        it = iter(cells)
        while True:
            if col in carry and carry[col][0] > 0:
                expanded.append(carry[col][1]); carry[col][0] -= 1; col += 1; continue
            c = next(it, None)
            if c is None: break
            v = cell(c)
            span = int(c.attrs.get('rowspan', '1'))
            if span > 1: carry[col] = [span - 1, v]
            expanded.append(v); col += 1
        lines.append('| ' + ' | '.join(expanded) + ' |')
        if i == 0:
            lines.append('|' + '---|' * len(expanded))
    return lines

def walk(n):
    for k in n.kids:
        yield k
        if not isinstance(k, str):
            yield from walk(k)

CAPS = []
def figure(n):
    cap_file = n.attrs.get('data-capture')
    if cap_file:
        caption = inline(n).strip()
        path = os.path.join(base, 'capturas', cap_file)
        CAPS.append((cap_file, re.sub(r'^Figura \w+\.\s*', '', caption), 'Incluida' if os.path.exists(path) else '**Pendiente**'))
        if os.path.exists(path):
            return [f'![{caption}](capturas/{cap_file})', '', f'*{caption}*', '']
        how = n.attrs.get('data-how', 'Ejecutar capture-evidence.mjs')
        return [f'> **Captura pendiente:** `capturas/{cap_file}`. {how}.', '>', f'> *{caption}*', '']
    img = next(k for k in walk(n) if not isinstance(k, str) and k.tag == 'img')
    capn = next((k for k in n.kids if not isinstance(k, str) and k.tag == 'figcaption'), None)
    caption = inline(capn).strip() if capn else img.attrs.get('alt', '')
    return [f'![{img.attrs.get("alt", "")}]({img.attrs["src"]})', '', f'*{caption}*', '']

def block(n, out):
    if isinstance(n, str):
        if n.strip():
            out += [n.strip(), '']
        return
    t, cls = n.tag, n.attrs.get('class', '')
    if t == 'section' and 'cover' in cls:
        kicker = sub = title = ''
        for k in n.kids:
            if isinstance(k, str): continue
            if k.tag == 'h1': title = inline(k).strip()
            elif 'kicker' in k.attrs.get('class', ''): kicker = inline(k).strip()
            elif 'sub' in k.attrs.get('class', ''): sub = inline(k).strip()
        out += [f'# {title}', '', f'**{sub}**', '', kicker, '']
        tbl = next(k for k in n.kids if not isinstance(k, str) and k.tag == 'table')
        rows = [r for r in walk(tbl) if not isinstance(r, str) and r.tag == 'tr']
        out += ['| | |', '|---|---|']
        for r in rows:
            cs = [c for c in r.kids if not isinstance(c, str)]
            out.append(f'| **{cell(cs[0])}** | {cell(cs[1])} |')
        out.append('')
        return
    if t in ('h1', 'h2', 'h3'):
        lvl = {'h1': 1, 'h2': 2, 'h3': 3}[t]
        out += ['#' * lvl + ' ' + inline(n).strip(), '']
        return
    if t == 'p':
        txt = inline(n).strip()
        if 'muted' in cls:
            txt = f'*{txt}*' if '*' not in txt else txt
        out += [txt, '']
        return
    if t in ('ul', 'ol'):
        i = 1
        for li in n.kids:
            if isinstance(li, str) or li.tag != 'li': continue
            mark = f'{i}.' if t == 'ol' else '-'
            out.append(f'{mark} {inline(li).strip()}')
            i += 1
        out.append('')
        return
    if t == 'table':
        if n.attrs.get('id') == 'capture-index':
            out += ['| Archivo | Figura | Estado |', '|---|---|---|']
            out += [f'| `{f}` | {c} | {st} |' for f, c, st in sorted(CAPS)]
            out.append('')
            return
        out += table(n) + ['']
        return
    if t == 'pre':
        txt = ''.join(k if isinstance(k, str) else inline(k) for k in n.kids)
        out += ['```text', txt.strip('\n'), '```', '']
        return
    if t == 'figure':
        out += figure(n)
        return
    if t == 'div' and 'alert' in cls:
        out += ['> [!WARNING]', '> ' + inline(n).strip(), '']
        return
    for k in n.kids:
        block(k, out)

lines = []
for k in p.root.kids:
    block(k, lines)

md = '\n'.join(lines)
md = re.sub(r'\n{3,}', '\n\n', md).strip() + '\n'
md = ('<!-- Generado desde informe-parte1.html con docs/informe/scripts/build-md.py. '
      'Edita el HTML y vuelve a generar. -->\n\n' + md)
open(out, 'w', encoding='utf-8', newline='\n').write(md)
print('Markdown generado:', os.path.normpath(out))
