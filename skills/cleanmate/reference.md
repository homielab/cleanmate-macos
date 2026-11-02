# CleanMate `cleanmate` reference

## Commands

| Command | Does |
| --- | --- |
| `cleanmate list --json` | every Smart Scan item: `id`, `group`, `name`, `description`, `selectedByDefault`, `disposal`, `dataLoss`, `needsFullDiskAccess`; scans nothing |
| `cleanmate scan --json` | measures the items like Smart Scan in the app; changes nothing |
| `cleanmate clean --dry-run --json --only ID,ID` | what a clean would do; deletes nothing, logs nothing |
| `cleanmate clean --yes --json --only ID,ID` | scans again, then cleans those items |
| `cleanmate space [PATH] --json` | a folder's children by size, like Space Lens (default: the home folder); read-only |
| `cleanmate large --json` | large files, like Large & Old Files (default: 50 MB or more in the home folder); read-only |
| `cleanmate --help` | every option, Undo, Full Disk Access, exit codes |

Options for `scan` and `clean`:

- `--only ID,ID`: these items (ids from `cleanmate list`). In `clean`, the items are cleaned even if unticked. The only
  way to clean an item with `"dataLoss": true`.
- `--group G,G`: these groups: `system`, `user`, `dev`, `ai`, `apps`, `privacy`. `clean --group` cleans only the items
  ticked by default in them, never the whole group.
- `--privacy`: include Privacy items (browser history, cookies, recent items). Needed to name a Privacy item or group.
- `--require-fda`: exit with code 3 instead of scanning when Full Disk Access is missing.
- `clean` without `--only` and `--group` cleans every item ticked by default. Prefer `--only` with the ids you showed.
- `clean` without `--only` never cleans an item with `"dataLoss": true` (`docker-volumes`, `docker-containers`), even
  ticked in the app: it lists it with `"locked": true` and the reason
  `"May hold data: name it with --only docker-volumes to clean it"`.
- Named with `--only`, `docker-volumes` and `docker-containers` remove every volume or container in their `entries`,
  one by one, except entries with a `reason` (a volume a stopped container still uses). The rows the user ticks in the
  app's Smart Scan stay in the app: `clean` does not see them, so it takes all of them. To keep some (a database), the
  user cleans them in the app instead, ticking only the ones to remove.

Options for `space` and `large`:

- `--limit N`: show the N biggest (`space` 20, `large` 50); the rest is counted in `moreItems` / `moreSize` or
  `moreFiles`.
- `large --min-size SIZE`: `50MB` by default, `1GB`, `500MB`… (1 MB = 10⁶ bytes). At least 50 MB for the whole home
  folder, 1 MB with `--in`.
- `large --older-than DAYS`: only files not opened or changed for that many days.
- `large --in PATH`: search this folder (in the home folder but not in `~/Library`, or an external drive).
- Without Full Disk Access, the folders macOS protects are listed in `skipped` and never read; a PATH inside one exits
  with code 3. A PATH that does not exist, is not a folder or can't be read exits with code 2.

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
> - Not suggested: Docker: unused volumes, 17.5 GB (`postgres-data`, `redis-data`). They may hold databases and are
>   deleted for good. Name them if you are sure.
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
      "dataLoss" : false,
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
      "dataLoss" : true,
      "disposal" : "delete",
      "entries" : [ { "name" : "postgres-data · local", "path" : "postgres-data", "size" : 17500000000 } ],
      "group" : "dev",
      "id" : "docker-volumes",
      "locked" : false,
      "name" : "Docker: unused volumes",
      "reason" : null,
      "selectedByDefault" : true,
      "size" : 17500000000,
      "sizeIsUpperBound" : false
    },
    {
      "dataLoss" : false,
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

An item may also have `records` (database rows a Privacy item erases) and `needsFullDiskAccess: true`. An entry may
have a `name` (a Docker volume or container, a simulator…): show it, its `path` is then an identifier (a volume name,
a container or image ID), not a file.

## `clean --yes --json` (shortened)

```json
{
  "dryRun" : false,
  "freed" : 19910000000,
  "inTrash" : 0,
  "items" : [
    {
      "dataLoss" : false,
      "freed" : 1500000000,
      "id" : "user-caches",
      "locked" : false,
      "name" : "User caches",
      "reason" : null,
      "skipped" : [
        { "path" : "~/Library/Caches/com.example.editor", "reason" : "Kept by the safety checks: in use, modified since the scan or not permitted" }
      ],
      "trashed" : 0
    },
    {
      "dataLoss" : true,
      "freed" : 0,
      "id" : "docker-volumes",
      "locked" : true,
      "name" : "Docker: unused volumes",
      "reason" : "May hold data: name it with --only docker-volumes to clean it",
      "skipped" : [ ],
      "trashed" : 0
    }
  ],
  "log" : "~/Library/Logs/CleanMate/activity.log",
  "upTo" : 0,
  "version" : "1.5"
}
```

`trashed` is the part of an item's `freed` moved to the Trash. `docker-volumes` shows what a clean without `--only`
does with a ticked item that may hold data: nothing, reported `locked`. With `--dry-run`, `dryRun` is `true`, `log` is `null`
and the numbers are what a clean would free.

## Example: what takes space

> **User:** What is filling my disk?
>
> **Agent:** *(runs `cleanmate space --json`, then `cleanmate space ~/Developer --json` on the biggest folder)* Your
> home folder holds 182 GB. The biggest part is Developer, 96 GB, mostly `~/Developer/game/Builds` (41 GB) and
> `~/Developer/web/node_modules` (3.2 GB). Then Movies 38 GB and Library 31 GB. Documents and Downloads were not
> measured: the app running me has no Full Disk Access.
>
> To remove builds you no longer need, open Space Lens in CleanMate: it moves them to the Trash so you can put them
> back. `node_modules` folders you have not touched for months are also in Smart Scan; shall I scan for them?

## `space --json` (shortened)

```json
{
  "fullDiskAccess" : false,
  "items" : [
    { "kind" : "folder", "name" : "Developer", "path" : "/Users/me/Developer", "reason" : null, "size" : 96000000000, "skipped" : false },
    { "kind" : "folder", "name" : "Movies", "path" : "/Users/me/Movies", "reason" : null, "size" : 38000000000, "skipped" : false },
    { "kind" : "file", "name" : "backup.zip", "path" : "/Users/me/backup.zip", "reason" : null, "size" : 2100000000, "skipped" : false },
    { "kind" : "folder", "name" : "Documents", "path" : "/Users/me/Documents", "reason" : "Needs Full Disk Access", "size" : null, "skipped" : true }
  ],
  "moreItems" : 9,
  "moreSize" : 4200000000,
  "path" : "/Users/me",
  "scannedAt" : "2026-11-02T08:00:00Z",
  "size" : 182000000000,
  "skipped" : [
    { "path" : "/Users/me/Documents", "reason" : "Needs Full Disk Access" }
  ],
  "version" : "1.5"
}
```

`size` is the whole folder without the skipped ones, hard links counted once. Skipped folders come after the measured
ones, with `size` `null`.

## `large --json` (shortened)

```json
{
  "count" : 2,
  "files" : [
    { "hardLinked" : false, "kind" : "diskImage", "lastUsed" : "2025-03-14T09:12:00Z", "modified" : "2025-03-01T10:00:00Z", "name" : "Xcode_16.dmg", "path" : "/Users/me/Downloads/Xcode_16.dmg", "size" : 3400000000 },
    { "hardLinked" : false, "kind" : "video", "lastUsed" : null, "modified" : "2024-08-20T18:30:00Z", "name" : "trip.mov", "path" : "/Users/me/Movies/trip.mov", "size" : 1900000000 }
  ],
  "fullDiskAccess" : true,
  "minSize" : 1000000000,
  "moreFiles" : 0,
  "olderThanDays" : 180,
  "root" : "/Users/me",
  "scannedAt" : "2026-11-02T08:00:00Z",
  "size" : 5300000000,
  "skipped" : [ ],
  "version" : "1.5"
}
```

`count` and `size` cover every file found, `files` the biggest `--limit` of them. `lastUsed` is when the file was last
opened, from Spotlight, `null` when Spotlight does not know.

## Safety

`cleanmate` cleans only the locations of CleanMate's catalog, with the app's safety rules and the user's exclusions
(Settings › Exclusions). It never runs as root, never touches system files macOS protects, and never connects to the
network. Every clean is written to the activity log. `space` and `large` only read: to remove what they find, the
user opens Space Lens or Large & Old Files in the app.
