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
| `cleanmate dupes --json` | duplicate files among those `large` finds, like the Duplicates Only filter; read-only |
| `cleanmate similar [PATH…] --json` | photos that look alike, like Similar Photos (default: the home folder); read-only |
| `cleanmate trash --yes --json PATH…` | moves exactly those files and folders to the Trash, after the user confirmed them |
| `cleanmate restore --list --json` | what CleanMate (the app and `cleanmate`) moved to the Trash and is still there, newest first; read-only |
| `cleanmate restore --json TRASHED…` | puts items CleanMate moved back at their old place, never overwriting |
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

Options for `space`, `large`, `dupes` and `similar`:

- `--limit N`: show the N biggest (`space` 20, `large` 50, `dupes` and `similar` 20 groups); the rest is counted in
  `moreItems` / `moreSize`, `moreFiles` or `moreGroups`.
- `large` / `dupes --min-size SIZE`: `50MB` by default, `1GB`, `500MB`… (1 MB = 10⁶ bytes). At least 50 MB for the whole home
  folder, 1 MB with `--in`.
- `large --older-than DAYS`: only files not opened or changed for that many days.
- `large` / `dupes --in PATH`: search this folder (in the home folder but not in `~/Library`, or an external drive).
- `similar PATH…`: search these folders (same rules as `--in`; `--in PATH` works too). Photos of 20 KB or more;
  `--min-size` and `--older-than` do not apply.
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
      "durationMs" : 1830,
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
> Shall I move `~/Developer/game/Builds` to the Trash? You can put it back. `node_modules` folders you have not
> touched for months are also in Smart Scan; shall I scan for them?
>
> **User:** Yes, the builds.
>
> **Agent:** *(runs `cleanmate trash --yes --json /Users/me/Developer/game/Builds`)* Moved Builds (41 GB) to the
> Trash. It frees the space once you empty the Trash; until then I can put it back.

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
    { "hardLinked" : false, "kind" : "installer", "lastUsed" : "2025-03-14T09:12:00Z", "modified" : "2025-03-01T10:00:00Z", "name" : "Xcode_16.dmg", "path" : "/Users/me/Downloads/Xcode_16.dmg", "size" : 3400000000 },
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
opened, from Spotlight, `null` when Spotlight does not know. `icloud` appears only on a file that syncs with iCloud
Drive: `uploaded` (every change is in iCloud), `notUploaded`, `syncing` or `conflict`. The command line can't remove a
download: for an `uploaded` file, point to **Remove Download** in Large & Old Files (it stays in iCloud).

## `dupes --json` (shortened)

```json
{
  "count" : 1,
  "groups" : [
    {
      "count" : 2,
      "files" : [
        { "freeable" : 1200000000, "modified" : "2024-05-02T10:00:00Z", "oldest" : true, "path" : "/Users/me/Movies/trip.mov" },
        { "freeable" : 1200000000, "modified" : "2025-01-10T09:00:00Z", "oldest" : false, "path" : "/Users/me/Downloads/trip copy.mov" }
      ],
      "size" : 1200000000,
      "wasted" : 1200000000
    }
  ],
  "fullDiskAccess" : true,
  "minSize" : 50000000,
  "moreGroups" : 0,
  "root" : "/Users/me",
  "scannedAt" : "2026-11-02T08:00:00Z",
  "skipped" : [ ],
  "version" : "1.5",
  "wasted" : 1200000000
}
```

`count` and `wasted` cover every group found, `groups` the `--limit` wasting the most. `wasted` is what moving every
copy but the oldest to the Trash frees; `freeable` 0 marks an APFS clone or a file with other hard links.

## `similar --json` (shortened)

```json
{
  "analyzed" : 3,
  "count" : 1,
  "durationMs" : 2140,
  "freeable" : 2900000,
  "fullDiskAccess" : true,
  "groups" : [
    {
      "count" : 3,
      "freeable" : 2900000,
      "photos" : [
        { "height" : 3024, "modified" : "2025-07-14T09:12:00Z", "path" : "/Users/me/Pictures/IMG_0412.jpg", "size" : 3100000, "suggested" : true, "width" : 4032 },
        { "height" : 3024, "modified" : "2025-07-14T09:12:01Z", "path" : "/Users/me/Pictures/IMG_0413.jpg", "size" : 2400000, "suggested" : false, "width" : 4032 },
        { "height" : 1512, "modified" : "2025-08-01T18:30:00Z", "path" : "/Users/me/Desktop/IMG_0412 small.jpg", "size" : 500000, "suggested" : false, "width" : 2016 }
      ]
    }
  ],
  "minSize" : 20000,
  "moreGroups" : 0,
  "photos" : 3,
  "roots" : [ "/Users/me/Pictures", "/Users/me/Desktop" ],
  "scannedAt" : "2026-11-02T08:00:00Z",
  "skipped" : [ ],
  "version" : "1.5"
}
```

`count` and `freeable` cover every group found, `groups` the `--limit` freeing the most. In each group the `suggested`
photo comes first (most pixels, then largest, then newest); `freeable` is what moving the other photos frees. Nothing
is ticked: the user picks. `photos` is how many were compared, `analyzed` how many of them were not yet in CleanMate's
cache (the app's; `similar` reads it but never writes it).

## `trash --yes --json` (shortened)

```json
{
  "count" : 1,
  "items" : [
    { "kind" : "file", "path" : "/Users/me/Downloads/trip copy.mov", "reason" : null, "size" : 1200000000, "skipped" : false, "trashed" : "/Users/me/.Trash/trip copy.mov" },
    { "kind" : "folder", "path" : "/Users/me/.ssh", "reason" : "Hidden (like ~/.ssh): CleanMate never moves hidden files or folders", "size" : null, "skipped" : true, "trashed" : null },
    { "kind" : null, "path" : "/Users/me/Movies/gone.mov", "reason" : "Not found", "size" : null, "skipped" : true, "trashed" : null }
  ],
  "log" : "~/Library/Logs/CleanMate/activity.log",
  "size" : 1200000000,
  "version" : "1.5"
}
```

One item per path, in the order given (a path given twice once). `count` and `size` cover what moved; it stays on disk
until the Trash is emptied. `trashed` is the argument for `restore` (Finder may add a number when the name is taken).

## `restore --json` (shortened)

```json
{
  "count" : 1,
  "items" : [
    { "path" : "/Users/me/Downloads/trip copy.mov", "reason" : null, "skipped" : false, "trashed" : "/Users/me/.Trash/trip copy.mov" },
    { "path" : "/Users/me/Movies/trip.mov", "reason" : "Something is already at its place: nothing was overwritten", "skipped" : true, "trashed" : "/Users/me/.Trash/trip.mov" },
    { "path" : null, "reason" : "Not moved to the Trash by CleanMate (or put back already): see `cleanmate restore --list`", "skipped" : true, "trashed" : "/Users/me/.Trash/other.mov" }
  ],
  "log" : "~/Library/Logs/CleanMate/activity.log",
  "version" : "1.5"
}
```

`path` is the old place. `restore` only knows what CleanMate moved: `trash`, `clean`, and in the app
Smart Scan, Large & Old Files, Space Lens and the Uninstaller (kept in
`~/Library/Application Support/CleanMate/trashed.json`, the last 1,000). Items the user moved to the Trash in Finder
are put back with Put Back in Finder; deleted junk can't be put back.

## `restore --list --json` (shortened)

```json
{
  "count" : 2,
  "items" : [
    { "date" : "2026-11-02T09:41:12+07:00", "kind" : "file", "path" : "/Users/me/Downloads/trip copy.mov", "size" : 1200000000, "source" : "Command Line", "trashed" : "/Users/me/.Trash/trip copy.mov" },
    { "date" : "2026-11-01T18:03:55+07:00", "kind" : "folder", "path" : "/Users/me/Projects/old-app", "size" : 734003200, "source" : "Space Lens", "trashed" : "/Users/me/.Trash/old-app" }
  ],
  "version" : "1.5"
}
```

Newest first, at most 200 (`--limit N`). `date` is when it was moved, `source` what moved it (`Command Line`,
`Smart Scan`, `Large & Old Files`, `Space Lens`, `Uninstaller`, `Login Items`; `unknown` for an older record, whose
`date` may be `null`), `size` its bytes then. Items no longer in the Trash
are not listed. Each `trashed` is an argument for `restore`. `version` is the app's version, like every other command's.

## Safety

`cleanmate` cleans only the locations of CleanMate's catalog, with the app's safety rules and the user's exclusions
(Settings › Exclusions). It never runs as root, never touches system files macOS protects, and never connects to the
network. Every clean is written to the activity log. `space`, `large`, `dupes` and `similar` only read. `trash` only moves to the
Trash, never deletes, and only the paths named that pass the same rules as Space Lens in the app; `trash` and `restore`
are written to the activity log too.
