# Freshservice Knowledge Base Exporter v3.4.2

A Windows PowerShell 5.1 desktop utility for exporting Freshservice **Solutions / Knowledge Base** articles into local, browsable HTML and structured JSON, with CSV inventories and execution logs.

The interface, progress dialogs, error messages and generated HTML metadata are in English. The exporter uses Freshservice REST API v2 and supports two ways to build the source article inventory.

See the [v3.4.2 release notes](docs/releases/v3.4.2.md) and [changelog](CHANGELOG.md) for the verified stable baseline.

## Features

- **Automatic inventory** from a scheduled Freshservice Analytics **Data Export** for the `Solutions` module.
- **Manual inventory** from an existing `.csv` or `.xlsx` reporting file.
- Article-ID deduplication (one content request per unique ID).
- Retrieval of article details by ID and category/folder metadata through the API.
- HTML and JSON files grouped into category/folder directories when mappings are available.
- Consolidated CSV inventory, source inventory, JSON aggregation, logging, and per-article error tracking.
- Windows Forms interface with validation, progress display, and modern folder selection.
- Optional Windows-user-protected storage of the Analytics URL and API key using `ConvertFrom-SecureString` / DPAPI.
- File/path-name sanitization for Windows paths; optional XLSX index when Microsoft Excel automation is available.

For complete setup and troubleshooting instructions, see the [English user guide](docs/USER_GUIDE.md).

## Requirements

- **Windows PowerShell 5.1** on Windows with Windows Forms.
- Network access to your Freshservice instance.
- An authorized Freshservice API key with access to the relevant Solutions articles, categories, and folders.
- For automatic inventory: an existing scheduled **Solutions** Analytics Data Export set to **API** delivery.
- For manual inventory: a CSV/XLSX report containing at least an `ID` column.

## Quick start

1. Download `Freshservice-KnowledgeBase-Exporter.ps1` using GitHub's **Raw / Download raw file** action (rather than copy-pasting its contents). Keep its **UTF-8 with BOM** encoding when saving edits; Windows PowerShell 5.1 can misparse UTF-8 files without BOM.
2. Open Windows PowerShell in the script directory.
3. Run:

   ```powershell
   .\Freshservice-KnowledgeBase-Exporter.ps1
   ```

4. Enter your Freshservice domain (for example `yourcompany.freshservice.com`) and API key. The Basic Auth password field uses the placeholder `X`; do not enter your personal password.
5. Choose **Automatic** (scheduled Analytics API export URL) or **Manual** (reporting CSV/XLSX).
6. Choose an export destination and click **Start export**.

An organization may require an approved execution policy or additional permissions. Follow your organization's security policies.

## Configure automatic inventory

In Freshservice: **Analytics → Settings → Data Export → Create Export**.

1. Select module **Solutions**.
2. Select the workspaces and scope you are authorized to export.
3. Include **ID** at minimum; **Title, Type, Status, Author, Category, Folder**, and dates are useful for the resulting inventory.
4. Choose **API** delivery, schedule the export, and save it.
5. Copy the generated Data Export API URL into the GUI.

The tool downloads the **latest available scheduled export** and then retrieves each unique article through the regular Freshservice API. It **does not trigger a fresh Analytics snapshot** at launch. A scheduled export must have run at least once.

## Output

Each run creates a dated export directory with article HTML/JSON, consolidated JSON, an index CSV, reference category/folder JSON files, and an execution log. The XLSX index is optional.

The exported set is limited to article IDs present in the source inventory **and** readable with the supplied API credentials. The completion summary separately reports **successful API reads** and **HTML+JSON article files actually saved**. Review any file-writing failures in the error log.

## Security

**Do not commit exported Knowledge Base data or credentials to GitHub.** KB articles can include internal procedures, technical configuration, links, or other confidential data.

- Enter secrets in the application, never in source code.
- The Analytics URL may grant access to exported data; keep it private.
- Optional saved secrets are protected for the current Windows user. Local encryption does not authorize sharing them.
- Verify scope and authorization before bulk exporting an organization's content.

See [SECURITY.md](SECURITY.md) for more details.

## Compatibility notes

The v3.4.2 English version preserves the validated v3.3 export engine while translating the interface, comments, error messages, and generated HTML metadata. The source was statically checked to retain the same executable tokens outside text and comments, and the UTF-8 BOM was preserved. This English edition has not yet been integration-tested on Windows PowerShell 5.1 or every Freshservice tenant.

## References

- [Freshworks — Scheduled Data Export](https://support.freshservice.com/support/solutions/articles/238958-scheduled-data-export)
- [Freshservice API documentation](https://api.freshservice.com/)

This project is a community utility and is not an official Freshworks product.
