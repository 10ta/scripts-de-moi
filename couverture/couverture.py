#!/usr/bin/env python3
"""Couverture lexicale d'un texte ou de sous-titres : part des mots connus, mots inconnus, débit.

Mots connus = les N lemmes les plus fréquents + (avec --export) les mots marqués « connus » dans VCita
et ceux de tes cartes stables (intervalle >= 21 j, non suspendues) — même règle que l'onglet
« 短文挖词 » de VCita.

Fréquences : Lexique 3.83 (sous-titres de films) et wordfreq (7 corpus), lemmatisés et fusionnés ;
rang = position parmi les lemmes de Lexique.

Exemples :
  python3 couverture.py texte.txt
  python3 couverture.py *.srt --export vcita.json.gz          # plusieurs fichiers : un résumé par ligne, triés
  python3 couverture.py episode.vtt --export vcita.json.gz --inconnus 40
  python3 couverture.py texte.txt --courbe                    # couverture pour N = 1000…12000
"""
import argparse, gzip, json, os, re, sys, collections as C

HERE = os.path.dirname(os.path.abspath(__file__))
FUNC = set("le la les l un une des de du d à au aux en et ou se s ne pas y que qu qui ce cet cette ces sa son ses "
           "leur leurs mon ma mes ton ta tes nous vous il ils elle elles on je j me m te t lui eux pour par sur dans "
           "avec sans être avoir faire mais donc car si".split())
WORD = re.compile(r"[^\W\d_]+(?:['’-][^\W\d_]+)*", re.U)
ELISION = re.compile(r"^((?:[ldjmnstc]|qu|jusqu|lorsqu|puisqu|quoiqu)['’])(\w.*)$", re.I | re.U)
NOT_WORDS = re.compile(r"\([^)]*\)|（[^）]*）|\bqq(?:ch|n)?\b|\binf\b\.?|\bsubj\b\.?|\+|…|⬚|\{\{|\}\}", re.I)
TIME = re.compile(r"(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[.,](\d{1,3})")
STABLE_DAYS = 21
# Écart avec l'ancre (texte dont la difficulté est connue : par défaut ancre.txt = T'es pas en retard,
# dictée réussie). Valeurs de départ, à ajuster à l'usage.
BANDS = [(1, 'shadowing / écoute extensive'), (-2, 'dictée'), (-5, 'écoute intensive (avec transcription)'),
         (-99, 'trop difficile')]


def norm(w):
    return w.lower().replace('œ', 'oe').replace('æ', 'ae').replace('’', "'").strip()


def gzopen(p):
    return gzip.open(p, 'rt', encoding='utf-8') if p.endswith('.gz') else open(p, encoding='utf-8')


class Lex:
    def __init__(self):
        self.f2l = json.load(gzopen(os.path.join(HERE, 'form2lemma.json.gz')))
        self.rank, self.lexique = {}, []      # lexique : lemmes de Lexique, dans l'ordre du rang
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
        if r is None and '-' in w:
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


def vocab_test(lex, per_band=12, bands=12, seed=None):
    """Échantillon de lemmes par tranche de 1000 rangs ; o = connu (je sais ce que ça veut dire), Entrée = non."""
    import random
    rnd = random.Random(seed)
    clean = [l for l in lex.lexique if re.fullmatch(r"[a-zàâäçéèêëîïôöùûüÿ]{3,}", l)]
    est = 0.0
    print("Pour chaque mot : o = je connais au moins un sens courant, Entrée = non.\n")
    for b in range(bands):
        lo, hi = b * 1000 + 1, (b + 1) * 1000
        pool = [l for l in clean if lo <= lex.rank[l] <= hi]
        sample = rnd.sample(pool, min(per_band, len(pool)))
        yes = 0
        for l in sample:
            yes += input(f'  [{lo:>5}–{hi:<5}] {l:<20} ').strip().lower() in ('o', 'y', 'oui', '1')
        share = yes / len(sample)
        est += share * 1000
        print(f'  → {share:.0%} connus dans cette tranche\n')
    print(f'Estimation : environ {round(est, -2):.0f} lemmes parmi les {bands * 1000} plus fréquents.')
    print(f'Utilise --top {int(est // 500 * 500)} ici, et la même valeur pour « 常用词前 N 个算认识 » dans VCita.')


def band(delta):
    return next(name for th, name in BANDS if delta >= th)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('fichiers', nargs='+')
    ap.add_argument('--top', type=int, default=None, help='les N lemmes les plus fréquents comptent comme connus (défaut : 5000, ou 2000 avec --export)')
    ap.add_argument('--export', help='export VCita (.json ou .json.gz)')
    ap.add_argument('--ancre', default=os.path.join(HERE, 'ancre.txt'), help='texte de référence (défaut : ancre.txt)')
    ap.add_argument('--inconnus', type=int, default=25, help='nombre de mots inconnus à lister (fichier unique)')
    ap.add_argument('--courbe', action='store_true', help='couverture pour N = 1000 … 12000')
    ap.add_argument('--test', action='store_true', help='test de vocabulaire (≈ 3 min) pour estimer ton N')
    a = ap.parse_args() if '--test' not in sys.argv else ap.parse_known_args(['-'] + sys.argv[1:])[0]
    if a.test:
        return vocab_test(Lex())
    top = a.top if a.top is not None else (2000 if a.export else 5000)
    lex = Lex()
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
        pct = 100 * k / max(t, 1)
        wpm = round(t / dur * 60) if dur else None
        rows.append((pct, f, t, unk, wpm))
    rows.sort(key=lambda r: -r[0])
    ref = None
    if a.ancre and os.path.exists(a.ancre):
        t, k, _ = analyse(lex, read_input(a.ancre)[0], top, known)
        ref = 100 * k / max(t, 1)
    print(f"Connus = top {top}" + (f" + VCita ({len(known)} lemmes)" if a.export else '')
          + (f" · ancre {os.path.basename(a.ancre)} = {ref:.1f} %" if ref is not None else '') + '\n')
    for pct, f, t, unk, wpm in rows:
        sp = f' · {wpm} mots/min' if wpm else ''
        verdict = f'{pct - ref:+5.1f}  {band(pct - ref):<38}' if ref is not None else ''
        print(f'{pct:5.1f} %  {verdict}{t:>6} mots · {len(unk):>4} inconnus distincts{sp}  {os.path.basename(f)}')
    if len(rows) == 1:
        unk = rows[0][3]
        print('\nMots inconnus (occurrences · rang) :')
        for lem, n in sorted(unk.items(), key=lambda x: (-x[1], lex.rank.get(x[0], 10**6)))[:a.inconnus]:
            r = lex.rank.get(lem)
            print(f'  {lem:<24} {n:>3} · {r if r else "—"}')


if __name__ == '__main__':
    main()
