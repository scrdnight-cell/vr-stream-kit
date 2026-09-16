# VR Stream Kit — Terms of Use

These terms explain what the kit is, what it does to your computer, and who is responsible for what. The code itself is licensed under the MIT License in [LICENSE](LICENSE); these terms add plain-language conditions for using it. The first time you open the menu you are asked to accept them, and nothing is changed on your system until you do.

Version 2 · September 2026 · by [scrdnight-cell](https://github.com/scrdnight-cell)

---

## 1. Unofficial

VR Stream Kit is an independent project. It is **not made, endorsed, sponsored or supported by Bigscreen, Inc.**, Meta Platforms, the authors of any virtual display driver, or any streaming service.

"Bigscreen" and "Bigscreen Remote Desktop" are trademarks of Bigscreen, Inc. Other names belong to their owners. They are used here only to say what the kit works with. Do not present the kit, or anything made from it, as an official product of any of them.

For help with the kit, use the kit's own documentation — not the support channels of Bigscreen or anyone else.

## 2. What the kit does to your computer

By accepting, you agree to let the kit do the following. None of it needs administrator rights.

| Action | Detail | How it is undone |
|---|---|---|
| **Changes the display layout** | Connects and detaches ("parks") a virtual display, and changes which display is primary, with the Windows display configuration API. | Pressing **R** hands the display back to your monitor and parks the virtual display. Opening the menu or quitting it with **Q** also parks it. |
| **Starts Bigscreen Remote Desktop with its debugger on** | Adds `--inspect=127.0.0.1:9229`. The kit uses the app's own built-in functions through it to set resolution, bitrate and frame rate, and to end the stream cleanly. | Nothing on disk is changed. The debugger closes when Bigscreen closes. |
| **Closes programs** | Closes Bigscreen Remote Desktop — including a copy that was already running when a session starts — and its own background helpers. | — |
| **Reads system information** | GPU, video memory, displays, network adapter, CPU, installed app versions, performance counters and the Windows event log (to check for GPU resets). | Nothing is changed. |
| **Writes files in its own folder** | `config\` (your profiles, the virtual display's mode, acceptance of these terms) and `logs\`. | Delete the folders. |

**The debugger is a local risk.** While a session runs, any program on your own PC could connect to `127.0.0.1:9229` and control the Bigscreen app. It cannot be reached from the network. Do not run sessions on a PC where you do not trust the other software running on it.

## 3. No data collection

The kit collects nothing, contacts no server of its own, and sends nothing anywhere. It has no telemetry and no update checks. Logs and settings stay in the kit's folder, and you control whether they are ever shared. The streaming itself is done by Bigscreen Remote Desktop, under Bigscreen's own terms and privacy policy.

## 4. Your responsibilities

- **Other software's terms.** You are responsible for following the terms of Bigscreen, your headset platform, your virtual display driver, and anything you stream or play. Bigscreen's published Terms of Service include a licence restricted to personal, non-commercial use and restrictions on modifying or reverse-engineering its services. The kit does not change or redistribute any Bigscreen file. It calls functions the installed app already contains, at runtime, through the app's built-in debugger. Whether that is acceptable under Bigscreen's terms is for you to judge. If you are unsure, use the **Stock** profile: it streams with no quality tuning, and the kit then only manages the displays. The debugger is still used to end the stream cleanly when you press **R**.
- **Protected content.** The kit does not remove, bypass or weaken copy protection (DRM or HDCP) and must not be changed to. Streaming services decide what quality they send, and the kit accepts that.
- **What you stream is your responsibility.** The kit is a general tool: it keeps a desktop stream stable and sharp, whatever is on the desktop. You alone decide what you show, and who sees it — in a private session, or in a room shared with other people. You are responsible for having the right to show it to that audience, under copyright law and under the terms of the service or software it comes from.
- **Health and safety.** Follow your headset maker's safety guidance. Low frame rates and stutter can cause discomfort. Stop if you feel unwell.

## 5. No warranty, your own risk

The kit is provided **"as is", without warranty of any kind** (see [LICENSE](LICENSE)). It changes display settings and closes programs. Display drivers, GPU drivers and apps behave differently between systems and versions. A profile that passes every check can still freeze a stream, and a GPU driver can still reset.

To the extent the law allows, the authors and contributors are **not liable** for any loss or damage arising from using the kit. That includes lost work, a desktop left on a display you cannot see, GPU resets, crashes, account actions by third parties, or hardware problems.

**If the desktop is ever stuck on the virtual display:** switch your monitor on and press **Win+P** (then choose *PC screen only*). If that fails, boot into Safe Mode and disable the virtual display driver in Device Manager.

## 6. Indemnity

You agree to indemnify and hold harmless the kit's authors and contributors against any claim, demand, loss or cost, including reasonable legal fees, that arises from:
- your use of the kit;
- the content you stream, display or share with it;
- your breach of these terms, or of the terms of any third-party software or service.

The kit's authors do not monitor, control or approve what anyone streams with it.

## 7. Checks and recommendations are guidance

Profile checks, recommendations and the headroom check combine measurements taken on your system with published standards (H.264 levels) and rules of thumb from testing. They are not guarantees. Anything that is possible is allowed. Where your hardware might not keep up, you are warned, and the choice is yours.

## 8. Changes

These terms may change in a later version of the kit. If they change in substance, the version number above goes up, and the menu asks you to accept again.
