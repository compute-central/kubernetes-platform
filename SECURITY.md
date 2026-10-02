# Security Policy

## Reporting a Vulnerability

Do **not** open a public issue for security problems.

Report privately through
[GitHub Security Advisories](https://github.com/compute-central/.github/security/advisories)
on this repository, or by email to the address on the
[Compute Central site](https://computecentral.in/about/).

Please include the affected file or command, what an attacker could do with it,
and the steps to reproduce. Expect an acknowledgement within 7 days.

## Scope

This repository contains **teaching and reference code**. It is not a hosted
service and holds no production data or credentials.

In scope:

- Code or configuration here that would be insecure if followed as written
  (for example, an over-permissive IAM policy, a container running as root, a
  shell command vulnerable to injection, a dependency with a known CVE).
- Secrets accidentally committed to this repository.

Out of scope:

- Vulnerabilities in upstream projects (Ansible, Kubernetes, Python packages).
  Report those to the upstream project.
- Findings from running these examples against your own infrastructure.

## Before You Run Anything Here

Every example is a learning artifact. Review it, adapt it, and test it in a
throwaway environment before pointing it at anything you care about. Commands
that delete cloud resources or change host state are marked, and default to a
dry run wherever the underlying API supports one.
