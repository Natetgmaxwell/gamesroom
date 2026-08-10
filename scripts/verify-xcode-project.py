#!/usr/bin/env python3

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "GamesRoom.xcodeproj" / "project.pbxproj"
SOURCE_ROOT = ROOT / "GamesRoom"
# W2.3 — the widget extension + watch app targets live outside the
# main app source root. Scan them too so their files are verified
# against the pbxproj like the app's are.
EXTRA_SOURCE_ROOTS = [ROOT / "GamesRoomWidgets", ROOT / "GamesRoomWatch"]

errors: list[str] = []
text = PROJECT.read_text()

file_reference_pattern = re.compile(
    r"(?P<id>[A-Fa-f0-9]{24}) /\* (?P<name>[^*]+) \*/ = "
    r"\{isa = PBXFileReference; (?P<attributes>[^}]+)\};"
)
path_pattern = re.compile(r"\bpath = (?P<path>[^;]+);")
source_files_by_name: dict[str, list[Path]] = {}

for source_root in [SOURCE_ROOT, *EXTRA_SOURCE_ROOTS]:
    for source_file in source_root.rglob("*.swift"):
        source_files_by_name.setdefault(source_file.name, []).append(source_file)

referenced_swift_files: set[str] = set()
for match in file_reference_pattern.finditer(text):
    attributes = match.group("attributes")
    if "lastKnownFileType = sourcecode.swift;" not in attributes:
        continue
    path_match = path_pattern.search(attributes)
    if not path_match:
        errors.append(f"{match.group('name')}: missing path")
        continue
    file_name = Path(path_match.group("path").strip('"')).name
    referenced_swift_files.add(file_name)
    candidates = source_files_by_name.get(file_name, [])
    if not candidates:
        errors.append(f"{file_name}: no matching Swift file exists under GamesRoom/")
    elif len(candidates) > 1:
        errors.append(f"{file_name}: filename is ambiguous under GamesRoom/")

source_phase_match = re.search(
    r"/\* Begin PBXSourcesBuildPhase section \*/(?P<section>.*?)/\* End PBXSourcesBuildPhase section \*/",
    text,
    re.DOTALL,
)
if not source_phase_match:
    errors.append("PBXSourcesBuildPhase section is missing")
else:
    source_phase = source_phase_match.group("section")
    for source_file in sorted(SOURCE_ROOT.rglob("*.swift")):
        if source_file.name not in referenced_swift_files:
            errors.append(f"{source_file.relative_to(ROOT)} has no PBXFileReference")
        if source_file.name not in source_phase:
            errors.append(f"{source_file.relative_to(ROOT)} is not in the Sources build phase")

target_config_pattern = re.compile(
    r"AAAAAAAA000000000000010[56] /\* (?:Debug|Release) \*/ = \{\n"
    r"\s*isa = XCBuildConfiguration;\n"
    r"\s*baseConfigurationReference = [^\n]+;\n"
    r"\s*buildSettings = \{(?P<body>.*?)\n\s*\};\n"
    r"\s*name = (?:Debug|Release);\n"
    r"\s*\};",
    re.DOTALL,
)
target_configs = target_config_pattern.findall(text)
if len(target_configs) != 2:
    errors.append("Could not identify both GamesRoom target build configurations")
else:
    for index, body in enumerate(target_configs):
        if "CODE_SIGN_ENTITLEMENTS = GamesRoom/GamesRoom.entitlements;" not in body:
            configuration = "Debug" if index == 0 else "Release"
            errors.append(f"{configuration} target configuration does not set CODE_SIGN_ENTITLEMENTS")

if "SystemCapabilities" not in text or "com.apple.SignInWithApple" not in text:
    errors.append("GamesRoom target does not declare the Sign in with Apple capability")

if text.count("baseConfigurationReference = AAAAAAAA0000000000000435") != 4:
    errors.append("Config.xcconfig must be wired to all four build configurations")

# W2.3 — widget extension target: app groups entitlement + extension
# API-only + the score-snapshot mirror must exist in its sources.
if text.count("CODE_SIGN_ENTITLEMENTS = GamesRoomWidgets/GamesRoomWidgets.entitlements;") != 2:
    errors.append("GamesRoomWidgets target must set CODE_SIGN_ENTITLEMENTS on Debug and Release")
if text.count("APPLICATION_EXTENSION_API_ONLY = YES;") != 2:
    errors.append("GamesRoomWidgets target must set APPLICATION_EXTENSION_API_ONLY on Debug and Release")

# W2.3 — watch target: app groups entitlement on both configs.
if text.count("CODE_SIGN_ENTITLEMENTS = GamesRoomWatch/GamesRoomWatch.entitlements;") != 2:
    errors.append("GamesRoomWatch target must set CODE_SIGN_ENTITLEMENTS on Debug and Release")

# W2.3 — the three targets each need their own ScoreSnapshot copy
# (no shared framework). A missing copy is a compile error on an
# Xcode host that headless parse-check cannot see.
for path, target in [
    (ROOT / "GamesRoom" / "Models" / "ScoreSnapshot.swift", "app"),
    (ROOT / "GamesRoomWidgets" / "GamesRoomWidgets.swift", "widget"),
    (ROOT / "GamesRoomWatch" / "GamesRoomWatchApp.swift", "watch"),
]:
    if not path.is_file() or "struct ScoreSnapshot: Codable" not in path.read_text():
        errors.append(f"{target} target is missing its ScoreSnapshot definition ({path})")

# W2.3 — Live Activity requires the app Info.plist key.
app_plist = ROOT / "GamesRoom" / "Info.plist"
if app_plist.is_file() and "<key>NSSupportsLiveActivities</key>" not in app_plist.read_text():
    errors.append("GamesRoom Info.plist must declare NSSupportsLiveActivities")

scheme = ROOT / "GamesRoom.xcodeproj" / "xcshareddata" / "xcschemes" / "GamesRoom.xcscheme"
if not scheme.is_file():
    errors.append("GamesRoom shared scheme is missing")
else:
    scheme_text = scheme.read_text()
    if scheme_text.count('BlueprintIdentifier = "AAAAAAAA00000000000000FD"') != 3:
        errors.append("GamesRoom shared scheme does not target the GamesRoom PBXNativeTarget")

if errors:
    print("Xcode project verification failed:")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)

print("Xcode project verification passed.")
