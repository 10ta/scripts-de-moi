# couverture

Mesure la part de mots connus d'un texte ou de sous-titres, liste les mots inconnus, donne le débit (mots/min) pour les `.srt` / `.vtt`, et compare le tout à un texte de référence.

## Démarrage

```fish
python3 couverture.py --test                       # ≈ 3 min, estime ton N (lemmes connus)
python3 couverture.py texte.txt --top 5000
python3 couverture.py *.vtt --export vcita.json.gz --top 5000
python3 couverture.py episode.srt --export vcita.json.gz --inconnus 40
python3 couverture.py a.txt b.txt --courbe        # couverture pour N = 1000 … 12000
```

Python 3 seul, aucune dépendance.

## Connus

- les N lemmes les plus fréquents (`--top`, défaut 5000 ; 2000 avec `--export`) ;
- avec `--export` : en plus, les mots marqués « 认识 » dans VCita et ceux des cartes stables (intervalle ≥ 21 j, non suspendues), comme l'onglet 短文挖词.

Après `--test`, mets la même valeur dans VCita → 设置 → 常用词前 N 个算认识.

## Lire le verdict

L'écart se lit par rapport à `ancre.txt` (*T'es pas en retard*, dictée réussie), mesuré avec les mêmes réglages :

| Écart | Usage |
| --- | --- |
| ≥ +1 | shadowing, écoute extensive |
| −2 à +1 | dictée |
| −5 à −2 | écoute intensive, avec transcription |
| < −5 | trop difficile |

Ce sont des valeurs de départ, à ajuster à l'usage. Un autre texte peut servir de référence : `--ancre fichier`.

## Trier des vidéos YouTube sans les regarder

```fish
yt-dlp --skip-download --write-auto-subs --sub-langs fr --sub-format vtt -o 'subs/%(title)s.%(ext)s' URL
python3 couverture.py subs/*.vtt --export vcita.json.gz --top 5000
```

Pour une chaîne entière : remplacer `URL` par celle de la chaîne et ajouter `--playlist-end 30`.

Les sous-titres automatiques contiennent des erreurs : le chiffre reste une estimation à ±1 point.

## Données

- `rank_fr.tsv.gz` : rang, lemme, présent dans Lexique (1/0). Score = max(fréquence Lexique 3.83 sous-titres de films, fréquence wordfreq lemmatisée) ; rang = position parmi les lemmes de Lexique, pour que l'anglais et les noms propres du web ne décalent pas les vrais lemmes.
- `form2lemma.json.gz` : forme → lemme (Lexique 3.83).
- Sources : Lexique 3.83 (New, Pallier et al., CC BY-SA 4.0) ; wordfreq 3.1 (Speer, données CC BY-SA 4.0 : Wikipédia, sous-titres, presse, livres, web, Twitter, Reddit).
- Limite : wordfreq s'arrête vers 2018–2021 et Lexique encore plus tôt ; les mots récents (*pandémie*, *télétravail*, *influenceur*) paraissent plus rares qu'ils ne le sont.
