# better-battery

Lightweight UPower listener for battery notifications and sounds.

This repository contains a configurable Bash daemon that listens to UPower via D-Bus (gdbus monitor) and dispatches desktop notifications and optional sounds on some battery/AC events.


## Quick install

1. Clone this repository.
2. Make the script executable `chmod +x better-battery`.
3. Copy better-battery.conf to ~/.config/better-battery to customize (optional).
4. Install the systemd service (optional).


```sh
mkdir -p ~/.config/systemd/user
cp better-battery.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now better-battery.service
```

5. Check logs with `journalctl --user -u better-battery.service -f` or run the script directly for debugging.

6. Customize the configuration files as you prefer.
7. Adjust `ExecStart` path to wherever you place the script (e.g. `~/.local/bin)` and the configuration file.

## Next steps

- Put the script into `~/.local/bin` and the config in `~/.config`.

- If you don't want sounds, set the sound variables to empty strings in the config file.


# LICENSE

This project is MIT licensed. See the [`LICENSE`](https://choosealicense.com/licenses/mit/).

