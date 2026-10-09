#!/usr/bin/env python3
"""Generate ios/Mazemaze.xcodeproj (no third-party tools needed).

Run from anywhere: python3 ios/tools/generate_project.py
The app target compiles every .swift file under ios/Mazemaze/ and bundles the files in
ios/Mazemaze/Resources/. Logic lives in the local Swift package ios/MazemazeCore.
Set your own Team in Xcode (Signing & Capabilities) to install on a device.
"""
import hashlib
import os
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
APP_DIR = IOS / "Mazemaze"
PROJ = IOS / "Mazemaze.xcodeproj"
BUNDLE_ID = os.environ.get("MAZEMAZE_BUNDLE_ID", "jp.mineno.mazemaze")
DEPLOYMENT = "17.0"


def oid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


swift_files = sorted(p.relative_to(APP_DIR) for p in APP_DIR.rglob("*.swift"))
resource_files = sorted(p.relative_to(APP_DIR) for p in (APP_DIR / "Resources").rglob("*") if p.is_file())

objs: list[str] = []


def add(section_lines: list[str]) -> None:
    objs.extend(section_lines)


# ---- ids
ID_PROJECT = oid("project")
ID_MAIN_GROUP = oid("group.main")
ID_APP_GROUP = oid("group.app")
ID_PRODUCTS_GROUP = oid("group.products")
ID_RES_GROUP = oid("group.resources")
ID_APP_PRODUCT = oid("product.app")
ID_TARGET = oid("target.app")
ID_SRC_PHASE = oid("phase.sources")
ID_FW_PHASE = oid("phase.frameworks")
ID_RES_PHASE = oid("phase.resources")
ID_PKG_REF = oid("pkgref.core")
ID_PKG_DEP = oid("pkgdep.core")
ID_PKG_BUILD = oid("pkgbuild.core")
ID_PLIST = oid("file.Info.plist")
ID_ASSETS = oid("file.Assets.xcassets")
ID_ASSETS_BUILD = oid("build.Assets.xcassets")
ID_CFG_PROJ_LIST = oid("cfglist.project")
ID_CFG_TARGET_LIST = oid("cfglist.target")
ID_CFG = {n: oid(f"cfg.{n}") for n in ("proj.Debug", "proj.Release", "tgt.Debug", "tgt.Release")}

out: list[str] = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {", ""]

# PBXBuildFile
out.append("/* Begin PBXBuildFile section */")
out.append(f"\t\t{ID_ASSETS_BUILD} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ID_ASSETS} /* Assets.xcassets */; }};")
for f in swift_files:
    out.append(f"\t\t{oid('build.' + str(f))} /* {f.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {oid('file.' + str(f))} /* {f.name} */; }};")
for f in resource_files:
    out.append(f"\t\t{oid('build.res.' + str(f))} /* {f.name} in Resources */ = {{isa = PBXBuildFile; fileRef = {oid('file.res.' + str(f))} /* {f.name} */; }};")
out.append(f"\t\t{ID_PKG_BUILD} /* MazemazeCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {ID_PKG_DEP} /* MazemazeCore */; }};")
out.append("/* End PBXBuildFile section */\n")

# PBXFileReference
out.append("/* Begin PBXFileReference section */")
out.append(f"\t\t{ID_APP_PRODUCT} /* Mazemaze.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Mazemaze.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
out.append(f"\t\t{ID_PLIST} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
out.append(f"\t\t{ID_ASSETS} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};")
for f in swift_files:
    out.append(f"\t\t{oid('file.' + str(f))} /* {f.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{f}\"; sourceTree = \"<group>\"; }};")
for f in resource_files:
    kind = {".js": "sourcetree.javascript", ".html": "text.html", ".json": "text.json"}.get(f.suffix, "file")
    kind = "sourcecode.javascript" if f.suffix == ".js" else kind
    out.append(f"\t\t{oid('file.res.' + str(f))} /* {f.name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = \"Resources/{f.relative_to('Resources')}\"; sourceTree = \"<group>\"; }};")
out.append("/* End PBXFileReference section */\n")

# PBXFrameworksBuildPhase
out.append("/* Begin PBXFrameworksBuildPhase section */")
out.append(f"\t\t{ID_FW_PHASE} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{ID_PKG_BUILD} /* MazemazeCore in Frameworks */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
out.append("/* End PBXFrameworksBuildPhase section */\n")

# PBXGroup
out.append("/* Begin PBXGroup section */")
out.append(f"\t\t{ID_MAIN_GROUP} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{ID_APP_GROUP} /* Mazemaze */,\n\t\t\t\t{ID_PRODUCTS_GROUP} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
children = "".join(f"\t\t\t\t{oid('file.' + str(f))} /* {f.name} */,\n" for f in swift_files)
children += "".join(f"\t\t\t\t{oid('file.res.' + str(f))} /* {f.name} */,\n" for f in resource_files)
children += f"\t\t\t\t{ID_PLIST} /* Info.plist */,\n\t\t\t\t{ID_ASSETS} /* Assets.xcassets */,\n"
out.append(f"\t\t{ID_APP_GROUP} /* Mazemaze */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t);\n\t\t\tpath = Mazemaze;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
out.append(f"\t\t{ID_PRODUCTS_GROUP} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{ID_APP_PRODUCT} /* Mazemaze.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
out.append("/* End PBXGroup section */\n")

# PBXNativeTarget
out.append("/* Begin PBXNativeTarget section */")
out.append(f"""\t\t{ID_TARGET} /* Mazemaze */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ID_CFG_TARGET_LIST} /* Build configuration list for PBXNativeTarget "Mazemaze" */;
\t\t\tbuildPhases = (
\t\t\t\t{ID_SRC_PHASE} /* Sources */,
\t\t\t\t{ID_FW_PHASE} /* Frameworks */,
\t\t\t\t{ID_RES_PHASE} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = Mazemaze;
\t\t\tpackageProductDependencies = (
\t\t\t\t{ID_PKG_DEP} /* MazemazeCore */,
\t\t\t);
\t\t\tproductName = Mazemaze;
\t\t\tproductReference = {ID_APP_PRODUCT} /* Mazemaze.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};""")
out.append("/* End PBXNativeTarget section */\n")

# PBXProject
out.append("/* Begin PBXProject section */")
out.append(f"""\t\t{ID_PROJECT} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{ID_TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {ID_CFG_PROJ_LIST} /* Build configuration list for PBXProject "Mazemaze" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = ja;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\tja,
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {ID_MAIN_GROUP};
\t\t\tpackageReferences = (
\t\t\t\t{ID_PKG_REF} /* XCLocalSwiftPackageReference "MazemazeCore" */,
\t\t\t);
\t\t\tproductRefGroup = {ID_PRODUCTS_GROUP} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{ID_TARGET} /* Mazemaze */,
\t\t\t);
\t\t}};""")
out.append("/* End PBXProject section */\n")

# PBXResourcesBuildPhase
res_files = f"\t\t\t\t{ID_ASSETS_BUILD} /* Assets.xcassets in Resources */,\n" + "".join(f"\t\t\t\t{oid('build.res.' + str(f))} /* {f.name} in Resources */,\n" for f in resource_files)
out.append("/* Begin PBXResourcesBuildPhase section */")
out.append(f"\t\t{ID_RES_PHASE} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{res_files}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
out.append("/* End PBXResourcesBuildPhase section */\n")

# PBXSourcesBuildPhase
src_files = "".join(f"\t\t\t\t{oid('build.' + str(f))} /* {f.name} in Sources */,\n" for f in swift_files)
out.append("/* Begin PBXSourcesBuildPhase section */")
out.append(f"\t\t{ID_SRC_PHASE} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{src_files}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
out.append("/* End PBXSourcesBuildPhase section */\n")

# XCBuildConfiguration
common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT,
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
}
proj_cfg = {
    "Debug": {**common, "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0",
              "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"'},
    "Release": {**common, "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "ENABLE_NS_ASSERTIONS": "NO",
                "SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"},
}
tgt_cfg = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "NO",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": "Mazemaze/Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "Mazemaze",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": '"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
    "MARKETING_VERSION": "0.1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
    "SUPPORTS_MACCATALYST": "NO",
    "TARGETED_DEVICE_FAMILY": "1",
}


def cfg_block(cid: str, name: str, settings: dict) -> str:
    body = "".join(f"\t\t\t\t{k} = {v};\n" for k, v in sorted(settings.items()))
    return f"\t\t{cid} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{body}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};"


out.append("/* Begin XCBuildConfiguration section */")
for n in ("Debug", "Release"):
    out.append(cfg_block(ID_CFG[f"proj.{n}"], n, proj_cfg[n]))
for n in ("Debug", "Release"):
    out.append(cfg_block(ID_CFG[f"tgt.{n}"], n, tgt_cfg))
out.append("/* End XCBuildConfiguration section */\n")

out.append("/* Begin XCConfigurationList section */")
out.append(f"\t\t{ID_CFG_PROJ_LIST} /* Build configuration list for PBXProject \"Mazemaze\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{ID_CFG['proj.Debug']} /* Debug */,\n\t\t\t\t{ID_CFG['proj.Release']} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};")
out.append(f"\t\t{ID_CFG_TARGET_LIST} /* Build configuration list for PBXNativeTarget \"Mazemaze\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{ID_CFG['tgt.Debug']} /* Debug */,\n\t\t\t\t{ID_CFG['tgt.Release']} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};")
out.append("/* End XCConfigurationList section */\n")

out.append("/* Begin XCLocalSwiftPackageReference section */")
out.append(f"\t\t{ID_PKG_REF} /* XCLocalSwiftPackageReference \"MazemazeCore\" */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = MazemazeCore;\n\t\t}};")
out.append("/* End XCLocalSwiftPackageReference section */\n")
out.append("/* Begin XCSwiftPackageProductDependency section */")
out.append(f"\t\t{ID_PKG_DEP} /* MazemazeCore */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = MazemazeCore;\n\t\t}};")
out.append("/* End XCSwiftPackageProductDependency section */")

out += ["\t};", f"\trootObject = {ID_PROJECT} /* Project object */;", "}", ""]

PROJ.mkdir(exist_ok=True)
(PROJ / "project.pbxproj").write_text("\n".join(out), encoding="utf-8")

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{ID_TARGET}" BuildableName = "Mazemaze.app" BlueprintName = "Mazemaze" ReferencedContainer = "container:Mazemaze.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{ID_TARGET}" BuildableName = "Mazemaze.app" BlueprintName = "Mazemaze" ReferencedContainer = "container:Mazemaze.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
sd = PROJ / "xcshareddata" / "xcschemes"
sd.mkdir(parents=True, exist_ok=True)
(sd / "Mazemaze.xcscheme").write_text(scheme, encoding="utf-8")
print(f"generated {PROJ} ({len(swift_files)} swift, {len(resource_files)} resources)")
