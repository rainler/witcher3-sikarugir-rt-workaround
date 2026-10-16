# Witcher 3 ray-tracing startup workaround for Sikarugir

**Experimental. Tested on one M5 Mac with Ray Tracing on and Path Tracing off.** The tester confirmed that a save loaded into playable gameplay after applying the workaround. Long-duration stability and other hardware have not been established.

## Download and Quick Start

**[Download v0.1.0-preview.1 ZIP](https://github.com/rainler/witcher3-sikarugir-rt-workaround/releases/download/v0.1.0-preview.1/witcher3-sikarugir-rt-workaround-v0.1.0-preview.1.zip)** · [Release notes](https://github.com/rainler/witcher3-sikarugir-rt-workaround/releases/tag/v0.1.0-preview.1)

This ZIP contains the installer and source. It builds the library on your Mac using Python 3 and Apple Command Line Tools; it is not a prebuilt application.

1. Complete the [prerequisites](#prerequisites), including the separate RT-only toggle unlock. Set **Path Tracing off**, then fully exit the game and Windows Steam.
2. Download and extract the ZIP. In Terminal, type `cd ` (with a space), drag the extracted folder into the Terminal window, and press Return.
3. Check the setup, then install:

   ```sh
   python3 manage.py install --dry-run
   python3 manage.py install
   ```

4. Launch as usual with **Ray Tracing on** and **Path Tracing off**, then load a save.

For a wrapper in a different location, see [Install](#install). To remove the workaround, use [the uninstall command](#remove-the-workaround).

## Tested setup

- Apple M5, 16 GB RAM
- macOS 27.2, build 26B5101f
- Sikarugir wrapper 1.0.11, Wine 10.0
- Apple GPTK / D3DMetal 4.0 beta 2
- Windows Steam, Witcher 3 Remastered 5.01, executable version 5.0.0.1048522
- Existing FidelityFX startup proxy and RT-only toggle unlock already installed

This preview installer targets Sikarugir and that exact RT-unlocked executable. CrossOver, Whisky and other game builds need separate adaptation and testing.

## What it fixes

With RT enabled, D3DMetal aborted while precompiling `PTRGS_SharcUpdateFinal`, even with Path Tracing disabled. The captured Metal compiler error was:

```text
Encountered unlowered function call to air.atomic.global.cmpxchg.weak.i64.
Verify device or GPU architecture supports this feature
```

The compatibility library first forwards normal pipeline creation. If a `PTRGS_Sharc` pipeline fails with that exact error, and the saved `PTEnable` setting is false, it substitutes an inactive compute kernel while retaining the descriptor's other properties and linked functions. It does not implement 64-bit atomic emulation or working Path Tracing. Other shaders are forwarded normally.

The confirmed launch logged 66 normal RT pipeline compilations, seven SHARC substitutions and no subsequent pipeline failures. Its monitor observed no dispatch of the substituted kernel. This supports the assumption that the failing shaders were unused with PT off on the tested setup.

The shared edition replaces account-specific paths with installer-supplied environment variables. It compiled and passed an isolated normal GPU dispatch test; its installer passed fixture checks. Full gameplay has been confirmed with the original local edition. A separate gameplay test of the portable edition has not been performed. See [validation details](docs/VALIDATION.md) for the exact scope.

## Prerequisites

Your game should already launch normally with RT off. Keep the working startup repair in place.

The toggle unlock is a separate community patch: [RT-only patch by gabrielmaialva33](https://gist.github.com/gabrielmaialva33/33ebb2542f0513d55100b22aa2149ff5). Follow its build verification and use `--rt-only` for the executable your wrapper actually launches. This package does not modify the game executable.

The executable hashes used by this preview are:

```text
Pristine tested executable:
2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101

After the RT-only unlock:
7b64e2c9207f341cc992f3db4a952d948f446554d3a005dd859316a2f70d38c9
```

The earlier startup proxy came from [tholtman1-del/witcher3-crossover-fix](https://github.com/tholtman1-del/witcher3-crossover-fix). That resolves a separate stream-output startup failure. It is credited here and is not bundled.

Building requires Python 3 and Apple Command Line Tools with a SDK containing the Metal 4 APIs. If the tools are missing, run `xcode-select --install` and complete Apple's installation prompt.

## Install

1. Set Path Tracing **off** in the game and exit. Fully exit Windows Steam as well; closing its window can leave Steam running.
2. Download this repository's ZIP and extract it. Open Terminal in the extracted folder.
3. Run the read-only check:

   ```sh
   python3 manage.py install --dry-run
   ```

4. If it passes, build and install:

   ```sh
   python3 manage.py install
   ```

5. Launch normally. Turn Ray Tracing **on** and leave Path Tracing **off**, then load a save.

Defaults are `~/Applications/SteamWindows.app` and `~/Documents/The Witcher 3/dx12user.settings`. For different locations, supply `--wrapper` and `--settings` with quoted paths. `--game-exe` selects the actual launched executable if it is outside the wrapper's usual `bin/x64` directory. Include those same arguments for the dry run and installation.

The installer builds the library locally from the included source, backs up the wrapper's complete Info.plist, and adds three environment exports. It preserves existing launch flags and commands. It refuses to replace an existing `DYLD_INSERT_LIBRARIES` setting. Game files, saves and graphics settings are not edited.

## Check the result

The log is inside the wrapper at `Contents/SharedSupport/Logs/Witcher3RTCompatPublic.log`. Look for successful normal RT pipelines and successful inactive SHARC substitutions.

If `INACTIVE_PT_DISPATCH` appears, a substituted shader may be in use on that setup. Remove the workaround and report the marker, hardware, macOS, renderer and game versions. This package's monitor covers the direct and indirect compute dispatch methods it hooks; it is not a comprehensive GPU capture.

## Remove the workaround

Close the game and Windows Steam, then run:

```sh
python3 manage.py uninstall
```

Include `--wrapper` if you used a custom wrapper path. The script removes its exports and preserves backups and the RT toggle unlock. If other wrapper preferences changed after installation, it preserves those preferences. If its export suffix was edited, automatic removal stops instead of overwriting the changed commands.

Only the source and installer are distributed here. Apple renderer libraries, game executables, saves, personal logs and the other community projects are not included.

Developed with Codex and tested by the person whose game had the failure. Independent reproduction reports are welcome.

## License

The source and installer in this repository are available under the [MIT License](LICENSE). The external game, renderer and community patches retain their respective licenses and are not included in this package.
