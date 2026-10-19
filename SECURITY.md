# Security Policy

This tool can export full Freshservice Knowledge Base articles. Use it only with an account that is authorized to read the articles and only for an approved purpose.

## Protect credentials and URLs

- **Never commit** a Freshservice API key, personal password, bearer token, or the URL of a live scheduled Analytics export.
- The exporter optionally stores an API key and Analytics URL with Windows user-scoped protection, using PowerShell `ConvertFrom-SecureString` / DPAPI. This protects the local settings file for the Windows account; it does not make exported data safe to share.
- Do not share `settings.json` or any generated inventory, exported article, or execution log.
- If an API key is exposed publicly, revoke or rotate it promptly.

## Handle exported articles carefully

Exported KB articles may contain internal network paths, employee names, system configurations, privileged operational procedures, or other sensitive information. Keep generated output outside the Git repository and store it in a location authorized by your organization.

The included `.gitignore` reduces the chance of adding generated reports, but is **not** a complete data-loss prevention mechanism. Inspect changes before every commit.

## Scope and authorization

The tool retrieves article IDs from a report or the latest scheduled Analytics export, then uses the supplied Freshservice API credentials to retrieve content. Accessible results are limited by the source inventory and the credentials' permissions.

## Responsible disclosure

For potential security issues in the tool, avoid opening a public issue that contains API keys, URLs of private exports, or extracted knowledge-base content. Contact the repository owner privately.
