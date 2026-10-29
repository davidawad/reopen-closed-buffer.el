# reopen-closed-buffer

A browser's "reopen closed tab", for Emacs buffers. Kill a buffer by
mistake and get it back as it was: a file at its position, a dired, an
eshell in its directory, an eat or vterm terminal running its command
again, a Claude Code session resumed by its id.

It is a thin shell over
[terra-emacs](https://github.com/davidawad/terra-emacs.el) and
[terra-emacs-capture](https://github.com/davidawad/terra-emacs-capture.el).
On a kill, terra-emacs-capture describes the buffer as a leaf record;
reopening hands that record to the engine, which restores it the way it
restores any leaf of a layout. Its companion,
[reopen-closed-workspace](https://github.com/davidawad/reopen-closed-workspace.el),
does the same for whole tabs and perspectives.

Pure Emacs Lisp, Emacs 29.1 or later.

## Install

Emacs 30 and later, with `package-vc` (dependencies first):

```elisp
(package-vc-install "https://github.com/davidawad/terra-emacs.el")
(package-vc-install "https://github.com/davidawad/terra-emacs-capture.el")
(package-vc-install "https://github.com/davidawad/reopen-closed-buffer.el")
(require 'reopen-closed-buffer)
(reopen-closed-buffer-mode 1)
(global-set-key (kbd "C-x C-S-t") #'reopen-closed-buffer)   ; any key you like
```

Emacs 29.1, or by hand: clone the three repositories and put them on
`load-path`.

```elisp
(add-to-list 'load-path "~/src/terra-emacs.el")
(add-to-list 'load-path "~/src/terra-emacs-capture.el")
(add-to-list 'load-path "~/src/reopen-closed-buffer.el")
(require 'reopen-closed-buffer)
(reopen-closed-buffer-mode 1)
```

## Commands

| Command | Does |
|---|---|
| `reopen-closed-buffer-mode` | global minor mode: record each killed buffer (`kill-buffer-hook`) |
| `reopen-closed-buffer` | reopen the most recently killed buffer |
| `reopen-closed-buffer-list` | pick one of the killed buffers (`completing-read`, newest first) and reopen it |

A buffer reopens in the workspace that showed it (the tab or
perspective of the terra-emacs backend in use) when that still exists,
in the same window when the layout still has as many windows, and
otherwise in the selected window.

## What is recorded

| Buffer | Comes back as |
|---|---|
| file, dired, Info, help, anything with bookmark support | its bookmark record: the file at its position |
| eshell | an eshell of that name in its directory |
| eat, vterm | the same command, re-run in its directory |
| Claude Code in eat | the session, resumed by id (`--resume ID`); when it is still live somewhere else, the engine opens a read-only view instead, never a second writer |

A buffer with nothing to restore but its name is not recorded: it would
come back empty. Neither are buffers whose name starts with a space,
minibuffers, terra-emacs placeholders, or names matching
`reopen-closed-buffer-ignore-regexps` (`*Messages*`, `*scratch*`,
`*Completions*`, `*Backtrace*`, ...). Replace the whole test with
`reopen-closed-buffer-ignore-predicate`, a function of the buffer.

Each entry holds the leaf record, the time, the workspace's name and
the window's index. One leaf (one file, one terminal command, one
Claude session) has one entry; killing it again moves it to the head.

## Options

| Option | Default |
|---|---|
| `reopen-closed-buffer-size` | 50 entries |
| `reopen-closed-buffer-file` | `reopen-closed-buffer.eld` in `user-emacs-directory`, rewritten on every change so the ring survives a restart; nil keeps it in memory |
| `reopen-closed-buffer-ignore-regexps` | see above |
| `reopen-closed-buffer-ignore-predicate` | `reopen-closed-buffer-ignore-p` |
| `reopen-closed-buffer-exit-wait` | 2.0: seconds reopening waits for a killed buffer's process to finish exiting, so a Claude session just killed is resumed rather than seen as live elsewhere |

## Tests

`make test` byte-compiles the package with warnings as errors, then
runs each `test/test-*.el` ERT suite in its own batch Emacs: recording
a kill, the ring and its file (including a real restart: one child
Emacs kills a buffer, the next reopens it), and reopening files, eat
terminals and a fake Claude session, in tab-bar and persp-mode
workspaces. The engine comes from `TERRA_EMACS_DIR` and the exporter
from `TERRA_EMACS_CAPTURE_DIR` (defaults: sibling checkouts). eat,
compat and persp-mode come from `TERRA_EMACS_TEST_PACKAGES`, the
colon-separated directories in `TERRA_EMACS_TEST_LOAD_PATH`, or else
your own Emacs's installed copies; tests needing one skip without it.

```sh
git clone https://github.com/davidawad/terra-emacs.el ../terra-emacs.el
git clone https://github.com/davidawad/terra-emacs-capture.el ../terra-emacs-capture.el
make test
```

## License

MIT. See [LICENSE](LICENSE).
