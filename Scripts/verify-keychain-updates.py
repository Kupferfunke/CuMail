#!/usr/bin/env python3
"""Exercise only a random synthetic key: update continuity and unauthorised peer rejection."""
from pathlib import Path
import hashlib,json,plistlib,subprocess,uuid,shutil
project=Path(__file__).resolve().parent.parent; root=project/'build/XPCSigningProbe'
root.mkdir(parents=True, exist_ok=True)
identity=subprocess.check_output(['python3',str(project/'Scripts/local-signing.py')],text=True).strip()
helper=Path.home()/'Library/Application Support/MikeMailHubDevelopment/KeychainService/MikeMailKeychain.xpc'
namespace='ch.kupferfunke.MikeMailHub.signingtest.'+str(uuid.uuid4())+'.signed-v1'
bundle=root/'Probe.app';contents=bundle/'Contents';(contents/'MacOS').mkdir(parents=True,exist_ok=True)
(contents/'XPCServices').mkdir(exist_ok=True)
shutil.copytree(helper,contents/'XPCServices/MikeMailKeychain.xpc',dirs_exist_ok=True)
info={'CFBundleIdentifier':'ch.kupferfunke.MikeMailHub','CFBundleExecutable':'Probe','CFBundleName':'Mike Mail Hub Signing Test','CFBundlePackageType':'APPL','MMHKeychainCertificateSHA1':identity}
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
(root/'Stubs.swift').write_text('''import Foundation
import Security
enum KeychainFailure: Error { case unavailable }
protocol KeychainAPI: Sendable {
func copy(_ query:[String:Any]) -> (OSStatus,Data?)
func add(_ query:[String:Any]) -> OSStatus
func update(_ query:[String:Any],attributes:[String:Any]) -> OSStatus
func delete(_ query:[String:Any]) -> OSStatus
}
''')
source='''import Foundation
import Security
let version = "VERSION"
let fingerprint = Bundle.main.object(forInfoDictionaryKey:"MMHKeychainCertificateSHA1") as! String
let api = try XPCKeychainAPI(fingerprint:fingerprint)
let namespace = CommandLine.arguments[1]
guard namespace.hasPrefix("ch.kupferfunke.MikeMailHub.signingtest.") else { exit(2) }
let base: [String:Any] = [kSecAttrService as String:namespace,kSecAttrAccount as String:"index-key.v1",kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
if CommandLine.arguments[2] == "create" {
 var query=base; query[kSecValueData as String]=Data(repeating:0x59,count:32)
 let status=api.add(query); print("create=\\(status); version=\\(version)"); exit(status == 0 ? 0 : 1)
}
let (status,data)=api.copy(base)
if CommandLine.arguments[2] == "deny" {
 print("unauthorised peer denied=\\(status != 0 && data == nil)");exit(status != 0 && data == nil ? 0 : 1)
}
let correct = data == Data(repeating:0x59,count:32)
let deleted=api.delete(base)
print("read=\\(status); expectedSyntheticValue=\\(correct); cleanup=\\(deleted); version=\\(version)")
exit(status == 0 && correct && deleted == 0 ? 0 : 1)
'''
records=[]
for version,mode,identifier in [('A','create','ch.kupferfunke.MikeMailHub'),('X','deny','ch.kupferfunke.UntrustedSigningProbe'),('Y','deny','ch.kupferfunke.MikeMailHub'),('B','read','ch.kupferfunke.MikeMailHub')]:
 (root/'main.swift').write_text(source.replace('VERSION',version))
 binary=contents/'MacOS/Probe'
 subprocess.run(['xcrun','swiftc','-swift-version','6',str(root/'Stubs.swift'),str(project/'Packages/MikeMailCore/Sources/MailSecurity/KeychainXPCProtocol.swift'),str(project/'Packages/MikeMailCore/Sources/MailSecurity/XPCKeychainAPI.swift'),str(root/'main.swift'),'-o',str(binary)],check=True,capture_output=True)
 subprocess.run(['/usr/bin/codesign','--force','--sign',('-' if version == 'Y' else identity),'--timestamp=none','--entitlements',str(project/'Config/MikeMailHub.entitlements'),'--identifier',identifier,str(bundle)],check=True,capture_output=True,timeout=30)
 check=subprocess.run([str(binary),namespace,mode],capture_output=True,text=True,timeout=30)
 display=subprocess.run(['/usr/bin/codesign','-d','-r-',str(bundle)],capture_output=True,text=True,check=True)
 requirement=(display.stdout+display.stderr).split('designated =>')[-1].splitlines()[0].strip()
 record={'build':version,'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'requirement':requirement,'result':check.stdout.strip(),'exit':check.returncode}
 records.append(record);print(json.dumps(record),flush=True)
 if check.returncode: print(check.stderr);raise SystemExit(check.returncode)
assert records[0]['sha256']!=records[-1]['sha256'] and records[0]['requirement']==records[-1]['requirement']
(root/'result.json').write_text(json.dumps({'userInteractionAllowed':False,'helperSHA256':hashlib.sha256((helper/'Contents/MacOS/MikeMailKeychain').read_bytes()).hexdigest(),'builds':records},indent=2)+'\n')
