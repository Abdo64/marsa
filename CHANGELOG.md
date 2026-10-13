# Changelog

## 0.4.2

### Terminal
- Copy selected text with Ctrl+C, as in Windows Terminal: with text selected
  it copies, with nothing selected it still sends Ctrl+C to the server.
  Ctrl+Shift+C always copies, Cmd+C on a Mac. Selecting by dragging is now
  covered by a test, including while a program such as tmux or vim has
  mouse reporting on.
- Press Enter on an ended or failed session to reconnect, no mouse needed.
  The terminal and the bar under it say so.

### Tabs
- The **+** button in the tab strip opens the Hosts page instead of a
  drop-down menu.

### SFTP
- A single click ticks a folder; a double click opens it.
- Drag and drop files and folders: onto the other pane to copy them into the
  folder it shows, onto a folder in the other pane to copy into that folder,
  or onto a folder in the same pane to move them into it. Dragging a ticked
  item takes everything ticked along.
- Fixed: a slow folder listing that finished after a newer one could take a
  pane back to the folder it had just left.
