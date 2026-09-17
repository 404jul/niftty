<!-- LOGO -->
<h1>
<p align="center">
 <img src="images/icons/256x256.png" alt="Logo" width="128">
 <br>Niftty
</h1>
 <p align="center">
 <strong>A terminal built for remote work</strong> <br />
 SSH, port forwarding, and drag-and-drop file upload —<br />
 all in one cozy, native app. <br />
 </p>
</p>

## About

Niftty is a fast, native, feature-rich terminal emulator focused on
working with remote machines, so you can spend less time
fiddling with tooling and more time getting work done.

## Features

| Feature | What it does |
| --------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **SSH** | First-class SSH connectivity for connecting to remote hosts without ever leaving the terminal. |
| **Port forwarding** | Easily set up local and remote port forwarding so services on a remote machine behave like they're local. |
| **Drag-and-drop upload** | Drag files from your desktop straight into the terminal to upload them to the remote host. |
| **Built-in shaders** | Choose from bundled cursor effects with live previews in Settings, or point at your own glsl. |
| **Built-in text editor** | Open files in an editor pane right beside your terminal, with save and dirty-state tracking. |

## Building

To build the macOS app:

```shell-session
zig build
```

The canonical output is `zig-out/Niftty.app`. If you're on macOS and don't
need the app bundle, use `-Demit-macos-app=false` to speed up compilation.

---

<p align="center">Made with Zig</p>
