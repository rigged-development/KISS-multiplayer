# Building
First, download and install [a Rust toolchain](https://rustup.rs/)

After, clone the KissMP repository
```sh
git clone https://github.com/TheHellBox/KISS-multiplayer.git
cd KISS-multiplayer
```

## One-click build on Windows (includes Linux artifacts)
The script below builds Windows targets and Linux targets (`x86_64-unknown-linux-gnu`) in one run.
It bootstraps Docker Desktop checks and installs `cross` when needed.
Linux system dependencies required by audio crates are provided via `Cross.toml`.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-all.ps1
```

Optional setup-only mode (prepare toolchain, Docker and cross, no compile):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-all.ps1 -SetupOnly
```

Now you are ready to build the server and bridge.
## Server
```sh
cd kissmp-server
cargo run --release
```
or
```sh
cargo run -p kissmp-server --release
```
## Bridge
```sh
cd kissmp-bridge
cargo run --release
```
or
```sh
cargo run -p kissmp-bridge --release
```
