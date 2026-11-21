#!/usr/bin/env python3
"""Couverture lexicale d'un texte ou de sous-titres : part des mots connus, mots inconnus, débit.

Mots connus = les N lemmes les plus fréquents (N : dernier --test, sinon 8000)
            + avec --export : les mots marqués « 认识 » dans VCita et ceux des cartes stables
              (intervalle >= 21 j, non suspendues), même règle que l'onglet 短文挖词.

  python3 couverture.py --test                        test de vocabulaire, une touche par mot
  python3 couverture.py texte.txt
  python3 couverture.py subs/*.vtt --export vcita.json.gz
  python3 couverture.py episode.srt --inconnus 40
  python3 couverture.py a.txt b.txt --courbe          couverture pour N = 1000 … 12000
"""
import argparse, collections as C, gzip, json, os, random, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(os.environ.get('XDG_STATE_HOME') or os.path.expanduser('~/.local/state'), 'couverture', 'niveau.json')
DEFAULT_TOP = 8000
FUNC = set("le la les l un une des de du d à au aux en et ou se s ne pas y que qu qui ce cet cette ces sa son ses "
           "leur leurs mon ma mes ton ta tes nous vous il ils elle elles on je j me m te t lui eux pour par sur dans "
           "avec sans être avoir faire mais donc car si".split())
WORD = re.compile(r"[^\W\d_]+(?:['’-][^\W\d_]+)*", re.U)
ELISION = re.compile(r"^((?:[ldjmnstc]|qu|jusqu|lorsqu|puisqu|quoiqu)['’])(\w.*)$", re.I | re.U)
NOT_WORDS = re.compile(r"\([^)]*\)|（[^）]*）|\bqq(?:ch|n)?\b|\binf\b\.?|\bsubj\b\.?|\+|…|⬚|\{\{|\}\}", re.I)
TIME = re.compile(r"(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[.,](\d{1,3})")
STABLE_DAYS = 21
# À partir de 8 000 lemmes, presque tout texte courant dépasse 97 % : la couverture sert à écarter les textes
# trop chargés en mots rares ; le reste se juge à l'écoute (une minute, sans texte).
FLOOR = 97.0


def norm(w):
    return w.lower().replace('œ', 'oe').replace('æ', 'ae').replace('’', "'").strip()


def gzopen(p):
    return gzip.open(p, 'rt', encoding='utf-8') if p.endswith('.gz') else open(p, encoding='utf-8')


class Lex:
    def __init__(self):
        self.f2l = json.load(gzopen(os.path.join(HERE, 'form2lemma.json.gz')))
        self.rank, self.lexique = {}, []      # lexique : lemmes présents dans Lexique, dans l'ordre du rang
        with gzopen(os.path.join(HERE, 'rank_fr.tsv.gz')) as fh:
            for line in fh:
                r, l, inlex = line.rstrip('\n').split('\t')
                self.rank.setdefault(l, int(r))
                if inlex == '1':
                    self.lexique.append(l)

    def lemma(self, w):
        k = norm(w)
        return self.f2l.get(k, k)

    def rank_of(self, w):
        r = self.rank.get(self.lemma(w))
        if r is None and '-' in w:             # réjouis-toi : rang de la partie la plus rare
            parts = [self.rank.get(self.lemma(p)) for p in w.split('-') if len(p) > 1]
            parts = [p for p in parts if p]
            r = max(parts) if parts else None
        return r


def tokens(text):
    for m in WORD.finditer(text):
        w = m.group(0)
        e = ELISION.match(w)
        yield e.group(2) if e else w


def read_input(path):
    """Texte brut ; pour .srt / .vtt : texte des répliques + durée en secondes."""
    raw = open(path, encoding='utf-8', errors='replace').read().replace('\r', '')
    if not path.lower().endswith(('.srt', '.vtt')):
        raw = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", raw)          # liens markdown
        raw = re.sub(r"^---\n.*?\n---\n", "", raw, flags=re.S)       # frontmatter
        return raw, None
    lines, start, end, seen = [], None, None, set()
    for block in re.split(r"\n{2,}", raw):
        rows = [l.strip() for l in block.split('\n') if l.strip()]
        i = next((j for j, l in enumerate(rows) if '-->' in l), -1)
        if i < 0:
            continue
        ts = [TIME.search(x) for x in rows[i].split('-->')]
        if all(ts):
            sec = [int(t.group(1) or 0) * 3600 + int(t.group(2)) * 60 + int(t.group(3)) for t in ts]
            start = sec[0] if start is None else min(start, sec[0])
            end = sec[1] if end is None else max(end, sec[1])
        for l in rows[i + 1:]:
            l = re.sub(r"<[^>]+>|\{[^}]+\}", "", l).strip()
            if l and l not in seen:                                  # sous-titres auto YouTube : lignes répétées
                seen.add(l); lines.append(l)
    return '\n'.join(lines), (end - start if start is not None and end else None)


def vcita_known(lex, path, top):
    """Lemmes connus d'après un export VCita : « connus » manuels + mots des cartes stables."""
    d = json.load(gzopen(path))
    known = {norm(k['id']) for k in d.get('known', []) if not k.get('deleted')}
    stable = C.defaultdict(bool)
    for c in d.get('cards', []):
        if not c.get('deleted') and not c.get('suspended') and c.get('state') == 'review' and c.get('interval', 0) >= STABLE_DAYS:
            stable[c['noteId']] = True
    for n in d.get('notes', []):
        if n.get('deleted') or not stable[n['id']]:
            continue
        ws = [w for w in tokens(NOT_WORDS.sub(' ', n['lemma'])) if len(w) > 1 and norm(w) not in FUNC]
        if len(ws) > 1:   # une expression ne rend « connus » que ses mots peu fréquents (comme VCita)
            ws = [w for w in ws if (lex.rank_of(w) or 10**6) > top]
        known.update(lex.lemma(w) for w in ws)
    return known


def analyse(lex, text, top, known):
    total = ok = 0
    unknown = C.Counter()
    toks = list(tokens(text))
    lower = {norm(w) for w in toks if not w[0].isupper()}
    for w in toks:
        # nom propre : toujours avec majuscule dans ce texte, et pas un mot courant en début de phrase
        if w[0].isupper() and norm(w) not in lower and (lex.rank_of(w) or 10**6) > 3000:
            continue
        lem = lex.lemma(w)
        total += 1
        r = lex.rank_of(w)
        if lem in FUNC or lem in known or (r is not None and r <= top):
            ok += 1
        else:
            unknown[lem] += 1
    return total, ok, unknown


def verdict(pct, delta):
    if pct < FLOOR:
        return 'trop de mots rares'
    if delta is None:
        return "à juger à l'écoute"
    return "proche de l'ancre" if delta >= -1 else "plus dur que l'ancre"


# ---------------- test de vocabulaire ----------------

KEYS_YES, KEYS_NO, KEYS_UNDO, KEYS_QUIT = '.', ',', ('\x7f', '\b'), ('q', '\x1b')


def keys_from_terminal():
    """Une touche à la fois, sans Entrée ni écho. Hors terminal (tests, tube) : on lit stdin caractère par caractère."""
    if not sys.stdin.isatty():
        while True:
            c = sys.stdin.read(1)
            if not c:
                yield 'q'
                return
            if c not in '\r\n':
                yield c
    import termios, tty
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        while True:
            yield sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def load_level():
    try:
        return json.load(open(STATE, encoding='utf-8'))
    except (OSError, ValueError):
        return None


def vocab_test(lex, keys, out=sys.stdout, seed=None, per_band=12, pseudo_per_band=2, bands=12, save=True):
    """12 tranches de 1000 rangs, 12 mots + 2 pseudo-mots par tranche, du plus fréquent au plus rare.
    Les pseudo-mots acceptés mesurent la tendance à dire « connu » ; l'estimation est corrigée d'autant.
    S'arrête de lui-même quand deux tranches de suite tombent sous 15 %."""
    rnd = random.Random(seed)
    clean = [l for l in lex.lexique if re.fullmatch(r"[a-zàâäçéèêëîïôöùûüÿ]{3,}", l)]
    pseudo = [w for w in open(os.path.join(HERE, 'pseudo.txt'), encoding='utf-8').read().split() if w]
    rnd.shuffle(pseudo)
    items = []                                   # (tranche, mot, est_pseudo)
    for b in range(bands):
        lo, hi = b * 1000 + 1, (b + 1) * 1000
        row = [(b, l, False) for l in rnd.sample([l for l in clean if lo <= lex.rank[l] <= hi], per_band)]
        row += [(b, pseudo.pop(), True) for _ in range(pseudo_per_band)]
        rnd.shuffle(row)
        items += row
    w = lambda s='': print(s, file=out, flush=True)
    w(f"Un mot à la fois.  {KEYS_YES} = je connais au moins un sens courant   {KEYS_NO} = non"
      "   ⌫ = corriger le précédent   q = arrêter")
    w("Certains mots n'existent pas : réponds « non » si tu ne les reconnais pas.\n")
    answers, i, low_streak, finished = [], 0, 0, True
    ask = keys if callable(keys) else (lambda it: lambda word: next(it, 'q'))(iter(keys))   # tests : fonction(mot) → touche
    while i < len(items):
        b, word, _ = items[i]
        print(f'  {b * 1000 + 1:>5}–{(b + 1) * 1000:<5} {word:<18}', end='', file=out, flush=True)
        k = ask(word)
        if k in KEYS_QUIT:
            w('arrêt'); finished = False; break
        if k in KEYS_UNDO:
            w('↩')
            if answers:
                answers.pop(); i -= 1
            continue
        if k not in (KEYS_YES, KEYS_NO):
            w(f"? ({KEYS_YES} ou {KEYS_NO})"); continue
        answers.append(k == KEYS_YES)
        w('✓' if k == KEYS_YES else '·')
        i += 1
        if i == len(items) or items[i][0] != b:   # fin de tranche
            real = [a for (bb, _, ps), a in zip(items, answers) if bb == b and not ps]
            share = sum(real) / len(real)
            w(f'  → {share:.0%}\n')
            low_streak = low_streak + 1 if share < 0.15 else 0
            if low_streak >= 2:
                w('Deux tranches sous 15 % : on s\'arrête là, la suite compte pour zéro.'); break
    done = list(zip(items, answers))
    if not done:
        w('Aucune réponse.'); return None
    ps = [a for (_, _, p), a in done if p]
    fa = sum(ps) / len(ps) if ps else 0.0
    by_band = C.defaultdict(list)
    for (b, _, p), a in done:
        if not p:
            by_band[b].append(a)
    raw = sum(sum(v) / len(v) * 1000 for v in by_band.values())
    corr = sum(max(0.0, (sum(v) / len(v) - fa) / (1 - fa)) * 1000 for v in by_band.values()) if fa < 1 else 0.0
    top = int(corr // 500 * 500)
    w(f'\nPseudo-mots acceptés : {sum(ps)}/{len(ps)}')
    w(f'Estimation brute : {round(raw, -2):.0f} · corrigée : {round(corr, -2):.0f} lemmes parmi les {bands * 1000} plus fréquents.')
    if fa > 0.25:
        w("Plus d'un pseudo-mot sur quatre accepté : refais le test en ne validant que les mots dont tu sais un sens.")
    result = {'complet': finished, 'date': time.strftime('%Y-%m-%d'), 'brut': round(raw), 'pseudo': f'{sum(ps)}/{len(ps)}', 'estimation': round(corr), 'top': top}
    if not finished:
        w('Test interrompu : résultat partiel, rien n\'est enregistré.')
    elif save and top > 0:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        json.dump(result, open(STATE, 'w', encoding='utf-8'), ensure_ascii=False)
        w(f'Enregistré : --top {top} par défaut ({STATE}). Mets la même valeur dans VCita → 常用词前 N 个算认识.')
    return result


# ---------------- main ----------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('fichiers', nargs='*')
    ap.add_argument('--top', type=int, default=None, help=f'les N lemmes les plus fréquents comptent comme connus (défaut : dernier --test, sinon {DEFAULT_TOP})')
    ap.add_argument('--export', help='export VCita (.json ou .json.gz)')
    ap.add_argument('--ancre', default=os.path.join(HERE, 'ancre.txt'), help='texte de référence (défaut : ancre.txt)')
    ap.add_argument('--inconnus', type=int, default=25, help='nombre de mots inconnus à lister (fichier unique)')
    ap.add_argument('--courbe', action='store_true', help='couverture pour N = 1000 … 12000')
    ap.add_argument('--test', action='store_true', help='test de vocabulaire (≈ 2 min) ; le résultat devient le --top par défaut')
    a = ap.parse_args(argv)
    lex = Lex()
    if a.test:
        vocab_test(lex, keys_from_terminal())
        return
    if not a.fichiers:
        ap.error('aucun fichier (ou --test)')
    level = load_level()
    top = a.top if a.top is not None else (level['top'] if level else DEFAULT_TOP)
    src = '' if a.top is not None else (f" (test du {level['date']})" if level else ' (par défaut)')
    known = vcita_known(lex, a.export, top) if a.export else set()
    docs = [(f, *read_input(f)) for f in a.fichiers]

    if a.courbe:
        ns = [1000, 2000, 3000, 4000, 5000, 6000, 8000, 10000, 12000]
        print('fichier'.ljust(32) + ''.join(f'{n:>7}' for n in ns))
        for f, text, _ in docs:
            row = []
            for n in ns:
                kn = vcita_known(lex, a.export, n) if a.export else set()
                t, k, _ = analyse(lex, text, n, kn)
                row.append(f'{100 * k / max(t, 1):6.1f}%')
            print(os.path.basename(f)[:31].ljust(32) + ' '.join(row))
        return

    rows = []
    for f, text, dur in docs:
        t, k, unk = analyse(lex, text, top, known)
        rows.append((100 * k / max(t, 1), f, t, unk, round(t / dur * 60) if dur else None))
    rows.sort(key=lambda r: -r[0])
    ref = None
    if a.ancre and os.path.exists(a.ancre):
        t, k, _ = analyse(lex, read_input(a.ancre)[0], top, known)
        ref = 100 * k / max(t, 1)
    print(f'Connus = top {top}{src}' + (f' + VCita ({len(known)} lemmes)' if a.export else '')
          + (f' · ancre {os.path.basename(a.ancre)} = {ref:.1f} %' if ref is not None else '') + '\n')
    for pct, f, t, unk, wpm in rows:
        sp = f' · {wpm} mots/min' if wpm else ''
        gap = f'{pct - ref:+5.1f}  ' if ref is not None else ''
        v = verdict(pct, pct - ref if ref is not None else None)
        print(f'{pct:5.1f} %  {gap}{v:<24}{t:>6} mots · {len(unk):>4} inconnus distincts{sp}  {os.path.basename(f)}')
    if len(rows) == 1:
        unk = rows[0][3]
        print('\nMots inconnus (occurrences · rang) :')
        for lem, n in sorted(unk.items(), key=lambda x: (-x[1], lex.rank.get(x[0], 10**6)))[:a.inconnus]:
            r = lex.rank.get(lem)
            print(f'  {lem:<24} {n:>3} · {r if r else "—"}')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print()
