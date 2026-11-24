# Security policy

## Reporting a vulnerability

Please **do not report security vulnerabilities through public GitHub issues, discussions or pull requests.**

Report them privately through GitHub: on this repository, open the **Security** tab and choose
**Report a vulnerability** ([private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)).
Include:

- the affected file(s), profile or module,
- steps to reproduce or a proof of concept,
- the impact you expect (for example a data plane that becomes reachable from public networks).

You'll get an acknowledgement as soon as possible. Fixes are published in this repository; the advisory is
disclosed once a fix is available.

## Scope

This repository is a sample / reference implementation. Reports about the **templates, scripts and
documentation in this repository** are in scope. Vulnerabilities in Azure services or Microsoft products
themselves are out of scope here; report them to the vendor (for Microsoft: the
[Microsoft Security Response Center](https://msrc.microsoft.com/create-report)).

Never include secrets, keys, tokens or customer data in a report.
