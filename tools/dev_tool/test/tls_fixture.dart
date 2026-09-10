/// A self-signed certificate for `localhost`, for tests that need real TLS.
///
/// Embedded rather than shipped as data files so it needs no runfiles
/// resolution and no `data` plumbing: the tests that use it write it to a temp
/// directory and hand the paths to the flags under test.
///
/// Generated once with, and regenerated the same way if it ever needs to be:
///
/// ```sh
/// openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
///   -sha256 -days 36500 -nodes -subj "/CN=localhost" \
///   -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
/// ```
///
/// It expires in 2126 and authenticates nothing anyone would want: it exists
/// so `HttpServer.bindSecure` has something to serve, and the clients that
/// dial it accept any certificate.
library;

import 'dart:io';

const testCertificatePem = '''
-----BEGIN CERTIFICATE-----
MIIDJzCCAg+gAwIBAgIUCSOCAGVENU3csSVetWjZB8ISsLYwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDgxNDA3MTU0NloYDzIxMjYw
NzIxMDcxNTQ2WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDfI0eLycn9ItTyhUshA67MFLjL2x5HhznPKjqRv+RU
KLAw500c6ZOtpt6zfGP1VNkGokEpogGn4XIqfUnQzUCQ5MbzI7Q7MpFNfG4ucrWb
zlMY5hTtqBvN2kVdHuLsHZmNnjGMn9ICV8Myp65KPcsNPk5rr58hzLb9TrWnTo+0
cq7AFYMiBcGLER8+9iKBY8f/bVtKRJOGf97uk0VcJR9set4eNp9WTHc1w3wQ5n8N
7Yc5rNSIaPIWwFJna+bn0elYuZcDiNeogY94/LgNQWEGgaXmDGkjyltgUA2rTBOH
Oa0RnCiHANRQZdpMxcMug4LCNvCCC3mK1KPQF0y/tcAjAgMBAAGjbzBtMB0GA1Ud
DgQWBBSlT/qItb63Y6dMaI/UqZrfEy3G+DAfBgNVHSMEGDAWgBSlT/qItb63Y6dM
aI/UqZrfEy3G+DAPBgNVHRMBAf8EBTADAQH/MBoGA1UdEQQTMBGCCWxvY2FsaG9z
dIcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAbkSW5D6njt4tucIJuxh0HKbWpaIS
rfnQ8jDgmSsv2u46UJiQRs8kcfm95x+jqREWGCdF8bgnRLfrp6vsA91lwI6mws4J
FdMXZJOIfbIjYnZQV3tq/NaFqjQX4GHxBBreMHFfdAVdyp8R8+0mCL3MpWVXqEev
viAxfYy3zqQiL07y27jnomxsJXMAOL6ocWmIPqqKTwvg+3GprOE3LDMMkt2HGTUp
3HSeu0QNoFa7k/CSNE6LPNUxuHJ0KFzCbpELXVQJ7AxWc9HYeyG/0j21OJwSCGpj
Fja5g11rNyx7mq/SbekOdnSG/9aJi2BuxKmtl2nQc1/lB+GHV0MFRQAHSQ==
-----END CERTIFICATE-----
''';

const testCertificateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDfI0eLycn9ItTy
hUshA67MFLjL2x5HhznPKjqRv+RUKLAw500c6ZOtpt6zfGP1VNkGokEpogGn4XIq
fUnQzUCQ5MbzI7Q7MpFNfG4ucrWbzlMY5hTtqBvN2kVdHuLsHZmNnjGMn9ICV8My
p65KPcsNPk5rr58hzLb9TrWnTo+0cq7AFYMiBcGLER8+9iKBY8f/bVtKRJOGf97u
k0VcJR9set4eNp9WTHc1w3wQ5n8N7Yc5rNSIaPIWwFJna+bn0elYuZcDiNeogY94
/LgNQWEGgaXmDGkjyltgUA2rTBOHOa0RnCiHANRQZdpMxcMug4LCNvCCC3mK1KPQ
F0y/tcAjAgMBAAECggEAC7kUjTBwzZJ0roA/lVI5/S3woixE5E/N++6I62yx5j9X
qXoSxxGjys38pieYobKL63zbqxy5JuE6n5jYJ4F9gnSX2eD0/qVp6jCwsFKwQamA
cXX98pkeZ4DonAJ/Zty3Pr5bIIJxdo0ofYTNSR2t+xLOCUJNrfeUtZBpDW7x2ys7
AUoaUO9nokCz5AUWJEqSaVUz5IPcZELJAELjNrjCQGeuYwRMwg7VChotvuG3/boE
aWZB7mZ5X2vZ7KUrJy0oJXUxUWQMdujgCn3pBsK3gu+3/jQrtzx2fTAFZ5F3fV0t
Fdghz7QkJwkF7zagAg3y99sm0AL8qkTFdQYiFpthYQKBgQD9YaeMA6YaS/Q2JP1u
YwlS9TgVgzL99G5xsgLX9ylx2LWUzKTQDjSN9oM+wWKzLz223gZ7ieI3pCukFxR1
EVhEaiB2IlzY5zjt851LNm8Dc0z7f5054gE2XHxNJ/0yot8naondwWF+RH58XT2c
3vkV1FebJWWSQjz7DWFsHrrFXwKBgQDhcZzJUtp49ZiBQNNu6z7lGkvzEgAJOB1U
ByvxfPFcmK7OdG48ppEOJ66OIERmj9twiaX3woT18/XVGtfOgOYEK/ZfmvLav0zw
UHze/jKOU2MKlWEQVn3fM0IpOuybQP7WljGtbHQwonf/xdIHuf+gWGJbX0pAk7qs
oCSLlPmXvQKBgH8YQbt4hRPBr4CNM1XwdVfYSsZ3pdc+iTucZ9K+VlqVshcuQyld
Rr1Cvnh29jQc6R7V5XiIJCF2xrErJobGKXk/poK7H8loyeSJgwecCTk41497ZnkH
RUZoQ61L9rQ0gCy8QuUpv+ZfIvbsqiAKs/RgK4VVz8n6Ua43+vsJuvOPAoGAF2C8
rXPWC+0L33tlcX8bio5ric04C7yx7eDAgc4/CSccGXShadCsAhfDViGqdig8zTK4
7zRQrWCbAXpDHrrnH0+fwNJElMJ5rAHssQMTIwcqohJTemo9q0OZfMULfB4FTyNM
C3vPoKt4XiGZYgu7olkH+gmrnX60QOpqX78XEtECgYEA6N7+19UkBDMy933eNG8E
o1ChxX0yOGjfqWX81qdgHJdQA9Ls6M/3vXadc6FhyNJSa7wi7LoW/Fiyw57TThKX
mkUoaLevH2+M4Jiea5mkqYEggiAGzVKMTJuYcMQZq6iv+muklQfaelvABMuLnRKk
OQDJHE9iDyaFVcj8OgNlYZM=
-----END PRIVATE KEY-----
''';

/// Write the fixture to [dir] and return the two paths, in the order
/// `--web-tls-cert-path` and `--web-tls-cert-key-path` take them.
({String certPath, String keyPath}) writeTestCertificate(Directory dir) {
  final certPath = '${dir.path}/localhost-cert.pem';
  final keyPath = '${dir.path}/localhost-key.pem';
  File(certPath).writeAsStringSync(testCertificatePem);
  File(keyPath).writeAsStringSync(testCertificateKeyPem);
  return (certPath: certPath, keyPath: keyPath);
}
