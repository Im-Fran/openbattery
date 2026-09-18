# Security Policy

## Supported versions

OpenBattery ships from the latest tag. Fixes land on `dev` and go out in the
next release; older versions are not patched.

| Version | Supported |
| --- | --- |
| Latest release | ✅ |
| Anything older | ❌ |

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/Im-Fran/openbattery/security/advisories/new)
(repository → **Security** → **Advisories** → **Report a vulnerability**).

Helpful things to include:

- What the issue is, and what an attacker gets out of it.
- Steps to reproduce, or a proof of concept.
- The OpenBattery version, macOS version and Mac model.
- Whether the app was installed from a release DMG, the App Store or built
  locally.

What to expect:

- An acknowledgement within a few days.
- An assessment and a plan once the report is confirmed.
- A fix in the next release, with credit in the advisory unless you would
  rather not be named.

Please give a reasonable window for a fix before disclosing publicly.

## Scope

OpenBattery's attack surface is small by design, and that shapes what counts:

- It **reads only** — it never writes to IOKit or changes a system setting.
- It runs **unprivileged**: no root, no privileged helper, no `sudo`.
- It has **no dependencies** and makes **no network requests**. Battery history
  is written locally and never leaves the Mac.
- It never shells out to `ioreg`, `pmset` or anything else.

In scope, for example: a way to make the app write to the system or escalate
privileges, code execution through crafted IORegistry data, a flaw in how
release builds are signed or notarized, or exposure of local history data to
another process or user.

Out of scope: vulnerabilities in macOS itself, physical access to an unlocked
Mac, issues that require the user to run the app from an already-compromised
system, and anything about macOS's own Charge Limit setting — that is Apple's
feature, not OpenBattery's.
