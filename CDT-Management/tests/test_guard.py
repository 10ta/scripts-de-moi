"""cdt-guard 本地测试：起一个假的阿里云 API（ALI_ENDPOINT_OVERRIDE）和假的 Sonde，不需要真实账号。

运行：python3 -m unittest discover CDT-Management/tests
"""
import importlib.util
import json
import os
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("cdt_guard", os.path.join(HERE, "..", "cdt_guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def instance(status="Running"):
    return {"Instances": {"Instance": [{
        "Status": status, "InstanceName": "test", "InstanceChargeType": "PostPaid",
        "PublicIpAddress": {"IpAddress": []}, "EipAddress": {}, "SecurityGroupIds": {"SecurityGroupId": ["sg-1"]},
        "InternetMaxBandwidthOut": 100}]}}


def traffic(gb):
    return {"TrafficDetails": [{"BusinessRegionId": "cn-hongkong", "Traffic": gb * guard.GIB}]} if gb is not None \
        else {"TrafficDetails": []}


class FakeAliyun(BaseHTTPRequestHandler):
    """按 Action 返回 server.responses 里的内容；值是 int 时当作 HTTP 状态码返回错误"""

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.endswith("/ingest"):
            self.server.ingest.append(json.loads(body))
            return self._send(200, {})
        action = urllib.parse.parse_qs(body.decode())["Action"][0]
        self.server.calls.append(action)
        r = self.server.responses.get(action, {})
        if isinstance(r, int):
            return self._send(r, {"Code": f"HTTP{r}", "Message": "fake error"})
        self._send(200, r)

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass


class GuardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeAliyun)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.srv.calls, self.srv.ingest, self.srv.responses = [], [], {}
        self.cfg = guard.Config({
            "ALI_AK": "ak", "ALI_SK": "sk", "ALI_REGION": "cn-hongkong", "ALI_INSTANCE_ID": "i-1",
            "STATE_DIR": self.tmp.name, "ALI_ENDPOINT_OVERRIDE": self.base,
            "SONDE_URL": self.base, "SONDE_TOKEN": "t", "GUARD_KEEPALIVE": "1"})
        guard.time.sleep = lambda s: None  # 重试间隔不真等

    def tearDown(self):
        self.tmp.cleanup()

    def state(self, **kw):
        if kw:
            guard.save_state(self.cfg, kw)
        return guard.load_state(self.cfg)

    def test_empty_reading_mid_month_keeps_fuse(self):
        """熔断中、同一个月里读数突然为空：不能解除熔断，也不能开机"""
        self.state(locked=True, lock_cycle=guard.bill_cycle(), used_gb=199.5)
        self.srv.responses = {"ListCdtInternetTraffic": traffic(None), "DescribeInstances": instance("Stopped")}
        self.assertEqual(guard.check(self.cfg), 0)
        self.assertNotIn("StartInstance", self.srv.calls)
        self.assertTrue(self.state()["locked"])

    def test_new_month_releases_fuse_and_starts(self):
        """换月后流量归零：解除熔断并开机"""
        self.state(locked=True, lock_cycle="2000-01", used_gb=199.5)
        self.srv.responses = {"ListCdtInternetTraffic": traffic(0.2), "DescribeInstances": instance("Stopped")}
        guard.check(self.cfg)
        self.assertIn("StartInstance", self.srv.calls)
        st = self.state()
        self.assertFalse(st["locked"])
        self.assertNotIn("lock_cycle", st)

    def test_over_limit_stops_and_records_cycle(self):
        self.srv.responses = {"ListCdtInternetTraffic": traffic(199.2), "DescribeInstances": instance("Running")}
        guard.check(self.cfg)
        self.assertIn("StopInstance", self.srv.calls)
        st = self.state()
        self.assertTrue(st["locked"])
        self.assertEqual(st["lock_cycle"], guard.bill_cycle())

    def test_stop_is_sent_once_on_server_error(self):
        """会改状态的操作不重试"""
        self.srv.responses = {"ListCdtInternetTraffic": traffic(199.2), "DescribeInstances": instance("Running"),
                              "StopInstance": 503}
        guard.check(self.cfg)
        self.assertEqual(self.srv.calls.count("StopInstance"), 1)

    def test_query_failure_is_counted(self):
        self.srv.responses = {"ListCdtInternetTraffic": 503}
        self.assertEqual(guard.check(self.cfg), 1)
        self.assertEqual(self.srv.calls.count("ListCdtInternetTraffic"), 3)  # 查询类重试 3 次
        self.assertEqual(self.state()["fail"], 1)

    def test_sonde_heartbeat(self):
        """状态没变时第二轮不上报；状态变了马上上报"""
        self.srv.responses = {"ListCdtInternetTraffic": traffic(10), "DescribeInstances": instance("Running")}
        guard.check(self.cfg)
        guard.check(self.cfg)
        self.assertEqual(len(self.srv.ingest), 1)
        self.assertEqual(self.srv.ingest[0]["interval"], guard.SONDE_HEARTBEAT)
        self.srv.responses["ListCdtInternetTraffic"] = traffic(199.5)  # 触发熔断 → locked 变化
        guard.check(self.cfg)
        self.assertEqual(len(self.srv.ingest), 2)

    def test_redact_ipv6(self):
        self.assertNotIn("2606:4700", guard._redact("connect to 2606:4700:4700::1111 failed"))


if __name__ == "__main__":
    unittest.main()
