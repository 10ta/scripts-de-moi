# couverture

[English](README.md) · **简体中文**

看一篇法语文本或一份字幕你认识多少：已知词比例、生词、语速，以及和一篇难度已知的文本相比如何。附带一个两分钟的词汇量测试，每个词按一个键作答。

```text
$ python3 couverture.py colline.md journal-0412.srt
Connus = top 8000 (test du 2026-11-21) · ancre ancre.txt = 98.8 %

 97.8 %   -1.0  plus dur que l'ancre       673 mots ·   13 inconnus distincts  colline.md
 94.4 %   -4.3  trop de mots rares          18 mots ·    1 inconnus distincts · 98 mots/min  journal-0412.srt
```
*输出是法语：这个工具属于法语学习流程。*

## 目录

- [为什么是 couverture？](#-为什么是-couverture)
- [亮点](#-亮点)
- [快速开始](#-快速开始)
- [安装](#-安装)
- [使用](#-使用)
- [配置](#-配置)
- [更新与维护](#-更新与维护)
- [工作原理](#-工作原理)
- [开发](#-开发)
- [文档地图](#-文档地图)
- [致谢](#-致谢)
- [许可](#-许可)

## 💡 为什么是 couverture？

靠耳朵找难度合适的听力、阅读材料要花几个小时。couverture 几秒内筛完文字稿和 YouTube 自动字幕，把生词过密的剔掉，只留一小批再去试听。

- ✅ 适合：中高级学习者筛选播客、视频、文章；想把自己卡片算进去的 [VCita](https://github.com/10ta/VCita) 用户。
- ❌ 不适合：判断和词汇无关的难度（语速、口音、由常用词组成的习语）——覆盖率高于约 97 % 时，去听。

## ✨ 亮点

- **一键作答的词汇量测试** —— `.` 认识，`,` 不认识，不用回车；退格撤销；连续两档低于 15 % 自动结束。
- **校正高估** —— 混入 24 个假词，按你接受假词的比例从估计里扣除。
- **记住你的水平** —— 测试结果成为之后每次运行的默认 `--top`。
- **算上你在学的** —— 给出 VCita 导出时，手动标「认识」的词和已稳定的卡算作已知。
- **批量筛选** —— 任意数量的 `.txt`、`.md`、`.srt`、`.vtt`，按覆盖率排序，字幕附每分钟词数。
- **零依赖** —— 只用 Python 3 标准库和本目录里的三个数据文件。

## 🚀 快速开始

```bash
cd /opt/scripts-de-moi/couverture
python3 couverture.py --test
python3 couverture.py ancre.txt
```

测试最后显示 `Enregistré : --top N par défaut`；第二条命令随后输出 `Connus = top N (test du …)` 和 `ancre ancre.txt = …`，差值为 `+0.0`。

## 📦 安装

无需安装，在克隆目录里直接运行。需要 Python ≥ 3.8。测试要在真正的终端里做（单键输入）；它也能读管道送来的按键，测试用例就是这样跑的。

仓库的 `update.sh` 不管 couverture：`git pull`（或 `git am`）就是更新。

## 🧭 使用

### 做词汇量测试

```bash
python3 couverture.py --test
```

按词频排名分 12 档，每档 1 000 个词，每档出 12 个真词和 2 个假词，从常用到少见。知道至少一个常用意思就算认识。按 `q` 中途退出，不保存。

### 筛选文件

```bash
python3 couverture.py subs/*.vtt --export vcita.json.gz
python3 couverture.py episode.srt --inconnus 40
```

每个文件一行，覆盖率高的在前。只给一个文件时，后面列出生词，出现次数多的在前。

### 不看视频就筛 YouTube

```bash
yt-dlp --skip-download --write-auto-subs --sub-langs fr --sub-format vtt -o 'subs/%(title)s.%(ext)s' <URL>
python3 couverture.py subs/*.vtt
```

筛整个频道：换成频道地址，加 `--playlist-end 30`。自动字幕有识别错误，数字按 ±1 个百分点看。

### 比较不同词汇量

```bash
python3 couverture.py a.txt b.txt --courbe
```

列出每个文件在 N = 1 000 … 12 000 时的覆盖率。

## 🔧 配置

| 选项 | 默认 | 含义 |
|---|---|---|
| `--top N` | 上次 `--test` 的结果，没有就是 `8000` | 词频前 N 个原形算认识 |
| `--export FILE` | — | VCita 导出（`.json` / `.json.gz`）：标了「认识」的词，以及间隔 ≥ 21 天、未暂停的卡 |
| `--ancre FILE` | `ancre.txt` | 差值一栏的参照文本；`--ancre ''` 关闭 |
| `--inconnus N` | `25` | 单个文件时列出的生词数 |
| `--courbe` | 关 | N = 1 000 … 12 000 的覆盖率表 |
| `--test` | — | 词汇量测试，保存水平 |

| 判定 | 规则 |
|---|---|
| `trop de mots rares` | 覆盖率 < 97 %：不管做什么练习都跳过 |
| `proche de l'ancre` | ≥ 97 %，比参照低不超过 1 个点 |
| `plus dur que l'ancre` | ≥ 97 %，比参照低 1 个点以上 |

水平保存在 `~/.local/state/couverture/niveau.json`（设了 `$XDG_STATE_HOME` 就放在那里）。删掉它就回到 8000。

## 🔄 更新与维护

### 更新

```bash
cd /opt/scripts-de-moi
git pull
```

### 重建数据

`rank_fr.tsv.gz`、`form2lemma.json.gz`、`pseudo.txt` 由 `build_data.py` 生成。需要 `Lexique383.txt`（在 pylexique 的 PyPI wheel 里）和 `large_fr.msgpack.gz`（在 wordfreq 的 wheel 里），以及 `msgpack` 包：

```bash
python3 build_data.py Lexique383.txt large_fr.msgpack.gz
```

## 🧠 工作原理

- **排名** → 每个原形取 max（Lexique 3.83 电影字幕词频，wordfreq 各词形词频之和）；排名只在 Lexique 收录的原形里算，网页语料里的英语词和人名不会把法语原形往后挤。
- **覆盖率** → 每个词还原成原形（Lexique 词形表）；虚词、前 N 个原形、VCita 里已知的原形算认识；全文只以大写出现的词当专有名词跳过。
- **测试估计** → 每档（真词认识率 − 假词认识率）/（1 − 假词认识率）× 1 000，相加；保存时向下取到 500 的整数倍。
- **为什么是底线，不分档** → 词汇量到 8 000 时，普通文本几乎都在 97–99 %：覆盖率只能区分「生词太多」和其余，分不出更细的难度。完整推理见[手册](docs/MANUAL.zh-CN.md)。

## 🔨 开发

```bash
python3 -m unittest discover couverture/tests
```

离线、无依赖：覆盖率、字幕、测试估计、撤销、自动结束和保存的水平。

## 📚 文档地图

- [docs/MANUAL.zh-CN.md](docs/MANUAL.zh-CN.md)：完整中文手册——怎么读数字、测试、数据来源与局限。
- [../AGENTS.md](../AGENTS.md)：给 AI 编码代理的约定与检查清单。

## 🙏 致谢

- [Lexique 3.83](http://www.lexique.org) —— New、Pallier 等，CC BY-SA 4.0。
- [wordfreq](https://github.com/rspeer/wordfreq) —— Robyn Speer；数据 CC BY-SA 4.0。

## 📄 许可

暂无许可证文件，默认保留所有权利。数据文件源自 CC BY-SA 4.0 的来源。见[仓库 README](../README.zh-CN.md#-许可)。
