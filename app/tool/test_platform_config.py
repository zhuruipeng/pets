"""Run: python -m unittest discover -s tool -p test_platform_config.py"""
import base64
import unittest
from pathlib import Path

from build_mobile import build_arguments
from check_ios_region import check_region
from check_platform_config import parse_project, validate_configuration


def encoded(value):
    return base64.b64encode(value.encode()).decode()


class PlatformConfigurationTests(unittest.TestCase):
    def test_actual_project_configuration(self):
        validate_configuration(Path(__file__).resolve().parents[1])

    def test_market_is_bound_to_dart_for_all_outputs(self):
        for platform, formats in (("android", ("apk", "aab")),
                                  ("ios", ("simulator", "unsigned", "ipa"))):
            for region in ("cn", "intl"):
                for output in formats:
                    with self.subTest(platform=platform, region=region, output=output):
                        args = build_arguments(platform, region, output)
                        self.assertEqual(args[args.index("--flavor") + 1], region)
                        self.assertIn(f"--dart-define-from-file=dart_define/{region}.json", args)
                        if output == "unsigned":
                            self.assertIn("--no-codesign", args)
                        if output == "simulator":
                            self.assertIn("--simulator", args)
                            self.assertIn("--debug", args)

    def test_incompatible_output_is_rejected(self):
        for platform, output in (("ios", "apk"), ("android", "ipa")):
            with self.assertRaises(ValueError):
                build_arguments(platform, "cn", output)

    def test_ios_guard_rejects_wrong_or_missing_cn_define(self):
        for defines in ("", encoded("REGION=intl"), encoded("REGION=wrong")):
            with self.assertRaises(ValueError):
                check_region({"APP_MARKET": "cn", "DART_DEFINES": defines})

    def test_ios_guard_preserves_other_defines_and_last_region(self):
        for market in ("cn", "intl"):
            check_region({"APP_MARKET": market, "DART_DEFINES": ",".join([
                encoded("API_BASE_CN=https://example.com"),
                encoded("REGION=intl"), encoded(f"REGION={market}"),
            ])})
        check_region({"APP_MARKET": "intl"})  # 旧 Runner 默认区域

    def test_invalid_xcode_environment_is_rejected(self):
        for environment in ({}, {"APP_MARKET": "other"}, {"APP_MARKET": "cn", "DART_DEFINES": "%%%"}):
            with self.assertRaises(ValueError):
                check_region(environment)

    def test_project_parser_rejects_duplicate_keys_and_bad_syntax(self):
        for source in ("{ isa = first; isa = second; }", "{ key = (one; two); }", "{ key = missing;", "{} trailing"):
            with self.assertRaises(ValueError):
                parse_project(source)


if __name__ == "__main__":
    unittest.main()
