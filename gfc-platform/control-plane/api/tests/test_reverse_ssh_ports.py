import unittest

from app.reverse_ssh import port_release_cooldown_seconds, ports_per_device, ssh_port_max, ssh_port_min
from app.settings import settings


class ReverseSSHPortPolicyTest(unittest.TestCase):
    def test_port_release_cooldown_default(self) -> None:
        self.assertGreaterEqual(port_release_cooldown_seconds(), 0)
        self.assertEqual(settings.reverse_ssh_port_release_cooldown_seconds, 3600)

    def test_port_pool_bounds(self) -> None:
        step = ports_per_device()
        self.assertGreaterEqual(step, 1)
        self.assertLessEqual(ssh_port_min(), ssh_port_max())
        self.assertGreater(ssh_port_max(), settings.client_ssh_port_base)


if __name__ == "__main__":
    unittest.main()
