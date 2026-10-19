# Changelog

All notable changes to Freshservice Knowledge Base Exporter are documented here.

## [3.4.2] - 2026-10-19

First end-to-end validated English edition.

### Added
- Automatic article inventory retrieval from a scheduled Freshservice Analytics Data Export for the Solutions module.
- Manual CSV/XLSX inventory import with article ID deduplication.
- HTML and JSON exports, category/folder organization, CSV inventory, and execution logs.
- Windows Forms interface and optional encrypted local preference storage.
- Separate counters for successful API reads and article HTML/JSON files saved.

### Fixed
- Sanitize trailing spaces and periods in Windows directory components, including after truncation.
- Report article-level file write failures accurately instead of counting all successful API reads as saved articles.
- Preserve UTF-8 BOM for Windows PowerShell 5.1 compatibility.
- Correct PowerShell interpolation when a colon follows an article ID in log messages.

### Validation

A complete automatic export was executed on Windows PowerShell 5.1 on 2026-10-19:

| Metric | Result |
| --- | ---: |
| Source report rows | 1,337 |
| Unique article IDs | 920 |
| Categories | 21 |
| Folders | 96 |
| Successful article API reads | 920 |
| HTML + JSON article pairs saved | 920 |
| Failed API reads | 0 |
| Failed article file writes | 0 |
| Logged errors | 0 |

CSV inventory generation succeeded. XLSX creation was skipped because Microsoft Excel automation was unavailable on the test machine; this is an optional output.

The results confirm successful extraction of all IDs in the *test inventory* accessible to the configured API account. They do not establish that the same article count or scope applies to other tenants.

### Compatibility

Windows PowerShell 5.1 on Windows. A scheduled Analytics Solutions Data Export is required for automatic mode; manual CSV/XLSX mode remains available.
