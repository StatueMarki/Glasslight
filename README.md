# Welcome to Glasslight

A tiny Spotlight replacement that can open your apps as quickly as your typing skills will allow it without the rather long animations or slow search of Spotlight. Glasslight is ultra-light weight but keeps the beauty of Liquid Glass. It uses a predictive text algorithm to predict what you are typing and sets priorities for Apps you open quite often. This predictive text corrects spelling mistakes as well as capitalization.

Pure AppKit + Liquid Glass (`NSGlassEffectView`, `.clear` style), no SwiftUI, no dependencies.
Requires macOS 26 or later.
|
|
|
|
|
## About Liquid Glass

You can customize the lensing and tint of the liquid glass effect using the below listed commands without having to rebuild the entire application. Simply quit and reopen Glasslight.
You can tune both without rebuilding. Quit and reopen Glasslight afterwards.

```bash
defaults write local.glasslight GlassTint -float 0.3     # 0 = fully clear … 1 = solid
defaults write local.glasslight GlassLensing -int 2      # 0 = standard … 3 = strongest
```

Lensing uses a private AppKit property. If a future macOS removes it, Glasslight falls back to standard clear glass.
|
|
|
|
|
## How to use it

Ones you launch Glasslight, it will appear as a simple magnifying glass/zoom icon in your menu bar. From there you can quit Glasslight and toggle the option to launch the program on startup. This feature is off by default as I think it is very annoying when programs assume you want all the features it can offer and sneak themselves into background activities and "launch on startup" without asking.

You can open and close Glasslight by simply double tapping the right command key ⌘. After that, it is just like using the normal Spotlight search: Type in what program you want to launch, press Enter, when your program is being suggested or use the up and down arrow keys to go down the list of available applications (you will probably never do that)



## Build

```bash
./build.sh            # → build/Glasslight.app
./build.sh install    # → ~/Applications/Glasslight.app, then launches it
./build.sh test       # ranking + shortcut tests
```
