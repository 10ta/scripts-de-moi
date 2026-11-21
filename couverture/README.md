# couverture

**English** · [简体中文](README.zh-CN.md)

Tells you how much of a French text or subtitle file you already know: share of known words, the unknown ones, speech rate, and how it compares with a text whose difficulty you know. Includes a two-minute vocabulary test answered with one key per word.

```text
$ python3 couverture.py colline.md journal-0412.srt
Connus = top 8000 (test du 2026-11-21) · ancre ancre.txt = 98.8 %

 97.8 %   -1.0  plus dur que l'ancre       673 mots ·   13 inconnus distincts  colline.md
 94.4 %   -4.3  trop de mots rares          18 mots ·    1 inconnus distincts · 98 mots/min  journal-0412.srt
```
*Output is in French: this tool is part of a French-learning routine.*

## Contents

- [Why couverture?](#-why-couverture)
- [Highlights](#-highlights)
- [Quick Start](#-quick-start)
- [Installation](#-installation)
- [Usage](#-usage)
- [Configuration](#-configuration)
- [Update & Maintenance](#-update--maintenance)
- [How It Works](#-how-it-works)
- [Development](#-development)
- [Documentation](#-documentation)
- [Acknowledgements](#-acknowledgements)
- [License](#-license)

## 💡 Why couverture?

Finding listening or reading material at the right level by ear takes hours. couverture screens transcripts and YouTube auto-subtitles in seconds and rejects the ones too dense in rare words, so only a short list is left to try by ear.

- ✅ Good fit: an intermediate-to-advanced learner sorting podcasts, videos or articles; a [VCita](https://github.com/10ta/VCita) user who wants their own cards counted.
- ❌ Not a fit: judging difficulty that isn't about vocabulary (speed, accent, idioms made of common words) — above ≈ 97 % coverage, listen instead.

## ✨ Highlights

- **One-key vocabulary test** — `.` known, `,` unknown, no Enter; Backspace undoes; stops by itself once two bands fall under 15 %.
- **Corrects for optimism** — 24 pseudo-words are mixed in; the share you accept is subtracted from the estimate.
- **Remembers your level** — the test result becomes the default `--top` for every later run.
- **Counts what you study** — with a VCita export, your manually known words and stable cards count as known.
- **Batch screening** — any number of `.txt`, `.md`, `.srt`, `.vtt` files, sorted, with words per minute for subtitles.
- **No dependencies** — Python 3 standard library and three data files in this directory.

## 🚀 Quick Start

```bash
cd /opt/scripts-de-moi/couverture
python3 couverture.py --test
python3 couverture.py ancre.txt
```

The test ends with `Enregistré : --top N par défaut`; the second command then prints `Connus = top N (test du …)` and `ancre ancre.txt = …` with a `+0.0` gap.

## 📦 Installation

Nothing to install: run it from the clone. Requires Python ≥ 3.8. The test needs a real terminal (single-key input); it also reads piped keys, which the tests use.

The repository-wide `update.sh` does not cover couverture — a `git pull` (or `git am`) is the update.

## 🧭 Usage

### Take the vocabulary test

```bash
python3 couverture.py --test
```

12 bands of 1 000 frequency ranks, 12 words and 2 pseudo-words each, from frequent to rare. Mark a word known if you know at least one common meaning. `q` stops without saving.

### Screen files

```bash
python3 couverture.py subs/*.vtt --export vcita.json.gz
python3 couverture.py episode.srt --inconnus 40
```

One line per file, best first. With a single file, the unknown words follow, most frequent first.

### Screen YouTube videos without watching them

```bash
yt-dlp --skip-download --write-auto-subs --sub-langs fr --sub-format vtt -o 'subs/%(title)s.%(ext)s' <URL>
python3 couverture.py subs/*.vtt
```

For a whole channel, pass the channel URL and add `--playlist-end 30`. Auto-subtitles contain errors: read the figure as ±1 point.

### Compare vocabulary sizes

```bash
python3 couverture.py a.txt b.txt --courbe
```

Coverage of each file for N = 1 000 … 12 000.

## 🔧 Configuration

| Option | Default | Meaning |
|---|---|---|
| `--top N` | last `--test`, else `8000` | The N most frequent lemmas count as known |
| `--export FILE` | — | VCita export (`.json` / `.json.gz`): words marked 认识 and cards with interval ≥ 21 days, not suspended |
| `--ancre FILE` | `ancre.txt` | Reference text for the gap column; `--ancre ''` turns it off |
| `--inconnus N` | `25` | Unknown words listed for a single file |
| `--courbe` | off | Coverage table for N = 1 000 … 12 000 |
| `--test` | — | Vocabulary test; saves the level |

| Verdict | Rule |
|---|---|
| `trop de mots rares` | coverage < 97 % — skip it, whatever the exercise |
| `proche de l'ancre` | ≥ 97 % and at most 1 point under the reference |
| `plus dur que l'ancre` | ≥ 97 % and more than 1 point under |

The level is stored in `~/.local/state/couverture/niveau.json` (`$XDG_STATE_HOME` if set). Delete it to fall back to 8000.

## 🔄 Update & Maintenance

### Update

```bash
cd /opt/scripts-de-moi
git pull
```

### Rebuild the data

`rank_fr.tsv.gz`, `form2lemma.json.gz` and `pseudo.txt` come from `build_data.py`. It needs `Lexique383.txt` (inside the PyPI wheel of pylexique) and `large_fr.msgpack.gz` (inside the wheel of wordfreq), plus the `msgpack` package:

```bash
python3 build_data.py Lexique383.txt large_fr.msgpack.gz
```

## 🧠 How It Works

- **Ranks** → each lemma scores max(Lexique 3.83 film-subtitle frequency, wordfreq frequency summed over its forms); rank = position among Lexique lemmas, so English words and names from web corpora don't push French lemmas down.
- **Coverage** → every token is lemmatised (Lexique forms); function words, lemmas in the top N and VCita-known lemmas count as known; capitalised words never seen in lower case are skipped as names.
- **Test estimate** → per band, (yes rate − pseudo-word yes rate) / (1 − pseudo-word yes rate), × 1 000, summed; saved rounded down to 500.
- **Why a floor, not bands** → at 8 000 lemmas almost any ordinary text scores 97–99 %: coverage separates "too many rare words" from the rest, and nothing finer. The full reasoning is in the [manual](docs/MANUAL.zh-CN.md).

## 🔨 Development

```bash
python3 -m unittest discover couverture/tests
```

Offline, no dependencies: coverage, subtitles, the test estimate, undo, early stop and the saved level.

## 📚 Documentation

- [docs/MANUAL.zh-CN.md](docs/MANUAL.zh-CN.md): Full Chinese manual — how to read the numbers, the test, data sources and limits.
- [../AGENTS.md](../AGENTS.md): Conventions and checks for AI coding agents working on this repo.

## 🙏 Acknowledgements

- [Lexique 3.83](http://www.lexique.org) — New, Pallier et al., CC BY-SA 4.0.
- [wordfreq](https://github.com/rspeer/wordfreq) — Robyn Speer; data CC BY-SA 4.0.

## 📄 License

No license file yet; all rights reserved by default. The data files derive from CC BY-SA 4.0 sources. See the [repository README](../README.md#-license).
