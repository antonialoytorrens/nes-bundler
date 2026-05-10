# Configure your bundle

This directory has a pre-configured bundle for reference.
If you want to build a proper bundle you also need to dig into the individual subdirectories here to customise icons etc.

Here is a breakdown of what can be customised:

* [config.yaml](config.yaml) — the main configuration
* [rom.nes](rom.nes) — your game
* [palette.pal](palette.pal) — the current palette is generated with `palgen_persune.py --skip-plot -aps 5 -ela 0.01429 -e -hue 3.75 -sat 0.8 -o palette.pal`. See [here](https://github.com/Gumball2415/palgen-persune) for details
* [Linux icon](linux/icon_256x256.png)
* [Windows app and window title icon](windows/app.ico) — see [Microsoft's icon guide](https://learn.microsoft.com/en-us/windows/apps/design/style/iconography/app-icon-construction) for details about a proper `.ico` file

## Prepare the configuration for bundling

Zip the files with `prepare.sh`:

```bash
./prepare.sh
```

This produces `config.zip` ready to POST to your bundler service. See the top-level [README.md](../README.md#bundling-your-own-game) for the request flow.

## Note on code signing

The Windows `.exe` produced by the bundler service is **not** code signed. Users will see the usual SmartScreen prompt on first launch and need to accept it.
