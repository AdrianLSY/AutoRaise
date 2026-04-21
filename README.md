**AutoRaise**

When you hover a window it is raised to the front and gets the focus — instantly, the moment the cursor crosses the window boundary. There is also an option to warp
the mouse to the center of the activated window when using the cmd-tab or cmd-grave (backtick) key combination.
See also [on stackoverflow](https://stackoverflow.com/questions/98310/focus-follows-mouse-plus-auto-raise-on-mac-os-x)

**Quick start**

1. Download the [latest release](https://github.com/sbmpost/AutoRaise/releases/latest)
2. In Finder, double click the downloaded file to unpack.
3. Locate the unpacked folder and double click AutoRaise.dmg
4. Single click AutoRaise under "Locations" in Finder.
5. Drag AutoRaise.app into the Applications folder.
6. Open AutoRaise from Applications.
7. Left click the balloon icon in the menu bar to give permissions to AutoRaise in System/Accessibility.
8. Right click the balloon icon in the menu bar to set preferences.

*Important*: When you enable Accessibility in System Preferences, if you see an older AutoRaise item with balloon icon in the
Accessibility pane, first remove it **completely** (clicking the minus). Then stop and start AutoRaise by left clicking the balloon
icon. The item should re-appear so that you can properly enable Accessibility.

**Upgrading from 5.x**

AutoRaise 6.0 replaces the polled timer loop with an event-driven `CGEventTap`. Raises now fire as soon as the cursor crosses a window boundary, with no settle time and no multi-tick countdown. The following options are removed: `-delay`, `-focusDelay`, `-requireMouseStop`, `-mouseDelta`, and the `EXPERIMENTAL_FOCUS_FIRST` compile flag. Existing configurations that reference these keys will emit a warning on startup and be auto-migrated (the config file is rewritten with the deprecated lines stripped, preserving your comments and the ordering of retained keys). Deprecated CLI flags are also warned-and-ignored; AutoRaise continues to run with default behavior.

**Compiling AutoRaise**

To compile AutoRaise yourself, download the master branch from [here](https://github.com/sbmpost/AutoRaise/archive/refs/heads/master.zip)
and use the following commands:

    unzip -d ~ ~/Downloads/AutoRaise-master.zip
    cd ~/AutoRaise-master && make clean && make && make install

**Advanced compilation options**

  * ALTERNATIVE_TASK_SWITCHER: The warp feature works accurately with the default OSX task switcher. Enable the alternative
  task switcher flag if you use an alternative task switcher and are willing to accept that in some cases you may encounter
  an unexpected mouse warp.

  * OLD_ACTIVATION_METHOD: Enable this flag if one of your applications is not raising properly. This can happen if the
  application uses a non native graphic technology like GTK or SDL. It could also be a [wine](https://www.winehq.org) application.
  Note this will introduce a deprecation warning.

Example advanced compilation command:

    make CXXFLAGS="-DOLD_ACTIVATION_METHOD" && make install

**Running AutoRaise**

After making the project, you end up with these two files:

    AutoRaise (command line version)
    AutoRaise.app (version without GUI)

The first binary is to be used directly from the command line and accepts parameters. The second binary, AutoRaise.app, can
be used without a terminal window and relies on the presence of a configuration file. AutoRaise.app runs on the background and
can only be stopped via "Activity Monitor" or the AppleScript provided near the bottom of this README.

**Command line usage:**

    ./AutoRaise -pollMillis 8 -warpX 0.5 -warpY 0.1 -scale 2.5 -altTaskSwitcher false -ignoreSpaceChanged false -ignoreApps "App1,App2" -ignoreTitles "^window$" -stayFocusedBundleIds "Id1,Id2" -disableKey control

  - pollMillis: Minimum milliseconds between raise checks. Lower values increase responsiveness but also CPU load during mouse motion. Minimum = 1, default = 8 (~120 checks per second at sustained motion). With the event-driven architecture, AutoRaise uses zero CPU when the mouse is idle.

  - warpX: A Factor between 0 and 1. Makes the mouse jump horizontally to the activated window. By default disabled.

  - warpY: A Factor between 0 and 1. Makes the mouse jump vertically to the activated window. By default disabled.

  - scale: Enlarge the mouse for a short period of time after warping it. The default is 2.0. To disable set it to 1.0.

  - altTaskSwitcher: Set to true if you use 3rd party tools to switch between applications (other than standard command-tab).

  - ignoreSpaceChanged: Do not immediately raise/focus after a space change. The default is false.

  - invertDisableKey: Makes the disable AutoRaise key behave in the opposite way. The default is false.

  - invertIgnoreApps: Turns the ignoreApps parameter into an includeApps parameter. The default is false.

  - ignoreApps: Comma separated list of apps for which you would like to disable focus/raise.

  - ignoreTitles: Comma separated list of window titles (a title can be an ICU regular expression) for which you would like to disable focus/raise.

  - stayFocusedBundleIds: Comma separated list of app bundle identifiers that shouldn't lose focus even when hovering the mouse over another window.

  - disableKey: Set to control, option or disabled. This will temporarily disable AutoRaise while holding the specified key. The default is control.

  - verbose: Set to true to make AutoRaise show a log of events when started in a terminal.

AutoRaise can read these parameters from a configuration file. To make this happen, create a **~/.AutoRaise** file or a
**~/.config/AutoRaise/config** file. The format is as follows:

    #AutoRaise config file
    pollMillis=8
    warpX=0.5
    warpY=0.1
    scale=2.5
    altTaskSwitcher=false
    ignoreSpaceChanged=false
    invertDisableKey=false
    invertIgnoreApps=false
    ignoreApps="IntelliJ IDEA,WebStorm"
    ignoreTitles="\\s\\| Microsoft Teams,^window$,..."
    stayFocusedBundleIds="com.apple.SecurityAgent,..."
    disableKey="control"

**AutoRaise.app usage:**

    a) setup configuration file, see above ^
    b) open /Applications/AutoRaise.app (allow Accessibility if asked for)
    c) either stop AutoRaise via "Activity Monitor" or read on:

To toggle AutoRaise on/off with a keyboard shortcut, paste the AppleScript below into an automator service workflow. Then
bind the created service to a keyboard shortcut via System Preferences|Keyboard|Shortcuts. This also works for AutoRaise.app
in which case "/Applications/AutoRaise" should be replaced with "/Applications/AutoRaise.app"

Applescript:

    on run {input, parameters}
        tell application "Finder"
            if exists of application process "AutoRaise" then
                quit application "/Applications/AutoRaise"
                display notification "AutoRaise Stopped"
            else
                launch application "/Applications/AutoRaise"
                display notification "AutoRaise Started"
            end if
        end tell
        return input
    end run

**Troubleshooting & Verbose logging**

If you experience any issues, it is suggested to first check these points:

- Are you using the latest version?
- Does it work with the command line version?
- Are you running other mouse tools that might intervene with AutoRaise?
- Are you running two AutoRaise instances at the same time? Use "Activity Monitor" to check this.
- Is Accessibility properly enabled? To be absolutely sure, remove any previous AutoRaise items
that may be present in the System Preferences|Security & Privacy|Privacy|Accessibility pane. Then
start AutoRaise and enable accessibility again.

If after checking the above you still experience the problem, I encourage you to create an issue
in github. It will be helpful to provide (a small part of) the verbose log, which can be enabled
like so:

    ./AutoRaise <parameters you would like to add> -verbose true

The output should look something like this:

    v6.0 by sbmpost(c) 2026, usage:

    AutoRaise
      -pollMillis <1, 2, ..., 8, ..., 50, ...>  (default 8)
      -warpX <0.5> -warpY <0.5> -scale <2.0>
      -altTaskSwitcher <true|false>
      -ignoreSpaceChanged <true|false>
      -invertDisableKey <true|false>
      -invertIgnoreApps <true|false>
      -ignoreApps "<App1,App2, ...>"
      -ignoreTitles "<Regex1, Regex2, ...>"
      -stayFocusedBundleIds "<Id1,Id2, ...>"
      -disableKey <control|option|disabled>
      -verbose <true|false>

    Started with:
      * pollMillis: 8ms
      * ignoreSpaceChanged: false
      * invertDisableKey: false
      * invertIgnoreApps: false
      * disableKey: control
      * verbose: true

    2026-04-21 14:25:56.192 AutoRaise[44780:1615626] AXIsProcessTrusted: YES
    2026-04-21 14:25:56.216 AutoRaise[44780:1615626] System cursor scale: 1.000000
    2026-04-21 14:25:56.234 AutoRaise[44780:1615626] Got run loop source: YES
    2026-04-21 14:25:56.284 AutoRaise[44780:1615626] Mouse window: AutoRaise — AutoRaise -verbose 1
    2026-04-21 14:25:56.285 AutoRaise[44780:1615626] Focused window: AutoRaise — AutoRaise -verbose 1
    2026-04-21 14:25:56.287 AutoRaise[44780:1615626] Desktop origin (-1920.000000, -360.000000)
    ...
    ...

*Note*: Dimentium created a homebrew formula for this tool which can be found here:

https://github.com/Dimentium/homebrew-autoraise
