"""Offline ownership transitions for legacy and M5 fan-mode keys."""
import importlib.util
from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest


class FanModeTests(unittest.TestCase):
    def controller(self, mode_key):
        path = Path(__file__).resolve().parents[1] / "daemon" / "fanctld.py"
        spec = importlib.util.spec_from_file_location("fanctld_mode_test", path)
        f = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(f)
        hardware = {"mode": 1, "rpm": 2000.0}
        statuses = []

        def helper(*args):
            output, code = "", 0
            if args == ("probe",):
                output = (
                    "fans=2\n"
                    "fan0 actual=2000 target=2000 min=2000 max=6000 "
                    "mode=manual mode_key=%s\n"
                    "fan1 actual=2000 target=2000 min=2000 max=6000 "
                    "mode=manual mode_key=%s\n"
                ) % (mode_key, mode_key.replace("F0", "F1"))
            elif args[0] == "get":
                if args[1] == mode_key:
                    output = "%s type=ui8  size=1 value=%.1f\n" % (
                        mode_key, hardware["mode"])
                elif args[1] == "F0Ac":
                    output = "F0Ac type=flt  size=4 value=%.1f\n" % hardware["rpm"]
                else:
                    code = 1
            elif args[0] == "set":
                if hardware["mode"] == 3:
                    code = 3
                else:
                    hardware.update(mode=1, rpm=float(args[1]))
            else:
                raise AssertionError("Unexpected SMC operation: %r" % (args,))
            return subprocess.CompletedProcess(args, code, stdout=output, stderr="")

        f.smcfan = helper
        f.log = lambda message: None
        f.write_status = statuses.append
        f.save_model = lambda *args, **kwargs: None
        f.handle_command = lambda: None
        f.read_power_watts = lambda: 8.0
        f.time = SimpleNamespace(time=lambda: 1000.0)
        self.assertTrue(f.probe_fans())
        f.state.update(
            manual=True, rpm=2000.0, written=2000.0,
            ticks=f.MODE_REASSERT - 1, last_temp=55.0, tm=f.tm_init(),
        )
        return f, hardware, statuses

    def test_system_reclaim_clears_stale_manual_status(self):
        for key in ("F0Md", "F0md"):
            with self.subTest(mode_key=key):
                f, hardware, statuses = self.controller(key)
                hardware["mode"] = 0
                f.control_tick(55.0)
                self.assertFalse(f.state["manual"])
                self.assertEqual(f.state["written"], 0.0)
                self.assertEqual(statuses[-1], "auto")

    def test_smart_control_reengages_after_system_reclaim(self):
        for key in ("F0Md", "F0md"):
            with self.subTest(mode_key=key):
                f, hardware, statuses = self.controller(key)
                hardware["mode"] = 0
                f.control_tick(55.0)
                f.control_tick(55.0)
                self.assertEqual(hardware["mode"], 1)
                self.assertTrue(f.state["manual"])
                self.assertEqual(statuses[-1], "manual")

    def test_firmware_override_is_not_forced_into_manual_control(self):
        for key in ("F0Md", "F0md"):
            with self.subTest(mode_key=key):
                f, hardware, statuses = self.controller(key)
                hardware["mode"] = 3
                f.control_tick(55.0)
                f.control_tick(55.0)
                self.assertEqual(hardware["mode"], 3)
                self.assertFalse(f.state["manual"])
                self.assertEqual(f.state["err"], "fan_control_yield")
                self.assertGreater(f.state["smc_until"], 1000.0)


if __name__ == "__main__":
    unittest.main()
