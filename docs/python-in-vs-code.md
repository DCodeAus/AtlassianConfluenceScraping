# Running Python in VS Code: A First-Time Setup Guide

## What you need before starting

1. **Python itself** — VS Code doesn't come with Python built in, it just edits the files. Download it from python.org (the Windows Store version works too, but python.org is the more standard choice).
2. **VS Code** — from code.visualstudio.com, if not already installed.
3. **The Python extension for VS Code** — inside VS Code, click the Extensions icon on the left sidebar (looks like four squares), search "Python", install the official one published by Microsoft.

---

## Step 1: Install Python correctly

Run the installer from python.org. On the very first screen, there's a checkbox near the bottom:

**☑ Add python.exe to PATH**

Tick this. It's easy to miss, and skipping it is the single most common reason Python "doesn't work" afterwards. This checkbox is what lets Windows find Python from anywhere, including inside VS Code's terminal.

If you've already installed Python without ticking this, you can re-run the installer and choose "Modify" to add it afterwards, no need to fully uninstall first.

---

## Step 2: Confirm Python is actually installed

Open a **fresh** terminal (Command Prompt or PowerShell, doesn't matter which) and type:

```
python --version
```

You should see something like `Python 3.12.x`. If instead you get an error saying `python` isn't recognised, the PATH checkbox above either wasn't ticked or the terminal needs a restart to pick up the change (see Troubleshooting below).

---

## Step 3: Open your project folder in VS Code

Use **File → Open Folder**, not just individual files. This matters because VS Code uses the folder as the "workspace," which is how it figures out which Python interpreter and settings to use for everything inside it.

---

## Step 4: Select your Python interpreter

VS Code needs to know *which* Python installation to use (useful later if you ever have more than one, e.g. different versions or virtual environments).

1. `Ctrl + Shift + P` to open the command palette
2. Type **Python: Select Interpreter**
3. Choose the one that matches the version you saw in Step 2

You'll see the selected interpreter shown in the bottom-right corner of the VS Code window from then on.

---

## Step 5: Running a script

Create or open a `.py` file. There are two ways to run it:

### Option A: The Play button
A triangular "run" button appears top-right of the editor once a `.py` file is open. Click it, VS Code opens a terminal panel automatically and runs the script for you. This is the easiest option and handles most of the setup detail automatically.

### Option B: Typing it into the terminal yourself
Open a terminal inside VS Code (**Terminal → New Terminal**, or `` Ctrl + ` ``), then type:

```
python scriptname.py
```

Note the `python` prefix, typing just `scriptname.py` on its own won't work, the terminal needs to be told which program should open the file.

---

## Common first-time issues

**"python is not recognised as an internal or external command"**
PATH isn't set up correctly. Re-check Step 1's checkbox, or try `py scriptname.py` instead of `python scriptname.py` as a quick alternative (the `py` launcher is installed separately and often works even when `python` doesn't).

**Works in a normal terminal but not inside VS Code**
If VS Code was open *before* Python was installed, it may still be using an outdated snapshot of your system settings. Fully close and reopen VS Code (not just a new terminal tab) and try again.

**Nothing happens when typing the filename alone**
Add the `python` prefix, see Option B above.

**Wrong Python version being used**
Double check Step 4, VS Code might have a different interpreter selected than the one you're expecting.

---

## Quick reference

| Task | Command |
|---|---|
| Check Python is installed | `python --version` |
| Run a script | `python scriptname.py` |
| Find where Python is installed | `where python` (Windows) |
| Open command palette | `Ctrl + Shift + P` |
| Open terminal | `` Ctrl + ` `` |
