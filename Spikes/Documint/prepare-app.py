#!/usr/bin/env python3
"""Prepare an isolated GistPad build without linking the spike into the shipping project."""
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
destination = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(tempfile.mkdtemp(prefix="gp-documint-source-"))
temporary_root = pathlib.Path("/tmp").resolve()
if not destination.is_relative_to(temporary_root) or destination == temporary_root:
    raise SystemExit("Choose a fresh, specific /tmp destination.")
if destination.exists() and any(destination.iterdir()):
    raise SystemExit("The destination must be empty.")
destination.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryFile() as archive:
    subprocess.run(["git", "archive", "HEAD"], cwd=root, stdout=archive, check=True)
    archive.seek(0)
    with tarfile.open(fileobj=archive) as tree:
        tree.extractall(destination, filter="data")
shutil.copytree(root / "Spikes/Documint", destination / "Spikes/Documint", dirs_exist_ok=True,
    ignore=shutil.ignore_patterns(".build", ".swiftpm"))
local_config = root / "Configuration/Local.xcconfig"
if local_config.exists():
    shutil.copy2(local_config, destination / "Configuration/Local.xcconfig")

app = destination / "GistPad/GistPadApp.swift"
text = app.read_text()
text = text.replace("import GistPadEditor\n", "import GistPadEditor\nimport GistPadDocumintSpike\n", 1)
needle = 'if LaunchArguments.captureScreen == "photos" {'
if text.count(needle) != 1:
    raise SystemExit("The fixture entry changed. Reconcile the spike entry before building.")
text = text.replace(needle, 'if LaunchArguments.captureScreen == "documint" {\n'
    '        DocumintSpikeWorkspace(session: session)\n'
    '      } else ' + needle, 1)
needle = 'if let screen = LaunchArguments.captureScreen, ["library", "note"].contains(screen) {\n            text = '
if text.count(needle) != 1:
    raise SystemExit("The fixture source loader changed. Reconcile before building.")
text = text.replace(needle, 'if LaunchArguments.captureScreen == "documint" {\n'
    '            text = try DocumintSpikeFixtures.markdown\n'
    '          } else ' + needle, 1)
app.write_text(text)

project = destination / "GistPad.xcodeproj/project.pbxproj"
text = project.read_text()
if "D900000000000000000000" in text:
    raise SystemExit("The isolated spike project ID namespace is already in use.")
text = text.replace("/* Begin PBXBuildFile section */", "/* Begin PBXBuildFile section */\n"
    '\t\tD90000000000000000000001 /* GistPadDocumintSpike in Frameworks */ = {isa = PBXBuildFile; productRef = D90000000000000000000003; };\n'
    '\t\tD90000000000000000000004 /* GistPadDocumintSpike in Test Frameworks */ = {isa = PBXBuildFile; productRef = D90000000000000000000005; };', 1)
lines = text.splitlines(keepends=True)
for index, line in enumerate(lines):
    if line.startswith("\t\tA00000000000000000000008 /*"):
        lines[index] = line.replace("files = (", "files = (D90000000000000000000001, ", 1)
    if line.startswith("\t\tA00000000000000000000009 /*"):
        lines[index] = line.replace("files = (", "files = (D90000000000000000000004, ", 1)
text = "".join(lines)
text = text.replace("packageReferences = (", "packageReferences = (D90000000000000000000002, ", 1)
needle = 'name = GistPad;\n\t\t\tpackageProductDependencies = ('
if text.count(needle) != 1:
    raise SystemExit("The app package-product section changed.")
text = text.replace(needle, needle + "D90000000000000000000003, ", 1)
needle = 'name = GistPadTests;\n\t\t\tpackageProductDependencies = ('
if text.count(needle) != 1:
    raise SystemExit("The app test package-product section changed.")
text = text.replace(needle, needle + "D90000000000000000000005, ", 1)
text = text.replace("/* Begin XCLocalSwiftPackageReference section */",
    '/* Begin XCLocalSwiftPackageReference section */\n'
    '\t\tD90000000000000000000002 = {isa = XCLocalSwiftPackageReference; relativePath = Spikes/Documint; };', 1)
text = text.replace("/* Begin XCSwiftPackageProductDependency section */",
    '/* Begin XCSwiftPackageProductDependency section */\n'
    '\t\tD90000000000000000000003 = {isa = XCSwiftPackageProductDependency; package = D90000000000000000000002; productName = GistPadDocumintSpike; };\n'
    '\t\tD90000000000000000000005 = {isa = XCSwiftPackageProductDependency; package = D90000000000000000000002; productName = GistPadDocumintSpike; };', 1)
project.write_text(text)
shutil.copytree(root / "Spikes/Documint/Tests/GistPadDocumintSpikeTests",
    destination / "GistPadTests/DocumintSpike", dirs_exist_ok=True)

ui_ids = {
    "target": "D90000000000000000000010",
    "product": "D90000000000000000000011",
    "group": "D90000000000000000000012",
    "sources": "D90000000000000000000013",
    "frameworks": "D90000000000000000000014",
    "resources": "D90000000000000000000015",
    "configuration": "D90000000000000000000016",
    "debug": "D90000000000000000000017",
    "release": "D90000000000000000000018",
}
text = project.read_text()
sections = {
    "PBXFileReference": f'\t\t{ui_ids["product"]} = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = DocumintSpikeUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};',
    "PBXFileSystemSynchronizedRootGroup": f'\t\t{ui_ids["group"]} = {{isa = PBXFileSystemSynchronizedRootGroup; path = Spikes/Documint/UITests; sourceTree = SOURCE_ROOT; }};',
    "PBXSourcesBuildPhase": f'\t\t{ui_ids["sources"]} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};',
    "PBXFrameworksBuildPhase": f'\t\t{ui_ids["frameworks"]} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};',
    "PBXResourcesBuildPhase": f'\t\t{ui_ids["resources"]} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};',
    "PBXNativeTarget": f'\t\t{ui_ids["target"]} = {{isa = PBXNativeTarget; buildConfigurationList = {ui_ids["configuration"]}; buildPhases = ({ui_ids["sources"]}, {ui_ids["frameworks"]}, {ui_ids["resources"]},); buildRules = (); dependencies = (A00000000000000000000033,); fileSystemSynchronizedGroups = ({ui_ids["group"]},); name = DocumintSpikeUITests; productName = DocumintSpikeUITests; productReference = {ui_ids["product"]}; productType = "com.apple.product-type.bundle.ui-testing"; }};',
    "XCConfigurationList": f'\t\t{ui_ids["configuration"]} = {{isa = XCConfigurationList; buildConfigurations = ({ui_ids["debug"]}, {ui_ids["release"]},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};',
}
settings = 'GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 27.1; PRODUCT_BUNDLE_IDENTIFIER = dev.gistpad.DocumintSpikeUITests; PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SWIFT_VERSION = 6.2; TARGETED_DEVICE_FAMILY = "1,2"; TEST_TARGET_NAME = GistPad; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = RHFNBL7EG4;'
sections["XCBuildConfiguration"] = "\n".join(
    f'\t\t{ui_ids[key]} = {{isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name}; }};'
    for key, name in [("debug", "Debug"), ("release", "Release")]
)
for section, value in sections.items():
    marker = f"/* Begin {section} section */"
    if text.count(marker) != 1:
        raise SystemExit(f"Missing isolated project section: {section}")
    text = text.replace(marker, marker + "\n" + value, 1)
text = text.replace("targets = (", f'targets = ({ui_ids["target"]}, ', 1)
project.write_text(text)
scheme_dir = destination / "GistPad.xcodeproj/xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3">
 <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES">
  <BuildActionEntries>
   <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
    <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000020" BuildableName="GistPad.app" BlueprintName="GistPad" ReferencedContainer="container:GistPad.xcodeproj"/>
   </BuildActionEntry>
   <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
    <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_ids["target"]}" BuildableName="DocumintSpikeUITests.xctest" BlueprintName="DocumintSpikeUITests" ReferencedContainer="container:GistPad.xcodeproj"/>
   </BuildActionEntry>
  </BuildActionEntries>
 </BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
  <Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_ids["target"]}" BuildableName="DocumintSpikeUITests.xctest" BlueprintName="DocumintSpikeUITests" ReferencedContainer="container:GistPad.xcodeproj"/></TestableReference></Testables>
 </TestAction>
</Scheme>
'''
(scheme_dir / "DocumintSpike.xcscheme").write_text(scheme)
print(destination)
