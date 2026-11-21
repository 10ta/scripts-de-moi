"""Tests hors ligne de couverture : python3 -m unittest discover couverture/tests"""
import io, json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import couverture as cv

LEX = cv.Lex()
PSEUDO = set(open(os.path.join(cv.HERE, 'pseudo.txt'), encoding='utf-8').read().split())


class Analyse(unittest.TestCase):
    def test_lemmes_et_mots_outils(self):
        t, k, unk = cv.analyse(LEX, "Les enfants mangeaient des pommes.", 3000, set())
        self.assertEqual((t, k), (5, 5))                     # mangeaient → manger, pommes → pomme
        t, k, unk = cv.analyse(LEX, "Une furtivité troublante.", 2000, set())
        self.assertIn('furtivité', unk)

    def test_nom_propre_ignore(self):
        t, _, unk = cv.analyse(LEX, "Inès regarde Hamid. Inès sourit.", 2000, set())
        self.assertNotIn('inès', unk)
        self.assertEqual(t, 2)                               # regarde, sourit

    def test_connus_de_vcita(self):
        _, _, unk = cv.analyse(LEX, "Une furtivité troublante.", 2000, {'furtivité'})
        self.assertNotIn('furtivité', unk)

    def test_pseudo_mots_absents_des_donnees(self):
        self.assertGreaterEqual(len(PSEUDO), 100)
        self.assertFalse({p for p in PSEUDO if p in LEX.rank or p in LEX.f2l})


class SousTitres(unittest.TestCase):
    def test_duree_et_doublons(self):
        srt = "1\n00:00:01,000 --> 00:00:04,000\nBonjour à tous.\n\n2\n00:00:04,000 --> 00:01:01,000\n<i>Bonjour à tous.</i>\nOn commence.\n"
        with tempfile.NamedTemporaryFile('w', suffix='.srt', delete=False, encoding='utf-8') as f:
            f.write(srt)
        text, dur = cv.read_input(f.name)
        os.unlink(f.name)
        self.assertEqual(text, 'Bonjour à tous.\nOn commence.')
        self.assertEqual(dur, 60)


class TestVocabulaire(unittest.TestCase):
    def run_test(self, keys, **kw):
        out = io.StringIO()
        return cv.vocab_test(LEX, keys, out=out, seed=1, save=False, **kw), out.getvalue()

    def test_estimation_et_arret_automatique(self):
        # connaît tout jusqu'au rang 5000, rien au-delà, rejette les pseudo-mots
        r, out = self.run_test(lambda w: ',' if w in PSEUDO or (LEX.rank.get(w, 10**6) > 5000) else '.')
        self.assertEqual(r['top'], 5000)
        self.assertEqual(r['pseudo'], '0/14')                # arrêt après la 7e tranche : 7 × 2 pseudo-mots
        self.assertIn("on s'arrête", out)

    def test_correction_par_les_pseudo_mots(self):
        # dit « connu » à tout : la correction ramène l'estimation à zéro
        r, _ = self.run_test(lambda w: '.')
        self.assertEqual(r['brut'], 12000)
        self.assertEqual(r['top'], 0)

    def test_retour_arriere(self):
        r, _ = self.run_test(['.', '\x7f', ',', ','], bands=1, per_band=2, pseudo_per_band=0)
        self.assertEqual(r['brut'], 0)
        r, _ = self.run_test(['.', ','], bands=1, per_band=2, pseudo_per_band=0)
        self.assertEqual(r['brut'], 500)

    def test_arret_manuel_n_enregistre_rien(self):
        with tempfile.TemporaryDirectory() as d:
            cv.STATE = os.path.join(d, 'niveau.json')
            r = cv.vocab_test(LEX, ['.'] * 20 + ['q'], out=io.StringIO(), seed=1)
            self.assertFalse(r['complet'])
            self.assertFalse(os.path.exists(cv.STATE))

    def test_niveau_enregistre_sert_de_top(self):
        with tempfile.TemporaryDirectory() as d:
            cv.STATE = os.path.join(d, 'niveau.json')
            cv.vocab_test(LEX, lambda w: ',' if w in PSEUDO or LEX.rank.get(w, 10**6) > 3000 else '.', out=io.StringIO(), seed=2)
            self.assertEqual(json.load(open(cv.STATE))['top'], 3000)
            txt = os.path.join(d, 't.txt')
            open(txt, 'w', encoding='utf-8').write('Bonjour.')
            out = io.StringIO()
            sys.stdout, old = out, sys.stdout
            try:
                cv.main([txt, '--ancre', ''])
            finally:
                sys.stdout = old
            self.assertIn('top 3000 (test du', out.getvalue())


if __name__ == '__main__':
    unittest.main()
