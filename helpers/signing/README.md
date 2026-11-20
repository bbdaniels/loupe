# Code signing

Loupe, LoupeHUD and Loupe Launcher are signed with a local self-signed
certificate, "Loupe Dev", so that the macOS permissions granted to them
(Accessibility, Calendars, Contacts, Reminders, Microphone and the rest)
persist across rebuilds: each designated requirement names the bundle id and
this certificate, not the build.

"Loupe Dev" replaced "Topaz Dev" on 2026-11-20, when the whole project took
the name Loupe (the app was Topaz, and LoupeHUD was Loupe, from 2026-11-08).
"Topaz Dev" had replaced "ClaudeHUD Dev" on 2026-11-08, whose private key had
been committed to the old ClaudeHUD repository; that key was removed from the
history merged here.

## Where the identity lives

- The login keychain of the Mac holds the identity (certificate and private
  key), with `/usr/bin/codesign` allowed to use the key, and a Code Signing
  trust setting for the certificate.
- `signing/loupe-dev.p12` on that Mac holds the same identity for another
  machine. It is never committed (`.gitignore`); its password is the login
  keychain item `loupe-dev-p12`.

## Making it again

The certificate: RSA 2048, SHA-256, ten years, subject
`CN=Loupe Dev, O=Loupe Local, OU=Dev`, with the critical extensions
`basicConstraints CA:FALSE`, `keyUsage digitalSignature` and
`extendedKeyUsage codeSigning`, made with `openssl req -x509` and packed with
`openssl pkcs12 -export -name "Loupe Dev"`.

## Installing on a new machine

```bash
P12_PASSWORD=$(security find-generic-password -s loupe-dev-p12 -w)   # on the Mac
security import signing/loupe-dev.p12 -k ~/Library/Keychains/login.keychain-db \
    -f pkcs12 -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db signing/loupe-dev-cert.pem
```

The trust step raises a macOS password dialog. `project.yml` names
`CODE_SIGN_IDENTITY: "Loupe Dev"`, and `loupe-build.sh` signs with the same name.

## Verifying

```bash
security find-identity -v -p codesigning | grep "Loupe Dev"
codesign -dr - /Applications/Loupe.app/Contents/Helpers/LoupeHUD.app
```
