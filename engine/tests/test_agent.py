import os
import socket
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agents"))
from cooperative import CacheAgent, MIB, private_session, request
from demo_cache import MapCache


class AgentTests(unittest.TestCase):
    def setUp(self):
        self.cache = MapCache(4)
        self.token = "a" * 64
        self.latency = 1.0
        self.agent = CacheAgent(self.cache, self.token, lambda: self.latency).start()

    def tearDown(self):
        self.agent.close()
        self.cache.close()

    def raw(self, message):
        with socket.create_connection(("127.0.0.1", self.agent.port), timeout=2) as s:
            s.sendall(message)
            return s.recv(512).decode("ascii")

    def test_status_has_no_mutation(self):
        value = request(self.agent.port, self.token)
        self.assertEqual(value[:3], (os.getpid(), 4 * MIB, 0))
        self.assertEqual(self.cache.size_bytes(), 4 * MIB)

    def test_release_and_process_remains_alive(self):
        result = request(self.agent.port, self.token, "RECLAIM", 2 * MIB)
        self.assertEqual(result[:3], (os.getpid(), 2 * MIB, 2 * MIB))
        self.assertEqual(request(self.agent.port, self.token)[0], os.getpid())

    def test_wrong_token_rejected_without_changes(self):
        with self.assertRaises(RuntimeError):
            request(self.agent.port, "b" * 64, "RECLAIM", MIB)
        self.assertEqual(self.cache.size_bytes(), 4 * MIB)

    def test_no_execute_or_arbitrary_command(self):
        self.assertIn("ERR request", self.raw(f"AME1 {self.token} EXECUTE 1\n".encode()))
        self.assertEqual(self.cache.size_bytes(), 4 * MIB)

    def test_budget_is_bounded(self):
        for n in [0, -1, 64 * MIB + 1]:
            with self.assertRaises(RuntimeError):
                request(self.agent.port, self.token, "RECLAIM", n)
        self.assertEqual(self.cache.size_bytes(), 4 * MIB)

    def test_cooldown_cannot_be_bypassed_by_client(self):
        request(self.agent.port, self.token, "RECLAIM", MIB)
        with self.assertRaises(RuntimeError):
            request(self.agent.port, self.token, "RECLAIM", MIB)
        self.assertEqual(self.cache.size_bytes(), 3 * MIB)

    def test_busy_application_declines(self):
        self.latency = 21
        with self.assertRaises(RuntimeError):
            request(self.agent.port, self.token, "RECLAIM", MIB)
        self.assertEqual(self.cache.size_bytes(), 4 * MIB)

    def test_invalid_latency_declines(self):
        self.latency = float("nan")
        with self.assertRaises(RuntimeError):
            request(self.agent.port, self.token, "RECLAIM", MIB)
        self.assertEqual(self.cache.size_bytes(), 4 * MIB)

    def test_multiple_frames_rejected(self):
        line = f"AME1 {self.token} RECLAIM {MIB}\n"
        self.assertIn("ERR frame", self.raw((line + line).encode()))
        self.assertEqual(self.cache.size_bytes(), 4 * MIB)

    def test_closed_map_is_unusable(self):
        mapping = self.cache._maps[-1]
        request(self.agent.port, self.token, "RECLAIM", MIB)
        with self.assertRaises(ValueError):
            mapping.read(1)

    def test_map_granularity_respects_budget(self):
        self.assertEqual(self.cache.release(MIB - 1), 0)
        self.assertEqual(self.cache.size_bytes(), 4 * MIB)

    def test_private_session_is_new_and_protected(self):
        with tempfile.TemporaryDirectory() as temp:
            session = Path(temp) / "session"
            token = private_session(session)
            self.assertEqual(len(token), 64)
            self.assertEqual((session / "token.txt").read_text().strip(), token)
            with self.assertRaises(OSError):
                private_session(session)
            if os.name != "nt":
                self.assertEqual(session.stat().st_mode & 0o777, 0o700)
                self.assertEqual((session / "token.txt").stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main(verbosity=2)
