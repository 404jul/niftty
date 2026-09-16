<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Niftty
</h1>
  <p align="center">
    ✨ <strong>A terminal built for remote work</strong> ✨<br />
    SSH, port forwarding, and drag-and-drop file upload —<br />
    all in one cozy, native app. 🖥️💚<br />
    A fork of <a href="https://ghostty.org">Ghostty</a> 👻
  </p>
</p>

## 🌟 About

Niftty is a fork of [Ghostty](https://ghostty.org), the fast, native,
feature-rich terminal emulator. Niftty takes that solid terminal core and
focuses it on working with remote machines, so you can spend less time
fiddling with tooling and more time getting work done. 🚀

## ✨ Features

| Feature                     | What it does                                                                                               |
| --------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 🔐 **SSH**                  | First-class SSH connectivity for connecting to remote hosts without ever leaving the terminal.             |
| 🛤️ **Port forwarding**      | Easily set up local and remote port forwarding so services on a remote machine behave like they're local.  |
| 📂 **Drag-and-drop upload** | Drag files from your desktop straight into the terminal to upload them to the remote host.                 |
| 👻 **Ghostty superpowers**  | The full Ghostty terminal core: native speed, rich features, and `libghostty` + `libghostty-vt` libraries. |

## 🛠️ Building

See [HACKING.md](HACKING.md) 📚 for development setup. To build the macOS app:

```shell-session
zig build
```

The canonical output is `zig-out/Niftty.app`. If you're on macOS and don't
need the app bundle, use `-Demit-macos-app=false` to speed up compilation. ⚡

## 🔗 Upstream

Niftty is built on Ghostty's terminal core, including the `libghostty` and
`libghostty-vt` libraries. For upstream documentation about Ghostty itself,
see the [Ghostty website](https://ghostty.org/docs). 📖

---

<p align="center">Made with 💚 and Zig ⚡</p>
