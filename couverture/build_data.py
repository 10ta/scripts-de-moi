#!/usr/bin/env python3
"""Régénère les données de couverture.py à partir de Lexique 3.83 et de wordfreq.

  rank_fr.tsv.gz      rang, lemme, présent dans Lexique (1/0)
  form2lemma.json.gz  forme → lemme (seulement quand elles diffèrent)
  pseudo.txt          pseudo-mots pour le test (absents de Lexique et de wordfreq)

Sources (téléchargées à part, elles ne sont pas dans le dépôt) :
  - Lexique383.txt (latin-1) : dans la roue PyPI pylexique, pylexique/Lexique383/Lexique383.txt
  - large_fr.msgpack.gz       : dans la roue PyPI wordfreq, wordfreq/data/large_fr.msgpack.gz
  Lire le second demande le paquet msgpack.

  python3 build_data.py Lexique383.txt large_fr.msgpack.gz
"""
import bisect, collections as C, csv, gzip, json, os, random, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FRENCH = re.compile(r"[a-zàâäçéèêëîïôöùûüÿñ'\-]+")


def norm(w):
    return w.lower().replace('œ', 'oe').replace('æ', 'ae').replace('’', "'").strip()


def num(x):
    try:
        return float(x.replace(',', '.'))
    except ValueError:
        return 0.0


def read_lexique(path):
    """films_pm par lemme (somme sur les catégories) et forme → lemme le plus fréquent."""
    films, seen, forms = C.Counter(), set(), C.defaultdict(dict)
    with open(path, encoding='latin-1') as fh:
        rows = csv.reader(fh, delimiter='\t', quoting=csv.QUOTE_NONE)
        next(rows)
        for r in rows:
            o, l, cg = norm(r[0]), norm(r[2]), r[3]
            if (l, cg) not in seen:
                seen.add((l, cg))
                films[l] += num(r[6])          # 7_freqlemfilms2
            f = num(r[8]) + num(r[9])          # freqfilms2 + freqlivres
            forms[o][l] = max(forms[o].get(l, 0), f)
    f2l = {o: max(d, key=lambda k: (d[k], films.get(k, 0))) for o, d in forms.items()}
    return films, f2l


def read_wordfreq(path):
    """Fréquence par mot : le fichier cBpack range les mots par tranche de 0,01 en log10."""
    import msgpack
    data = msgpack.unpackb(gzip.decompress(open(path, 'rb').read()), raw=False)
    return {w: 10 ** (-i / 100) for i, bucket in enumerate(data[1:]) for w in bucket}


def build_ranks(films, f2l, wf):
    wl = C.Counter()
    for w, f in wf.items():
        k = norm(w)
        if not FRENCH.fullmatch(k):
            continue
        l = f2l.get(k)
        if l is None:
            l = k[:-1] if k[-1:] in 'sx' and norm(k[:-1]) in wf else k
        wl[l] += f * 1e6
    score = {l: max(films.get(l, 0), wl.get(l, 0)) for l in set(films) | set(wl)}
    # Rang = position parmi les lemmes de Lexique : l'anglais et les noms propres du web ne décalent pas
    # les vrais lemmes ; un mot absent de Lexique (smartphone) prend le rang de son score.
    neg = sorted(-score[l] for l in films)
    out = []
    for l in sorted(score, key=lambda k: -score[k]):
        if score[l] < 0.05:
            break
        out.append((bisect.bisect_left(neg, -score[l]) + 1, l, int(l in films)))
    return out


ALPHA = 'abcdefghijlmnopqrstuvxzàâçéèêëîïôûù'


def near(w, taken):
    """Un vrai mot à une lettre près (attantif ≈ attentif) : on l'écarte, on le croirait mal orthographié."""
    for i in range(len(w) + 1):
        if i < len(w) and w[:i] + w[i + 1:] in taken:
            return True
        for c in ALPHA:
            if i < len(w) and w[:i] + c + w[i + 1:] in taken and c != w[i]:
                return True
            if w[:i] + c + w[i:] in taken:
                return True
    return False


def pseudowords(lemmas, taken, n=300, seed=1):
    """Chaîne de Markov d'ordre 3 sur des lemmes courants : des mots qui « ont l'air » français.
    Sans k / w / y (ils font anglais) et sans voisin réel à une lettre près."""
    rnd = random.Random(seed)
    model = C.defaultdict(C.Counter)
    for w in lemmas:
        s = '^^^' + w + '$'
        for i in range(3, len(s)):
            model[s[i - 3:i]][s[i]] += 1
    out = set()
    while len(out) < n:
        ctx, w = '^^^', ''
        while len(w) < 14:
            nxt = model[ctx]
            c = rnd.choices(list(nxt), weights=list(nxt.values()))[0]
            if c == '$':
                break
            w += c
            ctx = ctx[1:] + c
        if not 6 <= len(w) <= 11 or not re.fullmatch(f"[{ALPHA}]+", w):
            continue
        variants = {w, w + 's', w + 'e', w[:-1], w[:-2], w + 'r'}
        if variants & taken or near(w, taken):
            continue
        out.add(w)
    return sorted(out)


def main(lex_path, wf_path):
    films, f2l = read_lexique(lex_path)
    wf = read_wordfreq(wf_path)
    ranks = build_ranks(films, f2l, wf)
    with gzip.open(os.path.join(HERE, 'rank_fr.tsv.gz'), 'wt', encoding='utf-8') as out:
        for r, l, inlex in ranks:
            out.write(f'{r}\t{l}\t{inlex}\n')
    with gzip.open(os.path.join(HERE, 'form2lemma.json.gz'), 'wt', encoding='utf-8') as out:
        json.dump({k: v for k, v in f2l.items() if k != v}, out, ensure_ascii=False, separators=(',', ':'))
    common = [l for r, l, inlex in ranks if inlex and 1000 <= r <= 20000 and re.fullmatch(f"[{ALPHA}]{{5,}}", l)]
    taken = set(f2l) | {norm(w) for w in wf}
    with open(os.path.join(HERE, 'pseudo.txt'), 'w', encoding='utf-8') as out:
        out.write('\n'.join(pseudowords(common, taken)) + '\n')
    print(f'{len(ranks)} lemmes classés · {len(f2l)} formes · pseudo-mots écrits')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
