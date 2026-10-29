#!/usr/bin/env python3
"""Prepare PCC signing only from an explicitly supplied Apple provisioning profile."""
import argparse
import datetime
import hashlib
import os
import pathlib
import plistlib
import re
import subprocess


def validated_entitlements(profile, bundle_id, certificate_hash, now=None):
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("com.apple.developer.private-cloud-compute") is not True:
        raise ValueError("The profile does not grant Apple's Private Cloud Compute entitlement.")
    teams = profile.get("TeamIdentifier", [])
    team = entitlements.get("com.apple.developer.team-identifier")
    if not team or team not in teams:
        raise ValueError("The profile has no consistent Apple team identifier.")
    application = entitlements.get("com.apple.application-identifier", entitlements.get("application-identifier"))
    if application != f"{team}.{bundle_id}":
        raise ValueError("The profile must grant PCC to this exact Positronic bundle identifier.")
    if not set(profile.get("Platform", [])) & {"OSX", "macOS"}:
        raise ValueError("Use a macOS provisioning profile.")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime):
        raise ValueError("The profile has no expiration date.")
    expires = expires.replace(tzinfo=datetime.timezone.utc) if expires.tzinfo is None else expires
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if expires <= now:
        raise ValueError("The provisioning profile has expired.")
    allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
    if certificate_hash.upper() not in allowed:
        raise ValueError("The selected signing certificate is not permitted by this profile.")
    return {
        "com.apple.developer.private-cloud-compute": True,
        "com.apple.application-identifier": application,
        "com.apple.developer.team-identifier": team,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=pathlib.Path, required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], check=True, capture_output=True, text=True).stdout
        matches = [fingerprint for fingerprint, name in re.findall(r'\b([A-Fa-f0-9]{40})\s+"([^"\n]+)"', identities)
                   if args.identity == name or args.identity.upper() == fingerprint.upper()]
        if len(matches) != 1:
            raise ValueError("Choose one valid signing identity; use its certificate SHA-1 if the name is ambiguous.")
        decoded = subprocess.run(["security", "cms", "-D", "-i", str(args.profile)], check=True, capture_output=True).stdout
        profile = plistlib.loads(decoded)
        result = validated_entitlements(profile, args.bundle_id, matches[0])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(plistlib.dumps(result))
        os.chmod(args.output, 0o600)
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"PCC signing is not ready: {error}\n")


if __name__ == "__main__":
    main()
