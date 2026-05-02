# Security Policy

[Project Name] is committed to ensuring the security and integrity of our software and the data of our users.
This document outlines our security policy and procedures for handling security-related issues.

## Supported Versions

| Version | Supported |
| ------- | --------- |
| 1.0.x   | ✅        |
| 0.9.x   | ❌        |
| 0.8.x   | ❌        |

## Reporting a Vulnerability

We take the security of our project seriously, If you have discoverd a security vulnerability, please follow these guidelines to report it immediately. We take all reports seriously and will investigate and respond promptly

### How to report a Vulnerability

1. Do not report security vulnerabilities through public GitHub issues.
2. Please email us at [security@example.com](mailto:security@example.com), if possible, encrypt your message with our PGP key (link to PGP key).
3. Please include the following information in your report:
   - Type of issue (e.g., buffer overflow, SQL injection, cross-site scripting etc.)
   - Full paths of source files(s) related to the vulnerability
   - Location of affected source code(tag/branch/commit or direct URL, if applicable)
   - Description for the vulnerability
   - Steps to reproduce the issue
   - Potential impact of the vulnerability
   - Suggested fix (if possible)
4. Allow us some time to respond, We''l try to keep you informed about our progress towards a fix and full announcement
5. After the vulnerability has been fixed, we will publicly disclose the nature of the vulnerability and acknowledge your
   contribution, if you wish to be credited.

## Security Update Process

1. Security vulnerabilities are given the highest priority and will be addressed as quickly as possible.
2. When a security vulnerability is fixed, we will notify users via:
   - Release notes
   - Email updates to affected parties
   - Announcements on our community channels
3. Patches will be provided for supported versions as outlined above.

## Security Best Practices

For users of this project, we recommend te following best practices ensuring the security of your deployments:

- Secure coding practices.
- Always keep your software up-to-date.
- Monitor dependencies for vulnerabilities using tools like Dependency Checker or similar.
- Regularly audit your configurations and access policies.
- Access controls and authentication.
- Incident response planning.

## Third Party Dependencies

Our software relies on third-party libraries. We regularly audit these dependencies for security vulnerabilities and release updates accordingly. however we recommend:

- Review our list of dependencies in the [package.json](https://github.com/username/blob/main/package.json)
- Review our list of dependencies in the [pubspec.yaml](https://github.com/username/blob/main/pubspec.yaml)

## Security Audits

## Disclosure Policy

When we receive a security bug report, we will:

1. Confirm the problem and determine the affected versions.
2. Audit code to find any potential problems.
3. Prepare fixes for all releases still under maintenance.
4. Release new version as soon as possible.

## Comments on this Policy

If you have suggestions on how this process could be improved, please submit a pull request or open an issue to discuss.

## Security Tools Used

- [Security tool name1](https://example.com): Description of the tool and it's purpose
- [Security tool name2](https://example.com): Description of the tool and it's purpose

## Acknowledgements

## References

## Contact

If you have any questions regarding our security policy, please contact us at [security@example.com](mailto:security@example.com)
