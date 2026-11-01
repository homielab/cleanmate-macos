# CleanMate `cleanmate` reference

## Commands

| Command | Does |
| --- | --- |
| `cleanmate list --json` | every Smart Scan item: `id`, `group`, `name`, `description`, `selectedByDefault`, `disposal`, `needsFullDiskAccess`; scans nothing |
| `cleanmate scan --json` | measures the items like Smart Scan in the app; changes nothing |
| `cleanmate clean --dry-run --json --only ID,ID` | what a clean would do; deletes nothing, logs nothing |
| `cleanmate clean --yes --json --only ID,ID` | scans again, then cleans those items |
| `cleanmate --help` | every option, Undo, Full Disk Access, exit codes |

Options for `scan` and `clean`:

- `--only ID,ID`: these items (ids from `cleanmate list`). In `clean`, the items are cleaned even if unticked.
- `--group G,G`: these groups: `system`, `user`, `dev`, `ai`, `apps`, `privacy`. `clean --group` cleans only the items
  ticked by default in them, never the whole group.
- `--privacy`: include Privacy items (browser history, cookies, recent items). Needed to name a Privacy item or group.
- `--require-fda`: exit with code 3 instead of scanning when Full Disk Access is missing.
- `clean` without `--only` and `--group` cleans every item ticked by default. Prefer `--only` with the ids you showed.

## Example conversation

> **User:** My Mac is almost full, can you clean it up?
>
> **Agent:** *(runs `cleanmate scan --json`)* CleanMate found 23.4 GB to clean:
>
> - System Junk: User caches 1.5 GB, Old logs 210 MB (deleted, apps rebuild them)
> - Developer Junk: Xcode DerivedData 18.2 GB (deleted, rebuilt on the next build)
> - Trash: 3.5 GB in the Trash (emptied for good)
> - Locked: Google Chrome (Applications, 640 MB), because Google Chrome is running. Quit it and I can rescan.
> - Not suggested: Ollama: downloaded models, 12 GB (you'd have to download them again). Say if you want them gone.
>
> Shall I clean the four suggested items?
>
> **User:** Yes, but keep the Trash.
>
> **Agent:** *(runs `cleanmate clean --yes --json --only user-caches,old-logs,xcode-derived-data`)* Freed 19.9 GB.
> One cache folder was kept because an app is using it. The log is in Settings › Activity in CleanMate.

## `scan --json` (shortened)

```json
{
  "fullDiskAccess" : true,
  "items" : [
    {
      "disposal" : "delete",
      "entries" : [ { "path" : "~/Library/Developer/Xcode/DerivedData/App-abc", "size" : 9100000000 } ],
      "group" : "dev",
      "id" : "xcode-derived-data",
      "locked" : false,
      "moreEntries" : 12,
      "name" : "Xcode DerivedData",
      "reason" : null,
      "selectedByDefault" : true,
      "size" : 18200000000,
      "sizeIsUpperBound" : false
    },
    {
      "disposal" : "delete",
      "entries" : [ { "path" : "~/Library/Caches/Google/Chrome/Default", "size" : 640000000, "reason" : "Google Chrome is running" } ],
      "group" : "apps",
      "id" : "chrome",
      "locked" : true,
      "name" : "Google Chrome",
      "reason" : "Google Chrome is running",
      "selectedByDefault" : true,
      "size" : 640000000,
      "sizeIsUpperBound" : false
    }
  ],
  "scannedAt" : "2026-11-02T08:00:00Z",
  "total" : 23410000000,
  "totalUpTo" : 0,
  "version" : "1.5"
}
```

An item may also have `records` (database rows a Privacy item erases) and `needsFullDiskAccess: true`.

## `clean --yes --json` (shortened)

```json
{
  "dryRun" : false,
  "freed" : 19910000000,
  "inTrash" : 0,
  "items" : [
    {
      "freed" : 1500000000,
      "id" : "user-caches",
      "locked" : false,
      "name" : "User caches",
      "reason" : null,
      "skipped" : [
        { "path" : "~/Library/Caches/com.example.editor", "reason" : "Kept by the safety checks: in use, modified since the scan or not permitted" }
      ],
      "trashed" : 0
    }
  ],
  "log" : "~/Library/Logs/CleanMate/activity.log",
  "upTo" : 0,
  "version" : "1.5"
}
```

`trashed` is the part of an item's `freed` moved to the Trash. With `--dry-run`, `dryRun` is `true`, `log` is `null`
and the numbers are what a clean would free.

## Safety

`cleanmate` cleans only the locations of CleanMate's catalog, with the app's safety rules and the user's exclusions
(Settings › Exclusions). It never runs as root, never touches system files macOS protects, and never connects to the
network. Every clean is written to the activity log.
