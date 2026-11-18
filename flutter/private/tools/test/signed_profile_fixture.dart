import 'dart:convert';
import 'dart:typed_data';

/// The property list the signed profile below carries: a team wildcard
/// development profile's, cut to the keys that matter, with made-up
/// identifiers.
const signedProfileXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ApplicationIdentifierPrefix</key>
	<array>
		<string>UNSIGNED00</string>
	</array>
	<key>DER-Encoded-Profile</key>
	<data>MAA=</data>
	<key>Entitlements</key>
	<dict>
		<key>application-identifier</key>
		<string>UNSIGNED00.*</string>
		<key>com.apple.developer.team-identifier</key>
		<string>UNSIGNED00</string>
		<key>get-task-allow</key>
		<true/>
		<key>keychain-access-groups</key>
		<array>
			<string>UNSIGNED00.*</string>
			<string>com.apple.token</string>
		</array>
	</dict>
	<key>Name</key>
	<string>iOS Team Provisioning Profile: *</string>
	<key>TeamIdentifier</key>
	<array>
		<string>UNSIGNED00</string>
	</array>
	<key>Version</key>
	<integer>1</integer>
</dict>
</plist>
''';

/// [signedProfileXml] as a provisioning profile is: a CMS signed message,
/// made with `openssl cms -sign -nodetach -binary -outform DER -md sha256
/// -nosmimecap -noattr` and a throwaway self-signed certificate.
final Uint8List signedProfile = base64.decode(
  'MIIIUwYJKoZIhvcNAQcCoIIIRDCCCEACAQExDTALBglghkgBZQMEAgEwggN2BgkqhkiG9w0BBwGg'
  'ggNnBIIDYzw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04Ij8+CjwhRE9DVFlQRSBw'
  'bGlzdCBQVUJMSUMgIi0vL0FwcGxlLy9EVEQgUExJU1QgMS4wLy9FTiIgImh0dHA6Ly93d3cuYXBw'
  'bGUuY29tL0RURHMvUHJvcGVydHlMaXN0LTEuMC5kdGQiPgo8cGxpc3QgdmVyc2lvbj0iMS4wIj4K'
  'PGRpY3Q+Cgk8a2V5PkFwcGxpY2F0aW9uSWRlbnRpZmllclByZWZpeDwva2V5PgoJPGFycmF5PgoJ'
  'CTxzdHJpbmc+VU5TSUdORUQwMDwvc3RyaW5nPgoJPC9hcnJheT4KCTxrZXk+REVSLUVuY29kZWQt'
  'UHJvZmlsZTwva2V5PgoJPGRhdGE+TUFBPTwvZGF0YT4KCTxrZXk+RW50aXRsZW1lbnRzPC9rZXk+'
  'Cgk8ZGljdD4KCQk8a2V5PmFwcGxpY2F0aW9uLWlkZW50aWZpZXI8L2tleT4KCQk8c3RyaW5nPlVO'
  'U0lHTkVEMDAuKjwvc3RyaW5nPgoJCTxrZXk+Y29tLmFwcGxlLmRldmVsb3Blci50ZWFtLWlkZW50'
  'aWZpZXI8L2tleT4KCQk8c3RyaW5nPlVOU0lHTkVEMDA8L3N0cmluZz4KCQk8a2V5PmdldC10YXNr'
  'LWFsbG93PC9rZXk+CgkJPHRydWUvPgoJCTxrZXk+a2V5Y2hhaW4tYWNjZXNzLWdyb3Vwczwva2V5'
  'PgoJCTxhcnJheT4KCQkJPHN0cmluZz5VTlNJR05FRDAwLio8L3N0cmluZz4KCQkJPHN0cmluZz5j'
  'b20uYXBwbGUudG9rZW48L3N0cmluZz4KCQk8L2FycmF5PgoJPC9kaWN0PgoJPGtleT5OYW1lPC9r'
  'ZXk+Cgk8c3RyaW5nPmlPUyBUZWFtIFByb3Zpc2lvbmluZyBQcm9maWxlOiAqPC9zdHJpbmc+Cgk8'
  'a2V5PlRlYW1JZGVudGlmaWVyPC9rZXk+Cgk8YXJyYXk+CgkJPHN0cmluZz5VTlNJR05FRDAwPC9z'
  'dHJpbmc+Cgk8L2FycmF5PgoJPGtleT5WZXJzaW9uPC9rZXk+Cgk8aW50ZWdlcj4xPC9pbnRlZ2Vy'
  'Pgo8L2RpY3Q+CjwvcGxpc3Q+CqCCAz8wggM7MIICI6ADAgECAhQXJml0DxMBdYLB/lk7iMWfDL4I'
  'OzANBgkqhkiG9w0BAQsFADAsMSowKAYDVQQDDCFydWxlc19mbHV0dGVyIHRlc3QgcHJvZmlsZSBz'
  'aWduZXIwIBcNMjYxMTE4MDU0MjUzWhgPMjEyNjEwMjUwNTQyNTNaMCwxKjAoBgNVBAMMIXJ1bGVz'
  'X2ZsdXR0ZXIgdGVzdCBwcm9maWxlIHNpZ25lcjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC'
  'ggEBAKALvyHtFaQnYLWM5TjpVvwdrD/hT59Hrup5nnuC9Zs1E1//QkJgibeNsd4EKW+v57QVLkJN'
  '5OlL9PZb/+XQVXdtiQAoCGjVgzNVaZW4XKus0ml05NBwap1wo/4fBYxbOEcIQjfnLDVq1PJNe8Nq'
  '1GD6IvPhUlRKzxh+mXj7Mr4RG4RODLmi7xN4G2f0XMEQb+IkL3gqxzO1lo8msJn2Udtrrwef8GQA'
  'nBxNjMfFPMWPTgIvr9P7U8WXMoXjFkIJtNGKePCjg5a4bvNtzLuvnGJfWvb99ysXpPDuO+XmzWHi'
  'bJr5aR+2Qn4JeI0DboDa90Q50lDepDUqVrORCXkWixECAwEAAaNTMFEwHQYDVR0OBBYEFCkOxNSM'
  'lShEoeF2zDVZ2OU8XPf1MB8GA1UdIwQYMBaAFCkOxNSMlShEoeF2zDVZ2OU8XPf1MA8GA1UdEwEB'
  '/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAAERZDGYyMj1cQOXJ54i221wQGtO+bYBL5GFJ3cs'
  'JAsBB25Iye4vTX4Ih5SesdITt6aO25SC5lxFUgA5CpU404tAaVEI3J6+3NfRJmPjrWVBXE8HvMeq'
  '3T7GEgJGuZt6++M1Tde/dsvZM7DHGwIumOAgbP0i8F6sCuLvSKdBs1EYzHytUy2qeq9Peihu27w9'
  'tsvmxHJUXktau6pschxNqI1hd/0S8L6L+VPQS/pA/Xi6NMwd0eu8njBSVc37io+8Nw4BfFjBoeJP'
  'PY992pA9zBnBkImCkidKpfV3RK04TOtmb04XhPMJl1ck4FJIcTC1GzzcGli/7/iiiBwAddbpq30x'
  'ggFtMIIBaQIBATBEMCwxKjAoBgNVBAMMIXJ1bGVzX2ZsdXR0ZXIgdGVzdCBwcm9maWxlIHNpZ25l'
  'cgIUFyZpdA8TAXWCwf5ZO4jFnwy+CDswCwYJYIZIAWUDBAIBMA0GCSqGSIb3DQEBAQUABIIBAJuj'
  '45eoaszWQX/u2dFYjOeMvSO+iY63NreIR7IxD+s2pfxmt9x8HphinjuH1lzvZlIvw8zh0Hgnhifk'
  'jE4ra/4bHO6L+wizs+PNyXsusRvInZib6eoSeweKLY2h2e7pPfEz3dp3RBxh/924rmbKIiYW4b2U'
  'qKZjoj/UowOHekWTTJkwHJLsNeJv47LachvlRHDghxvka1gs9tAdotP1kvbAEgAax8AjdHgMRKKc'
  'WtvpkojpX3BlMdQJ1EEWLGkoSTr+7CQlkHycj9/+ThqfVFcj/+4YEDC1TvaGAEti/Y+dOsmmISV3'
  'KWP87c8fNP8gE34/vVlx6ruV1tjqoUd4Ic8=',
);
