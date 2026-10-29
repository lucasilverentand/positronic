import copy
import datetime
import hashlib
import unittest
from script.prepare_pcc_signing import validated_entitlements


class PCCSigningTests(unittest.TestCase):
    def setUp(self):
        self.bundle_id = "nl.lucasilverentand.mac-model-api"
        self.now = datetime.datetime(2026, 10, 29, tzinfo=datetime.timezone.utc)
        self.certificate = b"synthetic profile certificate"
        self.fingerprint = hashlib.sha1(self.certificate).hexdigest()
        self.profile = {
            "Platform": ["OSX"], "TeamIdentifier": ["FIXTURETEAM"],
            "ExpirationDate": datetime.datetime(2026, 11, 29),
            "DeveloperCertificates": [self.certificate],
            "Entitlements": {
                "com.apple.developer.private-cloud-compute": True,
                "com.apple.application-identifier": "FIXTURETEAM." + self.bundle_id,
                "com.apple.developer.team-identifier": "FIXTURETEAM",
                "unrelated-capability": True,
            },
        }

    def validate(self, profile=None, fingerprint=None):
        return validated_entitlements(profile or self.profile, self.bundle_id, fingerprint or self.fingerprint, self.now)

    def test_valid_profile_produces_only_required_entitlements(self):
        result = self.validate()
        self.assertTrue(result["com.apple.developer.private-cloud-compute"])
        self.assertEqual(len(result), 3)
        self.assertNotIn("unrelated-capability", result)

    def test_missing_grant_wrong_app_team_or_platform_are_rejected(self):
        for section, key, value in [
            ("Entitlements", "com.apple.developer.private-cloud-compute", False),
            ("Entitlements", "com.apple.application-identifier", "FIXTURETEAM.*"),
            ("Entitlements", "com.apple.developer.team-identifier", "OTHERTEAM"),
            (None, "Platform", ["iOS"]),
        ]:
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                (profile[section] if section else profile)[key] = value
                with self.assertRaises(ValueError): self.validate(profile)

    def test_expired_profile_or_unapproved_certificate_is_rejected(self):
        expired = copy.deepcopy(self.profile)
        expired["ExpirationDate"] = self.now - datetime.timedelta(seconds=1)
        with self.assertRaises(ValueError): self.validate(expired)
        with self.assertRaises(ValueError): self.validate(fingerprint="0" * 40)


if __name__ == "__main__":
    unittest.main()
