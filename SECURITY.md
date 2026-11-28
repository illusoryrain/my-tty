# Security policy

## Reporting

Report suspected vulnerabilities privately via GitHub Security Advisories for
this repository. Do not open a public issue with exploit details.

## Explicit non-goals

The following are intentional design decisions, not missing features. Please do
not report them as vulnerabilities or audit findings:

- **Login-failure throttling, account lockout, and retry backoff.** my-tty only
  verifies the configured password. Brute-force protection belongs to the
  external reverse proxy, firewall, or fail2ban in front of it.
- **TLS termination.** Bind to loopback and terminate HTTP/WebSocket at a
  reverse proxy. This repository contains no certificates or TLS code.
- **Multi-user privilege separation.** The terminal runs as the service user;
  it is not a sandbox between users.

## Scope

Useful reports include authentication/session bypass, path traversal outside
the documented file root, request-smuggling/parsing bugs, symlink handling that
escapes the intended file operation, WebSocket/session takeover races, and
resource-exhaustion bugs in the HTTP/PTY paths.
