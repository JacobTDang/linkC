# A terminal's name and project follow its folder

Jacob, 2026-09-24: "When I am using a terminal and switch directories, I would also like the name to change as well."

He decided that both the name and the grouping follow the folder: "Both follow". He approved the design below.

## Behaviour

- **A plain terminal is named after its current folder.** A plain terminal is one opened as a shell, with no command. Its name is the last component of its current folder: `cd Sources` shows "Sources". The home folder shows as "~" and the root as "/". The name updates within about a second of a `cd`, wherever the name appears: the sidebar row, the project tab strip, and their tooltips.
- **Command terminals don't change.** A terminal launched with a command, such as `docker logs`, keeps the title it was given.
- **Grouping follows the folder.** The terminal's current folder feeds the existing project rule (`TerminalFiling.project`: the filing first, then the folder). So `cd ~/Projects/linkC` moves an unfiled terminal under linkC. A terminal the user filed stays where it was filed; only its name changes.
- **It reopens where it was left.** The current folder is saved to `shells.json` on every change. So after quitting (or a crash), a restored terminal opens in the folder it was last in, not the one it started in.
- **A running program doesn't move it.** While a program such as `claude` or `vim` runs in the terminal, the shell itself hasn't changed folder, so the name stays.

## How the folder is read

linkC asks the kernel for the shell process's current folder once a second: `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO)`, the `pvi_cdir` path. This runs in the existing one-second shell sweep.
- It works for zsh, bash and fish.
- It needs no shell configuration.
- linkC never types into the shell or adds hooks to it.

The shell's own escape-code reporting (OSC 7) was rejected: zsh and bash don't send it by default, and enabling it means changing the user's shell startup.

## Pieces

- **`ProcessSnooper.currentDirectory(ofPid:) -> String?`** (LinkCKit): the kernel read. It returns nil when the process is gone or the kernel refuses.
- **`ShellTitle.name(forDirectory:home:) -> String`** (LinkCKit, pure): "~" for `home`, "/" for the root, otherwise the last path component. A trailing slash is ignored.
- **`ShellRow`**: `cwd` and `title` become `public internal(set) var`.
- **`ShellTerminalStore.updateDirectory(id:to:) -> ShellRow?`**:
  - It sets `cwd` and, for a plain terminal (`command == nil`), sets `title` via `ShellTitle`.
  - It writes only on a real change and returns the updated row; it returns nil otherwise. The sweep runs every second, and a write each tick would invalidate every observer of `rows`, as `updateDetectedAgent` already avoids.
- **`ShellCoordinator.sampleDirectories()`**:
  - For each running row with a live terminal, it reads `currentDirectory(ofPid: terminal.processId)`.
  - It standardizes the path and calls `updateDirectory`.
  - On a change, it upserts the manifest entry.
  - If a live shell's folder can't be read, it logs once per terminal (fail loud without flooding the log). It logs again only after a successful read.
- **App:** `AppModel.sampleShellAgents()` calls `shells?.sampleDirectories()` next to `sampleAgents()`. Nothing else changes: the sidebar, the tab strip and `currentProject` already read `row.cwd` and `row.title`.

## Testing (LinkCKit, test-first)

- **`ShellTitleTests`**: home → "~"; "/" → "/"; `/Users/j/Projects/linkC` → "linkC"; a trailing slash is ignored.
- **`ShellTerminalStoreTests`**:
  - a plain terminal's `cwd` and `title` change together;
  - a command terminal's `cwd` changes but its title doesn't;
  - the same folder again returns nil and leaves `rows` unchanged.
- **`ProcessSnooperTests`**: spawn `/bin/sh -c 'cd /tmp && sleep 5'`, and read back `/private/tmp`. A pid that doesn't exist returns nil.
- **`ShellCoordinatorTests`**: `sampleDirectories` updates a row whose shell has changed folder, and writes the manifest entry with the new folder.
- **`SidebarModelTests`**:
  - an unfiled terminal whose `cwd` is a project's folder shows under that project;
  - a filed terminal whose `cwd` is another project's folder stays under its filing.

Checked by hand in the app:
- `cd` around in a terminal and watch the sidebar row and tab;
- `cd` into another project's folder;
- run `claude` and check that the name holds;
- quit and reopen, and check that it reopens in the last folder.

## Out of scope

- Renaming terminals by hand.
- Showing a program's own folder while it runs in the terminal.
- OSC 7 or shell-integration hooks.
