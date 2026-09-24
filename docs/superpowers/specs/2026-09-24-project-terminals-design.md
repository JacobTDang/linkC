# Project terminals: open a terminal in a project, and file terminals under projects

Jacob: "I would also like to be able to launch a terminal inside of the project directories as well,
and be able to drag terminals to the projects if possible." Asked what dragging should do, he chose
**file it under the project**:
- it moves into that project's list and tab strip;
- the shell itself is untouched, so linkC never types `cd`;
- dragging it out unfiles it.

## Behaviour

1. **New terminal in a project.** The project row's ＋ menu and the tab strip's ＋ menu both gain
   **New terminal**, after the agents and a divider. It opens the login shell in the project's folder,
   files it under that project, and selects it.
2. **Terminals live under their project.** An expanded project lists its agent sessions, then its
   terminals, in the same row style as the Terminals section. The **Terminals** section keeps only
   terminals that belong to no project.
3. **Which project a terminal belongs to.** One pure rule, in LinkCKit:
   1. A terminal filed under a project belongs to it.
   2. Otherwise, a terminal whose folder is a project's folder belongs to that project. Folders are
      compared as the rest of the sidebar compares them. Merging symlinked paths is a separate,
      later fix.
   3. Otherwise it belongs to none.
4. **A project with only terminals** still shows in Projects, with a quiet dot, as long as a
   terminal is filed under it. Terminals that merely share a folder don't create a project.
5. **Dragging.**
   - Drag a terminal row onto a project row to file it there; the row highlights while it is a
     valid target.
   - Drag a terminal onto the **Terminals** label to unfile it.
   - Only linkC terminal rows are accepted. The payload is the terminal id with a `linkc-terminal:`
     prefix, and any other drop is ignored.
6. **The tab strip and the Board.**
   - A project's strip lists its terminals by the same rule.
   - Selecting a filed terminal makes its project the current one, so the Board tab and ⌘1 work
     from it.
7. **Persistence.**
   - Filings are saved with the other sidebar state as terminal id → project path.
   - They're pruned when a terminal is dismissed.
   - A relaunched terminal keeps its filing.

## Testing

- **LinkCKit, TDD:**
  - the membership rule: filed, then matching folder, then none;
  - filing, unfiling, pruning and persistence in `SidebarState`;
  - `SidebarModel` listing terminals under projects, and a project that has only filed terminals;
  - `ProjectTabs` using the rule.
- **In the app:**
  - New terminal from both menus;
  - dragging onto a project, and back to Terminals;
  - the highlight;
  - the Board working from a filed terminal;
  - relaunch keeping the filing.

## Out of scope

- Changing a shell's folder (no `cd`).
- Dragging agent sessions between projects.
- Merging symlinked project paths, a separate backlog item.
