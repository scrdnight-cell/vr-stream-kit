# VR Stream Kit

> **Unofficial.** Not made, endorsed or supported by Bigscreen, Inc. or Meta. Works with Bigscreen Remote Desktop. See [TERMS.md](TERMS.md).

By [scrdnight-cell](https://github.com/scrdnight-cell) · MIT licensed · [Support](#support)

Stream your Windows desktop to a VR headset with **Bigscreen Remote Desktop**, on a **virtual display**, so you can switch your real monitor off — without the stream dropping, and with better quality than the headset menu offers.

A setup menu detects your hardware, recommends settings for what you are doing, checks every profile against what your system can actually do, and saves your own profiles. Press **R** when you are done and it shuts everything down in a safe order.

---

## What it solves

| Problem | Cause | What the kit does |
|---|---|---|
| Switching the monitor off kills the stream | Bigscreen captures whichever display is **primary when it starts**. If that is the monitor, switching it off removes the capture source. | Makes the virtual display primary **before** Bigscreen starts, so the stream is bound to a display that never disappears. |
| The headset's quality menu stops at 1080p | That limit is only in the headset menu. The PC app accepts up to 4320 lines, 100 Mbps and 300 fps. | Starts Bigscreen with its debugger open on `127.0.0.1` and sets resolution, bitrate and frame rate directly. |
| The stream freezes or drops under load | One GPU is rendering a game **and** encoding the stream. At full load the encoder is starved. Some settings also exceed what headset decoders accept. | Recommends settings for your hardware and activity, warns when a profile is more than your system can carry, and measures real GPU headroom. |
| Ending a session badly crashes Bigscreen | Changing displays under a live stream crashed Bigscreen in testing, and a crash is the moment a GPU driver is most likely to reset. | **R** tears the stream down first, then closes Bigscreen, then hands the display back — and checks Windows for a GPU reset, by when it happened rather than when it was reported (see [Troubleshooting](#troubleshooting)). |
| Switching the monitor off mid-session stops the picture | Bigscreen creates a screen capture for **every** monitor on the GPU when it starts. A monitor that leaves the desktop takes its capture with it, and the capture cannot be rebuilt — so the stream can stop even though the headset was watching the virtual display. | Compares what Bigscreen is capturing with what is attached, and **restarts Bigscreen** whenever they differ, so it captures what is there now. The headset reconnects by itself and the profile is re-applied. |
| The monitor is off when the session ends | Windows cannot make a detached monitor primary. | A small hidden helper waits and makes the monitor primary as soon as you switch it on. |
| The desktop gets stranded on the virtual display — sometimes needing Safe Mode to recover | A virtual display left attached becomes the only screen when Windows switches an idle DisplayPort monitor off, and nothing is running to switch back. | The virtual display is **parked** (detached, still installed) whenever the kit is not running — and if a session dies without cleaning up, a local helper hands the desktop back as soon as a monitor returns. |

Not everyone hits every problem. A system with plenty of GPU headroom may never see the stream starve — the menu's **headroom check** tells you which case you are in before you change anything.

---

## Things people ask for that this does

These come up repeatedly wherever desktop streaming to a headset is discussed. Where a link is given, it is the public source for the claim; everything marked *(tested here)* is from this kit's own testing on one system, and your results may differ.

**"The resolution menu in the headset only offers 720p and 1080p."** That limit is in the headset's menu, not the PC app: the app's own functions accept up to 4320 lines, 0.5–100 Mbps and 1–300 fps. Bigscreen advertises [4K remote desktop](https://bigscreenvr.com/remotedesktop/), and the kit sets height, bitrate and frame rate directly rather than through the menu.

**"Can I set a custom bitrate or frame rate?"** Yes — any combination inside those ranges, saved as a profile. The kit checks it against your own hardware and warns only when your system does not support it, rather than capping you at a preset.

**"Desktop text is unreadable in the headset."** Text is the one thing that genuinely benefits from resolution. The *Desktop* profiles raise the stream to your virtual display's height with bitrate to match, which is exactly the case the headset menu cannot express.

**"I want to play my normal, non-VR games on a huge virtual screen."** That works, and it is the case most likely to disappoint without tuning: the same GPU renders the game *and* encodes the stream. The kit's games profiles, the headroom check and the advice in [Keeping headroom](#keeping-headroom) exist for this — render at the stream resolution, cap the frame rate, use the upscaler *(tested here: a game rendering at 4K held the GPU at 95–97% and the stream dropped while loading; the same game at 1440p capped to 30 fps ran at about 60% and held)*.

**"When I switch my monitor off, streaming freezes or the headset loses the desktop."** A widely reported problem — [users report a DisplayPort monitor switching off freezing VR desktop streaming](https://steamcommunity.com/app/382110/discussions/0/1333474229086218279), and the usual advice is to buy an [HDMI or DisplayPort dummy plug](https://www.amazon.com/Emulator-Headless-Compatible-Computer-fit-Headless/dp/B09P6DKF28) or move the monitor to another cable type. This kit does the same job in software with a virtual display driver: the stream is bound to a display that cannot be switched off, and when your monitor comes and goes the capture is rebuilt around it.

**"My desktop ended up on a display I cannot see."** The flip side of using a virtual display, and the reason this kit exists. See [Parking the virtual display](#parking-the-virtual-display) and [The guardian](#the-guardian).

---

## Requirements

- **Windows 10 or 11.** No administrator rights needed.
- **A virtual display driver**, for example the open-source [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver), with one virtual display enabled at the resolution you want (e.g. 3840×2160).
- **Bigscreen Remote Desktop** for Windows, installed per user (the usual install). The kit finds it under `%LOCALAPPDATA%\BigscreenRemoteDesktop`.
- **Node.js 22 or newer** ([nodejs.org](https://nodejs.org)) — used to talk to Bigscreen's debugger.
- **A headset** with the Bigscreen app, already paired with the PC.

Tested with an Intel Arc A770 and a Meta Quest 3.

---

## Setup

1. Put this folder anywhere, e.g. `Documents\VR-Stream-Kit`.
2. Install the virtual display driver and set the virtual display's resolution and refresh rate once in Windows display settings. After that the kit connects and parks it for you, and it comes back with the same settings.
3. Open `Start VR Stream.bat` in a text editor if you need to change a setting:
   - `VIRTUAL_ADAPTER` — part of your virtual display driver's name in Device Manager → *Display adapters*, if it is not the one linked above.
   - `BIGSCREEN_DIR` — only if Bigscreen is installed somewhere unusual.
   - `PARK_VIRTUAL_DISPLAY` — `yes` (default) detaches the virtual display whenever the kit is not running; `no` leaves it attached all the time.
   - `ON_MONITOR_RETURN` — what a monitor coming back on mid-session means: `monitor` (default) hands the desktop back to it, `virtual` keeps the stream on the virtual display. Either way the stream keeps going.
4. Run `Start VR Stream.bat`. The first time, it shows a short summary of the [terms](TERMS.md) and asks you to accept them - nothing on your system is changed before you do. Then press **S** to confirm the kit sees your GPU, both displays, Bigscreen and Node.js.

---

## The menu

```
  VR STREAM KIT
  =============

  PROFILES
    1  Desktop            1440p  30 fps  40 Mbps   Everyday desktop use.
    2  Desktop 4K         2160p  30 fps  80 Mbps   Sharpest text. Needs GPU headroom.
    3  Film (24 fps)      1440p  48 fps  50 Mbps   Most films and series.
    4  TV (25 fps)        1440p  50 fps  50 Mbps   UK/European broadcast content.
    5  Games              1440p  30 fps  60 Mbps   Render the game at 1440p, cap it at 30 fps.
    6  Games (smooth)     1080p  60 fps  60 Mbps   Needs GPU headroom. Cap the game at 60 fps.
    7  Stock              no tuning                No tuning - the headset menu decides.
    8  My racing setup    1080p  60 fps  60 Mbps   (custom)

    C  Create a profile         D  Delete a custom profile
    S  System report            H  Headroom check
    Q  Quit

  Choose (Enter = Film (24 fps)):
```

- **Number** — check that profile against your system, then start a session with it. **Enter** repeats the last profile you used.
- **C — Create a profile.** Name it, say what it is for (desktop, films/TV, games — and for films, the content's frame rate), and the menu shows recommendations for your hardware with suggested values. Press Enter to accept each, or type your own. The profile is checked against your system before it is saved (see [Profile checks](#profile-checks)).
- **D — Delete** a custom profile.
- **S — System report:** GPU and video memory, the hardware encoder Bigscreen will use, the virtual display's and monitor's resolution and refresh rate, the network link (wired or Wi-Fi), CPU, Bigscreen and Node.js versions.
- **H — Headroom check.** Start the game or film first (and Bigscreen, if you want its encoder included), then press **H**. It samples real GPU load for about 20 seconds and reports the peak, the busiest program, video-engine load and video memory, with a verdict: **healthy**, **tight** or **no headroom**.

Custom profiles and your last choice are saved in `config\profiles.json`, so you only enter them once.

**Built-in profiles fit your virtual display.** A stream taller than the virtual display is scaled up from a smaller desktop and adds no detail, so built-ins are lowered to its height (a 1080p virtual display turns the 1440p built-ins into 1080p ones), and profiles that only make sense on a taller display, like *Desktop 4K*, are hidden. Custom profiles are kept exactly as you enter them; the check warns if one is taller than the virtual display.

A lower virtual display is a sensible choice in its own right: a Quest 3 shows roughly 2K per eye, so a game rendering at 1080p or 1440p for a matching stream does less work than one rendering 4K only to be scaled down.

---

## Running a session

1. With your monitor **on**, run `Start VR Stream.bat` and choose a profile.
2. Connect from the headset. The profile is applied a few seconds after it connects, and again whenever the headset reconnects.
3. Switch the monitor off if you like.
4. **To finish, press R** in the window. That is the whole shutdown — no need to take the headset off, switch the monitor on, or close Bigscreen first.

```
  ================================================================
   SHUTDOWN COMPLETE
     Bigscreen : closed
     GPU       : no GPU reset
     Display   : monitor is off - it will be made primary when you switch it on
  ================================================================
```

The window closes by itself after a clean shutdown and stays open if anything went wrong. Everything is logged to `logs\session.log`.

---

## Following the display

Bigscreen decides what it can capture when it starts. Its log shows it creating a capture for every monitor on the GPU, not only the one you watch:

```
Found monitor: \\.\DISPLAY5.   1920 x 1080.   0, 1920, 0, 1080.     <- virtual display
Found monitor: \\.\DISPLAY1.   1920 x 1080.  -1920, 0, 0, 1080.     <- your monitor
```

When a DisplayPort monitor is switched off it leaves the desktop entirely, and that capture cannot be rebuilt. Bigscreen keeps trying, once a second, for as long as the monitor is away:

```
Failed to recreate duplication object: -2147467259
Failed to recreate duplication object: -2147467259
...
```

The headset gets a blank or frozen picture until the monitor comes back — even though you were watching the virtual display.

So the kit checks the one fact that matters: **does the list of monitors Bigscreen is capturing match the monitors actually attached?** It reads that list from Bigscreen's own log. When the two differ, the capture is broken, and Bigscreen is rebuilt around the displays that exist now:

| What you do | What the kit does | What you see in the headset |
|---|---|---|
| Switch the monitor **off** | Closes Bigscreen (stream torn down first), makes the virtual display primary, starts Bigscreen again — now capturing one display | The picture returns on its own after a few seconds |
| Switch the monitor **on** | Same again, and hands the desktop back to the monitor (`ON_MONITOR_RETURN=monitor`) | The picture returns, showing the monitor's desktop |

Checking the match, rather than watching for a *change*, is what makes this reliable. A change can happen while nothing is looking — the monitor dropping out in the second the headset connects, which is exactly how a blank picture first got past an earlier version — but a mismatch stays true until it is fixed. It is checked while waiting for the headset, when the session watcher starts, and every second after that. You can switch the monitor off before or after connecting; it makes no difference.

A mismatch has to hold for **1 second** before anything happens, restarts are at least **15 seconds** apart, and after **6** in one session the kit stops restarting and says so.

**How long a restart takes.** Measured on the test system, from the display change being detected to a tuned stream: **13–22 seconds**, typically about 16. Most of that is the headset noticing Bigscreen has come back, which the PC cannot speed up. The kit's own part is short: it waits for Bigscreen to report its stream torn down rather than pausing a fixed time, switches the primary display as soon as the change holds, and applies the profile the moment the new connection accepts it. Each restart writes its time to `logs\session.log` as `Streaming again - N s from the display change being detected.`

**R works during a restart.** The kit does not sit waiting for the headset to reconnect: the session carries on watching the keyboard and the displays the whole time, so you can end the session, or switch the monitor again, at any point.

A restart waits for the old Bigscreen process to be completely gone before starting the new one, and confirms the new one really started. Bigscreen refuses to run twice, so starting it a moment too early does nothing at all — and leaves the session with no app. Bigscreen's log is copied to `logsigscreen-<time>-before-restart.txt` first, because each launch overwrites it.

Every restart follows the same order as the shutdown — stream down, Bigscreen closed, *then* displays changed — because changing displays under a live stream crashed Bigscreen in testing.

### The guardian

While a session runs, the virtual display is attached, so something must be watching in case the session dies: the window closed with **X**, a crash, or the stream dropping with **R** never pressed. That is the guardian: one ordinary hidden PowerShell process (`display-guardian.ps1`), started with the session from this folder.

- While the session is alive it does nothing.
- If the session finishes properly it exits, having done nothing.
- If the session dies without handing the display back, it closes Bigscreen if needed, waits for a monitor to come back, makes it primary — the one that was primary before the session, if it is still there — parks the virtual display, and exits.

Nothing is installed: no scheduled task, no service, no logon entry, nothing outside this folder. You can see it in Task Manager as `powershell.exe` running `display-guardian.ps1`, and ending it is harmless — opening the kit repairs the layout anyway, and says so.

---

## Parking the virtual display

A virtual display that stays attached to the desktop between sessions is a trap. When Windows switches your monitor off after its idle timer, a DisplayPort monitor drops off the desktop completely — leaving the virtual display, which you cannot see, as the only screen. With nothing running to switch back, the desktop is stranded there.

So the kit only keeps the virtual display attached while it is in use:

- **Session start** — it is connected again with the layout Windows saved for it (its resolution and refresh rate), then made primary.
- **Session end** — once the monitor is primary again, the virtual display is detached. If the monitor is off, the background helper does this right after handing the display back.
- **Opening the kit, and quitting the menu (Q)** — the virtual display is detached.
- **A session that fails to start** — the display is handed back and the virtual display detached, as a normal end would.

**Right after installing a virtual display driver**, Windows may attach the virtual display and even make it primary. Opening the kit once parks it and makes your monitor primary again — the kit does this every time it opens, before you choose anything, so closing the window afterwards leaves nothing attached.

Parking needs no administrator rights: it removes the virtual display from the desktop layout, the same as disconnecting it in Display settings, and the driver stays installed. The kit never detaches the virtual display while it is the only screen attached, so the desktop is never left without a display. The menu shows it as *parked* between sessions, and profile checks use the resolution it will come back with.

Set `PARK_VIRTUAL_DISPLAY=no` in the launcher if you want the virtual display attached all the time.

> While the virtual display is primary, the taskbar and new windows appear on it. On the monitor, move a window across with **Win+Shift+Left/Right**.

---

## Keeping headroom

The profile checks compare a profile with your hardware; headroom depends on what you are doing.

**Desktop and apps.** Mostly still images, so cheap to encode, and text benefits from resolution. 1440p at 30 fps suits most systems; 2160p at 30 fps gives the sharpest text if the headroom check stays healthy.

**Films and TV.** Match the stream to the content: **48 fps** for 24 fps films, **50** for 25 fps TV, **60** for 30 fps video — every frame is then shown evenly, with no judder on pans. Film motion is the hardest content to compress, so give it bitrate rather than resolution. Streaming services usually send desktop browsers 720p or 1080p, so a 4K stream spends encoder work on detail that is not there.

**Games.** The game and the stream encoder share one GPU. If the GPU runs at 100%, the encoder is starved and the stream can freeze or drop — often while loading. Keep the game below about **85%** GPU load:
- render the game at the **stream resolution**, not higher (the virtual display can still offer 4K),
- **cap the game's frame rate** at the stream frame rate,
- turn on the **upscaler** if offered (DLSS, FSR or XeSS).

From testing on one system: a demanding game rendering at 4K held the GPU at 95–97% and the stream dropped while loading; the same game rendering at 1440p, capped at 30 fps, ran at about 60% and the stream held for the whole session. A system with more headroom may run heavier profiles without any of this — measure first.

**Encoder cost, as a guide.** Roughly, a 1440p stream at 30 fps is light (about 10–15% of the video engine on the test GPU); a 4K stream at 30 fps or a 1440p film stream at 48 fps costs about three times that.

**The headset.** A Quest 3 shows roughly 2K per eye, so streams above 1440p mostly benefit desktop text.

---

## Profile checks

Any profile your system can carry is allowed - including custom ones far beyond the built-ins, such as 8K at 120 fps on hardware built for it. A check only speaks up when **what it detects on your system** does not support a setting.

| Mark | Meaning | When |
|---|---|---|
| `[X]` | Not possible - must be changed | Outside what Bigscreen accepts (16-4320 lines, 1-300 fps, 0.5-100 Mbps), or beyond **H.264 level 6.2**, the top of the standard Bigscreen encodes with (8K reaches about 128 fps). |
| `[!]` | Your system says it will not work as intended - you can still start | Taller than your virtual display, or faster than its refresh rate (raise the virtual display to match) · wider than hardware H.264 encoders support (4096 pixels per side on current GPUs) · more than half your network link, or a PC on Wi-Fi above 40 Mbps · more than 1080p on an integrated or low-memory GPU, or more encoding work than 4K at 30 fps on a GPU that is not in the class that usually carries it. |
| `[i]` | Worth knowing, nothing to fix on the PC | The H.264 level the headset has to decode - the PC cannot see the headset's decoder, so if the picture freezes when a profile applies, the headset is the limit · film frame rates that are not a multiple of the content's. |

In testing, a Quest 3 froze on 4K at 72 fps (beyond level 5.2), which is why the level is shown - but that is a limit of that headset, not of the profile.
---

## How it works

```
Start VR Stream.bat             settings, then the menu
└─ scripts\menu.ps1             profiles, checks, advice, system report, headroom check
   │   hardware.ps1  profiles.ps1  headroom.ps1
   └─ run-session.ps1           one session, start to finish
      ├─ close-bigscreen.ps1    close any running Bigscreen safely
      ├─ display.ps1            connect the parked virtual display
      ├─ prefer-virtual.ps1     virtual display primary
      ├─ display-guardian.ps1   hidden safety net, outlives the session if it dies
      ├─ bigscreen.ps1          start Bigscreen, wait for the headset, apply the profile
      │   └─ bigscreen-quality.js   sets height, bitrate and frame rate over the debugger
      └─ session-watch.ps1      follows the displays; on R, shuts down in order
         ├─ bigscreen.ps1             displays changed: close, re-aim, start again
         ├─ close-bigscreen.ps1       tear the stream down (bigscreen-close.js), then close
         └─ prefer-virtual.ps1 -Restore   monitor primary again, then park the virtual display
```

- **Display switching** uses the Windows CCD API (`SetDisplayConfig`), the same one the Settings app uses, so no administrator rights are needed.
- **Stream settings** are applied through Bigscreen's own functions via its debugger. Nothing on disk is changed; closing Bigscreen undoes them.
- **The debugger listens on `127.0.0.1` only** — it cannot be reached from the network — and closes with Bigscreen.
- **Hardware detection** reads Windows' display-adapter records, display configuration, network routes and performance counters. Nothing is changed.

---

## What the kit cannot fix

Some limits are in Windows, the GPU or the app, not in anything a script can reach. They are listed here so you can recognise them rather than chase them.

**Hardware acceleration can blank a window in the stream.** A program using GPU acceleration can hand its window straight to the GPU, so [those pixels never reach the desktop surface that the Desktop Duplication API reads](https://obsproject.com/forum/threads/screen-recording-woes-black-screen-issue-with-browser-hardware-acceleration.172210/) — the window is black or frozen in the headset while looking fine on your monitor. Any capture-based streaming app has this, and no setting in this kit changes it. The workaround is in the program itself:

- **Chrome, Edge:** Settings → System → *Use graphics acceleration when available* → off.
- **Firefox:** Settings → General → Performance → untick *Use recommended performance settings*, then *Use hardware acceleration when available* → off.
- Games: try borderless window instead of exclusive full screen.

Turning hardware acceleration off moves that work onto the CPU, so it costs performance — and on a system that is already short of headroom for encoding, that is a real trade.

**Protected video stays black, by design.** Capture APIs are required to blank DRM-protected surfaces, so a paid film may play with sound and no picture. The kit does not, and must not, work around that. Use the service's own app in the headset instead.

**Streaming services decide their own quality.** Many cap desktop browsers well below your subscription's maximum, and a virtual display cannot present itself as an HDCP-capable screen. A 4K stream cannot add detail that was never sent.

**Bigscreen needs a hardware video encoder.** Its requirements name [an Nvidia GPU with NVENC, an AMD GPU on Adrenalin 18.8.1 or newer, or Intel graphics with Quick Sync](https://bigscreenvr.com/remotedesktop/). Press **S** in the menu to see which one the kit detects on your system. Without one there is nothing to tune.

**The headset's own decoder is a ceiling the PC cannot see.** A profile the PC accepts can still freeze the picture if the headset cannot decode it *(tested here: a Quest 3 froze at 4K 72 fps)*. That is why the level a profile needs is shown as information, not a block.

**A headset in a low-power or battery-saving state looks soft** regardless of what the PC sends.

---

## Troubleshooting

**"No virtual display driver found."** The driver is not installed, disabled, or failed to load — check Device Manager → *Display adapters*, and `VIRTUAL_ADAPTER` matches its name, then press **S**. A *parked* virtual display is normal between sessions and needs nothing.

**The virtual display came back at the wrong resolution.** Connect it once through a session, set the resolution in Windows display settings while it is attached, and end the session with R. Windows saves that layout and reuses it next time.

**"The display switch did not hold."** Another program is changing the display layout — close other display-management or monitor-switching tools.

**The picture goes black when the mouse is still (games or full-screen video).** Screen capture only receives a new frame when the desktop image or the pointer changes, and a full-screen app can bypass the desktop image. Try: switching the virtual display driver's cursor to software (for the driver above, `HardwareCursor` = `false` in its settings file, then reload the driver); turning off *Optimizations for windowed games* in *Settings → System → Display → Graphics*; switching the game between borderless and exclusive full screen.

**The picture cuts out for a few seconds when I switch the monitor on or off.** That is the restart described in [Following the display](#following-the-display) — Bigscreen is rebuilding its capture around the displays that are attached now. `logs\session.log` names each one. If you would rather stay on the virtual display when a monitor comes back, set `ON_MONITOR_RETURN=virtual` in the launcher.

**The stream freezes the moment the profile is applied.** The frame rate or resolution is more than the headset's decoder accepts. Lower the frame rate first.

**The stream drops under load.** Run the headroom check with the activity running. If it says **tight** or **no headroom**, lower the game's render resolution or frame cap, or use a lighter profile.

**"GPU RESET" in Event Viewer that does not line up with anything.** Windows Error Reporting re-files the same old GPU reports again and again — on the test machine about a hundred times each, some years old, often in a burst just after a reboot. So a *LiveKernelEvent 141* entry's time is when it was *reported*, not when the GPU reset. Each report names its dump file, and the name carries the real moment: `WATCHDOG-20260916-0948.dmp`. The kit's shutdown check uses that, not the report time.

**Bigscreen does not start, with no error and nothing in its log.** Something has set `ELECTRON_RUN_AS_NODE=1` in the environment you launched from — VS Code does this for processes it starts, including tasks and terminals it hosts. It makes any Electron app, Bigscreen included, exit instantly and silently. The kit clears it before starting Bigscreen; if you start Bigscreen yourself from such a terminal, run it from the Start menu instead.

**A window is black or frozen in the headset but fine on the monitor.** Hardware acceleration in that program — see [What the kit cannot fix](#what-the-kit-cannot-fix), which lists the settings to turn off.

**Streaming services look soft, or a film plays with sound and no picture.** Services cap desktop browsers regardless of plan, and protected video is blanked by every capture API. Both are covered in [What the kit cannot fix](#what-the-kit-cannot-fix). For paid films, the service's own headset app is the answer.

---

## Diagnostics (optional)

`diagnostics\session-telemetry.ps1` records app GPU load, encoder load, GPU memory, CPU and network every 30 seconds to `logs\telemetry-*.csv`, and prints crashes, GPU resets and a summary every five minutes — useful for tuning a profile over a long session.

```
powershell -ExecutionPolicy Bypass -File diagnostics\session-telemetry.ps1 -App msedge
powershell -ExecutionPolicy Bypass -File diagnostics\session-telemetry.ps1 -App MyGame
```

`-App` is the process name without `.exe`. Stop it with **Ctrl+C**.

---

## Limits

- Relies on the Bigscreen Remote Desktop PC app exposing its stream settings to its debugger. A future Bigscreen release could remove that; the kit reports `NOT FOUND` if so.
- One virtual display is assumed. With several monitors, the one that was primary when the session started is the one the desktop is handed back to; any other attached monitor is used as a fallback.
- Recommendations are rules of thumb from testing, and the encoder width limit is general to current GPUs rather than read from yours; the headroom check measures your system, and should win where they disagree.
- Closing the window with **X** is survivable but not the intended way out — use **R**. The guardian takes over: it shuts Bigscreen down properly (stream torn down first, as R does), waits for a monitor, hands the desktop back and parks the virtual display. It cannot run the shutdown report or the GPU-reset check, so R still tells you more.
- Each display change costs a Bigscreen restart, so the headset picture drops while it reconnects - about 16 seconds on the test system, most of it the headset's own reconnect.
- The debugger is reachable by other programs on the same PC while a session runs (never from the network).

---

## Support

Written and maintained by [scrdnight-cell](https://github.com/scrdnight-cell). It is a personal project given away under the MIT licence, so be clear about what that means: **there is no support contract, no guaranteed response and no warranty** (see [TERMS.md](TERMS.md)). What there is:

- **Issues and questions** — open an issue on the repository. Best effort, in spare time.
- **Fixes and improvements** — pull requests are welcome, especially from people with hardware this was never tested on: other GPUs, other headsets, other virtual display drivers.
- **Before reporting anything**, the kit can usually tell you what went wrong itself:
  - press **S** for the system report (GPU, encoder, displays, network, versions) and **H** for a headroom check while the problem is happening;
  - `logs\session.log` records every session, every display change and every shutdown;
  - `diagnostics\session-telemetry.ps1` records load over a long session.
  Include those in an issue, along with what you did and what happened.

**Do not take kit problems to Bigscreen, Meta or your virtual display driver's authors.** This is not their software, and their support channels are for their own products. Equally, if something is broken in Bigscreen itself, this kit cannot fix it — report it to them.

Tested on one system only: an Intel Arc A770 and a Meta Quest 3, on Windows 11. Everything else is untested, which is not the same as unsupported — it just means you may be the first.

---

## Terms and licence

- **[TERMS.md](TERMS.md)** - what the kit does to your system, what it does not do, and who is responsible for what. You accept them once, the first time the menu opens.
- **[LICENSE](LICENSE)** - the code is MIT-licensed.

VR Stream Kit is an independent, unofficial project. "Bigscreen" and "Bigscreen Remote Desktop" are trademarks of Bigscreen, Inc.; they are used only to say what the kit works with. The kit does not modify or redistribute any Bigscreen file, and does not bypass copy protection.
