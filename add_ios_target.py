#!/usr/bin/env python3
"""Patch ide.xcodeproj/project.pbxproj to add an iOS app target named 'ide-ios'.

Idempotent-ish: if a target named ide-ios already exists, exits without changes.

Run:
    python3 add_ios_target.py
"""

import os
import re
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).parent.resolve()
PBXPROJ = ROOT / "ide.xcodeproj" / "project.pbxproj"
IOS_FOLDER_NAME = "ide-ios"


def hex_id():
    return uuid.uuid4().hex.upper()[:24]


def main():
    text = PBXPROJ.read_text()

    if f"path = {IOS_FOLDER_NAME};" in text or "/* ide-ios */" in text:
        print("ide-ios target already present — nothing to do.")
        return

    # Fresh UUIDs for everything we add.
    UID = {
        "synced_group":        hex_id(),
        "app_ref":             hex_id(),
        "frameworks_phase":    hex_id(),
        "sources_phase":       hex_id(),
        "resources_phase":     hex_id(),
        "target":              hex_id(),
        "config_list":         hex_id(),
        "debug_config":        hex_id(),
        "release_config":      hex_id(),
    }

    # ---------- New entries ----------

    new_file_reference = f"""\t\t{UID['app_ref']} /* {IOS_FOLDER_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{IOS_FOLDER_NAME}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};\n"""

    new_synced_group = f"""\t\t{UID['synced_group']} /* {IOS_FOLDER_NAME} */ = {{isa = PBXFileSystemSynchronizedRootGroup; explicitFileTypes = {{}}; explicitFolders = (); path = "{IOS_FOLDER_NAME}"; sourceTree = "<group>"; }};\n"""

    new_frameworks_phase = f"""\t\t{UID['frameworks_phase']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""

    new_sources_phase = f"""\t\t{UID['sources_phase']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""

    new_resources_phase = f"""\t\t{UID['resources_phase']} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""

    new_target = f"""\t\t{UID['target']} /* {IOS_FOLDER_NAME} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {UID['config_list']} /* Build configuration list for PBXNativeTarget "{IOS_FOLDER_NAME}" */;
\t\t\tbuildPhases = (
\t\t\t\t{UID['sources_phase']} /* Sources */,
\t\t\t\t{UID['frameworks_phase']} /* Frameworks */,
\t\t\t\t{UID['resources_phase']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{UID['synced_group']} /* {IOS_FOLDER_NAME} */,
\t\t\t);
\t\t\tname = "{IOS_FOLDER_NAME}";
\t\t\tproductName = "{IOS_FOLDER_NAME}";
\t\t\tproductReference = {UID['app_ref']} /* {IOS_FOLDER_NAME}.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
"""

    # Build settings for iOS: deployment target 26.0, iPhone+iPad family, weak link CoreAI/FoundationModels.
    common_settings = """\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;
\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.example.ide-ios";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
"""

    new_debug_config = f"""\t\t{UID['debug_config']} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{common_settings}\t\t\t}};
\t\t\tname = Debug;
\t\t}};
"""

    new_release_config = f"""\t\t{UID['release_config']} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{common_settings}\t\t\t}};
\t\t\tname = Release;
\t\t}};
"""

    new_config_list = f"""\t\t{UID['config_list']} /* Build configuration list for PBXNativeTarget "{IOS_FOLDER_NAME}" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{UID['debug_config']} /* Debug */,
\t\t\t\t{UID['release_config']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
"""

    # ---------- Insert into the right sections ----------

    def insert_before(marker, content):
        nonlocal text
        if marker not in text:
            print(f"!! marker not found in pbxproj: {marker!r}")
            sys.exit(1)
        text = text.replace(marker, content + marker, 1)

    insert_before("/* End PBXFileReference section */", new_file_reference)
    insert_before("/* End PBXFileSystemSynchronizedRootGroup section */", new_synced_group)
    insert_before("/* End PBXFrameworksBuildPhase section */", new_frameworks_phase)
    insert_before("/* End PBXSourcesBuildPhase section */", new_sources_phase)
    insert_before("/* End PBXResourcesBuildPhase section */", new_resources_phase)
    insert_before("/* End PBXNativeTarget section */", new_target)
    insert_before("/* End XCBuildConfiguration section */", new_debug_config + new_release_config)
    insert_before("/* End XCConfigurationList section */", new_config_list)

    # ---------- Patch existing groups / project targets ----------

    # 1. Add to root group's children list (looks like ide and ideTests siblings).
    root_group_pattern = re.compile(
        r"(children = \(\s*[0-9A-F]{24} /\* ide \*/,\s*[0-9A-F]{24} /\* ideTests \*/,)",
        re.MULTILINE,
    )
    new_root_children = f"\\1\n\t\t\t\t{UID['synced_group']} /* {IOS_FOLDER_NAME} */,"
    new_text, n = root_group_pattern.subn(new_root_children, text, count=1)
    if n != 1:
        print("!! couldn't find root group's children block")
        sys.exit(1)
    text = new_text

    # 2. Add to Products group's children list.
    products_pattern = re.compile(
        r"(/\* Products \*/ = \{\s*isa = PBXGroup;\s*children = \(\s*[0-9A-F]{24} /\* ide\.app \*/,\s*[0-9A-F]{24} /\* ideTests\.xctest \*/,)",
        re.MULTILINE,
    )
    new_products = f"\\1\n\t\t\t\t{UID['app_ref']} /* {IOS_FOLDER_NAME}.app */,"
    new_text, n = products_pattern.subn(new_products, text, count=1)
    if n != 1:
        print("!! couldn't find Products group's children block")
        sys.exit(1)
    text = new_text

    # 3. Add to PBXProject's targets list.
    targets_pattern = re.compile(
        r"(targets = \(\s*[0-9A-F]{24} /\* ide \*/,\s*[0-9A-F]{24} /\* ideTests \*/,)",
        re.MULTILINE,
    )
    new_targets = f"\\1\n\t\t\t\t{UID['target']} /* {IOS_FOLDER_NAME} */,"
    new_text, n = targets_pattern.subn(new_targets, text, count=1)
    if n != 1:
        print("!! couldn't find PBXProject.targets block")
        sys.exit(1)
    text = new_text

    PBXPROJ.write_text(text)
    print(f"✓ added iOS target '{IOS_FOLDER_NAME}'")
    print(f"  - target UID: {UID['target']}")
    print(f"  - product:    {IOS_FOLDER_NAME}.app")
    print(f"  - bundle ID:  com.example.{IOS_FOLDER_NAME}")
    print(f"  - deploy:     iOS 26.0")


if __name__ == "__main__":
    main()
