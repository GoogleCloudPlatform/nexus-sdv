"""The subject names the format and the vehicle.

Run:  python3 -m unittest discover -s tests   (no dependencies needed)
"""
import unittest

from nexus_sdk.subjects import telemetry_subject


class TelemetrySubject(unittest.TestCase):
    def test_family_then_vin(self):
        self.assertEqual(telemetry_subject("VIN1"), "telemetry.VIN1")

    def test_a_vin_that_would_change_the_subject_is_refused(self):
        for vin in ["", "A.B", "A B", "A*", "A>"]:
            with self.assertRaises(ValueError, msg=repr(vin)):
                telemetry_subject(vin)


if __name__ == "__main__":
    unittest.main()
