"""traffic-bot 本地测试：不联网，查询函数和外部接口都换成假的。

需要 bot 的依赖，用部署时的 venv 运行：
  /opt/traffic-bot/venv/bin/python -m unittest discover traffic-bot/tests
"""
import asyncio
import importlib.util
import os
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bot", os.path.join(HERE, "..", "bot.py"))
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)


def section(name):
    return lambda: bot.Section(f"<b>{name}</b>", [bot.Metric(f"k:{name}", name, 10, "p", "1 / 10")])


def slow():
    time.sleep(1.5)
    return bot.Section("slow")


class CollectTest(unittest.TestCase):
    def setUp(self):
        bot._cache.update(ts=0.0, data=[])
        bot._cache_lock = None

    def test_slow_provider_times_out_without_blocking_others(self):
        providers = [(lambda: True, section("A"), "A", ("G", "a")),
                     (lambda: True, slow, "Slow", ("G", "s"))]
        async def timed():  # 在事件循环里计时：asyncio.run 退出时还会等超时那个线程跑完，那段不算
            t0 = time.monotonic()
            res = await bot.collect_sections(max_age=0)
            return res, time.monotonic() - t0

        with mock.patch.object(bot, "PROVIDERS", providers), mock.patch.object(bot, "PROVIDER_TIMEOUT_SEC", 0.3):
            secs, took = asyncio.run(timed())
        self.assertLess(took, 1.0)
        self.assertEqual(secs[0].text, "<b>A</b>")
        self.assertIn("查询超时", secs[1].text)
        self.assertEqual(secs[1].name, "Slow")


class AlertStateTest(unittest.TestCase):
    def test_stale_keys_are_pruned(self):
        state = {"gone": {"period": "2026-09", "level": 80, "seen": "2026-09-01"},
                 "recent": {"period": "2026-10", "level": 0, "seen": "2026-10-30"}}
        m = bot.Metric("k", "K", 96, "2026-11", "96 / 100")
        msgs = bot.evaluate_alerts([m], state, today="2026-11-01")
        self.assertEqual(len(msgs), 1)  # 第一次越过 95%
        self.assertNotIn("gone", state)
        self.assertIn("recent", state)
        self.assertEqual(state["k"], {"period": "2026-11", "level": 95, "seen": "2026-11-01"})
        self.assertEqual(bot.evaluate_alerts([m], state, today="2026-11-01"), [])  # 同一档不重复推


class CloudflareFallbackTest(unittest.TestCase):
    def setUp(self):
        bot._no_cpu.clear()

    def test_missing_field_is_remembered(self):
        calls = []

        def fake(template, **params):
            calls.append(params["fields"])
            if "cpuTimeUs" in params["fields"]:
                raise bot.CFError('Cannot query field "cpuTimeUs"')
            return {"viewer": {"accounts": [{"ds": [{"sum": {"requests": 5}}]}]}}

        with mock.patch.object(bot, "cf_graphql", fake):
            self.assertEqual(bot.cf_invocations("q", "ds")[1], False)
            bot.cf_invocations("q", "ds")
        self.assertEqual(calls, ["requests cpuTimeUs", "requests", "requests"])

    def test_network_error_is_not_remembered(self):
        with mock.patch.object(bot, "cf_graphql", side_effect=bot.CFError("网络错误 ConnectTimeout")):
            with self.assertRaises(bot.CFError):
                bot.cf_invocations("q", "ds")
        self.assertNotIn("ds", bot._no_cpu)


class CacheTest(unittest.TestCase):
    def test_cached_calls_once_within_ttl(self):
        bot._slow_cache.clear()
        fn = mock.Mock(return_value=42)
        self.assertEqual(bot.cached("x", fn), 42)
        self.assertEqual(bot.cached("x", fn), 42)
        fn.assert_called_once()


class SondeTest(unittest.TestCase):
    def test_payload_is_scrubbed_and_has_no_html(self):
        sec = bot.Section("<b>X</b> 1.2.3.4", [bot.Metric("k", "K", 50, "p", "5 / 10", limit=10, unit="GB")],
                          name="X", group="G", notes=["host a.example.com"])
        with mock.patch.object(bot, "SONDE_URL", "https://sonde.test"), mock.patch.object(bot, "SONDE_TOKEN", "t"), \
                mock.patch.object(bot.requests, "post") as post:
            post.return_value.status_code = 200
            bot.sonde_report([sec])
        card = post.call_args.kwargs["json"]["data"]["providers"][0]
        self.assertNotIn("html", card)
        self.assertEqual(card["notes"], ["host ***"])


if __name__ == "__main__":
    unittest.main()
